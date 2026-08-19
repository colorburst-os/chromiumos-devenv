#!/usr/bin/env bash
# Boot the built Chromium OS image in a native window on your desktop.
#
#   ./run-vm-window.sh [path-to-image.bin]
#
# Defaults to the latest amd64-generic test image. Close the window or Ctrl-C
# to stop the VM. SSH: ssh -p 9222 root@localhost (password: test0000).
#
# Display is plain virtio-vga (2D): the guest composites the UI in software,
# which renders correctly and is plenty fast for UI work. Do NOT switch to
# virtio-vga-gl / -display gl=on: Chromium OS Chrome's virgl scanout buffers
# make qemu's GL display drop the surface ("Display output is not active")
# right after the boot splash — verified broken on qemu 8.2 and 10.2, with
# and without blob=true. Accelerated guest GL needs crosvm instead.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST_IMG="${1:-$DIR/chromiumos/src/build/images/amd64-generic/latest/chromiumos_test_image.bin}"
if [ ! -f "$HOST_IMG" ]; then
    echo "error: image not found: $HOST_IMG" >&2
    exit 1
fi
IMG="/home/cros/chromiumos/${HOST_IMG#"$DIR/chromiumos/"}"

echo ">>> Booting $HOST_IMG"
echo ">>> SSH: ssh -p 9222 root@localhost (password: test0000)"

# cros-vm image (qemu 10.x); disk/net mirror what cros vm uses. The SSH
# forward binds 0.0.0.0:2222 so Docker's 9222 mapping can reach it.
exec env CROS_IMAGE=cros-vm GUI=1 PUBLISH_PORTS=1 "$DIR/cros-sdk.sh" \
    qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 8 -m 8G \
    -device virtio-vga,xres=1920,yres=1080 \
    -display gtk,show-cursor=on \
    -usb -device usb-tablet \
    -device virtio-net,netdev=eth0 \
    -netdev user,id=eth0,net=10.0.2.0/27,hostfwd=tcp:0.0.0.0:2222-:22 \
    -device virtio-scsi-pci,id=scsi \
    -device scsi-hd,drive=hd,rotation_rate=1 \
    -drive if=none,id=hd,file="$IMG",format=raw,cache=unsafe \
    -device virtio-rng
