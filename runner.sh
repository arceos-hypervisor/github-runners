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
RUNNER_COUNT="${RUNNER_COUNT:-2}"
BOARD_RUNNERS="phytiumpi:phytiumpi;roc-rk3568-pc:roc-rk3568-pc"  # e.g. board1_name:labels1,label2;board2_name:labels1,label2[;...], semicolon-separated entries, labels inside each entry comma-separated
COMPOSE_FILE="docker-compose.yml"
DOCKERFILE_HASH_FILE="${DOCKERFILE_HASH_FILE:-.dockerfile.sha256}"
RUNNER_LABELS="${RUNNER_LABELS:-intel}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:+${RUNNER_NAME_PREFIX}-}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"

# Internal container privileges and device mapping settings
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
  echo "Usage: ./runner.sh COMMAND [options]    Where [options] depend on COMMAND. Available COMMANDs:"
  echo

  echo "1. Creation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh init [-n N]" "Generate N services and start (defaults to RUNNER_COUNT from .env)"
  printf "  %-${COLW}s %s\n" "" "First run will request a registration token from the organization and persist it into each volume"
  echo

  echo "2. Instance operation commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Register specified instances; no args will iterate over all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh start [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Start specified instances (will register if needed); no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh stop [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Stop Runner containers; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh restart [${RUNNER_NAME_PREFIX}runner-<id> ...]" "Restart specified instances; no args will iterate all existing instances"
  printf "  %-${COLW}s %s\n" "./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>" "Follow logs of a specified instance"
  echo

  echo "3. Query commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh ps" "Show status of related containers"
  printf "  %-${COLW}s %s\n" "./runner.sh list|status" "Show container status and registered Runner status"
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
  printf "  %-${KEYW}s %s\n" "ORG" "Organization name (required)"
  printf "  %-${KEYW}s %s\n" "GH_PAT" "Classic PAT (requires admin:org), used for org API and registration token"
  printf "  %-${KEYW}s %s\n" "RUNNER_LABELS" "Example: self-hosted,linux,docker"
  printf "  %-${KEYW}s %s\n" "RUNNER_GROUP" "Runner group (optional)"
  printf "  %-${KEYW}s %s\n" "RUNNER_NAME_PREFIX" "Runner name prefix"
  printf "  %-${KEYW}s %s\n" "RUNNER_COUNT" "Default count for creation"
  printf "  %-${KEYW}s %s\n" "BOARD_RUNNERS" "Board Runner list: name:label1[,label2] semicolon-separated entries; labels inside each entry comma-separated"
  printf "  %-${KEYW}s %s\n" "DISABLE_AUTO_UPDATE" '"1" disables Runner auto-update'
  printf "  %-${KEYW}s %s\n" "RUNNER_WORKDIR" "Work directory (default /runner/_work)"
  printf "  %-${KEYW}s %s\n" "MOUNT_DOCKER_SOCK" '"true"/"1" mounts /var/run/docker.sock (high privilege, use with caution)'
  printf "  %-${KEYW}s %s\n" "REPO" "Optional repository name (when set, operate on repo-scoped runners under ORG/REPO instead of organization-wide runners)"
  printf "  %-${KEYW}s %s\n" "RUNNER_IMAGE" "Image used for compose generation (default ghcr.io/actions/actions-runner:latest)"
  printf "  %-${KEYW}s %s\n" "RUNNER_CUSTOM_IMAGE" "Image tag used for auto-build (can override)"
  printf "  %-${KEYW}s %s\n" "PRIVILEGED" "Run as privileged (default true, recommended to solve loop device issues)"
  printf "  %-${KEYW}s %s\n" "MAP_LOOP_DEVICES" "Map host /dev/loop* to container (default true)"
  printf "  %-${KEYW}s %s\n" "LOOP_DEVICE_COUNT" "Max loop devices to map (default 4)"
  printf "  %-${KEYW}s %s\n" "MAP_KVM_DEVICE" "Map /dev/kvm to container (default true if present)"
  printf "  %-${KEYW}s %s\n" "MAP_USB_DEVICE" "Map /dev/ttyUSB* to container (default true if present)"
  printf "  %-${KEYW}s %s\n" "MOUNT_UDEV_RULES_DIR" "Mount /etc/udev/rules.d to ensure the directory exists (default true)"

  echo
  echo "Example workflow runs-on: runs-on: [self-hosted, linux, docker]"

  echo
  echo "Tips:" 
  echo "- The dynamically generated docker-compose.yml will overwrite an existing file with the same name (existing containers are not affected)."
  echo "- Re-start/up will reuse existing volumes; Runner configuration and tool caches will not be lost."
  echo "- BOARD_RUNNERS example: phytiumpi:phytiumpi,extra1;roc-rk3568-pc:roc-rk3568-pc; semicolon separates boards, labels after colon are board-specific (comma-separated)."
  echo "- Board instances now only use their own labels (from BOARD_RUNNERS), they no longer include the base RUNNER_LABELS."
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

