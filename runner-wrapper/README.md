## Runner Wrapper - 多组织共享硬件锁（Job 级别）

基于 Pre/Post Job 钩子和文件锁的 GitHub Actions Runner 入口脚本，用于多组织共享同一硬件测试环境时的**按 job 串行**控制。

## 核心特性

- **两个 Runner 均可 Idle**：不再 wrapping 整个 run.sh，Runner 可正常连接 GitHub。
- **仅在 job 执行时持锁**：通过 `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` 实现。
- **零外部依赖**：只依赖 flock + Bash，单机即可部署。

## 快速使用

```bash
chmod +x runner-wrapper.sh pre-job-lock.sh post-job-lock.sh
export RUNNER_RESOURCE_ID=hardware-test-1
export RUNNER_SCRIPT=/home/runner/run.sh
./runner-wrapper.sh
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `runner-wrapper.sh` | 入口脚本，设置 Job 钩子并执行 run.sh |
| `pre-job-lock.sh` | Pre-job 钩子，job 开始前获取 flock |
| `post-job-lock.sh` | Post-job 钩子，job 结束后释放 flock |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RUNNER_RESOURCE_ID` | `default-hardware` | 锁资源 ID，相同 ID 的 Runner 其 job 串行执行 |
| `RUNNER_SCRIPT` | `/home/runner/run.sh` | 实际 Runner 脚本路径 |
| `RUNNER_LOCK_DIR` | `/tmp/github-runner-locks` | 锁文件目录 |

## 与 runner.sh 的配合（锁的释放）

通过 `./runner.sh restart`、`./runner.sh stop` 等操作重启或停止容器时：

- **锁会随进程退出而释放**：锁由 pre-job 钩子中创建的子进程通过 `flock` 持有；容器被停止或重启时，该进程会随之退出，内核会关闭文件描述符并释放 flock，不会造成锁长期占用。
- **Runner 正在跑 job 时重启**：当前 job 会失败，但容器退出后锁会立即释放，其他等待同一 `RUNNER_RESOURCE_ID` 的 Runner 可以继续获取锁执行 job。

建议将锁目录放在**本地盘**；若使用 NFS 等网络文件系统，需确认其对 flock 语义的支持，以免异常退出时锁释放延迟。

## 依赖

- `flock`（通常随 util-linux 提供）
- Bash

## 参考

- [多组织共享集成测试环境问题分析与解决方案](https://github.com/orgs/arceos-hypervisor/discussions/341)
- [GitHub Docs: Running scripts before or after a job](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)

