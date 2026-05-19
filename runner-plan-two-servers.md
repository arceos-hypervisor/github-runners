# TGOSKits CI 双服务器 self-hosted 迁移方案

## 1. 目标

当前目标不是单纯“把所有东西都改成同一个 Docker 镜像”，而是同时满足以下要求：

1. **降低 GitHub-hosted 并发限制影响**  
   GitHub 主要负责触发 workflow 和分发 job。耗时测试尽量由自有 self-hosted runner 承接，避免大量 job 占用 GitHub-hosted runner 的并发额度。

2. **使用两台自有服务器承接测试**  
   10.3.10.194 服务器继续承担已有 self-hosted 特殊测试，包括 Axvisor x86_64 KVM/VMX 测试和开发板相关测试。新增服务器 `10.0.20.39` 第一阶段承接原 GitHub-hosted 普通测试，例如普通 QEMU、clippy、sync-lint、std 等不依赖 KVM/物理板的测试。

3. **开发板测试仍限定在 10.3.10.194**  
   具体开发板、串口、TFTP、电源控制等硬件资源仍在 `10.3.10.194` 上，因此 board 测试应只调度到 10.3.10.194 上对应的 board runner。

4. **原 GitHub-hosted 普通测试第一阶段迁到 10.0.20.39**  
   ArceOS、StarryOS、Axvisor 的普通 QEMU 测试，以及 clippy、sync-lint、std 测试，第一阶段迁移到 `10.0.20.39` 上的普通 runner。需要 KVM/VMX/SVM 的测试仍必须调度到具备 `/dev/kvm` 和对应 CPU 虚拟化能力的 10.3.10.194 runner；开发板测试仍固定在 10.3.10.194。

5. **目标仓库是 rcore-os/tgoskits 时走自有 runner 流程**  
   因为希望 PR 到 rcore 主仓时也由服务器测试，所以只要 workflow 运行在 `rcore-os/tgoskits` 主仓上下文中，包括 rcore 内部分支、内部 PR、外部 fork 提到 rcore 的 PR，都使用 rcore self-hosted runner。第一阶段普通测试迁到 `10.0.20.39`；现有 KVM/VMX 和物理板特殊测试继续留在 10.3.10.194。外部 fork 仓库自己的 CI 仍继续使用 GitHub-hosted runner。

6. **两套流程环境应尽量一致**  
   rcore 主仓 self-hosted 流程和 fork 仓库自己的 GitHub-hosted 流程，应使用尽量一致的测试依赖、QEMU、Rust、musl 工具链。这样 fork 用户在自己的 GitHub CI 上看到的普通测试结果，与 PR 到 rcore 后的普通测试结果尽量一致。fork 仓库自己的 CI 对当前 self-hosted 三项继续保持原有跳过行为。

## 2. 当前问题总结

当前主 CI 大体分为：

```text
GitHub-hosted + tgoskits-container
  -> 大多数普通测试

10.3.10.194 self-hosted runner 容器
  -> Axvisor x86_64、Axvisor board、Starry board
```

其中 GitHub-hosted 普通测试使用：

```text
ghcr.io/rcore-os/tgoskits-container:latest
ghcr.io/rcore-os/tgoskits-container-axvisor-lvz:latest
```

10.3.10.194 self-hosted 测试使用：

```text
qc-actions-runner:v0.0.1
```

并且测试命令直接在 runner 容器内执行。

当前 self-hosted 测试并不全是物理板测试：

```text
Test axvisor self-hosted x86_64
  -> cargo xtask axvisor test qemu --arch x86_64
  -> 非物理板测试
  -> 但依赖 x86_64 KVM/VMX

Test axvisor self-hosted board orangepi-5-plus-linux
  -> cargo xtask axvisor test board --board orangepi-5-plus-linux
  -> 物理板测试

Test starry self-hosted board orangepi-5-plus
  -> cargo xtask starry test board --board orangepi-5-plus
  -> 物理板测试
```

其中 `cargo xtask axvisor test qemu --arch x86_64` 虽然是 QEMU 测试，但它不是普通 TCG QEMU 测试。对应配置使用 `-accel kvm`、`-cpu host`，构建特性包含 `vmx`，因此需要 `/dev/kvm` 和宿主 CPU 虚拟化能力。它放在 self-hosted runner 上有技术原因，不应简单迁移到标准 GitHub-hosted `ubuntu-latest`。

主要问题：

- 普通测试仍大量占用 GitHub-hosted runner 并发。
- self-hosted 测试环境和 `tgoskits-container` 不完全一致。
- 当前 self-hosted 测试已有 `rcore-os` owner 限制。新的目标是保留这个限制，让非 rcore 仓库自己的 CI 不使用 self-hosted；但对于外部 fork 提到 `rcore-os/tgoskits` 的 PR，允许其在主仓 workflow 上下文中使用与 rcore 组织内分支/PR 相同的 self-hosted 测试能力。
- fork 仓库自己的 CI 应与原有流程保持一致：继续跳过当前 self-hosted 三项，不把它们转换成 GitHub-hosted 测试。

### 2.1 当前已有的 self-hosted 组织限制

当前 `tgoskits/.github/workflows/ci.yml` 中，已有 self-hosted 测试项都带有：

```yaml
required_repository_owner: rcore-os
```

例如：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu","kvm","intel"]'
required_repository_owner: rcore-os
```

和：

```yaml
runs_on: '["self-hosted","linux","board"]'
required_repository_owner: rcore-os
```

这些矩阵项最终调用 `.github/workflows/reusable-command.yml`。复用 workflow 中实际判断条件是：

```yaml
inputs.required_repository_owner == '' || github.repository_owner == inputs.required_repository_owner
```

含义是：

- 如果 `required_repository_owner` 为空，则不限制仓库 owner。
- 如果 `required_repository_owner` 为 `rcore-os`，则只有 `github.repository_owner == 'rcore-os'` 时才会运行该 job。
- 如果 workflow 在非 `rcore-os` 组织或个人 fork 仓库中运行，这些 self-hosted job 会被跳过。

因此，当前实现中“非 rcore 组织下不测 self-hosted runner”这个判断基本成立。优化方案仍应保留这个设计：外部 fork 仓库自己的 CI 不应请求 rcore 的 self-hosted runner。

需要注意的是，`github.repository_owner` 判断的是当前 workflow 所在仓库的 owner。对于外部 fork 自己仓库中的 CI，它能正确跳过 self-hosted。但如果是 fork PR 触发 `rcore-os/tgoskits` 主仓中的 `pull_request` workflow，`github.repository_owner` 仍可能是 `rcore-os`。在当前新目标下，这正好符合预期：外部 fork PR 到 rcore 主仓后，可以和 rcore 组织内分支/PR 一样使用 self-hosted runner。

这也意味着风险边界发生变化：外部 fork PR 的代码会在 rcore 服务器上执行，并且可以触达当前 self-hosted 测试所使用的资源。该方案是为了 CI 效率和覆盖率主动接受这部分风险，后续应通过 runner 隔离、权限收敛、资源清理和 GitHub PR 审批策略降低风险。

## 3. 推荐总体架构

推荐将 CI 分成两条路径：

```text
rcore-os/tgoskits 主仓 workflow
  -> self-hosted runner 优先
  -> 原 GitHub-hosted 普通测试第一阶段迁到 10.0.20.39
  -> 10.3.10.194 继续承接 Axvisor x86_64 KVM/VMX 测试
  -> 10.3.10.194 继续承接开发板测试

fork 仓库自己的 CI
  -> GitHub-hosted runner
  -> 使用 tgoskits-container
  -> 不使用 rcore 自有服务器
```

### 3.1 rcore 主仓流程

```text
GitHub Actions 调度
  ├── 普通测试
  │     └── runs-on: [self-hosted, linux, tgoskits]
  │           └── 第一阶段落到 10.0.20.39 普通 runner
  ├── KVM 测试
  │     └── runs-on: [self-hosted, linux, tgoskits, qemu, kvm, intel]
  │           └── 10.3.10.194 上支持 /dev/kvm + VMX 的 runner
  └── board 测试
        └── runs-on: [self-hosted, linux, tgoskits, board-...]
              └── 10.3.10.194 上绑定真实开发板资源的 runner
