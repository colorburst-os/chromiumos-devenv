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
#        - platform2    : the whole platform2-patches series (idempotent)
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

log "platform2: apply the whole patch series (device-id, DLC-URL, regions)"
# Run apply.sh unconditionally. It is safe to re-run -- each patch goes through
# `git apply --3way` and falls back to `patch --forward`, both of which no-op on
# an already-applied patch.
#
# This used to be guarded by grepping the tree for the NEWEST patch's marker and
# skipping when found. That guard is a trap: the moment a patch is added to the
# series, the marker names an older one, and any tree carrying that older patch
# gets "already applied -- skipping" while the new patch is silently never
# applied. That is exactly how it stood after the regions patch landed -- the
# guard still checked the DLC marker, so a tree from before today would have
# skipped the OOBE fix and rebuilt an image that crashes on first boot.
platform2-patches/apply.sh chromiumos/src/platform2

# (No chromite patch: the DLC factory-install approach was reverted -- Crostini
# DLCs are served from the update server, so the stock chromite/dlc_allowlist.py
# and upstream termina-dlc ebuilds are used unchanged.)

# --- 2. nuke the board build cache (clean build) ----------------------------
# `setup_board --force`, NOT `rm -rf out/build/${BOARD}`.
#
# The sysroot is full of root-owned files, and inside the chroot parts of it
# (var/tmp/portage) are live mount points. A plain rm from the container runs as
# uid 1000 and dies with "Operation not permitted" / "Permission denied" on
# exactly those paths -- and because `rm -rf` keeps going and the whole step was
# unchecked, the build sailed on with the sysroot still standing. Portage then
# saw chromeos-chrome already installed at the same version and skipped it, so
# the "clean" release image carried a Chrome built from an EARLIER source tree.
# 2026.32.11 was staged that way once: 30 minutes end to end, every gate green,
# and not reproducible from its own recorded manifest.
#
# --force is chromite's own board-root recreation: it knows about the mounts and
# runs with the privileges to remove them.
log "nuke board build cache (keep out/sdk + .cache/distfiles)"
in_container chromium-nuke-cache "
    set -ex
    cd ~/chromiumos
    cros_sdk -- setup_board --board=${BOARD} --force
    cros_sdk -- sudo rm -rf /build/${BOARD}/packages /build/amd64-generic
    rm -rf src/build/images/${BOARD}
    echo 'kept: out/sdk (host SDK cache), .cache/distfiles (downloads)'
    df -h /home/cros/chromiumos
"

# Assert it actually happened, from the host, where the sysroot is plainly
# visible. A wipe that quietly did nothing is the whole failure mode above, and
# chromeos-chrome is the package it matters most for: bootstrap-board.sh is the
# only place our Chromium is compiled, and it only compiles when portage cannot
# find chromeos-chrome already installed or as a binpkg.
CHROME_LEFTOVERS=$(ls -d "chromiumos/out/build/${BOARD}/var/db/pkg/chromeos-base/chromeos-chrome-"* \
                          "chromiumos/out/build/${BOARD}/packages/chromeos-base/chromeos-chrome-"* \
                   2>/dev/null || true)
if [ -n "$CHROME_LEFTOVERS" ]; then
    echo "FATAL: the board wipe did not remove chromeos-chrome:" >&2
    echo "$CHROME_LEFTOVERS" | sed 's/^/    /' >&2
    echo "Chrome would NOT be rebuilt and the release would not match its own" >&2
    echo "recorded source. Refusing to continue." >&2
    exit 1
fi
log "board wipe verified: no chromeos-chrome installed or cached"

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
echo
echo "Language variants. Each is ChromeOS's own OEM customization manifest"
echo "written onto the OEM partition -- no rebuild, no re-sign, and every"
echo "variant shares this one OTA payload. Run it for EVERY shipped image:"
echo "    release/make-variant.sh us <image>.bin <image>-en.bin"
echo "    release/make-variant.sh vn <image>.bin <image>-vi.bin"
