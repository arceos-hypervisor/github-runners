## 开发板文件锁与取消等待使用说明

本文档说明如何在多组织共享同一块开发板时，结合文件锁与 `lock-watcher.sh`，实现 **等待中的 Job 能被 Cancel 正常打断**，避免死锁。

---

### 1. 组件概览

- **`runner-wrapper/runner-wrapper.sh`**：为 Runner 注入 Job Started / Completed 钩子。
- **`runner-wrapper/pre-job-lock.sh`**：在 Job 开始前获取板子级文件锁（`flock`），并通过后台子进程持有锁。
- **`runner-wrapper/post-job-lock.sh`**：在 Job 结束时创建 `.release` 标记，唤醒持锁子进程释放锁。
- **`runner-wrapper/lock-watcher.sh`**：周期性查询 GitHub Actions Run 的状态；当发现持锁 Run 已被 **Cancel** 时，强制清理解锁文件，避免后续等待 Job 永久卡死。**一个 watcher 进程可同时监控多块板子**。配置 `RUNNER_LOCK_MONITOR_TOKEN` 后，watcher 会作为 compose 服务随 `./runner.sh start` **自动启动**，与锁机制一样使用无感。

锁文件结构（默认目录 `/tmp/github-runner-locks`）：

- `${RESOURCE_ID}.lock`：flock 使用的锁文件
- `${RESOURCE_ID}.holder`：当前持锁信息，格式为 `PID RUNNER_NAME RUN_ID RUN_ATTEMPT`
- `${RESOURCE_ID}.${RUNNER_NAME}.${RUN_ID}.${RUN_ATTEMPT}.release`：释放标记，由 `post-job-lock.sh` 创建

---

### 1.1 部署流程概览

可按以下顺序操作；细节见后续章节。

