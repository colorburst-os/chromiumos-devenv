#!/bin/bash
# Build chromeos-chrome from the local Chromium checkout and install it into the
# board sysroot. ~2-3 h cold, a few minutes warm.
#
# USE=chrome_media is what gets H.264 and AAC (proprietary_codecs=true,
# ffmpeg_branding=ChromeOS). --usepkg n --getbinpkg n so portage cannot shortcut
# to the binhost and hand us a build without our patches.
set -eu
. "$(dirname "$0")/common.sh"

in_container chromium-build "
set -x
date -Is
cd ~/chromiumos
cros_sdk --chrome-root=/chromium -- env \
  CHROME_ORIGIN=LOCAL_SOURCE \
  USE='chrome_media hevc_codec -chrome_debug -build_tests' \
  EXTRA_GN_ARGS='symbol_level=0 blink_symbol_level=0' \
  MAKEOPTS='-j${JOBS:-12}' \
  emerge-${BOARD} -v --usepkg n --getbinpkg n chromeos-chrome
echo CHROME_RC=\$?
date -Is
"
