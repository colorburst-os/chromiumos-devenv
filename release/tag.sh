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
tag_repo() { # tag_repo <path> <label>
    local path="$1" label="$2"
    [ -d "$path/.git" ] || { echo "    skip $label (not a git repo)"; return; }
    if git -C "$path" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "    $label already tagged $TAG"
    else
        git -C "$path" tag -a "$TAG" -m "colorburst $VER"
        echo "    tagged $label $TAG"
    fi
}

echo ">>> tagging $TAG"
tag_repo "." "chromium-os"
tag_repo "chromiumos/src/overlays" "board-overlays"
tag_repo "chromiumos/src/platform/crosvm" "crosvm"

cat <<EOF

=== $TAG applied locally ===
Push them yourself when you are ready:
    git push origin $TAG
    git -C chromiumos/src/overlays push colorburst $TAG
    git -C chromiumos/src/platform/crosvm push colorburst $TAG
EOF
