# Runner Wrapper - 多组织共享硬件锁（Job 级别）

基于 Pre/Post Job 钩子和文件锁的 GitHub Actions Runner 入口脚本，用于多组织共享同一硬件测试环境时的**按 job 串行**控制。

## 核心特性

- **两个 Runner 均可 Idle**：不再 wrapping 整个 run.sh，Runner 可正常连接 GitHub
- **仅在 job 执行时持锁**：通过 `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` 实现
- **零外部依赖**：flock + Bash，单机部署即可

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

## 依赖

- `flock`（通常随 util-linux 提供）
- Bash

## 参考

- [多组织共享集成测试环境问题分析与解决方案](https://github.com/orgs/arceos-hypervisor/discussions/341)
- [GitHub Docs: Running scripts before or after a job](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)
