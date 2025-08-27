#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE="${ENV_FILE:-.env}"

# ------------------------------- load .env file -------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/export /')
fi

ORG="${ORG:-}"
GH_PAT="${GH_PAT:-}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,docker}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:+${RUNNER_NAME_PREFIX}-}"
RUNNER_COUNT="${RUNNER_COUNT:-2}"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
MOUNT_DOCKER_SOCK="${MOUNT_DOCKER_SOCK:-}"

# 镜像设置：用于 compose 渲染与本地构建
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_CUSTOM_IMAGE="${RUNNER_CUSTOM_IMAGE:-qc-actions-runner:v0.0.1}"
DOCKERFILE_HASH_FILE="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"

# Loop device/privilege handling (to avoid 'failed to setup loop device')
PRIVILEGED="${PRIVILEGED:-true}"
ADD_SYS_ADMIN_CAP="${ADD_SYS_ADMIN_CAP:-true}"
MAP_LOOP_DEVICES="${MAP_LOOP_DEVICES:-true}"
LOOP_DEVICE_COUNT="${LOOP_DEVICE_COUNT:-4}"
ADD_DEVICE_CGROUP_RULES="${ADD_DEVICE_CGROUP_RULES:-true}"
# kvm 相关处理
MAP_KVM_DEVICE="${MAP_KVM_DEVICE:-true}"
KVM_GROUP_ADD="${KVM_GROUP_ADD:-true}"
MOUNT_UDEV_RULES_DIR="${MOUNT_UDEV_RULES_DIR:-true}"

# REG_TOKEN cache control
REG_TOKEN_CACHE_FILE="${REG_TOKEN_CACHE_FILE:-.reg_token.cache}"
REG_TOKEN_CACHE_TTL="${REG_TOKEN_CACHE_TTL:-300}" # seconds, default 5 minutes

# ------------------------------- Helpers -------------------------------
shell_usage() {
  local COLW=48
  echo "用法: ./runner.sh COMMAND [选项]    其中，[选项] 由 COMMAND 决定，可用 COMMAND 如下所示："
  echo

  echo "1. 初始化/扩缩相关命令:"
  printf "  %-${COLW}s %s\n" "./runner.sh init [-n N]" "生成 N 个服务并启动（默认使用 .env 中 RUNNER_COUNT）"
  printf "  %-${COLW}s %s\n" "" "首次会向组织申请注册令牌并持久化到各自卷中"
  printf "  %-${COLW}s %s\n" "./runner.sh scale N" "将 Runner 数量调整为 N；启动 1 .. N，停止其他的（保留卷）"
  # 已移除 build 子命令：自动构建由脚本内部完成
  echo

  echo "2. 单实例操作相关命令:"
  printf "  %-${COLW}s %s\n" "./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]" "注册指定实例；不带参数默认遍历所有已存在实例"
  printf "  %-${COLW}s %s\n" "./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]" "启动指定实例（会按需注册）；不带参数默认遍历所有已存在实例"
  printf "  %-${COLW}s %s\n" "./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]" "直接停止 Runner 容器；不带参数默认遍历所有已存在实例"
  printf "  %-${COLW}s %s\n" "./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]" "重启指定实例；不带参数默认遍历所有已存在实例"
  printf "  %-${COLW}s %s\n" "./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>" "跟随查看指定实例日志"
  echo

  echo "3. 查询相关命令:"
  printf "  %-${COLW}s %s\n" "./runner.sh ps" "查看相关容器的状态"
  printf "  %-${COLW}s %s\n" "./runner.sh list" "同时显示相关容器的状态 + 注册的 Runner 状态"
  echo

  echo "4. 删除相关命令:"
  printf "  %-${COLW}s %s\n" "./runner.sh rm|remove|delete [${RUNNER_NAME_PREFIX}runner-<id> ...]" "删除指定实例；不带参数删除全部（需确认，-y 跳过）"
  printf "  %-${COLW}s %s\n" "./runner.sh purge [-y]" "在 remove 的基础上再删除动态生成的 docker-compose.yml 文件"
  echo

  echo "5. 帮助"
  printf "  %-${COLW}s %s\n" "./runner.sh help" "显示本说明"
  echo

  echo "环境变量（来自 .env 文件或交互输入）:"
  local KEYW=24
  printf "  %-${KEYW}s %s\n" "ORG" "组织名称（必填）"
  printf "  %-${KEYW}s %s\n" "GH_PAT" "Classic PAT（需 admin:org 权限），用于组织 API 与注册令牌"
  printf "  %-${KEYW}s %s\n" "RUNNER_LABELS" "示例: self-hosted,linux,docker"
  printf "  %-${KEYW}s %s\n" "RUNNER_GROUP" "Runner 组（可选）"
  printf "  %-${KEYW}s %s\n" "RUNNER_NAME_PREFIX" "Runner 命名前缀"
  printf "  %-${KEYW}s %s\n" "RUNNER_COUNT" "start/scale 默认数量"
  printf "  %-${KEYW}s %s\n" "DISABLE_AUTO_UPDATE" '"1" 表示禁用 Runner 自更新'
  printf "  %-${KEYW}s %s\n" "RUNNER_WORKDIR" "工作目录（默认 /runner/_work）"
  printf "  %-${KEYW}s %s\n" "MOUNT_DOCKER_SOCK" '"true"/"1" 表示挂载 /var/run/docker.sock（高权限，谨慎）'
  printf "  %-${KEYW}s %s\n" "RUNNER_IMAGE" "用于生成 compose 的镜像（默认 ghcr.io/actions/actions-runner:latest）"
  printf "  %-${KEYW}s %s\n" "RUNNER_CUSTOM_IMAGE" "自动构建时使用的镜像 tag（可重写）"
  printf "  %-${KEYW}s %s\n" "PRIVILEGED" "是否以 privileged 运行（默认 true，建议: 解决 loop device 问题）"
  printf "  %-${KEYW}s %s\n" "ADD_SYS_ADMIN_CAP" "当不启用 privileged 时，添加 SYS_ADMIN 能力（默认 true）"
  printf "  %-${KEYW}s %s\n" "MAP_LOOP_DEVICES" "是否映射宿主 /dev/loop* 到容器（默认 true）"
  printf "  %-${KEYW}s %s\n" "LOOP_DEVICE_COUNT" "最多映射的 loop 设备数量（默认 4）"
  printf "  %-${KEYW}s %s\n" "ADD_DEVICE_CGROUP_RULES" "当不启用 privileged 时，添加 device_cgroup_rules 以允许 loop（默认 true）"
  printf "  %-${KEYW}s %s\n" "MAP_KVM_DEVICE" "是否映射 /dev/kvm 到容器（默认 true，存在时）"
  printf "  %-${KEYW}s %s\n" "KVM_GROUP_ADD" "将容器加入宿主 /dev/kvm 的 GID（默认 true）"
  printf "  %-${KEYW}s %s\n" "MOUNT_UDEV_RULES_DIR" "为 /etc/udev/rules.d 提供挂载以确保目录存在（默认 true）"

  echo
  echo "工作流 runs-on 示例: runs-on: [self-hosted, linux, docker]"

  echo
  echo "提示:"
  echo "- 动态生成的 docker-compose.yml 会覆盖同名文件（存量容器不受影响）。"
  echo "- 重新 start/scale/up 会复用已有卷，不会丢失 Runner 配置与工具缓存。"
}

