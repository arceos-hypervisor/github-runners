#!/usr/bin/env bash
set -euo pipefail

# 忽略多组织部署时的 orphan 容器警告（同一主机运行多个组织的 runner 是正常场景）
export COMPOSE_IGNORE_ORPHANS=1

ENV_FILE="${ENV_FILE:-.env}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PXE_BOOT_DIR="${PXE_BOOT_DIR:-${SCRIPT_DIR}/pxe-boot}"

# ------------------------------- load .env file -------------------------------
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/export /')
fi

# Organization, REG_TOKEN, etc.
ORG="${ORG:-}"
GH_PAT="${GH_PAT:-}"
REPO="${REPO:-}"

# Runner container related parameters
RUNNER_IMAGE="${RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
RUNNER_CUSTOM_IMAGE="${RUNNER_CUSTOM_IMAGE:-qc-actions-runner:v0.0.1}"
# 容器名前缀：未显式设置时自动拼入 ORG/REPO，避免同一主机多副本时容器重名
# 组织级默认：<hostname>-<org>-  仓库级默认：<hostname>-<org>-<repo>-
if [[ -z "${RUNNER_NAME_PREFIX:-}" ]]; then
  if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
    RUNNER_NAME_PREFIX="$(hostname)-${ORG}-${REPO}-"
  elif [[ -n "${ORG:-}" ]]; then
    RUNNER_NAME_PREFIX="$(hostname)-${ORG}-"
  else
    RUNNER_NAME_PREFIX="$(hostname)-"
  fi
else
  # 用户显式设置了 RUNNER_NAME_PREFIX；确保以 - 结尾
  [[ "$RUNNER_NAME_PREFIX" == *- ]] || RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX}-"
fi
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-}"
RUNNER_LABELS="${RUNNER_LABELS:-intel}"
RUNNER_BOARD="4"
DISABLE_AUTO_UPDATE="${DISABLE_AUTO_UPDATE:-false}"
# 板子级：未设置时用本板默认值（同类型板串行、不同类型板并行）；多组织共享同一块板时显式设为相同 ID 即可
RUNNER_RESOURCE_ID_PHYTIUMPI="${RUNNER_RESOURCE_ID_PHYTIUMPI:-}"
RUNNER_RESOURCE_ID_ROC_RK3568_PC="${RUNNER_RESOURCE_ID_ROC_RK3568_PC:-}"
RUNNER_RESOURCE_ID_X86_64_PC="${RUNNER_RESOURCE_ID_X86_64_PC:-}"
RUNNER_RESOURCE_ID_VISIONFIVE2="${RUNNER_RESOURCE_ID_VISIONFIVE2:-}"
RUNNER_LOCK_DIR="${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
RUNNER_LOCK_HOST_PATH="${RUNNER_LOCK_HOST_PATH:-/tmp/github-runner-locks}"
# Compose 文件名：未显式设置时自动拼入 ORG/REPO，避免同一主机多组织时文件冲突
# 组织级默认：docker-compose.<org>.yml  仓库级默认：docker-compose.<org>.<repo>.yml
if [[ -z "${COMPOSE_FILE:-}" ]]; then
  if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
    COMPOSE_FILE="docker-compose.${ORG}.${REPO}.yml"
  elif [[ -n "${ORG:-}" ]]; then
    COMPOSE_FILE="docker-compose.${ORG}.yml"
  else
    COMPOSE_FILE="docker-compose.yml"
  fi
fi
# Dockerfile hash 文件名：同样根据 ORG/REPO 区分，避免多组织时 hash 冲突
if [[ -z "${DOCKERFILE_HASH_FILE:-}" ]]; then
  if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
    DOCKERFILE_HASH_FILE=".dockerfile.${ORG}.${REPO}.sha256"
  elif [[ -n "${ORG:-}" ]]; then
    DOCKERFILE_HASH_FILE=".dockerfile.${ORG}.sha256"
  else
    DOCKERFILE_HASH_FILE=".dockerfile.sha256"
  fi
fi
# REG_TOKEN_CACHE_FILE 文件名：未显式设置时自动拼入 ORG/REPO，避免同一主机多组织时文件冲突
# 组织级默认：.reg_token.cache.<org>  仓库级默认：.reg_token.cache.<org>.<repo>
if [[ -z "${REG_TOKEN_CACHE_FILE:-}" ]]; then
  if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
    REG_TOKEN_CACHE_FILE=".reg_token.cache.${ORG}.${REPO}"
  elif [[ -n "${ORG:-}" ]]; then
    REG_TOKEN_CACHE_FILE=".reg_token.cache.${ORG}"
  else
    REG_TOKEN_CACHE_FILE=".reg_token.cache"
  fi
fi
REG_TOKEN_CACHE_TTL="${REG_TOKEN_CACHE_TTL:-300}" # seconds, default 5 minutes

# ------------------------------- Helpers -------------------------------
if [[ -t 1 || -t 2 ]]; then
  SHELL_COLOR_RED=$'\033[0;31m'
  SHELL_COLOR_GREEN=$'\033[0;32m'
  SHELL_COLOR_YELLOW=$'\033[1;33m'
  SHELL_COLOR_BLUE=$'\033[0;34m'
  SHELL_COLOR_RESET=$'\033[0m'
else
  SHELL_COLOR_RED=''
  SHELL_COLOR_GREEN=''
  SHELL_COLOR_YELLOW=''
  SHELL_COLOR_BLUE=''
  SHELL_COLOR_RESET=''
fi

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

  echo "6. PXE deployment commands:"
  printf "  %-${COLW}s %s\n" "./runner.sh pxe --install [options]" "Deploy PXE service using templates from ./pxe-boot"
  printf "  %-${COLW}s %s\n" "./runner.sh pxe --status" "Show PXE service status"
  echo

  echo "7. Help"
  printf "  %-${COLW}s %s\n" "./runner.sh help" "Show this help"
  echo

  echo "Environment variables (from .env or interactive input):"
  local KEYW=24
  printf "  %-${KEYW}s %s\n" "GH_PAT" "Classic PAT (requires admin:org), used for org API and registration token"
  printf "  %-${KEYW}s %s\n" "ORG" "Organization name or user name (required)"
  printf "  %-${KEYW}s %s\n" "REPO" "Optional repository name (when set, operate on repo-scoped runners under ORG/REPO instead of organization-wide runners)"
  printf "  %-${KEYW}s %s\n" "RUNNER_NAME_PREFIX" "Container name prefix (default: <hostname>-<org>[-<repo>]-); auto includes ORG/REPO to avoid name conflicts"
  printf "  %-${KEYW}s %s\n" "RUNNER_IMAGE" "Image used for compose generation (default ghcr.io/actions/actions-runner:latest)"
  printf "  %-${KEYW}s %s\n" "RUNNER_CUSTOM_IMAGE" "Image tag used for auto-build (can override)"
  printf "  %-${KEYW}s %s\n" "RUNNER_RESOURCE_ID_PHYTIUMPI" "Lock ID for phytiumpi board (default: board-phytiumpi); same ID = serial across runners"
  printf "  %-${KEYW}s %s\n" "RUNNER_RESOURCE_ID_ROC_RK3568_PC" "Lock ID for roc-rk3568-pc board (default: board-roc-rk3568-pc); same ID = serial"
  printf "  %-${KEYW}s %s\n" "RUNNER_RESOURCE_ID_X86_64_PC" "Lock ID for x86_64-pc board (default: board-x86_64-pc); same ID = serial"
  printf "  %-${KEYW}s %s\n" "RUNNER_RESOURCE_ID_VISIONFIVE2" "Lock ID for visionfive2 board (default: board-visionfive2); same ID = serial"
  printf "  %-${KEYW}s %s\n" "RUNNER_LOCK_DIR" "Lock dir in container (default /tmp/github-runner-locks)"
  printf "  %-${KEYW}s %s\n" "RUNNER_LOCK_HOST_PATH" "Lock dir on host for bind mount (default /tmp/github-runner-locks)"
  echo
  echo "Example workflow runs-on: runs-on: [self-hosted, linux, docker]"

  echo
  echo "Tips:"
  echo "- Compose file is auto-generated per ORG/REPO (e.g., docker-compose.<org>.yml)"
  echo "- Re-start/up will reuse existing volumes; Runner configuration and tool caches will not be lost."
}

