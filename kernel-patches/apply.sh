#!/bin/bash
# Apply colorburst's kernel patches to a chromiumos kernel checkout.
#
# Usage: ./apply.sh /path/to/chromiumos/src/third_party/kernel/v6.12
#
# These are un-upstreamed changes to first-party ChromeOS kernel config that
# colorburst carries but does not maintain as a fork repo. Apply them to the
# kernel checkout before building (the build cros_workons the affected
# package from the local tree). The patches:
#   - reven-virtio-input-0001.patch: enables CONFIG_VIRTIO_INPUT on the
#     reven flavour so crosvm's window mouse/keyboard actually reach the
#     guest.
# See each patch header for the full reasoning.
#
# Safe to re-run: chromium/rebuild-release.sh calls this unconditionally, so
# an already-patched tree is the normal case.
set -euo pipefail
KDIR="${1:?usage: apply.sh <chromiumos/src/third_party/kernel/vX.YY>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
test -f "$KDIR/chromeos/scripts/prepareconfig" \
  || { echo "does not look like a chromiumos kernel checkout: $KDIR" >&2; exit 1; }
for p in "$HERE"/*.patch; do
  # Detect an already-applied patch and skip it quietly. Without this the
  # fallback `patch --forward` still copes, but announces it as "Reversed (or
  # previously applied) patch detected", drops a .rej file next to the source,
  # and looks like a failure when it is a no-op.
  if git -C "$KDIR" apply --reverse --check "$p" 2>/dev/null; then
    echo ">>> $(basename "$p") already applied -- skipping"
    continue
  fi
  echo ">>> applying $(basename "$p")"
  git -C "$KDIR" apply --index --3way "$p" 2>/dev/null \
    || patch -d "$KDIR" -p1 --forward < "$p"
done
echo "OK. Rebuild the kernel (cros_workon start + emerge) and the image."