shell_die() { echo "[ERROR] $*" >&2; exit 1; }
shell_info() { echo "[INFO] $*"; }
shell_warn() { echo "[WARN] $*" >&2; }

shell_prompt_confirm() {
  # 返回 0 表示确认，1 表示取消
  local prompt="${1:-确认执行吗? [y/N]} "
  read -r -p "$prompt" ans
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" ]]
}

shell_get_org_and_pat() {
  # Fast path when both provided via env/.env
  if [[ -n "${ORG:-}" && -n "${GH_PAT:-}" ]]; then
    return 0
  fi

  # Detect interactive TTY; if not interactive, require env values
  local has_tty=0
  if [[ -t 0 || -t 1 || -t 2 ]]; then has_tty=1; fi
  if [[ $has_tty -eq 0 ]]; then
    [[ -n "${ORG:-}" && -n "${GH_PAT:-}" ]] || \
      shell_die "ORG/GH_PAT 不能为空（非交互环境请通过环境变量或 .env 提供）。"
    return 0
  fi

  # Prompt using /dev/tty so it works inside command substitutions
  local wrote_env=0
  if [[ -z "${ORG:-}" ]]; then
    while true; do
      if [[ -e /dev/tty ]]; then
        printf "请输入组织名（与 github.com 上一致）: " > /dev/tty
        IFS= read -r ORG < /dev/tty || true
      else
        read -rp "请输入组织名（与 github.com 上一致）: " ORG || true
      fi
      ORG="$(printf '%s' "${ORG:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$ORG" ]] && break
      printf "[WARN] 组织名不能为空，请重试。\n" > /dev/tty
    done
    wrote_env=1
  fi

  if [[ -z "${GH_PAT:-}" ]]; then
    while true; do
      if [[ -e /dev/tty ]]; then
        printf "请输入 Classic PAT（admin:org）（输入不可见）: " > /dev/tty
        IFS= read -rs GH_PAT < /dev/tty || true; echo > /dev/tty
      else
        echo -n "请输入 Classic PAT（admin:org）（输入不可见）: " >&2
        read -rs GH_PAT || true; echo >&2
      fi
      GH_PAT="$(printf '%s' "${GH_PAT:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$GH_PAT" ]] && break
      printf "[WARN] PAT 不能为空，请重试。\n" > /dev/tty
    done
    wrote_env=1
  fi

  export ORG GH_PAT

  # Persist to .env (ENV_FILE) if values were entered interactively
  if [[ $wrote_env -eq 1 ]]; then
    local env_file="$ENV_FILE" tmp
    touch "$env_file"
    chmod 600 "$env_file" 2>/dev/null || true

    if [[ -n "${ORG:-}" ]]; then
      tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
      grep -v -E '^[[:space:]]*ORG=' "$env_file" > "$tmp" || true
      printf 'ORG=%s\n' "$ORG" >> "$tmp"
      mv "$tmp" "$env_file"
    fi
    if [[ -n "${GH_PAT:-}" ]]; then
      tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
      grep -v -E '^[[:space:]]*GH_PAT=' "$env_file" > "$tmp" || true
      printf 'GH_PAT=%s\n' "$GH_PAT" >> "$tmp"
      mv "$tmp" "$env_file"
    fi
  fi
}

# 根据 Dockerfile 与本地镜像情况决定镜像；按需构建；通过 echo 返回选中的镜像名
shell_prepare_runner_image() {
  local cmd="${1:-}"
  local base="ghcr.io/actions/actions-runner:latest"
  local current="${RUNNER_IMAGE:-$base}"
  local hash_file="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"

  case "$cmd" in
    init|scale|start|stop|restart|logs)
      ;; # these render compose and may need image preparation
    *)
      echo "$current"
      return 0
      ;;
  esac

  if [[ -f Dockerfile ]]; then
    local new_hash="" old_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
      new_hash=$(sha256sum Dockerfile | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
      new_hash=$(shasum -a 256 Dockerfile | awk '{print $1}')
    fi

    if [[ -n "$new_hash" ]]; then
      [[ -f "$hash_file" ]] && old_hash=$(cat "$hash_file" 2>/dev/null || true)
      if [[ "$new_hash" != "$old_hash" ]]; then
        shell_info "检测到 Dockerfile 变更，开始构建 ${RUNNER_CUSTOM_IMAGE} 镜像" >&2
        docker build -t "${RUNNER_CUSTOM_IMAGE}" . 1>&2
        echo "$new_hash" > "$hash_file"
        shell_info "构建完成。本次将使用 ${RUNNER_CUSTOM_IMAGE} 作为镜像" >&2
        echo "${RUNNER_CUSTOM_IMAGE}"
        return 0
      fi
    fi

    if [[ "$current" == "$base" ]]; then
      if command -v docker >/dev/null 2>&1 && docker image inspect "${RUNNER_CUSTOM_IMAGE}" >/dev/null 2>&1; then
        # shell_info "检测到已存在自定义镜像，优先使用 ${RUNNER_CUSTOM_IMAGE} 作为镜像" >&2
        echo "${RUNNER_CUSTOM_IMAGE}"
        return 0
      fi
    fi
    echo "$current"
    return 0
  else
    # shell_info "未找到 Dockerfile 文件，跳过自定义镜像构建，将使用官方 ${base} 作为镜像！" >&2
    echo "$base"
    return 0
  fi
}

# 生成 docker-compose.yml 文件
shell_render_compose_file() {
  local count="$1"
  [[ "$count" =~ ^[0-9]+$ ]] || shell_die "生成 compose 失败：数量非法！"
  (( count >= 1 )) || shell_die "生成 compose 失败：数量必须 >= 1！"

  shell_info "生成 ${COMPOSE_FILE}（${RUNNER_NAME_PREFIX}runner-1 ... ${RUNNER_NAME_PREFIX}runner-${count}）"
  {
    printf "%s\n" "x-runner-base: &runner_base"
    printf "  %s\n" "image: ${RUNNER_IMAGE}"
    printf "  %s\n" "restart: unless-stopped"
    printf "  %s\n" "environment: &runner_env"
    printf "    %s\n" "RUNNER_ORG_URL: \"https://github.com/${ORG}\""
    printf "    %s\n" "RUNNER_TOKEN: \"${REG_TOKEN}\""
    printf "    %s\n" "RUNNER_LABELS: \"${RUNNER_LABELS}\""
    printf "    %s\n" "RUNNER_GROUP: \"${RUNNER_GROUP}\""
    printf "    %s\n" "RUNNER_REMOVE_ON_STOP: \"false\""
    printf "    %s\n" "DISABLE_AUTO_UPDATE: \"${DISABLE_AUTO_UPDATE}\""
    printf "    %s\n" "RUNNER_WORKDIR: \"${RUNNER_WORKDIR}\""
    printf "    %s\n" "HTTP_PROXY: \"${HTTP_PROXY}\""
    printf "    %s\n" "HTTPS_PROXY: \"${HTTPS_PROXY}\""
    printf "    %s\n" "NO_PROXY: localhost,127.0.0.1,.internal"
    printf "  %s\n" "network_mode: host"

    # privileged
    if [[ "$PRIVILEGED" == "1" || "$PRIVILEGED" == "true" ]]; then
      printf "  %s\n" "privileged: true"
    else
      if [[ "$ADD_SYS_ADMIN_CAP" == "1" || "$ADD_SYS_ADMIN_CAP" == "true" ]]; then
        printf "  %s\n" "cap_add:"
        printf "    - %s\n" "SYS_ADMIN"
      fi
      if [[ "$ADD_DEVICE_CGROUP_RULES" == "1" || "$ADD_DEVICE_CGROUP_RULES" == "true" ]]; then
        printf "  %s\n" "device_cgroup_rules:"
        printf "    - %s\n" "'b 7:* rwm'"
        printf "    - %s\n" "'c 10:237 rwm'"
        printf "    - %s\n" "'c 10:232 rwm'"
      fi
    fi
    # Device mappings (loop and kvm)
    local printed_devices=0
    if [[ "$MAP_LOOP_DEVICES" == "1" || "$MAP_LOOP_DEVICES" == "true" ]]; then
      local j
      for j in $(seq 0 $((LOOP_DEVICE_COUNT-1))); do
        if [[ -e "/dev/loop${j}" ]]; then
          if (( printed_devices == 0 )); then
            printf "  %s\n" "devices:"
            printed_devices=1
            if [[ -e "/dev/loop-control" ]]; then
              printf "    - %s\n" "/dev/loop-control:/dev/loop-control"
            fi
          fi
          printf "    - %s\n" "/dev/loop${j}:/dev/loop${j}"
        fi
      done
    fi
    if [[ "$MAP_KVM_DEVICE" == "1" || "$MAP_KVM_DEVICE" == "true" ]]; then
      if [[ -e "/dev/kvm" ]]; then
        if (( printed_devices == 0 )); then
          printf "  %s\n" "devices:"
          printed_devices=1
        fi
        printf "    - %s\n" "/dev/kvm:/dev/kvm"
      fi
    fi
    if [[ "$KVM_GROUP_ADD" == "1" || "$KVM_GROUP_ADD" == "true" ]]; then
      if [[ -e "/dev/kvm" ]]; then
        local kvm_gid
        kvm_gid="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"
        if [[ -n "$kvm_gid" ]]; then
          printf "  %s\n" "group_add:"
          printf "    - %s\n" "$kvm_gid"
        fi
      fi
    fi

    if [[ "$MOUNT_DOCKER_SOCK" == "1" || "$MOUNT_DOCKER_SOCK" == "true" ]]; then
      printf "  %s\n" "volumes:"
      printf "    - %s\n" "/var/run/docker.sock:/var/run/docker.sock"
    else
      printf "  %s\n" "# 如需在 job 中使用 docker 命令，需挂载宿主 docker.sock（高权限，谨慎）"
      printf "  %s\n" "# volumes:"
      printf "  %s\n" "#   - /var/run/docker.sock:/var/run/docker.sock"
    fi

    echo
    echo "services:"

    local i svc vname
    for i in $(seq 1 "$count"); do
      svc="${RUNNER_NAME_PREFIX}runner-${i}"
      vname="${svc}-data"
      printf "  %s:\n" "$svc"
      printf "    %s\n" "<<: *runner_base"
      printf "    %s\n" "container_name: \"$svc\""
      printf "    %s\n" "command: [\"/home/runner/run.sh\"]"
      printf "    %s\n" "environment:"
      printf "      %s\n" "<<: *runner_env"
      printf "      %s\n" "RUNNER_NAME: \"$svc\""
      printf "    %s\n" "volumes:"
      printf "      - %s\n" "$vname:/home/runner"
      if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
        printf "      - %s\n" "${svc}-udev-rules:/etc/udev/rules.d"
      fi
    done

    echo
    echo "volumes:"
    for i in $(seq 1 "$count"); do
      printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-data:"
      if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
        printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:"
      fi
    done
  } > "$COMPOSE_FILE"
}

# 统一的“删除全部”执行器：统计 -> 提示 -> 注销 -> 本地清理
shell_delete_all_execute() {
  local require_confirm_msg="$1"  # 为空表示无需二次确认

  local prefix cont_list org_count=0 cont_count=0 resp
  prefix="${RUNNER_NAME_PREFIX}runner-"

  if command -v jq >/dev/null 2>&1; then
    resp=$(github_api GET "/actions/runners?per_page=100" || echo "{}")
    org_count=$(echo "$resp" | jq -r --arg p "$prefix" '[.runners[] | select(.name|startswith($p))] | length' 2>/dev/null || echo 0)
  else
    shell_warn "未安装 jq，无法统计组织端 runner 数量，将仅本地删除容器与卷并尽力注销。"
  fi

  cont_list="$(docker_list_existing_containers)"
  if [[ -n "$cont_list" ]]; then cont_count=$(echo "$cont_list" | wc -l | tr -d ' '); fi

  shell_info "即将删除 ${org_count} 个 Runner 以及本机中的 ${cont_count} 个容器和相关数据卷"

  if [[ -n "$require_confirm_msg" ]]; then
    if ! shell_prompt_confirm "$require_confirm_msg"; then
      echo "操作已取消！"; return 130
    fi
  fi

  github_delete_all_runners_with_prefix || true
  docker_remove_all_local_containers_and_volumes || true
  shell_info "批量删除完成！"
}

# Ensure REG_TOKEN is present and not older than TTL; echo it
shell_get_reg_token() {
  local now ts cached_token
  now=$(date +%s)

  if [[ -f "$REG_TOKEN_CACHE_FILE" ]]; then
    ts=$(head -n1 "$REG_TOKEN_CACHE_FILE" 2>/dev/null || true)
    cached_token=$(sed -n '2p' "$REG_TOKEN_CACHE_FILE" 2>/dev/null || true)
    if [[ -n "$ts" && -n "$cached_token" && "$ts" =~ ^[0-9]+$ ]]; then
      if (( now - ts < REG_TOKEN_CACHE_TTL )); then
        REG_TOKEN="$cached_token"
        export REG_TOKEN
        printf '%s\n' "$REG_TOKEN"
        return 0
      fi
    fi
  fi

  if [[ -n "${REG_TOKEN:-}" && "${REG_TOKEN:-}" != "null" ]]; then
    printf '%s\n%s\n' "$now" "$REG_TOKEN" > "$REG_TOKEN_CACHE_FILE"
    export REG_TOKEN
    printf '%s\n' "$REG_TOKEN"
    return 0
  fi

  shell_get_org_and_pat
  shell_info "请求组织注册令牌..." >&2
  local new_token
  new_token="$(github_fetch_reg_token || true)"
  [[ -n "$new_token" && "$new_token" != "null" ]] || shell_die "获取注册令牌失败！"
  REG_TOKEN="$new_token"
  export REG_TOKEN
  printf '%s\n%s\n' "$now" "$REG_TOKEN" > "$REG_TOKEN_CACHE_FILE"
  printf '%s\n' "$REG_TOKEN"
}

# ------------------------------- GitHub API helpers -------------------------------
github_api() {
  local method="$1" path="$2" body="${3:-}"
  [[ -n "${GH_PAT:-}" ]] || shell_die "需要 GH_PAT 以调用组织相关 API！"
  local url="https://api.github.com/orgs/${ORG}${path}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer ${GH_PAT}" \
      -H "Accept: application/vnd.github+json" \
      -d "$body" "$url"
  else
    curl -sS -X "$method" -H "Authorization: Bearer ${GH_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "$url"
  fi
}

github_fetch_reg_token() {
  local resp token
  resp=$(github_api POST "/actions/runners/registration-token") || return 1
  if command -v jq >/dev/null 2>&1; then
    token=$(echo "$resp" | jq -r .token)
  elif command -v python3 >/dev/null 2>&1; then
    token=$(printf '%s' "$resp" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("token", ""))')
  else
    token=$(echo "$resp" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"[:cntrl:]]*\)".*/\1/p' | head -1)
  fi
  echo "${token}"
}

github_get_runner_id_by_name() {
  local name="$1"
  local resp
  resp=$(github_api GET "/actions/runners?per_page=100") || return 1
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq -r --arg n "$name" '.runners[] | select(.name==$n) | .id' | head -1
  else
    echo "$resp" | grep -A3 -F "\"name\": \"${name}\"" | grep -m1 '"id":' | sed 's/[^0-9]//g' | head -1
  fi
}

github_delete_runner_by_id() {
  local id="$1"
  github_api DELETE "/actions/runners/$id" >/dev/null
}

github_delete_all_runners_with_prefix() {
  local prefix="${RUNNER_NAME_PREFIX}runner-"
  local resp
  resp=$(github_api GET "/actions/runners?per_page=100" || echo "{}")
  if command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" && "$id" != "null" ]] || continue
      shell_info "从 Github 上注销: $name (id=$id)"
      github_delete_runner_by_id "$id" || shell_warn "从 Github 上注销 $name 失败，请手动从 Github 网站注销！"
    done < <(echo "$resp" | jq -r --arg p "$prefix" '.runners[] | select(.name|startswith($p)) | "\(.id)\t\(.name)"')
  else
    shell_warn "未安装 jq，无法在组织端批量注销；将仅本地删除容器与卷。"
  fi
}

# ------------------------------- Docker Compose wrappers -------------------------------
docker_pick_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    shell_die "docker compose (v2) 或 docker-compose 未安装。"
  fi
}

DC=$(docker_pick_compose)

docker_compose_up() {
  $DC -f "$COMPOSE_FILE" up -d "$@"; 
}

docker_compose_stop() {
  $DC -f "$COMPOSE_FILE" stop "$@";
}

docker_compose_restart() {
  $DC -f "$COMPOSE_FILE" restart "$@";
}

docker_compose_logs() {
  $DC -f "$COMPOSE_FILE" logs -f "$@";
}

docker_compose_ps() {
  $DC -f "$COMPOSE_FILE" ps;
}

docker_compose_create() {
  $DC -f "$COMPOSE_FILE" create "$@";
}

# Highest existing index among services named "<prefix>runner-<n>" from compose
docker_highest_existing_index() {
  local prefix="${RUNNER_NAME_PREFIX}runner-"
  if [[ ! -f "$COMPOSE_FILE" ]]; then echo 0; return 0; fi
  $DC -f "$COMPOSE_FILE" ps --services --all 2>/dev/null \
    | awk -v p="$prefix" '
        index($0, p) == 1 {
          n = substr($0, length(p) + 1)
          if (n ~ /^[0-9]+$/) {
            val = n + 0
            if (val > max) max = val
          }
        }
        END { if (max == "") print 0; else print max }
      ' || echo 0
}

docker_list_existing_containers() {
  [[ -f "$COMPOSE_FILE" ]] || { echo ""; return 0; }
  $DC -f "$COMPOSE_FILE" ps --services --all | grep -F "${RUNNER_NAME_PREFIX}runner-" || true
}

docker_print_existing_containers_status() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    docker_compose_ps
    return 0
  fi

  # Fallback: query via docker when compose file is absent
  if command -v docker >/dev/null 2>&1; then
    local out
    out="$(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true)"
    printf "%-40s %-10s %s\n" "NAME" "STATE" "STATUS"
    if [[ -n "$out" ]]; then
      awk -v p="^${RUNNER_NAME_PREFIX}runner-[0-9]+$" -F '\t' 'NF>=3 { if ($1 ~ p) printf("%-40s %-10s %s\n", $1, $2, $3) }' <<< "$out"
    fi
  else
    shell_info "未找到 ${COMPOSE_FILE}，且未检测到 docker 命令，无法查询状态。"
  fi
}

