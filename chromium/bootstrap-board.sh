#!/bin/bash
# One-time bring-up of a new board's sysroot: setup_board + build-packages.
#
#   BOARD=colorburst ./bootstrap-board.sh
#
# The Chrome tree is mounted and CHROME_ORIGIN=LOCAL_SOURCE exported so that
# build-packages builds OUR Chromium from local source, not the tree's pinned
# upstream source and not a remote prebuilt binpkg. This is where colorburst
# Chrome is actually compiled: the release path (build-release.sh) does NOT
# re-emerge chromeos-chrome, it reuses the binpkg built here. So a failure to
# build local Chrome here MUST be fatal -- otherwise a later `cros build-image`
# would satisfy the chromeos-chrome dependency from the remote amd64-generic
# binhost and silently ship upstream Chrome with none of our patches.
set -eu
. "$(dirname "$0")/common.sh"
inhibit_sleep "$0" "$@"   # keep the host awake; released when this exits

# `set -e` inside the container: any failure (notably a local-Chrome compile
# error) aborts with a non-zero status, which propagates out through
# in_container -> bootstrap-board.sh (set -eu) -> rebuild-release.sh (set -e).
# Previously this used `set -x` only and ended with `echo BOOTSTRAP_RC=$?`,
# whose own 0 exit masked a failed build-packages and let the build fall
# through to an image made from a stale/remote Chrome.
#
# --no-withautotest: colorburst ships no autotest, and chromeos-base/autotest-
# chrome does not build in this tree -- it dies in its compile phase on
# "ERROR:root:video_AVAnalysis import error: No module named 'telemetry'".
# Nothing here ever ran it; the package was simply never rebuilt, because the
# board wipe in rebuild-release.sh silently failed for who knows how long and
# left a fully-populated sysroot behind every time. Fixing the wipe is what
# first made this script actually build a board from nothing, and this is the
# first thing that fell over when it did.
in_container "chromium-bootstrap-$BOARD" "
set -ex
date -Is
cd ~/chromiumos
cros_sdk -- setup_board --board=${BOARD}
cros_sdk --chrome-root=/chromium -- env \
  CHROME_ORIGIN=LOCAL_SOURCE \
  USE='chrome_media hevc_codec -chrome_debug -build_tests' \
  EXTRA_GN_ARGS='symbol_level=0 blink_symbol_level=0' \
  cros build-packages --board=${BOARD} --no-withautotest
echo BOOTSTRAP_OK
date -Is
"
