#!/bin/bash
# Generate the (unsigned) DLC update payloads for Crostini's three DLCs and
# extract each payload's + metadata hashes for out-of-band signing.
#
#   release/gen-dlc-payloads.sh [os-version] [dlc_id ...]
#
# With no args it stages all three Crostini DLCs (termina-dlc,
# termina-tools-dlc, edk2-ovmf-dlc) from the current colorburst board sysroot,
# grouped under the newest release image's OS version.
#
# Output: chromiumos/ota-release/<os-version>/dlc/<dlc_id>/ containing
#   <dlc_id>-<dlc_version>-full.bin        unsigned DLC payload
#   <dlc_id>-<dlc_version>-full.bin.json   metadata (paygen-shaped)
#   payload_hash.bin, metadata_hash.bin    raw 32-byte SHA-256 hashes
#   INSTRUCTIONS.txt                       what to do next
#
# Next: release/sign-dlc-on-yubikey.sh chromiumos/ota-release/<os-version>
#       then release/publish-dlcs.sh   (see release/DLC-RELEASE.md).
#
# Why this exists: Crostini's DLCs are NOT durable when factory-installed on
# this plain-ext4 board (they live only in stateful, aren't written by OTA,
# don't survive powerwash). The durable fix is to serve them from the Omaha
# server like any other DLC. dlcservice -> update_engine forms a composite
# appid {OS_APPID}_<dlc_id> (omaha_request_params.cc:350-353) and asks for a
# normal DLC-over-Omaha payload; this produces exactly that payload.
#
# The delta_generator invocation mirrors chromite paygen's DLC path
# (paygen_payload_lib.py:613-627, :878-911): a single partition named
# "dlc/<dlc_id>/<dlc_package>" whose new image is the whole dlc.img. Hash
# extraction / signature reinsertion are byte-identical to the OS payload
# (there is no DLC-specific delta_generator flag).
set -eu
export BOARD="${BOARD:-colorburst}"
OS_APPID="{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVENV"

# The DLC build output in the board sysroot (host side, chroot-visible as
# /build/<board>/... inside cros_sdk).
DLC_ROOT_HOST="chromiumos/out/build/${BOARD}/build/rootfs/dlc"
DLC_ROOT_CHROOT="/build/${BOARD}/build/rootfs/dlc"

