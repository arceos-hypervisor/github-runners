#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

# ------------------------------- load .env file -------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/export /')
fi

# Organization, REG_TOKEN, etc.
ORG="${ORG:-}"
GH_PAT="${GH_PAT:-}"
REPO="${REPO:-}"
REG_TOKEN_CACHE_FILE="${REG_TOKEN_CACHE_FILE:-.reg_token.cache}"
REG_TOKEN_CACHE_TTL="${REG_TOKEN_CACHE_TTL:-300}" # seconds, default 5 minutes

# Runner container related parameters
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_CUSTOM_IMAGE="${RUNNER_CUSTOM_IMAGE:-qc-actions-runner:v0.0.1}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(hostname)}-"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
RUNNER_LABELS="${RUNNER_LABELS:-intel}"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"
## Removed: dynamic compose generation and board overrides; compose must exist
COMPOSE_FILE="docker-compose.yml"
DOCKERFILE_HASH_FILE="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"
## boards
declare -A BOARD_CONFIGS=(
    ["phytiumpi"]="phytiumpi|\
                    phytiumpi_linux.tar.gz|\
                    mbpoll -m rtu -a 1 -r 6 -t 0 -b 9600 -P none -v /dev/ttyUSB0 1|\
                    mbpoll -m rtu -a 1 -r 6 -t 0 -b 9600 -P none -v /dev/ttyUSB0 0|\
                    /home/runner/test/phytiumpi_firefly.dtb|\
                    /dev/ttyUSB2|\
                    1152000"
    ["roc-rk3568-pc"]="roc-rk3568-pc|roc-rk3568-pc_linux.tar.gz|mbpoll -m rtu -a 1 -r 5 -t 0 -b 9600 -P none -v /dev/ttyUSB0 1|mbpoll -m rtu -a 1 -r 5 -t 0 -b 9600 -P none -v /dev/ttyUSB0 0|/home/runner/test/rk3568-firefly-roc-pc-se.dtb|/dev/ttyUSB2|1500000"
)

# ------------------------------- Helpers -------------------------------
shell_usage() {
  local COLW=48
  echo "Usage: ./runner.sh COMMAND [options]    Where [options] depend on COMMAND. Available COMMANDs:"
  echo

  echo "1. Creation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh init -n N" "Generate docker-compose.yml then create runners and start"
  printf "  %-${COLW}s %s\n" "./runner.sh compose" "Regenerate docker-compose.yml with existing generic and board-specific runners"
  echo

  echo "2. Instance operation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Register specified instances; no args will iterate over all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Start specified instances (will register if needed); no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Stop Runner containers; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Restart specified instances; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>" "Follow logs of a specified instance"
  echo

  echo "3. Query commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh ps|ls|list|status" "Show container status and registered Runner status"
  echo

  echo "4. Deletion commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh rm|remove|delete [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Delete specified instances; no args will delete all (confirmation required, -y to skip)"
  printf "  %-${COLW}s %s\n" "./runner.sh purge [-y]" "On top of remove, also delete the dynamically generated docker-compose.yml"
  echo

  echo "5. Help"
  printf "  %-${COLW}s %s\n" "./runner.sh help" "Show this help"
  echo

  echo "Environment variables (from .env or interactive input):"
  local KEYW=24
  printf "  %-${KEYW}s %s\n" "GH_PAT" "Classic PAT (requires admin:org), used for org API and registration token"
  printf "  %-${KEYW}s %s\n" "ORG" "Organization name or user name (required)"
  printf "  %-${KEYW}s %s\n" "REPO" "Optional repository name (when set, operate on repo-scoped runners under ORG/REPO instead of organization-wide runners)"
  printf "  %-${KEYW}s %s\n" "RUNNER_NAME_PREFIX" "Runner name prefix"
  printf "  %-${KEYW}s %s\n" "RUNNER_IMAGE" "Image used for compose generation (default ghcr.io/actions/actions-runner:latest)"
  printf "  %-${KEYW}s %s\n" "RUNNER_CUSTOM_IMAGE" "Image tag used for auto-build (can override)"
  echo
  echo "Example workflow runs-on: runs-on: [self-hosted, linux, docker]"

  echo
  echo "Tips:"
  echo "- docker-compose.yml must exist. The script will not generate or modify it."
  echo "- Re-start/up will reuse existing volumes; Runner configuration and tool caches will not be lost."
}

