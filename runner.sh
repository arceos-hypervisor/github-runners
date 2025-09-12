#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

# ------------------------------- load .env file -------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/export /')
fi

# 组织，REG_TOKEN 等
ORG="${ORG:-}"
GH_PAT="${GH_PAT:-}"
REG_TOKEN_CACHE_FILE="${REG_TOKEN_CACHE_FILE:-.reg_token.cache}"
REG_TOKEN_CACHE_TTL="${REG_TOKEN_CACHE_TTL:-300}" # seconds, default 5 minutes

# Runner 容器相关参数
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_CUSTOM_IMAGE="${RUNNER_CUSTOM_IMAGE:-qc-actions-runner:v0.0.1}"
RUNNER_COUNT="${RUNNER_COUNT:-2}"
BOARD_RUNNERS="phytiumpi:board,phytiumpi;roc-rk3568-pc:board,roc-rk3568-pc"  # 形如 board1_name:labels1,label2;board2_name:labels1,label2[;...] 使用分号分隔多个开发板条目（内部标签仍用逗号）
COMPOSE_FILE="docker-compose.yml"
DOCKERFILE_HASH_FILE="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,docker}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:+${RUNNER_NAME_PREFIX}-}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"

# 容器内部权限与设备映射设置
PRIVILEGED="${PRIVILEGED:-true}"
MAP_LOOP_DEVICES="${MAP_LOOP_DEVICES:-true}"
LOOP_DEVICE_COUNT="${LOOP_DEVICE_COUNT:-4}"
MAP_KVM_DEVICE="${MAP_KVM_DEVICE:-true}"
MAP_USB_DEVICE="${MAP_USB_DEVICE:-true}"
MOUNT_UDEV_RULES_DIR="${MOUNT_UDEV_RULES_DIR:-true}"
MOUNT_DOCKER_SOCK="${MOUNT_DOCKER_SOCK:-}"

