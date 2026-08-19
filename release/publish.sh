#!/bin/bash
# Publish a signed release payload: upload to R2, regenerate releases.json,
# and confirm the live update server offers the new release.
#
#   release/publish.sh chromiumos/ota-release/<version>
#
# Layout in the colorburst-updates bucket (see update-server/README.md):
#   payloads/<target_version>/<payload>.bin   the signed payload
#   releases.json                             what the worker serves from
#
# This REPLACES releases.json for the stable channel: every official-build
# device on a lower version will be offered this payload on its next
# check. Run only for a payload that sign-on-yubikey.sh verified.
set -eu
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SERVER_DIR="${UPDATE_SERVER_DIR:-$DEVENV/../update-server}"
APPID="{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"
BUCKET=colorburst-updates
OMAHA=https://update.colorburst.net/update
cd "$DEVENV"

WORK="${1:?usage: $0 chromiumos/ota-release/<version>}"
WORK="${WORK%/}"
SIGNED="$(ls "$WORK"/colorburst-*-full-signed.bin 2>/dev/null | head -1)"
[ -n "$SIGNED" ] && [ -f "$SIGNED.json" ] || {
    echo "$WORK has no signed payload (+.json) -- run sign-on-yubikey.sh first" >&2
    exit 1
}
NAME="$(basename "$SIGNED")"

# Cloudflare credentials (never printed).
export CLOUDFLARE_ACCOUNT_ID="$(sed -n 's/^account_id://p' ~/.cloudflare/token)"
export CLOUDFLARE_API_TOKEN="$(sed -n 's/^api_token://p' ~/.cloudflare/token)"
[ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "no api_token in ~/.cloudflare/token" >&2; exit 1; }
wrangler() { (cd "$UPDATE_SERVER_DIR" && npx wrangler "$@"); }

# --- build releases.json from the payload's own metadata ---------------
# sha256_hex in the paygen .json is actually BASE64 (nebraska's
# b/131762584 quirk); the worker emits hash_sha256 verbatim and
# update_engine wants hex, so compute the real hex from the file and
# cross-check it against the json's base64 value.
TARGET_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['target_version'])" "$SIGNED.json")"
python3 - "$SIGNED" "$WORK/releases.json" <<'EOF'
import base64, hashlib, json, sys
signed, out = sys.argv[1:3]
meta = json.load(open(signed + ".json"))
digest = hashlib.sha256(open(signed, "rb").read()).digest()
if base64.b64decode(meta["sha256_hex"]) != digest:
    sys.exit("payload sha256 does not match its .json (sha256_hex is base64)")
if not meta.get("metadata_signature"):
    sys.exit("unsigned payload -- refusing to publish")
if meta.get("appid") != "{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}":
    sys.exit(f"unexpected appid {meta.get('appid')!r}")
rel = {
    "stable": {
        "appid": meta["appid"],
        "target_version": meta["target_version"],
        "payload": signed.rsplit("/", 1)[-1],
        "size": int(meta["size"]),
        "sha256_hex": digest.hex(),
        "metadata_size": int(meta["metadata_size"]),
        "metadata_signature": meta["metadata_signature"],
        "is_delta": bool(meta.get("is_delta")),
    }
}
json.dump(rel, open(out, "w"), indent=1)
print(json.dumps(rel, indent=1))
EOF

# --- upload ------------------------------------------------------------
echo ">>> uploading ${NAME} to r2://${BUCKET}/payloads/${TARGET_VERSION}/"
# wrangler's API path caps uploads at ~300 MiB, and a full payload is ~700.
# Go straight to R2's S3 API using credentials derived from the account API
# token in ~/.cloudflare/token (access key = the token's id from
# /accounts/<id>/tokens/verify, secret = sha256 of the token value).
CF_TOKEN="$(sed -n 's/^api_token://p' ~/.cloudflare/token)"
CF_ACCT="$(sed -n 's/^account_id://p' ~/.cloudflare/token)"
CF_KEYID="$(curl -s -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCT}/tokens/verify" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
CF_SECRET="$(printf %s "${CF_TOKEN}" | sha256sum | cut -d' ' -f1)"
HTTP_CODE="$(curl -s -X PUT --aws-sigv4 "aws:amz:auto:s3" \
    --user "${CF_KEYID}:${CF_SECRET}" \
    --upload-file "$(readlink -f "$SIGNED")" \
    -o /dev/null -w '%{http_code}' \
    "https://${CF_ACCT}.r2.cloudflarestorage.com/${BUCKET}/payloads/${TARGET_VERSION}/${NAME}")"
[ "$HTTP_CODE" = 200 ] || { echo "S3 PUT failed: http ${HTTP_CODE}" >&2; exit 1; }

echo ">>> uploading releases.json"
wrangler r2 object put "${BUCKET}/releases.json" \
    --file "$(readlink -f "$WORK/releases.json")" --remote \
    --content-type application/json

# --- end-to-end check against the live server --------------------------
# An Omaha request from a device on a version below TARGET_VERSION must be
# offered exactly this payload.
echo ">>> asking ${OMAHA} as a device on 0.0.0"
RESP="$(curl -sS -X POST --data-binary @- "$OMAHA" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" updater="ChromeOSUpdateEngine" updaterversion="0.1.0.0" ismachine="1">
    <os version="Indy" platform="Chrome OS" sp="0.0.0_x86_64"></os>
    <app appid="${APPID}" version="0.0.0" track="stable-channel" board="colorburst" delta_okay="false">
        <updatecheck></updatecheck>
    </app>
</request>
EOF
)"
echo "$RESP" | xmllint --format - 2>/dev/null || echo "$RESP"
echo "$RESP" | grep -q 'updatecheck status="ok"' &&
echo "$RESP" | grep -qF "run=\"${NAME}\"" &&
echo "$RESP" | grep -qF "payloads/${TARGET_VERSION}" || {
    echo "live server did NOT offer ${NAME} -- investigate before announcing" >&2
    exit 1
}

# And a device already on the target version must get noupdate.
RESP2="$(curl -sS -X POST --data-binary @- "$OMAHA" <<EOF
<request protocol="3.0"><app appid="${APPID}" version="${TARGET_VERSION}" track="stable-channel" board="colorburst"><updatecheck></updatecheck></app></request>
EOF
)"
echo "$RESP2" | grep -q 'updatecheck status="noupdate"' || {
    echo "device on ${TARGET_VERSION} was not given noupdate -- check versionLess in the worker" >&2
    exit 1
}

echo
echo "=== published: ${TARGET_VERSION} (${NAME}) is live on ${OMAHA} ==="