shell_die() { echo "[ERROR] $*" >&2; exit 1; }
shell_info() { echo "[INFO] $*"; }
shell_warn() { echo "[WARN] $*" >&2; }

shell_prompt_confirm() {
    # Return 0 for confirm, 1 for cancel
    local prompt="${1:-Confirm? [y/N]} "
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
        shell_die "ORG/GH_PAT cannot be empty (in non-interactive environments provide via env or .env)."
        return 0
    fi

    # Prompt using /dev/tty so it works inside command substitutions
    local wrote_env=0
    if [[ -z "${ORG:-}" ]]; then
        while true; do
            if [[ -e /dev/tty ]]; then
                printf "Enter organization name (must match github.com): " > /dev/tty
                IFS= read -r ORG < /dev/tty || true
            else
                read -rp "Enter organization name (must match github.com): " ORG || true
            fi
            ORG="$(printf '%s' "${ORG:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -n "$ORG" ]] && break
            printf "[WARN] Organization name cannot be empty, please try again.\n" > /dev/tty
        done
        wrote_env=1
    fi

    if [[ -z "${GH_PAT:-}" ]]; then
        while true; do
            if [[ -e /dev/tty ]]; then
                printf "Enter Classic PAT (admin:org) (input hidden): " > /dev/tty
                IFS= read -rs GH_PAT < /dev/tty || true; echo > /dev/tty
            else
                echo -n "Enter Classic PAT (admin:org) (input hidden): " >&2
                read -rs GH_PAT || true; echo >&2
            fi
            GH_PAT="$(printf '%s' "${GH_PAT:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -n "$GH_PAT" ]] && break
            printf "[WARN] PAT cannot be empty, please try again.\n" > /dev/tty
        done
        wrote_env=1
    fi

    # Optional: repository name. If empty, operations default to organization scope.
    if [[ -z "${REPO:-}" ]]; then
        while true; do
            if [[ -e /dev/tty ]]; then
                printf "Enter repository name (optional, leave empty to use organization runners): " > /dev/tty
                IFS= read -r REPO < /dev/tty || true
            else
                read -rp "Enter repository name (optional, leave empty to use organization runners): " REPO || true
            fi
            REPO="$(printf '%s' "${REPO:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            break
        done
        [[ -n "${REPO:-}" ]] && wrote_env=1
    fi

    export ORG GH_PAT REPO

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
        if [[ -n "${REPO:-}" ]]; then
            tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
            grep -v -E '^[[:space:]]*REPO=' "$env_file" > "$tmp" || true
            printf 'REPO=%s\n' "$REPO" >> "$tmp"
            mv "$tmp" "$env_file"
        fi
    fi
}

# Decide which image to use based on Dockerfile and local images; build if needed; echo the chosen image name
shell_prepare_runner_image() {
    local base="ghcr.io/actions/actions-runner:latest"
    local current="${RUNNER_IMAGE:-$base}"
    local hash_file="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"

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
                shell_info "Detected Dockerfile change, building ${RUNNER_CUSTOM_IMAGE} image" >&2
                docker build -t "${RUNNER_CUSTOM_IMAGE}" . 1>&2
                echo "$new_hash" > "$hash_file"
                shell_info "Build complete. Will use ${RUNNER_CUSTOM_IMAGE} as image" >&2
                echo "${RUNNER_CUSTOM_IMAGE}"
                return 0
            fi
        fi

        if [[ "$current" == "$base" ]]; then
            if command -v docker >/dev/null 2>&1 && docker image inspect "${RUNNER_CUSTOM_IMAGE}" >/dev/null 2>&1; then
                # shell_info "Detected existing custom image, prefer ${RUNNER_CUSTOM_IMAGE} as image" >&2
                echo "${RUNNER_CUSTOM_IMAGE}"
                return 0
            fi
        fi
        echo "$current"
        return 0
    else
        # shell_info "Dockerfile not found, skipping custom image build; using official ${base} as image" >&2
        echo "$base"
        return 0
    fi
}