```

这里的“rcore 主仓流程”包括：

```text
rcore-os/tgoskits push
rcore-os/tgoskits 内部 PR
外部 fork 提到 rcore-os/tgoskits 的 PR
```

普通测试、KVM/VMX 测试、board 测试都按同一套主仓 workflow 规则执行。也就是说，外部 fork PR 到 `rcore-os/tgoskits` 后，与 rcore 组织内分支/PR 使用相同的测试集合；但不同测试通过不同 label 调度到具备对应能力的 runner。

调度原则是按资源能力分发，而不是两个服务器完全随机分发：

```text
普通可迁移测试
  -> 第一阶段由 10.0.20.39 承接
Axvisor x86_64 KVM/VMX 测试
  -> 只发到 10.3.10.194 的 KVM/Intel runner

board 测试
  -> 只发到 10.3.10.194 的 board runner
```

### 3.2 fork 仓库自己的流程

```text
GitHub Actions 调度
  └── 普通测试
        └── runs-on: ubuntu-latest
              └── ghcr.io/rcore-os/tgoskits-container:latest
```

fork 仓库自己的 CI 不应调度到：

```text
self-hosted, linux, tgoskits
self-hosted, linux, board
self-hosted, linux, kvm
self-hosted, linux, tgoskits, qemu, kvm, intel
```

这样可以避免外部 fork 仓库直接使用 rcore 自有机器。外部 fork PR 到 rcore 主仓时，通过 rcore 主仓 workflow 使用 self-hosted runner，而不是让 fork 仓库直接拥有 self-hosted runner 调度能力。

fork 仓库自己的 CI 保持原有流程：继续运行原本在 GitHub-hosted 上执行的普通测试，例如：

```text
clippy
sync-lint
std
ArceOS 普通 QEMU
StarryOS 普通 QEMU
Axvisor aarch64/riscv64/loongarch64 普通 QEMU
```

fork 仓库自己的 CI 继续跳过当前这些 self-hosted 测试：

```text
Axvisor x86_64 KVM/VMX QEMU 测试
  -> 需要 /dev/kvm、-accel kvm、-cpu host、vmx/svm 后端

Axvisor board 测试
  -> 需要 10.3.10.194 上的真实开发板、串口、TFTP、电源控制等资源

Starry board 测试
  -> 需要 10.3.10.194 上的真实开发板、串口、TFTP、电源控制等资源
```

因此 fork 仓库自己的 CI 跳过 self-hosted 部分是合理的。优化方案不改变 fork 仓库自己的 CI 覆盖范围，只改变 rcore 主仓 workflow 中普通测试的承载位置。

## 4. runner label 规划

建议重新规划 self-hosted runner label。目标是让调度表达资源能力，而不是只表达机器类型。

### 4.1 普通 runner

第一阶段只在 `10.0.20.39` 上注册普通 runner：

```text
self-hosted
linux
tgoskits
qemu
```

这类 runner 用于承接原 GitHub-hosted 普通测试。workflow 只需要写：

```yaml
runs-on: [self-hosted, linux, tgoskits, qemu]
```

第一阶段只有 `10.0.20.39` 配置这组普通 label，因此普通测试会落到 `10.0.20.39`。

`10.0.20.39` 当前检查结果显示：

```text
没有 /dev/kvm
CPU flags 中没有 vmx/svm
当前不适合承接 Axvisor x86_64 KVM/VMX 测试
```

因此不要给 `10.0.20.39` 的 runner 打以下 label：

```text
kvm
intel
amd
board
```

否则 GitHub Actions 可能把 KVM/board job 派到 `10.0.20.39`，导致失败。

### 4.2 10.3.10.194 KVM/VMX runner

当前已有的 `Test axvisor self-hosted x86_64` 属于 KVM/VMX 类测试，而不是普通 QEMU 测试。当前方案统一使用能力更明确的 label：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu","kvm","intel"]'
```

只有 10.3.10.194 上确实具备 `/dev/kvm`、VMX 和容器 KVM 透传的 runner 才应该打这些 label。

如果将来需要 AMD SVM 测试，可以使用：

```yaml
runs-on: [self-hosted, linux, tgoskits, qemu, kvm, amd]
```

在当前目标下，外部 fork PR 到 `rcore-os/tgoskits` 后与 rcore 组织内分支/PR 使用相同 label。也就是说，不再默认按 PR 来源拆分 `trusted` / `external-pr` 两套普通 runner。

### 4.3 10.3.10.194 board runner

开发板 runner 继续只放在 10.3.10.194 上，并使用现有 board 相关 label 承接 board 测试。

```text
board
```

现有实现中，满足 `board` label 的 runner 会作为 board 测试资源池使用。GitHub Actions 会把 job 分配给空闲 runner；没有空闲 runner 时，job 会等待。这种“资源空闲则执行、资源不足则排队”的行为是合理的，不需要在本方案中额外优化。

## 5. 环境一致性策略

当前阶段建议采用和 `10.3.10.194` 已有实现一致的方式：

```text
服务器预先启动多个 runner Docker 容器；
每个 runner 容器注册成一个 GitHub self-hosted runner；
GitHub Actions 把 job 分发给空闲 runner；
测试命令直接在该 runner 容器内执行；
job 内部不再额外启动 GitHub Actions container。
```

也就是说，当前阶段的 self-hosted 流程不是：

```text
self-hosted runner
  -> GitHub Actions job-level container
       -> ghcr.io/rcore-os/tgoskits-container:latest
```

而是：

```text
self-hosted runner Docker container
  -> cargo xtask ...
```

这里的 runner Docker container 本身就是测试环境。环境一致性通过维护统一的 runner 镜像实现，而不是通过每个 job 再进入 `tgoskits-container` 实现。

### 5.1 为什么这种方式合理

这种方式和 `10.3.10.194` 当前运行方式一致，迁移风险更小：

- `10.3.10.194` 上现有 KVM/VMX 和 board 测试已经是“runner 容器内直接执行命令”。
- board 测试涉及串口、TFTP、电源控制、host network、设备节点等资源，避免再套一层 job-level container 可以减少 Docker-in-Docker 或 Docker-outside-of-Docker 的复杂度。
- KVM/VMX 测试需要 `/dev/kvm`、正确的 group 权限和宿主 CPU 虚拟化能力，直接在预配置好的 runner 容器内执行更容易控制。
- `10.0.20.39` 第一阶段只跑普通测试，不需要 KVM/board 设备透传，但同样可以使用相同 runner 容器管理方式，便于两台服务器统一运维。

需要明确的是，这种方式不会让 self-hosted 流程和 fork 仓库 GitHub-hosted 流程做到“同一个运行时容器”。fork 仓库自己的 CI 仍使用：

```text
runs-on: ubuntu-latest
container: ghcr.io/rcore-os/tgoskits-container:latest
```

rcore 主仓 self-hosted 流程使用：

```text
runs-on: [self-hosted, linux, tgoskits, qemu]
不设置 job-level container
测试命令直接在 qc-actions-runner 容器内执行
```

因此当前阶段的环境一致性目标是：

```text
让 qc-actions-runner 镜像尽量模仿 tgoskits-container 的基础依赖；
而不是强行让 self-hosted job 运行在 tgoskits-container 内。
```

### 5.2 需要对齐的 runner 镜像内容

需要修改 `github-runners/Dockerfile`，生成新的 runner 镜像，例如：

```text
qc-actions-runner:v0.0.2
```

该镜像应以 `tgoskits-container` 为参考，对齐普通测试需要的基础环境：

- QEMU 版本和 target 支持。
- Rust toolchain、targets、components。
- musl 交叉工具链。
- `cargo-binutils`、`cargo-clone` 等 cargo 工具。
- clippy、rustfmt、llvm-tools、rust-src。
- tgoskits 普通测试需要的系统包。

同时保留 runner 自身需要的内容：

