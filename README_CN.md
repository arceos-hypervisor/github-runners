# Github Runner

[English](README.md) | 中文

## 简介

本仓库提供脚本与工具集合，用于在 Docker 容器中创建、管理并注册 GitHub 自托管 Runner。与直接在主机上安装 [GitHub 官方 self-hosted runner](https://github.com/actions/runner) 不同，本方案将 runner 封装在 Docker 容器中，具有以下优势：

- **环境隔离**：每个 runner 运行在独立容器中，避免依赖冲突
- **易于管理**：通过 Docker Compose 批量管理多个 runner 实例
- **快速部署**：支持自定义镜像，预装项目所需工具链
- **多组织支持**：同一主机可运行多个容器，分别注册到不同组织

## 功能

- 使用 Docker Compose 批量管理多个 Runner 容器
- 支持组织级与仓库级 Runner（通过 `REPO` 变量切换）
- 支持按 Runner 配置标签、设备、用户组、卷、环境变量和启动命令
- 检测 `Dockerfile` 变更并自动重建自定义镜像
- 缓存注册令牌以减少 GitHub API 请求
- 提供完整生命周期命令：`init`、`add`、`compose`、`register`、`start`、`stop`、`restart`、`log`、`list`、`rm`、`purge`、`image`

## 使用

### 前提条件

- 主机需安装 Docker 与 Docker Compose
- 需要 GitHub Classic Personal Access Token（`GH_PAT`），组织级操作需组织管理员权限，仓库级操作需仓库管理员权限

### 快速开始

```bash
# 1. 赋予执行权限
chmod +x runner.sh

# 2. 生成并启动 Runner
./runner.sh init [-n N]
```

### 常用命令

| 命令 | 说明 |
|------|------|
| `./runner.sh init [-n N]` | 生成并启动 N 个 Runner |
| `./runner.sh add [-n N]` | 在现有 Runner 编号之后继续追加 N 个自动编号 Runner |
| `./runner.sh add <runner-name> [...]` | 新增一个或多个显式命名的 Runner |
| `./runner.sh compose` | 基于已有 Runner 重新生成 compose 文件 |
| `./runner.sh register [runner-<id> ...]` | 注册指定实例；不带参数则注册所有未配置实例 |
| `./runner.sh start/stop/restart [runner-<id> ...]` | 启动/停止/重启容器 |
| `./runner.sh log runner-<id>` | 跟随查看实例日志 |
| `./runner.sh ps` | 显示容器状态 |
| `./runner.sh list` | 显示本地容器状态及 GitHub 注册状态 |
| `./runner.sh rm [runner-<id> ...] [-y]` | 取消注册并删除容器；`-y` 跳过确认 |
| `./runner.sh purge [-y]` | 删除容器并移除生成文件（`docker-compose.yml`、缓存等） |
| `./runner.sh image` | 重新构建自定义 Runner 镜像 |

## 配置说明

### 容器命名

默认前缀自动包含 `ORG`（及 `REPO`），格式为 `<hostname>-<org>-runner-N` 或 `<hostname>-<org>-<repo>-runner-N`，避免多组织/多仓库容器重名。可通过 `RUNNER_NAME_PREFIX` 覆盖。

### Runner 配置

自动编号 Runner 使用 `${RUNNER_NAME_PREFIX}runner-N` 命名。`add -n N` 会在现有最大编号之后追加 N 个自动编号 Runner；`add <runner-name> [...]` 会按给定名称创建 Runner。默认 `RUNNER_*` 变量作用于所有 Runner，也可以追加 `_1`、`_2` 这类序号为单个自动编号 Runner 覆盖配置。显式命名的 Runner 默认使用通用配置；如果其生成位置碰巧对应某个编号覆盖，也会使用该覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RUNNER_LABELS` | `intel` | 注册 Runner 时使用的标签 |
| `RUNNER_DEVICES` | `/dev/loop-control,/dev/loop0,/dev/loop1,/dev/loop2,/dev/loop3,/dev/kvm` | 逗号分隔的设备映射；没有 `:` 的条目会映射到容器内相同路径 |
| `RUNNER_GROUP_ADD` | `dialout` | 逗号分隔的额外用户组 |
| `RUNNER_VOLUMES` | 空 | 分号分隔的额外卷挂载 |
| `RUNNER_ENV` | 空 | 分号分隔的 `KEY=VALUE` 环境变量 |
| `RUNNER_COMMAND` | `/home/runner/run.sh` | Runner 执行的启动命令 |

按 Runner 覆盖配置示例：

```bash
RUNNER_LABELS_2=board,phytiumpi,arm64
RUNNER_DEVICES_2=/dev/kvm,/dev/ttyUSB0:/dev/ttyUSB0
RUNNER_ENV_2='BOARD_NAME=phytiumpi;SERIAL=/dev/ttyUSB0'
```

### 其他配置

- **自定义镜像**：若存在 `Dockerfile`，脚本会根据哈希决定是否重建 `RUNNER_CUSTOM_IMAGE`
- **令牌缓存**：注册令牌缓存到 `.reg_token.cache`，通过 `REG_TOKEN_CACHE_TTL` 配置过期时间（秒）
## 贡献

```bash
# 1. Fork 并创建分支
git checkout -b feat/my-change

# 2. 修改并验证语法
bash -n runner.sh

# 3. 提交 PR，描述变更与测试步骤
```

注意事项：
- 请勿提交包含 `GH_PAT` 或其他敏感信息的文件
- 新增依赖时请在 README 中说明，并尽量提供回退方案
- 保持脚本兼容 Bash