# 判断指定容器是否已存在（本地 docker ps -a 名称匹配）
docker_container_exists() {
  local name="$1"
  [[ -f "$COMPOSE_FILE" ]] || return 1
  $DC -f "$COMPOSE_FILE" ps --services --all | grep -qx "$name" >/dev/null 2>&1
}

docker_remove_container_and_volume_by_index() {
  local i="$1"
  local cname="${RUNNER_NAME_PREFIX}runner-${i}"
  if [[ -f "$COMPOSE_FILE" ]]; then
    $DC -f "$COMPOSE_FILE" rm -s -f "$cname" >/dev/null 2>&1 || true
  fi
}

docker_remove_all_local_containers_and_volumes() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    shell_info "使用 docker compose down -v 删除所有服务与卷"
    $DC -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  else
    shell_warn "未找到 ${COMPOSE_FILE}，跳过 compose down -v。"
  fi
}

docker_runner_is_configured() {
  local idx="$1" svc; svc="${RUNNER_NAME_PREFIX}runner-${idx}"
  [[ -f "$COMPOSE_FILE" ]] || return 1
  $DC -f "$COMPOSE_FILE" run --rm --no-deps "$svc" bash -lc 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1
}

docker_runner_register() {
  local idx="$1" force="${2:-0}" name; name="${RUNNER_NAME_PREFIX}runner-${idx}"
  if [[ "$force" != "1" ]] && docker_runner_is_configured "$idx"; then
    shell_info "已配置过，跳过注册: $name"
    return 0
  fi

  local cfg_opts=(
    "--url" "https://github.com/${ORG}"
    "--token" "${REG_TOKEN}"
    "--name" "${name}"
    "--labels" "${RUNNER_LABELS}"
    "--runnergroup" "${RUNNER_GROUP}"
    "--unattended" "--replace"
  )
  if [[ -n "${RUNNER_WORKDIR}" ]]; then
    cfg_opts+=("--work" "${RUNNER_WORKDIR}")
  fi
  if [[ "${DISABLE_AUTO_UPDATE}" == "1" ]]; then
    cfg_opts+=("--disableupdate")
  fi

  if [[ "$force" == "1" ]]; then
    shell_info "在 Github 上重新注册(替换): ${name}"
  else
    shell_info "在 Github 上注册: ${name}"
  fi
  [[ -f "$COMPOSE_FILE" ]] || shell_die "缺少 ${COMPOSE_FILE}，无法使用 compose 进行注册。"
  $DC -f "$COMPOSE_FILE" run --rm --no-deps "$name" bash -lc "/home/runner/config.sh ${cfg_opts[*]}" >/dev/null
}

