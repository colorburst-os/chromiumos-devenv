#!/bin/bash
# Runs INSIDE the cros_sdk chroot (as /mnt/host/source/vm_shell.sh).
# Starts the VM and drops into a shell in the same cros_sdk session.
# The VM must stay in this session: cros_sdk gives each invocation its own
# PID namespace, so qemu dies as soon as the session that started it exits.
set -e
BOARD="${2:-amd64-generic}"
# cros vm's own SSH forward binds 127.0.0.1 inside the container, which
# Docker's port publishing can't reach; add a second forward on 0.0.0.0:2222
# (mapped to the host's 9222 by cros-sdk.sh).
cros vm --start --board="$BOARD" --image-path="$1" \
    --qemu-args ' -vnc 0.0.0.0:0' \
    --qemu-hostfwd 'tcp:0.0.0.0:2222-:22'
echo ">>> VM is up. VNC: localhost:5900   SSH: ssh -p 9222 root@localhost (password: test0000)"
echo ">>> You are now in the SDK chroot. Exit this shell to stop the VM."
exec bash -i
