#!/usr/bin/env bash
# Boot the built Chromium OS image in QEMU/KVM with a VNC display.
#
#   ./run-vm.sh [path-to-image.bin]
#
# Defaults to the latest colorburst test image (the live board; amd64-generic
# is retired). Connect a viewer to localhost:5900 (e.g.
# `remmina -c vnc://localhost:5900`), or SSH in with
# `ssh -p 9222 root@localhost` (password: test0000).
#
# The VM lives inside the container: keep this script running, and Ctrl-C /
# `exit` from the shell it drops you into to shut everything down.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD="${CROS_VM_BOARD:-colorburst}"

# Translate a host image path to the container's /mnt/host/source view.
HOST_IMG="${1:-$DIR/chromiumos/src/build/images/$BOARD/latest/chromiumos_test_image.bin}"
if [ ! -f "$HOST_IMG" ]; then
    echo "error: image not found: $HOST_IMG" >&2
    exit 1
fi
IMG="/mnt/host/source/${HOST_IMG#"$DIR/chromiumos/"}"

echo ">>> Booting $HOST_IMG"
echo ">>> VNC: localhost:5900    SSH: ssh -p 9222 root@localhost (password: test0000)"

# The VM and your shell must live in ONE cros_sdk session: cros_sdk gives
# each invocation its own PID namespace, so qemu is killed the moment the
# session that started it exits. vm_shell.sh starts the VM and then execs an
# interactive shell inside that same session.
exec env PUBLISH_PORTS=1 "$DIR/cros-sdk.sh" \
    cros_sdk -- /mnt/host/source/vm_shell.sh "$IMG" "$BOARD"
