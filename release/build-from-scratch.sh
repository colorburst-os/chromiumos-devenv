#!/bin/bash
# Build a colorburst release END TO END on a clean build machine, from an empty
# directory to a verity release image, a staged (unsigned) OTA payload, and the
# per-language USB images -- without signing, publishing, tagging or pushing.
#
#   release/build-from-scratch.sh /data/cbos              # build main
#   release/build-from-scratch.sh /data/cbos v2026.32.12  # build a tag
#   release/build-from-scratch.sh --preflight /data/cbos  # only check the host
#   release/build-from-scratch.sh --no-variants /data/cbos
#
# This script is standalone on purpose: it clones the repository itself, so it
# is the ONE file you copy to a new machine. Everything after the clone is the
# repository's own tooling, in the order README.md documents.
#
# Expect ~5 hours cold and ~250 GB: a 287-project repo sync, a 30 GB Chromium
# fetch, then a full clean build in which Chrome is the long pole. Run it under
# nohup, tmux or screen -- the build scripts inhibit host sleep, but nothing
# saves you from a closed SSH session.
#
# RESUMABLE. Every phase drops a stamp in <dir>/.stamps/ and is skipped on a
# re-run, so an interrupted run costs only the phase it died in. To redo a
# phase, delete its stamp. This matters: a killed sync or fetch is otherwise
# hours to repeat, and an interrupted Chrome compile leaves partial state in
# the build cache that phase 5 must clear anyway (it wipes the board cache, so
# re-running it is always safe -- and is what makes it safe).
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - sign (needs the YubiKey)         release/sign-on-yubikey.sh
#   - publish the OTA payload          release/publish.sh
#   - publish the USB images           release/publish-usb-images.sh
#   - tag anything                     release/tag.sh
#   - push to any remote
# Those are maintainer steps with credentials behind them; a build machine
# should not be able to take them.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/colorburst-os/chromiumos-devenv.git}"
BOARD="${BOARD:-colorburst}"
MANIFEST_URL="https://chromium.googlesource.com/chromiumos/manifest"
REPO_LAUNCHER_URL="https://storage.googleapis.com/git-repo-downloads/repo"
NEED_GB=250

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PREFLIGHT_ONLY=0
VARIANTS=1
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --preflight)   PREFLIGHT_ONLY=1 ;;
        --no-variants) VARIANTS=0 ;;
        -h|--help)     usage 0 ;;
        -*)            echo "unknown option: $1" >&2; usage 1 ;;
        *)             ARGS+=("$1") ;;
    esac
    shift
done
DIR="${ARGS[0]:-}"
REF="${ARGS[1]:-}"
[ -n "$DIR" ] || usage 1

# Absolute, and creatable. Everything below lives under it; nothing outside it
# is written.
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
SRC="$DIR/chromiumos-devenv"          # the repository
CHROME="$DIR/chromium-src"            # sibling, as chromium/common.sh expects
STAMPS="$DIR/.stamps"
LOGS="$DIR/logs"
mkdir -p "$STAMPS" "$LOGS"

step()  { printf '\n=== %s  %s\n' "$(date -Is)" "$*"; }
note()  { printf '    %s\n' "$*"; }
die()   { printf '!! %s\n' "$*" >&2; exit 1; }
done_p() { [ -e "$STAMPS/$1" ]; }
mark()  { : > "$STAMPS/$1"; }

# A phase runs under `tee` so a live run is watchable and a dead one is
# diagnosable. pipefail is on, so the phase's status is the one that counts.
phase() { # phase <stamp> <logname> <command...>
    local stamp="$1" logname="$2"; shift 2
    if done_p "$stamp"; then note "skip (already done): $stamp"; return 0; fi
    "$@" 2>&1 | tee "$LOGS/$logname.log"
    mark "$stamp"
}

# --- preflight ---------------------------------------------------------------
# Everything checked here has bitten a real build. Fail now, not four hours in.
step "preflight"

for c in git curl python3 docker gh; do
    command -v "$c" >/dev/null || die "$c not found -- install it first"
done
docker info >/dev/null 2>&1 || die "docker is not usable by $(id -un) -- add yourself to the docker group and re-login"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated -- run: gh auth login"

if [ "$VARIANTS" = 1 ]; then
    for c in mcopy sfdisk zip; do
        command -v "$c" >/dev/null || die "$c not found (needed for the USB variants) -- apt install mtools fdisk zip, or pass --no-variants"
    done
fi