- GitHub Actions runner 运行环境。
- `config.sh`、`run.sh` 等 runner 入口。
- Docker Compose 管理所需约定。
- KVM/board runner 需要的额外依赖，例如 `udev`、`dialout`、`kvm` 组、设备访问相关工具。

当前 `github-runners/Dockerfile` 的基础镜像是：

```dockerfile
FROM ghcr.io/actions/actions-runner:latest
```

这个镜像是 GitHub 官方 self-hosted runner 的容器镜像，只负责提供 runner 进程和基础运行环境。它不是：

```text
ghcr.io/rcore-os/tgoskits-container:latest
```

也不是：

```text
ghcr.io/rcore-os/tgoskits-container-axvisor-lvz:latest
```

`qc-actions-runner:v0.0.1` / `v0.0.2` 是基于 `ghcr.io/actions/actions-runner:latest` 额外安装 QEMU、Rust、musl、系统依赖后得到的 runner 镜像。当前阶段应维护这个 runner 镜像，使它尽量接近 `tgoskits-container` 的测试依赖集合。

### 5.3 workflow 侧的直接影响

迁移到 self-hosted 的普通测试，在当前阶段应使用 `run_host` 路径，而不是 `run_container` 路径。

也就是说，rcore 主仓 self-hosted 普通测试应满足：

```text
use_container: false
runs_on: '["self-hosted","linux","tgoskits","qemu"]'
```

命令直接在 runner 容器里执行。

fork 仓库自己的 GitHub-hosted 普通测试继续保持：

```text
use_container: true
runs_on: '["ubuntu-latest"]'
container_image: ghcr.io/rcore-os/tgoskits-container:latest
```

这样可以保持原有 fork CI 行为，同时让 rcore 主仓耗时普通测试迁出 GitHub-hosted runner。

### 5.4 `github-runners` 的作用

`github-runners` 仓库不是 tgoskits 的测试代码，它是服务器侧 runner 的部署和管理工具。它负责：

- 读取 `.env` 中的组织、仓库、token、镜像、label、runner 数量等配置。
- 根据 `Dockerfile` 构建或选择 runner 镜像。
- 生成 Docker Compose 文件。
- 启动多个 runner 容器。
- 向 GitHub 注册这些 runner。
- 管理 runner 生命周期，例如 start、stop、restart、list、rm、purge。

它的核心流程是：

```text
./runner.sh init -n N
  -> 读取 .env
  -> 获取 GitHub registration token
  -> shell_prepare_runner_image 选择或构建 runner 镜像
  -> shell_generate_compose_file 生成 docker-compose.<org>.yml
  -> docker compose up -d 启动 N 个普通 runner 容器
  -> docker_runner_register 把容器注册到 GitHub
```

镜像选择沿用 `github-runners` 原流程：通过 `RUNNER_CUSTOM_IMAGE` 指定自定义 runner 镜像，由 `./runner.sh init` 负责构建或选择该镜像，并写入生成的 compose 文件。

### 5.5 10.0.20.39 的 github-runners 配置建议

`10.0.20.39` 第一阶段只作为普通 runner 池，不承接 KVM/VMX 和 board 测试。因此 `.env` 应体现这个边界：

```bash
ORG=rcore-os
GH_PAT=<github classic pat>
RUNNER_CUSTOM_IMAGE=qc-actions-runner:v0.0.2
RUNNER_LABELS=tgoskits,qemu
RUNNER_BOARD_COUNT=0
```

部署后只需要检查生成的 compose 文件，确认 `image:` 为 `qc-actions-runner:v0.0.2`。

初始化命令建议为：

```bash
cd github-runners
./runner.sh init -n 32
./runner.sh list
```

稳定后可调整为 64 个普通 runner 进行压力测试。

`10.0.20.39` 不应配置以下 label：

```text
kvm
intel
amd
board
```

原因是该服务器当前没有 `/dev/kvm`，CPU flags 中也没有 `vmx/svm`，不能承接 Axvisor x86_64 KVM/VMX 测试；同时它也没有实际开发板资源。

还需要注意 `github-runners/runner.sh` 当前实现的一个部署细节：普通 runner 的 compose 生成逻辑会固定写入：

```yaml
devices:
  - /dev/loop-control:/dev/loop-control
  - /dev/loop0:/dev/loop0
  - /dev/loop1:/dev/loop1
  - /dev/loop2:/dev/loop2
  - /dev/loop3:/dev/loop3
  - /dev/kvm:/dev/kvm
group_add:
  - <kvm_gid>
```

这适合 `10.3.10.194`，因为该机器有 `/dev/kvm`。但 `10.0.20.39` 当前没有 `/dev/kvm`，因此第一阶段在 39 上部署普通 runner 前，需要调整 `github-runners`：

```text
普通 runner 的 devices/group_add 应可配置；
没有 /dev/kvm 的机器不应强制映射 /dev/kvm；
只有 KVM runner 才需要 /dev/kvm 和 kvm group。
```

必须修改 `github-runners/runner.sh`，增加类似配置：

```bash
RUNNER_DEVICES=/dev/loop-control,/dev/loop0,/dev/loop1,/dev/loop2,/dev/loop3
RUNNER_GROUP_ADD=
```

并让 `shell_generate_compose_file` 生成普通 runner 时使用这些变量。对于 `10.3.10.194` 的 KVM runner，可以继续配置：

```bash
RUNNER_DEVICES=/dev/loop-control,/dev/loop0,/dev/loop1,/dev/loop2,/dev/loop3,/dev/kvm
RUNNER_GROUP_ADD=<kvm_gid>
```

### 5.6 10.3.10.194 的 github-runners 现状

`10.3.10.194` 当前已经采用 `github-runners` 这类模式：宿主机上预启动多个 runner 容器，每个容器注册成 GitHub self-hosted runner。

当前观测到的 runner 容器使用镜像：

```text
qc-actions-runner:v0.0.1
```

普通 KVM/VMX runner：

```text
s1lqc-rcore-os-runner-1
...
s1lqc-rcore-os-runner-10
```

主要 label：

```text
intel
```

board runner：

```text
s1lqc-rcore-os-runner-board-1
...
s1lqc-rcore-os-runner-board-10
```

主要 label：

```text
board
```

这些容器运行在宿主机 Docker 上，使用 `network_mode: host`、`privileged: true`，并把 `/dev/kvm`、loop device 等设备映射进容器。board runner 还额外加入 `dialout` 等组，以便访问串口类设备。

这说明当前 self-hosted 的基本实现已经是：

```text
宿主机 Docker
  -> 多个长期运行的 runner 容器
      -> 每个容器承接一个 GitHub Actions job
      -> job 命令直接在容器内执行
```

`10.0.20.39` 应复用这种实现方式，只是 label 和 runner 数量不同。

### 5.7 当前阶段不采用 job-level container

当前阶段不把 self-hosted job 改成：

```yaml
runs-on: [self-hosted, linux, tgoskits, qemu]
container:
  image: ghcr.io/rcore-os/tgoskits-container:latest
```

原因是当前 runner 本身已经运行在 Docker 容器中。再启用 job-level `container:` 会引入额外问题：

- 需要决定 runner 容器内是否挂载 Docker socket。
- 可能形成 Docker-outside-of-Docker 或 Docker-in-Docker。
- KVM、串口、host network、udev、TFTP 等资源需要重新透传到 job container。
- board 测试的设备访问和清理逻辑需要重新验证。
- 当前 194 已有稳定实现会被扩大改动面。

因此当前结论是：

```text
短期采用预启动 runner 容器 + 命令直接执行；
通过 qc-actions-runner:v0.0.2 对齐测试依赖；
job-level tgoskits-container 仅作为后续优化方向。
```

### 5.8 环境统一实施设计

当前阶段的“统一环境”不是让所有 job 都进入同一个 `tgoskits-container`，而是建立一个明确的环境基准，并让 self-hosted runner 镜像成为这个基准的超集。

基准环境定义为：

