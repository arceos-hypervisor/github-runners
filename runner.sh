#!/usr/bin/env bash
set -euo pipefail

# 忽略多组织部署时的 orphan 容器警告（同一主机运行多个组织的 runner 是正常场景）
export COMPOSE_IGNORE_ORPHANS=1

ENV_FILE="${ENV_FILE:-.env}"

shell_load_env_file() {
    local file="$1" line
    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        export "$line"
    done < "$file"
}

shell_default_runner_prefix() {
    if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
        printf '%s-%s-%s-' "$(hostname)" "$ORG" "$REPO"
    elif [[ -n "${ORG:-}" ]]; then
        printf '%s-%s-' "$(hostname)" "$ORG"
    else
        printf '%s-' "$(hostname)"
    fi
}

shell_scoped_file() {
    local base="$1" ext="${2:-}" suffix=""
    if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
        suffix=".${ORG}.${REPO}"
    elif [[ -n "${ORG:-}" ]]; then
        suffix=".${ORG}"
    fi
    printf '%s%s%s\n' "$base" "$suffix" "$ext"
}

shell_refresh_derived_config() {
    if [[ "${RUNNER_NAME_PREFIX_AUTO:-0}" -eq 1 ]]; then
        RUNNER_NAME_PREFIX="$(shell_default_runner_prefix)"
    else
        [[ "$RUNNER_NAME_PREFIX" == *- ]] || RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX}-"
    fi

    [[ "${COMPOSE_FILE_AUTO:-0}" -eq 1 ]] && COMPOSE_FILE="$(shell_scoped_file "docker-compose" ".yml")"
    [[ "${DOCKERFILE_HASH_FILE_AUTO:-0}" -eq 1 ]] && DOCKERFILE_HASH_FILE="$(shell_scoped_file ".dockerfile" ".sha256")"
    [[ "${REG_TOKEN_CACHE_FILE_AUTO:-0}" -eq 1 ]] && REG_TOKEN_CACHE_FILE="$(shell_scoped_file ".reg_token.cache")"
}

# ------------------------------- load .env file -------------------------------
shell_load_env_file "$ENV_FILE"

# Organization, PAT, etc.
ORG="${ORG:-}"
GH_PAT="${GH_PAT:-}"
REPO="${REPO:-}"

# Runner container related parameters
RUNNER_NAME_PREFIX_AUTO=0
COMPOSE_FILE_AUTO=0
DOCKERFILE_HASH_FILE_AUTO=0
REG_TOKEN_CACHE_FILE_AUTO=0
[[ -z "${RUNNER_NAME_PREFIX:-}" ]] && RUNNER_NAME_PREFIX_AUTO=1
[[ -z "${COMPOSE_FILE:-}" ]] && COMPOSE_FILE_AUTO=1
[[ -z "${DOCKERFILE_HASH_FILE:-}" ]] && DOCKERFILE_HASH_FILE_AUTO=1
[[ -z "${REG_TOKEN_CACHE_FILE:-}" ]] && REG_TOKEN_CACHE_FILE_AUTO=1

RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_CUSTOM_IMAGE="${RUNNER_CUSTOM_IMAGE:-qc-actions-runner:v0.0.1}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
RUNNER_LABELS="${RUNNER_LABELS:-intel}"
RUNNER_DEVICES="${RUNNER_DEVICES:-/dev/loop-control,/dev/loop0,/dev/loop1,/dev/loop2,/dev/loop3,/dev/kvm}"
RUNNER_GROUP_ADD="${RUNNER_GROUP_ADD:-dialout}"
RUNNER_VOLUMES="${RUNNER_VOLUMES:-}"
RUNNER_ENV="${RUNNER_ENV:-}"
RUNNER_COMMAND="${RUNNER_COMMAND:-/home/runner/run.sh}"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
DOCKERFILE_HASH_FILE="${DOCKERFILE_HASH_FILE:-}"
REG_TOKEN_CACHE_FILE="${REG_TOKEN_CACHE_FILE:-}"
REG_TOKEN_CACHE_TTL="${REG_TOKEN_CACHE_TTL:-300}" # seconds, default 5 minutes
shell_refresh_derived_config

