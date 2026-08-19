#!/bin/bash
# The whole pipeline: Chrome, then our BSP package, then an image.
#
#   ./build-image.sh
#
# NEVER run plain `cros build-packages` after building Chrome locally: it passes
# --force-remote-binary=chromeos-base/chromeos-chrome and replaces our build
# with the binhost's, silently. See CHROME-BUILD.md 8.
#
# The BSP step is separate because the board sysroot persists between builds, so
# an ebuild edit only reaches the image if that package is re-merged.
set -eu
. "$(dirname "$0")/common.sh"

in_container chromium-build-image "
set -x
date -Is
cd ~/chromiumos
df -h /home/cros/chromiumos

cros_sdk --chrome-root=/chromium -- env \
  CHROME_ORIGIN=LOCAL_SOURCE \
  USE='chrome_media hevc_codec -chrome_debug -build_tests' \
  EXTRA_GN_ARGS='symbol_level=0 blink_symbol_level=0' \
  MAKEOPTS='-j${JOBS:-12}' \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-chrome
CHROME_RC=\$?; echo CHROME_RC=\$CHROME_RC
[ \$CHROME_RC -eq 0 ] || exit \$CHROME_RC

cros_sdk --chrome-root=/chromium -- \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-base/chromeos-bsp-${BOARD}
BSP_RC=\$?; echo BSP_RC=\$BSP_RC
[ \$BSP_RC -eq 0 ] || exit \$BSP_RC

# update_engine carries our colorburst patch (the per-installation device id
# in the Omaha request). It is a cros-workon package, so it only builds from
# this checkout's platform2 tree while workon is started for it -- otherwise
# emerge silently builds the pinned upstream revision and the patch vanishes.
cros_sdk --chrome-root=/chromium -- \
  cros_workon --board=${BOARD} start chromeos-base/update_engine 2>/dev/null
cros_sdk --chrome-root=/chromium -- \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-base/update_engine
UE_RC=\$?; echo UE_RC=\$UE_RC
[ \$UE_RC -eq 0 ] || exit \$UE_RC

cros_sdk --chrome-root=/chromium -- env \
  CHROMEOS_VERSION_DEVSERVER='https://devserver.colorburst.net' \
  cros build-image --board=${BOARD} --no-enable-rootfs-verification test
IMAGE_RC=\$?; echo IMAGE_RC=\$IMAGE_RC
[ \$IMAGE_RC -eq 0 ] || exit \$IMAGE_RC

# Release naming: colorburst-<year>.<week floored to /4>.<minor>.bin, the
# same scheme the BSP stamps into /etc/os-release VERSION (R-prefixed
# there). Minor comes from the overlay's RELEASE-MINOR so the image name
# and the OS's own idea of its version cannot drift.
MINOR=\$(cat src/overlays/overlay-${BOARD}/chromeos-base/chromeos-bsp-${BOARD}/files/RELEASE-MINOR 2>/dev/null || echo 0)
WEEK=\$(( 10#\$(date +%V) / 4 * 4 ))
REL=\$(date +%G).\${WEEK}.\${MINOR}
IMGDIR=\$(readlink -f src/build/images/${BOARD}/latest)
ln -f \"\$IMGDIR/chromiumos_test_image.bin\" \"\$IMGDIR/colorburst-\${REL}.bin\"
echo \"RELEASE R\${REL}: \$IMGDIR/colorburst-\${REL}.bin\"
date -Is
df -h /home/cros/chromiumos
"