docker_start_runner_container() {
  local idx="$1" name; name="${RUNNER_NAME_PREFIX}runner-${idx}"
  [[ -f "$COMPOSE_FILE" ]] || shell_die "缺少 ${COMPOSE_FILE}，无法使用 compose 启动 Runner 容器。"
  docker_compose_up "$name"
}

docker_stop_extra_containers_over() {
  local limit="$1" max_exist
  max_exist="$(docker_highest_existing_index)"
  (( max_exist <= limit )) && return 0
  shell_info "停止超出目标的容器: $((limit+1)) .. $max_exist"
  for i in $(seq $((limit+1)) "$max_exist"); do
    local cname; cname="${RUNNER_NAME_PREFIX}runner-$i"
    docker_compose_stop "$cname" || true
  done
}

# ---------- Commands ----------
CMD="${1:-help}"; shift || true
REG_TOKEN="$(shell_get_reg_token)"
RUNNER_IMAGE="$(shell_prepare_runner_image "$CMD")"

case "$CMD" in
  # ./runner.sh help|-h|--help
  help|-h|--help)
    shell_usage
    ;;

  # ./runner.sh ps
  ps)
    docker_print_existing_containers_status
    ;;

  # ./runner.sh list
  list)
    echo "--------------------------------- Containers -----------------------------------------"
    docker_print_existing_containers_status
    echo
    shell_get_org_and_pat
    echo "--------------------------------- Runners --------------------------------------------"
    resp=$(github_api GET "/actions/runners?per_page=100") || shell_die "获取组织 runner 列表失败。"
    if command -v jq >/dev/null 2>&1; then
      echo "$resp" | jq -r '.runners[] | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' \
        | awk -F'\t' 'BEGIN{printf("%-40s %-8s %-6s %s\n","NAME","STATUS","BUSY","LABELS")}{printf("%-40s %-8s %-6s %s\n",$1,$2,$3,$4)}'
    else
      echo "$resp"
    fi
    echo
    shell_info "由于 Github 限制，组织级 Runner 列表最多 100 条！"
    echo
    ;;

  # ./runner.sh init [-n|--count N]
  init)
    count="$RUNNER_COUNT"
    if [[ "${1:-}" == "-n" || "${1:-}" == "--count" ]]; then
      shift
      count="${1:-$RUNNER_COUNT}"
      shift || true
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || shell_die "数量必须是数字！"
    (( count >= 1 )) || shell_die "数量必须 >= 1！"

    shell_render_compose_file "$count"

    docker_compose_up $(for i in $(seq 1 "$count"); do echo -n "${RUNNER_NAME_PREFIX}runner-$i "; done)
    for i in $(seq 1 "$count"); do docker_runner_register "$i"; done
    ;;
  
  # ./runner.sh scale N
  scale)
    count="${1:-$RUNNER_COUNT}"
    [[ -n "$count" ]] || shell_die "缺少数量参数！"
    [[ "$count" =~ ^[0-9]+$ ]] || shell_die "数量必须是数字！"
    (( count >= 1 )) || shell_die "数量必须 >= 1！"

    shell_render_compose_file "$count"

    docker_compose_up $(for i in $(seq 1 "$count"); do echo -n "${RUNNER_NAME_PREFIX}runner-$i "; done)
    docker_stop_extra_containers_over "$count"
    ;;

  # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
  register)
    ids=()
    if [[ $# -ge 1 ]]; then
      for s in "$@"; do
        if ! docker_container_exists "$s"; then
          shell_warn "未找到 $s 对应的 Runner 容器，忽略该参数！"
          continue
        fi
        idx="${s##*-}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        ids+=("$idx")
      done
      if [[ ${#ids[@]} -eq 0 ]]; then
        shell_info "没有可注册的 Runner 容器！"
        exit 0
      fi
    else
      names="$(docker_list_existing_containers)"
      if [[ -z "$names" ]]; then
        shell_info "没有可注册的 Runner 容器！"
        exit 0
      fi
      while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        idx="${cname##*-}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        ids+=("$idx")
      done <<< "$names"
    fi

    for id in "${ids[@]}"; do
      docker_runner_register "$id"
    done
    ;;

  # ./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]
  start)
    ids=(); max_id=0
    if [[ $# -ge 1 ]]; then
      for s in "$@"; do
        if ! docker_container_exists "$s"; then
          shell_warn "未找到 $s 对应的 Runner 容器，忽略该参数！"
          continue
        fi
        ids+=("$s")
        n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done
      if [[ ${#ids[@]} -eq 0 ]]; then
        shell_info "没有可启动的 Runner 容器！"
        exit 0
      fi
    else
      names="$(docker_list_existing_containers)"
      if [[ -z "$names" ]]; then
        shell_info "没有可启动的 Runner 容器！"
        exit 0
      fi
      while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        ids+=("$cname")
        n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done <<< "$names"
    fi

    (( max_id >= 1 )) || max_id=1
    shell_render_compose_file "$max_id"

    # 检查是否有未配置的实例，按需注册
    need_register=0
    declare -a reg_ids=()
    declare -a force_reg_ids=()
    # 获取组织端现有 runners 列表用于判断是否缺失
    org_names=""
    if command -v jq >/dev/null 2>&1; then
      if [[ -n "${ORG:-}" && -n "${GH_PAT:-}" ]]; then
        resp=$(github_api GET "/actions/runners?per_page=100" || echo "{}")
        org_names=$(echo "$resp" | jq -r '.runners[].name' 2>/dev/null || echo "")
      fi
    fi
    for s in "${ids[@]}"; do
      idx="${s##*-}"; [[ "$idx" =~ ^[0-9]+$ ]] || continue
      if ! docker_runner_is_configured "$idx"; then
        need_register=1
        reg_ids+=("$idx")
      else
        if [[ -n "$org_names" ]] && ! echo "$org_names" | grep -qx "$s"; then
          need_register=1
          force_reg_ids+=("$idx")
        fi
      fi
    done
    if [[ "$need_register" -eq 1 ]]; then
      for idx in "${reg_ids[@]}"; do docker_runner_register "$idx" 0; done
      for idx in "${force_reg_ids[@]}"; do docker_runner_register "$idx" 1; done
    fi
    for s in "${ids[@]}"; do
      idx="${s##*-}"; [[ "$idx" =~ ^[0-9]+$ ]] || continue
      docker_start_runner_container "$idx"
    done
    ;;

  # ./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]
  stop)
    if [[ $# -ge 1 ]]; then
      ids=(); max_id=0
      for s in "$@"; do
        if ! docker_container_exists "$s"; then
          shell_warn "未找到 $s 对应的 Runner 容器，忽略该参数！"
          continue
        fi
        ids+=("$s")
        n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done
      if [[ ${#ids[@]} -eq 0 ]]; then
        shell_info "没有可停止的 Runner 容器！"
        exit 0
      fi
      exist_max="$(docker_highest_existing_index)"
      count="$exist_max"; (( max_id > count )) && count="$max_id"
      (( count >= 1 )) || count=1
      shell_render_compose_file "$count"
      docker_compose_stop "${ids[@]}"
    else
      names="$(docker_list_existing_containers)"
      if [[ -z "$names" ]]; then
        shell_info "没有可停止的 Runner 容器！"
        exit 0
      fi
      ids=(); max_id=0
      while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        ids+=("$cname")
        n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done <<< "$names"
      (( max_id >= 1 )) || max_id=1
      shell_render_compose_file "$max_id"
      docker_compose_stop "${ids[@]}"
    fi
    ;;

  # ./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]
  restart)
    ids=(); max_id=0
    if [[ $# -ge 1 ]]; then
      for s in "$@"; do
        if ! docker_container_exists "$s"; then
          shell_warn "未找到 $s 对应的 Runner 容器，忽略该参数！"
          continue
        fi
        ids+=("$s")
        n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done
      if [[ ${#ids[@]} -eq 0 ]]; then
        shell_info "没有可重启的 Runner 容器！"
        exit 0
      fi
    else
      names="$(docker_list_existing_containers)"
      if [[ -z "$names" ]]; then
        shell_info "没有可重启的 Runner 容器！"
        exit 0
      fi
      while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        ids+=("$cname")
        n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
      done <<< "$names"
    fi
    (( max_id >= 1 )) || max_id=1
    shell_render_compose_file "$max_id"
    docker_compose_restart "${ids[@]}"
    ;;

  # ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>
  logs)
    [[ $# -eq 1 ]] || shell_die "用法: ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>"
    [[ "$1" =~ ^${RUNNER_NAME_PREFIX}runner-([0-9]+)$ ]] || shell_die "非法服务名: $1"
    id="${BASH_REMATCH[1]}"
    exist_max="$(docker_highest_existing_index)"
    count="$exist_max"; (( id > count )) && count="$id"
    (( count >= 1 )) || count=1
    shell_render_compose_file "$count"
    docker_compose_logs "$1"
    ;;

  # ./runner.sh rm|remove|delete [${RUNNER_NAME_PREFIX}runner-<id> ...] [-y|--yes]
  rm|remove|delete)
    shell_get_org_and_pat
    if [[ "$#" -eq 0 || "$1" == "-y" || "$1" == "--yes" ]]; then
      if [[ "$#" -ge 1 ]]; then
        shell_delete_all_execute ""
      else
        shell_delete_all_execute "确认删除以上所有 Runner/容器/卷吗? [y / N] " || exit 0
      fi
    else
      matched=()
      for s in "$@"; do
        if ! docker_container_exists "$s"; then
          shell_warn "未找到 $s 对应的 Runner 容器，忽略该参数！"
          continue
        fi
        matched+=("$s")
      done
      if [[ ${#matched[@]} -eq 0 ]]; then
        shell_info "没有可删除的 Runner 容器！"
        exit 0
      fi
      for s in "${matched[@]}"; do
        i="${s##*-}"
        name="$s"
        shell_info "从 Github 上注销: $name"
        rid="$(github_get_runner_id_by_name "$name" || true)"
        if [[ -n "$rid" ]]; then
          github_delete_runner_by_id "$rid" || shell_warn "从 Github 上注销 $name 失败，请手动在 Github 网页上注销！"
        else
          shell_warn "未在组织列表找到 $name，可能已被移除！"
        fi
        shell_info "删除容器与数据卷: $name / ${RUNNER_NAME_PREFIX}runner-${i}-data"
        docker_remove_container_and_volume_by_index "$i"
      done
    fi
    ;;

  # ./runner.sh purge [-y|--yes]
  purge)
    shell_get_org_and_pat
    if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
      shell_delete_all_execute ""
    else
      shell_delete_all_execute "确定要注销所有 Runners、删除所有容器和卷，并移除所有生成的文件？[y / N] " || { echo "操作已取消！"; exit 0; }
    fi
    for f in "$COMPOSE_FILE" \
             "${REG_TOKEN_CACHE_FILE}" \
             "${DOCKERFILE_HASH_FILE}" \
             "$ENV_FILE"; do
      if [[ -f "$f" ]]; then
        shell_info "删除 $f 文件"
        rm -f "$f" || true
      fi
    done
    shell_info "purge 完成！"
    ;;

  # ./runner.sh
  *)
    shell_usage
    exit 1
    ;;
esac