# Unified "delete all" executor: count -> prompt -> unregister -> local cleanup
shell_delete_all_execute() {
    local require_confirm_msg="$1"  # empty means no extra confirmation required

    local prefix cont_list org_count=0 cont_count=0 resp
    prefix="${RUNNER_NAME_PREFIX}runner-"

    if command -v jq >/dev/null 2>&1; then
        resp=$(github_api GET "/actions/runners?per_page=100" || echo "{}")
        org_count=$(echo "$resp" | jq -r --arg p "$prefix" '[.runners[] | select(.name|startswith($p))] | length' 2>/dev/null || echo 0)
    else
        shell_warn "jq is not installed; cannot count organization runners. Will only remove local containers/volumes and attempt best-effort unregister."
    fi

    cont_list="$(docker_list_existing_containers)"
    if [[ -n "$cont_list" ]]; then cont_count=$(echo "$cont_list" | wc -l | tr -d ' '); fi

    shell_info "About to delete ${org_count} runners and ${cont_count} containers and associated volumes on this host"

    if [[ -n "$require_confirm_msg" ]]; then
        if ! shell_prompt_confirm "$require_confirm_msg"; then
            echo "Operation cancelled!"; return 130
        fi
    fi

    # 根据计数条件执行相应的删除操作
    [[ "$org_count" -gt 0 ]] && { shell_info "Deleting ${org_count} GitHub runners..."; github_delete_all_runners_with_prefix || true; }
    [[ "$cont_count" -gt 0 ]] && { shell_info "Deleting ${cont_count} Docker containers and volumes..."; docker_remove_all_local_containers_and_volumes || true; }

    shell_info "Batch deletion complete!"
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
                printf '%s\n' "$REG_TOKEN"
                return 0
            fi
        fi
    fi

    if [[ -n "${REG_TOKEN:-}" && "${REG_TOKEN:-}" != "null" ]]; then
        printf '%s\n%s\n' "$now" "$REG_TOKEN" > "$REG_TOKEN_CACHE_FILE"
        printf '%s\n' "$REG_TOKEN"
        return 0
    fi

    shell_get_org_and_pat
    shell_info "Requesting <${ORG:-${REPO}}> registration token..." >&2
    local new_token
    new_token="$(github_fetch_reg_token || true)"
    [[ -n "$new_token" && "$new_token" != "null" ]] || shell_die "Failed to fetch registration token!"
    REG_TOKEN="$new_token"
    export REG_TOKEN
    printf '%s\n%s\n' "$now" "$REG_TOKEN" > "$REG_TOKEN_CACHE_FILE"
    # Keep compose file in sync when fetching a fresh token
    printf '%s\n' "$REG_TOKEN"
}

# Update a field in docker-compose.yml under environment (mapping or list styles)
# Usage: shell_update_compose_file KEY VALUE
shell_update_compose_file() {
    local key="$1" token="$2"
    [[ -n "$key" && -n "$token" ]] || return 0
    local file="$COMPOSE_FILE"
    [[ -f "$file" ]] || { shell_warn "${file} not found; skip updating ${key}." >&2; return 0; }
    
    local tmpfile updated
    tmpfile=$(mktemp "${file}.tmp.XXXXXX") || return 1
    updated=0
    
    while IFS= read -r line; do
        # Mapping style: KEY: "value" (preserve indentation and spacing)
        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*: ]]; then
            # Extract leading whitespace and preserve it
            local indent="${line%%[^ ]*}"
            printf '%s%s: "%s"\n' "$indent" "$key" "$token" >> "$tmpfile"
            updated=1
        # List style: - KEY="value" (preserve indentation and dash)
        elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*${key}= ]]; then
            # Extract leading spaces and dash
            local prefix="${line%${key}*}"
            printf '%s%s="%s"\n' "$prefix" "$key" "$token" >> "$tmpfile"
            updated=1
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$file"
    
    if [[ $updated -eq 1 ]]; then
        mv "$tmpfile" "$file"
        shell_info "Updated ${key} in ${file}." >&2
    else
        rm -f "$tmpfile"
        shell_warn "${key} key not found in ${file}; ensure your compose defines it under environment." >&2
    fi
}