```text
tgoskits/container/Dockerfile
  -> ghcr.io/rcore-os/tgoskits-container:latest
  -> 普通测试依赖基准

tgoskits/container/Dockerfile.axvisor-lvz
  -> ghcr.io/rcore-os/tgoskits-container-axvisor-lvz:latest
  -> Axvisor loongarch64 LVZ 测试扩展基准

github-runners/Dockerfile
  -> qc-actions-runner:v0.0.2
  -> GitHub runner 能力 + tgoskits 测试依赖 + KVM/board 额外依赖
```

也就是说，`qc-actions-runner:v0.0.2` 不应该是另一个随意维护的环境，而应该是：

```text
ghcr.io/actions/actions-runner:latest
  + tgoskits-container 的普通测试依赖
  + GitHub runner 所需入口和运行环境
  + KVM/board/self-hosted 额外依赖
```

不能反过来把 `github-runners` 的 `RUNNER_IMAGE` 直接改成 `ghcr.io/rcore-os/tgoskits-container:latest`，因为 `tgoskits-container` 是测试环境镜像，不是 runner 镜像，通常不包含 `config.sh`、`run.sh`、Runner.Listener、Runner.Worker 等 self-hosted runner 入口。

### 5.9 当前差异和 v0.0.2 目标

当前已知差异：

```text
tgoskits-container:
  base: ubuntu:24.04
  QEMU: 10.2.1
  Rust: rust-toolchain.toml 中的 nightly-2026-04-27
  targets:
    x86_64-unknown-none
    riscv64gc-unknown-none-elf
    aarch64-unknown-none-softfloat
    loongarch64-unknown-none-softfloat
  components:
    rust-src
    llvm-tools
    rustfmt
    clippy
  includes:
    qemu-user-static
    aarch64/riscv64/x86_64/loongarch64 musl cross toolchains

qc-actions-runner:v0.0.1:
  base: ghcr.io/actions/actions-runner:latest
  QEMU: 10.1.2
  Rust: nightly + nightly-2026-04-01 + nightly-2026-02-25
  includes:
    musl cross toolchains
    cargo-binutils
    cargo-clone
    KVM/board/runner 相关依赖
```

`qc-actions-runner:v0.0.2` 的目标：

```text
base:
  仍然使用 ghcr.io/actions/actions-runner:latest

QEMU:
  对齐到 10.2.1
  target-list 对齐 tgoskits/container/Dockerfile
  保留 KVM runner 需要的 KVM 支持
  安装 qemu-user-static

Rust:
  使用 rust-toolchain.toml 作为唯一来源
  默认 toolchain 对齐 nightly-2026-04-27
  targets/components 与 rust-toolchain.toml 一致

musl:
  aarch64/riscv64/x86_64/loongarch64 安装逻辑与 tgoskits-container 保持一致

系统包:
  以 tgoskits-container 的 apt 包为基准
  额外保留 runner、KVM、board 测试需要的包和权限

runner 能力:
  保留 GitHub self-hosted runner 入口
  保留 runner 用户
  保留 dialout/kvm 组配置
  保留 host network / privileged / device mount 的部署能力
```

### 5.10 需要修改的代码位置

需要修改 `github-runners/Dockerfile`：

```text
1. QEMU_VERSION 从 10.1.2 改为 10.2.1。
2. QEMU configure 增加明确 target-list，对齐 tgoskits/container/Dockerfile。
3. 安装 qemu-user-static。
4. Rust 安装逻辑改为读取/复制 tgoskits 的 rust-toolchain.toml。
5. 移除或弱化手工维护的 nightly-2026-04-01 / nightly-2026-02-25，避免和仓库 toolchain 漂移。
6. targets/components 使用 rust-toolchain.toml 中的定义。
7. apt 包集合改为 tgoskits-container 依赖 + runner/KVM/board 额外依赖的并集。
8. 保留 cargo-binutils、cargo-clone。
9. 保留 runner 用户加入 dialout/kvm 组。
```

需要修改 `github-runners/runner.sh`：

```text
1. 普通 runner 的 devices/group_add 改成可配置。
2. 没有 /dev/kvm 的 10.0.20.39 不强制映射 /dev/kvm。
3. KVM runner 或 10.3.10.194 需要 KVM 时，再显式配置 /dev/kvm。
4. 确认 init/compose 生成的 image 使用 qc-actions-runner:v0.0.2。
```

需要修改 `tgoskits/.github/workflows/ci.yml`：

```text
1. rcore 主仓迁移到 self-hosted 的普通测试：
   runs_on: '["self-hosted","linux","tgoskits","qemu"]'
   use_container: false

2. fork 仓库自己的普通测试：
   runs_on: '["ubuntu-latest"]'
   use_container: true
   container_image: base 或 axvisor-lvz

3. 当前 self-hosted 特殊测试继续保持：
   Axvisor x86_64 KVM/VMX -> 10.3.10.194
   Axvisor board -> 10.3.10.194
   Starry board -> 10.3.10.194
```

### 5.11 环境校验方法

当前阶段环境校验作为部署检查执行，不新增持续运行的环境校验 CI job。部署检查对象至少包括：

```text
ghcr.io/rcore-os/tgoskits-container:latest
ghcr.io/rcore-os/tgoskits-container-axvisor-lvz:latest
qc-actions-runner:v0.0.2
```

校验内容：

```bash
rustc --version
cargo --version
rustup show active-toolchain
rustup target list --installed
qemu-system-aarch64 --version
qemu-system-riscv64 --version
qemu-system-x86_64 --version
qemu-system-loongarch64 --version
qemu-aarch64-static --version
qemu-riscv64-static --version
qemu-x86_64-static --version
qemu-loongarch64-static --version
aarch64-linux-musl-cc --version
riscv64-linux-musl-cc --version
x86_64-linux-musl-cc --version
loongarch64-linux-musl-cc --version
cargo binutils --version 或 cargo objcopy --version
cargo clone --version
```

对于 self-hosted runner，还应额外校验：

```bash
id
groups
test -e /dev/kvm && ls -l /dev/kvm || true
command -v /home/runner/run.sh || true
```

39 普通 runner 的校验预期是：

```text
不要求 /dev/kvm 存在。
不要求 vmx/svm 存在。
必须具备普通 QEMU、Rust、musl、qemu-user-static 等普通测试依赖。
```

194 KVM/board runner 的校验预期是：

```text
必须具备 /dev/kvm 和对应权限。
board runner 必须具备串口/设备访问权限。
必须保留 host network / privileged / device mount 能力。
```

### 5.12 环境统一的发布和回滚策略

不要直接覆盖 `qc-actions-runner:v0.0.1`。推荐流程：

```text
1. 构建 qc-actions-runner:v0.0.2。
2. 在 10.0.20.39 上启动少量 canary runner。

3. 先跑普通测试：
   clippy
   sync-lint
   std
   ArceOS 普通 QEMU
   StarryOS 普通 QEMU
   Axvisor aarch64/riscv64/loongarch64 普通 QEMU
4. 普通测试稳定后，再扩大到 32 个 runner。
5. 32 个 runner 稳定后，再尝试 64 个 runner。
6. 64 个 runner 压测稳定后，再把 qc-actions-runner:v0.0.2 迁移到 10.3.10.194。
7. 在 10.3.10.194 上先升级少量 canary runner，验证：
   Axvisor x86_64 KVM/VMX 测试
   Axvisor board 测试
   Starry board 测试
8. 194 canary 稳定后，逐步替换 194 上剩余 KVM/board runner。
9. 两台服务器都稳定后，再删除 qc-actions-runner:v0.0.1。
```

这里需要特别强调：

```text
v0.0.2 是为了统一普通测试环境。
最终也要迁移到 194，统一 KVM/board runner 的基础依赖。
但 194 升级必须发生在 39 普通测试和 64 runner 压测稳定之后。
迁移到 194 时不改变已有 KVM/board 的执行语义，只替换 runner 镜像环境。
不是为了让 self-hosted job 进入 job-level container。
不是为了让 39 承接 KVM/board 测试。
```

## 6. workflow 分流策略

核心要求：

