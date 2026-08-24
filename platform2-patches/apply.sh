#!/bin/bash
# Apply colorburst's platform2 patches to a chromiumos platform2 checkout.
#
# Usage: ./apply.sh /path/to/chromiumos/src/platform2
#
# These are un-upstreamed changes to first-party ChromeOS system code that are
# not carried as a fork repo. Apply them to the platform2 checkout before
# building the image (the build cros_workons the affected package from the
# local tree). The patches:
#   - update-engine-device-id-0001.patch: update_engine sends
#     colorburst_device_id in the Omaha request.
#   - update-engine-dlc-url-0001.patch: scaled/force-ota DLC installs fetch
#     from dl.colorburst.net instead of Google's hardcoded CDN.
#   - regions-drop-vi-tcvn-0001.patch: region vn must not list an input method
#     colorburst does not ship, or OOBE crashes on first boot.
# See each patch header for the full reasoning.
#
# Safe to re-run: chromium/rebuild-release.sh calls this unconditionally, so an
# already-patched tree is the normal case.
set -euo pipefail
P2="${1:?usage: apply.sh <chromiumos/src/platform2>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$P2/update_engine/cros/omaha_request_builder_xml.cc" \
  || { echo "does not look like a platform2 checkout: $P2" >&2; exit 1; }
for p in "$HERE"/*.patch; do
  # Detect an already-applied patch and skip it quietly. Without this the
  # fallback `patch --forward` still copes, but announces it as "Reversed (or
  # previously applied) patch detected", drops a .rej file next to the source,
  # and looks like a failure when it is a no-op.
  if git -C "$P2" apply --reverse --check "$p" 2>/dev/null; then
    echo ">>> $(basename "$p") already applied -- skipping"
    continue
  fi
  echo ">>> applying $(basename "$p")"
  git -C "$P2" apply --index --3way "$p" 2>/dev/null \
    || patch -d "$P2" -p1 --forward < "$p"
done
echo "OK. Rebuild update_engine (cros_workon start + emerge) and the image."