AVAIL_GB=$(df -BG --output=avail "$DIR" | tail -1 | tr -dc '0-9')
[ "${AVAIL_GB:-0}" -ge "$NEED_GB" ] || die "$DIR has ${AVAIL_GB} GB free; need ~${NEED_GB} GB"
note "disk: ${AVAIL_GB} GB free at $DIR"

# The container's build user has a UID baked in at image build time, and it
# must match the invoking user or the bind-mounted trees are unwritable --
# which surfaces hours later as a PermissionError mid-fetch.
if docker image inspect cros-build >/dev/null 2>&1; then
    IMG_UID="$(docker run --rm --entrypoint id cros-build -u 2>/dev/null || echo '')"
    if [ -n "$IMG_UID" ] && [ "$IMG_UID" != "$(id -u)" ]; then
        die "the cros-build image is baked for UID $IMG_UID but you are $(id -u) -- rebuild it: docker build --build-arg HOST_UID=\$(id -u) -t cros-build $SRC/docker/"
    fi
    note "cros-build image present (UID ${IMG_UID:-unknown})"
else
    note "cros-build image absent -- will build it after the clone"
fi

# `repo` is not packaged on most hosts. Keep our own launcher inside $DIR
# rather than installing to the system.
export PATH="$DIR/bin:$PATH"
if ! command -v repo >/dev/null; then
    note "repo launcher absent -- will install to $DIR/bin/repo"
fi

if [ "$PREFLIGHT_ONLY" = 1 ]; then
    step "preflight only -- host looks usable"
    exit 0
fi

# --- the clock ---------------------------------------------------------------
# Written BEFORE the first real command, so the elapsed time reported at the
# end covers the clone as well. Kept across resumes: a re-run reports total
# wall clock from the original start, which is the number that matters.
if [ ! -f "$DIR/BUILD-START" ]; then
    { date -Is; date +%s; } > "$DIR/BUILD-START"
fi
START_EPOCH="$(sed -n 2p "$DIR/BUILD-START")"
note "started $(sed -n 1p "$DIR/BUILD-START")"

# --- 1. the repository -------------------------------------------------------
step "1/6  clone the repository"
if ! done_p clone; then
    [ -d "$SRC/.git" ] || git clone "$REPO_URL" "$SRC" 2>&1 | tee "$LOGS/clone.log"
    if [ -n "$REF" ]; then
        git -C "$SRC" fetch --tags --quiet origin
        git -C "$SRC" checkout --quiet "$REF"
    fi
    mark clone
fi
note "$(git -C "$SRC" log --oneline -1)"

if ! docker image inspect cros-build >/dev/null 2>&1; then
    step "1b/6  build the cros-build container image for UID $(id -u)"
    phase docker-image docker-build \
        docker build --build-arg HOST_UID="$(id -u)" -t cros-build "$SRC/docker/"
fi

if ! command -v repo >/dev/null; then
    mkdir -p "$DIR/bin"
    curl -fsSL "$REPO_LAUNCHER_URL" -o "$DIR/bin/repo"
    chmod +x "$DIR/bin/repo"
    note "installed $DIR/bin/repo"
fi

# The version being built comes from the tree, never from this script.
VER="$(tr -d '[:space:]' < "$SRC/chromiumos/src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files/RELEASE" 2>/dev/null || true)"

# --- 2. the ChromiumOS tree --------------------------------------------------
step "2/6  assemble the ChromiumOS tree (287 projects, ~176 GB)"
sync_tree() {
    mkdir -p "$SRC/chromiumos"
    cd "$SRC/chromiumos"
    # Any manifest first, so .repo/manifests exists as a git repo to drop the
    # pinned one into.
    [ -d .repo ] || repo init -u "$MANIFEST_URL"
    cp "$SRC/pinned-manifest.xml" .repo/manifests/
    repo init -m pinned-manifest.xml
    mkdir -p .repo/local_manifests
    # A COPY, not the symlink README.md shows. The symlink points at
    # <repo>/local_manifests/, which is outside the one directory the build
    # container bind-mounts, so inside the container it dangles and chromite
    # logs "Lookup service error ... no such file". Harmless today -- the
    # version comes from files/RELEASE -- but it is a real dangling path, and
    # a copy costs nothing. Re-copied on every run so it cannot go stale.
    cp -f "$SRC/local_manifests/colorburst.xml" .repo/local_manifests/colorburst.xml
    # repo retries transient network failures itself; -j8 is what README uses.
    repo sync -j8
}
phase sync repo-sync sync_tree

