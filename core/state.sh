#!/usr/bin/env bash
# =============================================================================
# core/state.sh — Atomic, validated state persistence
# =============================================================================

# Allowed keys and their value patterns (basic whitelist)
declare -rA _STATE_KEYS=(
    [ANONYMITY_ACTIVE]="^(true|false)$"
    [CURRENT_MODE]="^(none|extreme|partial)$"
    [CURRENT_PROFILE]="^[a-zA-Z0-9_-]{1,64}$"
    [MONITORING_PID]="^[0-9]*$"
    [DISTRO_FAMILY]="^(debian|arch|rhel|unknown)$"
    [FIREWALL_BACKEND]="^(iptables|iptables-legacy|nftables|unknown)$"
    [AM_VERSION_SAVED]="^[0-9]+\.[0-9]+$"
)

save_state() {
    local tmp="${AM_STATE_FILE}.tmp"

    # Write to temp file first (atomic)
    cat > "${tmp}" << EOF
ANONYMITY_ACTIVE=${ANONYMITY_ACTIVE}
CURRENT_MODE=${CURRENT_MODE}
CURRENT_PROFILE=${CURRENT_PROFILE}
MONITORING_PID=${MONITORING_PID:-}
DISTRO_FAMILY=${DISTRO_FAMILY}
FIREWALL_BACKEND=${FIREWALL_BACKEND}
AM_VERSION_SAVED=${AM_VERSION}
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "${tmp}"
    mv "${tmp}" "${AM_STATE_FILE}"
    log "INFO" "State saved (mode=${CURRENT_MODE}, active=${ANONYMITY_ACTIVE})"
}

load_state() {
    if [[ ! -f "${AM_STATE_FILE}" ]]; then
        log "INFO" "No state file found — starting fresh"
        return 0
    fi

    if [[ ! -r "${AM_STATE_FILE}" ]]; then
        log "WARN" "State file not readable — ignoring"
        return 0
    fi

    local line key value
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        # Skip comments and blank lines
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]]               && continue

        # Strip surrounding whitespace
        key="${key// /}"
        value="${value// /}"

        # Reject keys not in our whitelist
        if [[ -z "${_STATE_KEYS[${key}]+x}" ]]; then
            log "WARN" "state.sh: ignoring unknown key '${key}'"
            continue
        fi

        # Validate value against allowed pattern
        local pattern="${_STATE_KEYS[${key}]}"
        if [[ ! "${value}" =~ ${pattern} ]]; then
            log "WARN" "state.sh: invalid value '${value}' for key '${key}' — ignoring"
            continue
        fi

        # Safe to assign
        declare -g "${key}"="${value}"

    done < "${AM_STATE_FILE}"

    log "INFO" "State loaded (mode=${CURRENT_MODE:-none}, active=${ANONYMITY_ACTIVE:-false})"
}

clear_state() {
    ANONYMITY_ACTIVE="false"
    CURRENT_MODE="none"
    CURRENT_PROFILE="default"
    MONITORING_PID=""
    save_state
}
