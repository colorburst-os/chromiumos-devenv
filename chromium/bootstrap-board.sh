#!/bin/bash
# One-time bring-up of a new board's sysroot: setup_board + build-packages.
#
#   BOARD=colorburst ./bootstrap-board.sh
#
# The Chrome tree is mounted and CHROME_ORIGIN=LOCAL_SOURCE exported so that
# if build-packages decides to build a browser (fresh boards have no usable
# binpkg), it builds OUR Chromium, not the tree's pinned upstream source.
# Whatever browser lands here is only a bootstrap: build-image.sh always
# re-emerges chromeos-chrome from local source afterwards, so a stray binpkg
# cannot survive into an image.
set -eu
. "$(dirname "$0")/common.sh"

in_container "chromium-bootstrap-$BOARD" "
set -x
date -Is
cd ~/chromiumos
cros_sdk -- setup_board --board=${BOARD}
cros_sdk --chrome-root=/chromium -- env \
  CHROME_ORIGIN=LOCAL_SOURCE \
  USE='chrome_media hevc_codec -chrome_debug -build_tests' \
  EXTRA_GN_ARGS='symbol_level=0 blink_symbol_level=0' \
  cros build-packages --board=${BOARD}
echo BOOTSTRAP_RC=\$?
date -Is
"
