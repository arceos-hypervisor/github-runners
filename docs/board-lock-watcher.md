## 开发板文件锁与取消等待使用说明

本文档说明如何在多组织共享同一块开发板时，结合文件锁与 `lock-watcher.sh`，实现 **等待中的 Job 能被 Cancel 正常打断**，避免死锁。

---

### 1. 组件概览

- **`runner-wrapper/runner-wrapper.sh`**：为 Runner 注入 Job Started / Completed 钩子。
- **`runner-wrapper/pre-job-lock.sh`**：在 Job 开始前获取板子级文件锁（`flock`），并通过后台子进程持有锁。
- **`runner-wrapper/post-job-lock.sh`**：在 Job 结束时创建 `.release` 标记，唤醒持锁子进程释放锁。
- **`runner-wrapper/lock-watcher.sh`**（新增）：运行在宿主机上的守护脚本，周期性查询某个仓库下 Actions Run 的状态；当发现持锁 Run 已被 **Cancel** 时，强制清理解锁文件，避免后续等待 Job 永久卡死。

锁文件结构（默认目录 `/tmp/github-runner-locks`）：

- `${RESOURCE_ID}.lock`：flock 使用的锁文件
- `${RESOURCE_ID}.holder`：当前持锁信息，格式为 `PID RUNNER_NAME RUN_ID RUN_ATTEMPT`
- `${RESOURCE_ID}.${RUNNER_NAME}.${RUN_ID}.${RUN_ATTEMPT}.release`：释放标记，由 `post-job-lock.sh` 创建

---

### 2. Runner 端配置（各组织 .env）

在各组织对应的 `.env` 中（示例：`.env.linebridge` / `.env.yoinspiration`）：

```bash
ORG=<org-name>
REPO=test-runner
GH_PAT=ghp_xxx                           # Runner 注册用 Classic PAT

RUNNER_RESOURCE_ID_ROC_RK3568_PC=board-roc-rk3568-pc
RUNNER_LOCK_HOST_PATH=/tmp/github-runner-locks
RUNNER_LOCK_DIR=/tmp/github-runner-locks
```

注意：

- 多组织共享同一块板子时，所有相关 `.env` 中的
  - `RUNNER_RESOURCE_ID_ROC_RK3568_PC`
  - `RUNNER_LOCK_HOST_PATH`
  - `RUNNER_LOCK_DIR`
  必须保持一致。

修改完 `.env` 后，重启对应 Runner：

```bash
ENV_FILE=.env.linebridge    ./runner.sh restart
ENV_FILE=.env.yoinspiration ./runner.sh restart
```

---

### 3. 宿主机上配置 lock-watcher

#### 3.1 实例数量建议

- 默认推荐：**每个参与共享同一块板子的仓库，各启动一个 `lock-watcher.sh` 实例**，即每个仓库一份 `ORG/REPO/GITHUB_TOKEN` 配置。  
- 例如：`linebridge/test-runner`、`yoinspiration/test-runner` 各有一份 `.env.watcher.*` 与一个对应的 watcher 进程。

#### 3.2 准备 PAT

在对应组织账号下创建 **Fine-grained PAT**（推荐）：

- 选择包含 `test-runner` 的仓库（例如 `linebridge/test-runner`）。
- 在 **Repository permissions** 中将 **Actions** 设置为 **Read-only**。

生成后得到 `github_pat_xxx`。

#### 3.2 创建 watcher 环境文件

在仓库根目录创建 `.env.watcher`（示例为监控 `linebridge/test-runner` 与 `board-roc-rk3568-pc` 板）：

```bash
ORG=linebridge
REPO=test-runner
GITHUB_TOKEN=github_pat_xxx
RUNNER_RESOURCE_ID=board-roc-rk3568-pc
RUNNER_LOCK_DIR=/tmp/github-runner-locks
INTERVAL=10
```

> 如需为其他组织（例如 `yoinspiration`）单独监控，可再创建一个环境文件（如 `.env.watcher.yoinspiration`），修改 `ORG` / `REPO` / `GITHUB_TOKEN` 后启动第二个 watcher 实例。