```text
workflow 运行在 rcore-os/tgoskits 主仓上下文时使用 self-hosted；
workflow 运行在外部 fork 仓库自身上下文时使用 GitHub-hosted。
```

可以通过 `github.repository` 判断当前 workflow 属于主仓还是 fork 仓库。

当前已有的 `required_repository_owner: rcore-os` 机制应继续保留，作为第一层保护：

```yaml
required_repository_owner: rcore-os
```

普通测试迁移到 self-hosted 后，不再排除外部 fork PR。判断条件应变为：

```text
当前仓库必须是 rcore-os/tgoskits；
不要求 pull_request 的 head repo 也是 rcore-os/tgoskits。
```

### 6.1 判断是否使用 rcore self-hosted

推荐定义条件：

```yaml
${{ github.repository == 'rcore-os/tgoskits' }}
```

含义：

- 当前仓库必须是 `rcore-os/tgoskits`。
- `rcore-os/tgoskits` 的 push 满足该条件。
- `rcore-os/tgoskits` 内部 PR 满足该条件。
- 外部 fork 提到 `rcore-os/tgoskits` 的 PR 也满足该条件，因为 workflow 在主仓上下文中运行。
- fork 仓库自己运行 CI 时不满足该条件。

这个条件保留了“非 rcore 仓库自己的 CI 不使用 self-hosted”的既有设计，同时允许外部 fork PR 到 rcore 主仓时使用服务器测试。

需要注意：fork 仓库自己的 GitHub-hosted 流程不是 self-hosted 流程的完整替代。它应覆盖普通可迁移测试，但继续跳过当前 self-hosted 三项：

```text
Test axvisor self-hosted x86_64
Test axvisor self-hosted board orangepi-5-plus-linux
Test starry self-hosted board orangepi-5-plus
```

原因分别是 KVM/VMX 能力依赖和真实物理板依赖。

### 6.2 推荐实现：共享测试定义 + 两条显式执行路径

推荐不要在 `ci.yml` 中手写两份完整测试矩阵，也不要把所有分流逻辑塞进一个复杂 matrix 表达式中。更合适的方式是：

```text
测试项只定义一份；
rcore / fork 两套 job 仍然分开；
CI 运行时自动把同一份测试定义生成两套 matrix。
```

推荐新增一个测试定义文件：

```text
.github/ci/test-matrix.yml
```

该文件只描述“测什么”，不直接描述每条路径怎么调度。示例：

```yaml
tests:
  - name: Test arceos x86_64 qemu
    command: cargo xtask arceos test qemu --arch x86_64
    cache_key: test-arceos-x86_64
    capability: normal
    container_image: base
    apk_region: us
    rcore: true
    fork: true

  - name: Test axvisor loongarch64 qemu
    command: cargo xtask axvisor test qemu --arch loongarch64
    cache_key: test-axvisor-loongarch64
    capability: normal
    container_image: axvisor-lvz
    apk_region: us
    rcore: true
    fork: true

  - name: Test axvisor self-hosted x86_64
    command: cargo xtask axvisor test qemu --arch x86_64
    cache_key: ""
    capability: kvm-intel
    rcore: true
    fork: false

  - name: Test starry self-hosted board orangepi-5-plus
    command: cargo xtask starry test board --board orangepi-5-plus
    cache_key: ""
    capability: board
    rcore: true
    fork: false
```

再新增一个生成脚本：

```text
scripts/ci/generate_matrix.py
```

该脚本在 CI 运行时自动执行，不需要开发者每次手动运行，也不需要提交生成后的 matrix 文件。新增测试项时只需要修改：

```text
.github/ci/test-matrix.yml
```

然后 CI 自动执行：

```text
generate_ci_matrix job
  -> python3 scripts/ci/generate_matrix.py .github/ci/test-matrix.yml
  -> 输出 rcore_matrix
  -> 输出 fork_matrix
  -> 输出 fallback_matrix
```

生成规则：

```text
capability: normal
  rcore -> runs_on: ["self-hosted","linux","tgoskits","qemu"], use_container: false
  fork  -> runs_on: ["ubuntu-latest"], use_container: true
  fallback -> runs_on: ["ubuntu-latest"], use_container: true

capability: kvm-intel
  rcore -> runs_on: ["self-hosted","linux","tgoskits","qemu","kvm","intel"], use_container: false
  fork  -> 跳过
  fallback -> 跳过

capability: board
  rcore -> runs_on: ["self-hosted","linux","board"], use_container: false
  fork  -> 跳过
  fallback -> 跳过
```

`container_image` 的含义：

```text
rcore self-hosted:
  当前阶段 use_container=false，因此普通测试不会进入 container_image。
  该字段主要用于 fork GitHub-hosted 路径和手动 fallback 路径。

fork GitHub-hosted:
  container_image=base -> ghcr.io/rcore-os/tgoskits-container:latest
  container_image=axvisor-lvz -> ghcr.io/rcore-os/tgoskits-container-axvisor-lvz:latest
```

workflow 结构保持两条路径：

```yaml
generate_ci_matrix:
  runs-on: ubuntu-latest
  outputs:
    rcore_matrix: ${{ steps.gen.outputs.rcore_matrix }}
    fork_matrix: ${{ steps.gen.outputs.fork_matrix }}
    fallback_matrix: ${{ steps.gen.outputs.fallback_matrix }}
  steps:
    - uses: actions/checkout@v6
    - id: gen
      run: |
        python3 scripts/ci/generate_matrix.py .github/ci/test-matrix.yml >> "$GITHUB_OUTPUT"
```

```yaml
post_fmt_checks_rcore:
  if: >-
    ${{
      needs.detect_changes.outputs.ci_checks == 'true'
      && github.repository == 'rcore-os/tgoskits'
    }}
  needs:
    - detect_changes
    - fmt
    - generate_ci_matrix
  strategy:
    matrix:
      include: ${{ fromJson(needs.generate_ci_matrix.outputs.rcore_matrix) }}
  uses: ./.github/workflows/reusable-command.yml
```

```yaml
post_fmt_checks_fork:
  if: >-
    ${{
      needs.detect_changes.outputs.ci_checks == 'true'
      && github.repository != 'rcore-os/tgoskits'
    }}
  needs:
    - detect_changes
    - fmt
    - generate_ci_matrix
  strategy:
    matrix:
      include: ${{ fromJson(needs.generate_ci_matrix.outputs.fork_matrix) }}
  uses: ./.github/workflows/reusable-command.yml
```

手动 fallback 路径只通过 `workflow_dispatch` 触发，用于 self-hosted 普通 runner 出现故障时临时恢复普通测试。它不作为默认路径，不自动 fallback，也不运行 KVM/board 测试。

```yaml
post_fmt_checks_fallback:
  if: >-
    ${{
      github.event_name == 'workflow_dispatch'
      && github.event.inputs.ci_target == 'github-hosted-fallback'
    }}
  needs:
    - detect_changes
    - fmt
    - generate_ci_matrix
  strategy:
    matrix:
      include: ${{ fromJson(needs.generate_ci_matrix.outputs.fallback_matrix) }}
  uses: ./.github/workflows/reusable-command.yml
```

`ci.yml` 仍然存在，并且仍然是主 workflow 文件。`test-matrix.yml` 不替代 `ci.yml`，只替代 `ci.yml` 里原来手写的大段 `strategy.matrix.include` 测试项列表。

迁移后文件职责如下：

```text
.github/workflows/ci.yml
  -> workflow 入口
  -> 触发条件
  -> detect_changes
  -> fmt
  -> generate_ci_matrix job
  -> post_fmt_checks_rcore
  -> post_fmt_checks_fork
  -> post_fmt_checks_fallback
  -> container publish jobs

.github/ci/test-matrix.yml
  -> 唯一测试项定义
  -> name / command / cache_key / capability / container_image / apk_region / fetch_depth 等字段

scripts/ci/generate_matrix.py
  -> 读取 test-matrix.yml
  -> 生成 rcore_matrix / fork_matrix / fallback_matrix
  -> 根据 capability 映射 runs_on、use_container、container_image

.github/workflows/reusable-command.yml
  -> 实际执行单个测试命令
  -> 根据 use_container 选择 run_host 或 run_container
```

