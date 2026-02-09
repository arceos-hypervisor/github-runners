#!/bin/bash
# pre-job-lock.sh - Job 开始前获取硬件锁
#
# 作为 ACTIONS_RUNNER_HOOK_JOB_STARTED 钩子使用，在 job 执行前获取 flock，
# 阻塞直到锁可用。通过后台子进程持有锁，直到 post-job-lock.sh 创建释放文件。
#
# 依赖：flock（util-linux）、RUNNER_RESOURCE_ID、RUNNER_LOCK_DIR 环境变量

set -e

LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
RESOURCE_ID="${RUNNER_RESOURCE_ID:-default-hardware}"
LOCK_FILE="${LOCK_DIR}/${RESOURCE_ID}.lock"
RELEASE_FILE="${LOCK_DIR}/${RESOURCE_ID}.release"
HOLDER_PID_FILE="${LOCK_DIR}/${RESOURCE_ID}.holder"

mkdir -p "${LOCK_DIR}"

# 打开锁文件并获取排他锁（阻塞等待）
exec 200>"${LOCK_FILE}"
echo "[$(date -Iseconds)] ⏳ Waiting for lock: ${RESOURCE_ID}" >&2
flock -x 200
echo "[$(date -Iseconds)] ✅ Acquired lock for ${RESOURCE_ID}" >&2

# 后台子进程继承 fd 200 并持有锁，等待 post-job 创建释放文件
(
  while [ ! -f "${RELEASE_FILE}" ]; do
    sleep 1
  done
  rm -f "${RELEASE_FILE}" "${HOLDER_PID_FILE}"
) &
echo $! > "${HOLDER_PID_FILE}"

# 主脚本退出，子进程继续持有 fd 200，锁保持到 post-job 执行
exit 0
