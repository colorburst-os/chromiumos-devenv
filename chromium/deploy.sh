#!/bin/bash
# Push the locally built Chrome onto a running VM without rebuilding an image.
# This is the fast loop: minutes per iteration.
#
#   ./deploy.sh 9222          # vm-instance 0 (SSH port 9222 + instance id)
#   ./deploy.sh 9222 --rootfs # write into the rootfs instead of bind-mounting
#
# --mount (the default) bind-mounts the new Chrome over /opt/google/chrome from
# the stateful partition, so the read-only rootfs is not touched and the change
# survives until the next boot. --rootfs writes for real and needs the rootfs
# to be writable -- see chromiumos-readonly-rootfs notes in CHROME-ITERATION.md.
set -eu
. "$(dirname "$0")/common.sh"

PORT="${1:?usage: deploy.sh <ssh-port> [--rootfs]}"
MOUNT="--mount"
[ "${2:-}" = "--rootfs" ] && MOUNT=""

# The inner command is one line on purpose: it goes through docker -> bash -lc
# -> cros_sdk -> bash -c, and a backslash continuation does not survive that.
in_container chromium-deploy "cd ~/chromiumos && cros_sdk --chrome-root=/chromium -- bash -c 'install -m600 /mnt/host/source/chromite/ssh_keys/testing_rsa /tmp/k && deploy_chrome --board=${BOARD} --build-dir=/var/cache/chromeos-chrome/chrome-src/src/out_${BOARD}/Release --device=localhost:${PORT} --private-key=/tmp/k ${MOUNT} --noremove-rootfs-verification --nostrip --compress=never --force'"
