#!/bin/bash
# Publish the signed Crostini DLC payloads: upload each to R2 and MERGE a
# `dlcs` section into the live releases.json WITHOUT disturbing the OS tracks.
#
#   release/publish-dlcs.sh chromiumos/ota-release/<os-version> [dlc_id ...]
#
# Layout in the colorburst-updates bucket:
#   dlcs/<dlc_id>/<version>/<payload>-signed.bin   the signed DLC payload
#   releases.json                                  gains a top-level "dlcs" key
#
# The worker serves dlcs[<dlc_id>] for an incoming app appid
# {OS_APPID}_<dlc_id>. This script:
#   1. GETs the current releases.json (so the OS "stable"/channel tracks are
#      preserved -- we only add/replace the "dlcs" key),
#   2. uploads every signed DLC payload,
#   3. PUTs the merged releases.json back,
#   4. asks the live server as a device installing each DLC and checks the
#      response points at the freshly-uploaded payload.
#
# Both the payloads and releases.json go up via R2's S3 API (curl --aws-sigv4),
# same as publish.sh's payload path -- the wrangler build here rejects
# `r2 object put --file`, so S3 is the reliable route for every object.
# Run only for payloads that sign-dlc-on-yubikey.sh verified.
set -eu
DEVENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_APPID="{3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"
BUCKET=colorburst-updates
OMAHA=https://update.colorburst.net/update
cd "$DEVENV"

