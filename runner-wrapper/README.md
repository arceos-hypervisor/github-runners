# Runner Wrapper - 多组织共享硬件锁

基于文件锁的 GitHub Actions Runner 包装脚本，用于多组织共享同一硬件测试环境时的并发控制。

## 快速使用

```bash
chmod +x runner-wrapper.sh
export RUNNER_RESOURCE_ID=hardware-test-1
export RUNNER_SCRIPT=/home/runner/run.sh
./runner-wrapper.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RUNNER_RESOURCE_ID` | `default-hardware` | 锁资源 ID，相同 ID 的 Runner 串行执行 |
| `RUNNER_SCRIPT` | `/home/runner/run.sh` | 实际 Runner 脚本路径 |
| `RUNNER_LOCK_DIR` | `/tmp/github-runner-locks` | 锁文件目录 |

## 依赖

- `flock`（通常随 util-linux 提供）
- Bash

## 参考

- [多组织共享集成测试环境问题分析与解决方案](https://github.com/orgs/arceos-hypervisor/discussions/341)