# ------------------------------- Helpers -------------------------------
shell_usage() {
  local COLW=48
  echo "Usage: ./runner.sh COMMAND [options]    Where [options] depend on COMMAND. Available COMMANDs:"
  echo

  echo "1. Creation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh init -n N" "Generate docker-compose.yml then create runners and start"
  printf "  %-${COLW}s %s\n" "./runner.sh add [-n N]" "Append N new numbered runners after existing runner indexes"
  printf "  %-${COLW}s %s\n" "./runner.sh add <runner-name> [...]" "Add one or more runners with explicit names"
  printf "  %-${COLW}s %s\n" "./runner.sh compose" "Regenerate docker-compose.yml with existing runners"
  echo

  echo "2. Instance operation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Register specified instances; no args will iterate over all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Start specified instances (will register if needed); no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Stop Runner containers; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Restart specified instances; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh log ${RUNNER_NAME_PREFIX}runner-<id>" "Follow logs of a specified instance"
  echo

  echo "3. Query commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh ps|ls|list|status" "Show container status and registered Runner status"
  echo

  echo "4. Deletion commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh rm|remove|delete [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Delete specified instances; no args will delete all (confirmation required, -y to skip)"
  printf "  %-${COLW}s %s\n" "./runner.sh purge [-y]" "On top of remove, also delete the dynamically generated docker-compose.yml"
  echo

  echo "5. Image management commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh image" "Rebuild Docker image based on Dockerfile"
  echo

  echo "6. Help"
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
  printf "  %-${KEYW}s %s\n" "RUNNER_LABELS" "Default labels for runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_DEVICES" "Comma-separated device list for runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_GROUP_ADD" "Comma-separated extra groups for runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_VOLUMES" "Semicolon-separated extra volume mounts for runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_ENV" "Semicolon-separated KEY=VALUE envs for runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_COMMAND" "Command executed by runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_*_<N>" "Per-runner overrides, e.g. RUNNER_LABELS_1 or RUNNER_DEVICES_2"
  echo
  echo "Example workflow runs-on: runs-on: [self-hosted, linux, docker]"

  echo
  echo "Tips:"
  echo "- Compose file is auto-generated per ORG/REPO (e.g., docker-compose.<org>.yml)"
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

shell_detect_device_gid() {
    local device_path="${1:-}"
    [[ -n "$device_path" && -e "$device_path" ]] || return 1
    stat -c '%g' "$device_path" 2>/dev/null
}

shell_trim() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "$value"
}

shell_env_upsert() {
    local file="$1" key="$2" value="$3" tmp
    [[ -n "$key" && -n "$value" ]] || return 0

    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    grep -v -E "^[[:space:]]*${key}=" "$file" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
}

shell_get_indexed_env() {
    local key="$1" index="$2" default_value="${3:-}"
    local indexed_key="${key}_${index}"
    if [[ -n "${!indexed_key-}" ]]; then
        printf '%s' "${!indexed_key}"
    else
        printf '%s' "$default_value"
    fi
}

shell_parse_count_arg() {
    local default_count="$1"; shift
    local count="$default_count"

    if [[ "${1:-}" == "-n" || "${1:-}" == "--count" ]]; then
        shift
        count="${1:-}"
        [[ -n "$count" ]] || shell_die "Count is required after -n|--count!"
        shift || true
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || shell_die "Count must be numeric!"

    PARSED_COUNT="$count"
    PARSED_REMAINING_ARGS=("$@")
}

shell_runner_index_from_name() {
    local name="$1" prefix="${RUNNER_NAME_PREFIX}runner-"
    [[ "$name" == "${prefix}"* ]] || return 1

    local index="${name#"$prefix"}"
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$index"
}

shell_numbered_runner_name() {
    local index="$1"
    printf '%srunner-%s\n' "$RUNNER_NAME_PREFIX" "$index"
}

shell_validate_runner_name() {
    local name="${1:-}"
    [[ -n "$name" ]] || shell_die "Runner name cannot be empty!"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || \
        shell_die "Invalid runner name: $name (allowed: letters, numbers, dot, underscore, dash; must start with a letter or number)"
}

