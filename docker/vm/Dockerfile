# VM runner for built Chromium OS images. Separate from the build image:
# needs a much newer qemu than Ubuntu 24.04 ships — virgl blob scanout
# (required by current CrOS Chrome for accelerated display) needs qemu >= 9.1.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-system-gui \
        qemu-system-x86 \
        libgl1-mesa-dri \
        libegl1 \
        libgl1 \
        libgles2 \
        librsvg2-common \
        shared-mime-info \
        adwaita-icon-theme \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null; \
    useradd -m -u 1000 -s /bin/bash cros

USER cros
WORKDIR /home/cros/chromiumos
CMD ["/bin/bash"]
