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
    && rm -rf /var/lib/apt/lists/*

# 串口访问只能是 root 和 dialout 组，这里直把 runner 用户加入 dialout 组
RUN usermod -aG dialout runner
RUN usermod -aG kvm runner

# Optional: add more toolchains here (cmake, ninja, python, etc)
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     cmake ninja-build python3 python3-pip \
#  && rm -rf /var/lib/apt/lists/*

# Return to the default user expected by the runner image 
USER runner