shell_die() { printf '%s[ERROR]%s %s\n' "${SHELL_COLOR_RED}" "${SHELL_COLOR_RESET}" "$*" >&2; exit 1; }
shell_info() { printf '%s[INFO]%s %s\n' "${SHELL_COLOR_BLUE}" "${SHELL_COLOR_RESET}" "$*"; }
shell_warn() { printf '%s[WARN]%s %s\n' "${SHELL_COLOR_YELLOW}" "${SHELL_COLOR_RESET}" "$*" >&2; }

shell_prompt_confirm() {
    # Return 0 for confirm, 1 for cancel
    local prompt="${1:-Confirm? [y/N]} "
    read -r -p "$prompt" ans
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" ]]
}

shell_escape_sed_replacement() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    printf '%s' "$value"
}

pxe_usage() {
    cat <<'EOF'
Usage: ./runner.sh pxe [options]

Options:
  -i, --install           Install and configure PXE environment
  -s, --start             Start dnsmasq PXE service
  -t, --stop              Stop dnsmasq PXE service
  -c, --clean             Clean PXE configuration and optionally TFTP root
      --status            Show PXE service status
  -h, --help              Show this help
      --yes               Skip confirmation when used with --clean
      --interface NAME    Network interface to listen on (default: eno1np0)
      --server-ip IP      PXE server IP (default: detected from interface)
      --client-ip IP      Optional static client IP embedded into GRUB config (default: empty)
      --mode MODE         DHCP mode: proxy | exclusive | none (default: proxy)
      --tftp-root DIR     TFTP root directory (default: /home/root/test/x86_64-pc)

Examples:
  ./runner.sh pxe --install
  ./runner.sh pxe --install --mode proxy
  ./runner.sh pxe --status
EOF
}

pxe_ipv4_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

pxe_int_to_ipv4() {
    local value="$1"
    printf '%d.%d.%d.%d\n' \
        $(( (value >> 24) & 255 )) \
        $(( (value >> 16) & 255 )) \
        $(( (value >> 8) & 255 )) \
        $(( value & 255 ))
}

pxe_prefix_to_mask_int() {
    local prefix="$1"
    if [[ "$prefix" -eq 0 ]]; then
        echo 0
    else
        echo $(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
}

pxe_prefix_to_netmask() {
    local prefix="$1"
    pxe_int_to_ipv4 "$(pxe_prefix_to_mask_int "$prefix")"
}

pxe_require_root() {
    [[ "$EUID" -eq 0 ]] || shell_die "PXE deployment requires root privileges. Please run with sudo or as root."
}

pxe_require_file() {
    local path="$1"
    [[ -f "$path" ]] || shell_die "Required file not found: $path"
}

pxe_require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || shell_die "Required command not found: $cmd"
}

