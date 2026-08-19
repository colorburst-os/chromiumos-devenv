#!/bin/bash
# OTA-TEST image: a test image that behaves like a RELEASE image toward
# update_engine, used to verify end-to-end OTA against the live server in a
# VM. See release/verify-vm-update.sh for the harness that consumes it.
#
#   chromium/build-ota-test-image.sh [minor]     # default: RELEASE-MINOR
#
# What it shares with a real release image (chromium/build-release.sh):
#   - CHROMEOS_AUSERVER baked as https://update.colorburst.net/update and
#     CHROMEOS_RELEASE_VERSION = <year>.<week/4*4>.<minor>, via the same
#     chromeos_version.sh rewrite. The wire behavior of update_engine
#     (server, appid, reported version) is identical.
#   - The payload public key at /usr/share/update_engine/
#     update-payload-key.pub.pem (the BSP installs it unconditionally).
#   - rootfs verification ON (no --no-enable-rootfs-verification).
#
# How it deliberately differs (each difference is required to observe the
# update from the outside):
#   - `cros build-image test`, not base: sshd + test keys, so the harness
#     can drive update_engine_client and read logs. A real release image
#     has no remote access at all.
#   - No package rebuilds: whatever is in the sysroot ships. Run it right
#     after a release build for maximal fidelity.
#   - Track is testimage-channel (the test-image mod); update_engine
#     silently rewrites that to stable-channel on the wire, so the server
#     sees the same request a release device sends.
#
# The one thing an image cannot decide by itself is officialness:
# crossystem debug_build is literally "is cros_debug on the kernel command
# line", and our VMs direct-kernel-boot. Boot this image WITHOUT cros_debug
# (CROS_VM_OFFICIAL=1 ./run-crosvm.sh ...) and update_engine runs in
# official mode: periodic checks on, payload signature verification
# mandatory against the baked pubkey.
set -eu
export BOARD="${BOARD:-colorburst}"
. "$(dirname "$0")/common.sh"

AUSERVER='https://update.colorburst.net/update'

MINOR="${1:-$(cat "$DEVENV/chromiumos/src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files/RELEASE-MINOR")}"
WEEK=$(( 10#$(date +%V) / 4 * 4 ))
YEAR=$(date +%G)
REL="${YEAR}.${WEEK}.${MINOR}"

VERSION_FILE="$DEVENV/chromiumos/src/third_party/chromiumos-overlay/chromeos/config/chromeos_version.sh"
cp "$VERSION_FILE" "$VERSION_FILE.dev-backup"
restore_version() { mv -f "$VERSION_FILE.dev-backup" "$VERSION_FILE"; }
trap restore_version EXIT
sed -i \
    -e "s/^CHROMEOS_BUILD=.*/CHROMEOS_BUILD=${YEAR}/" \
    -e "s/^CHROMEOS_BRANCH=.*/CHROMEOS_BRANCH=${WEEK}/" \
    -e "s/^CHROMEOS_PATCH=.*/CHROMEOS_PATCH=${MINOR}/" \
    "$VERSION_FILE"
echo "OTA-test image version: ${REL}"

in_container chromium-build-ota-test "
set -x
date -Is
cd ~/chromiumos

cros_sdk --chrome-root=/chromium -- env \
  CHROMEOS_VERSION_AUSERVER='${AUSERVER}' \
  CHROMEOS_VERSION_DEVSERVER='https://devserver.colorburst.net' \
  CHROMEOS_VERSION_TRACK=stable-channel \
  cros build-image --board=${BOARD} test
[ \$? -eq 0 ] || exit 1

IMGDIR=\$(readlink -f src/build/images/${BOARD}/latest)
ln -f \"\$IMGDIR/chromiumos_test_image.bin\" \"\$IMGDIR/colorburst-${REL}-ota-test.bin\"
echo \"OTA-TEST ${REL}: \$IMGDIR/colorburst-${REL}-ota-test.bin\"
date -Is
"

# --- verification: the bits update_engine will read -------------------
IMGDIR=$(readlink -f "$DEVENV/chromiumos/src/build/images/${BOARD}/latest")
IMG="$IMGDIR/colorburst-${REL}-ota-test.bin"
echo; echo "=== verifying $IMG ==="
OFF=$(( $(sfdisk -J "$IMG" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print([p["start"] for p in d["partitiontable"]["partitions"] if p["node"].endswith("3")][0])') * 512 ))
dbg() { debugfs -c -R "cat $1" "$IMG?offset=$OFF" 2>/dev/null; }
set +e
fail=0
check() { if [ "$2" = 0 ]; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }
LSB=$(dbg /etc/lsb-release); echo "$LSB" | sed 's/^/    /'
echo "$LSB" | grep -q "CHROMEOS_AUSERVER=${AUSERVER}"; check "AUSERVER baked" $?
echo "$LSB" | grep -q "CHROMEOS_RELEASE_VERSION=${REL}"; check "RELEASE_VERSION=${REL}" $?
echo "$LSB" | grep -q "CHROMEOS_RELEASE_APPID={3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"; check "appid" $?
dbg /usr/share/update_engine/update-payload-key.pub.pem | grep -q "BEGIN PUBLIC KEY"
check "payload pubkey present" $?
[ "$fail" = 0 ] && echo "=== OTA-test image verified ===" || { echo "=== VERIFICATION FAILED ==="; exit 1; }
