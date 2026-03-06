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

### 1.1 部署流程概览

可按以下顺序操作；细节见后续章节。

| 时机 | 要做的事 |
|------|----------|
| **第一次在这台机器上部署** | ① 准备各组织的 `.env`（含 ORG、REPO、GH_PAT、板子锁变量、以及要用 watcher 时必填 `RUNNER_LOCK_MONITOR_TOKEN`）<br>② **在宿主机**设置锁目录权限：`sudo mkdir -p /tmp/github-runner-locks && sudo chmod 1777 /tmp/github-runner-locks`（详见 2.1）<br>③ 每个组织执行一次 `./runner.sh init -n 2`，生成 compose、起容器并注册<br>④（可选）安装 `jq`：`sudo apt install -y jq`<br>⑤ 每个组织起一个 watcher：`ENV_FILE=.env.xxx ./runner.sh watcher`，建议用 tmux/screen 或 systemd 常驻 |
| **以后每次使用（非初次）** | 需要时执行 `ENV_FILE=.env.xxx ./runner.sh start`（每个组织）；watcher 若已用 tmux/screen/systemd 常驻则不用管，否则再按上面命令各起一个 |

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
# 必填（仅在使用 ./runner.sh watcher 时）：Fine-grained PAT，Actions: Read-only
RUNNER_LOCK_MONITOR_TOKEN=github_pat_xxx
```

注意：

- 多组织共享同一块板子时，所有相关 `.env` 中的
  - `RUNNER_RESOURCE_ID_ROC_RK3568_PC`
  - `RUNNER_LOCK_HOST_PATH`
  - `RUNNER_LOCK_DIR`
  必须保持一致。

#### 2.1 宿主机锁目录权限（首次部署或报 Permission denied 时）

锁目录从宿主机挂进容器，若宿主机上该目录权限不对，容器内会报 `chmod: Operation not permitted` 或 `Permission denied`。**在宿主机**执行（仅首次部署或出现上述报错时）：

```bash
# 若目录已存在但权限不对，可先清理再改权限
sudo rm -f /tmp/github-runner-locks/*.holder /tmp/github-runner-locks/*.release
sudo chmod 1777 /tmp/github-runner-locks
sudo find /tmp/github-runner-locks -maxdepth 1 -type f -name 'board-*' -exec chmod 666 {} \;
```

若目录不存在，先创建再设权限：

```bash
sudo mkdir -p /tmp/github-runner-locks
sudo chmod 1777 /tmp/github-runner-locks
```

完成后重启对应 Runner（见下文）。

修改完 `.env` 后，重启对应 Runner：

```bash
ENV_FILE=.env.linebridge    ./runner.sh restart
ENV_FILE=.env.yoinspiration ./runner.sh restart
```

---

### 3. 宿主机上配置 lock-watcher

#### 3.0 推荐：通过 runner.sh 启动（与锁同源配置，使用无感）

Watcher 已集成进 `runner.sh`，**可直接复用各组织的 `.env`**，无需单独维护 `.env.watcher`：

1. 在对应组织的 `.env` 中增加一行（必填）：
   ```bash
   RUNNER_LOCK_MONITOR_TOKEN=github_pat_xxx   # Fine-grained PAT，Actions: Read-only
   ```
2. 在宿主机执行（与 start/restart 同一套 ENV_FILE）：
   ```bash
   ENV_FILE=.env.linebridge ./runner.sh watcher
   ```
   脚本会自动使用当前 `.env` 的 `ORG`、`REPO`、`RUNNER_LOCK_DIR` 以及 `RUNNER_RESOURCE_ID_ROC_RK3568_PC` 或 `RUNNER_RESOURCE_ID_PHYTIUMPI`（优先 roc）。若需指定资源 ID，可传参：
   ```bash
   ENV_FILE=.env.linebridge ./runner.sh watcher board-roc-rk3568-pc
   ```
3. 建议用 tmux/screen 或 systemd 常驻该进程；多组织时每个组织各开一个终端（或服务）运行 `./runner.sh watcher`。具体做法见下文「3.0.1 让 watcher 常驻」。

#### 3.0.1 让 watcher 常驻（tmux / screen / systemd）

任选一种方式，使 watcher 在断开 SSH 或重启后仍可运行。

**方式 A：tmux**

```bash
# 安装（若无）
sudo apt install -y tmux

# 第一个组织
cd /path/to/github-runners
tmux new -s watcher-linebridge
ENV_FILE=.env.linebridge ./runner.sh watcher
# 断开会话：Ctrl+B 再按 D

# 第二个组织（新开一个终端或新会话）
tmux new -s watcher-yoinspiration
ENV_FILE=.env.yoinspiration ./runner.sh watcher
# 同样 Ctrl+B D 断开

# 重新连上查看
tmux attach -t watcher-linebridge
tmux attach -t watcher-yoinspiration
```

**方式 B：screen**

```bash
# 安装（若无）
sudo apt install -y screen

# 第一个组织
cd /path/to/github-runners
screen -S watcher-linebridge
ENV_FILE=.env.linebridge ./runner.sh watcher
# 断开：Ctrl+A 再按 D

# 第二个组织
screen -S watcher-yoinspiration
ENV_FILE=.env.yoinspiration ./runner.sh watcher
# Ctrl+A D 断开

# 重新连上
screen -r watcher-linebridge
screen -r watcher-yoinspiration
```

**方式 C：systemd（开机自启，推荐长期使用）**

每个组织一个 service 文件，例如 linebridge：

```bash
sudo nano /etc/systemd/system/github-runner-watcher-linebridge.service
```

内容（将 `fei` 和 `/path/to/github-runners` 换成你的用户名与仓库绝对路径）：

```ini
[Unit]
Description=GitHub Runner lock watcher (linebridge)
After=network-online.target

[Service]
Type=simple
User=fei
WorkingDirectory=/path/to/github-runners
Environment=ENV_FILE=.env.linebridge
ExecStart=/path/to/github-runners/runner.sh watcher
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

再为 yoinspiration 建一份（如 `github-runner-watcher-yoinspiration.service`），仅把 `linebridge` 改为 `yoinspiration`、`ENV_FILE=.env.linebridge` 改为 `ENV_FILE=.env.yoinspiration` 即可。

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now github-runner-watcher-linebridge
sudo systemctl enable --now github-runner-watcher-yoinspiration
```

查看状态与日志：

```bash
sudo systemctl status github-runner-watcher-linebridge
journalctl -u github-runner-watcher-linebridge -f
```

#### 3.1 实例数量建议

- 默认推荐：**每个参与共享同一块板子的仓库，各启动一个 watcher 实例**（即每个组织一份 `.env`，各执行一次 `./runner.sh watcher`）。  
- 例如：`linebridge/test-runner`、`yoinspiration/test-runner` 分别执行 `ENV_FILE=.env.linebridge ./runner.sh watcher` 与 `ENV_FILE=.env.yoinspiration ./runner.sh watcher`。

#### 3.2 准备 PAT

在对应组织账号下创建 **Fine-grained PAT**（推荐）：

- 选择包含 `test-runner` 的仓库（例如 `linebridge/test-runner`）。
- 在 **Repository permissions** 中将 **Actions** 设置为 **Read-only**。

生成后得到 `github_pat_xxx`。

#### 3.3 创建 watcher 环境文件（方式二时使用）

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

#### 3.4 安装依赖

在宿主机上安装 `jq` 以解析 GitHub API 返回的 JSON：

```bash
sudo apt update
sudo apt install -y jq
```

---

### 4. 启动 lock-watcher

**方式一（推荐）：用 runner.sh 启动，与锁同源配置**

```bash
cd /path/to/github-runners
ENV_FILE=.env.linebridge ./runner.sh watcher
```

**方式二：单独环境文件**

在宿主机上打开一个长期运行的终端（建议放在 tmux/screen 或 systemd 服务中）：

```bash
cd /path/to/github-runners
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