pxe_parse_args() {
    PXE_ACTION=""
    PXE_INTERFACE="${PXE_INTERFACE:-eno1np0}"
    PXE_SERVER_IP="${PXE_SERVER_IP:-}"
    PXE_CLIENT_IP="${PXE_CLIENT_IP:-}"
    PXE_DHCP_MODE="${PXE_DHCP_MODE:-proxy}"
    PXE_TFTP_ROOT="${PXE_TFTP_ROOT:-/home/root/test/x86_64-pc}"
    PXE_KERNEL_FILE="${PXE_KERNEL_FILE:-}"
    PXE_ASSUME_YES=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--install) PXE_ACTION="install"; shift ;;
            -s|--start) PXE_ACTION="start"; shift ;;
            -t|--stop) PXE_ACTION="stop"; shift ;;
            -c|--clean) PXE_ACTION="clean"; shift ;;
            --status) PXE_ACTION="status"; shift ;;
            --interface)
                [[ $# -ge 2 ]] || shell_die "Missing value for --interface"
                PXE_INTERFACE="$2"
                shift 2
                ;;
            --server-ip)
                [[ $# -ge 2 ]] || shell_die "Missing value for --server-ip"
                PXE_SERVER_IP="$2"
                shift 2
                ;;
            --client-ip)
                [[ $# -ge 2 ]] || shell_die "Missing value for --client-ip"
                PXE_CLIENT_IP="$2"
                shift 2
                ;;
            --kernel)
                [[ $# -ge 2 ]] || shell_die "Missing value for --kernel"
                PXE_KERNEL_FILE="$2"
                shift 2
                ;;
            --mode)
                [[ $# -ge 2 ]] || shell_die "Missing value for --mode"
                PXE_DHCP_MODE="$2"
                shift 2
                ;;
            --tftp-root)
                [[ $# -ge 2 ]] || shell_die "Missing value for --tftp-root"
                PXE_TFTP_ROOT="$2"
                shift 2
                ;;
            --yes|-y) PXE_ASSUME_YES=1; shift ;;
            -h|--help) PXE_ACTION="help"; shift ;;
            *) shell_die "Unknown pxe option: $1" ;;
        esac
    done

    [[ -n "$PXE_ACTION" ]] || PXE_ACTION="help"
}

pxe_validate_mode() {
    case "$PXE_DHCP_MODE" in
        proxy|exclusive|none) ;;
        *) shell_die "Unsupported PXE mode: ${PXE_DHCP_MODE}. Supported modes: proxy, exclusive, none." ;;
    esac
}

pxe_check_network_interface() {
    pxe_require_command ip

    if ! ip link show "$PXE_INTERFACE" >/dev/null 2>&1; then
        shell_warn "Available network interfaces:"
        ip -o link show | awk -F': ' '{print $2}' >&2
        shell_die "Network interface does not exist: $PXE_INTERFACE"
    fi

    local actual_cidr actual_ip prefix mask_int network_int
    actual_cidr="$(ip -o -4 addr show dev "$PXE_INTERFACE" | awk '{print $4}' | head -n1)"
    actual_ip="${actual_cidr%%/*}"
    prefix="${actual_cidr##*/}"
    [[ -n "$actual_ip" && -n "$prefix" ]] || shell_die "Network interface ${PXE_INTERFACE} does not have an IPv4 address."

    if [[ -n "$PXE_SERVER_IP" && "$PXE_SERVER_IP" != "$actual_ip" ]]; then
        shell_warn "Interface ${PXE_INTERFACE} currently uses ${actual_ip}; overriding requested server IP ${PXE_SERVER_IP}."
    fi
    PXE_SERVER_IP="$actual_ip"
    PXE_SERVER_PREFIX="$prefix"
    mask_int="$(pxe_prefix_to_mask_int "$prefix")"
    network_int=$(( $(pxe_ipv4_to_int "$actual_ip") & mask_int ))
    PXE_SERVER_NETMASK="$(pxe_prefix_to_netmask "$prefix")"
    PXE_SERVER_NETWORK="$(pxe_int_to_ipv4 "$network_int")"
}

pxe_find_artifact() {
    local candidate
    for candidate in "$@"; do
        [[ -n "$candidate" && -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

pxe_install_packages() {
    local pkgs=()

    pxe_require_command apt-get

    command -v ip >/dev/null 2>&1 || pkgs+=(iproute2)
    command -v dnsmasq >/dev/null 2>&1 || pkgs+=(dnsmasq)
    command -v grub-mkimage >/dev/null 2>&1 || pkgs+=(grub-efi-amd64-bin)

    if ! pxe_find_artifact \
        /usr/lib/ipxe/undionly.kpxe \
        /usr/lib/ipxe/ipxe.efi \
        /usr/lib/ipxe/snponly.efi \
        /usr/lib/ipxe/snp.efi >/dev/null 2>&1; then
        pkgs+=(ipxe)
    fi

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        shell_info "Installing PXE dependencies: ${pkgs[*]}"
        apt-get update -qq
        apt-get install -y "${pkgs[@]}"
    fi
}

pxe_ensure_dnsmasq_conf_dir() {
    local dnsmasq_conf="/etc/dnsmasq.conf"
    pxe_require_file "$dnsmasq_conf"

    if ! grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq\.d/?' "$dnsmasq_conf"; then
        printf '\nconf-dir=/etc/dnsmasq.d/,*.conf\n' >> "$dnsmasq_conf"
    fi
}

pxe_render_template() {
    local src="$1"
    local dest="$2"
    shift 2

    pxe_require_file "$src"

    local sed_args=()
    local kv key value escaped
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        escaped="$(shell_escape_sed_replacement "$value")"
        sed_args+=(-e "s|__${key}__|${escaped}|g")
    done

    sed "${sed_args[@]}" "$src" > "$dest"
}

pxe_prepare_tftp_directory() {
    install -d -m 755 "$PXE_TFTP_ROOT"
    install -m 0644 "${PXE_BOOT_DIR}/ipxe-mb.efi" "${PXE_TFTP_ROOT}/ipxe-mb.efi"

    local bios_source fallback_efi_source
    bios_source="$(pxe_find_artifact /usr/lib/ipxe/undionly.kpxe)" || bios_source=""
    fallback_efi_source="$(pxe_find_artifact /usr/lib/ipxe/ipxe.efi /usr/lib/ipxe/snponly.efi /usr/lib/ipxe/snp.efi)" || fallback_efi_source=""

    if [[ -n "$bios_source" ]]; then
        install -m 0644 "$bios_source" "${PXE_TFTP_ROOT}/undionly.kpxe"
        PXE_BIOS_BOOT_LINE="dhcp-boot=tag:!ipxe,tag:bios,undionly.kpxe,,${PXE_SERVER_IP}"
    else
        PXE_BIOS_BOOT_LINE="# BIOS support disabled: undionly.kpxe not found"
        shell_warn "undionly.kpxe was not found; legacy BIOS PXE clients will be unsupported."
    fi

    if [[ -n "$fallback_efi_source" ]]; then
        install -m 0644 "$fallback_efi_source" "${PXE_TFTP_ROOT}/ipxe.efi"
        PXE_FALLBACK_EFI_BOOT_LINE="dhcp-boot=tag:!ipxe,tag:!efi-x86_64,tag:!bios,ipxe.efi,,${PXE_SERVER_IP}"
    else
        PXE_FALLBACK_EFI_BOOT_LINE="# Fallback EFI support disabled: ipxe.efi not found"
        shell_warn "No fallback EFI iPXE binary was found; non-x86_64 EFI clients will be unsupported."
    fi
}

pxe_render_dnsmasq_conf() {
    local dhcp_range_line dhcp_host_line no_dhcp_interface_line

    case "$PXE_DHCP_MODE" in
        proxy)
            dhcp_range_line="dhcp-range=${PXE_SERVER_NETWORK},proxy,${PXE_SERVER_NETMASK}"
            dhcp_host_line="# dhcp-host disabled in proxy mode"
            no_dhcp_interface_line="# full DHCP enabled in proxy mode"
            ;;
        exclusive)
            local network_int range_start range_end
            network_int="$(pxe_ipv4_to_int "$PXE_SERVER_NETWORK")"
            range_start="$(pxe_int_to_ipv4 $(( network_int + 100 )))"
            range_end="$(pxe_int_to_ipv4 $(( network_int + 200 )))"
            dhcp_range_line="dhcp-range=${range_start},${range_end},${PXE_SERVER_NETMASK},12h"
            dhcp_host_line="dhcp-host=88:88:88:88:87:88,${PXE_CLIENT_IP},infinite"
            no_dhcp_interface_line="# full DHCP enabled in exclusive mode"
            ;;
        none)
            dhcp_range_line="# DHCP range disabled in TFTP-only mode"
            dhcp_host_line="# dhcp-host disabled in TFTP-only mode"
            no_dhcp_interface_line="no-dhcp-interface=${PXE_INTERFACE}"
            ;;
    esac

    install -d -m 755 /etc/dnsmasq.d
    pxe_render_template \
        "${PXE_BOOT_DIR}/pxe-physical.conf" \
        "/etc/dnsmasq.d/pxe-physical.conf" \
        "INTERFACE=${PXE_INTERFACE}" \
        "SERVER_IP=${PXE_SERVER_IP}" \
        "CLIENT_IP=${PXE_CLIENT_IP}" \
        "TFTP_ROOT=${PXE_TFTP_ROOT}" \
        "DHCP_RANGE_LINE=${dhcp_range_line}" \
        "DHCP_HOST_LINE=${dhcp_host_line}" \
        "NO_DHCP_INTERFACE_LINE=${no_dhcp_interface_line}" \
        "BIOS_BOOT_LINE=${PXE_BIOS_BOOT_LINE}" \
        "FALLBACK_EFI_BOOT_LINE=${PXE_FALLBACK_EFI_BOOT_LINE}"
}

pxe_render_boot_assets() {
    local grub_cfg boot_ipxe autoexec_ipxe
    grub_cfg="$(mktemp /tmp/grub-embedded.XXXXXX.cfg)"
    boot_ipxe="$(mktemp /tmp/boot.XXXXXX.ipxe)"
    autoexec_ipxe="$(mktemp /tmp/autoexec.XXXXXX.ipxe)"

    local net_default_ip_line
    if [[ -n "${PXE_CLIENT_IP:-}" ]]; then
        net_default_ip_line="set net_default_ip=${PXE_CLIENT_IP}"
    else
        net_default_ip_line="# set net_default_ip is intentionally omitted"
    fi

    pxe_render_template \
        "${PXE_BOOT_DIR}/grub-embedded.cfg" \
        "$grub_cfg" \
        "NET_DEFAULT_IP_LINE=${net_default_ip_line}" \
        "SERVER_IP=${PXE_SERVER_IP}"

    grub-mkimage -o "${PXE_TFTP_ROOT}/grubx64.efi" -O x86_64-efi \
        -p "" \
        -c "$grub_cfg" \
        normal configfile tftp net boot multiboot multiboot2 \
        efinet linux linux16 serial terminal \
        echo cat ls test

    pxe_render_template \
        "${PXE_BOOT_DIR}/boot.ipxe" \
        "$boot_ipxe" \
        "SERVER_IP=${PXE_SERVER_IP}"

    if [[ -f "${PXE_BOOT_DIR}/autoexec.ipxe" ]]; then
        pxe_render_template \
            "${PXE_BOOT_DIR}/autoexec.ipxe" \
            "$autoexec_ipxe" \
            "SERVER_IP=${PXE_SERVER_IP}"
    else
        cp "$boot_ipxe" "$autoexec_ipxe"
    fi

    install -m 0644 "$boot_ipxe" "${PXE_TFTP_ROOT}/boot.ipxe"
    install -m 0644 "$autoexec_ipxe" "${PXE_TFTP_ROOT}/autoexec.ipxe"
    rm -f "$grub_cfg" "$boot_ipxe" "$autoexec_ipxe"
}

pxe_stop_conflicting_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop dnsmasq 2>/dev/null || true
        systemctl stop tftpd-hpa 2>/dev/null || true
        systemctl disable tftpd-hpa 2>/dev/null || true
    fi
}

