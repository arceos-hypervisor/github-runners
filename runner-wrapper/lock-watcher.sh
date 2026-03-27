#!/usr/bin/env bash
set -euo pipefail

# lock-watcher.sh - 简单的文件锁清理脚本
#
# 场景：
# - pre-job-lock.sh 在获取锁时可能因为网络/runner 异常导致锁长期不释放
# - GitHub 前端 Cancel workflow 后，run 状态变为 cancelled，但本地锁文件还在
# - 本脚本定期检查 holder 文件中的 run_id，对应 run 如已 cancelled，则强制清理解锁
#
# 使用方式（示例，在宿主机上运行）：
#   export ORG=yoinspiration
#   export REPO=test-runner
#   export GITHUB_TOKEN=github_pat_xxx        # 具备 Actions 只读权限
#   export RUNNER_RESOURCE_IDS="board-roc board-phytiumpi"   # 多块板子空格分隔；或单块用 RUNNER_RESOURCE_ID
#   export RUNNER_LOCK_DIR=/tmp/github-runner-locks
#   ./runner-wrapper/lock-watcher.sh
#
# 必要环境变量：
#   ORG, REPO, GITHUB_TOKEN
# 可选环境变量：
#   RUNNER_RESOURCE_IDS（空格分隔的多个锁 ID，与 runner.sh 集成时自动传）
#   RUNNER_RESOURCE_ID（单个锁 ID，RUNNER_RESOURCE_IDS 未设时使用）
#   RUNNER_LOCK_DIR（默认：/tmp/github-runner-locks）
#   INTERVAL（轮询间隔秒，默认 10）

: "${ORG:?ORG is required, e.g. yoinspiration}"
: "${REPO:?REPO is required, e.g. test-runner}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required (with Actions read permission)}"

LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
INTERVAL="${INTERVAL:-10}"

# 资源 ID 列表：支持多块板子，空格分隔
if [[ -n "${RUNNER_RESOURCE_IDS:-}" ]]; then
  RESOURCE_IDS=(${RUNNER_RESOURCE_IDS})
else
  RESOURCE_IDS=("${RUNNER_RESOURCE_ID:-default-hardware}")
fi

api_base="${GITHUB_API_URL:-https://api.github.com}"

echo "[lock-watcher] monitoring ${ORG}/${REPO}, resources=${RESOURCE_IDS[*]}, lock_dir=${LOCK_DIR}, interval=${INTERVAL}s"

while true; do
  for RUNNER_RESOURCE_ID in "${RESOURCE_IDS[@]}"; do
    holder_file="${LOCK_DIR}/${RUNNER_RESOURCE_ID}.holder"

    if [[ ! -f "${holder_file}" ]]; then
      continue
    fi

    # holder 文件格式: PID RUNNER_NAME RUN_ID RUN_ATTEMPT
    holder_pid=""
    holder_runner=""
    holder_run_id=""
    holder_run_attempt=""
    if ! read -r holder_pid holder_runner holder_run_id holder_run_attempt < "${holder_file}"; then
      echo "[lock-watcher] failed to read holder file ${holder_file}" >&2
      continue
    fi

    if [[ -z "${holder_run_id:-}" || "${holder_run_id}" == "unknown" ]]; then
      continue
    fi

    run_url="${api_base}/repos/${ORG}/${REPO}/actions/runs/${holder_run_id}"
    resp="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${run_url}" || true)"

    if [[ -z "${resp}" ]]; then
      echo "[lock-watcher] empty response for run_id=${holder_run_id}, skip" >&2
      continue
    fi

    # 优先使用 jq 解析；若 jq 不可用，则退化为空字符串（不报错）
    if command -v jq >/dev/null 2>&1; then
      status="$(printf '%s\n' "${resp}" | jq -r '.status // empty' 2>/dev/null || true)"
      conclusion="$(printf '%s\n' "${resp}" | jq -r '.conclusion // empty' 2>/dev/null || true)"
    else
      status=""
      conclusion=""
    fi

    echo "[lock-watcher] resource=${RUNNER_RESOURCE_ID} run_id=${holder_run_id} status=${status:-<none>} conclusion=${conclusion:-<none>} pid=${holder_pid} holder_runner=${holder_runner}"

    # 如果 workflow 已取消，认为这个锁可以强制释放
    if [[ "${status}" == "completed" && "${conclusion}" == "cancelled" ]]; then
      echo "[lock-watcher] detected cancelled workflow, force releasing lock for ${RUNNER_RESOURCE_ID}" >&2

      # 尝试在宿主机上杀掉同名 PID（注意：容器内/宿主机 PID 命名空间不同，可能杀不到，仅 best-effort）
      if [[ -n "${holder_pid}" && "${holder_pid}" =~ ^[0-9]+$ ]]; then
        kill "${holder_pid}" 2>/dev/null || true
      fi

      # 清理 holder 和对应的 release 标记，让后续等待不再被旧锁阻塞
      rm -f "${holder_file}" 2>/dev/null || true
      rm -f "${LOCK_DIR}/${RUNNER_RESOURCE_ID}."*.release 2>/dev/null || true
    fi
  done

  sleep "${INTERVAL}"
done

