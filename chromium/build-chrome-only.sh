#!/bin/bash
# Build chromeos-chrome from local source into the board sysroot, nothing
# else. Same invocation as the chrome step of build-image.sh; used when a
# Chrome change needs to land in the sysroot before build-release.sh.
set -eu
. "$(dirname "$0")/common.sh"

in_container chromium-build-chrome "
set -x
date -Is
cd ~/chromiumos
cros_sdk --chrome-root=/chromium -- env \
  CHROME_ORIGIN=LOCAL_SOURCE \
  USE='chrome_media hevc_codec -chrome_debug -build_tests' \
  EXTRA_GN_ARGS='symbol_level=0 blink_symbol_level=0' \
  MAKEOPTS='-j${JOBS:-12}' \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-chrome
RC=\$?; echo CHROME_RC=\$RC; date -Is
exit \$RC
"
