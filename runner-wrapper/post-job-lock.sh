#!/bin/bash
# post-job-lock.sh - Job 结束后释放硬件锁
#
# 作为 ACTIONS_RUNNER_HOOK_JOB_COMPLETED 钩子使用，创建释放文件，
# 使 pre-job-lock.sh 中启动的 holder 子进程退出并释放 flock。
#
# 依赖：RUNNER_RESOURCE_ID、RUNNER_LOCK_DIR 环境变量

LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
RESOURCE_ID="${RUNNER_RESOURCE_ID:-default-hardware}"
RELEASE_FILE="${LOCK_DIR}/${RESOURCE_ID}.release"

echo "[$(date -Iseconds)] 🔓 Releasing lock for ${RESOURCE_ID}" >&2
touch "${RELEASE_FILE}"

# Holder 会在 1 秒内检测到并退出，锁随之释放
exit 0