pxe_start_service() {
    pxe_require_command dnsmasq
    pxe_require_command systemctl

    if ! dnsmasq --test >/dev/null 2>&1; then
        dnsmasq --test || true
        shell_die "dnsmasq configuration test failed."
    fi

    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq
    systemctl is-active --quiet dnsmasq || shell_die "dnsmasq failed to start."
}

pxe_stop_service() {
    pxe_require_command systemctl
    systemctl stop dnsmasq 2>/dev/null || true
}

pxe_print_port_status() {
    if command -v ss >/dev/null 2>&1; then
        ss -lun | awk 'NR==1 || /:(67|69|4011)[[:space:]]/'
    fi
}

pxe_show_status() {
    pxe_check_network_interface

    echo "PXE status"
    echo "=========="
    echo "Interface : ${PXE_INTERFACE}"
    echo "Server IP : ${PXE_SERVER_IP}"
    echo "Subnet    : ${PXE_SERVER_NETWORK}/${PXE_SERVER_PREFIX}"
    echo "TFTP root : ${PXE_TFTP_ROOT}"
    echo

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet dnsmasq; then
        echo "dnsmasq   : running"
    else
        echo "dnsmasq   : stopped"
    fi

    if [[ -f /etc/dnsmasq.d/pxe-physical.conf ]]; then
        echo "Config    : /etc/dnsmasq.d/pxe-physical.conf"
    else
        echo "Config    : missing"
    fi

    for file in ipxe-mb.efi undionly.kpxe ipxe.efi boot.ipxe autoexec.ipxe grubx64.efi grub.cfg kernel; do
        if [[ -f "${PXE_TFTP_ROOT}/${file}" ]]; then
            printf 'File      : %s\n' "$file"
        fi
    done

    echo
    pxe_print_port_status || true
}

pxe_clean_environment() {
    pxe_stop_service
    rm -f /etc/dnsmasq.d/pxe-physical.conf

    if [[ -d "$PXE_TFTP_ROOT" ]]; then
        if [[ "$PXE_ASSUME_YES" -eq 1 ]] || shell_prompt_confirm "Delete TFTP root ${PXE_TFTP_ROOT}? [y/N] "; then
            rm -rf "$PXE_TFTP_ROOT"
            shell_info "Removed TFTP root: ${PXE_TFTP_ROOT}"
        else
            shell_info "Kept TFTP root: ${PXE_TFTP_ROOT}"
        fi
    fi
}

pxe_install() {
    pxe_require_root
    pxe_validate_mode
    pxe_require_file "${PXE_BOOT_DIR}/pxe-physical.conf"
    pxe_require_file "${PXE_BOOT_DIR}/grub-embedded.cfg"
    pxe_require_file "${PXE_BOOT_DIR}/boot.ipxe"
    pxe_require_file "${PXE_BOOT_DIR}/autoexec.ipxe"
    pxe_require_file "${PXE_BOOT_DIR}/ipxe-mb.efi"

    pxe_install_packages
    pxe_check_network_interface
    if [[ -n "${PXE_KERNEL_FILE:-}" ]]; then
        shell_warn "--kernel is ignored by pxe now; deploy only prepares PXE service and bootloader files."
    fi
    pxe_stop_conflicting_services
    pxe_ensure_dnsmasq_conf_dir
    pxe_prepare_tftp_directory
    pxe_render_dnsmasq_conf
    pxe_render_boot_assets
    pxe_start_service

    shell_info "Interface: ${PXE_INTERFACE}"
    shell_info "Server IP: ${PXE_SERVER_IP}"
    shell_info "Subnet   : ${PXE_SERVER_NETWORK}/${PXE_SERVER_PREFIX}"
    shell_info "TFTP root: ${PXE_TFTP_ROOT}"
    shell_info "PXE deployment completed."
}