# ------------------------------- Helpers -------------------------------
shell_usage() {
  local COLW=48
  echo "用法: ./runner.sh COMMAND [选项]    其中，[选项] 由 COMMAND 决定，可用 COMMAND 如下所示："
  echo

  echo "1. 创建相关命令:"
  printf "  %-${COLW}s %s\n" "./runner.sh init [-n N]" "生成 N 个服务并启动（默认使用 .env 中 RUNNER_COUNT）"
  printf "  %-${COLW}s %s\n" "" "首次会向组织申请注册令牌并持久化到各自卷中"
  echo

  echo "2. 实例操作相关命令:"
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
  printf "  %-${KEYW}s %s\n" "RUNNER_COUNT" "创建时的默认数量"
  printf "  %-${KEYW}s %s\n" "BOARD_RUNNERS" "开发板 Runner 列表: name:label1[,label2] 以分号分隔多个开发板条目; 内部 label 仍以逗号"
  printf "  %-${KEYW}s %s\n" "DISABLE_AUTO_UPDATE" '"1" 表示禁用 Runner 自更新'
  printf "  %-${KEYW}s %s\n" "RUNNER_WORKDIR" "工作目录（默认 /runner/_work）"
  printf "  %-${KEYW}s %s\n" "MOUNT_DOCKER_SOCK" '"true"/"1" 表示挂载 /var/run/docker.sock（高权限，谨慎）'
  printf "  %-${KEYW}s %s\n" "RUNNER_IMAGE" "用于生成 compose 的镜像（默认 ghcr.io/actions/actions-runner:latest）"
  printf "  %-${KEYW}s %s\n" "RUNNER_CUSTOM_IMAGE" "自动构建时使用的镜像 tag（可重写）"
  printf "  %-${KEYW}s %s\n" "PRIVILEGED" "是否以 privileged 运行（默认 true，建议: 解决 loop device 问题）"
  printf "  %-${KEYW}s %s\n" "MAP_LOOP_DEVICES" "是否映射宿主 /dev/loop* 到容器（默认 true）"
  printf "  %-${KEYW}s %s\n" "LOOP_DEVICE_COUNT" "最多映射的 loop 设备数量（默认 4）"
  printf "  %-${KEYW}s %s\n" "MAP_KVM_DEVICE" "是否映射 /dev/kvm 到容器（默认 true，存在时）"
  printf "  %-${KEYW}s %s\n" "MAP_USB_DEVICE" "是否映射 /dev/ttyUSB* 到容器（默认 true，存在时）"
  printf "  %-${KEYW}s %s\n" "MOUNT_UDEV_RULES_DIR" "为 /etc/udev/rules.d 提供挂载以确保目录存在（默认 true）"

  echo
  echo "工作流 runs-on 示例: runs-on: [self-hosted, linux, docker]"

  echo
  echo "提示:"
  echo "- 动态生成的 docker-compose.yml 会覆盖同名文件（存量容器不受影响）。"
  echo "- 重新 start/scale/up 会复用已有卷，不会丢失 Runner 配置与工具缓存。"
  echo "- BOARD_RUNNERS 形如 phytiumpi:phytiumpi,extra1;roc-rk3568-pc:roc-rk3568-pc 使用分号分隔多个开发板；条目内冒号后可再用逗号列出多个标签。"
  echo "- 注册时会自动将基础 RUNNER_LABELS 与对应开发板追加标签合并并去重。"
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

# 统计 BOARD_RUNNERS 中有效开发板条目数量（形如 name:labels），返回数字
shell_count_board_runners() {
  local br="${BOARD_RUNNERS:-}" c=0 e
  [[ -n "$br" ]] || { echo 0; return 0; }
  IFS=';' read -r -a __arr <<< "$br"
  for e in "${__arr[@]}"; do
    # 去掉首尾空白
    e="$(echo "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$e" ]] && continue
    # 必须包含冒号且冒号后非空
    [[ "$e" == *:* ]] || continue
    local name="${e%%:*}" rest="${e#*:}"
    [[ -n "$name" && -n "$rest" ]] || continue
    ((c++))
  done
  echo "$c"
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
    printf "    %s\n" "RUNNER_GROUP: \"${RUNNER_GROUP}\""
    printf "    %s\n" "RUNNER_REMOVE_ON_STOP: \"false\""
    printf "    %s\n" "DISABLE_AUTO_UPDATE: \"${DISABLE_AUTO_UPDATE}\""
    printf "    %s\n" "RUNNER_WORKDIR: \"${RUNNER_WORKDIR}\""
    printf "    %s\n" "HTTP_PROXY: \"${HTTP_PROXY}\""
    printf "    %s\n" "HTTPS_PROXY: \"${HTTPS_PROXY}\""
    printf "    %s\n" "NO_PROXY: localhost,127.0.0.1,.internal"
    printf "  %s\n" "network_mode: host"

    # 这里让容器获得几乎和宿主机一样的全部内核能力，并解锁对所有设备的访问权限（更合适的是使用 cap-add 细分的权限控制）
    if [[ "$PRIVILEGED" == "1" || "$PRIVILEGED" == "true" ]]; then
      printf "  %s\n" "privileged: true"
    fi

    # 映射设备（kvm、loo、usb）
    printf "  %s\n" "devices:"
    if [[ "$MAP_LOOP_DEVICES" == "1" || "$MAP_LOOP_DEVICES" == "true" ]]; then
      if [[ -e "/dev/loop-control" ]]; then
        printf "    - %s\n" "/dev/loop-control:/dev/loop-control"
      fi
      local j
      for j in $(seq 0 $((LOOP_DEVICE_COUNT-1))); do
        if [[ -e "/dev/loop${j}" ]]; then
          printf "    - %s\n" "/dev/loop${j}:/dev/loop${j}"
        fi
      done
    fi
    if [[ "$MAP_KVM_DEVICE" == "1" || "$MAP_KVM_DEVICE" == "true" ]]; then
      if [[ -e "/dev/kvm" ]]; then
        printf "    - %s\n" "/dev/kvm:/dev/kvm"
      fi
    fi
    if [[ "$MAP_USB_DEVICE" == "1" || "$MAP_USB_DEVICE" == "true" ]]; then
      for ttyUSB in /dev/ttyUSB*; do
        if [[ -e "$ttyUSB" ]]; then
          printf "    - %s\n" "$ttyUSB:$ttyUSB"
        fi
      done
      if [[ -e "/dev/ttyACM0" ]]; then
        printf "    - %s\n" "/dev/ttyACM0:/dev/ttyACM0"
      fi
    fi

    # 映射 Linux 用户组（group）权限，以便可以访问属于特定的 group 的设备（如 /dev/kvm）
    printf "  group_add:\n"
    if [[ "$MAP_KVM_DEVICE" == "1" || "$MAP_KVM_DEVICE" == "true" ]]; then
      if [[ -e "/dev/kvm" ]]; then
        local kvm_gid
        kvm_gid="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"
        if [[ -n "$kvm_gid" ]]; then
          printf "    - %s\n" "$kvm_gid"
        fi
      fi
    fi
    if [[ "$MAP_USB_DEVICE" == "1" || "$MAP_USB_DEVICE" == "true" ]]; then
      printf "    - dialout\n"
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
      printf "      %s\n" "RUNNER_LABELS: \"${RUNNER_LABELS}\""
      printf "    %s\n" "volumes:"
      printf "      - %s\n" "$vname:/home/runner"
      if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
        printf "      - %s\n" "${svc}-udev-rules:/etc/udev/rules.d"
      fi
    done

    # 动态开发板实例（BOARD_RUNNERS: board1_name:labels1,label2;board2_name:labels1,label2[;...] 使用分号分隔多个开发板条目（内部标签仍用逗号）
    if [[ -n "${BOARD_RUNNERS:-}" ]]; then
      local IFS=';' entry raw name blabels svc vname
      for entry in ${BOARD_RUNNERS}; do
        raw="${entry}"; name="${raw%%:*}"; blabels="${raw#*:}"
        [[ -n "$name" && -n "$blabels" ]] || continue
        svc="${RUNNER_NAME_PREFIX}runner-${name}"
        vname="${svc}-data"
        printf "  %s:\n" "$svc"
        printf "    %s\n" "<<: *runner_base"
        printf "    %s\n" "container_name: \"$svc\""
        printf "    %s\n" "command: [\"/home/runner/run.sh\"]"
        printf "    %s\n" "environment:"
        printf "      %s\n" "<<: *runner_env"
        printf "      %s\n" "RUNNER_LABELS: \"${RUNNER_LABELS},${blabels}\""
        printf "      %s\n" "RUNNER_NAME: \"$svc\""
        printf "    %s\n" "volumes:"
        printf "      - %s\n" "$vname:/home/runner"
        if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
          printf "      - %s\n" "${svc}-udev-rules:/etc/udev/rules.d"
        fi
      done
    fi

    echo
    echo "volumes:"
    # 使用 C 风格循环避免 IFS 在前面被修改后影响 seq 输出的分词，导致 i 变成多行内容
    local i
    for (( i=1; i<=count; i++ )); do
      printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-data:"
      if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
        printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:"
      fi
    done
    # 动态开发板实例（BOARD_RUNNERS: board1_name:labels1,label2;board2_name:labels1,label2[;...] 使用分号分隔多个开发板条目（内部标签仍用逗号）
    if [[ -n "${BOARD_RUNNERS:-}" ]]; then
      local IFS=';' entry raw name blabels svc
      for entry in ${BOARD_RUNNERS}; do
        raw="${entry}"; name="${raw%%:*}"; blabels="${raw#*:}"
        [[ -n "$name" && -n "$blabels" ]] || continue
        printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${name}-data:"
        if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
          printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${name}-udev-rules:"
        fi
      done
    fi
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

docker_remove_all_local_containers_and_volumes() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    shell_info "使用 docker compose down -v 删除所有服务与卷"
    $DC -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  else
    shell_warn "未找到 ${COMPOSE_FILE}，跳过 compose down -v。"
  fi
}

docker_runner_register() {
  # 用法：
  #   docker_runner_register                -> 自动发现所有 runner-* 容器并注册未配置的
  #   docker_runner_register runner-1 ...   -> 注册指定名称的 runner
  local names=()
  if [[ $# -gt 0 ]]; then
    names=("$@")
  else
    mapfile -t names < <(docker_list_existing_containers | sed '/^$/d') || true
  fi
  if [[ ${#names[@]} -eq 0 ]]; then
    shell_info "没有可注册的 Runner 容器！"
    return 0
  fi
  [[ -f "$COMPOSE_FILE" ]] || shell_die "缺少 ${COMPOSE_FILE}，无法使用 compose 进行注册。"
  local cname
  for cname in "${names[@]}"; do
    if ! docker_container_exists "$cname"; then
      shell_warn "容器未在 compose 中定义或不存在: $cname (跳过)"
      continue
    fi
    if $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
      shell_info "已配置过，跳过注册: $cname"
      continue
    fi
    # 计算标签：基础标签 + 针对 BOARD_RUNNERS 的附加标签
    local labels="${RUNNER_LABELS}" extra
    if [[ -n "${BOARD_RUNNERS:-}" ]]; then
      # 使用分号分隔多个开发板条目
      local IFS=';' entry raw name blabels svcbase
      svcbase="${cname#${RUNNER_NAME_PREFIX}runner-}"
      for entry in ${BOARD_RUNNERS}; do
        raw="${entry}"; name="${raw%%:*}"; blabels="${raw#*:}"
        if [[ "$name" == "$svcbase" ]]; then
          # blabels 里可能还有逗号（上面按逗号切割会分裂），所以直接使用原始剩余部分
          labels="${labels},${blabels}"
        fi
      done
      # 恢复 IFS，避免后续使用 ${cfg_opts[*]} 展开时被分号连接
      IFS=$' \t\n'
    fi
    # 去重标签
    labels="$(echo "$labels" | awk -F',' '{n=split($0,a,",");o="";for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/,"",a[i]);if(a[i]!=""&&!m[a[i]]++){o=(o?o",":"")a[i]}}print o}')"
    local cfg_opts=(
      "--url" "https://github.com/${ORG}"
      "--token" "${REG_TOKEN}"
      "--name" "${cname}"
      "--labels" "${labels}"
      "--runnergroup" "${RUNNER_GROUP}"
      "--unattended" "--replace"
    )
    [[ -n "${RUNNER_WORKDIR}" ]] && cfg_opts+=("--work" "${RUNNER_WORKDIR}")
    [[ "${DISABLE_AUTO_UPDATE}" == "1" ]] && cfg_opts+=("--disableupdate")
    shell_info "在 Github 上注册: ${cname}"
    $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc "/home/runner/config.sh ${cfg_opts[*]}" >/dev/null || shell_warn "注册失败(容器: $cname)"
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
    # 计算开发板数量
    board_count="$(shell_count_board_runners)"
    generic_count=$(( count - board_count ))
    (( generic_count > 0 )) || shell_die "(总数 - board_count) 后的常规实例数量必须 > 0 ！"

    # 仅在渲染 compose 时减去开发板专用数量（开发板实例后续追加）
    shell_render_compose_file "$generic_count"

    # 仅为常规实例启动与注册（开发板实例在 compose 里已单独追加）
    docker_compose_up
    docker_runner_register
    ;;

  # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
  register)
    if [[ $# -ge 1 ]]; then
      # 直接把传入参数（容器名或数字）交给 docker_runner_register
      # 允许一次性多参数
      docker_runner_register "$@"
    else
      docker_runner_register
    fi
    ;;

  # ./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]
  start)
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
      docker_compose_up "${ids[@]}"
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
      docker_compose_up "${ids[@]}"
    fi
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
        name="$s"
        shell_info "从 Github 上注销: $name"
        rid="$(github_get_runner_id_by_name "$name" || true)"
        if [[ -n "$rid" ]]; then
          github_delete_runner_by_id "$rid" || shell_warn "从 Github 上注销 $name 失败，请手动在 Github 网页上注销！"
        else
          shell_warn "未在组织列表找到 $name，可能已被移除！"
        fi
        # 相关卷名称：<container>-data 以及可选的 <container>-udev-rules
        vol_list="${name}-data"
        if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
          vol_list+=" / ${name}-udev-rules"
        fi
        shell_info "删除容器与数据卷: $name / ${vol_list}"
        if [[ -f "$COMPOSE_FILE" ]]; then
          $DC -f "$COMPOSE_FILE" rm -s -f "$name" >/dev/null 2>&1 || true
        fi
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