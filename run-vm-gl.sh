#!/usr/bin/env bash
# Boot the Chromium OS image with GPU-accelerated graphics in a native window.
#
#   ./run-vm-gl.sh [path-to-image.bin]
#
# Guest Chrome renders via virgl on the host GPU (needs an image built with
# the virgl Mesa driver; the colorburst board inherits it from reven:base.
# Without it every display backend shows black after the splash). Close the
# window or Ctrl-C to stop the VM.
# SSH: ssh -p 9222 root@localhost (password: test0000).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_IMG="${1:-$DIR/chromiumos/src/build/images/colorburst/latest/chromiumos_test_image.bin}"
if [ ! -f "$HOST_IMG" ]; then
    echo "error: image not found: $HOST_IMG" >&2
    exit 1
fi
IMG="/home/cros/chromiumos/${HOST_IMG#"$DIR/chromiumos/"}"

echo ">>> Booting $HOST_IMG (virgl GL window)"
echo ">>> SSH: ssh -p 9222 root@localhost (password: test0000)"

exec env CROS_IMAGE=cros-vm GUI=1 PUBLISH_PORTS=1 "$DIR/cros-sdk.sh" \
    qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 8 -m 8G \
    -device virtio-vga-gl -display gtk,gl=on,show-cursor=on \
    -usb -device usb-tablet \
    -device virtio-net,netdev=eth0 \
    -netdev user,id=eth0,net=10.0.2.0/27,hostfwd=tcp:0.0.0.0:2222-:22 \
    -device virtio-scsi-pci,id=scsi \
    -device scsi-hd,drive=hd,rotation_rate=1 \
    -drive if=none,id=hd,file="$IMG",format=raw,cache=unsafe \
    -device virtio-rng
