#!/bin/bash
# Cut a release: set the tree's version, record exactly what went into it, tag
# every repo. Run this BEFORE chromium/rebuild-release.sh -- the build reads
# the version this writes.
#
#   release/cut.sh patch            # 2026.32.9  -> 2026.32.10  (next in series)
#   release/cut.sh series           # 2026.32.9  -> 2026.<ISO week>.0 (new cycle)
#   release/cut.sh 2026.34.0        # explicit
#   release/cut.sh record           # (re)write the manifest for the CURRENT
#                                   #  version, without bumping -- use after a
#                                   #  build to capture what it actually built
#
# `record` describes the tree AS IT IS NOW: it stamps the current HEAD as the
# release's commit. That is right at cut time and wrong for documenting a build
# that happened earlier -- fix the commit by hand afterwards if you are writing
# up a past release (2026.32.9 was recorded that way).
#
# WHY THIS EXISTS
# ---------------
# A version has to identify SOURCE, not a moment. Through 2026.32.9 the
# version was computed from `date` at build time in five places, so the same
# commit built a week later produced a different version and a shipped release
# could not be rebuilt. Now files/RELEASE in the BSP holds the whole string,
# every consumer reads it, and this script is the only thing that changes it.
#
# WHAT A RELEASE IS
# -----------------
# releases/<version>/
#   manifest.xml   `repo manifest -r` -- all ~287 projects at exact SHAs,
#                  INCLUDING both forks (local_manifests resolves those by
#                  branch tip, so without this snapshot the fork state of an
#                  old release is unrecoverable)
#   RELEASE.json   the version, the chromium-os commit, the Chromium base,
#                  fork SHAs, artifact hashes, signing key
# Together with the tag in each repo, that is enough to rebuild.
#
# VERSION SHAPE: <year>.<series>.<patch>
#   year   - year the series opened
#   series - the ISO week the cycle opened (bumped deliberately, not by clock)
#   patch  - +1 per SHIPPED build in the series; never reused
set -euo pipefail

export BOARD="${BOARD:-colorburst}"
. "$(dirname "$0")/../chromium/common.sh"
cd "$DEVENV"

BSP="chromiumos/src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files"
RELEASE_FILE="$BSP/RELEASE"
BUILD_ID_FILE="$BSP/BUILD-ID"
OVERLAYS="chromiumos/src/overlays"
CROSVM="chromiumos/src/platform/crosvm"

CUR="$(release_version)"
MODE="${1:?usage: $0 patch|series|<version>|record}"

case "$MODE" in
    record) NEW="$CUR" ;;
    patch)  NEW="${CUR%.*}.$(( ${CUR##*.} + 1 ))" ;;
    series) NEW="$(date +%G).$(( 10#$(date +%V) )).0" ;;
    [0-9]*) NEW="$MODE" ;;
    *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $NEW" >&2; exit 1; }

# Never re-cut a version that already has a record: its artifacts are public
# and its hashes are fixed. `record` is the one exception (it refreshes the
# manifest for the version currently in the tree).
if [ "$MODE" != record ] && [ -e "releases/$NEW/RELEASE.json" ]; then
    echo "releases/$NEW already exists -- versions are never reused" >&2
    exit 1
fi

echo ">>> $CUR -> $NEW"
printf '%s\n' "$NEW" > "$RELEASE_FILE"

# BUILD_ID = the chromium-os commit that drives the build. Written now as the
# CURRENT HEAD; the cut commit itself lands right after, so re-run `record`
# after committing if you want it to name the cut commit exactly.
git rev-parse --short HEAD > "$BUILD_ID_FILE"

mkdir -p "releases/$NEW"

echo ">>> snapshotting the source manifest (all projects at exact SHAs)"
( cd chromiumos && python3 .repo/repo/repo manifest -r -o "$DEVENV/releases/$NEW/manifest.xml" )

OVERLAYS_SHA="$(git -C "$OVERLAYS" rev-parse HEAD)"
CROSVM_SHA="$(git -C "$CROSVM" rev-parse HEAD 2>/dev/null || echo unknown)"
PINNED_BASE="${PINNED_BASE:-831a446cd4}"

python3 - "$NEW" "$OVERLAYS_SHA" "$CROSVM_SHA" "$PINNED_BASE" "$(git rev-parse HEAD)" <<'PY'
import json, os, sys
ver, overlays, crosvm, base, devenv_commit = sys.argv[1:6]
path = f"releases/{ver}/RELEASE.json"
rec = json.load(open(path)) if os.path.exists(path) else {}
rec.update({
    "version": ver,
    "source": {
        "chromium_os": {"repo": "colorburst-os/chromiumos-devenv",
                        "commit": devenv_commit},
        "chromium": {"pinned_base": base,
                     "patches": "chromium-patches/apply-all.sh at the commit above"},
        "manifest": {"file": "manifest.xml",
                     "note": "repo manifest -r: every project at an exact SHA"},
        "forks": {"board-overlays": overlays, "crosvm": crosvm},
    },
})
rec.setdefault("artifacts", {})
rec.setdefault("signing", {"key": "update-payload-key.pub.pem",
                           "slot": "YubiKey PIV 9C"})
json.dump(rec, open(path, "w"), indent=2)
print(f"    wrote {path}")
PY

cat <<EOF

=== cut $NEW ===
  version file : $RELEASE_FILE
  record       : releases/$NEW/{RELEASE.json,manifest.xml}

Next:
  1. git add -A && git commit -m "Cut $NEW"        # in chromium-os
     git -C $OVERLAYS commit -am "Cut $NEW"        # RELEASE lives here
  2. release/cut.sh record                          # BUILD-ID = the cut commit
  3. chromium/rebuild-release.sh                    # builds THIS version
  4. release/sign-on-yubikey.sh chromiumos/ota-release/$NEW
  5. release/publish.sh + release/publish-dlc-images.sh
  6. release/tag.sh $NEW                            # tag every repo
EOF
