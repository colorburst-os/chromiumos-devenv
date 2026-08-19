#!/bin/bash
# Shared settings for the scripts in this directory. Sourced, not run.
#
# Two trees are involved and they are NOT the same checkout:
#
#   $DEVENV   this repository, which contains chromiumos/ (the repo checkout)
#   $CHROME   a Chromium checkout, outside this repository because it is 30 GB
#             and managed by gclient. See chromium/README.md for how to make one.
#
# Override either with the environment if your layout differs:
#
#     CHROME=/somewhere/chromium-src chromium/build.sh
set -u

DEVENV="${DEVENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHROME="${CHROME:-$(cd "$DEVENV/.." && pwd)/chromium-src}"
BOARD="${BOARD:-colorburst}"
DOCKER_IMAGE="${DOCKER_IMAGE:-cros-build}"

[ -d "$DEVENV/chromiumos" ] || {
    echo "no ChromiumOS checkout at $DEVENV/chromiumos -- see README.md" >&2
    exit 1
}

# Every script here runs inside the same container the rest of the tooling uses
# (cros-sdk.sh builds it), with both trees bind-mounted. cros_sdk then mounts
# $CHROME at /home/cros/chrome_root inside the chroot, which is the
# chromeos-chrome ebuild's default CHROME_ROOT, so CHROME_ROOT needs no
# override.
# The build host's hostname must not end up in shipped images. Packages embed
# `whoami@$(hostname)` build stamps (ectool's version string is one), and
# chromite defaults CHROMEOS_DEVSERVER/CHROMEOS_AUSERVER to
# "http://$(hostname):8080" when a build does not name a server -- which put
# the literal machine name in /etc/lsb-release for anyone to read in
# chrome://system. Naming the container fixes every such stamp at once.
#
# This is why the build container is NOT --network=host: Docker refuses
# --hostname in host network mode, and a --privileged container still cannot
# rename itself there (the UTS namespace is the host's). Bridge networking is
# enough -- builds only make outbound connections.
BUILD_HOSTNAME="${BUILD_HOSTNAME:-colorburst-builder}"

in_container() { # in_container <name> <command...>
    local name="$1"; shift
    docker run --rm --privileged --hostname "$BUILD_HOSTNAME" --name "$name" \
        -v "$DEVENV/chromiumos":/home/cros/chromiumos \
        -v "$CHROME":/chromium \
        -v /dev:/dev "$DOCKER_IMAGE" \
        bash -lc "$*"
}