# Helper: Extract an environment variable value for a specific service from docker-compose.yml
# Usage: shell_get_compose_file SERVICE_NAME ENV_KEY
shell_get_compose_file() {
    local service="$1" key="$2"
    local file="$COMPOSE_FILE"
    [[ -f "$file" ]] || return 1
    
    local in_service=0 in_env=0 found=0
    
    while IFS= read -r line; do
        # Check if we're entering the target service
        if [[ "$line" =~ ^[[:space:]]*${service}:[[:space:]]*$ ]]; then
            in_service=1
            in_env=0
            continue
        fi
        
        # If we were in a service and encounter another service at same indentation, exit
        if [[ $in_service -eq 1 ]] && [[ "$line" =~ ^[a-zA-Z_] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            break
        fi
        
        # Check if we're entering the environment block
        if [[ $in_service -eq 1 ]] && [[ "$line" =~ ^[[:space:]]*environment:[[:space:]]*$ ]]; then
            in_env=1
            continue
        fi
        
        # If we're in environment section, look for the key
        if [[ $in_env -eq 1 ]]; then
            # Stop if we encounter a key at lower indentation level (end of environment)
            if [[ "$line" =~ ^[a-zA-Z_] ]] || [[ "$line" =~ ^[[:space:]]{0,2}[a-zA-Z_] ]]; then
                break
            fi
            
            # Match the key in mapping style: KEY: value
            if [[ "$line" =~ ^[[:space:]]*${key}:[[:space:]]* ]]; then
                # Extract value after the colon, then trim spaces
                local value="${line#*:}"
                value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                # Strip matching surrounding quotes if present (both double and single)
                if [[ "$value" == \"*\" ]]; then value="${value#\"}"; value="${value%\"}"; fi
                if [[ "$value" == \'*\' ]]; then value="${value#\'}"; value="${value%\'}"; fi
                [[ -n "$value" ]] && echo "$value"
                found=1
                break
            fi
        fi
    done < "$file"
    
    [[ $found -eq 1 ]] && return 0 || return 1
}

shell_generate_compose_file() {
    local general_count=$1
    
    # 使用 printf 输出文件头
    printf '%s\n' \
        "# 自动生成的 Docker Compose 配置" \
        "# 机器名: $RUNNER_NAME_PREFIX" \
        "# 普通 runner 数量: $general_count" \
        "# 板子 runner 数量: ${#BOARD_CONFIGS[@]}" \
        "" \
        "# 基础配置" \
        "x-${RUNNER_NAME_PREFIX}runner-base: &runner_base" \
        "  image: \"${RUNNER_IMAGE}\"" \
        "  restart: unless-stopped" \
        "  environment: &runner_env" \
        "    RUNNER_ORG_URL: \"https://github.com/arceos-hypervisor\"" \
        "    RUNNER_TOKEN: \"${REG_TOKEN}\"" \
        "    RUNNER_GROUP: \"${RUNNER_GROUP}\"" \
        "    RUNNER_REMOVE_ON_STOP: \"false\"" \
        "    DISABLE_AUTO_UPDATE: \"${DISABLE_AUTO_UPDATE}\"" \
        "    RUNNER_WORKDIR: \"${RUNNER_WORKDIR}\"" \
        "    HTTP_PROXY: \"http://127.0.0.1:7890\"" \
        "    HTTPS_PROXY: \"http://127.0.0.1:7890\"" \
        "    NO_PROXY: localhost,127.0.0.1,.internal" \
        "  network_mode: host" \
        "  privileged: true" \
        "" \
        "services:" > docker-compose.yml

    # 生成普通 runners
    echo "  # 普通 runners" >> docker-compose.yml
    for i in $(seq 1 $general_count); do
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-${i}:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-${i}\"" \
            "    command: [\"/home/runner/run.sh\"]" \
            "    devices:" \
            "      - /dev/loop-control:/dev/loop-control" \
            "      - /dev/loop0:/dev/loop0" \
            "      - /dev/loop1:/dev/loop1" \
            "      - /dev/loop2:/dev/loop2" \
            "      - /dev/loop3:/dev/loop3" \
            "      - /dev/kvm:/dev/kvm" \
            "    group_add:" \
            "      - kvm" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-${i}\"" \
            "      RUNNER_LABELS: \"${RUNNER_LABELS}\"" \
            "    volumes:" \
            "      - ${RUNNER_NAME_PREFIX}runner-${i}-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:/etc/udev/rules.d" \
            "" >> docker-compose.yml
    done

    # 生成板子 runners
    echo "  # 板子专用 runners" >> docker-compose.yml
    for board_name in "${!BOARD_CONFIGS[@]}"; do
        IFS='|' read -r labels download_file power_on power_off dtb_path uart_dev baud_rate <<< "$(echo "${BOARD_CONFIGS[$board_name]}" | sed -E 's/\\[[:space:]]*//g' | tr -d '\n' | sed -E 's/[[:space:]]*\|[[:space:]]*/|/g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
        
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-${board_name}:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-${board_name}\"" \
            "    command:" \
            "      - /bin/bash" \
            "      - -c" \
            "      - |" \
            "        set -e" \
            "        mkdir -p /home/runner/test" \
            "        cd /home/runner/test" \
            "        wget -q https://github.com/arceos-hypervisor/axvisor-guest/releases/download/v0.0.15/${download_file}" \
            "        tar -xzf ${download_file}" \
            "        exec /home/runner/run.sh" \
            "    devices:" \
            "      - /dev/loop-control:/dev/loop-control" \
            "      - /dev/loop0:/dev/loop0" \
            "      - /dev/loop1:/dev/loop1" \
            "      - /dev/loop2:/dev/loop2" \
            "      - /dev/loop3:/dev/loop3" \
            "      - /dev/kvm:/dev/kvm" \
            "      - /dev/ttyUSB0:/dev/ttyUSB0" \
            "      - /dev/ttyUSB1:/dev/ttyUSB1" \
            "    group_add:" \
            "      - kvm" \
            "      - dialout" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-${board_name}\"" \
            "      RUNNER_LABELS: \"${labels}\"" \
            "      BOARD_POWER_ON: \"${power_on}\"" \
            "      BOARD_POWER_OFF: \"${power_off}\"" \
            "      BOARD_DTB: \"${dtb_path}\"" \
            "      BOARD_COMM_UART_DEV: \"${uart_dev}\"" \
            "      BOARD_COMM_UART_BAUD: \"${baud_rate}\"" \
            "      BOARD_COMM_NET_IFACE: \"eth0\"" \
            "    volumes:" \
            "      - ${RUNNER_NAME_PREFIX}runner-${board_name}-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-${board_name}-udev-rules:/etc/udev/rules.d" \
            "" >> docker-compose.yml
    done

    # 生成 volumes
    echo "volumes:" >> docker-compose.yml
    
    for i in $(seq 1 $general_count); do
        echo "  ${RUNNER_NAME_PREFIX}runner-${i}-data:" >> docker-compose.yml
        echo "  ${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:" >> docker-compose.yml
    done
    
    for board_name in "${!BOARD_CONFIGS[@]}"; do
        echo "  ${RUNNER_NAME_PREFIX}runner-${board_name}-data:" >> docker-compose.yml
        echo "  ${RUNNER_NAME_PREFIX}runner-${board_name}-udev-rules:" >> docker-compose.yml
    done
}

# ------------------------------- GitHub API helpers -------------------------------
github_api() {
    local method="$1" path="$2" body="${3:-}"
    [[ -n "${GH_PAT:-}" ]] || shell_die "GH_PAT is required to call organization-related APIs!"
    # If REPO is set, target repo-scoped endpoints under /repos/{ORG}/{REPO}, otherwise org endpoints
    local base
    if [[ -n "${REPO:-}" ]]; then
        base="https://api.github.com/repos/${ORG}/${REPO}"
    else
        base="https://api.github.com/orgs/${ORG}"
    fi
    local url="${base}${path}"
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
            shell_info "Unregistering from GitHub: $name (id=$id)"
            github_delete_runner_by_id "$id" || shell_warn "Failed to unregister $name on GitHub; please remove it manually via the GitHub web UI!"
        done < <(echo "$resp" | jq -r --arg p "$prefix" '.runners[] | select(.name|startswith($p)) | "\(.id)\t\(.name)"')
    else
        shell_warn "jq is not installed; cannot batch-unregister on the organization side; will only remove local containers and volumes."
    fi
}

# ------------------------------- Docker Compose wrappers -------------------------------
docker_pick_compose() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        shell_die "docker compose (v2) or docker-compose is not installed."
    fi
}

docker_list_existing_containers() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        $DC -f "$COMPOSE_FILE" ps --services --all | grep -F "${RUNNER_NAME_PREFIX}runner-" || true
    else
        docker ps -a --filter "name=${RUNNER_NAME_PREFIX}runner-" --format "{{.Names}}" || true
    fi
}

docker_print_existing_containers_status() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        $DC -f "$COMPOSE_FILE" ps -a
        return 0
    fi

    # Fallback: query via docker when compose file is absent
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --filter "name=${RUNNER_NAME_PREFIX}runner-" --format "table {{.Names}}\t{{.State}}\t{{.Status}}"
    else
        shell_info "${COMPOSE_FILE} not found and docker command not detected; cannot query status."
    fi
}

# Check whether a specific container exists (local docker ps -a name match)
docker_container_exists() {
    local name="$1"
    if [[ -f "$COMPOSE_FILE" ]]; then
        $DC -f "$COMPOSE_FILE" ps --services --all | grep -qx "$name" >/dev/null 2>&1
    else
        docker ps -a --format '{{.Names}}' | grep -qx "$name" >/dev/null 2>&1
    fi
}

docker_remove_all_local_containers_and_volumes() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        shell_info "Using docker compose down -v to remove all services and volumes"
        $DC -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    else
        shell_info "Removing containers and volumes with docker commands"
        # Remove containers
        local containers
        containers=$(docker ps -a --filter "name=${RUNNER_NAME_PREFIX}runner-" --format "{{.Names}}" 2>/dev/null || true)
        if [[ -n "$containers" ]]; then
            echo "$containers" | xargs -r docker rm -f >/dev/null 2>&1 || true
        fi
        # Remove volumes
        local volumes
        volumes=$(docker volume ls --filter "name=${RUNNER_NAME_PREFIX}runner-" --format "{{.Name}}" 2>/dev/null || true)
        if [[ -n "$volumes" ]]; then
            echo "$volumes" | xargs -r docker volume rm >/dev/null 2>&1 || true
        fi
    fi
}

# Usage:
#   docker_runner_register                -> auto-detect all runner-* containers and register unconfigured ones
#   docker_runner_register runner-1 ...   -> register runners with the specified names
docker_runner_register() {
    local names=()
    if [[ $# -gt 0 ]]; then
        names=("$@")
    else
        mapfile -t names < <(docker_list_existing_containers | sed '/^$/d') || true
    fi
    if [[ ${#names[@]} -eq 0 ]]; then
        shell_info "No Runner containers to register!"
        return 0
    fi
    [[ -f "$COMPOSE_FILE" ]] || shell_die "Missing ${COMPOSE_FILE}; cannot register using compose."
    local cname
    for cname in "${names[@]}"; do
        if ! docker_container_exists "$cname"; then
            shell_warn "Container not defined in compose or does not exist: $cname (skipping)"
            continue
        fi
        if $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
            shell_info "Already configured, skipping registration: $cname"
            continue
        fi
        # Extract RUNNER_LABELS for this specific service from docker-compose.yml
        local labels
        labels="$(shell_get_compose_file "$cname" "RUNNER_LABELS")" || labels=""
        # Sanitize possible surrounding quotes then deduplicate labels
        labels="$(printf '%s' "$labels" | sed -e 's/^\"\(.*\)\"$/\1/' -e "s/^'\(.*\)'$/\1/" | awk -F',' '{n=split($0,a,",");o="";for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/,"",a[i]);if(a[i]!=""&&!m[a[i]]++){o=(o?o",":"")a[i]}}print o}')"
        
        local cfg_opts=(
            "--url" "https://github.com/${ORG}${REPO:+/}${REPO}"
            "--token" "${REG_TOKEN}"
            "--name" "${cname}"
            "--labels" "${labels}"
            "--runnergroup" "${RUNNER_GROUP}"
            "--unattended" "--replace"
        )
        [[ -n "${RUNNER_WORKDIR}" ]] && cfg_opts+=("--work" "${RUNNER_WORKDIR}")
        [[ "${DISABLE_AUTO_UPDATE}" == "1" ]] && cfg_opts+=("--disableupdate")
        shell_info "Registering on GitHub: ${cname}"
        # Pass arguments directly to avoid shell quoting issues
        $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" /home/runner/config.sh "${cfg_opts[@]}" >/dev/null || shell_warn "Registration failed (container: $cname)"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    DC=$(docker_pick_compose)
    CMD="${1:-help}"; shift || true
    case "$CMD" in
        # ./runner.sh help|-h|--help
        help|-h|--help)
            shell_usage
            ;;

        # ./runner.sh ps|ls|list|status
        ps|ls|list|status)
            shell_get_org_and_pat
            echo "--------------------------------- Containers -----------------------------------------"
            docker_print_existing_containers_status
            echo

            echo "--------------------------------- Runners --------------------------------------------"
            resp=$(github_api GET "/actions/runners?per_page=100") || shell_die "Failed to fetch runner list."
            if command -v jq >/dev/null 2>&1; then
                echo "$resp" | jq -r '.runners[] | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' \
                    | awk -F'\t' 'BEGIN{printf("%-40s %-8s %-6s %s\n","NAME","STATUS","BUSY","LABELS")}{printf("%-40s %-8s %-6s %s\n",$1,$2,$3,$4)}'
            else
                echo "$resp"
            fi
            echo
            shell_info "Due to GitHub limitations, runner list is limited to 100 entries!"
            echo
            ;;

        # ./runner.sh init -n|--count N
        init)
            count=0
            if [[ "${1:-}" == "-n" || "${1:-}" == "--count" ]]; then
                shift
                count="${1:-0}"
                shift || true
            fi
            [[ "$count" =~ ^[0-9]+$ ]] || shell_die "Count must be numeric!"

            shell_info "Generating $COMPOSE_FILE with $count generic runners and ${#BOARD_CONFIGS[@]} board-specific runners."

            RUNNER_IMAGE="$(shell_prepare_runner_image)";

            REG_TOKEN="$(shell_get_reg_token)"

            shell_generate_compose_file "$count"

            $DC -f "$COMPOSE_FILE" up -d "$@";

            docker_runner_register
            ;;
        
        # ./runner.sh compose
        compose)
            cont_count=0
            cont_list="$(docker_list_existing_containers)"
            if [[ -n "$cont_list" ]]; then cont_count=$(echo "$cont_list" | wc -l | tr -d ' '); fi
            generic_count=$(( cont_count - ${#BOARD_CONFIGS[@]} ))
            shell_info "Regenerating $COMPOSE_FILE with ${generic_count} existing runners and ${#BOARD_CONFIGS[@]} board-specific runners."
            RUNNER_IMAGE="$(shell_prepare_runner_image)";
            REG_TOKEN="$(shell_get_reg_token)"
            shell_generate_compose_file "$generic_count"
            ;;

        # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
        register)
            [[ -f "$COMPOSE_FILE" ]] || shell_die "${COMPOSE_FILE} not found. Please create docker-compose.yml first."

            REG_TOKEN="$(shell_get_reg_token)"
            shell_update_compose_file "RUNNER_TOKEN" "$REG_TOKEN"

            if [[ $# -ge 1 ]]; then
                # Pass incoming parameters (container names or numbers) directly to docker_runner_register
                # Allow multiple parameters at once
                docker_runner_register "$@"
            else
                docker_runner_register
            fi
            ;;

        # ./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]
        start)
            if [[ $# -ge 1 ]]; then
                ids=()
                for s in "$@"; do
                    if ! docker_container_exists "$s"; then
                        shell_warn "No Runner container found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to start!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_existing_containers) || ids=()
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to start!"
                    exit 0
                fi
            fi
            shell_info "Starting ${#ids[@]} container(s): ${ids[*]}"
            if [[ -f "$COMPOSE_FILE" ]]; then
                $DC -f "$COMPOSE_FILE" up -d "${ids[@]}"
            else
                docker start "${ids[@]}"
            fi
            ;;

        # ./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]
        stop)
            if [[ $# -ge 1 ]]; then
                ids=()
                for s in "$@"; do
                    if ! docker_container_exists "$s"; then
                        shell_warn "No Runner container found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to stop!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_existing_containers) || ids=()
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to stop!"
                    exit 0
                fi
            fi
            shell_info "Stopping ${#ids[@]} container(s): ${ids[*]}"
            if [[ -f "$COMPOSE_FILE" ]]; then
                $DC -f "$COMPOSE_FILE" stop "${ids[@]}"
            else
                docker stop "${ids[@]}"
            fi
            ;;

        # ./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]
        restart)
            if [[ $# -ge 1 ]]; then
                ids=()
                for s in "$@"; do
                    if ! docker_container_exists "$s"; then
                        shell_warn "No Runner container found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to restart!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_existing_containers) || ids=()
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to restart!"
                    exit 0
                fi
            fi
            shell_info "Restarting ${#ids[@]} container(s): ${ids[*]}"
            if [[ -f "$COMPOSE_FILE" ]]; then
                $DC -f "$COMPOSE_FILE" restart "${ids[@]}"
            else
                docker restart "${ids[@]}"
            fi
            ;;

        # ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>
        logs)
            [[ $# -eq 1 ]] || shell_die "Usage: ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>"

            docker_container_exists "$1" || shell_die "Container $1 not found"

            shell_info "Showing logs for: $1"
            if [[ -f "$COMPOSE_FILE" ]]; then
                $DC -f "$COMPOSE_FILE" logs -f "$1"
            else
                docker logs -f "$1"
            fi
            ;;

        # ./runner.sh rm|remove|delete [${RUNNER_NAME_PREFIX}runner-<id> ...] [-y|--yes]
        rm|remove|delete)
            shell_get_org_and_pat
            if [[ "$#" -eq 0 || "$1" == "-y" || "$1" == "--yes" ]]; then
                if [[ "$#" -ge 1 ]]; then
                    shell_delete_all_execute ""
                else
                    shell_delete_all_execute "Confirm deletion of all above Runners/containers/volumes? [y / N] " || exit 0
                fi
            else
                matched=()
                for s in "$@"; do
                    if ! docker_container_exists "$s"; then
                        shell_warn "No Runner container found for $s, ignoring this argument!"
                        continue
                    fi
                    matched+=("$s")
                done
                if [[ ${#matched[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to delete!"
                    exit 0
                fi
                for s in "${matched[@]}"; do
                    name="$s"
                    shell_info "Unregistering from GitHub: $name"
                    rid="$(github_get_runner_id_by_name "$name" || true)"
                    if [[ -n "$rid" ]]; then
                        github_delete_runner_by_id "$rid" || shell_warn "Failed to unregister $name on GitHub; please remove it manually via the GitHub web UI!"
                    else
                        shell_warn "Not found in organization list: $name; it may have been removed already!"
                    fi
                    Related volume names: <container>-data and optionally <container>-udev-rules
                    vol_list="${name}-data"
                    if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
                        vol_list+=" / ${name}-udev-rules"
                    fi
                    shell_info "Removing container and data volumes: $name / ${vol_list}"
                    if [[ -f "$COMPOSE_FILE" ]]; then
                        $DC -f "$COMPOSE_FILE" rm -s -f "$name" >/dev/null 2>&1 || true
                    fi
                done
            fi
            ;;

        # ./runner.sh purge [-y|--yes]
        purge)
            REG_TOKEN="$(shell_get_reg_token)"
            if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
                shell_delete_all_execute ""
            else
                shell_delete_all_execute "Confirm unregister of all Runners, delete all containers and volumes, and remove all generated files? [y / N] " || { echo "Operation cancelled!"; exit 0; }
            fi
            for f in \
                "${REG_TOKEN_CACHE_FILE}" \
                "${DOCKERFILE_HASH_FILE}" \
                "$ENV_FILE"; do
                if [[ -f "$f" ]]; then
                    shell_info "Removing file $f"
                    rm -f "$f" || true
                fi
            done
            shell_info "purge complete!"
            ;;

        # ./runner.sh
        *)
            shell_usage
            exit 1
            ;;
    esac
fi
