#!/bin/bash
# Boot the freshly built test image in QEMU/KVM, verify it over SSH, shut down.
# Run inside the SDK chroot: cros_sdk -- bash /mnt/host/source/vm_smoke_test.sh
set -ex

IMG=/mnt/host/source/src/build/images/amd64-generic/latest/chromiumos_test_image.bin
cros vm --start --board=amd64-generic --image-path="$IMG"
echo "=== VM STARTED, verifying over SSH ==="

KEY=/tmp/testing_rsa
cp /mnt/host/source/chromite/ssh_keys/testing_rsa "$KEY"
chmod 600 "$KEY"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$KEY" -p 9222 root@localhost 'cat /etc/lsb-release; uname -a; uptime'
echo "=== SSH VERIFY OK ==="

cros vm --stop
echo "=== VM TEST PASSED ==="
