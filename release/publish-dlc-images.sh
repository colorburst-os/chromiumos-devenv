#!/bin/bash
# Publish Crostini's force-ota DLC images to colorburst's CDN.
#
#   release/publish-dlc-images.sh
#
# WHY THIS EXISTS
# --------------
# termina-dlc, termina-tools-dlc and edk2-ovmf-dlc are `force-ota` (and
# non-scaled) DLCs. On a release/OTA device they are NOT preloaded and NOT
# factory-installed, so dlcservice asks update_engine to fetch them, and
# update_engine's InstallAction fetches the raw `dlc.img` over HTTPS from a
# HARDCODED CDN -- it does NOT go through our Omaha server at all. Stock
# ChromeOS hardcodes Google's CDN (edgedl.me.gvt1.com / dl.google.com); a
# colorburst-only DLC like edk2-ovmf-dlc is not there, so it 404s and Crostini
# install dies right after termina.
#
# The fix (platform2-patches/update-engine-dlc-url-0001.patch) redirects those
# constants to https://dl.colorburst.net/dlc . The exact object URL InstallAction
# requests for a force-ota DLC is (confirmed empirically from update_engine.log):
#
#     https://dl.colorburst.net/dlc / <builder_path> / <slotting> / <id> / package / dlc.img
#                                     (empty)          (= "dlc")
#   = https://dl.colorburst.net/dlc/dlc/<id>/package/dlc.img
#
#   builder_path : CHROMEOS_RELEASE_BUILDER_PATH, empty on colorburst.
#   slotting     : "dlc" for force-ota (kForceOTASlotting), "dlc-scaled" otherwise.
#
# So we host each dlc.img at the R2 key `dlc/dlc/<id>/package/dlc.img` in the
# colorburst-updates bucket, which dl.colorburst.net serves directly (bucket
# custom domain, no path rewrite -- same as payloads/).
#
# NO SIGNING. InstallAction verifies the downloaded bytes against the on-device
# imageloader manifest `image-sha256-hash` (see install_action.cc
# OnTransferComplete), not against a payload signature. So the object we host
# must be the EXACT dlc.img whose sha256 is in the manifest baked into the OS
# image the device runs. This script reads both from the same board sysroot and
# refuses to upload on any mismatch.
#
# SHARP EDGE -- the CDN path has NO version component (builder_path is empty).
# Every OS version fetches the same URL. That is safe only while the DLC content
# is unchanged across the OS versions in the field: if a future release ships a
# different dlc.img (new hash in its manifest), overwriting the R2 object would
# break DLC install for devices still on the older OS (their manifest expects the
# old hash). termina/edk2 change rarely, so re-run this whenever the DLC content
# changes and roll all channels forward together. The durable fix, if we ever
# ship diverging DLC content per channel, is to set CHROMEOS_RELEASE_BUILDER_PATH
# so the URL carries the version and host per-version.
#
# Credentials: R2 S3 API, from ~/.cloudflare/token (never printed). Same scheme
# as release/publish.sh / publish-dlcs.sh.
set -euo pipefail

BOARD="${BOARD:-colorburst}"
BUCKET=colorburst-updates
DLC_IDS=(termina-dlc termina-tools-dlc edk2-ovmf-dlc)

DEVENV="$(cd "$(dirname "$0")/.." && pwd)"
DLCROOT="$DEVENV/chromiumos/out/build/${BOARD}/build/rootfs/dlc"
[ -d "$DLCROOT" ] || { echo "no DLC sysroot at $DLCROOT -- build the board first" >&2; exit 1; }

CF_TOKEN="$(sed -n 's/^api_token://p' ~/.cloudflare/token)"
CF_ACCT="$(sed -n 's/^account_id://p' ~/.cloudflare/token)"
[ -n "$CF_TOKEN" ] && [ -n "$CF_ACCT" ] || { echo "missing api_token/account_id in ~/.cloudflare/token" >&2; exit 1; }
CF_KEYID="$(curl -s -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCT}/tokens/verify" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
CF_SECRET="$(printf %s "${CF_TOKEN}" | sha256sum | cut -d' ' -f1)"
S3="https://${CF_ACCT}.r2.cloudflarestorage.com/${BUCKET}"

s3_put() { # s3_put <local-file> <key>
    local code
    code="$(curl -s -X PUT --aws-sigv4 "aws:amz:auto:s3" --user "${CF_KEYID}:${CF_SECRET}" \
        -H "Content-Type: application/octet-stream" --upload-file "$1" \
        -o /dev/null -w '%{http_code}' "${S3}/$2")"
    [ "$code" = 200 ] || { echo "S3 PUT $2 failed: http ${code}" >&2; exit 1; }
}

for id in "${DLC_IDS[@]}"; do
    img="$DLCROOT/$id/package/dlc.img"
    man="$DLCROOT/$id/package/meta/imageloader.json"
    [ -f "$img" ] && [ -f "$man" ] || { echo "$id: missing dlc.img or imageloader.json under $DLCROOT" >&2; exit 1; }
    want="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["image-sha256-hash"])' "$man")"
    got="$(sha256sum "$img" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || { echo "$id: HASH MISMATCH -- img=$got manifest=$want (refusing)" >&2; exit 1; }
    key="dlc/dlc/${id}/package/dlc.img"
    echo ">>> $id  sha256=$got  size=$(stat -c%s "$img")  ->  r2://${BUCKET}/${key}"
    s3_put "$img" "$key"
done

echo
echo "Uploaded. Verifying over the public custom domain (dl.colorburst.net):"
fail=0
for id in "${DLC_IDS[@]}"; do
    url="https://dl.colorburst.net/dlc/dlc/${id}/package/dlc.img"
    man="$DLCROOT/$id/package/meta/imageloader.json"
    want="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["image-sha256-hash"])' "$man")"
    code="$(curl -sI "$url" -o /dev/null -w '%{http_code}')"
    remote="$(curl -s "$url" | sha256sum | cut -d' ' -f1)"
    if [ "$code" = 200 ] && [ "$remote" = "$want" ]; then
        echo "  OK  $id  HTTP 200  sha256 matches manifest"
    else
        echo "  FAIL $id  HTTP $code  remote=$remote want=$want" >&2; fail=1
    fi
done
[ "$fail" = 0 ] || { echo "verification FAILED" >&2; exit 1; }
echo "All DLC images live and verified. No signing or worker deploy needed for these."
