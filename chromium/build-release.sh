#!/bin/bash
# RELEASE image build: what ships to devices, as opposed to build-image.sh's
# dev/test loop. The differences, each load-bearing for OTA:
#
#   - `cros build-image base` (not test) WITH rootfs verification: no
#     --no-enable-rootfs-verification, so dm-verity is on and the kernel
#     cmdline carries no cros_debug. `crossystem debug_build` is literally
#     "is cros_debug on the kernel cmdline" and update_engine's
#     IsOfficialBuild() is "debug_build == 0": only dev/test images get
#     cros_debug (dev_image_util.sh/test_image_util.sh pass
#     --force_developer_mode to cros_make_image_bootable; base images never
#     do). An unofficial build blocks periodic update checks AND waives
#     payload signature verification, so this is the whole trust story.
#     NOTE: CHROMEOS_OFFICIAL=1 is NOT used -- cros_set_lsb_release's
#     --official would overwrite CHROMEOS_AUSERVER with Google's server.
#   - Debug conveniences out: the kernel loses the vtconsole/fbconsole/
#     efi_earlycon consoles and the BSP loses cb-diag.conf plus the
#     chrome_dev.conf devtools block (USE=-colorburst_devtools). Both are
#     re-merged with release USE before the image build, and restored to
#     the dev configuration afterwards so build-image.sh keeps working.
#   - CHROMEOS_AUSERVER baked as https://update.colorburst.net/update via
#     the CHROMEOS_VERSION_AUSERVER env var (base_image_util.sh:507);
#     track becomes stable-channel via CHROMEOS_VERSION_TRACK.
#   - CHROMEOS_RELEASE_VERSION = <year>.<week/4*4>.<minor> -- the same
#     colorburst release number the BSP stamps into /etc/os-release, so
#     the version update_engine reports and the image file name cannot
#     drift. Monotonic across releases: minor bumps within a 4-week
#     window, the week floors upward across windows, the year rolls the
#     first component. Implemented by temporarily rewriting
#     CHROMEOS_BUILD/BRANCH/PATCH in chromeos_version.sh (chromite reads
#     the version only from that file; env overrides are clobbered by
#     GetBuildImageEnvvars) and restoring it on exit.
#   - The OTA payload public key lands at
#     /usr/share/update_engine/update-payload-key.pub.pem via the BSP
#     (see the ebuild; insert_au_publickey.sh has no public caller).
#
# The result is verified in place with debugfs before the script declares
# success. Payload generation is separate: release/gen-payload.sh.
set -eu
export BOARD="${BOARD:-colorburst}"
. "$(dirname "$0")/common.sh"

RELEASE_USE='-vtconsole -fbconsole -efi_earlycon -colorburst_devtools'
AUSERVER='https://update.colorburst.net/update'
# CHROMEOS_DEVSERVER is the dev-tooling package server (dev_install, factory
# installer, historically gmerge). Nothing on a shipped device consults it --
# OTA uses CHROMEOS_AUSERVER above -- but cros_set_lsb_release defaults it to
# "http://<builder hostname>:8080", which bakes the build machine's hostname
# into every image for anyone to read in chrome://system. Passing an empty
# value does NOT help: the tool substitutes the hostname for a falsy one. So
# name a host we own instead.
DEVSERVER='https://devserver.colorburst.net'

