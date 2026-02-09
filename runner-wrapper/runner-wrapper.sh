#!/bin/bash
# runner-wrapper.sh - 多组织共享硬件测试环境的 Runner 入口脚本（Job 级别锁）
#
# 用途：在多个 GitHub 组织的 Runner 共享同一硬件设备时，通过 Pre/Post Job 钩子
#       实现「仅在 job 执行阶段」的串行访问，避免并发访问串口、电源等独占资源。
#
# 与旧版区别：不再在整个 run.sh 生命周期持锁，而是：
#   - 两个 Runner 均可连接 GitHub 并显示 Idle
#   - 仅在 job 开始前获取锁、job 结束后释放锁，实现按 job 串行
#
# 实现：利用 ACTIONS_RUNNER_HOOK_JOB_STARTED / ACTIONS_RUNNER_HOOK_JOB_COMPLETED
#       调用 pre-job-lock.sh 和 post-job-lock.sh
#
# 参考：https://github.com/orgs/arceos-hypervisor/discussions/341
#
# 用法：
#   1. 将 run.sh 的入口替换为此脚本（或通过 docker command 调用）
#   2. 设置 RUNNER_RESOURCE_ID 指定锁资源（默认 default-hardware）
#   3. 多个 Runner 使用相同 RUNNER_RESOURCE_ID 时，job 将串行执行

set -e

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/home/runner/run.sh}"

# 导出 Job 钩子，使 Runner 在 job 开始/结束时调用锁脚本
export ACTIONS_RUNNER_HOOK_JOB_STARTED="${WRAPPER_DIR}/pre-job-lock.sh"
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED="${WRAPPER_DIR}/post-job-lock.sh"

# 锁相关环境变量（pre-job-lock.sh 和 post-job-lock.sh 会读取）
export RUNNER_RESOURCE_ID="${RUNNER_RESOURCE_ID:-default-hardware}"
export RUNNER_LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"

# 直接执行 run.sh，不持锁（Runner 可正常连接 GitHub）
if [ -x "${RUNNER_SCRIPT}" ] || [ -f "${RUNNER_SCRIPT}" ]; then
  exec "${RUNNER_SCRIPT}" "$@"
else
  echo "Error: Runner script not found: ${RUNNER_SCRIPT}" >&2
  exit 1
fi
