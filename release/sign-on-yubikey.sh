#!/bin/bash
# Sign a release payload with the YubiKey (PIV slot 9C) and produce the
# final signed payload + metadata json. RUN THIS YOURSELF -- it prompts
# for the PIV PIN and needs a physical touch per signature (two total:
# payload hash, then metadata hash).
#
#   release/sign-on-yubikey.sh chromiumos/ota-release/<version>
#
# Needs: opensc (pkcs11-tool). If missing:  sudo apt install opensc
#
# Signature format (update_engine payload_signer.cc SignHash /
# payload_verifier.cc PadRSASHA256Hash): a standard RSASSA-PKCS1-v1_5
# signature over the SHA-256 digest -- i.e. PKCS#1 v1.5 padding of
# DigestInfo(SHA-256) || 32-byte-hash. pkcs11-tool's CKM_RSA_PKCS
# mechanism applies exactly that padding to its input, so we feed it
# DigestInfo||hash. This matches what Google's remote signer does
# (sign_official_build.sh sign_update_payload: openssl pkeyutl
# -pkeyopt rsa_padding_mode:pkcs1 -pkeyopt digest:sha256).
set -eu
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVENV"

WORK="${1:?usage: $0 chromiumos/ota-release/<version>}"
WORK="${WORK%/}"
[ -f "$WORK/payload_hash.bin" ] && [ -f "$WORK/metadata_hash.bin" ] || {
    echo "$WORK does not look like a gen-payload.sh work dir" >&2; exit 1
}
PUBKEY="${PUBKEY:-$DEVENV/release/keys/update-payload-key.pub.pem}"
PAYLOAD="$(ls "$WORK"/colorburst-*-full.bin | head -1)"
VER="$(basename "$PAYLOAD" | sed 's/^colorburst-\(.*\)-full\.bin$/\1/')"
SIGNED="${PAYLOAD%.bin}-signed.bin"

command -v pkcs11-tool >/dev/null || {
    echo "pkcs11-tool not found:  sudo apt install opensc  (optionally yubico-piv-tool)" >&2
    exit 1
}
MODULE="$(ls /usr/lib/*/opensc-pkcs11.so /usr/lib/opensc-pkcs11.so 2>/dev/null | head -1)"
[ -n "$MODULE" ] || { echo "opensc-pkcs11.so not found" >&2; exit 1; }

# PIV slot 9C is OpenSC object id 02 ("SIGN key").
KEYID=02
# The 19-byte ASN.1 DigestInfo prefix for SHA-256.
DIGESTINFO=3031300d060960864801650304020105000420

sign_hash() { # sign_hash <hash.bin> <out.sig> <label>
    local hash="$1" out="$2" label="$3" tmp
    tmp="$(mktemp)"
    { printf '%s' "$DIGESTINFO" | xxd -r -p; cat "$hash"; } > "$tmp"
    echo
    echo ">>> Signing ${label}. Enter the PIV PIN if prompted, then TOUCH the YubiKey when it blinks."
    pkcs11-tool --module "$MODULE" --login \
        --sign --mechanism RSA-PKCS --id "$KEYID" \
        --input-file "$tmp" --output-file "$out"
    rm -f "$tmp"
    # Independent check against the public key before going anywhere near
    # the payload: exactly the verification update_engine will perform.
    openssl pkeyutl -verify -pubin -inkey "$PUBKEY" \
        -pkeyopt rsa_padding_mode:pkcs1 -pkeyopt digest:sha256 \
        -in "$hash" -sigfile "$out" >/dev/null || {
        echo "signature over ${label} does NOT verify with ${PUBKEY} -- wrong key on the token?" >&2
        exit 1
    }
    echo "${label} signature verified against $(basename "$PUBKEY")"
}

sign_hash "$WORK/payload_hash.bin"  "$WORK/payload_hash.sig"  "the payload hash"
sign_hash "$WORK/metadata_hash.bin" "$WORK/metadata_hash.sig" "the metadata hash"

# Reinsert the detached signatures (paygen's _InsertSignaturesIntoPayload).
CWORK="/mnt/host/source/ota-release/${VER}"
run() { ./cros-sdk.sh cros_sdk -- "$@"; }
echo; echo ">>> Inserting signatures into the payload"
run delta_generator \
    --in_file="${CWORK}/$(basename "$PAYLOAD")" \
    --signature_size=256 \
    --payload_signature_file="${CWORK}/payload_hash.sig" \
    --metadata_signature_file="${CWORK}/metadata_hash.sig" \
    --out_file="${CWORK}/$(basename "$SIGNED")"

# End-to-end verification of the finished artifact with the public key
# (delta_generator VerifySignedPayload -- same code update_engine uses).
mkdir -p chromiumos/ota-release/keys
cp "$PUBKEY" chromiumos/ota-release/keys/update-payload-key.pub.pem
echo ">>> Verifying the signed payload"
run delta_generator \
    --in_file="${CWORK}/$(basename "$SIGNED")" \
    --public_key=/mnt/host/source/ota-release/keys/update-payload-key.pub.pem

# Regenerate the metadata json for the SIGNED payload: properties from
# delta_generator, plus appid/target_version the way paygen fills them in.
run delta_generator \
    --in_file="${CWORK}/$(basename "$SIGNED")" \
    --properties_file="${CWORK}/properties.json" \
    --properties_format=json
python3 - "$WORK" "$VER" "$(basename "$SIGNED")" <<'EOF'
import json, sys
work, ver, name = sys.argv[1:4]
props = json.load(open(f"{work}/properties.json"))
old = json.load(open(f"{work}/{name.replace('-signed.bin', '.bin')}.json"))
props["appid"] = old.get("appid") or "{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"
props["target_version"] = ver
if not props.get("metadata_signature"):
    sys.exit("signed payload has no metadata_signature -- refusing")
json.dump(props, open(f"{work}/{name}.json", "w"), indent=1, sort_keys=True)
print(f"wrote {work}/{name}.json")
EOF

echo
echo "=== SUCCESS: $WORK/$(basename "$SIGNED") is signed and verified ==="
echo "Next:  release/publish.sh $WORK"
