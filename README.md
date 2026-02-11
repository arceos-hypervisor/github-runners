# Github Runner

English | [中文](README_CN.md)

## Overview

This repository provides scripts for creating, managing, and registering GitHub self-hosted runners using Docker containers. The main script, `runner.sh`, dynamically generates a `docker-compose.yml` and can build a custom runner image when a `Dockerfile` is present.

The toolkit supports both organization-scoped and repository-scoped runners. To target a specific repository, set the `REPO` variable in the environment (or via the interactive prompt).

## Features

- Create and manage multiple runner containers using Docker Compose.
- Support for organization-scoped and repository-scoped runners (controlled by `REPO`).
- Per-instance labels via `BOARD_RUNNERS` (those instances will use only the labels defined in `BOARD_RUNNERS`).
- Optional custom Docker image build when a `Dockerfile` is present; rebuilds are triggered when the Dockerfile changes.
- Caches GitHub registration tokens in `.reg_token.cache` to reduce API calls (TTL configurable).
- Common lifecycle commands: `init`, `register`, `start`, `stop`, `restart`, `logs`, `list`, `rm`, `purge`.

## Prerequisites

- Docker and Docker Compose must be installed on the host. The scripts support both `docker compose` and legacy `docker-compose`.
- A GitHub Personal Access Token (classic PAT) with the required permissions is needed (`GH_PAT`).
- Organization-level operations typically need organization admin or appropriate permissions; repository-level operations need repository admin permissions.

## Quickstart

1. Make the script executable:

```bash
chmod +x runner.sh
```

2. (Optional) Copy `.env.example` to `.env` and set `ORG`, `GH_PAT`, etc. If you skip this, the script will prompt for these on first run.

```bash
cp .env.example .env
# Edit .env and set at least ORG and GH_PAT
```

3. Run initialization (generates compose, builds image if needed, and starts containers):

```bash
./runner.sh init [-n N]
```

## Common Commands

- `./runner.sh init [-n N]`: generate and start N runners.
- `./runner.sh register [runner-<id> ...]`: register the specified runner containers with GitHub; with no arguments, attempts to register any unregistered instances found locally.
- `./runner.sh start [runner-<id> ...]`: start containers; will attempt registration if a container is running but not registered.
- `./runner.sh stop [runner-<id> ...]`: stop containers.
- `./runner.sh restart [runner-<id> ...]`: restart containers.
- `./runner.sh logs runner-<id>`: tail logs for the specified runner container.
- `./runner.sh ps`: show generated compose services or fall back to `docker ps`.
- `./runner.sh list`: show local container status and corresponding registration state on GitHub.
- `./runner.sh rm|remove|delete [runner-<id> ...] [-y|--yes]`: unregister and remove containers and volumes; confirmation required unless `-y` is provided.
- `./runner.sh purge [-y]`: remove generated files (such as `docker-compose.yml` and token caches) and containers; confirmation required unless `-y` is provided.

## Notes

- BOARD_RUNNERS format: `name:label1[,label2];name2:label1`. For names listed in `BOARD_RUNNERS`, the script will use only the labels specified there and will not append the global `RUNNER_LABELS`.
- If a `Dockerfile` exists in the repository root, the script will compute a hash of its contents and rebuild the custom runner image when that hash changes.
- Registration tokens are cached in `.reg_token.cache`. Control cache TTL with `REG_TOKEN_CACHE_TTL` (seconds).

## Multi-org Shared Hardware

When multiple GitHub organizations share the same hardware test environment (serial ports, power control, etc.), concurrent CI runs can cause resource conflicts. Use the **runner-wrapper** to serialize execution via file locks.

**Registration model**: GitHub’s runner model allows each self-hosted runner to register to only one organization or repository, not multiple orgs. In this repo, the target is set by `ORG`/`REPO` in `.env`. For multi-org shared hardware, use one `.env` and one set of runner instances per organization; multiple sets share the same `RUNNER_RESOURCE_ID` and lock directory so jobs run serially—not one runner registered to multiple orgs.

### Quick setup

When using **runner.sh** to generate compose, set `RUNNER_RESOURCE_ID` in `.env` (e.g. `board-phytiumpi`) so board runners use the wrapper and lock directory automatically. For manual or non–runner.sh setups:

1. Set `RUNNER_RESOURCE_ID` to the same value for all runners that share hardware (e.g. `board-phytiumpi`).
2. Mount a shared lock directory: `-v /tmp/github-runner-locks:/tmp/github-runner-locks`
3. Replace the container command with the wrapper:

```yaml
command: ["/home/runner/runner-wrapper/runner-wrapper.sh"]
environment:
  RUNNER_RESOURCE_ID: "board-phytiumpi"
  RUNNER_SCRIPT: "/home/runner/run.sh"
volumes:
  - /tmp/github-runner-locks:/tmp/github-runner-locks
```

**Performance**: Serialization is required by hardware (one board runs one job at a time). This setup turns chaotic contention into an ordered queue and does not reduce throughput. To increase throughput, set a different `RUNNER_RESOURCE_ID` per board (e.g. `RUNNER_RESOURCE_ID_PHYTIUMPI`, `RUNNER_RESOURCE_ID_ROC_RK3568_PC`); jobs on different boards then run in parallel and throughput scales linearly with the number of boards.

See [runner-wrapper/README.md](runner-wrapper/README.md) for details. Reference: [Discussion #341](https://github.com/orgs/arceos-hypervisor/discussions/341).

## Development and Contributing

Contributions are welcome. Suggested workflow:

1. Fork the repo and create a feature branch: `git checkout -b feat/your-change`.
2. Make changes and validate script syntax: `bash -n runner.sh`.
3. Open a pull request describing the change and how to test it.

Guidelines:

- Never commit files containing `GH_PAT` or other secrets.
- If you add dependencies like `jq`, update the README and provide fallbacks where practical.
- Try to keep the scripts compatible with POSIX-ish Bash and add tests where applicable.