这样有两个优点：

```text
1. 测试项只维护一份。
   新增、删除、修改测试命令，只改 .github/ci/test-matrix.yml。

2. rcore / fork 执行路径仍然分开。
   workflow 中仍能清楚看到 post_fmt_checks_rcore 和 post_fmt_checks_fork。
```

### 6.3 为什么不直接手写两套 matrix

直接手写：

```text
post_fmt_checks_rcore
post_fmt_checks_fork
```

也能实现目标，但会带来长期维护问题：

```text
同一个测试命令需要在两套 matrix 中各写一次；
新增测试项时要同时改 rcore 和 fork；
调整 cache_key、apk_region、fetch_depth 时也要同步两边；
review 时需要检查两套矩阵是否语义一致；
长期容易出现 rcore 和 fork 测试集合漂移。
```

因此当前推荐方案不是“完全手写两套 matrix”，而是：

```text
共享测试定义文件；
CI 自动生成两套 matrix；
workflow 保留两条显式 job 路径。
```

## 7. 推荐修改步骤

### 阶段 1：新增第二台服务器 runner

在第二台服务器上部署 `github-runners`：

- 安装 Docker 和 Docker Compose。
- 构建或拉取统一的 runner 镜像。
- 注册到 `rcore-os`。
- 配置 label：

```text
self-hosted, linux, tgoskits, qemu
```

`10.0.20.39` 当前没有 `/dev/kvm` 和 `vmx/svm`，因此不要配置：

```text
kvm
intel
amd
board
```

10.3.10.194 继续保留 KVM/VMX 和 board runner，但 KVM/VMX runner 需要统一为能力 label：

```text
self-hosted, linux, tgoskits, qemu, kvm, intel
```

### 阶段 2：对齐 runner 镜像环境

修改 `github-runners/Dockerfile`，生成：

```text
qc-actions-runner:v0.0.2
```

对齐内容：

- QEMU 10.2.1
- Rust toolchain
- musl 交叉工具链
- `tgoskits-container` 的系统依赖
- 保留 runner/board/KVM 额外依赖

先在少量 runner 上灰度：

```text
s1lqc-rcore-os-runner-canary-1
```

验证通过后再批量替换。

### 阶段 3：共享测试定义并拆分 rcore / fork 执行路径

新增统一测试定义文件：

```text
.github/ci/test-matrix.yml
```

新增 CI 运行时生成脚本：

```text
scripts/ci/generate_matrix.py
```

开发者新增测试项时，只修改：

```text
.github/ci/test-matrix.yml
```

不需要手动运行脚本，也不提交生成后的 matrix。CI 自动运行 `generate_ci_matrix` job，生成：

```text
rcore_matrix
fork_matrix
```

然后在 `ci.yml` 中保留两条显式路径：

```text
post_fmt_checks_rcore
  -> 使用 rcore_matrix
  -> 只在 rcore-os/tgoskits 主仓 workflow 中运行
  -> self-hosted

post_fmt_checks_fork
  -> 使用 fork_matrix
  -> 只在 fork 仓库自己的 workflow 中运行
  -> GitHub-hosted
```

rcore job 条件：

```yaml
if: >-
  ${{
    needs.detect_changes.outputs.ci_checks == 'true'
    && github.repository == 'rcore-os/tgoskits'
  }}
```

rcore 的 self-hosted 矩阵项仍应保留：

```yaml
required_repository_owner: rcore-os
```

这不是替代 `if` 条件，而是防御性冗余：即使后续有人调整 job 级别 `if`，复用 workflow 内部仍会拒绝非 `rcore-os` owner 使用 self-hosted 路径。

fork 仓库自身流程条件：

```yaml
if: >-
  ${{
    needs.detect_changes.outputs.ci_checks == 'true'
    && github.repository != 'rcore-os/tgoskits'
  }}
```

这样分流后：

```text
外部 fork 仓库自己 push / PR
  -> github.repository != 'rcore-os/tgoskits'
  -> 使用 GitHub-hosted

外部 fork 提 PR 到 rcore-os/tgoskits
  -> workflow 运行在 rcore-os/tgoskits
  -> github.repository == 'rcore-os/tgoskits'
  -> 使用 post_fmt_checks_rcore
  -> 使用 self-hosted
```

### 阶段 4：普通测试迁到 self-hosted

rcore 主仓普通测试使用：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu"]'
```

第一阶段只有 `10.0.20.39` 配置 `self-hosted, linux, tgoskits, qemu` 普通 label，因此这些 job 会落到 `10.0.20.39`。

KVM/VMX 测试继续使用 10.3.10.194 专用能力 label：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu","kvm","intel"]'
```

外部 fork 提到 `rcore-os/tgoskits` 的 PR 也使用同一套主仓 self-hosted 规则，不额外切到 `external-pr` label。

fork 仓库自身普通测试保持：

```yaml
runs_on: '["ubuntu-latest"]'
```

两边应尽量使用相同测试命令，但运行环境不同：

```text
rcore 主仓 self-hosted 普通测试
  -> use_container: false
  -> 直接在 qc-actions-runner 容器内执行

fork 仓库自己的 GitHub-hosted 普通测试
  -> use_container: true
  -> 进入 ghcr.io/rcore-os/tgoskits-container:latest 执行
```

因此当前阶段不能假设两边使用相同 job-level container。环境一致性依赖 `qc-actions-runner` 镜像尽量对齐 `tgoskits-container` 的依赖集合。当前已有 self-hosted 三项不应强行在 fork 仓库自己的 GitHub-hosted CI 中补跑。

迁移后应形成如下规则：

```text
rcore-os/tgoskits 内部分支
  -> 普通测试第一阶段使用 10.0.20.39 普通 runner
  -> KVM/VMX 测试使用 10.3.10.194 KVM runner
  -> board 测试使用 10.3.10.194 board runner

rcore-os/tgoskits 内部 PR
  -> 普通测试第一阶段使用 10.0.20.39 普通 runner
  -> KVM/VMX 测试使用 10.3.10.194 KVM runner
  -> board 测试使用 10.3.10.194 board runner

外部 fork 提到 rcore-os/tgoskits 的 PR
  -> 与 rcore 组织内分支/PR 使用相同测试集合和相同 label 规则

外部 fork 自己仓库中的 CI
  -> 普通可迁移测试使用 GitHub-hosted runner
  -> 当前 self-hosted 三项继续跳过
```

### 阶段 5：board 测试固定到 10.3.10.194

board 测试继续固定到 10.3.10.194 上对应的 runner。当前目标下，board 测试与其他 self-hosted 测试一样，只要 workflow 运行在 `rcore-os/tgoskits` 主仓上下文中就可以执行，包括：

```text
rcore-os/tgoskits push
rcore-os/tgoskits 内部 PR
外部 fork 提到 rcore-os/tgoskits 的 PR
```

这与当前实现一致：现有 self-hosted board 测试只有 `required_repository_owner: rcore-os` 限制，没有排除外部 fork PR。

```yaml
runs_on: '["self-hosted","linux","board"]'
```

## 8. 预期效果

### 8.1 对 rcore 主仓流程

预期效果：

- 大量耗时普通测试不再占用 GitHub-hosted 并发额度。
- 原 GitHub-hosted 普通测试第一阶段迁移到 `10.0.20.39` 普通 runner。
- 10.3.10.194 继续承接 Axvisor x86_64 KVM/VMX 测试。
- 10.3.10.194 继续承接开发板测试。
- CI 排队时间减少。
- self-hosted 环境与 `tgoskits-container` 更接近。
- 外部 fork PR 到 `rcore-os/tgoskits` 后，也可以由自有服务器承接与 rcore 组织内分支/PR 相同的测试集合；具体落在哪台服务器由 label 能力决定。

### 8.2 对 fork 仓库自己的 CI

预期效果：

