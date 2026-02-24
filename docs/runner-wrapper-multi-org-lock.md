# Runner-Wrapper 多组织共享硬件锁 — 功能文档

## 1. 背景与问题

在 [arceos-hypervisor](https://github.com/arceos-hypervisor) 项目的 CI 环境中，多个 GitHub 组织需要共享同一台物理主机上的硬件测试设备（开发板），包括串口（ttyUSB）、电源控制（Modbus RTU）等独占资源。

### 面临的挑战

1. **硬件资源独占**：一块开发板同一时间只能被一个 CI Job 使用（串口通信、电源控制等不可并发共享）。
2. **GitHub Runner 注册限制**：GitHub 的 self-hosted runner 模型中，一个 runner 只能注册到**一个**组织或仓库，无法同时服务多个组织。
3. **并发冲突**：多个组织的 CI 同时触发时，多个 runner 可能同时操作同一块板子，导致串口数据错乱、电源状态不一致等问题。

### 参考讨论

- [Discussion #341: 多组织共享集成测试环境问题分析与解决方案](https://github.com/orgs/arceos-hypervisor/discussions/341)

## 2. 解决方案概述

采用 **runner-wrapper** 包装脚本 + **flock 文件锁**的方案，在 Job 级别实现串行控制：

- 每个组织部署**独立的一套 runner 实例**（各自有 `.env` 和注册配置）。
- 所有共享同一块板子的 runner 通过**相同的锁 ID**和**共享的锁目录**协调执行。
- 利用 GitHub Actions 的 **Pre/Post Job 钩子**机制，仅在 Job 执行阶段持锁，runner 空闲时不占锁。

## 3. 架构设计

### 3.1 整体架构

```
主机 (物理服务器)
├── 组织 A 的 Runner 实例 (.env-a)
│   ├── runner-phytiumpi      (注册到 Org-A，使用 runner-wrapper)
│   └── runner-roc-rk3568-pc  (注册到 Org-A，使用 runner-wrapper)
│
├── 组织 B 的 Runner 实例 (.env-b)
│   ├── runner-phytiumpi      (注册到 Org-B，使用 runner-wrapper)
│   └── runner-roc-rk3568-pc  (注册到 Org-B，使用 runner-wrapper)
│
├── 共享锁目录: /tmp/github-runner-locks/
│   ├── board-phytiumpi.lock       ← Org-A 和 Org-B 的 phytiumpi runner 共享此锁
│   └── board-roc-rk3568-pc.lock   ← Org-A 和 Org-B 的 roc-rk3568-pc runner 共享此锁
│
└── 硬件设备
    ├── PhytiumPi 开发板 (/dev/ttyUSB0, /dev/ttyUSB1)
    └── ROC-RK3568-PC 开发板 (/dev/ttyUSB2, /dev/ttyUSB3)
```

### 3.2 锁粒度设计

| 锁 ID | 默认值 | 保护的资源 |
|--------|--------|-----------|
| `RUNNER_RESOURCE_ID_PHYTIUMPI` | `board-phytiumpi` | PhytiumPi 开发板及其串口/电源 |
| `RUNNER_RESOURCE_ID_ROC_RK3568_PC` | `board-roc-rk3568-pc` | ROC-RK3568-PC 开发板及其串口/电源 |

**关键设计**：每块板子使用独立的锁 ID，不同板子的 Job 可以**并行**执行；只有操作**同一块板子**的 Job 才会串行排队。

## 4. 实现细节

### 4.1 文件结构

```
runner-wrapper/
├── runner-wrapper.sh      # 入口脚本：设置 Job 钩子，启动 run.sh
├── pre-job-lock.sh        # Pre-Job 钩子：Job 开始前获取 flock
└── post-job-lock.sh       # Post-Job 钩子：Job 结束后释放 flock
```

### 4.2 执行流程

```
Runner 启动
    │
    ▼
runner-wrapper.sh
    ├── 设置环境变量：
    │   ACTIONS_RUNNER_HOOK_JOB_STARTED  → pre-job-lock.sh
    │   ACTIONS_RUNNER_HOOK_JOB_COMPLETED → post-job-lock.sh
    │
    └── exec run.sh  （Runner 正常连接 GitHub，显示 Idle）
         │
         ├── [Job 被调度到此 Runner]
         │     │
         │     ▼
         │   pre-job-lock.sh 被触发
         │     ├── flock -x 获取排他锁（若锁被占则阻塞等待）
         │     ├── 启动后台 holder 子进程持有锁（继承 fd 200）
         │     └── 返回，Job 开始执行
         │
         │     ... Job 运行中（持锁）...
         │
         │   post-job-lock.sh 被触发
         │     ├── 创建 .release 文件
         │     └── holder 子进程检测到后退出，flock 释放
         │
         └── Runner 回到 Idle，等待下一个 Job
```

### 4.3 锁机制原理

锁基于 Linux 的 `flock` 系统调用实现，通过文件描述符继承来跨进程持有锁：

1. **获取锁**（`pre-job-lock.sh`）：
   - 打开锁文件到 fd 200：`exec 200>/tmp/github-runner-locks/board-phytiumpi.lock`
   - 调用 `flock -x 200` 获取排他锁（阻塞直到可用）
   - 派生后台子进程继承 fd 200 并轮询 `.release` 文件
   - 主脚本退出，但子进程继续持有锁

2. **释放锁**（`post-job-lock.sh`）：
   - 创建 `.release` 标记文件
   - 后台 holder 子进程检测到标记后退出
   - 进程退出时内核关闭 fd 200，flock 自动释放

3. **异常释放**：
   - 容器被 stop/restart 时，holder 进程随之被杀死
   - 内核关闭文件描述符，锁**立即释放**，不会死锁

### 4.4 与 runner.sh 的集成

`runner.sh` 在生成 `docker-compose.yml` 时自动完成以下配置：

- 板子 runner 的 `command` 指向 `runner-wrapper.sh`（替代直接调用 `run.sh`）
- 注入 `RUNNER_RESOURCE_ID`、`RUNNER_SCRIPT`、`RUNNER_LOCK_DIR` 环境变量
- 挂载宿主机锁目录到容器内（`-v /tmp/github-runner-locks:/tmp/github-runner-locks`）

相关代码位于 `runner.sh` 的 `shell_generate_compose_file()` 函数中。

### 4.5 容器命名策略

为避免同一主机上多组织/多仓库部署时容器重名，`RUNNER_NAME_PREFIX` 默认自动拼入 ORG（和 REPO）：

| 场景 | 默认前缀 |
|------|---------|
| 组织级（仅设 ORG） | `<hostname>-<org>-` |
| 仓库级（设 ORG + REPO） | `<hostname>-<org>-<repo>-` |
| 用户显式设置 | 使用用户提供的值 |

## 5. 配置指南

### 5.1 使用 runner.sh（推荐）

板子 runner **默认即启用** wrapper 和锁机制，无需额外配置。如需自定义：

```bash
# .env 文件
ORG=my-organization
GH_PAT=ghp_xxxx

# 可选：自定义板子锁 ID（多组织共享同一块板时，所有组织设相同值）
RUNNER_RESOURCE_ID_PHYTIUMPI=board-phytiumpi
RUNNER_RESOURCE_ID_ROC_RK3568_PC=board-roc-rk3568-pc

# 可选：自定义锁目录
RUNNER_LOCK_DIR=/tmp/github-runner-locks
RUNNER_LOCK_HOST_PATH=/tmp/github-runner-locks
```

然后执行：

```bash
./runner.sh init -n 3   # 3 个通用 runner + 2 个板子 runner
```

### 5.2 多组织部署示例

假设主机上有一块 PhytiumPi 板子，需要服务 Org-A 和 Org-B：

```bash
# --- Org-A 的部署目录 ---
cd /opt/runners/org-a
cat .env
  ORG=org-a
  GH_PAT=ghp_aaaa
  RUNNER_RESOURCE_ID_PHYTIUMPI=board-phytiumpi

./runner.sh init -n 1

# --- Org-B 的部署目录 ---
cd /opt/runners/org-b
cat .env
  ORG=org-b
  GH_PAT=ghp_bbbb
  RUNNER_RESOURCE_ID_PHYTIUMPI=board-phytiumpi    # 相同 ID → Job 串行

./runner.sh init -n 1
```

两个组织的 runner 共享 `/tmp/github-runner-locks/board-phytiumpi.lock`，确保同一时刻只有一个 Job 操作板子。

### 5.3 手动配置（不使用 runner.sh）

在 `docker-compose.yml` 中手动配置：

```yaml
services:
  my-board-runner:
    image: qc-actions-runner:v0.0.1
    command: ["/home/runner/runner-wrapper/runner-wrapper.sh"]
    environment:
      RUNNER_RESOURCE_ID: "board-phytiumpi"
      RUNNER_SCRIPT: "/home/runner/run.sh"
      RUNNER_LOCK_DIR: "/tmp/github-runner-locks"
    volumes:
      - /tmp/github-runner-locks:/tmp/github-runner-locks
```

## 6. 环境变量参考

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RUNNER_RESOURCE_ID` | （空） | 全局锁 ID，仅用于手动配置 wrapper 时 |
| `RUNNER_RESOURCE_ID_PHYTIUMPI` | `board-phytiumpi` | PhytiumPi 板子的锁 ID |
| `RUNNER_RESOURCE_ID_ROC_RK3568_PC` | `board-roc-rk3568-pc` | ROC-RK3568-PC 板子的锁 ID |
| `RUNNER_LOCK_DIR` | `/tmp/github-runner-locks` | 容器内锁文件目录 |
| `RUNNER_LOCK_HOST_PATH` | `/tmp/github-runner-locks` | 宿主机锁文件目录（bind mount 源） |
| `RUNNER_SCRIPT` | `/home/runner/run.sh` | 实际 runner 脚本路径 |
| `RUNNER_NAME_PREFIX` | `<hostname>-<org>[-<repo>]-` | 容器名前缀（自动生成或显式覆盖） |

## 7. 性能与可靠性

### 性能

- **不降低吞吐**：串行是硬件本身的限制（一块板子同时只能跑一个测试），方案只是把无秩序竞争变为有序排队。
- **不同板子可并行**：PhytiumPi 和 ROC-RK3568-PC 使用不同锁 ID，各自独立，互不阻塞。
- **Idle 状态不持锁**：runner 空闲时正常连接 GitHub 接受调度，不浪费锁资源。

### 可靠性

- **容器重启自动释放**：锁通过 flock 系统调用持有，进程退出时内核自动释放，不会死锁。
- **零外部依赖**：仅依赖 `flock`（util-linux）和 Bash，单机即可部署，无需 Redis、etcd 等外部服务。
- **锁目录建议**：使用本地磁盘。若使用 NFS 等网络文件系统，需确认其对 flock 语义的支持。

## 8. 依赖

| 依赖 | 用途 | 来源 |
|------|------|------|
| `flock` | 文件锁原语 | util-linux（通常已预装） |
| Bash | 脚本运行时 | 系统自带 |
| Docker + Docker Compose | 容器管理 | 需预装 |

## 9. 相关文件

| 文件 | 说明 |
|------|------|
| `runner-wrapper/runner-wrapper.sh` | 入口包装脚本 |
| `runner-wrapper/pre-job-lock.sh` | Pre-Job 钩子（获取锁） |
| `runner-wrapper/post-job-lock.sh` | Post-Job 钩子（释放锁） |
| `runner.sh` | 主管理脚本（集成 wrapper 配置生成） |
| `Dockerfile` | 自定义 runner 镜像（包含 wrapper 脚本复制） |
| `.env.example` | 环境变量模板 |
| `verify-changes.sh` | 功能验证脚本 |

## 10. 参考资料

- [GitHub Docs: Running scripts before or after a job](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)
- [Discussion #341: 多组织共享集成测试环境问题分析与解决方案](https://github.com/orgs/arceos-hypervisor/discussions/341)
- [flock(1) - Linux man page](https://man7.org/linux/man-pages/man1/flock.1.html)
