#!/bin/bash
# Generate the (unsigned) OTA payload for the current release image and
# extract the payload + metadata hashes for out-of-band signing.
#
#   release/gen-payload.sh [path-to-release-image.bin]
#
# Output: chromiumos/ota-release/<version>/ containing
#   colorburst-<version>-full.bin        unsigned payload
#   colorburst-<version>-full.bin.json   metadata as emitted by paygen
#   payload_hash.bin, metadata_hash.bin  raw 32-byte SHA-256 hashes
#   INSTRUCTIONS.txt                     what to do next
#
# Next step: release/sign-on-yubikey.sh <that dir>   (needs the YubiKey).
#
# The flow mirrors chromite's paygen exactly (paygen_payload_lib.py):
# an unsigned payload is generated, then delta_generator recomputes the
# hashes as-if a 256-byte signature will be appended
# (--signature_size=256); the detached signatures are later reinserted
# with --payload_signature_file/--metadata_signature_file. Measured on
# this host: ~70 s and ~645 MiB for a full payload.
set -eu
export BOARD="${BOARD:-colorburst}"
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVENV"

# Which image: argument, or the newest colorburst-*-release.bin under latest/.
if [ $# -ge 1 ]; then
    IMG_HOST="$(readlink -f "$1")"
else
    IMGDIR="$(readlink -f "chromiumos/src/build/images/${BOARD}/latest")"
    IMG_HOST="$(ls "$IMGDIR"/colorburst-*-release.bin 2>/dev/null | head -1)"
fi
[ -n "${IMG_HOST:-}" ] && [ -f "$IMG_HOST" ] || {
    echo "no release image found -- run chromium/build-release.sh first" >&2
    exit 1
}

# Version = the image's own idea of it (from the file name, matching
# CHROMEOS_RELEASE_VERSION -- build-release.sh guarantees they agree).
VER="$(basename "$IMG_HOST" | sed 's/^colorburst-\(.*\)-release\.bin$/\1/')"
PAYLOAD="colorburst-${VER}-full.bin"

OUT_HOST="chromiumos/ota-release/${VER}"
mkdir -p "$OUT_HOST"

# Chroot-side paths. The image lives under src/build/images (inside the
# checkout, so visible in the chroot); ota-release/ likewise.
IMG_CHROOT="/mnt/host/source/${IMG_HOST#"$DEVENV"/chromiumos/}"
OUT="/mnt/host/source/ota-release/${VER}"

run() { ./cros-sdk.sh cros_sdk -- "$@"; }

echo "== payload for ${VER} from ${IMG_HOST}"
# Quirk: on success cros_generate_update_payload's main() returns the list
# of generated paths, which chromite hands to sys.exit() -- printing the
# list and exiting 1. Success is therefore judged by the artifacts below,
# not the exit code.
run cros_generate_update_payload \
    --tgt-image "$IMG_CHROOT" \
    --output "${OUT}/${PAYLOAD}" \
    --work-dir "${OUT}/work" || true
[ -s "${OUT_HOST}/${PAYLOAD}" ] && [ -s "${OUT_HOST}/${PAYLOAD}.json" ] || {
    echo "payload generation failed -- no ${PAYLOAD}(.json)" >&2; exit 1
}

echo "== hashes for out-of-band signing (RSA-2048 -> --signature_size=256)"
run delta_generator \
    --in_file="${OUT}/${PAYLOAD}" \
    --signature_size=256 \
    --out_hash_file="${OUT}/payload_hash.bin" \
    --out_metadata_hash_file="${OUT}/metadata_hash.bin"

rm -rf "${OUT_HOST}/work"

for f in "${OUT_HOST}/${PAYLOAD}" "${OUT_HOST}/${PAYLOAD}.json" \
         "${OUT_HOST}/payload_hash.bin" "${OUT_HOST}/metadata_hash.bin"; do
    [ -s "$f" ] || { echo "missing expected output $f" >&2; exit 1; }
done

cat > "${OUT_HOST}/INSTRUCTIONS.txt" <<EOF
colorburst release ${VER} -- unsigned payload, ready for signing.

  payload:        ${PAYLOAD} ($(stat -c%s "${OUT_HOST}/${PAYLOAD}") bytes, unsigned)
  payload hash:   payload_hash.bin  (raw SHA-256, 32 bytes)
  metadata hash:  metadata_hash.bin (raw SHA-256, 32 bytes)

Next (requires the signing YubiKey, its PIN, and two touches):

  release/sign-on-yubikey.sh chromiumos/ota-release/${VER}

That signs both hashes in PIV slot 9C, reinserts the signatures with
delta_generator, verifies the signed payload against
internal-knowledge/keys/update-payload-key.pub.pem, and writes
${PAYLOAD%.bin}-signed.bin + .json. Then release/publish.sh uploads it.
EOF
echo; cat "${OUT_HOST}/INSTRUCTIONS.txt"
echo "== done: ${OUT_HOST}"
