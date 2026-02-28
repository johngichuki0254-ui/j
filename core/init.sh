#!/usr/bin/env bash
# =============================================================================
# core/init.sh — Bootstrap, root enforcement, locking, logging, globals
# Sourced first. All globals defined here. set -euo pipefail already active.
# =============================================================================

# =============================================================================
# IMMUTABLE CONFIGURATION CONSTANTS
# =============================================================================
readonly AM_CONFIG_DIR="/etc/anonmanager"
readonly AM_BACKUP_DIR="${AM_CONFIG_DIR}/backups"
readonly AM_PROFILES_DIR="${AM_CONFIG_DIR}/profiles"
readonly AM_LOG_FILE="/var/log/anonmanager.log"
readonly AM_SECURITY_LOG="/var/log/anonmanager-security.log"
readonly AM_STATE_FILE="${AM_CONFIG_DIR}/state"
readonly AM_LOCK_FILE="/var/run/anonmanager.lock"
readonly AM_MODULE_DIR="${AM_CONFIG_DIR}/modules"

# Tor network ports
readonly TOR_SOCKS_PORT="9050"
readonly TOR_CONTROL_PORT="9051"
readonly TOR_DNS_PORT="5353"
readonly TOR_TRANS_PORT="9040"
readonly TOR_PID_FILE="/var/run/anonmanager-tor.pid"

# Namespace / veth topology (Whonix-style)
readonly NS_NAME="anonspace"
readonly NS_VETH_HOST="veth_host"
readonly NS_VETH_TOR="veth_tor"
readonly NS_TOR_IP="10.200.1.1"      # Tor binds here (inside namespace)
readonly NS_HOST_IP="10.200.1.2"     # Host veth endpoint
readonly NS_SUBNET="10.200.1.0/24"

# Terminal colours (safe for non-interactive too — guarded by is_interactive())
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Unicode symbols
readonly SYM_CHECK="✓"
readonly SYM_CROSS="✗"
readonly SYM_ARROW="→"
readonly SYM_WARN="⚠"
readonly SYM_LOCK="🔒"
readonly SYM_UNLOCK="🔓"
readonly SYM_SHIELD="🛡"

# =============================================================================
# MUTABLE RUNTIME STATE  (declare -g so sourced modules can update them)
# =============================================================================
declare -g ANONYMITY_ACTIVE="false"
declare -g CURRENT_MODE="none"
declare -g CURRENT_PROFILE="default"
declare -g MONITORING_PID=""
declare -g TOR_USER=""          # Resolved at init time, NOT hardcoded
declare -g TOR_DATA_DIR=""
declare -g DISTRO_FAMILY=""
declare -g PKG_MANAGER=""
declare -g FIREWALL_BACKEND=""

# =============================================================================
# LOGGING
# =============================================================================

# Writes to log file AND stderr (stderr only for WARN/ERROR/FATAL)
log() {
    local level="${1}"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "${msg}" >> "${AM_LOG_FILE}" 2>/dev/null || true
    case "${level}" in
        WARN|ERROR|FATAL) echo "${msg}" >&2 ;;
    esac
}

security_log() {
    local event="${1}"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SECURITY] [${event}] $*"
    echo "${msg}" >> "${AM_SECURITY_LOG}" 2>/dev/null || true
    echo "${msg}" >> "${AM_LOG_FILE}"     2>/dev/null || true
    log "SECURITY" "[${event}] $*"
}

# =============================================================================
# TERMINAL DETECTION
# =============================================================================

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# =============================================================================
# ROOT ENFORCEMENT — must be called before any file I/O
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[FATAL] This script must be run as root.${NC}" >&2
        echo -e "${YELLOW}  Try: sudo $(basename "${BASH_SOURCE[-1]}")${NC}" >&2
        exit 1
    fi
}

# =============================================================================
# PROCESS LOCK — prevents concurrent instances
# =============================================================================