- fork 仓库自己的 CI 不使用 rcore 自有服务器。
- fork 仓库自己的 CI 继续使用 GitHub-hosted runner。
- fork 仓库自己的 CI 仍使用 `ghcr.io/rcore-os/tgoskits-container:latest` 等测试镜像。
- fork 仓库自己的 CI 继续运行普通可迁移测试。
- fork 仓库自己的 CI 跳过当前 self-hosted 三项：Axvisor x86_64 KVM/VMX QEMU、Axvisor board、Starry board。
- fork 用户可以在自己的 GitHub 环境中复现类似 CI。

### 8.3 对安全性

安全边界变化：

- 外部 fork PR 到 rcore 主仓后，PR 代码会在 rcore self-hosted runner 上执行。
- 当前目标是外部 fork PR 与 rcore 组织内分支/PR 使用相同测试集合和 label 规则，因此 board、串口、TFTP、电源控制、KVM、Docker、host network 等资源如果被对应 job 使用，也可能被外部 PR 测试间接触达。
- 这是为了 CI 效率和覆盖率主动接受的风险。
- 后续仍建议通过 GitHub 的 fork PR 审批策略、runner 容器隔离、最小化 secrets、清理工作目录、限制网络访问等方式降低风险。

## 9. 风险与注意事项

1. **runner 镜像对齐不是完全统一**  
   即使 `qc-actions-runner:v0.0.2` 尽量模仿 `tgoskits-container`，它仍不是同一个镜像。

2. **label 设计很关键**  
   普通测试、KVM/VMX 测试、board 测试应使用能表达资源能力的 label，避免把特殊测试派到不具备能力的服务器。

3. **fork 仓库自身 CI 与 rcore 主仓 PR 分流必须严格**  
   fork 仓库自己的 CI 不应使用 rcore self-hosted runner。外部 fork PR 到 rcore 主仓则通过主仓 workflow 使用 self-hosted runner，并与 rcore 组织内分支/PR 使用相同测试集合和 label 规则。

4. **`latest` 镜像可能不是 PR 中 Dockerfile 修改后的环境**  
   如果 PR 修改 `container/Dockerfile`，仍需要后续考虑临时镜像验证。

5. **第二台服务器的能力要标注清楚**  
   是否有 KVM、是否有板卡、是否只跑普通 QEMU，需要通过 label 表达。当前 `10.0.20.39` 不应打 `kvm`、`intel`、`amd`、`board` label。

6. **外部 PR 使用 self-hosted 是主动接受的安全风险**  
   该方案的目标包含“PR 到 rcore 时也使用服务器测试，并与 rcore 组织内分支/PR 使用相同测试集合和 label 规则”，因此不能再用 PR head repo 判断排除 fork PR。风险控制应放在 GitHub 审批、runner 隔离、权限收敛、网络隔离和资源清理上。

7. **不要把普通测试池和特殊测试池混在一起**  
   当前主实现中，普通测试只迁到 `10.0.20.39`；Axvisor x86_64 KVM/VMX 和 board 测试继续只落到 10.3.10.194。不要给 `10.0.20.39` 打会匹配这些特殊 job 的 label。10.3.10.194 参与普通测试池只作为后续优化方案记录，当前主实现不包含该内容。

8. **不要把 KVM/VMX 测试误认为普通 QEMU 测试**  
   `cargo xtask axvisor test qemu --arch x86_64` 当前使用 `-accel kvm`、`-cpu host` 和 `vmx` 特性。它虽然不是物理板测试，但仍需要 self-hosted KVM runner；fork 仓库自己的 GitHub-hosted CI 不应默认运行它。

9. **环境统一不等于使用同一个运行时容器**  
   当前阶段 rcore 主仓 self-hosted 普通测试不进入 `tgoskits-container`。统一环境的方式是让 `qc-actions-runner:v0.0.2` 对齐 `tgoskits-container` 的测试依赖，并作为 self-hosted runner 的执行环境。实现时不要把 `RUNNER_IMAGE` 直接改成 `ghcr.io/rcore-os/tgoskits-container:latest`。

## 10. 已确定决策

以下内容已经确定，作为当前实现前提：

```text
1. 保留手动 GitHub-hosted fallback。
   - 默认路径仍是 rcore 主仓 self-hosted。
   - fallback 只通过 workflow_dispatch 手动触发。
   - fallback 只覆盖普通测试，不覆盖 KVM/board 测试。

2. github-runners 作为统一 runner 代码仓库。
   - 修改 github-runners 后提交代码。
   - 39 和 194 从同一仓库拉取一致代码。
   - 各服务器只做 .env、runner 数量、label、设备映射等本机适配。
   - 不要求把 qc-actions-runner:v0.0.2 推送到统一 registry。

3. 环境校验只作为部署检查。
   - 部署时确认 Rust/QEMU/musl/qemu-user-static 等依赖一致。
   - 后续环境一致性由人工维护和变更流程保证。
   - 当前不新增持续运行的环境校验 CI job。

4. .github/ci/test-matrix.yml 按功能完整表达当前测试矩阵。
   - 字段集合由现有 ci.yml matrix 的功能决定。
   - 至少覆盖 name、command、cache_key、capability、container_image、apk_region、rcore、fork、required_repository_owner、main_pr_only、fetch_depth。
   - 后续新增测试项时，如果现有字段无法表达，再随功能扩展字段。
```

## 11. 推荐结论

推荐采用分阶段方案：

```text
第一阶段：
  新增第二台服务器 runner。
  对齐 qc-actions-runner 环境到 tgoskits-container。
  10.0.20.39 注册普通 runner label。
  原 GitHub-hosted 普通测试优先迁到 10.0.20.39。
  Axvisor x86_64 KVM/VMX 和 board 测试继续留在 10.3.10.194。
  外部 fork PR 到 rcore 主仓也使用同一套主仓测试集合和 label 规则。
  fork 仓库自己的 CI 保持 GitHub-hosted，并继续跳过当前 self-hosted 三项。

后续优化：
  评估 10.3.10.194 是否新增独立普通 runner 加入普通测试池。
  评估 self-hosted 普通测试是否进入 tgoskits-container。
```

核心原则：

```text
GitHub 负责调度；
自有服务器负责承接 rcore 主仓耗时测试；
第一阶段普通测试优先由 10.0.20.39 承接；
Axvisor x86_64 KVM/VMX 和 board 测试继续固定到 10.3.10.194 对应能力 runner；
外部 fork PR 到 rcore 主仓也使用与 rcore 组织内分支/PR 相同的测试集合和 label 规则；
fork 仓库自己的 CI 继续走原有 GitHub-hosted 流程；
当前 self-hosted 三项在 fork 仓库自己的 CI 中继续跳过；
非 rcore 仓库自己的 workflow 不使用 self-hosted；
required_repository_owner 这类 owner guard 必须保留；
runner 镜像既负责接 job，也提供当前 self-hosted 测试执行环境；
self-hosted job 当前不使用 job-level container；
测试依赖通过 qc-actions-runner 镜像尽量与 tgoskits-container 保持一致。
```

## 12. 当前初步实施方案

当前建议先采用更保守的初步方案：

```text
10.3.10.194：
  保持原有 self-hosted 特殊测试不变。
  继续运行 Axvisor x86_64 KVM/VMX 测试。
  继续运行 Axvisor board 和 Starry board 测试。

10.0.20.39：
  新增普通 runner 池。
  承接原 GitHub-hosted 普通测试。
  不承接 KVM/VMX 测试。
  不承接 board 测试。
```

这样做的目的：

- 不影响 10.3.10.194 上已经稳定运行的 KVM/VMX 和 board 测试。
- 先把 GitHub-hosted 普通测试迁到 10.0.20.39，降低 GitHub 并发压力。
- 避免普通测试抢占 10.3.10.194 上的 KVM/VMX runner。
- 让迁移范围更小，便于回滚和定位问题。

### 12.1 10.0.20.39 runner 数量

`10.0.20.39` 当前资源情况：

```text
CPU: 96 vCPU
Memory: 442 GiB
KVM: 当前无 /dev/kvm，vmx=0，svm=0
用途: 普通测试 runner
```

建议初始 runner 数可以更激进一些，用于实际压力测试：

