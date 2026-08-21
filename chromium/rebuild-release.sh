#!/bin/bash
# One-shot, deterministic CLEAN release rebuild. Run it and wait -- it needs no
# decisions along the way, which is the point: the image it produces depends on
# the committed tree, not on who (or what) is driving.
#
#   chromium/rebuild-release.sh
#
# What it does, in order:
#   1. Normalise the patch state of both patched trees to the committed series:
#        - chromium-src : hard-reset to the pinned base, then apply-all.sh
#        - platform2    : the update_engine device-id patch (idempotent)
#   2. Nuke the board build cache for a clean build -- the colorburst sysroot
#      (+ its binpkgs), the retired amd64-generic sysroot, and old images.
#      KEEPS out/sdk (the host SDK, expensive to rebuild) and .cache/distfiles
#      (downloads). Builds in place on the source partition.
#   3. bootstrap-board.sh -- setup_board + a COMPLETE build-packages. On a
#      freshly-nuked board this builds our local Chromium (CHROME_ORIGIN=
#      LOCAL_SOURCE) and every image package as binpkgs.
#   4. build-release.sh -- kernel/BSP/update_engine with release USE, then
#      `cros build-image base` (verity on, no cros_debug), then it verifies the
#      image in place with debugfs and exits non-zero if anything is wrong.
#   5. gen-payload.sh -- stage the UNSIGNED OTA payload + hashes under
#      chromiumos/ota-release/<version>/ for signing.
#
# It does NOT sign (that needs the YubiKey) and does NOT push anything.
# Everything heavy runs inside the build container via the other scripts; this
# driver only orchestrates them.
set -euo pipefail
. "$(dirname "$0")/common.sh"        # DEVENV, CHROME, BOARD, in_container
cd "$DEVENV"

# The pinned Chromium base apply-all.sh expects (see its header).
PINNED_BASE="${PINNED_BASE:-831a446cd4}"

log() { printf '\n=== %s === %s\n' "$1" "$(date -Is)"; }

# --- 0. preflight -----------------------------------------------------------
[ -d "$CHROME/src/.git" ] || { echo "no chromium checkout at $CHROME/src -- see chromium/README.md" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
log "preflight ok; board=$BOARD chrome=$CHROME"
df -h "$DEVENV" | sed 's/^/    /'

# --- 1. patches: normalise every tree to the committed series ---------------
log "chromium-src: hard-reset to pinned base $PINNED_BASE, then apply full series"
git -C "$CHROME/src" reset --hard "$PINNED_BASE"
chromium-patches/apply-all.sh "$CHROME/src"

log "platform2: update_engine patches (device-id + DLC-URL redirect)"
# Guard on the NEWEST patch's marker: apply.sh applies the whole series in one
# shot, so if the latest change (the DLC CDN redirect) is present, the earlier
# device-id patch is too. Checking only the older marker would skip apply.sh on
# a tree that has device-id but not the newer patch.
if grep -q 'dl.colorburst.net' chromiumos/src/platform2/update_engine/cros/install_action.cc 2>/dev/null; then
    echo "    already applied -- skipping"
else
    platform2-patches/apply.sh chromiumos/src/platform2
fi

# (No chromite patch: the DLC factory-install approach was reverted -- Crostini
# DLCs are served from the update server, so the stock chromite/dlc_allowlist.py
# and upstream termina-dlc ebuilds are used unchanged.)

# --- 2. nuke the board build cache (clean build) ----------------------------
# Done inside the container so root-owned build artefacts can be removed.
log "nuke board build cache (keep out/sdk + .cache/distfiles)"
in_container chromium-nuke-cache "
    set -x
    cd ~/chromiumos
    rm -rf out/build/${BOARD} out/build/amd64-generic src/build/images/${BOARD}
    echo 'kept: out/sdk (host SDK cache), .cache/distfiles (downloads)'
    df -h /home/cros/chromiumos
"

# --- 3. bootstrap the board (setup_board + full build-packages) -------------
log "bootstrap board: setup_board + build-packages (builds local Chrome)"
chromium/bootstrap-board.sh

# --- 4. release image build + in-place verification -------------------------
log "release image build + verify"
chromium/build-release.sh

# --- 5. stage the unsigned OTA payload --------------------------------------
log "stage unsigned OTA payload for signing"
release/gen-payload.sh

# --- done -------------------------------------------------------------------
REL="$(release_version)"
log "DONE -- release ${REL}"
echo "Unsigned payload staged under chromiumos/ota-release/${REL}/"
echo "Next (maintainer, needs the YubiKey):"
echo "    release/sign-on-yubikey.sh chromiumos/ota-release/${REL}"
echo
echo "Crostini DLCs (no YubiKey; verified against the on-device manifest hash --"
echo "see release/DLC-RELEASE.md). Run once per release, before/with publishing:"
echo "    release/publish-dlc-images.sh"
