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
- 支持针对特定实例的自定义标签（`BOARD_RUNNERS`）
- 检测 `Dockerfile` 变更并自动重建自定义镜像
- 缓存注册令牌以减少 GitHub API 请求
- 提供完整生命周期命令：`init`、`register`、`start`、`stop`、`restart`、`logs`、`list`、`rm`、`purge`

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
| `./runner.sh register [runner-<id> ...]` | 注册指定实例；不带参数则注册所有未配置实例 |
| `./runner.sh start/stop/restart [runner-<id> ...]` | 启动/停止/重启容器 |
| `./runner.sh logs runner-<id>` | 查看实例日志 |
| `./runner.sh ps` | 显示容器状态 |
| `./runner.sh list` | 显示本地容器状态及 GitHub 注册状态 |
| `./runner.sh rm [runner-<id> ...] [-y]` | 取消注册并删除容器；`-y` 跳过确认 |
| `./runner.sh purge [-y]` | 删除容器并移除生成文件（`docker-compose.yml`、缓存等） |

> **注意**：`init` 命令默认会创建两个基于硬件的 Runner（phytiumpi 和 roc-rk3568-pc），此行为不受 `-n` 参数控制。

## 配置说明

### 容器命名

默认前缀自动包含 `ORG`（及 `REPO`），格式为 `<hostname>-<org>-runner-N` 或 `<hostname>-<org>-<repo>-runner-N`，避免多组织/多仓库容器重名。可通过 `RUNNER_NAME_PREFIX` 覆盖。

### BOARD_RUNNERS 格式

```
name:label1[,label2];name2:label1
```

示例：`phytiumpi:arm64,phytiumpi;roc-rk3568-pc:arm64,roc-rk3568-pc`

开发板实例将仅使用 `BOARD_RUNNERS` 中定义的标签，不会追加全局 `RUNNER_LABELS`。

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