```text
第一轮：32 个普通 runner
第二轮：如果 CPU、内存、磁盘 IO、网络和 CI 稳定，再尝试 64 个普通 runner
```

需要观察的指标：

- CI 排队时间是否下降。
- 单个 job 耗时是否明显变长。
- CPU load 是否长期超过 vCPU 数。
- 内存是否出现明显 swap。
- 磁盘 IO 是否成为瓶颈。
- Cargo/cache/Docker overlay 是否出现异常。
- runner 是否频繁失败或卡住。

如果 64 个 runner 导致 job 耗时明显变长，建议回退到 32 或 48，再根据实际负载调整。

### 12.2 第一阶段 label 设计

10.0.20.39 普通 runner：

```text
self-hosted
linux
tgoskits
qemu
```

10.0.20.39 不应配置：

```text
kvm
intel
amd
board
```

10.3.10.194 KVM/VMX runner：

```text
self-hosted
linux
tgoskits
qemu
kvm
intel
```

10.3.10.194 现有 board runner：

```text
self-hosted
linux
board
```

board runner 保持现有 label。

### 12.3 第一阶段 workflow 调度

原 GitHub-hosted 普通测试迁移为：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu"]'
use_container: false
```

由于第一阶段只有 10.0.20.39 配置 `tgoskits,qemu` 普通 label，因此这些普通测试会优先落到 10.0.20.39。`use_container: false` 表示命令直接在预启动的 runner 容器中执行，不再进入 `ghcr.io/rcore-os/tgoskits-container:latest`。

原有 KVM/VMX 测试保持：

```yaml
runs_on: '["self-hosted","linux","tgoskits","qemu","kvm","intel"]'
```

原有 board 测试保持：

```yaml
runs_on: '["self-hosted","linux","board"]'
```

fork 仓库自己的 CI 保持原有流程：

```text
继续使用 GitHub-hosted。
继续跳过当前 self-hosted 三项。
```

## 13. 后续优化方案

后续优化中再评估更复杂的调度策略。该部分不是当前主实现内容。

```text
先保证 KVM/VMX 测试和 board 测试不被普通测试抢占。
普通测试优先分到 10.0.20.39。
如果 10.0.20.39 压力过大，再让 10.3.10.194 上额外普通 runner 加入普通测试池。
```

后续优化可采用：

```text
10.3.10.194 KVM/VMX runner:
  self-hosted, linux, tgoskits, qemu, kvm, intel

10.3.10.194 board runner:
  self-hosted, linux, board

10.3.10.194 额外普通 runner:
  self-hosted, linux, tgoskits, qemu

10.0.20.39 普通 runner:
  self-hosted, linux, tgoskits, qemu
```

10.3.10.194 上如果加入普通测试池，必须新增独立普通 runner，而不是复用现有 KVM/VMX runner。这样可以避免普通测试占用 KVM/VMX runner slot，导致 Axvisor x86_64 KVM/VMX 测试排队。

## 14. 当前实现边界

本节用于避免实现时把后续优化误当成当前目标。

### 14.1 当前必须实现

当前阶段只实现以下内容：

```text
1. 10.3.10.194 保持原有 self-hosted 特殊测试。
   - Axvisor x86_64 KVM/VMX 测试继续使用 10.3.10.194。
   - Axvisor board 测试继续使用 10.3.10.194。
   - Starry board 测试继续使用 10.3.10.194。

2. 10.0.20.39 新增普通 runner 池。
   - 承接原 GitHub-hosted 普通测试。
   - 初始建议 32 个普通 runner。
   - 稳定后可尝试 64 个普通 runner。

3. rcore-os/tgoskits 主仓 workflow 使用 self-hosted。
   - rcore 内部分支使用 self-hosted。
   - rcore 内部 PR 使用 self-hosted。
   - 外部 fork PR 到 rcore-os/tgoskits 后，也使用主仓 self-hosted 流程。

4. fork 仓库自己的 CI 保持原有流程。
   - 继续使用 GitHub-hosted。
   - 继续跳过当前 self-hosted 三项。

5. 10.0.20.39 使用 github-runners 预启动普通 runner 容器。
   - 使用 qc-actions-runner:v0.0.2 或等价的新 runner 镜像。
   - `RUNNER_LABELS=tgoskits,qemu`。
   - `RUNNER_BOARD_COUNT=0`。
   - 初始 `./runner.sh init -n 32`。
   - 普通 runner 不应强制映射不存在的 /dev/kvm。

6. rcore 主仓迁移到 self-hosted 的普通测试使用 run_host 路径。
   - `use_container: false`。
   - 不设置 job-level container。
   - 命令直接在 runner 容器内执行。

7. 使用共享测试定义生成 rcore/fork 两套 matrix。
   - 新增 `.github/ci/test-matrix.yml`。
   - 新增 `scripts/ci/generate_matrix.py`。
   - CI 自动运行 generate_ci_matrix job。
   - 新增测试项时只修改 `.github/ci/test-matrix.yml`。
   - 不提交生成后的 matrix 文件。
   - `post_fmt_checks_rcore` 和 `post_fmt_checks_fork` 保持两条显式路径。

8. 完成 self-hosted 普通 runner 环境统一。
   - 构建 qc-actions-runner:v0.0.2。
   - QEMU 对齐到 10.2.1。
   - Rust toolchain 对齐 rust-toolchain.toml。
   - musl 和 qemu-user-static 对齐 tgoskits-container。
   - 保留 GitHub runner、KVM、board 额外能力。
   - 增加环境校验，确认普通测试依赖一致。
   - 39 上 32 个 runner 稳定后，再测试 64 个 runner。
   - 64 个 runner 稳定后，再迁移升级 194。
   - 194 稳定后，再删除 qc-actions-runner:v0.0.1。
```

### 14.2 当前明确不实现

当前阶段不实现以下内容：

```text
1. 不让 10.3.10.194 现有 KVM/VMX runner 承接普通测试。
2. 不让 10.0.20.39 承接 KVM/VMX 测试。
3. 不让 10.0.20.39 承接 board 测试。
4. 不按 PR 来源拆分 trusted / external-pr 两套普通 runner。
5. 不新增 external-pr 专用 runner label。
6. 不新增 external-pr 专用 runner group。
7. 不让 self-hosted job 使用 job-level container。
8. 不强制修改现有 board label。
9. 不把 RUNNER_IMAGE 直接改成 ghcr.io/rcore-os/tgoskits-container:latest。
10. 不要求 10.3.10.194 现有 KVM/board runner 第一阶段全部升级到 qc-actions-runner:v0.0.2。
```

特别注意：

```text
在当前目标下，外部 fork PR 到 rcore-os/tgoskits 后，
与 rcore 组织内分支/PR 使用相同 label 规则。

也就是说，当前不默认按 PR 来源拆分：
  trusted runner
  external-pr runner

如果后续希望降低外部 PR 的安全风险，
可以再引入独立 runner label 或 runner group。

但这是后续增强，不是当前方案的默认前提，
现阶段不要实现。
```

### 14.3 后续可优化方向

后续可以评估但当前不实现：

```text
1. 10.3.10.194 新增独立普通 runner，加入普通测试池。
   - 前提是 10.0.20.39 普通 runner 压力较大。
   - 不复用现有 KVM/VMX runner。

2. 将 Axvisor x86_64 KVM/VMX label 从 intel 细化为：
   self-hosted, linux, tgoskits, qemu, kvm, intel

3. 引入 external-pr 专用 runner label 或 runner group。
   - 用于降低外部 fork PR 运行在自有服务器上的安全风险。
   - 需要单独讨论隔离、权限、网络和缓存策略。

4. 尝试让 self-hosted 普通测试进入 tgoskits-container。
   - 先验证普通 QEMU 测试。
   - 再评估 KVM/board 是否适合进入容器。

5. 根据 10.0.20.39 实测负载调整 runner 数。
   - 32 个 runner 起步。
   - 稳定后试 64 个。
   - 如 job 变慢或失败率上升，回退到 32 或 48。
```
