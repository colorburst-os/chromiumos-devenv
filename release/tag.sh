#!/bin/bash
# Tag every repo that contributes to a release, and record the artifact hashes.
# Run AFTER the release is built, signed and published.
#
#   release/tag.sh 2026.32.9
#
# The tags are for humans -- releases/<version>/manifest.xml already pins every
# project by SHA, so a release is reconstructible without them. What tags add
# is a name you can `git checkout` in each repo you actually edit.
#
# Each tag goes on the commit RELEASE.json records, not on HEAD, so it stays
# correct however long after the build you run this.
#
# Pushing tags is left to you (they are public and permanent):
#   git push origin v<version>            # in each repo listed at the end
set -euo pipefail

export BOARD="${BOARD:-colorburst}"
. "$(dirname "$0")/../chromium/common.sh"
cd "$DEVENV"

VER="${1:?usage: $0 <version>}"
TAG="v$VER"
REC="releases/$VER/RELEASE.json"
[ -f "$REC" ] || { echo "no $REC -- run release/cut.sh first" >&2; exit 1; }

# --- record the artifact hashes now that they exist ------------------------
IMG="$(ls chromiumos/src/build/images/${BOARD}/*/colorburst-${VER}-release.bin 2>/dev/null | head -1 || true)"
PAYLOAD="chromiumos/ota-release/${VER}/colorburst-${VER}-full-signed.bin"
python3 - "$REC" "${IMG:-}" "$PAYLOAD" <<'PY'
import hashlib, json, os, sys
rec_path, img, payload = sys.argv[1:4]
rec = json.load(open(rec_path))
art = rec.setdefault("artifacts", {})

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# Merge, never replace: a record may already carry fields this script does not
# compute (is_delta, the .xz hashes of a published USB image, ...).
if img and os.path.exists(img):
    art.setdefault("image", {}).update(
        {"name": os.path.basename(img),
         "sha256": sha256(img), "size": os.path.getsize(img)})
    print(f"    image   {art['image']['sha256'][:16]}...")
if os.path.exists(payload):
    meta = json.load(open(payload + ".json")) if os.path.exists(payload + ".json") else {}
    entry = art.setdefault("ota_payload", {})
    entry.update({"name": os.path.basename(payload),
                  "sha256": sha256(payload),
                  "size": os.path.getsize(payload)})
    if meta.get("metadata_size"):
        entry["metadata_size"] = int(meta["metadata_size"])
    entry.setdefault("is_delta", bool(meta.get("is_delta", False)))
    print(f"    payload {entry['sha256'][:16]}...")
json.dump(rec, open(rec_path, "w"), indent=2)
PY

# --- tag each repo ---------------------------------------------------------
# Tag the commits RELEASE.json records, NOT HEAD. Tagging HEAD only happens to
# be right if nothing has landed since the build; once the release goes through
# a pull request, HEAD is the merge plus whatever else merged with it. 2026.32.11
# was nearly tagged that way, which would have pointed the tag at a tree that
# includes kernel-patches/ -- code the shipped image does not contain.
#
# An existing tag is checked, not trusted: if it already points somewhere else,
# say so and stop rather than moving a public tag.
tag_repo() { # tag_repo <path> <label> <sha>
    local path="$1" label="$2" sha="$3"
    [ -d "$path/.git" ] || { echo "    skip $label (not a git repo)"; return; }
    if [ -z "$sha" ] || [ "$sha" = "null" ]; then
        echo "    skip $label (no SHA in $REC)"; return
    fi
    if ! git -C "$path" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo "    !! $label: $REC names $sha, which is not in this checkout" >&2
        FAIL=1; return
    fi
    if git -C "$path" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        local at
        at="$(git -C "$path" rev-parse "$TAG^{commit}")"
        if [ "$at" = "$(git -C "$path" rev-parse "${sha}^{commit}")" ]; then
            echo "    $label already tagged $TAG (correct commit)"
        else
            echo "    !! $label: $TAG points at ${at:0:10}, record says ${sha:0:10}" >&2
            FAIL=1
        fi
        return
    fi
    git -C "$path" tag -a "$TAG" "$sha" -m "colorburst $VER"
    echo "    tagged $label $TAG -> ${sha:0:10}"
}

# The SHAs the record names for this release.
read -r SHA_DEVENV SHA_OVERLAYS SHA_CROSVM < <(python3 - "$REC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
src = d.get("source", {})
forks = src.get("forks", {})
print(src.get("chromium_os", {}).get("commit", ""),
      forks.get("board-overlays", ""),
      forks.get("crosvm", ""))
PY
)

FAIL=0
echo ">>> tagging $TAG at the commits $REC records"
tag_repo "." "chromium-os" "$SHA_DEVENV"
tag_repo "chromiumos/src/overlays" "board-overlays" "$SHA_OVERLAYS"
tag_repo "chromiumos/src/platform/crosvm" "crosvm" "$SHA_CROSVM"
[ "$FAIL" = 0 ] || { echo "!! tagging incomplete -- see above" >&2; exit 1; }

cat <<EOF

=== $TAG applied locally ===
Push them yourself when you are ready:
    git push origin $TAG
    git -C chromiumos/src/overlays push colorburst $TAG
    git -C chromiumos/src/platform/crosvm push colorburst $TAG
EOF
