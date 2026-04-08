# Github Runner

English | [中文](README_CN.md)

## Overview

This repository provides scripts and tools for creating, managing, and registering GitHub self-hosted runners in Docker containers. Unlike installing the [official GitHub self-hosted runner](https://github.com/actions/runner) directly on the host, this approach encapsulates runners in Docker containers with the following benefits:

- **Environment Isolation**: Each runner runs in an isolated container, avoiding dependency conflicts
- **Easy Management**: Batch management of multiple runner instances via Docker Compose
- **Fast Deployment**: Supports custom images with pre-installed toolchains
- **Multi-Org Support**: Multiple containers can run on the same host, registering to different organizations

## Features

- Batch management of multiple runner containers using Docker Compose
- Support for organization-level and repository-level runners (controlled by `REPO` variable)
- Per-instance custom labels via `BOARD_RUNNERS`
- Automatic custom image rebuild when `Dockerfile` changes
- Cached registration tokens to reduce GitHub API requests
- Full lifecycle commands: `init`, `register`, `start`, `stop`, `restart`, `logs`, `list`, `rm`, `purge`

## Usage

### Prerequisites

- Docker and Docker Compose installed on the host
- GitHub Classic Personal Access Token (`GH_PAT`) with appropriate permissions (org admin for organization-level, repo admin for repository-level)

### Quick Start

```bash
# 1. Make the script executable
chmod +x runner.sh

# 2. Generate and start runners
./runner.sh init [-n N]
```

### Common Commands

| Command | Description |
|---------|-------------|
| `./runner.sh init [-n N]` | Generate and start N runners |
| `./runner.sh register [runner-<id> ...]` | Register specified instances; without arguments, registers all unconfigured instances |
| `./runner.sh start/stop/restart [runner-<id> ...]` | Start/stop/restart containers |
| `./runner.sh logs runner-<id>` | View instance logs |
| `./runner.sh ps` | Show container status |
| `./runner.sh list` | Show local container status and GitHub registration status |
| `./runner.sh rm [runner-<id> ...] [-y]` | Unregister and remove containers; `-y` skips confirmation |
| `./runner.sh purge [-y]` | Remove containers and generated files (`docker-compose.yml`, caches, etc.) |

> **Note**: The `init` command creates two hardware-based runners (phytiumpi and roc-rk3568-pc) by default. This behavior is not controlled by the `-n` parameter.

## Configuration

### Container Naming

The default prefix automatically includes `ORG` (and `REPO` if set), formatted as `<hostname>-<org>-runner-N` or `<hostname>-<org>-<repo>-runner-N` to avoid naming conflicts when multiple orgs/repos run on the same host. Override with `RUNNER_NAME_PREFIX`.

### BOARD_RUNNERS Format

```
name:label1[,label2];name2:label1
```

Example: `phytiumpi:arm64,phytiumpi;roc-rk3568-pc:arm64,roc-rk3568-pc`

Board instances will only use labels defined in `BOARD_RUNNERS` and will not append global `RUNNER_LABELS`.

### Other Settings

- **Custom Image**: If a `Dockerfile` exists, the script will rebuild `RUNNER_CUSTOM_IMAGE` based on hash changes
- **Token Cache**: Registration tokens are cached in `.reg_token.cache`, configure TTL via `REG_TOKEN_CACHE_TTL` (seconds)

## Contributing

```bash
# 1. Fork and create a branch
git checkout -b feat/my-change

# 2. Make changes and validate syntax
bash -n runner.sh

# 3. Submit a PR describing the changes and test steps
```

Notes:
- Do not commit files containing `GH_PAT` or other sensitive information
- Document new dependencies in README and provide fallback options where possible
- Keep scripts compatible with Bash
