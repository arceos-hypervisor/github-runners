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
RUNNER_NAME_SAFE="${RUNNER_NAME:-unknown-runner}"
RUN_ID_SAFE="${GITHUB_RUN_ID:-unknown}"
RUN_ATTEMPT_SAFE="${GITHUB_RUN_ATTEMPT:-unknown}"
RUN_KEY="${RUNNER_NAME_SAFE}.${RUN_ID_SAFE}.${RUN_ATTEMPT_SAFE}"
LOCK_FILE="${LOCK_DIR}/${RESOURCE_ID}.lock"
RELEASE_FILE="${LOCK_DIR}/${RESOURCE_ID}.${RUN_KEY}.release"
HOLDER_PID_FILE="${LOCK_DIR}/${RESOURCE_ID}.holder"

if ! mkdir -p "${LOCK_DIR}" 2>/dev/null; then
  echo "[$(date -Iseconds)] ❌ Cannot create lock dir ${LOCK_DIR}" >&2
  exit 1
fi
chmod 1777 "${LOCK_DIR}" 2>/dev/null || true

# 如果目录不可写，给出明确提示后退出
if ! touch "${LOCK_DIR}/.write-test" 2>/dev/null; then
  echo "[$(date -Iseconds)] ❌ Lock dir ${LOCK_DIR} is not writable by user $(id -un)." >&2
  echo "[$(date -Iseconds)]    Fix on runner host: sudo chmod 1777 ${LOCK_DIR}" >&2
  exit 1
fi
rm -f "${LOCK_DIR}/.write-test" || true

# 清理当前 run 的残留释放标记，避免误判为可释放
rm -f "${RELEASE_FILE}" || true

# 打开锁文件并获取排他锁（阻塞等待）
exec 200>"${LOCK_FILE}"
chmod 666 "${LOCK_FILE}" 2>/dev/null || true
echo "[$(date -Iseconds)] ⏳ Waiting for lock: ${RESOURCE_ID}" >&2
# 后台每 10s 打印一次，便于在第二个 job 的日志中看到等待状态（避免在 echo 中嵌套括号与引号，防止部分 bash 误解析）
(
  i=0
  while true; do
    sleep 10
    i=$((i + 10))
    ts="$(date -Iseconds)"
    printf '%s ⏳ Still waiting for lock: %s after %ss\n' "${ts}" "${RESOURCE_ID}" "${i}" >&2
  done
) &
WAITER_PID=$!
flock -x 200
kill "${WAITER_PID}" 2>/dev/null || true
wait "${WAITER_PID}" 2>/dev/null || true
echo "[$(date -Iseconds)] ✅ Acquired lock for ${RESOURCE_ID}" >&2

# 后台子进程继承 fd 200 并持有锁，等待 post-job 创建释放文件
(
  holder_pid="${BASHPID:-$$}"
  printf '%s %s %s %s\n' \
    "${holder_pid}" \
    "${RUNNER_NAME_SAFE}" \
    "${RUN_ID_SAFE}" \
    "${RUN_ATTEMPT_SAFE}" > "${HOLDER_PID_FILE}"
  chmod 666 "${HOLDER_PID_FILE}" 2>/dev/null || true

  while [ ! -f "${RELEASE_FILE}" ]; do
    sleep 1
  done

  # 仅清理由自己写入的 holder 记录，避免并发切换时误删新 holder 信息
  current_holder_pid=""
  if [ -f "${HOLDER_PID_FILE}" ]; then
    read -r current_holder_pid _ < "${HOLDER_PID_FILE}" || true
  fi
  rm -f "${RELEASE_FILE}" || true
  if [ "${current_holder_pid}" = "${holder_pid}" ]; then
    rm -f "${HOLDER_PID_FILE}" || true
  fi
) &

# 主脚本退出，子进程继续持有 fd 200，锁保持到 post-job 执行
exit 0