#### 3.3 安装依赖

在宿主机上安装 `jq` 以解析 GitHub API 返回的 JSON：

```bash
sudo apt update
sudo apt install -y jq
```

---

### 4. 启动 lock-watcher

在宿主机上打开一个长期运行的终端（建议放在 tmux/screen 或 systemd 服务中）：

```bash
cd /home/fei/os-internship/github-runners

source .env.watcher

./runner-wrapper/lock-watcher.sh
```

启动成功后，终端会打印类似：

```text
[lock-watcher] monitoring linebridge/test-runner, resource=board-roc-rk3568-pc, lock_dir=/tmp/github-runner-locks, interval=10s
```

运行过程中示例日志：

- 正常持锁：

```text
[lock-watcher] run_id=22663158623 status=in_progress conclusion=<none> pid=1511 holder_runner=DESKTOP-...-runner-roc-rk3568-pc
```

- 对应 workflow 在 GitHub 上被 Cancel 后：

```text
[lock-watcher] run_id=22663158623 status=completed conclusion=cancelled pid=1511 holder_runner=DESKTOP-...-runner-roc-rk3568-pc
[lock-watcher] detected cancelled workflow, force releasing lock for board-roc-rk3568-pc
```

表示 watcher 已检测到 Cancel，并强制清理解锁文件。

---

### 5. 典型验证流程

以下以 `linebridge/test-runner` 与 `yoinspiration/test-runner` 共享 `board-roc-rk3568-pc` 板为例。

#### 5.1 触发占板子的 holder

在 `linebridge/test-runner` 仓库中：

1. 打开 Actions，选择 `board-lock-holder` workflow。
2. 点击 **Run workflow** 触发一次运行。
3. 在日志中看到：

   - `Waiting for lock: board-roc-rk3568-pc`
   - `Acquired lock for board-roc-rk3568-pc`

表示 holder 成功持有锁并占用板子。

#### 5.2 触发等待的 waiter

在 `yoinspiration/test-runner` 仓库中：

1. 打开 Actions，选择 `board-lock-waiter` workflow。
2. 点击 **Run workflow**。
3. 在日志中可以看到：

   - `Waiting for lock: board-roc-rk3568-pc`

表示 waiter 正在等待同一块板子的锁。

#### 5.3 Cancel 并观察自动解锁

1. 在 `linebridge/test-runner` 的 `board-lock-holder` 运行页面点击 **Cancel workflow**。
2. 几秒后，宿主机上 `lock-watcher.sh` 日志应出现：

   ```text
   [lock-watcher] run_id=... status=completed conclusion=cancelled ...
   [lock-watcher] detected cancelled workflow, force releasing lock for board-roc-rk3568-pc
   ```

3. 此时 `yoinspiration` 侧的 `board-lock-waiter` 将在锁释放后继续执行，直至 Job 完成，而不会长时间卡在等待状态。

---

### 6. 常见问题

- **Q: watcher 日志中一直是 `status=in_progress conclusion=<none>`？**  
  **A:** Run 还在运行中，尚未 Cancel 或完成，watcher 只会记录状态，不会释放锁。需要在 GitHub 页面上点击 Cancel，且等状态变为 Cancelled 后再观察。

- **Q: watcher 日志中频繁出现 `empty response for run_id=..., skip`？**  
  **A:** 对应的 Run 不属于当前 `ORG/REPO`，或 `GITHUB_TOKEN` 对该仓库没有足够的 Actions 读取权限。请确认：
  - `.env.watcher` 中的 `ORG` / `REPO` 是否与 Run 实际所在仓库一致；
  - Fine-grained PAT 是否勾选了对应仓库，并将 Actions 权限设为 Read-only。

- **Q: 没有安装 jq 时，status / conclusion 总是 `<none>`？**  
  **A:** 需要先在宿主机安装 `jq`，否则 watcher 无法从响应 JSON 中解析状态。

