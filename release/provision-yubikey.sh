#!/bin/bash
# Provision a (freshly reset) YubiKey as an update-payload signing token:
# import the RSA-2048 payload key from the encrypted backup into PIV slot 9C
# (pin-policy=once, touch-policy=CACHED -- one tap covers back-to-back
# signatures for 15 s, the firmware maximum; key #1 uses ALWAYS), secure the PIV applet, and prove the card
# signs correctly. RUN THIS YOURSELF -- it asks for the backup passphrase and
# the new PIN/PUK, and needs a touch at the end.
#
#   release/provision-yubikey.sh [~/colorburst-update-key.pem.enc]
#
# Precondition: PIV applet at factory defaults (`ykman piv reset`). Only the
# PIV applet is touched; OTP/OpenPGP/OATH on the stick are left alone.
# Needs: ykman, openssl, opensc (pkcs11-tool).
set -eu
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENC="${1:-$HOME/colorburst-update-key.pem.enc}"
PUBKEY="$DEVENV/release/keys/update-payload-key.pub.pem"
CERT="$DEVENV/release/keys/update-signing-cert-9c.pem"
DEFAULT_MGMT=010203040506070801020304050607080102030405060708

for f in "$ENC" "$PUBKEY" "$CERT"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
for t in ykman openssl pkcs11-tool; do command -v $t >/dev/null || { echo "$t not found" >&2; exit 1; }; done

echo ">>> Token:"; ykman info | sed -n '1,3p'
ykman piv info | grep -q 'CHUID: *No data' || {
    echo "PIV applet is not at factory state -- run 'ykman piv reset' first" >&2; exit 1; }

# Plaintext only ever lives in tmpfs and is shredded on exit.
TMP="$(mktemp -d -p /dev/shm)"; chmod 700 "$TMP"
cleanup() { shred -u "$TMP"/* 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
KEY="$TMP/key.pem"

echo; echo ">>> Decrypting backup $ENC (aes-256-cbc, pbkdf2, 600000 iterations)"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$ENC" -out "$KEY"
grep -q 'BEGIN.*PRIVATE KEY' "$KEY" || { echo "decrypted data is not a PEM key -- wrong passphrase?" >&2; exit 1; }

# The backup must be THE published key before it goes anywhere near the card.
if ! cmp -s <(openssl pkey -in "$KEY" -pubout) "$PUBKEY"; then
    echo "decrypted key does NOT match $PUBKEY -- refusing to import" >&2; exit 1
fi
echo "backup matches the published public key"

echo; echo ">>> Importing into slot 9C (pin-policy=once, touch-policy=cached: one touch covers 15 s of signatures)"
ykman piv keys import -m "$DEFAULT_MGMT" \
    --pin-policy ONCE --touch-policy CACHED 9c "$KEY"
ykman piv certificates import -m "$DEFAULT_MGMT" 9c "$CERT"
shred -u "$KEY"

# Independent proof the card holds the right key, read back from the card.
ykman piv keys export 9c "$TMP/card.pub.pem"
cmp -s "$TMP/card.pub.pem" "$PUBKEY" \
    || { echo "key read back from slot 9C != $PUBKEY" >&2; exit 1; }
echo "slot 9C public key == $(basename "$PUBKEY")"

echo; echo ">>> Securing the PIV applet: new PIN (6-8 chars), new PUK (8 chars)."
echo "    Write the PUK on paper and keep it with the off-host backup copy."
ykman piv access change-pin -P 123456
ykman piv access change-puk -p 12345678
# Random management key, stored on-card behind the PIN (same as key #1) so
# there is nothing extra to keep; a PIN is all that admin ops need.
ykman piv access change-management-key -m "$DEFAULT_MGMT" --generate --protect
ykman piv info

echo; echo ">>> Test signature through the same pkcs11 path sign-on-yubikey.sh uses."
echo "    Enter the NEW PIN, then TOUCH the key when it blinks."
MODULE="$(ls /usr/lib/*/opensc-pkcs11.so /usr/lib/opensc-pkcs11.so 2>/dev/null | head -1)"
head -c 32 /dev/urandom > "$TMP/hash.bin"
{ printf '%s' 3031300d060960864801650304020105000420 | xxd -r -p; cat "$TMP/hash.bin"; } > "$TMP/digestinfo.bin"
pkcs11-tool --module "$MODULE" --login --sign --mechanism RSA-PKCS --id 02 \
    --input-file "$TMP/digestinfo.bin" --output-file "$TMP/hash.sig"
openssl pkeyutl -verify -pubin -inkey "$PUBKEY" \
    -pkeyopt rsa_padding_mode:pkcs1 -pkeyopt digest:sha256 \
    -in "$TMP/hash.bin" -sigfile "$TMP/hash.sig"

echo; echo "=== SUCCESS: YubiKey serial $(ykman info | awk '/Serial/{print $3}') slot 9C signs as $(basename "$PUBKEY") ==="
echo "Store this key in a SECOND location; sign-on-yubikey.sh works with either token."
