#!/usr/bin/env bash
# =============================================================================
# network/mac.sh — MAC address randomization with clean restoration
# Uses NM connection clone (preferred) or macchanger (fallback).
# Stores the temp connection name so restore is deterministic.
# =============================================================================

readonly _MAC_STATE_FILE="${AM_CONFIG_DIR}/mac_state"

mac_spoof() {
    local iface="${1}"
    log "INFO" "MAC randomization for interface: ${iface}"

    local original_mac
    original_mac="$(ip link show "${iface}" 2>/dev/null \
        | awk '/link\/ether/ {print $2}')"

    # Method 1: NetworkManager clone
    if _mac_spoof_nm "${iface}" "${original_mac}"; then
        return 0
    fi

    # Method 2: macchanger fallback
    if command -v macchanger >/dev/null 2>&1; then
        _mac_spoof_macchanger "${iface}" "${original_mac}"
        return $?
    fi

    log "WARN" "MAC spoofing unavailable — no supported method found"
    return 1
}

mac_restore() {
    log "INFO" "Restoring original MAC configuration"

    if [[ ! -f "${_MAC_STATE_FILE}" ]]; then
        log "INFO" "No MAC state file — nothing to restore"
        return 0
    fi

    local method temp_name orig_uuid iface original_mac
    # shellcheck source=/dev/null
    source "${_MAC_STATE_FILE}" 2>/dev/null || true

    case "${method:-}" in
        nm)
            if [[ -n "${temp_name:-}" ]]; then
                nmcli connection down "${temp_name}" 2>/dev/null || true
                nmcli connection delete "${temp_name}" 2>/dev/null || true
            fi
            if [[ -n "${orig_uuid:-}" ]]; then
                nmcli connection up "${orig_uuid}" 2>/dev/null || \
                    log "WARN" "Failed to re-activate original NM connection"
            fi
            ;;
        macchanger)
            if [[ -n "${iface:-}" && -n "${original_mac:-}" ]]; then
                ip link set "${iface}" down 2>/dev/null || true
                ip link set "${iface}" address "${original_mac}" 2>/dev/null || \
                    log "WARN" "Failed to restore MAC address"
                ip link set "${iface}" up 2>/dev/null || true
            fi
            ;;
    esac

    rm -f "${_MAC_STATE_FILE}"
    security_log "MAC" "MAC address configuration restored"
}

_mac_spoof_nm() {
    local iface="${1}" original_mac="${2}"

    if ! command -v nmcli >/dev/null 2>&1; then return 1; fi
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then return 1; fi

    local orig_uuid
    orig_uuid="$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
        | grep ":${iface}$" | cut -d: -f1 | head -1 || echo '')"
    [[ -z "${orig_uuid}" ]] && return 1

    local temp_name="AM_MAC_$$"

    if ! nmcli connection clone "${orig_uuid}" "${temp_name}" >/dev/null 2>&1; then
        return 1
    fi

    # Set random MAC for both ethernet and wifi profiles
    nmcli connection modify "${temp_name}" \
        ethernet.cloned-mac-address random 2>/dev/null || true
    nmcli connection modify "${temp_name}" \
        802-11-wireless.cloned-mac-address random 2>/dev/null || true

    if ! nmcli connection up "${temp_name}" >/dev/null 2>&1; then
        # Clean up the clone — don't leave it orphaned
        nmcli connection delete "${temp_name}" 2>/dev/null || true
        return 1
    fi

    # Save state for restore
    cat > "${_MAC_STATE_FILE}" << EOF
method=nm
temp_name=${temp_name}
orig_uuid=${orig_uuid}
iface=${iface}
original_mac=${original_mac}
EOF
    chmod 600 "${_MAC_STATE_FILE}"

    local new_mac
    new_mac="$(ip link show "${iface}" 2>/dev/null | awk '/link\/ether/ {print $2}')"
    log "INFO" "MAC changed: ${original_mac} → ${new_mac}"
    security_log "MAC" "MAC randomized via NetworkManager on ${iface}"
    return 0
}

_mac_spoof_macchanger() {
    local iface="${1}" original_mac="${2}"

    ip link set "${iface}" down
    if ! macchanger -r "${iface}" >/dev/null 2>&1; then
        ip link set "${iface}" up
        return 1
    fi
    ip link set "${iface}" up

    cat > "${_MAC_STATE_FILE}" << EOF
method=macchanger
iface=${iface}
original_mac=${original_mac}
EOF
    chmod 600 "${_MAC_STATE_FILE}"

    local new_mac
    new_mac="$(ip link show "${iface}" 2>/dev/null | awk '/link\/ether/ {print $2}')"
    log "INFO" "MAC changed: ${original_mac} → ${new_mac} (macchanger)"
    security_log "MAC" "MAC randomized via macchanger on ${iface}"
    return 0
}
