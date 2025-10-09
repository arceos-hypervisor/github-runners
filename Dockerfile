# Custom Actions Runner with QEMU and build tools
# Base image: official GitHub Actions runner
FROM ghcr.io/actions/actions-runner:latest

# Switch to root to install packages
USER root

ENV DEBIAN_FRONTEND=noninteractive

# Install QEMU and common build tools
# - build-essential: gcc, g++, make, libc dev headers
# - qemu-system: system emulators
# - qemu-user, qemu-user-static: user-mode emulators for cross-arch binaries
# - qemu-utils: qemu-img, etc
# - binfmt-support: helpers for binfmt_misc (host typically manages handlers)
# - pkg-config, git, ca-certificates: common utilities
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       pkg-config \
       git \
       ca-certificates \
       qemu-system \
       qemu-user \
       qemu-user-static \
       qemu-utils \
       binfmt-support \
       dosfstools \
       python3-venv \
       udev \
       libudev-dev \
       openssl \
       libssl-dev \
       xxd \
       wget \
       mbpoll \
       flex \
       bison \
       libelf-dev \
       gcc-aarch64-linux-gnu \
       g++-aarch64-linux-gnu \
       gcc-riscv64-linux-gnu \
       g++-riscv64-linux-gnu \
       bc \
       fakeroot \
       coreutils \
       cpio \
       gzip \
       debootstrap \
       binfmt-support \
       debian-archive-keyring \
       eatmydata \
       file \
       rsync \
    && rm -rf /var/lib/apt/lists/*

#  Rust development
env RUSTUP_DIST_SERVER="https://rsproxy.cn"
env RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"

RUN curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh | sh -s -- -y
# Add Rust mirror configuration to ~/.cargo/config.toml
RUN mkdir -p ~/.cargo && echo '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy]\nregistry = "https://rsproxy.cn/crates.io-index"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n[registries.rsproxy]\nindex = "https://rsproxy.cn/crates.io-index"\n[net]\ngit-fetch-with-cli = true' > ~/.cargo/config.toml

# 串口访问只能是 root 和 dialout 组，这里直把 runner 用户加入 dialout 组
RUN usermod -aG dialout runner
RUN usermod -aG kvm runner

# Optional: add more toolchains here (cmake, ninja, python, etc)
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cmake ninja-build python3 python3-pip \
#  && rm -rf /var/lib/apt/lists/*

# Return to the default user expected by the runner image
USER runner
