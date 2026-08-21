#!/bin/bash
# Sign the three Crostini DLC payloads with the YubiKey (PIV slot 9C) and
# produce the final signed payloads + metadata json. RUN THIS YOURSELF -- it
# prompts for the PIV PIN and needs a physical touch per signature (two per
# DLC: payload hash, then metadata hash).
#
#   release/sign-dlc-on-yubikey.sh chromiumos/ota-release/<os-version> [dlc_id ...]
#
# This is the DLC sibling of sign-on-yubikey.sh and uses the SAME key, the SAME
# slot 9C, and the SAME RSASSA-PKCS1-v1_5(SHA-256) signature format -- a DLC
# payload is verified on-device with the same update-payload key as the OS
# payload (payload_verifier.cc has no DLC-specific path). See that script for
# the signature-format rationale.
#
# Needs: opensc (pkcs11-tool).  sudo apt install opensc
set -eu
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVENV"

BASE="${1:?usage: $0 chromiumos/ota-release/<os-version> [dlc_id ...]}"
BASE="${BASE%/}"
[ -d "$BASE/dlc" ] || { echo "$BASE has no dlc/ dir -- run gen-dlc-payloads.sh first" >&2; exit 1; }
VER="$(basename "$BASE")"
shift || true
DLC_IDS=("$@")
if [ ${#DLC_IDS[@]} -eq 0 ]; then
    DLC_IDS=()
    for d in "$BASE"/dlc/*/; do [ -d "$d" ] && DLC_IDS+=("$(basename "$d")"); done
fi
[ ${#DLC_IDS[@]} -gt 0 ] || { echo "no DLC dirs under $BASE/dlc" >&2; exit 1; }

PUBKEY="${PUBKEY:-$DEVENV/release/keys/update-payload-key.pub.pem}"
command -v pkcs11-tool >/dev/null || {
    echo "pkcs11-tool not found:  sudo apt install opensc" >&2; exit 1; }
MODULE="$(ls /usr/lib/*/opensc-pkcs11.so /usr/lib/opensc-pkcs11.so 2>/dev/null | head -1)"
[ -n "$MODULE" ] || { echo "opensc-pkcs11.so not found" >&2; exit 1; }

# PIV slot 9C is OpenSC object id 02 ("SIGN key"); 19-byte SHA-256 DigestInfo.
KEYID=02
DIGESTINFO=3031300d060960864801650304020105000420

# Public key must be visible in the chroot for the delta_generator verify.
mkdir -p chromiumos/ota-release/keys
cp "$PUBKEY" chromiumos/ota-release/keys/update-payload-key.pub.pem
run() { ./cros-sdk.sh cros_sdk -- "$@"; }

sign_hash() { # sign_hash <hash.bin> <out.sig> <label>
    local hash="$1" out="$2" label="$3" tmp
    tmp="$(mktemp)"
    { printf '%s' "$DIGESTINFO" | xxd -r -p; cat "$hash"; } > "$tmp"
    echo
    echo ">>> Signing ${label}. TOUCH the YubiKey when it blinks (PIN already entered)."
    pkcs11-tool --module "$MODULE" --login "${PIN_ARGS[@]}" \
        --sign --mechanism RSA-PKCS --id "$KEYID" \
        --input-file "$tmp" --output-file "$out"
    rm -f "$tmp"
    openssl pkeyutl -verify -pubin -inkey "$PUBKEY" \
        -pkeyopt rsa_padding_mode:pkcs1 -pkeyopt digest:sha256 \
        -in "$hash" -sigfile "$out" >/dev/null || {
        echo "signature over ${label} does NOT verify with $(basename "$PUBKEY") -- wrong key?" >&2
        exit 1; }
    echo "${label} signature verified against $(basename "$PUBKEY")"
}

# Ask for the PIV PIN ONCE and reuse it for every signature this run. Each
# slot-9C sign does a CKU_USER login AND a CKA_ALWAYS_AUTHENTICATE per-signature
# re-auth (two prompts), times two hashes per DLC -- so without this the
# maintainer would retype the PIN 2*2*<#dlcs> times. --pin feeds both the login
# and the context-specific re-auth non-interactively (OpenSC >= 0.21 reuses it).
# The PIN is only ever handed to the local pkcs11-tool and never leaves this
# machine. Set PIV_PIN in the environment to skip the prompt entirely.
# NOTE: the physical TOUCH is a hardware gesture and cannot be consolidated in
# software; with touch-policy=cached one touch covers a ~15s window, so
# back-to-back signatures share a touch.
PIN_ARGS=()
if [ -n "${PIV_PIN:-}" ]; then
    PIN_ARGS=(--pin "$PIV_PIN")
else
    read -rsp "PIV PIN (typed once for all $(( ${#DLC_IDS[@]} * 2 )) signatures this run): " _pin; echo
    [ -n "$_pin" ] && PIN_ARGS=(--pin "$_pin")
fi

for id in "${DLC_IDS[@]}"; do
    WORK="$BASE/dlc/$id"
    [ -f "$WORK/payload_hash.bin" ] && [ -f "$WORK/metadata_hash.bin" ] || {
        echo "$WORK is not a gen-dlc-payloads.sh dir" >&2; exit 1; }
    PAYLOAD="$(ls "$WORK"/${id}-*-full.bin 2>/dev/null | head -1)"
    [ -n "$PAYLOAD" ] || { echo "no unsigned payload in $WORK" >&2; exit 1; }
    NAME="$(basename "$PAYLOAD")"
    SIGNED_NAME="${NAME%.bin}-signed.bin"
    CWORK="/mnt/host/source/ota-release/${VER}/dlc/${id}"

    echo; echo "########## ${id} ##########"
    sign_hash "$WORK/payload_hash.bin"  "$WORK/payload_hash.sig"  "${id} payload hash"
    sign_hash "$WORK/metadata_hash.bin" "$WORK/metadata_hash.sig" "${id} metadata hash"

    echo ">>> Inserting signatures into ${id} payload"
    run delta_generator \
        --in_file="${CWORK}/${NAME}" \
        --signature_size=256 \
        --payload_signature_file="${CWORK}/payload_hash.sig" \
        --metadata_signature_file="${CWORK}/metadata_hash.sig" \
        --out_file="${CWORK}/${SIGNED_NAME}"

    echo ">>> Verifying signed ${id} payload against the public key"
    run delta_generator \
        --in_file="${CWORK}/${SIGNED_NAME}" \
        --public_key=/mnt/host/source/ota-release/keys/update-payload-key.pub.pem

    # Metadata json for the SIGNED payload (has the reinserted metadata_size +
    # metadata_signature). appid/target_version copied from the unsigned json.
    run delta_generator \
        --in_file="${CWORK}/${SIGNED_NAME}" \
        --properties_file="${CWORK}/properties.json" \
        --properties_format=json
    python3 - "$WORK" "$NAME" "$SIGNED_NAME" <<'EOF'
import json, sys
work, name, signed_name = sys.argv[1:4]
props = json.load(open(f"{work}/properties.json"))
old = json.load(open(f"{work}/{name}.json"))
props["appid"] = old["appid"]
props["target_version"] = old["target_version"]
if not props.get("metadata_signature"):
    sys.exit(f"{signed_name} has no metadata_signature -- refusing")
json.dump(props, open(f"{work}/{signed_name}.json", "w"), indent=1, sort_keys=True)
print(f"wrote {work}/{signed_name}.json")
EOF
    echo ">>> ${id}: $WORK/${SIGNED_NAME} signed and verified"
done

echo
echo "=== SUCCESS: all DLC payloads under $BASE/dlc are signed and verified ==="
echo "Next:  release/publish-dlcs.sh $BASE"
