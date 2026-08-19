#!/bin/bash
# Apply colorburst's platform2 patches to a chromiumos platform2 checkout.
#
# Usage: ./apply.sh /path/to/chromiumos/src/platform2
#
# These are un-upstreamed changes to first-party ChromeOS system code that are
# not carried as a fork repo. Apply them to the platform2 checkout before
# building the image (the build cros_workons the affected package from the
# local tree). Currently one patch:
#   - update-engine-device-id-0001.patch: update_engine sends
#     colorburst_device_id in the Omaha request. See the patch header for why.
set -euo pipefail
P2="${1:?usage: apply.sh <chromiumos/src/platform2>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$P2/update_engine/cros/omaha_request_builder_xml.cc" \
  || { echo "does not look like a platform2 checkout: $P2" >&2; exit 1; }
for p in "$HERE"/*.patch; do
  echo ">>> applying $(basename "$p")"
  git -C "$P2" apply --index --3way "$p" 2>/dev/null \
    || patch -d "$P2" -p1 --forward < "$p"
done
echo "OK. Rebuild update_engine (cros_workon start + emerge) and the image."
