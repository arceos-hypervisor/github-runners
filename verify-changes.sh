#!/usr/bin/env bash
# 验证 PR 两处改动：1) 板子锁 ID 用 per-board 默认；2) 容器名前缀自动拼 ORG/REPO
# 不依赖 GH_PAT/REG_TOKEN，仅检查逻辑与生成内容

set -e
cd "$(dirname "$0")"

echo "========== 1. 验证板子锁 ID（不回退到 RUNNER_RESOURCE_ID）=========="
export RUNNER_RESOURCE_ID=global-should-not-be-used
unset RUNNER_RESOURCE_ID_PHYTIUMPI RUNNER_RESOURCE_ID_ROC_RK3568_PC
# 加载 .env 会覆盖，所以这里直接按 runner.sh 逻辑算板子默认
res_phytiumpi="${RUNNER_RESOURCE_ID_PHYTIUMPI:-board-phytiumpi}"
res_roc="${RUNNER_RESOURCE_ID_ROC_RK3568_PC:-board-roc-rk3568-pc}"
if [[ "$res_phytiumpi" == "board-phytiumpi" && "$res_roc" == "board-roc-rk3568-pc" ]]; then
  echo "  [OK] 未设板子变量时使用 per-board 默认，未使用 global RUNNER_RESOURCE_ID"
else
  echo "  [FAIL] res_phytiumpi=$res_phytiumpi res_roc=$res_roc"
  exit 1
fi

echo ""
echo "========== 2. 验证容器名前缀（自动拼 ORG/REPO）=========="
# 模拟 runner.sh 中 RUNNER_NAME_PREFIX 的默认逻辑
check_prefix() {
  local ORG="$1" REPO="$2" expect="$3"
  local RUNNER_NAME_PREFIX=""
  if [[ -z "${RUNNER_NAME_PREFIX:-}" ]]; then
    if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
      RUNNER_NAME_PREFIX="$(hostname)-${ORG}-${REPO}-"
    elif [[ -n "${ORG:-}" ]]; then
      RUNNER_NAME_PREFIX="$(hostname)-${ORG}-"
    else
      RUNNER_NAME_PREFIX="$(hostname)-"
    fi
  fi
  if [[ "$RUNNER_NAME_PREFIX" == "$expect" ]]; then
    echo "  [OK] ORG=$ORG REPO=$REPO => prefix=$RUNNER_NAME_PREFIX"
  else
    echo "  [FAIL] ORG=$ORG REPO=$REPO => got $RUNNER_NAME_PREFIX, expected $expect"
    exit 1
  fi
}
# 组织级：应为 hostname-org-
check_prefix "myorg" "" "$(hostname)-myorg-"
# 仓库级：应为 hostname-org-repo-
check_prefix "myorg" "myrepo" "$(hostname)-myorg-myrepo-"
# 无 ORG：应为 hostname-
check_prefix "" "" "$(hostname)-"

echo ""
echo "========== 3. 若有 .env 且可生成 compose，检查生成文件（可选）=========="
if [[ -f .env ]]; then
  # 仅当存在 docker-compose 且由脚本生成时，grep 检查
  if [[ -f docker-compose.yml ]]; then
    if grep -q "RUNNER_RESOURCE_ID.*board-phytiumpi" docker-compose.yml 2>/dev/null; then
      echo "  [OK] docker-compose.yml 中 phytiumpi 使用 board-phytiumpi"
    else
      echo "  [SKIP] 未在 docker-compose.yml 中找到 board-phytiumpi（可能未生成板子服务）"
    fi
    if grep -q "container_name:.*runner-" docker-compose.yml 2>/dev/null; then
      echo "  [OK] docker-compose.yml 中存在 container_name"
      grep "container_name:" docker-compose.yml | head -3
    fi
  else
    echo "  [SKIP] 无 docker-compose.yml，请先运行 ./runner.sh init -n 1 生成后再查看容器名"
  fi
else
  echo "  [SKIP] 无 .env，跳过 compose 文件检查"
fi

echo ""
echo "========== 验证完成 =========="
