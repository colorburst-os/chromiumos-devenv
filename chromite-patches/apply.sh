#!/bin/bash
# Apply colorburst's chromite patches to a chromiumos chromite checkout.
#
# Usage: ./apply.sh /path/to/chromiumos/chromite
#
# These are un-upstreamed changes to the ChromeOS build tooling (chromite) that
# colorburst carries but does not maintain as a fork repo. Apply them to the
# chromite checkout before building the image. Currently one patch:
#   - dlc-factory-install-crostini-0001.patch: allow termina-dlc,
#     termina-tools-dlc and edk2-ovmf-dlc to be factory-installed, so Crostini
#     ("Linux development environment") is baked into the release image and
#     installs with no DLC OTA. See the patch header for why.
set -euo pipefail
CHROMITE="${1:?usage: apply.sh <chromiumos/chromite>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$CHROMITE/lib/dlc_allowlist.py" \
  || { echo "does not look like a chromite checkout: $CHROMITE" >&2; exit 1; }
for p in "$HERE"/*.patch; do
  echo ">>> applying $(basename "$p")"
  git -C "$CHROMITE" apply --index --3way "$p" 2>/dev/null \
    || patch -d "$CHROMITE" -p1 --forward < "$p"
done
echo "OK. Rebuild the DLC packages + image (emerge-<board> the DLCs, cros build-image)."