# OS version to group the DLC set under. Argument 1 if it looks like a version,
# otherwise derived from the newest release image (same rule as gen-payload.sh).
VER=""
if [ $# -ge 1 ] && printf '%s' "$1" | grep -qE '^[0-9]'; then
    VER="$1"; shift
fi
if [ -z "$VER" ]; then
    IMGDIR="$(readlink -f "chromiumos/src/build/images/${BOARD}/latest" 2>/dev/null || true)"
    IMG="$(ls "$IMGDIR"/colorburst-*-release.bin 2>/dev/null | head -1 || true)"
    [ -n "$IMG" ] && VER="$(basename "$IMG" | sed 's/^colorburst-\(.*\)-release\.bin$/\1/')"
fi
[ -n "$VER" ] || { echo "could not determine OS version -- pass it as arg 1" >&2; exit 1; }

# Which DLCs: the rest of the args, or the three Crostini DLCs by default.
DLC_IDS=("$@")
[ ${#DLC_IDS[@]} -gt 0 ] || DLC_IDS=(termina-dlc termina-tools-dlc edk2-ovmf-dlc)

run() { ./cros-sdk.sh cros_sdk -- "$@"; }

echo "== DLC payloads for OS ${VER} (board ${BOARD})"
for id in "${DLC_IDS[@]}"; do
    MANIFEST="${DLC_ROOT_HOST}/${id}/package/meta/imageloader.json"
    IMG_HOST="${DLC_ROOT_HOST}/${id}/package/dlc.img"
    [ -f "$MANIFEST" ] && [ -f "$IMG_HOST" ] || {
        echo "!! ${id}: no dlc.img / imageloader.json under ${DLC_ROOT_HOST}/${id} -- build the board first" >&2
        exit 1
    }

    # dlc_id / dlc_package / dlc_version straight from the image's own manifest.
    DLC_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$MANIFEST")"
    DLC_PKG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["package"])' "$MANIFEST")"
    DLC_VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
    [ "$DLC_ID" = "$id" ] || { echo "!! manifest id ${DLC_ID} != dir ${id}" >&2; exit 1; }
    APPID="${OS_APPID}_${DLC_ID}"
    PART="dlc/${DLC_ID}/${DLC_PKG}"
    NAME="${DLC_ID}-${DLC_VER}-full.bin"

    OUT_HOST="chromiumos/ota-release/${VER}/dlc/${DLC_ID}"
    OUT_CHROOT="/mnt/host/source/ota-release/${VER}/dlc/${DLC_ID}"
    IMG_CHROOT="${DLC_ROOT_CHROOT}/${DLC_ID}/package/dlc.img"
    mkdir -p "$OUT_HOST"

    echo
    echo "== ${DLC_ID} ${DLC_VER}  (partition ${PART}, $(stat -c%s "$IMG_HOST") byte image)"

    # 1. Unsigned full payload. Single DLC partition, whole dlc.img as the new
    #    image; no old_partitions (full), no minor_version, no postinstall cfg.
    run delta_generator \
        --major_version=2 \
        --partition_names="${PART}" \
        --new_partitions="${IMG_CHROOT}" \
        --out_file="${OUT_CHROOT}/${NAME}"
    [ -s "${OUT_HOST}/${NAME}" ] || { echo "!! ${DLC_ID}: no payload produced" >&2; exit 1; }

    # 2. Hashes for out-of-band signing (RSA-2048 -> --signature_size=256).
    run delta_generator \
        --in_file="${OUT_CHROOT}/${NAME}" \
        --signature_size=256 \
        --out_hash_file="${OUT_CHROOT}/payload_hash.bin" \
        --out_metadata_hash_file="${OUT_CHROOT}/metadata_hash.bin"

    # 3. Metadata json (paygen-shaped). delta_generator can't know the appid,
    #    so inject appid + target_version the way paygen does
    #    (paygen_payload_lib.py:1166,1209). sha256_hex here is BASE64 (the
    #    nebraska b/131762584 quirk) -- publish-dlcs.sh recomputes the hex.
    run delta_generator \
        --in_file="${OUT_CHROOT}/${NAME}" \
        --properties_file="${OUT_CHROOT}/${NAME}.json" \
        --properties_format=json
    python3 - "${OUT_HOST}/${NAME}.json" "$APPID" "$DLC_VER" <<'EOF'
import json, sys
path, appid, dlc_ver = sys.argv[1:4]
props = json.load(open(path))
props["appid"] = appid
# target_version = the DLC's own imageloader version. Only cosmetic on the wire
# (dlcservice installs send 0.0.0.0; a mismatch is a LOG(WARNING) only --
# omaha_request_action.cc:655) but it is what the worker echoes as <manifest
# version> and uses in the R2 path.
props["target_version"] = dlc_ver
json.dump(props, open(path, "w"), indent=1, sort_keys=True)
EOF

    for f in "${OUT_HOST}/${NAME}" "${OUT_HOST}/${NAME}.json" \
             "${OUT_HOST}/payload_hash.bin" "${OUT_HOST}/metadata_hash.bin"; do
        [ -s "$f" ] || { echo "!! missing expected output $f" >&2; exit 1; }
    done

    cat > "${OUT_HOST}/INSTRUCTIONS.txt" <<EOF
colorburst DLC ${DLC_ID} ${DLC_VER} (for OS ${VER}) -- unsigned, ready to sign.

  appid:          ${APPID}
  partition:      ${PART}
  payload:        ${NAME} ($(stat -c%s "${OUT_HOST}/${NAME}") bytes, unsigned)
  payload hash:   payload_hash.bin  (raw SHA-256, 32 bytes)
  metadata hash:  metadata_hash.bin (raw SHA-256, 32 bytes)

Sign (needs the YubiKey; same slot-9C flow as the OS payload):

  release/sign-dlc-on-yubikey.sh chromiumos/ota-release/${VER}

Then publish (merges the dlcs section into releases.json, keeps OS tracks):

  release/publish-dlcs.sh chromiumos/ota-release/${VER}

See release/DLC-RELEASE.md for the full runbook + end-to-end verification.
EOF
    echo "   -> ${OUT_HOST}/${NAME}"
done

echo
echo "== done. Unsigned DLC payloads under chromiumos/ota-release/${VER}/dlc/"
echo "   Next: release/sign-dlc-on-yubikey.sh chromiumos/ota-release/${VER}"