# Count valid BOARD_RUNNERS entries (form: name:labels) and return the number
shell_count_board_runners() {
    local br="${BOARD_RUNNERS:-}" c=0 e
    [[ -n "$br" ]] || { echo 0; return 0; }
    IFS=';' read -r -a __arr <<< "$br"
    for e in "${__arr[@]}"; do
    # Trim leading/trailing whitespace
        e="$(echo "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$e" ]] && continue
    # Must contain colon and non-empty part after colon
        [[ "$e" == *:* ]] || continue
        local name="${e%%:*}" rest="${e#*:}"
        [[ -n "$name" && -n "$rest" ]] || continue
        ((c++))
    done
    echo "$c"
}

# Generate docker-compose.yml file
shell_render_compose_file() {
    local count="$1"
    [[ "$count" =~ ^[0-9]+$ ]] || shell_die "Failed to generate compose: invalid count!"
    (( count >= 1 )) || shell_die "Failed to generate compose: count must be >= 1!"

    shell_info "Generating ${COMPOSE_FILE} (${RUNNER_NAME_PREFIX}runner-1 ... ${RUNNER_NAME_PREFIX}runner-${count})"
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

        # Grant containers near-host kernel capabilities and unlock access to devices (it's preferable to use cap-add for fine-grained control)
        if [[ "$PRIVILEGED" == "1" || "$PRIVILEGED" == "true" ]]; then
            printf "  %s\n" "privileged: true"
        fi

        # Map devices (kvm, loop, usb)
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

        # Add Linux groups so container can access devices owned by specific groups (e.g. /dev/kvm)
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
            printf "  %s\n" "# To use docker inside jobs, mount host docker.sock (high privilege; use with caution)"
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

        # Dynamic board instances (BOARD_RUNNERS: board1_name:labels1,label2;board2_name:labels1,label2[;...])
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
                # For board instances, only use labels provided in BOARD_RUNNERS; do not append base RUNNER_LABELS
                printf "      %s\n" "RUNNER_LABELS: \"${blabels}\""
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
        # Use a C-style loop to avoid IFS modifications affecting seq output splitting
        local i
        for (( i=1; i<=count; i++ )); do
            printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-data:"
            if [[ "$MOUNT_UDEV_RULES_DIR" == "1" || "$MOUNT_UDEV_RULES_DIR" == "true" ]]; then
                printf "  %s\n" "${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:"
            fi
        done
        # Dynamic board instances (BOARD_RUNNERS: board1_name:labels1,label2;board2_name:labels1,label2[;...])
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

    github_delete_all_runners_with_prefix || true
    docker_remove_all_local_containers_and_volumes || true
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
    shell_info "Requesting organization registration token..." >&2
    local new_token
    new_token="$(github_fetch_reg_token || true)"
    [[ -n "$new_token" && "$new_token" != "null" ]] || shell_die "Failed to fetch registration token!"
    REG_TOKEN="$new_token"
    export REG_TOKEN
    printf '%s\n%s\n' "$now" "$REG_TOKEN" > "$REG_TOKEN_CACHE_FILE"
    printf '%s\n' "$REG_TOKEN"
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
        shell_info "${COMPOSE_FILE} not found and docker command not detected; cannot query status."
    fi
}

# Check whether a specific container exists (local docker ps -a name match)
docker_container_exists() {
    local name="$1"
    [[ -f "$COMPOSE_FILE" ]] || return 1
    $DC -f "$COMPOSE_FILE" ps --services --all | grep -qx "$name" >/dev/null 2>&1
}

docker_remove_all_local_containers_and_volumes() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        shell_info "Using docker compose down -v to remove all services and volumes"
        $DC -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    else
        shell_warn "${COMPOSE_FILE} not found; skipping compose down -v."
    fi
}

