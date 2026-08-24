# Chromium OS build environment.
# The actual building happens inside the cros_sdk chroot; this container only
# needs the host-side prerequisites from the Chromium OS developer guide.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        file \
        git \
        gnupg \
        less \
        lsb-release \
        openssh-client \
        procps \
        python3 \
        python3-oauth2client \
        python3-pkg-resources \
        python3-virtualenv \
        python-is-python3 \
        rsync \
        qemu-system-gui \
        qemu-system-x86 \
        libgl1-mesa-dri \
        libegl1 \
        libgl1 \
        libgles2 \
        sudo \
        unzip \
        vim-tiny \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

# cros_sdk refuses to run as root; it wants a normal user with sudo.
# Replace the stock ubuntu user so our user gets UID/GID 1000, matching the
# host user that owns the bind-mounted source tree.
ARG HOST_UID=1000
RUN userdel -r ubuntu \
    && useradd -m -u ${HOST_UID} -s /bin/bash cros \
    && echo 'cros ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cros \
    && chmod 0440 /etc/sudoers.d/cros

USER cros
WORKDIR /home/cros

# depot_tools provides repo and the cros tool. Owned by the build user so it
# can self-update and bootstrap its own toolchain on first use.
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /home/cros/depot_tools
ENV PATH=/home/cros/depot_tools:$PATH

RUN git config --global user.name "Lưu Oa Oa" \
    && git config --global user.email "212658678+luuoaoa@users.noreply.github.com" \
    && git config --global color.ui false

WORKDIR /home/cros/chromiumos
CMD ["/bin/bash"]
