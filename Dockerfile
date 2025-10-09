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
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    RUST_VERSION=nightly

RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) rustArch='x86_64-unknown-linux-gnu'; rustupSha256='20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' ;; \
        armhf) rustArch='armv7-unknown-linux-gnueabihf'; rustupSha256='3b8daab6cc3135f2cd4b12919559e6adaee73a2fbefb830fadf0405c20231d61' ;; \
        arm64) rustArch='aarch64-unknown-linux-gnu'; rustupSha256='e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c' ;; \
        i386) rustArch='i686-unknown-linux-gnu'; rustupSha256='a5db2c4b29d23e9b318b955dd0337d6b52e93933608469085c924e0d05b1df1f' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.28.2/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
    rustup --version; \
    cargo --version; \
    rustc --version;

# Install additional Rust toolchains
RUN rustup toolchain install nightly-2025-05-20

# Install additional targets and components 
RUN rustup target add aarch64-unknown-none-softfloat \
    riscv64gc-unknown-none-elf \
    x86_64-unknown-none \
    loongarch64-unknown-none-softfloat --toolchain nightly-2025-05-20
RUN rustup target add aarch64-unknown-none-softfloat \
    riscv64gc-unknown-none-elf \
    x86_64-unknown-none \
    loongarch64-unknown-none-softfloat --toolchain nightly
RUN rustup component add clippy llvm-tools rust-src --toolchain nightly-2025-05-20
RUN rustup component add clippy llvm-tools rust-src --toolchain nightly

# 串口访问只能是 root 和 dialout 组，这里直把 runner 用户加入 dialout 组
RUN usermod -aG dialout runner
RUN usermod -aG kvm runner

# Optional: add more toolchains here (cmake, ninja, python, etc)
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cmake ninja-build python3 python3-pip \
#  && rm -rf /var/lib/apt/lists/*

# Return to the default user expected by the runner image
USER runner

# Add Rust mirror configuration to ~/.cargo/config.toml
RUN mkdir -p /home/runner/.cargo && echo '[source.crates-io]\nreplace-with = "rsproxy-sparse"\n[source.rsproxy]\nregistry = "https://rsproxy.cn/crates.io-index"\n[source.rsproxy-sparse]\nregistry = "sparse+https://rsproxy.cn/index/"\n[registries.rsproxy]\nindex = "https://rsproxy.cn/crates.io-index"\n[net]\ngit-fetch-with-cli = true' > /home/runner/.cargo/config.toml
