# Github Runner

[English](README.md) | 中文

## 简介

本仓库提供一个脚本与工具集合，用于在 Docker 容器中创建、管理并注册 GitHub 自托管 Runner（self-hosted runner）。脚本会动态生成 `docker-compose.yml`，并在需要时构建自定义 Runner 镜像，支持组织级（organization）与仓库级（repository）两种作用域。

## 功能

1. 使用 Docker Compose 批量生成并管理多个 Runner 容器。
2. 支持组织级与仓库级 Runner（通过设置 `REPO` 切换到仓库级）。
3. 支持针对特定实例/开发板的自定义标签（`BOARD_RUNNERS`）。
4. 检测并构建本地 `Dockerfile` 为自定义 Runner 镜像（按哈希变更触发重建）。
5. 缓存注册令牌以减少 GitHub API 请求（缓存文件 `.reg_token.cache`，TTL 可配置）。
6. 提供常用生命周期命令：`init`、`register`、`start`、`stop`、`restart`、`logs`、`list`、`rm`、`purge`。

## 使用

### 前提条件

- 主机需安装 Docker 与 Docker Compose（支持 `docker compose` 或 `docker-compose`）。
- 需要一个具有相应权限的 GitHub Classic Personal Access Token（`GH_PAT`）。组织级操作通常需要组织管理员权限，仓库级操作需要仓库管理员权限。

### 快速开始

1. 赋予脚本执行权限：

```bash
chmod +x runner.sh
```

2. 生成并启动 Runner：

```bash
./runner.sh init [-n N]
```

### 常用命令

- `./runner.sh init [-n N]`：生成并启动 N 个 Runner（默认读取 `.env` 中 `RUNNER_COUNT`）。
- `./runner.sh register [runner-<id> ...]`：注册指定实例；不带参数扫描并注册所有未配置实例。
- `./runner.sh start [runner-<id> ...]`：启动容器（必要时进行注册）。
- `./runner.sh stop [runner-<id> ...]`：停止容器。
- `./runner.sh restart [runner-<id> ...]`：重启容器。
- `./runner.sh logs runner-<id>`：查看实例日志。
- `./runner.sh ps`：显示容器状态（若无 `docker-compose.yml` 则回退到 `docker ps`）。
- `./runner.sh list`：显示本地主机容器状态及 GitHub 上的 Runner 注册状态。
- `./runner.sh rm|remove|delete [runner-<id> ...] [-y|--yes]`：取消注册并删除指定容器与卷；不带参数将删除全部（会要求确认，`-y` 跳过确认）。
- `./runner.sh purge [-y]`：在删除的同时移除生成文件（如 `docker-compose.yml`、缓存文件等）。

### 注意事项

- `BOARD_RUNNERS` 格式：`name:label1[,label2];name2:label1`。开发板实例将仅使用 `BOARD_RUNNERS` 中定义的标签，不会追加全局 `RUNNER_LABELS`。
- 若存在 `Dockerfile`，脚本会根据其哈希决定是否重建 `RUNNER_CUSTOM_IMAGE`。
- 注册令牌会缓存到 `.reg_token.cache`，可通过 `REG_TOKEN_CACHE_TTL` 配置过期时间（秒）。

## 贡献

欢迎贡献：

1. Fork 仓库并创建分支：`git checkout -b feat/my-change`。
2. 本地修改并测试，使用 `bash -n runner.sh` 检查脚本语法。
3. 提交并发起 Pull Request，描述变更与测试步骤。

贡献指南：

- 请勿提交包含 `GH_PAT` 或其他敏感信息的文件。
- 若引入新的依赖（例如 `jq`），请在 README 中说明并尽量提供无该依赖的回退方案。
- 保持脚本兼容 Bash，并在修改后运行基础验证（`bash -n` / 运行常用命令）。
