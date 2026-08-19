#!/bin/bash
# Incremental ninja build of ChromeOS Chrome. Minutes, not hours: a resource or
# single-file change is 3-5 edges plus a link.
#
#   ./ninja.sh                     # default target
#   ./ninja.sh -n some/other:target
#
# The output tree lives in the chroot's Chrome cache, not in the Chromium
# checkout, and is shared with the emerge in build.sh -- so a ninja.sh run
# leaves almost nothing for the next emerge to do.
#
# The target is section_embedded_chrome_binary, not chrome:
# use_embedded_sections_chrome() is true unless a sanitizer is on.
set -eu
. "$(dirname "$0")/common.sh"

OUT=/var/cache/chromeos-chrome/chrome-src/src/out_${BOARD}/Release
in_container chromium-ninja "
set -x
cd ~/chromiumos && cros_sdk --chrome-root=/chromium -- \
  /home/cros/chrome_root/src/third_party/ninja/ninja -C $OUT -j${JOBS:-12} \
  ${*:-section_embedded_chrome_binary}
"