docker_runner_register() {
    # Usage:
    #   docker_runner_register                -> auto-detect all runner-* containers and register unconfigured ones
    #   docker_runner_register runner-1 ...   -> register runners with the specified names
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
        # Compute labels: base RUNNER_LABELS, overridden by BOARD_RUNNERS entry when matching
        local labels="${RUNNER_LABELS}"
        if [[ -n "${BOARD_RUNNERS:-}" ]]; then
            # BOARD_RUNNERS entries are semicolon-separated
            local IFS=';' entry raw name blabels svcbase
            svcbase="${cname#"${RUNNER_NAME_PREFIX}"runner-}"
            for entry in ${BOARD_RUNNERS}; do
                raw="${entry}"; name="${raw%%:*}"; blabels="${raw#*:}"
                if [[ "$name" == "$svcbase" ]]; then
                    # Match board instance: only use the labels from the board entry, overriding base RUNNER_LABELS
                    labels="${blabels}"
                fi
            done
            # Restore IFS to avoid semicolon-joined expansion in subsequent ${cfg_opts[*]}
            IFS=$' \t\n'
        fi
        # Deduplicate labels
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
        shell_info "Registering on GitHub: ${cname}"
        $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc "/home/runner/config.sh ${cfg_opts[*]}" >/dev/null || shell_warn "Registration failed (container: $cname)"
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

    # ./runner.sh list|status
    list|status)
        echo "--------------------------------- Containers -----------------------------------------"
        docker_print_existing_containers_status
        echo
        shell_get_org_and_pat
        echo "--------------------------------- Runners --------------------------------------------"
        resp=$(github_api GET "/actions/runners?per_page=100") || shell_die "Failed to fetch organization runner list."
        if command -v jq >/dev/null 2>&1; then
            echo "$resp" | jq -r '.runners[] | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' \
                | awk -F'\t' 'BEGIN{printf("%-40s %-8s %-6s %s\n","NAME","STATUS","BUSY","LABELS")}{printf("%-40s %-8s %-6s %s\n",$1,$2,$3,$4)}'
        else
            echo "$resp"
        fi
        echo
        shell_info "Due to GitHub limitations, organization runner list is limited to 100 entries!"
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
        [[ "$count" =~ ^[0-9]+$ ]] || shell_die "Count must be numeric!"
        # Compute number of board-specific runners
        board_count="$(shell_count_board_runners)"
        generic_count=$(( count - board_count ))
        (( generic_count > 0 )) || shell_die "(total - board_count) resulting generic instance count must be > 0!"

        # Subtract board-specific count only when rendering compose (board instances are appended separately)
        shell_render_compose_file "$generic_count"

        # Only start/register generic instances here (board instances were added separately in the compose file)
        docker_compose_up
        docker_runner_register
        ;;

    # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
    register)
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
            ids=(); max_id=0
            for s in "$@"; do
                if ! docker_container_exists "$s"; then
                    shell_warn "No Runner container found for $s, ignoring this argument!"
                    continue
                fi
                ids+=("$s")
                n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
            if [[ ${#ids[@]} -eq 0 ]]; then
                shell_info "No Runner containers to stop!"
                exit 0
            fi
            exist_max="$(docker_highest_existing_index)"
            count="$exist_max"; (( max_id > count )) && count="$max_id"
            (( count >= 1 )) || count=1
            shell_render_compose_file "$count"
            docker_compose_up "${ids[@]}"
        else
            mapfile -t names < <(docker_list_existing_containers) || names=()
            if [[ ${#names[@]} -eq 0 ]]; then
                shell_info "No Runner containers to stop!"
                exit 0
            fi
            ids=(); max_id=0
            for cname in "${names[@]}"; do
                [[ -n "$cname" ]] || continue
                ids+=("$cname")
                n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
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
                    shell_warn "No Runner container found for $s, ignoring this argument!"
                    continue
                fi
                ids+=("$s")
                n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
            if [[ ${#ids[@]} -eq 0 ]]; then
                shell_info "No Runner containers to stop!"
                exit 0
            fi
            exist_max="$(docker_highest_existing_index)"
            count="$exist_max"; (( max_id > count )) && count="$max_id"
            (( count >= 1 )) || count=1
            shell_render_compose_file "$count"
            docker_compose_stop "${ids[@]}"
        else
            mapfile -t names < <(docker_list_existing_containers) || names=()
            if [[ ${#names[@]} -eq 0 ]]; then
                shell_info "No Runner containers to stop!"
                exit 0
            fi
            ids=(); max_id=0
            for cname in "${names[@]}"; do
                [[ -n "$cname" ]] || continue
                ids+=("$cname")
                n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
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
                    shell_warn "No Runner container found for $s, ignoring this argument!"
                    continue
                fi
                ids+=("$s")
                n="${s##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
            if [[ ${#ids[@]} -eq 0 ]]; then
                shell_info "No Runner containers to restart!"
                exit 0
            fi
        else
            mapfile -t names < <(docker_list_existing_containers) || names=()
            if [[ ${#names[@]} -eq 0 ]]; then
                shell_info "No Runner containers to restart!"
                exit 0
            fi
            for cname in "${names[@]}"; do
                [[ -n "$cname" ]] || continue
                ids+=("$cname")
                n="${cname##*-}"; [[ "$n" =~ ^[0-9]+$ ]] && (( n > max_id )) && max_id="$n"
            done
        fi
        (( max_id >= 1 )) || max_id=1
        shell_render_compose_file "$max_id"
        docker_compose_restart "${ids[@]}"
        ;;

    # ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>
    logs)
        [[ $# -eq 1 ]] || shell_die "Usage: ./runner.sh logs ${RUNNER_NAME_PREFIX}runner-<id>"
        [[ "$1" =~ ^${RUNNER_NAME_PREFIX}runner-([0-9]+)$ ]] || shell_die "Invalid service name: $1"
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
                # Related volume names: <container>-data and optionally <container>-udev-rules
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
        shell_get_org_and_pat
        if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
            shell_delete_all_execute ""
        else
            shell_delete_all_execute "Confirm unregister of all Runners, delete all containers and volumes, and remove all generated files? [y / N] " || { echo "Operation cancelled!"; exit 0; }
        fi
        for f in "$COMPOSE_FILE" \
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