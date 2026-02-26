#!/bin/bash
# post-job-lock.sh - Job 结束后释放硬件锁
#
# 作为 ACTIONS_RUNNER_HOOK_JOB_COMPLETED 钩子使用，创建释放文件，
# 使 pre-job-lock.sh 中启动的 holder 子进程退出并释放 flock。
#
# 依赖：RUNNER_RESOURCE_ID、RUNNER_LOCK_DIR 环境变量

set -e

LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
RESOURCE_ID="${RUNNER_RESOURCE_ID:-default-hardware}"
RUNNER_NAME_SAFE="${RUNNER_NAME:-unknown-runner}"
RUN_ID_SAFE="${GITHUB_RUN_ID:-unknown}"
RUN_ATTEMPT_SAFE="${GITHUB_RUN_ATTEMPT:-unknown}"
RUN_KEY="${RUNNER_NAME_SAFE}.${RUN_ID_SAFE}.${RUN_ATTEMPT_SAFE}"
RELEASE_FILE="${LOCK_DIR}/${RESOURCE_ID}.${RUN_KEY}.release"
HOLDER_PID_FILE="${LOCK_DIR}/${RESOURCE_ID}.holder"

echo "[$(date -Iseconds)] 🔓 Releasing lock for ${RESOURCE_ID}" >&2
mkdir -p "${LOCK_DIR}"
chmod 1777 "${LOCK_DIR}" || true

# 仅允许当前持锁 runner 释放，防止 cancel 后旧 post-hook 误释放新任务锁
if [ ! -f "${HOLDER_PID_FILE}" ]; then
  echo "[$(date -Iseconds)] ⚠️ Holder file not found, skip releasing: ${RESOURCE_ID}" >&2
  exit 0
fi

holder_pid=""
holder_runner=""
holder_run_id=""
holder_run_attempt=""
read -r holder_pid holder_runner holder_run_id holder_run_attempt < "${HOLDER_PID_FILE}" || true

if [ -z "${holder_runner}" ] || [ "${holder_runner}" != "${RUNNER_NAME_SAFE}" ]; then
  echo "[$(date -Iseconds)] ⚠️ Holder runner mismatch (holder=${holder_runner:-unknown}, current=${RUNNER_NAME_SAFE}), skip releasing ${RESOURCE_ID}" >&2
  exit 0
fi

if [ -z "${holder_run_id}" ] || [ "${holder_run_id}" != "${RUN_ID_SAFE}" ] || \
   [ -z "${holder_run_attempt}" ] || [ "${holder_run_attempt}" != "${RUN_ATTEMPT_SAFE}" ]; then
  echo "[$(date -Iseconds)] ⚠️ Holder run mismatch (holder=${holder_run_id:-unknown}/${holder_run_attempt:-unknown}, current=${RUN_ID_SAFE}/${RUN_ATTEMPT_SAFE}), skip releasing ${RESOURCE_ID}" >&2
  exit 0
fi

touch "${RELEASE_FILE}" || {
  echo "[$(date -Iseconds)] ⚠️ Failed to create release mark: ${RELEASE_FILE}" >&2
  # 避免因释放标记写入失败让 job 直接失败，后续由运维处理锁目录权限
  exit 0
}

# Holder 会在 1 秒内检测到并退出，锁随之释放
exit 0
