# Builder + runner for crosvm from the checkout's src/platform/crosvm.
# Ubuntu 26.04 for current wayland/virglrenderer; rustup pinned to the
# toolchain crosvm's rust-toolchain file demands.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        curl \
        git \
        libcap-dev \
        libclang-dev \
        libdrm-dev \
        libepoxy-dev \
        libgbm-dev \
        libslirp-dev \
        libvirglrenderer-dev \
        libwayland-dev \
        libxext-dev \
        libx11-dev \
        ninja-build \
        meson \
        pkg-config \
        protobuf-compiler \
        python3 \
        wayland-protocols \
        sudo \
        dnsmasq \
        iptables \
        iproute2 \
        procps \
        libgl1-mesa-dri \
        libegl1 \
        libgl1 \
        libgles2 \
    && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null; \
    useradd -m -u 1000 -s /bin/bash cros \
    && echo 'cros ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cros \
    && chmod 0440 /etc/sudoers.d/cros

USER cros
ENV RUSTUP_HOME=/home/cros/.rustup CARGO_HOME=/home/cros/.cargo \
    PATH=/home/cros/.cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup.sh https://sh.rustup.rs \
    && sh /tmp/rustup.sh -y --default-toolchain 1.88.0 --profile minimal \
    && rm /tmp/rustup.sh \
    && cargo --version

WORKDIR /home/cros/chromiumos
CMD ["/bin/bash"]
