#!/bin/bash
# runner-wrapper.sh - 多组织共享硬件测试环境的 Runner 锁包装脚本
#
# 用途：在多个 GitHub 组织的 Runner 共享同一硬件设备时，通过文件锁实现串行执行，
#       避免并发访问串口、电源控制等独占资源导致的测试失败。
#
# 参考：https://github.com/orgs/arceos-hypervisor/discussions/341
#      方案三 - 实施方案 3.2：基于文件锁的简单方案
#
# 用法：
#   1. 将 run.sh 替换为此脚本的调用，或通过 systemd/entrypoint 调用
#   2. 设置环境变量 RUNNER_RESOURCE_ID 指定锁资源（默认 default-hardware）
#   3. 多个 Runner 使用相同 RUNNER_RESOURCE_ID 时，将串行执行
#
# 依赖：flock（通常随 util-linux 提供）

set -e

LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
RESOURCE_ID="${RUNNER_RESOURCE_ID:-default-hardware}"
LOCK_FILE="${LOCK_DIR}/${RESOURCE_ID}.lock"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/home/runner/run.sh}"

# 从 GitHub Actions 环境变量获取任务信息（Runner 执行时由 GitHub 注入）
ORG_NAME="${GITHUB_REPOSITORY_OWNER:-unknown}"
REPO_NAME="${GITHUB_REPOSITORY:-unknown}"
REPO_NAME="${REPO_NAME##*/}"  # 取 repo 部分

# 创建锁目录
mkdir -p "${LOCK_DIR}"

# 清理函数：释放锁并退出
cleanup() {
  local exit_code=$?
  echo "[$(date -Iseconds)] 🔓 Releasing lock for ${RESOURCE_ID}"
  flock -u 200 2>/dev/null || true
  rm -f "${LOCK_FILE}"
  exit "${exit_code}"
}

# 捕获退出信号
trap cleanup EXIT INT TERM

# 获取排他锁（阻塞等待）
echo "[$(date -Iseconds)] ⏳ Waiting for lock: ${RESOURCE_ID}"
echo "[$(date -Iseconds)]    Requested by: ${ORG_NAME}/${REPO_NAME}"

exec 200>"${LOCK_FILE}"
flock -x 200

echo "[$(date -Iseconds)] ✅ Acquired lock for ${RESOURCE_ID}"
echo "[$(date -Iseconds)]    Owner: ${ORG_NAME}/${REPO_NAME}"
echo "[$(date -Iseconds)]    Started at: $(date)"

# 执行实际的 Runner 任务（不使用 exec，以便退出时 trap 能正确释放锁）
if [ -x "${RUNNER_SCRIPT}" ] || [ -f "${RUNNER_SCRIPT}" ]; then
  "${RUNNER_SCRIPT}" "$@"
else
  echo "Error: Runner script not found or not executable: ${RUNNER_SCRIPT}" >&2
  echo "Set RUNNER_SCRIPT to the path of run.sh (e.g. /home/runner/run.sh)" >&2
  exit 1
fi