shell_runner_name_exists_in_list() {
    local needle="$1"; shift || true
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

shell_get_max_existing_runner_index() {
    local name index max_index=0
    local existing_names=()
    mapfile -t existing_names < <(docker_list_runner_services | sed '/^$/d') || true

    for name in "${existing_names[@]}"; do
        [[ -n "$name" ]] || continue
        index="$(shell_runner_index_from_name "$name" || true)"
        if [[ -n "$index" && "$index" -gt "$max_index" ]]; then
            max_index="$index"
        fi
    done

    printf '%s\n' "$max_index"
}

shell_append_csv_yaml_list() {
    local file="$1" indent="$2" csv="$3"
    local item trimmed
    IFS=',' read -r -a _items <<< "$csv"
    for item in "${_items[@]}"; do
        trimmed="$(shell_trim "$item")"
        [[ -n "$trimmed" ]] || continue
        printf '%s- %s\n' "$indent" "$trimmed" >> "$file"
    done
}

shell_append_device_yaml_list() {
    local file="$1" indent="$2" csv="$3"
    local item trimmed mapping
    IFS=',' read -r -a _items <<< "$csv"
    for item in "${_items[@]}"; do
        trimmed="$(shell_trim "$item")"
        [[ -n "$trimmed" ]] || continue
        if [[ "$trimmed" == *:* ]]; then
            mapping="$trimmed"
        else
            mapping="${trimmed}:${trimmed}"
        fi
        printf '%s- %s\n' "$indent" "$mapping" >> "$file"
    done
}

shell_append_semicolon_yaml_list() {
    local file="$1" indent="$2" values="$3"
    local item trimmed
    IFS=';' read -r -a _items <<< "$values"
    for item in "${_items[@]}"; do
        trimmed="$(shell_trim "$item")"
        [[ -n "$trimmed" ]] || continue
        printf '%s- %s\n' "$indent" "$trimmed" >> "$file"
    done
}

shell_append_semicolon_env_map() {
    local file="$1" indent="$2" values="$3"
    local item trimmed key value
    IFS=';' read -r -a _items <<< "$values"
    for item in "${_items[@]}"; do
        trimmed="$(shell_trim "$item")"
        [[ -n "$trimmed" ]] || continue
        [[ "$trimmed" == *"="* ]] || continue
        key="$(shell_trim "${trimmed%%=*}")"
        value="$(shell_trim "${trimmed#*=}")"
        [[ -n "$key" ]] || continue
        printf '%s%s: "%s"\n' "$indent" "$key" "$value" >> "$file"
    done
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

    # Recalculate auto-derived names after interactive ORG/REPO input.
    shell_refresh_derived_config
    export RUNNER_NAME_PREFIX COMPOSE_FILE DOCKERFILE_HASH_FILE REG_TOKEN_CACHE_FILE

    # Persist to .env (ENV_FILE) if values were entered interactively
    if [[ $wrote_env -eq 1 ]]; then
        local env_file="$ENV_FILE"
        touch "$env_file"
        chmod 600 "$env_file" 2>/dev/null || true

        shell_env_upsert "$env_file" "ORG" "${ORG:-}"
        shell_env_upsert "$env_file" "GH_PAT" "${GH_PAT:-}"
        shell_env_upsert "$env_file" "REPO" "${REPO:-}"
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
            if [[ ! -f "$hash_file" || "$new_hash" != "$old_hash" ]]; then
                shell_info "Detected Dockerfile change or missing hash file, building ${RUNNER_CUSTOM_IMAGE} image" >&2
                if docker build -t "${RUNNER_CUSTOM_IMAGE}" . 1>&2; then
                    echo "$new_hash" > "$hash_file"
                    shell_info "Build complete. Will use ${RUNNER_CUSTOM_IMAGE} as image" >&2
                    echo "${RUNNER_CUSTOM_IMAGE}"
                    return 0
                else
                    shell_warn "Docker build failed; hash file not updated. Fix the build error and retry." >&2
                    # fall through to check for existing image or use base
                fi
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
    local scope_names=()
    local use_compose_scope=0
    [[ -f "$COMPOSE_FILE" ]] && use_compose_scope=1
    mapfile -t scope_names < <(docker_list_runner_services | sed '/^$/d') || true

    if command -v jq >/dev/null 2>&1; then
        resp=$(github_api GET "/actions/runners?per_page=100" || echo "{}")
        if github_response_has_runner_list "$resp"; then
            if [[ $use_compose_scope -eq 1 ]]; then
                org_count=$(echo "$resp" | jq -r '[.runners[] | select(.name as $n | ($ARGS.positional | index($n)))] | length' --args "${scope_names[@]}" 2>/dev/null || echo 0)
            else
                org_count=$(echo "$resp" | jq -r --arg p "$prefix" '[.runners[] | select(.name|startswith($p))] | length' 2>/dev/null || echo 0)
            fi
        else
            github_print_api_error "$resp"
        fi
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

# Helper: Extract an environment variable value for a specific service from docker-compose.yml
# Usage: shell_get_compose_file SERVICE_NAME ENV_KEY
shell_get_compose_file() {
    local service="$1" key="$2"
    local file="$COMPOSE_FILE"
    [[ -f "$file" ]] || return 1
    
    local in_service=0 in_env=0 found=0
    
    while IFS= read -r line; do
        # Check if we're entering the target service
        if [[ "$line" == "  ${service}:" ]]; then
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
            # {0,4} matches top-level and service-level keys (0-4 spaces), but not environment
            # entries which are indented at 6+ spaces in the generated compose file
            if [[ "$line" =~ ^[a-zA-Z_] ]] || [[ "$line" =~ ^[[:space:]]{0,4}[a-zA-Z_] ]]; then
                in_env=0
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
    local runner_count=$1
    local runner_names=()
    local i

    if [[ "$runner_count" -gt 0 ]]; then
        for i in $(seq 1 "$runner_count"); do
            runner_names+=("$(shell_numbered_runner_name "$i")")
        done
    fi

    shell_generate_compose_file_for_names "${runner_names[@]}"
}

shell_generate_compose_file_for_names() {
    local runner_names=("$@")
    local runner_count="${#runner_names[@]}"
    local extra_proxy_env=()
    local kvm_gid="${RUNNER_KVM_GID:-}"

    if [[ "$runner_count" -eq 0 ]]; then
        printf '%s\n' \
            "# 自动生成的 Docker Compose 配置" \
            "# 机器名: $(hostname)" \
            "# runner 数量: 0" \
            "" \
            "services: {}" \
            "volumes: {}" > "${COMPOSE_FILE}"
        return 0
    fi

    # /dev/kvm 的权限检查是按数字 GID 生效
    # 优先使用宿主机当前 /dev/kvm 的实际 GID，必要时允许通过 RUNNER_KVM_GID 覆盖
    if [[ -z "$kvm_gid" ]]; then
        kvm_gid="$(shell_detect_device_gid /dev/kvm || true)"
    fi
    if [[ -n "$kvm_gid" ]]; then
        shell_info "Using /dev/kvm group id: ${kvm_gid}"
    else
        kvm_gid="993"
        shell_warn "/dev/kvm gid not detected; falling back to legacy gid ${kvm_gid}. Set RUNNER_KVM_GID to override."
    fi
    [[ -n "${HTTP_PROXY:-}" ]] && extra_proxy_env+=("      HTTP_PROXY: \"${HTTP_PROXY}\"")
    [[ -n "${HTTPS_PROXY:-}" ]] && extra_proxy_env+=("      HTTPS_PROXY: \"${HTTPS_PROXY}\"")
    [[ -n "${NO_PROXY:-}" ]] && extra_proxy_env+=("      NO_PROXY: \"${NO_PROXY}\"")

    # 使用 printf 输出文件头
    printf '%s\n' \
        "# 自动生成的 Docker Compose 配置" \
        "# 机器名: $(hostname)" \
        "# runner 数量: $runner_count" \
        "" \
        "# 基础配置" \
        "x-${RUNNER_NAME_PREFIX}runner-base: &runner_base" \
        "  image: \"${RUNNER_IMAGE}\"" \
        "  restart: unless-stopped" \
        "  network_mode: host" \
        "  privileged: true" \
        "" \
        "services:" > "${COMPOSE_FILE}"

    # 生成 runners。差异通过 RUNNER_*_<index> 环境变量按实例覆盖。
    local i=0 runner_name runner_index runner_labels runner_devices runner_groups runner_env runner_volumes runner_command
    for runner_name in "${runner_names[@]}"; do
        i=$((i + 1))
        runner_index="$(shell_runner_index_from_name "$runner_name" || true)"
        [[ -n "$runner_index" ]] || runner_index="$i"

        runner_labels="$(shell_get_indexed_env "RUNNER_LABELS" "$runner_index" "${RUNNER_LABELS}")"
        runner_devices="$(shell_get_indexed_env "RUNNER_DEVICES" "$runner_index" "${RUNNER_DEVICES}")"
        runner_groups="$(shell_get_indexed_env "RUNNER_GROUP_ADD" "$runner_index" "${RUNNER_GROUP_ADD}")"
        runner_env="$(shell_get_indexed_env "RUNNER_ENV" "$runner_index" "${RUNNER_ENV}")"
        runner_volumes="$(shell_get_indexed_env "RUNNER_VOLUMES" "$runner_index" "${RUNNER_VOLUMES}")"
        runner_command="$(shell_get_indexed_env "RUNNER_COMMAND" "$runner_index" "${RUNNER_COMMAND}")"

        printf '%s\n' \
            "  ${runner_name}:" \
            "    <<: *runner_base" \
            "    container_name: \"${runner_name}\"" \
            "    command:" \
            "      - /bin/bash" \
            "      - -lc" \
            "      - |" \
            "        exec ${runner_command}" >> "${COMPOSE_FILE}"
        if [[ -n "$(shell_trim "$runner_devices")" ]]; then
            printf '%s\n' "    devices:" >> "${COMPOSE_FILE}"
            shell_append_device_yaml_list "${COMPOSE_FILE}" "      " "${runner_devices}"
        fi
        printf '%s\n' \
            "    group_add:" \
            "      - ${kvm_gid}" >> "${COMPOSE_FILE}"
        shell_append_csv_yaml_list "${COMPOSE_FILE}" "      " "${runner_groups}"
        printf '%s\n' \
            "    environment:" \
            "      RUNNER_LABELS: \"${runner_labels}\"" \
            "${extra_proxy_env[@]}" >> "${COMPOSE_FILE}"
        shell_append_semicolon_env_map "${COMPOSE_FILE}" "      " "${runner_env}"
        printf '%s\n' \
            "    volumes:" \
            "      - ${runner_name}-data:/home/runner" \
            "      - ${runner_name}-udev-rules:/etc/udev/rules.d" >> "${COMPOSE_FILE}"
        shell_append_semicolon_yaml_list "${COMPOSE_FILE}" "      " "${runner_volumes}"
        printf '\n' >> "${COMPOSE_FILE}"
    done

    # 生成 volumes
    echo "volumes:" >> ${COMPOSE_FILE}
    
    for runner_name in "${runner_names[@]}"; do
        printf '%s\n' \
            "  ${runner_name}-data:" \
            "    name: ${runner_name}-data" \
            "  ${runner_name}-udev-rules:" \
            "    name: ${runner_name}-udev-rules" >> "${COMPOSE_FILE}"
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

github_response_has_runner_list() {
    local resp="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$resp" | jq -e '.runners | type == "array"' >/dev/null 2>&1
    else
        echo "$resp" | grep -q '"runners"[[:space:]]*:'
    fi
}

github_print_api_error() {
    local resp="$1" message documentation_url
    if command -v jq >/dev/null 2>&1; then
        message="$(echo "$resp" | jq -r '.message // empty' 2>/dev/null || true)"
        documentation_url="$(echo "$resp" | jq -r '.documentation_url // empty' 2>/dev/null || true)"
    else
        message="$(echo "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        documentation_url="$(echo "$resp" | sed -n 's/.*"documentation_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    fi

    if [[ -n "$message" ]]; then
        shell_warn "GitHub API did not return a runner list: ${message}"
    else
        shell_warn "GitHub API did not return a runner list. Check ORG/REPO, GH_PAT, and token permissions."
    fi
    [[ -n "$documentation_url" ]] && shell_warn "GitHub API documentation: ${documentation_url}"
}

github_get_runner_id_by_name() {
    local name="$1"
    local resp
    resp=$(github_api GET "/actions/runners?per_page=100") || return 1
    github_response_has_runner_list "$resp" || { github_print_api_error "$resp"; return 1; }
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
    github_response_has_runner_list "$resp" || { github_print_api_error "$resp"; return 1; }
    local scope_names=()
    local use_compose_scope=0
    [[ -f "$COMPOSE_FILE" ]] && use_compose_scope=1
    mapfile -t scope_names < <(docker_list_runner_services | sed '/^$/d') || true
    if command -v jq >/dev/null 2>&1; then
        if [[ $use_compose_scope -eq 1 ]]; then
            while IFS=$'\t' read -r id name; do
                [[ -n "$id" && "$id" != "null" ]] || continue
                shell_info "Unregistering from GitHub: $name (id=$id)"
                github_delete_runner_by_id "$id" || shell_warn "Failed to unregister $name on GitHub; please remove it manually via the GitHub web UI!"
            done < <(echo "$resp" | jq -r '.runners[] | select(.name as $n | ($ARGS.positional | index($n))) | "\(.id)\t\(.name)"' --args "${scope_names[@]}")
        else
            while IFS=$'\t' read -r id name; do
                [[ -n "$id" && "$id" != "null" ]] || continue
                shell_info "Unregistering from GitHub: $name (id=$id)"
                github_delete_runner_by_id "$id" || shell_warn "Failed to unregister $name on GitHub; please remove it manually via the GitHub web UI!"
            done < <(echo "$resp" | jq -r --arg p "$prefix" '.runners[] | select(.name|startswith($p)) | "\(.id)\t\(.name)"')
        fi
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

docker_list_runner_services() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        $DC -f "$COMPOSE_FILE" config --services || true
    else
        docker ps -a --filter "name=${RUNNER_NAME_PREFIX}runner-" --format "{{.Names}}" || true
    fi
}

docker_list_existing_containers() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local service
        while IFS= read -r service; do
            [[ -n "$service" ]] || continue
            docker_container_exists "$service" && printf '%s\n' "$service"
        done < <(docker_list_runner_services | sed '/^$/d')
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

docker_runner_service_exists() {
    local name="$1"
    if [[ -f "$COMPOSE_FILE" ]]; then
        $DC -f "$COMPOSE_FILE" config --services | grep -qx "$name" >/dev/null 2>&1
    else
        docker ps -a --format '{{.Names}}' | grep -qx "$name" >/dev/null 2>&1
    fi
}

# Check whether a specific container exists (local docker ps -a name match)
docker_container_exists() {
    local name="$1"
    docker ps -a --format '{{.Names}}' | grep -qx "$name" >/dev/null 2>&1
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
        mapfile -t names < <(docker_list_runner_services | sed '/^$/d') || true
    fi
    if [[ ${#names[@]} -eq 0 ]]; then
        shell_info "No Runner containers to register!"
        return 0
    fi
    
    local cname
    for cname in "${names[@]}"; do
        if ! docker_runner_service_exists "$cname"; then
            shell_warn "Runner service does not exist: $cname (skipping)"
            continue
        fi
        
        # Check if already configured
        local is_configured=false
        if [[ -f "$COMPOSE_FILE" ]]; then
            if $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
                is_configured=true
            fi
        else
            # docker exec only works on running containers; use docker run with the volume
            # so that stopped containers are also correctly detected as already configured
            local _cimg
            _cimg=$(docker inspect "$cname" --format='{{.Config.Image}}' 2>/dev/null || true)
            if [[ -n "$_cimg" ]]; then
                if docker run --rm -v "${cname}-data:/home/runner" "$_cimg" \
                    bash -c 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
                    is_configured=true
                fi
            fi
        fi
        
        if $is_configured; then
            shell_info "Already configured, skipping registration: $cname"
            continue
        fi
        
        # Extract RUNNER_LABELS
        local labels=""
        if [[ -f "$COMPOSE_FILE" ]]; then
            labels="$(shell_get_compose_file "$cname" "RUNNER_LABELS")" || labels=""
        else
            # Fallback: try to get from running container environment
            labels="$(docker inspect "$cname" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^RUNNER_LABELS=' | cut -d= -f2-)" || labels=""
        fi
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
        [[ "${DISABLE_AUTO_UPDATE}" == "1" || "${DISABLE_AUTO_UPDATE}" == "true" ]] && cfg_opts+=("--disableupdate")
        
        shell_info "Registering ${cname} on GitHub with ${cfg_opts[@]}"
        # Pass arguments directly to avoid shell quoting issues
        if [[ -f "$COMPOSE_FILE" ]]; then
            $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" /home/runner/config.sh "${cfg_opts[@]}" >/dev/null || shell_warn "Registration failed (container: $cname)"
        else
            docker exec "$cname" /home/runner/config.sh "${cfg_opts[@]}" >/dev/null || shell_warn "Registration failed (container: $cname)"
        fi
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
            mapfile -t scope_names < <(docker_list_runner_services | sed '/^$/d') || true
            if command -v jq >/dev/null 2>&1; then
                if github_response_has_runner_list "$resp"; then
                    if [[ ${#scope_names[@]} -gt 0 ]]; then
                        echo "$resp" | jq -r '.runners[] | select(.name as $n | ($ARGS.positional | index($n))) | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' --args "${scope_names[@]}" \
                            | awk -F'\t' 'BEGIN{printf("%-40s %-8s %-6s %s\n","NAME","STATUS","BUSY","LABELS")}{printf("%-40s %-8s %-6s %s\n",$1,$2,$3,$4)}'
                    else
                        echo "$resp" | jq -r --arg p "${RUNNER_NAME_PREFIX}runner-" '.runners[] | select(.name|startswith($p)) | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' \
                            | awk -F'\t' 'BEGIN{printf("%-40s %-8s %-6s %s\n","NAME","STATUS","BUSY","LABELS")}{printf("%-40s %-8s %-6s %s\n",$1,$2,$3,$4)}'
                    fi
                else
                    github_print_api_error "$resp"
                    exit 1
                fi
            else
                if github_response_has_runner_list "$resp"; then
                    echo "$resp"
                else
                    github_print_api_error "$resp"
                    exit 1
                fi
            fi
            echo
            shell_info "Due to GitHub limitations, runner list is limited to 100 entries!"
            echo
            ;;

        # ./runner.sh init -n|--count N
        init)
            shell_parse_count_arg 0 "$@"
            count="$PARSED_COUNT"
            set -- "${PARSED_REMAINING_ARGS[@]}"
            [[ $# -eq 0 ]] || shell_die "Unexpected arguments after -n|--count: $*"
            [[ "$count" -gt 0 ]] || shell_die "Init count must be greater than 0!"

            REG_TOKEN="$(shell_get_reg_token)"

            RUNNER_IMAGE="$(shell_prepare_runner_image)";

            shell_info "Generating $COMPOSE_FILE with $count runners."

            shell_generate_compose_file "$count"

            $DC -f "$COMPOSE_FILE" up -d "$@";

            docker_runner_register
            ;;

        # ./runner.sh add -n|--count N
        # ./runner.sh add runner-name [...]
        add)
            existing_names=()
            mapfile -t existing_names < <(docker_list_runner_services | sed '/^$/d') || true
            new_names=()

            if [[ "${1:-}" == "-n" || "${1:-}" == "--count" || $# -eq 0 ]]; then
                shell_parse_count_arg 1 "$@"
                add_count="$PARSED_COUNT"
                set -- "${PARSED_REMAINING_ARGS[@]}"
                [[ $# -eq 0 ]] || shell_die "Unexpected arguments after -n|--count: $*"
                [[ "$add_count" -gt 0 ]] || shell_die "Add count must be greater than 0!"

                current_max="$(shell_get_max_existing_runner_index)"
                new_total=$((current_max + add_count))
                for i in $(seq $((current_max + 1)) "$new_total"); do
                    new_names+=("$(shell_numbered_runner_name "$i")")
                done
            else
                for name in "$@"; do
                    shell_validate_runner_name "$name"
                    if shell_runner_name_exists_in_list "$name" "${existing_names[@]}" "${new_names[@]}"; then
                        shell_die "Runner already exists or was specified more than once: $name"
                    fi
                    new_names+=("$name")
                done
                add_count="${#new_names[@]}"
            fi

            REG_TOKEN="$(shell_get_reg_token)"

            RUNNER_IMAGE="$(shell_prepare_runner_image)";

            shell_info "Adding ${add_count} runner(s): ${new_names[*]}"
            all_names=("${existing_names[@]}" "${new_names[@]}")
            shell_info "Regenerating $COMPOSE_FILE with ${#all_names[@]} total runner slots."

            shell_generate_compose_file_for_names "${all_names[@]}"

            $DC -f "$COMPOSE_FILE" up -d "${new_names[@]}";

            docker_runner_register "${new_names[@]}"
            ;;
        
        # ./runner.sh compose
        compose)
            mapfile -t existing_names < <(docker_list_runner_services | sed '/^$/d') || true
            shell_info "Regenerating $COMPOSE_FILE with ${#existing_names[@]} existing runners."
            RUNNER_IMAGE="$(shell_prepare_runner_image)";
            REG_TOKEN="$(shell_get_reg_token)"
            shell_generate_compose_file_for_names "${existing_names[@]}"
            ;;

        # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
        register)
            REG_TOKEN="$(shell_get_reg_token)"

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
                    if ! docker_runner_service_exists "$s"; then
                        shell_warn "No Runner service found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to start!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_runner_services) || ids=()
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
                    if ! docker_runner_service_exists "$s"; then
                        shell_warn "No Runner service found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to stop!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_runner_services) || ids=()
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
                    if ! docker_runner_service_exists "$s"; then
                        shell_warn "No Runner service found for $s, ignoring this argument!"
                        continue
                    fi
                    ids+=("$s")
                done
                if [[ ${#ids[@]} -eq 0 ]]; then
                    shell_info "No Runner containers to restart!"
                    exit 0
                fi
            else
                mapfile -t ids < <(docker_list_runner_services) || ids=()
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

        # ./runner.sh log ${RUNNER_NAME_PREFIX}runner-<id>
        log)
            [[ $# -eq 1 ]] || shell_die "Usage: ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>"

            docker_runner_service_exists "$1" || shell_die "Runner service $1 not found"

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
                    if ! docker_runner_service_exists "$s"; then
                        shell_warn "No Runner service found for $s, ignoring this argument!"
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
                    
                    shell_info "Removing container: $name"
                    if [[ -f "$COMPOSE_FILE" ]]; then
                        # Stop and remove specific container using compose
                        $DC -f "$COMPOSE_FILE" rm -s -f -v "$name" >/dev/null 2>&1 || true
                        docker volume rm "${name}-data" >/dev/null 2>&1 || true
                        docker volume rm "${name}-udev-rules" >/dev/null 2>&1 || true
                    else
                        # Stop and remove container using docker
                        docker rm -f "$name" >/dev/null 2>&1 || true
                        # Remove associated volumes
                        docker volume rm "${name}-data" >/dev/null 2>&1 || true
                        docker volume rm "${name}-udev-rules" >/dev/null 2>&1 || true
                    fi
                    shell_info "Removed: $name"
                done
                if [[ -f "$COMPOSE_FILE" ]]; then
                    mapfile -t existing_names < <($DC -f "$COMPOSE_FILE" config --services || true)
                    remaining_names=()
                    for name in "${existing_names[@]}"; do
                        if ! shell_runner_name_exists_in_list "$name" "${matched[@]}"; then
                            remaining_names+=("$name")
                        fi
                    done
                    RUNNER_IMAGE="$(shell_prepare_runner_image)";
                    shell_info "Regenerating $COMPOSE_FILE with ${#remaining_names[@]} remaining runner slots."
                    shell_generate_compose_file_for_names "${remaining_names[@]}"
                fi
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
                "${REG_TOKEN_CACHE_FILE}"* \
                "${DOCKERFILE_HASH_FILE}" \
                "$ENV_FILE" \
                "$COMPOSE_FILE"; do
                if [[ -f "$f" ]]; then
                    shell_info "Removing file $f"
                    rm -f "$f" || true
                fi
            done
            shell_info "purge complete!"
            ;;

        # ./runner.sh image
        image)
            if [[ ! -f Dockerfile ]]; then
                shell_die "Dockerfile not found in current directory!"
            fi
            
            shell_info "Rebuilding Docker image based on Dockerfile..."
            
            # Force rebuild by removing hash file if it exists
            if [[ -f "$DOCKERFILE_HASH_FILE" ]]; then
                rm -f "$DOCKERFILE_HASH_FILE"
                shell_info "Removed existing Dockerfile hash to force rebuild"
            fi
            
            # Build the image
            if docker build -t "${RUNNER_CUSTOM_IMAGE}" .; then
                shell_info "Successfully built ${RUNNER_CUSTOM_IMAGE} image"
                
                # Update hash file
                image_new_hash=""
                if command -v sha256sum >/dev/null 2>&1; then
                    image_new_hash=$(sha256sum Dockerfile | awk '{print $1}')
                elif command -v shasum >/dev/null 2>&1; then
                    image_new_hash=$(shasum -a 256 Dockerfile | awk '{print $1}')
                fi
                
                if [[ -n "$image_new_hash" ]]; then
                    echo "$image_new_hash" > "$DOCKERFILE_HASH_FILE"
                    shell_info "Updated Dockerfile hash"
                fi
            else
                shell_die "Failed to build Docker image!"
            fi
            ;;

        # ./runner.sh
        *)
            shell_usage
            exit 1
            ;;
    esac
fi
