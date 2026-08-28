#!/bin/bash
# Publish the per-language USB images as a GitHub release.
#
#   release/publish-usb-images.sh <version> [--draft]
#   release/publish-usb-images.sh 2026.32.11
#
# This is the download people actually flash. It is separate from
# release/publish.sh, which uploads the signed OTA payload to R2 for devices
# that are already installed -- different artifact, different audience, and a
# release can legitimately have one without the other.
#
# What it does:
#   1. Finds colorburst-<version>-{en,vi}.zip beside the built release image.
#   2. Refuses to upload an image whose OEM partition carries no manifest, or
#      whose partition 8 is not Microsoft basic data -- an unrepacked image
#      would boot in the wrong language and be invisible in Windows Explorer.
#   3. Records name/sha256/size for each into releases/<version>/RELEASE.json,
#      merging rather than replacing, exactly as release/tag.sh does.
#   4. Creates (or updates) the GitHub release and uploads the zips plus a
#      SHA256SUMS file.
#
# --draft leaves the release unpublished so you can look before it is public.
set -euo pipefail
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVENV"

REPO="${REPO:-colorburst-os/colorburst}"
BOARD="${BOARD:-colorburst}"
VER="${1:?usage: $0 <version> [--draft]}"
DRAFT=""
[ "${2:-}" = "--draft" ] && DRAFT="--draft"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated" >&2; exit 1; }

IMGDIR="$(ls -d chromiumos/src/build/images/${BOARD}/*/ 2>/dev/null |
          xargs -I{} sh -c 'ls {}colorburst-'"${VER}"'-en.zip >/dev/null 2>&1 && echo {}' | head -1)"
[ -n "$IMGDIR" ] || {
    echo "no colorburst-${VER}-en.zip under chromiumos/src/build/images/${BOARD}/" >&2
    echo "Build the release, then run release/make-variant.sh for each variant." >&2
    exit 1
}
echo ">>> images in ${IMGDIR}"

# --- collect the variants -----------------------------------------------------
ZIPS=()
for v in en vi; do
    z="${IMGDIR}colorburst-${VER}-${v}.zip"
    [ -f "$z" ] || { echo "missing $z" >&2; exit 1; }
    ZIPS+=("$z")
done

# --- refuse to ship an unrepacked image ---------------------------------------
# make-variant.sh writes the manifest AND stamps the Windows partition type. An
# image missing either is one that was never repacked: it would boot in whatever
# language Chrome defaults to, and Explorer would not show the partition. Both
# failures are silent on the device, so they get caught here instead.
for v in en vi; do
    bin="${IMGDIR}colorburst-${VER}-${v}.bin"
    if [ ! -f "$bin" ]; then
        echo "!! ${v}: no .bin beside the zip; cannot verify the variant" >&2
        exit 1
    fi
    out="$(release/make-variant.sh --show "$bin" 2>&1)" || {
        echo "!! ${v}: make-variant.sh --show failed" >&2; exit 1; }
    echo "$out" | grep -q '"initial_locale"' || {
        echo "!! ${v}: no startup manifest on the OEM partition -- not repacked" >&2
        echo "$out" | sed 's/^/     /' >&2; exit 1; }
    echo "$out" | grep -q 'Microsoft basic data' || {
        echo "!! ${v}: partition 8 is not Microsoft basic data" >&2; exit 1; }
    printf '>>> %s: %s\n' "$v" "$(echo "$out" | grep '"initial_locale"' | tr -s ' ')"
done

# --- checksums ----------------------------------------------------------------
SUMS="${IMGDIR}SHA256SUMS-${VER}"
( cd "$IMGDIR" && sha256sum "colorburst-${VER}-en.zip" "colorburst-${VER}-vi.zip" ) > "$SUMS"
echo ">>> checksums"; sed 's/^/    /' "$SUMS"

# --- record them in RELEASE.json ---------------------------------------------
REC="releases/${VER}/RELEASE.json"
if [ -f "$REC" ]; then
    python3 - "$REC" "${ZIPS[@]}" <<'PY'
import hashlib, json, os, sys
rec_path, *zips = sys.argv[1:]
rec = json.load(open(rec_path))
art = rec.setdefault("artifacts", {})
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
# Merge, never replace -- the record already carries the image and payload
# hashes written by release/tag.sh.
usb = art.setdefault("usb_images", {})
for z in zips:
    variant = os.path.basename(z).rsplit("-", 1)[1].removesuffix(".zip")
    usb.setdefault(variant, {}).update(
        {"name": os.path.basename(z), "sha256": sha256(z),
         "size": os.path.getsize(z)})
    print("    %-3s %s..." % (variant, usb[variant]["sha256"][:16]))
json.dump(rec, open(rec_path, "w"), indent=2)
PY
    echo ">>> recorded in $REC"
else
    echo "!! $REC does not exist -- not recording (run release/cut.sh record)" >&2
fi

# --- create or update the GitHub release --------------------------------------
TAG="v${VER}"
NOTES="$(mktemp)"; trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
Two images, one build. They differ only by the OEM customization manifest that
sets the device's language, timezone and keyboard.

| file | language |
|---|---|
| \`colorburst-${VER}-en.zip\` | English |
| \`colorburst-${VER}-vi.zip\` | Tiếng Việt |

Write either to a USB stick of 16 GB or more with
[balenaEtcher](https://etcher.balena.io/), which takes the \`.zip\` directly, or
on Linux \`unzip\` then \`dd\`. Booting from the stick does not touch the
machine's disk; installing erases the disk you choose.

Verify your download against \`SHA256SUMS-${VER}\`.

See the [README](https://github.com/${REPO}#readme) for the full instructions,
including turning off Secure Boot.
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo ">>> release $TAG exists -- uploading assets (clobbering same-named)"
    gh release upload "$TAG" "${ZIPS[@]}" "$SUMS" --repo "$REPO" --clobber
else
    echo ">>> creating release $TAG"
    gh release create "$TAG" "${ZIPS[@]}" "$SUMS" \
        --repo "$REPO" --title "colorburst ${VER}" --notes-file "$NOTES" $DRAFT
fi

echo
echo ">>> published:"
gh release view "$TAG" --repo "$REPO" \
    --json url,isDraft,assets \
    --jq '"    " + .url + (if .isDraft then "  (DRAFT)" else "" end),
          (.assets[] | "    " + .name + "  " + (.size/1048576|floor|tostring) + " MB")'