pxe_main() {
    pxe_parse_args "$@"

    case "$PXE_ACTION" in
        help) pxe_usage ;;
        install) pxe_install ;;
        start)
            pxe_require_root
            pxe_check_network_interface
            pxe_start_service
            ;;
        stop)
            pxe_require_root
            pxe_stop_service
            ;;
        clean)
            pxe_require_root
            pxe_clean_environment
            ;;
        status) pxe_show_status ;;
    esac
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

    # Recalculate RUNNER_NAME_PREFIX if it was auto-generated (not explicitly set by user)
    # Same logic as COMPOSE_FILE etc.: check if empty or equals default value (hostname only)
    local default_prefix
    default_prefix="$(hostname)-"
    if [[ -z "${RUNNER_NAME_PREFIX:-}" ]] || [[ "$RUNNER_NAME_PREFIX" == "$default_prefix" ]]; then
        if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
            RUNNER_NAME_PREFIX="$(hostname)-${ORG}-${REPO}-"
        elif [[ -n "${ORG:-}" ]]; then
            RUNNER_NAME_PREFIX="$(hostname)-${ORG}-"
        else
            RUNNER_NAME_PREFIX="$default_prefix"
        fi
        export RUNNER_NAME_PREFIX
    fi

    # Recalculate file paths based on newly obtained ORG/REPO
    if [[ -z "${COMPOSE_FILE:-}" ]] || [[ "$COMPOSE_FILE" == "docker-compose.yml" ]]; then
        if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
            COMPOSE_FILE="docker-compose.${ORG}.${REPO}.yml"
        elif [[ -n "${ORG:-}" ]]; then
            COMPOSE_FILE="docker-compose.${ORG}.yml"
        else
            COMPOSE_FILE="docker-compose.yml"
        fi
        export COMPOSE_FILE
    fi
    if [[ -z "${DOCKERFILE_HASH_FILE:-}" ]] || [[ "$DOCKERFILE_HASH_FILE" == ".dockerfile.sha256" ]]; then
        if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
            DOCKERFILE_HASH_FILE=".dockerfile.${ORG}.${REPO}.sha256"
        elif [[ -n "${ORG:-}" ]]; then
            DOCKERFILE_HASH_FILE=".dockerfile.${ORG}.sha256"
        else
            DOCKERFILE_HASH_FILE=".dockerfile.sha256"
        fi
        export DOCKERFILE_HASH_FILE
    fi
    if [[ -z "${REG_TOKEN_CACHE_FILE:-}" ]] || [[ "$REG_TOKEN_CACHE_FILE" == ".reg_token.cache" ]]; then
        if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
            REG_TOKEN_CACHE_FILE=".reg_token.cache.${ORG}.${REPO}"
        elif [[ -n "${ORG:-}" ]]; then
            REG_TOKEN_CACHE_FILE=".reg_token.cache.${ORG}"
        else
            REG_TOKEN_CACHE_FILE=".reg_token.cache"
        fi
        export REG_TOKEN_CACHE_FILE
    fi

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
    # ════════════════════════════════════════════════════════════════
    # 第一步：为两种板子 runner 类型定义资源 ID
    # ════════════════════════════════════════════════════════════════
    # 硬件板 phytiumpi - 总是启用文件锁
    local res_phytiumpi="${RUNNER_RESOURCE_ID_PHYTIUMPI:-board-phytiumpi}"
    # 硬件板 roc - 总是启用文件锁
    local res_roc="${RUNNER_RESOURCE_ID_ROC_RK3568_PC:-board-roc-rk3568-pc}"
    # 硬件板 x86_64 - 总是启用文件锁
    local res_x86_64="${RUNNER_RESOURCE_ID_X86_64_PC:-board-x86_64-pc}"
    # 硬件板 visionfive2 - 总是启用文件锁
    local res_visionfive2="${RUNNER_RESOURCE_ID_VISIONFIVE2:-board-visionfive2}"

    # ════════════════════════════════════════════════════════════════
    # 第二步：两种板子 runner 类型的 entrypoint 配置
    # ════════════════════════════════════════════════════════════════
    # 设计说明：若设置了资源 ID（RUNNER_RESOURCE_ID_*），板子 runner 使用
    #   runner-wrapper.sh 来管理文件锁
    # 普通 runner 始终使用 /home/runner/run.sh（不经过 runner-wrapper）
    local runner_entrypoint_phytiumpi="/home/runner/run.sh"
    local runner_entrypoint_roc="/home/runner/run.sh"
    local runner_entrypoint_x86_64="/home/runner/run.sh"
    local runner_entrypoint_visionfive2="/home/runner/run.sh"
    # 若设置了资源 ID，则改用 runner-wrapper 来处理文件锁
    [[ -n "$res_phytiumpi" ]] && runner_entrypoint_phytiumpi="/home/runner/runner-wrapper/runner-wrapper.sh"
    [[ -n "$res_roc" ]] && runner_entrypoint_roc="/home/runner/runner-wrapper/runner-wrapper.sh"
    [[ -n "$res_x86_64" ]] && runner_entrypoint_x86_64="/home/runner/runner-wrapper/runner-wrapper.sh"
    [[ -n "$res_visionfive2" ]] && runner_entrypoint_visionfive2="/home/runner/runner-wrapper/runner-wrapper.sh"

    # ════════════════════════════════════════════════════════════════
    # 第三步：为两种板子 runner 类型准备额外的环境变量数组
    # ════════════════════════════════════════════════════════════════
    # 重复模式说明：以下两部分几乎完全相同，都是：
    #   1. 定义空数组：extra_env_X=()
    #   2. 如果有资源 ID，则添加三个环境变量：
    #      - RUNNER_RESOURCE_ID: 用于锁机制
    #      - RUNNER_SCRIPT: 给 runner-wrapper 使用的脚本路径
    #      - RUNNER_LOCK_DIR: 容器内锁文件目录
    # 原因：两种板子 runner 都可能需要文件锁机制
    local extra_env_phytiumpi=()
    local extra_env_roc=()
    local extra_env_x86_64=()
    local extra_env_visionfive2=()
    local extra_proxy_env=()
    # 只有设置了相应的资源 ID，才为该类型 runner 添加锁相关环境变量
    [[ -n "$res_phytiumpi" ]] && extra_env_phytiumpi=("      RUNNER_RESOURCE_ID: \"$res_phytiumpi\"" "      RUNNER_SCRIPT: \"/home/runner/run.sh\"" "      RUNNER_LOCK_DIR: \"${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}\"")
    [[ -n "$res_roc" ]] && extra_env_roc=("      RUNNER_RESOURCE_ID: \"$res_roc\"" "      RUNNER_SCRIPT: \"/home/runner/run.sh\"" "      RUNNER_LOCK_DIR: \"${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}\"")
    [[ -n "$res_x86_64" ]] && extra_env_x86_64=("      RUNNER_RESOURCE_ID: \"$res_x86_64\"" "      RUNNER_SCRIPT: \"/home/runner/run.sh\"" "      RUNNER_LOCK_DIR: \"${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}\"")
    [[ -n "$res_visionfive2" ]] && extra_env_visionfive2=("      RUNNER_RESOURCE_ID: \"$res_visionfive2\"" "      RUNNER_SCRIPT: \"/home/runner/run.sh\"" "      RUNNER_LOCK_DIR: \"${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}\"")
    [[ -n "${HTTP_PROXY:-}" ]] && extra_proxy_env+=("    HTTP_PROXY: \"${HTTP_PROXY}\"")
    [[ -n "${HTTPS_PROXY:-}" ]] && extra_proxy_env+=("    HTTPS_PROXY: \"${HTTPS_PROXY}\"")
    [[ -n "${NO_PROXY:-}" ]] && extra_proxy_env+=("    NO_PROXY: \"${NO_PROXY}\"")

    # ════════════════════════════════════════════════════════════════
    # 第四步：为两种板子 runner 类型准备卷挂载配置
    # ════════════════════════════════════════════════════════════════
    # 重复模式说明：以下两部分完全相同（除变量名），都实现：
    #   如果设置了资源 ID，则挂载主机的锁文件目录到容器内
    # 原因：文件锁机制需要在主机和容器间共享锁文件
    local extra_vol_phytiumpi=""
    local extra_vol_roc=""
    local extra_vol_x86_64=""
    local extra_vol_visionfive2=""
    # 只有设置了相应的资源 ID，才为该类型 runner 挂载锁文件目录
    [[ -n "$res_phytiumpi" ]] && extra_vol_phytiumpi="      - ${RUNNER_LOCK_HOST_PATH:-/tmp/github-runner-locks}:${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
    [[ -n "$res_roc" ]] && extra_vol_roc="      - ${RUNNER_LOCK_HOST_PATH:-/tmp/github-runner-locks}:${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
    [[ -n "$res_x86_64" ]] && extra_vol_x86_64="      - ${RUNNER_LOCK_HOST_PATH:-/tmp/github-runner-locks}:${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"
    [[ -n "$res_visionfive2" ]] && extra_vol_visionfive2="      - ${RUNNER_LOCK_HOST_PATH:-/tmp/github-runner-locks}:${RUNNER_LOCK_DIR:-/tmp/github-runner-locks}"

    # 使用 printf 输出文件头
    printf '%s\n' \
        "# 自动生成的 Docker Compose 配置" \
        "# 机器名: $(hostname)" \
        "# 普通 runner 数量: $general_count" \
        "# 板子 runner 数量: ${RUNNER_BOARD}" \
        "" \
        "# 基础配置" \
        "x-${RUNNER_NAME_PREFIX}runner-base: &runner_base" \
        "  image: \"${RUNNER_IMAGE}\"" \
        "  restart: unless-stopped" \
        "  environment: &runner_env" \
        "    RUNNER_ORG_URL: \"https://github.com/${ORG}${REPO:+/}${REPO}\"" \
        "    RUNNER_TOKEN: \"${REG_TOKEN}\"" \
        "    RUNNER_GROUP: \"${RUNNER_GROUP}\"" \
        "    RUNNER_REMOVE_ON_STOP: \"false\"" \
        "    DISABLE_AUTO_UPDATE: \"${DISABLE_AUTO_UPDATE}\"" \
        "    RUNNER_WORKDIR: \"${RUNNER_WORKDIR}\"" \
        "${extra_proxy_env[@]}" \
        "  network_mode: host" \
        "  privileged: true" \
        "" \
        "services:" > "${COMPOSE_FILE}"

    # 生成普通 runners
    echo "  # 普通 runners" >> ${COMPOSE_FILE}
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
            "      - 993" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-${i}\"" \
            "      RUNNER_LABELS: \"${RUNNER_LABELS}\"" \
            "    volumes:" \
            "      - ${RUNNER_NAME_PREFIX}runner-${i}-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:/etc/udev/rules.d" \
            "" >> "${COMPOSE_FILE}"
    done

    # 只有当 RUNNER_BOARD 大于 0 时才生成板子 runners
    if [[ "${RUNNER_BOARD}" -gt 0 ]]; then
        # 生成板子 runners
        echo "  # 板子专用 runners" >> "${COMPOSE_FILE}"
        
        # phytiumpi 板子配置
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-phytiumpi:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-phytiumpi\"" \
            "    command:" \
            "      - /bin/bash" \
            "      - -c" \
            "      - |" \
            "        set -e" \
            "        mkdir -p /home/runner/board" \
            "        cd /home/runner/board" \
            "        # 尝试下载文件，如果失败则跳过" \
            "        echo \"Attempting to download phytiumpi files...\"" \
            "        if curl -fsSL --connect-timeout 30 --max-time 300 https://github.com/arceos-hypervisor/axvisor-guest/releases/download/v0.0.18/phytiumpi_linux.tar.gz -o phytiumpi_linux.tar.gz; then" \
            "            echo \"Download successful, extracting...\"" \
            "            tar -xzf phytiumpi_linux.tar.gz" \
            "            echo \"Extraction completed\"" \
            "        else" \
            "            echo \"Download failed, continuing with existing files if any...\"" \
            "        fi" \
            "        ${runner_entrypoint_phytiumpi}" \
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
            "      - 993" \
            "      - dialout" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-phytiumpi\"" \
            "      RUNNER_LABELS: \"phytiumpi\"" \
            "      BOARD_POWER_ON: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB1 1\"" \
            "      BOARD_POWER_OFF: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB1 0\"" \
            "      BOARD_POWER_RESET: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB1 0 && sleep 2 && mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB1 1\"" \
            "      BOARD_DTB: \"/home/runner/board/phytiumpi.dtb\"" \
            "      BOARD_COMM_UART_DEV: \"/dev/ttyUSB0\"" \
            "      BOARD_COMM_UART_BAUD: \"115200\"" \
            "      BOARD_COMM_NET_IFACE: \"eno2np1\"" \
            "      TFTP_DIR: \"phytiumpi\"" \
            "      BIN_DIR: \"/home/runner/test/phytiumpi\"" \
            "${extra_env_phytiumpi[@]}" \
            "    volumes:" \
            "      - /home/$(whoami)/test/phytiumpi:/home/runner/tftp" \
            "$extra_vol_phytiumpi" \
            "      - ./runner-wrapper:/home/runner/runner-wrapper:ro" \
            "      - ${RUNNER_NAME_PREFIX}runner-phytiumpi-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-phytiumpi-udev-rules:/etc/udev/rules.d" \
            "" >> "${COMPOSE_FILE}"
        
        # roc-rk3568-pc 板子配置
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc\"" \
            "    command:" \
            "      - /bin/bash" \
            "      - -c" \
            "      - |" \
            "        set -e" \
            "        mkdir -p /home/runner/board" \
            "        cd /home/runner/board" \
            "        # 尝试下载文件，如果失败则跳过" \
            "        echo \"Attempting to download roc-rk3568-pc files...\"" \
            "        if curl -fsSL --connect-timeout 30 --max-time 300 https://github.com/arceos-hypervisor/axvisor-guest/releases/download/v0.0.18/roc-rk3568-pc_linux.tar.gz -o roc-rk3568-pc_linux.tar.gz; then" \
            "            echo \"Download successful, extracting...\"" \
            "            tar -xzf roc-rk3568-pc_linux.tar.gz" \
            "            echo \"Extraction completed\"" \
            "        else" \
            "            echo \"Download failed, continuing with existing files if any...\"" \
            "        fi" \
            "        ${runner_entrypoint_roc}" \
            "    devices:" \
            "      - /dev/loop-control:/dev/loop-control" \
            "      - /dev/loop0:/dev/loop0" \
            "      - /dev/loop1:/dev/loop1" \
            "      - /dev/loop2:/dev/loop2" \
            "      - /dev/loop3:/dev/loop3" \
            "      - /dev/kvm:/dev/kvm" \
            "      - /dev/ttyUSB2:/dev/ttyUSB2" \
            "      - /dev/ttyUSB3:/dev/ttyUSB3" \
            "    group_add:" \
            "      - 993" \
            "      - dialout" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc\"" \
            "      RUNNER_LABELS: \"roc-rk3568-pc\"" \
            "      BOARD_POWER_ON: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB2 1\"" \
            "      BOARD_POWER_OFF: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB2 0\"" \
            "      BOARD_POWER_RESET: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB2 0 && sleep 2 && mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB2 1\"" \
            "      BOARD_DTB: \"/home/runner/board/roc-rk3568-pc.dtb\"" \
            "      BOARD_COMM_UART_DEV: \"/dev/ttyUSB3\"" \
            "      BOARD_COMM_UART_BAUD: \"1500000\"" \
            "${extra_env_roc[@]}" \
            "    volumes:" \
            "      - ./runner-wrapper:/home/runner/runner-wrapper:ro" \
            "$extra_vol_roc" \
            "      - ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-udev-rules:/etc/udev/rules.d" \
            "" >> "${COMPOSE_FILE}"

        # x86_64 板子配置
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-x86_64-pc:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-x86_64-pc\"" \
            "    command: [\"${runner_entrypoint_x86_64}\"]" \
            "    devices:" \
            "      - /dev/loop-control:/dev/loop-control" \
            "      - /dev/loop0:/dev/loop0" \
            "      - /dev/loop1:/dev/loop1" \
            "      - /dev/loop2:/dev/loop2" \
            "      - /dev/loop3:/dev/loop3" \
            "      - /dev/kvm:/dev/kvm" \
            "      - /dev/ttyUSB4:/dev/ttyUSB4" \
            "      - /dev/ttyUSB5:/dev/ttyUSB5" \
            "    group_add:" \
            "      - 993" \
            "      - dialout" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-x86_64-pc\"" \
            "      RUNNER_LABELS: \"x86_64-pc\"" \
            "      BOARD_POWER_ON: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB4 1\"" \
            "      BOARD_POWER_OFF: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB4 0\"" \
            "      BOARD_POWER_RESET: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB4 0 && sleep 2 && mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB4 1\"" \
            "      BOARD_COMM_UART_DEV: \"/dev/ttyUSB5\"" \
            "      BOARD_COMM_UART_BAUD: \"115200\"" \
            "      BIN_DIR: \"/home/$(whoami)/test/x86_64-pc\"" \
            "${extra_env_x86_64[@]}" \
            "    volumes:" \
            "      - /home/$(whoami)/test/x86_64-pc:/home/runner/tftp" \
            "$extra_vol_x86_64" \
            "      - ./runner-wrapper:/home/runner/runner-wrapper:ro" \
            "      - ${RUNNER_NAME_PREFIX}runner-x86_64-pc-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-x86_64-pc-udev-rules:/etc/udev/rules.d" \
            "" >> "${COMPOSE_FILE}"

        # visionfive2 板子配置
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-visionfive2:" \
            "    <<: *runner_base" \
            "    container_name: \"${RUNNER_NAME_PREFIX}runner-visionfive2\"" \
            "    command:" \
            "      - /bin/bash" \
            "      - -c" \
            "      - |" \
            "        set -e" \
            "        mkdir -p /home/runner/board" \
            "        cd /home/runner/board" \
            "        echo \"Attempting to download visionfive2 files...\"" \
            "        if curl -fsSL --connect-timeout 30 --max-time 300 https://github.com/user-attachments/files/26230373/visionfive2.tar.gz -o visionfive2.tar.gz; then" \
            "            echo \"Download successful, extracting...\"" \
            "            tar -xzf visionfive2.tar.gz" \
            "            echo \"Extraction completed\"" \
            "        else" \
            "            echo \"Download failed, continuing with existing files if any...\"" \
            "        fi" \
            "        ${runner_entrypoint_visionfive2}" \
            "    devices:" \
            "      - /dev/loop-control:/dev/loop-control" \
            "      - /dev/loop0:/dev/loop0" \
            "      - /dev/loop1:/dev/loop1" \
            "      - /dev/loop2:/dev/loop2" \
            "      - /dev/loop3:/dev/loop3" \
            "      - /dev/kvm:/dev/kvm" \
            "      - /dev/ttyUSB6:/dev/ttyUSB6" \
            "      - /dev/ttyUSB7:/dev/ttyUSB7" \
            "    group_add:" \
            "      - 993" \
            "      - dialout" \
            "    environment:" \
            "      <<: *runner_env" \
            "      RUNNER_NAME: \"${RUNNER_NAME_PREFIX}runner-visionfive2\"" \
            "      RUNNER_LABELS: \"visionfive2\"" \
            "      BOARD_POWER_ON: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB7 1\"" \
            "      BOARD_POWER_OFF: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB7 0\"" \
            "      BOARD_POWER_RESET: \"mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB7 0 && sleep 2 && mbpoll -m rtu -a 1 -r 1 -t 0 -b 38400 -P none -v /dev/ttyUSB7 1\"" \
            "      BOARD_DTB: \"/home/runner/board/jh7110-visionfive-v2.dtb\"" \
            "      BOARD_COMM_UART_DEV: \"/dev/ttyUSB6\"" \
            "      BOARD_COMM_UART_BAUD: \"115200\"" \
            "      TFTP_DIR: \"visionfive2\"" \
            "      BIN_DIR: \"/home/runner/test/visionfive2\"" \
            "${extra_env_visionfive2[@]}" \
            "    volumes:" \
            "      - /home/$(whoami)/test/visionfive2:/home/runner/tftp" \
            "$extra_vol_visionfive2" \
            "      - ./runner-wrapper:/home/runner/runner-wrapper:ro" \
            "      - ${RUNNER_NAME_PREFIX}runner-visionfive2-data:/home/runner" \
            "      - ${RUNNER_NAME_PREFIX}runner-visionfive2-udev-rules:/etc/udev/rules.d" \
            "" >> "${COMPOSE_FILE}"
    fi

    # 生成 volumes
    echo "volumes:" >> ${COMPOSE_FILE}
    
    for i in $(seq 1 $general_count); do
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-${i}-data:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-${i}-data" \
            "  ${RUNNER_NAME_PREFIX}runner-${i}-udev-rules:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-${i}-udev-rules" >> "${COMPOSE_FILE}"
    done
    
    # 只有当 RUNNER_BOARD 大于 0 时才生成板子相关的 volumes
    if [[ "${RUNNER_BOARD}" -gt 0 ]]; then
        # 为 phytiumpi 板子生成 volumes
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-phytiumpi-data:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-phytiumpi-data" \
            "  ${RUNNER_NAME_PREFIX}runner-phytiumpi-udev-rules:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-phytiumpi-udev-rules" >> "${COMPOSE_FILE}"
        
        # 为 roc-rk3568-pc 板子生成 volumes
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-data:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-data" \
            "  ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-udev-rules:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-roc-rk3568-pc-udev-rules" >> "${COMPOSE_FILE}"

        # 为 x86_64 板子生成 volumes
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-x86_64-pc-data:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-x86_64-pc-data" \
            "  ${RUNNER_NAME_PREFIX}runner-x86_64-pc-udev-rules:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-x86_64-pc-udev-rules" >> "${COMPOSE_FILE}"

        # 为 visionfive2 板子生成 volumes
        printf '%s\n' \
            "  ${RUNNER_NAME_PREFIX}runner-visionfive2-data:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-visionfive2-data" \
            "  ${RUNNER_NAME_PREFIX}runner-visionfive2-udev-rules:" \
            "    name: ${RUNNER_NAME_PREFIX}runner-visionfive2-udev-rules" >> "${COMPOSE_FILE}"
    fi
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
    
    local cname
    for cname in "${names[@]}"; do
        if ! docker_container_exists "$cname"; then
            shell_warn "Container does not exist: $cname (skipping)"
            continue
        fi
        
        # Check if already configured
        local is_configured=false
        if [[ -f "$COMPOSE_FILE" ]]; then
            if $DC -f "$COMPOSE_FILE" run --rm --no-deps "$cname" bash -lc 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
                is_configured=true
            fi
        else
            if docker exec "$cname" bash -c 'test -f /home/runner/.runner && test -f /home/runner/.credentials' >/dev/null 2>&1; then
                is_configured=true
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
        [[ "${DISABLE_AUTO_UPDATE}" == "1" ]] && cfg_opts+=("--disableupdate")
        
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
    CMD="${1:-help}"; shift || true
    case "$CMD" in
        # ./runner.sh help|-h|--help
        help|-h|--help)
            shell_usage
            ;;

        # ./runner.sh pxe ...
        pxe)
            pxe_main "$@"
            ;;

        # ./runner.sh ps|ls|list|status
        ps|ls|list|status)
            DC=$(docker_pick_compose)
            shell_get_org_and_pat
            echo "--------------------------------- Containers -----------------------------------------"
            docker_print_existing_containers_status
            echo

            echo "--------------------------------- Runners --------------------------------------------"
            resp=$(github_api GET "/actions/runners?per_page=100") || shell_die "Failed to fetch runner list."
            if command -v jq >/dev/null 2>&1; then
                echo "$resp" | jq -r '.runners[] | [.name, .status, (if .busy then "busy" else "idle" end), ( [.labels[].name] | join(","))] | @tsv' \
                    | grep -E "^${RUNNER_NAME_PREFIX}runner-" \
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
            DC=$(docker_pick_compose)
            count=0
            if [[ "${1:-}" == "-n" || "${1:-}" == "--count" ]]; then
                shift
                count="${1:-0}"
                shift || true
            fi
            [[ "$count" =~ ^[0-9]+$ ]] || shell_die "Count must be numeric!"

            REG_TOKEN="$(shell_get_reg_token)"

            RUNNER_IMAGE="$(shell_prepare_runner_image)";

            if [[ "${RUNNER_BOARD}" -gt 0 ]]; then
                shell_info "Generating $COMPOSE_FILE with $count generic runners and ${RUNNER_BOARD} board-specific runners."
            else
                shell_info "Generating $COMPOSE_FILE with $count generic runners."
            fi

            shell_generate_compose_file "$count"

            $DC -f "$COMPOSE_FILE" up -d "$@";

            docker_runner_register
            ;;
        
        # ./runner.sh compose
        compose)
            DC=$(docker_pick_compose)
            cont_count=0
            cont_list="$(docker_list_existing_containers)"
            if [[ -n "$cont_list" ]]; then cont_count=$(echo "$cont_list" | wc -l | tr -d ' '); fi
            
            # 计算通用 runner 的数量
            if [[ "${RUNNER_BOARD}" -gt 0 ]]; then
                # 如果启用了板子 runner，则减去 RUNNER_BOARD 个板子 runner，且不少于 0
                generic_count=$(( cont_count - RUNNER_BOARD ))
                [[ "$generic_count" -lt 0 ]] && generic_count=0
            else
                # 如果没有启用板子 runner，则所有容器都是通用 runner
                generic_count=$cont_count
            fi
            if [[ "${RUNNER_BOARD}" -gt 0 ]]; then
                shell_info "Regenerating $COMPOSE_FILE with ${generic_count} existing runners and ${RUNNER_BOARD} board-specific runners."
            else
                shell_info "Regenerating $COMPOSE_FILE with ${generic_count} existing runners."
            fi
            RUNNER_IMAGE="$(shell_prepare_runner_image)";
            REG_TOKEN="$(shell_get_reg_token)"
            shell_generate_compose_file "$generic_count"
            ;;

        # ./runner.sh register [${RUNNER_NAME_PREFIX}runner-<id> ...]
        register)
            DC=$(docker_pick_compose)
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
            DC=$(docker_pick_compose)
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
            DC=$(docker_pick_compose)
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
            DC=$(docker_pick_compose)
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

        # ./runner.sh log ${RUNNER_NAME_PREFIX}runner-<id>
        log)
            DC=$(docker_pick_compose)
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
            DC=$(docker_pick_compose)
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
                    
                    shell_info "Removing container: $name"
                    if [[ -f "$COMPOSE_FILE" ]]; then
                        # Stop and remove specific container using compose
                        $DC -f "$COMPOSE_FILE" rm -s -f -v "$name" >/dev/null 2>&1 || true
                    else
                        # Stop and remove container using docker
                        docker rm -f "$name" >/dev/null 2>&1 || true
                        # Remove associated volumes
                        docker volume rm "${name}-data" >/dev/null 2>&1 || true
                        docker volume rm "${name}-udev-rules" >/dev/null 2>&1 || true
                    fi
                    shell_info "Removed: $name"
                done
            fi
            ;;

        # ./runner.sh purge [-y|--yes]
        purge)
            DC=$(docker_pick_compose)
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
            DC=$(docker_pick_compose)
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
                new_hash=""
                if command -v sha256sum >/dev/null 2>&1; then
                    new_hash=$(sha256sum Dockerfile | awk '{print $1}')
                elif command -v shasum >/dev/null 2>&1; then
                    new_hash=$(shasum -a 256 Dockerfile | awk '{print $1}')
                fi
                
                if [[ -n "$new_hash" ]]; then
                    echo "$new_hash" > "$DOCKERFILE_HASH_FILE"
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