# --- 3. Chromium -------------------------------------------------------------
step "3/6  fetch Chromium (~30 GB)"
phase fetch chromium-fetch env CHROME="$CHROME" "$SRC/chromium/fetch.sh"

# --- 4. the patch series -----------------------------------------------------
# The pinned base is a property of the release, so read it from the release
# record rather than hardcoding it here; fall back to the series' own base.
step "4/6  apply the colorburst Chromium patch series"
apply_series() {
    local base=""
    if [ -n "$VER" ] && [ -f "$SRC/releases/$VER/RELEASE.json" ]; then
        base="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"]["chromium"]["pinned_base"])' \
                "$SRC/releases/$VER/RELEASE.json" 2>/dev/null || true)"
    fi
    base="${base:-831a446cd4}"
    echo ">>> pinned base: $base"
    git -C "$CHROME/src" checkout -B colorburst "$base"
    "$SRC/chromium-patches/apply-all.sh" "$CHROME/src"
}
phase patches apply-all apply_series

# --- 5. the build ------------------------------------------------------------
# rebuild-release.sh is itself the clean-build guarantee: it re-normalises every
# patched tree, wipes the board cache, bootstraps the board, compiles our Chrome
# from local source, builds a verity image with cros_debug OFF, verifies it in
# place, and stages the unsigned payload. It fails loudly rather than falling
# back to a prebuilt Chrome.
step "5/6  clean release build (hours)"
phase build rebuild-release env CHROME="$CHROME" "$SRC/chromium/rebuild-release.sh"

VER="$(tr -d '[:space:]' < "$SRC/chromiumos/src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files/RELEASE")"
IMGDIR="$(readlink -f "$SRC/chromiumos/src/build/images/${BOARD}/latest")"
IMG="$(ls "$IMGDIR"/colorburst-"${VER}"*.bin 2>/dev/null | grep -v -- '-en\.bin$\|-vi\.bin$' | head -1 || true)"
[ -n "$IMG" ] && [ -f "$IMG" ] || die "no release image for ${VER} in $IMGDIR"

# --- 6. the USB variants -----------------------------------------------------
# Not an afterthought: publish-usb-images.sh refuses an image whose OEM
# partition carries no manifest, so BOTH variants are repacked, English
# included. Each is a few hundred bytes of OEM partition -- the kernel, rootfs
# and verity hash are identical, so all variants share the one OTA payload.
if [ "$VARIANTS" = 1 ]; then
    step "6/6  language variants + zips"
    make_variants() {
        cd "$SRC"
        release/make-variant.sh us "$IMG" "$IMGDIR/colorburst-${VER}-en.bin"
        release/make-variant.sh vn "$IMG" "$IMGDIR/colorburst-${VER}-vi.bin"
        cd "$IMGDIR"
        rm -f "colorburst-${VER}-en.zip" "colorburst-${VER}-vi.zip"
        zip -j "colorburst-${VER}-en.zip" "colorburst-${VER}-en.bin"
        zip -j "colorburst-${VER}-vi.zip" "colorburst-${VER}-vi.bin"
    }
    phase variants make-variants make_variants
else
    step "6/6  language variants skipped (--no-variants)"
fi

# --- report ------------------------------------------------------------------
{ date -Is; date +%s; } > "$DIR/BUILD-END"
ELAPSED=$(( $(sed -n 2p "$DIR/BUILD-END") - START_EPOCH ))

step "DONE -- colorburst ${VER}"
printf '    elapsed      %02d:%02d (h:mm) from %s\n' \
    $(( ELAPSED / 3600 )) $(( ELAPSED % 3600 / 60 )) "$(sed -n 1p "$DIR/BUILD-START")"
printf '    image        %s\n' "$IMG"
printf '    payload      %s\n' "$SRC/chromiumos/ota-release/${VER}/"
[ "$VARIANTS" = 1 ] && {
    printf '    usb images   %s\n' "$IMGDIR/colorburst-${VER}-{en,vi}.zip"
}
printf '    logs         %s\n' "$LOGS/"
cat <<EOF

Nothing was signed, published, tagged or pushed. The maintainer steps, in order:

    cd $SRC
    release/sign-on-yubikey.sh chromiumos/ota-release/${VER}
    release/publish.sh chromiumos/ota-release/${VER}
    release/publish-usb-images.sh ${VER} --draft
    release/tag.sh ${VER}

publish.sh looks for the update-server checkout as a sibling of the repository;
on a machine that has none, point it at one:

    UPDATE_SERVER_DIR=/path/to/update-server release/publish.sh chromiumos/ota-release/${VER}
EOF