| 时机 | 要做的事 |
|------|----------|
| **第一次在这台机器上部署** | ① 准备各组织的 `.env`（含 ORG、REPO、GH_PAT、板子锁变量、以及 `RUNNER_LOCK_MONITOR_TOKEN`）<br>② **在宿主机**设置锁目录权限：`sudo mkdir -p /tmp/github-runner-locks && sudo chmod 1777 /tmp/github-runner-locks`（[详见 2.1](#21-宿主机锁目录权限首次部署或报-permission-denied-时)）<br>③ 每个组织执行一次 `./runner.sh init -n 2`，生成 compose、起容器并注册<br>④ watcher 会作为 compose 服务**随 start 自动启动**，无需单独起进程（[详见 3](#3-watcher-自动启动与锁使用无感)） |
| **以后每次使用（非初次）** | 执行 `ENV_FILE=.env.xxx ./runner.sh start`（每个组织）；watcher 随 runners 一起启停，使用无感 |

---

### 2. Runner 端配置（各组织 .env）

在各组织对应的 `.env` 中（示例：`.env.linebridge` / `.env.yoinspiration`）：

```bash
ORG=<org-name>
REPO=test-runner
GH_PAT=ghp_xxx                           # Runner 注册用，权限见 2.2

RUNNER_RESOURCE_ID_ROC_RK3568_PC=board-roc-rk3568-pc
RUNNER_LOCK_HOST_PATH=/tmp/github-runner-locks
RUNNER_LOCK_DIR=/tmp/github-runner-locks
# 必填（watcher 自动启动时用）：Fine-grained PAT，Actions: Read-only
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

#### 2.2 PAT 权限说明

- **GH_PAT**（Runner 注册、管理 runner 用）  
  - **组织级 Runner**（只设 `ORG`、不设 `REPO`）：Classic PAT 需勾选 **`admin:org`**，用于调用组织 Actions runner 注册等接口。  
  - **仓库级 Runner**（设了 `ORG` 和 `REPO`）：一般需 **`repo`**（完整仓库权限）；若仓库属组织且需在组织下管理 runner，可能仍要求 **`admin:org`**。  
  - 若用 Fine-grained PAT：在对应 org/repo 的权限中勾选可“管理 Actions runners”的项（名称以 GitHub 当前界面为准）。

- **RUNNER_LOCK_MONITOR_TOKEN**（仅 watcher 用，只读 run 状态）  
  - 建议使用 **Fine-grained PAT**，在对应仓库下将 **Actions** 设为 **Read-only**，权限最小、与 GH_PAT 分离更安全。

---

### 3. Watcher 自动启动（与锁使用无感）

配置 `RUNNER_LOCK_MONITOR_TOKEN` 后，`./runner.sh compose` 或 `init` 生成的 compose 会包含 **lock-watcher** 服务。执行 `./runner.sh start` 时，watcher 会随 runners 一起启动；`stop` / `restart` 时一起停止，**无需单独开终端或 systemd**。

1. 在对应组织的 `.env` 中增加（必填）：
   ```bash
   RUNNER_LOCK_MONITOR_TOKEN=github_pat_xxx   # Fine-grained PAT，Actions: Read-only
   ```
2. 若已有 compose，需重新生成以加入 watcher：
   ```bash
   ENV_FILE=.env.linebridge ./runner.sh compose
   ```
3. 之后执行 `./runner.sh start` 即可，watcher 自动随 runners 启停。

**手动单独运行**（可选）：若需在 compose 外单独跑 watcher（例如另一台机器），仍可使用：
   ```bash
   ENV_FILE=.env.linebridge ./runner.sh watcher
   ```
   建议用 tmux/screen 常驻。传参可指定只监控一块板子：`./runner.sh watcher board-roc-rk3568-pc`。

#### 3.0.1 手动常驻（仅在不使用 compose 自动启动时）

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

- **使用 compose 自动启动**：每组织一个 watcher 容器，随 `./runner.sh start` 自动拉起；无需额外配置。
- **手动运行**：每组织一个 watcher 进程，分别执行 `ENV_FILE=.env.linebridge ./runner.sh watcher` 与 `ENV_FILE=.env.yoinspiration ./runner.sh watcher`。

#### 3.2 准备 PAT

在对应组织账号下创建 **Fine-grained PAT**（推荐）：

- 选择包含 `test-runner` 的仓库（例如 `linebridge/test-runner`）。
- 在 **Repository permissions** 中将 **Actions** 设置为 **Read-only**。

生成后得到 `github_pat_xxx`。

#### 3.3 安装依赖

- **compose 自动启动**：watcher 容器使用 alpine，启动时自动安装 `jq`，宿主机无需安装。
- **手动运行 watcher**：需在宿主机安装 `jq`：`sudo apt install -y jq`，否则无法解析 run 状态。

---

### 4. 启动与验证

**compose 自动启动（推荐）**

```bash
cd /path/to/github-runners
ENV_FILE=.env.linebridge ./runner.sh start
```

watcher 会随 runners 一起启动。查看 watcher 日志：

```bash
docker logs -f $(docker ps -q -f name=lock-watcher)
```

**手动运行 watcher**（可选）

```bash
ENV_FILE=.env.linebridge ./runner.sh watcher
```

启动成功后，终端会打印类似：

```text
[lock-watcher] monitoring linebridge/test-runner, resources=board-roc-rk3568-pc board-phytiumpi, lock_dir=/tmp/github-runner-locks, interval=10s
```

运行过程中示例日志：

- 正常持锁：

```text
[lock-watcher] resource=board-roc-rk3568-pc run_id=22663158623 status=in_progress conclusion=<none> pid=1511 holder_runner=DESKTOP-...-runner-roc-rk3568-pc
```

- 对应 workflow 在 GitHub 上被 Cancel 后：

```text
[lock-watcher] resource=board-roc-rk3568-pc run_id=22663158623 status=completed conclusion=cancelled pid=1511 holder_runner=DESKTOP-...-runner-roc-rk3568-pc
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
  - watcher 使用的 `ORG` / `REPO`（来自 `ENV_FILE` 的 .env 或自建环境文件）是否与 Run 实际所在仓库一致；
  - Fine-grained PAT 是否勾选了对应仓库，并将 Actions 权限设为 Read-only。

- **Q: 没有安装 jq 时，status / conclusion 总是 `<none>`？**  
  **A:** 需要先在宿主机安装 `jq`，否则 watcher 无法从响应 JSON 中解析状态。