BASE="${1:?usage: $0 chromiumos/ota-release/<os-version> [dlc_id ...]}"
BASE="${BASE%/}"
[ -d "$BASE/dlc" ] || { echo "$BASE has no dlc/ dir" >&2; exit 1; }
shift || true
DLC_IDS=("$@")
if [ ${#DLC_IDS[@]} -eq 0 ]; then
    DLC_IDS=()
    for d in "$BASE"/dlc/*/; do [ -d "$d" ] && DLC_IDS+=("$(basename "$d")"); done
fi

# R2 S3 credentials from the account API token (never printed). access key =
# the token id from /tokens/verify; secret = sha256 of the token value.
CF_TOKEN="$(sed -n 's/^api_token://p' ~/.cloudflare/token)"
CF_ACCT="$(sed -n 's/^account_id://p' ~/.cloudflare/token)"
[ -n "$CF_TOKEN" ] || { echo "no api_token in ~/.cloudflare/token" >&2; exit 1; }
CF_KEYID="$(curl -s -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCT}/tokens/verify" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
CF_SECRET="$(printf %s "${CF_TOKEN}" | sha256sum | cut -d' ' -f1)"
S3="https://${CF_ACCT}.r2.cloudflarestorage.com/${BUCKET}"
s3_put() { # s3_put <local-file> <key> <content-type>
    local code
    code="$(curl -s -X PUT --aws-sigv4 "aws:amz:auto:s3" --user "${CF_KEYID}:${CF_SECRET}" \
        -H "Content-Type: $3" --upload-file "$1" -o /dev/null -w '%{http_code}' "${S3}/$2")"
    [ "$code" = 200 ] || { echo "S3 PUT $2 failed: http ${code}" >&2; exit 1; }
}
s3_get() { # s3_get <key> -> stdout (empty on 404)
    curl -s --aws-sigv4 "aws:amz:auto:s3" --user "${CF_KEYID}:${CF_SECRET}" "${S3}/$1"
}

# --- fetch current releases.json so we only touch the dlcs key -------------
CUR="$(mktemp)"; s3_get releases.json > "$CUR"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$CUR" 2>/dev/null || {
    echo "current releases.json is missing/invalid -- refusing to overwrite" >&2
    echo "(publish the OS release first, or seed releases.json)" >&2; exit 1; }

# --- build each dlcs entry from its SIGNED payload's metadata ---------------
MERGED="$BASE/releases.json"
cp "$CUR" "$MERGED"
for id in "${DLC_IDS[@]}"; do
    WORK="$BASE/dlc/$id"
    SIGNED="$(ls "$WORK"/${id}-*-full-signed.bin 2>/dev/null | head -1)"
    [ -n "$SIGNED" ] && [ -f "$SIGNED.json" ] || {
        echo "$WORK has no signed payload (+.json) -- run sign-dlc-on-yubikey.sh" >&2; exit 1; }
    NAME="$(basename "$SIGNED")"
    VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["target_version"])' "$SIGNED.json")"
    echo ">>> uploading ${NAME} to r2://${BUCKET}/dlcs/${id}/${VER}/"
    s3_put "$(readlink -f "$SIGNED")" "dlcs/${id}/${VER}/${NAME}" application/octet-stream
    python3 - "$MERGED" "$SIGNED" "$id" "$OS_APPID" <<'EOF'
import base64, hashlib, json, sys
merged, signed, dlc_id, os_appid = sys.argv[1:5]
meta = json.load(open(signed + ".json"))
digest = hashlib.sha256(open(signed, "rb").read()).digest()
if base64.b64decode(meta["sha256_hex"]) != digest:
    sys.exit("payload sha256 does not match its .json")
if not meta.get("metadata_signature"):
    sys.exit(f"{dlc_id}: unsigned payload -- refusing to publish")
if meta.get("appid") != f"{os_appid}_{dlc_id}":
    sys.exit(f"{dlc_id}: unexpected appid {meta.get('appid')!r}")
rel = json.load(open(merged))
rel.setdefault("dlcs", {})[dlc_id] = {
    "appid": meta["appid"],
    "version": meta["target_version"],
    "payload": signed.rsplit("/", 1)[-1],
    "size": int(meta["size"]),
    "sha256_hex": digest.hex(),
    "metadata_size": int(meta["metadata_size"]),
    "metadata_signature": meta["metadata_signature"],
    "is_delta": bool(meta.get("is_delta")),
}
json.dump(rel, open(merged, "w"), indent=1)
print(f"  merged dlcs.{dlc_id} ({meta['target_version']})")
EOF
done

# --- upload the merged releases.json ---------------------------------------
echo ">>> uploading merged releases.json (OS tracks preserved, dlcs updated)"
s3_put "$(readlink -f "$MERGED")" releases.json application/json

# --- end-to-end check against the live server ------------------------------
# A device installing each DLC (version 0.0.0.0, its own <app>) must be offered
# exactly the payload we just uploaded.
for id in "${DLC_IDS[@]}"; do
    NAME="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dlcs"][sys.argv[2]]["payload"])' "$MERGED" "$id")"
    VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dlcs"][sys.argv[2]]["version"])' "$MERGED" "$id")"
    echo ">>> asking ${OMAHA} to install ${id}"
    RESP="$(curl -sS -X POST --data-binary @- "$OMAHA" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" updater="ChromeOSUpdateEngine" installsource="ondemandupdate" ismachine="1">
    <os version="Indy" platform="Chrome OS" sp="0.0.0_x86_64"></os>
    <app appid="${OS_APPID}" version="0.0.0.0" track="stable-channel" board="colorburst"></app>
    <app appid="${OS_APPID}_${id}" version="0.0.0.0" track="stable-channel" board="colorburst">
        <updatecheck></updatecheck>
    </app>
</request>
EOF
)"
    echo "$RESP" | grep -qF "dlcs/${id}/${VER}/" &&
    echo "$RESP" | grep -qF "run=\"${NAME}\"" &&
    echo "$RESP" | grep -q 'updatecheck status="ok"' || {
        echo "$RESP" | (xmllint --format - 2>/dev/null || cat)
        echo "live server did NOT offer ${id} correctly -- investigate" >&2; exit 1; }
    echo "  ok: ${id} -> dlcs/${id}/${VER}/${NAME}"
done
rm -f "$CUR"

echo
echo "=== published: DLCs [${DLC_IDS[*]}] are live on ${OMAHA} ==="
