# 多组织共享 Runner 使用说明

本文档用于指导在同一台主机上部署两套（或多套）GitHub Actions Runner，并通过 `runner-wrapper` 实现：

- 同板卡任务串行（避免硬件冲突）
- 异板卡任务并行（提升吞吐）
- 支持网页手动 `Cancel` 后的安全恢复

---

## 1. 适用场景

- 多个组织（或多个账号）共享同一块测试板卡。
- 需要保证同一资源标签（如 `roc-rk3568-pc`）不会并发操作硬件。
- 允许不同硬件标签（如 `roc-rk3568-pc` 与 `phytiumpi`）并行执行。

---

## 2. 前置条件

- 同一台 Linux 主机（锁基于本机文件锁，跨主机不生效）。
- 已安装并可用：
  - `docker` / `docker compose`
  - `bash`
- 两套有效的 GitHub 凭据（组织或账号均可）。

> 注意：不要提交 `.env*`（含 PAT）到仓库。

---

## 3. 环境变量准备

为每个组织（或账号）准备独立 env 文件，例如：

- `.env.orgA`
- `.env.orgB`

示例（两份都类似）：

```env
ORG=your-org-or-user
REPO=test-runner
GH_PAT=ghp_xxx

RUNNER_RESOURCE_ID_PHYTIUMPI=board-phytiumpi
RUNNER_RESOURCE_ID_ROC_RK3568_PC=board-roc-rk3568-pc
RUNNER_LOCK_HOST_PATH=/tmp/github-runner-locks
RUNNER_LOCK_DIR=/tmp/github-runner-locks
```

关键要求：

- 两套配置的 `RUNNER_RESOURCE_ID_*` 必须一致（同板卡共享同一锁）。
- 两套配置的 `RUNNER_LOCK_HOST_PATH` 必须一致（指向同一宿主机目录）。

---

## 4. 初次部署

在仓库根目录执行：

```bash
ENV_FILE=.env.orgA ./runner.sh init -n 2
ENV_FILE=.env.orgB ./runner.sh init -n 2
```

检查状态：

```bash
ENV_FILE=.env.orgA ./runner.sh ps
ENV_FILE=.env.orgB ./runner.sh ps
```

预期：两套都出现 `runner-roc-rk3568-pc`、`runner-phytiumpi` 且 `online`。

---

## 5. 日常更新（脚本/配置改动后）

当修改了 `runner.sh` 或 `.env` 后：

```bash
ENV_FILE=.env.orgA ./runner.sh compose
ENV_FILE=.env.orgB ./runner.sh compose
docker compose -f docker-compose.<orgA>.<repo>.yml up -d --force-recreate
docker compose -f docker-compose.<orgB>.<repo>.yml up -d --force-recreate
```

如果修改了镜像内依赖（例如 Dockerfile），再执行：

```bash
ENV_FILE=.env.orgA ./runner.sh image
```

> 当前实现已把 `./runner-wrapper` 目录只读挂载进板卡容器，`pre/post` 脚本改动通常不需要重建镜像，只需 `compose + force-recreate`。

---

## 6. 验证方法

### 6.1 同板卡串行验证（应串行）

两边同时触发：

```yaml
runs-on: [self-hosted, linux, roc-rk3568-pc]
```

步骤里包含：

```yaml
- run: echo "START $(date -Iseconds)"
- run: sleep 120
- run: echo "END $(date -Iseconds)"
```

预期：

- 一个先 Running，另一个先 Waiting；
- 前者结束后后者开始；
- 两个 `sleep 120` 时间段不重叠。

### 6.2 异板卡并行验证（应并行）

- 任务 A：`roc-rk3568-pc`
- 任务 B：`phytiumpi`

预期：两者可同时 Running，执行时间有重叠。

---

## 7. Cancel 场景说明

允许在网页点 `Cancel`，但建议遵循：

- 重要验证尽量让任务自然结束；
- 若中途取消后出现异常（如等待异常、状态不同步），执行一次清场：

```bash
sudo rm -f /tmp/github-runner-locks/*.holder /tmp/github-runner-locks/*.release
sudo chmod 1777 /tmp/github-runner-locks
sudo find /tmp/github-runner-locks -maxdepth 1 -type f -name 'board-*' -exec chmod 666 {} \;
docker restart <orgA-roc-container>
docker restart <orgB-roc-container>
```

当前锁实现已包含：

- 按 `RUNNER_NAME + GITHUB_RUN_ID + GITHUB_RUN_ATTEMPT` 生成唯一 release 文件；
- 防止旧任务 post-hook 误释放新任务锁（cancel 竞态保护）。

---

## 8. 常见问题

### 8.1 一直 `Waiting for a runner to pick up this job...`

优先检查：

- 该组织/仓库下 runner 是否 `online`
- 标签是否精确匹配（`self-hosted, linux, roc-rk3568-pc`）
- Runner group 是否授权目标仓库

### 8.2 Runner 全部 `offline`

常见原因是代理配置错误（例如容器内 `127.0.0.1:7890` 不可达）。

当前脚本已改为：仅当显式设置 `HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 时才注入代理变量。

### 8.3 明明改了脚本，但容器没生效

执行：

```bash
ENV_FILE=.env.<org> ./runner.sh compose
docker compose -f docker-compose.<org>.<repo>.yml up -d --force-recreate
```

并在容器内检查脚本关键字是否存在。