acquire_lock() {
    if [[ -f "${AM_LOCK_FILE}" ]]; then
        local existing_pid
        existing_pid=$(cat "${AM_LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            echo -e "${RED}[FATAL] Another instance is already running (PID: ${existing_pid}).${NC}" >&2
            exit 1
        fi
        # Stale lock
        rm -f "${AM_LOCK_FILE}"
    fi
    echo "$$" > "${AM_LOCK_FILE}"
    chmod 600 "${AM_LOCK_FILE}"
}

release_lock() {
    rm -f "${AM_LOCK_FILE}"
}

# =============================================================================
# TRAP / CLEANUP
# =============================================================================

_cleanup_on_exit() {
    local exit_code=$?
    release_lock
    stop_monitoring 2>/dev/null || true
    if [[ ${exit_code} -ne 0 ]]; then
        log "ERROR" "Script exited with code ${exit_code} — attempting emergency restore"
        emergency_restore 2>/dev/null || true
    fi
}

_cleanup_on_signal() {
    echo -e "\n${YELLOW}${SYM_WARN} Interrupted — restoring system to safe state...${NC}" >&2
    log "WARN" "Script interrupted by signal"
    stop_monitoring  2>/dev/null || true
    emergency_restore 2>/dev/null || true
    release_lock
    exit 130
}

trap '_cleanup_on_exit'   EXIT
trap '_cleanup_on_signal' INT TERM HUP

# =============================================================================
# INITIALIZATION
# =============================================================================

initialize() {
    # Create config directories with tight permissions
    mkdir -p "${AM_CONFIG_DIR}" "${AM_BACKUP_DIR}" "${AM_PROFILES_DIR}" "${AM_MODULE_DIR}"
    chmod 700 "${AM_CONFIG_DIR}" "${AM_BACKUP_DIR}" "${AM_PROFILES_DIR}" "${AM_MODULE_DIR}"

    # Touch log files so they exist before first write
    touch "${AM_LOG_FILE}" "${AM_SECURITY_LOG}"
    chmod 600 "${AM_LOG_FILE}" "${AM_SECURITY_LOG}"

    # Resolve Tor user for this distro (never hardcoded)
    TOR_USER="$(detect_tor_user)"
    TOR_DATA_DIR="$(detect_tor_data_dir)"

    log "INFO" "=========================================="
    log "INFO" "AnonManager v${AM_VERSION} started (PID: $$)"
    log "INFO" "Tor user: ${TOR_USER}  Data dir: ${TOR_DATA_DIR}"
}

# =============================================================================
# TOR USER / DATA DIR DETECTION
# =============================================================================

detect_tor_user() {
    local candidates=("debian-tor" "_tor" "tor")
    for u in "${candidates[@]}"; do
        if id -u "${u}" >/dev/null 2>&1; then
            echo "${u}"
            return 0
        fi
    done
    # Fallback: create a dedicated user if none found (package not yet installed)
    echo "debian-tor"
}

detect_tor_data_dir() {
    # Prefer what tor itself reports; fall back to distro convention
    local candidates=("/var/lib/tor" "/var/lib/tor-instance-default")
    for d in "${candidates[@]}"; do
        if [[ -d "${d}" ]]; then
            echo "${d}"
            return 0
        fi
    done
    echo "/var/lib/tor"
}

# =============================================================================
# ARGUMENT PARSER
# =============================================================================

parse_arguments() {
    case "${1:-}" in
        --extreme)  enable_extreme_anonymity; exit 0 ;;
        --partial)  enable_partial_anonymity; exit 0 ;;
        --disable)  disable_anonymity;        exit 0 ;;
        --status)   show_status_dashboard;    exit 0 ;;
        --verify)   verify_anonymity_comprehensive; exit 0 ;;
        --newid)    get_new_tor_identity;     exit 0 ;;
        --restore)  emergency_restore; echo -e "${GREEN}Restore complete${NC}"; exit 0 ;;
        --logs)     view_logs;                exit 0 ;;
        --help|-h)  show_help;                exit 0 ;;
        "")         return 0 ;;
        *)
            echo -e "${RED}Unknown option: ${1}${NC}" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
}