MINOR=$(cat "$DEVENV/chromiumos/src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files/RELEASE-MINOR")
WEEK=$(( 10#$(date +%V) / 4 * 4 ))
YEAR=$(date +%G)
REL="${YEAR}.${WEEK}.${MINOR}"

# --- version mapping: colorburst release number -> CHROMEOS_RELEASE_VERSION
VERSION_FILE="$DEVENV/chromiumos/src/third_party/chromiumos-overlay/chromeos/config/chromeos_version.sh"
cp "$VERSION_FILE" "$VERSION_FILE.dev-backup"
restore_version() { mv -f "$VERSION_FILE.dev-backup" "$VERSION_FILE"; }
trap restore_version EXIT
sed -i \
    -e "s/^CHROMEOS_BUILD=.*/CHROMEOS_BUILD=${YEAR}/" \
    -e "s/^CHROMEOS_BRANCH=.*/CHROMEOS_BRANCH=${WEEK}/" \
    -e "s/^CHROMEOS_PATCH=.*/CHROMEOS_PATCH=${MINOR}/" \
    "$VERSION_FILE"
echo "Release version: ${REL} (CHROMEOS_RELEASE_VERSION=${REL})"

in_container chromium-build-release "
set -x
date -Is
cd ~/chromiumos

# Kernel without the bring-up consoles. --usepkg=n so the USE change really
# rebuilds (cached binpkgs are trap #1).
cros_sdk -- env USE='-vtconsole -fbconsole -efi_earlycon' \
  emerge-${BOARD} -v --usepkg n --getbinpkg n sys-kernel/chromeos-kernel-6_12
[ \$? -eq 0 ] || exit 1

# BSP without devtools: no cb-diag.conf, no OOBE API / DevTools port in
# chrome_dev.conf (which is inert on an official image anyway -- session
# manager only reads it when is_developer_end_user).
cros_sdk -- env USE='-colorburst_devtools' \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-base/chromeos-bsp-${BOARD}
[ \$? -eq 0 ] || exit 1

# update_engine from this checkout's platform2 tree: it carries the colorburst
# patch that sends the per-installation device id. cros-workon must be started
# or emerge quietly builds the pinned upstream revision instead.
cros_sdk -- cros_workon --board=${BOARD} start chromeos-base/update_engine 2>/dev/null
cros_sdk -- emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-base/update_engine
[ \$? -eq 0 ] || exit 1

# The base image, verity on. Same USE so image-build dependency resolution
# matches the binpkgs we just made.
cros_sdk --chrome-root=/chromium -- env \
  USE='${RELEASE_USE}' \
  CHROMEOS_VERSION_AUSERVER='${AUSERVER}' \
  CHROMEOS_VERSION_DEVSERVER='${DEVSERVER}' \
  CHROMEOS_VERSION_TRACK=stable-channel \
  cros build-image --board=${BOARD} base
[ \$? -eq 0 ] || exit 1

IMGDIR=\$(readlink -f src/build/images/${BOARD}/latest)
ln -f \"\$IMGDIR/chromiumos_base_image.bin\" \"\$IMGDIR/colorburst-${REL}-release.bin\"
echo \"RELEASE R${REL}: \$IMGDIR/colorburst-${REL}-release.bin\"

# Put the sysroot back in the dev configuration so the next build-image.sh
# run is unaffected (the BSP it re-merges itself, but nothing in the dev
# flow re-merges the kernel, and a console-less kernel would silently ship
# in the next dev image otherwise).
cros_sdk -- emerge-${BOARD} -v --usepkg n --getbinpkg n \
  sys-kernel/chromeos-kernel-6_12 chromeos-base/chromeos-bsp-${BOARD}
date -Is
"

# --- verification: read the actual bits out of the image ---------------
IMGDIR=$(readlink -f "$DEVENV/chromiumos/src/build/images/${BOARD}/latest")
IMG="$IMGDIR/colorburst-${REL}-release.bin"
echo; echo "=== verifying $IMG ==="
OFF=$(( $(sfdisk -J "$IMG" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print([p["start"] for p in d["partitiontable"]["partitions"] if p["node"].endswith("3")][0])') * 512 ))
dbg() { debugfs -c -R "cat $1" "$IMG?offset=$OFF" 2>/dev/null; }
set +e  # each check reports individually; the summary decides pass/fail
fail=0
check() { # check <label> <ok?>
    if [ "$2" = 0 ]; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi
}
LSB=$(dbg /etc/lsb-release); echo "$LSB" | sed 's/^/    /'
echo "$LSB" | grep -q "CHROMEOS_AUSERVER=${AUSERVER}"; check "AUSERVER baked" $?
echo "$LSB" | grep -q "CHROMEOS_DEVSERVER=${DEVSERVER}"; check "DEVSERVER baked" $?
echo "$LSB" | grep -qi "$(hostname -s)"; [ $? -ne 0 ]; check "no build-host hostname in lsb-release" $?
echo "$LSB" | grep -q "CHROMEOS_RELEASE_VERSION=${REL}"; check "RELEASE_VERSION=${REL}" $?
echo "$LSB" | grep -q "CHROMEOS_RELEASE_TRACK=stable-channel"; check "stable-channel" $?
echo "$LSB" | grep -q "CHROMEOS_RELEASE_APPID={3EFFC3C6-5828-4F3A-967D-BAEA412E2DC8}"; check "appid" $?
dbg /usr/share/update_engine/update-payload-key.pub.pem | grep -q "BEGIN PUBLIC KEY"
check "payload pubkey present" $?
dbg /etc/os-release.d/VERSION | grep -q "R${REL}"; check "os-release VERSION=R${REL}" $?
[ -z "$(dbg /etc/init/cb-diag.conf)" ]; check "cb-diag.conf absent" $?
CDC=$(dbg /etc/chrome_dev.conf)
! echo "$CDC" | grep -q "remote-debugging-port"; check "no devtools port" $?
! echo "$CDC" | grep -q "enable-oobe-test-api"; check "no OOBE test API" $?
# cros_debug must NOT be on the kernel cmdline (official build).
! dbg /boot/syslinux/root.A.cfg | grep -q cros_debug; check "no cros_debug (syslinux)" $?
! dbg /boot/efi/boot/grub.cfg | grep -q cros_debug; check "no cros_debug (grub)" $?
# dm-verity: the grub/syslinux configs should point the kernel at dm-verity
# roots (boot target 'verified', dm= present).
dbg /boot/efi/boot/grub.cfg | grep -q 'dm='; check "dm-verity cmdline present" $?
# Kernel built without VT consoles.
KNAME=$(debugfs -c -R "ls /boot" "$IMG?offset=$OFF" 2>/dev/null |
        tr -s ' \n' '\n\n' | grep '^config-' | head -1)
KCONF=$([ -n "$KNAME" ] && dbg "/boot/$KNAME")
if [ -n "$KCONF" ]; then
    ! echo "$KCONF" | grep -q '^CONFIG_VT=y'; check "kernel CONFIG_VT off" $?
else
    echo "warn: no /boot/config-* in rootfs; kernel config not checked"
fi
[ "$fail" = 0 ] && echo "=== release image verified ===" || { echo "=== VERIFICATION FAILED ==="; exit 1; }
