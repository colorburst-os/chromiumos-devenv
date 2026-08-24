#!/usr/bin/env bash
# Run a command (or an interactive shell) in the Chromium OS build container.
#
#   ./cros-sdk.sh                 # interactive shell
#   ./cros-sdk.sh repo sync -j16  # one-off command
#
# The source tree lives on the host at ./chromiumos and is bind-mounted into
# the container, so containers are disposable and the checkout/chroot persist.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/chromiumos"
mkdir -p "$SRC"

TTY_FLAGS=()
if [ -t 0 ]; then
    TTY_FLAGS=(-it)
fi

# NET=host runs on the host network (workaround for flaky container DNS;
# incompatible with PUBLISH_PORTS, which it makes unnecessary anyway).
NET_FLAGS=()
if [ "${NET:-}" = host ]; then
    NET_FLAGS=(--network=host)
fi

# PUBLISH_PORTS=1 exposes the VM's VNC display (5900) and SSH (9222) on the
# host's localhost. Opt-in so parallel build containers don't fight over ports.
# VM_SSH_PORT / VM_VNC_PORT move the host-side ports so several VM instances
# can run side by side -- see tools/vm-instance.sh.
PORT_FLAGS=()
if [ "${PUBLISH_PORTS:-0}" = 1 ]; then
    # 9222 maps to 2222: qemu's extra SSH hostfwd binds 0.0.0.0:2222 in the
    # container (the default 9222 forward is loopback-only and unreachable).
    PORT_FLAGS=(
        -p "127.0.0.1:${VM_VNC_PORT:-5900}:5900"
        -p "127.0.0.1:${VM_SSH_PORT:-9222}:2222"
    )
fi

# Naming the container makes an instance findable (and killable) by id.
NAME_FLAGS=()
if [ -n "${CONTAINER_NAME:-}" ]; then
    NAME_FLAGS=(--name "$CONTAINER_NAME")
fi

# Grant /dev/kvm access (root:kvm on the host) for running the VM.
KVM_FLAGS=()
KVM_GID="$(getent group kvm | cut -d: -f3)" && KVM_FLAGS=(--group-add "$KVM_GID")

# GUI=1 lets the container open windows on the host's Wayland/X session and
# use the GPU render node (for qemu with virgl acceleration).
GUI_FLAGS=()
if [ "${GUI:-0}" = 1 ]; then
    RUNDIR="/run/user/$(id -u)"
    GUI_FLAGS=(
        --ipc=host
        -v "$RUNDIR":"$RUNDIR"
        -v /tmp/.X11-unix:/tmp/.X11-unix
        -e XDG_RUNTIME_DIR="$RUNDIR"
        -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
        -e "DISPLAY=${DISPLAY:-:0}"
    )
    XAUTH="$(ls "$RUNDIR"/xauth_* 2>/dev/null | head -1)" \
        && GUI_FLAGS+=(-e XAUTHORITY="$XAUTH")
    RENDER_GID="$(getent group render | cut -d: -f3)" \
        && GUI_FLAGS+=(--group-add "$RENDER_GID")
fi

# --privileged: cros_sdk needs to create its chroot with bind mounts, and
# image building needs loop devices.
GPU_FLAGS=()
if command -v nvidia-smi &>/dev/null && [ "${GUI:-0}" = 1 ]; then
    GPU_FLAGS=(
        --runtime=nvidia
        -e NVIDIA_VISIBLE_DEVICES=all
        -e NVIDIA_DRIVER_CAPABILITIES=all
    )
fi

exec docker run --rm "${TTY_FLAGS[@]}" \
    --privileged \
    "${NAME_FLAGS[@]}" \
    "${KVM_FLAGS[@]}" \
    "${NET_FLAGS[@]}" \
    "${PORT_FLAGS[@]}" \
    "${GUI_FLAGS[@]}" \
    "${GPU_FLAGS[@]}" \
    --hostname cros-build \
    -v "$SRC":/home/cros/chromiumos \
    -v /dev:/dev \
    "${CROS_IMAGE:-cros-build}" "$@"
