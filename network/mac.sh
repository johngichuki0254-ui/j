#!/usr/bin/env bash
# =============================================================================
# network/mac.sh — MAC address randomization with clean restoration
#
# Supports:
#   - random       : fully random MAC (default)
#   - apple        : random MAC with Apple OUI prefix  (00:17:f2, ...)
#   - samsung      : random MAC with Samsung OUI prefix
#   - dell         : random MAC with Dell OUI prefix
#   - lenovo       : random MAC with Lenovo OUI prefix
#   - preserve     : don't change MAC
#
# Vendor preference is read from user_prefs and saved after each spoof.
# Uses NM connection clone (preferred) or manual ip link (fallback).
# =============================================================================

readonly _MAC_STATE_FILE="${AM_CONFIG_DIR}/mac_state"

# Vendor OUI prefixes (first 3 octets)
declare -grA _MAC_VENDORS=(
    [apple]="00:17:f2"
    [apple2]="ac:de:48"
    [apple3]="a8:66:7f"
    [samsung]="8c:77:12"
    [samsung2]="44:a7:cf"
    [dell]="f8:db:88"
    [dell2]="18:db:f2"
    [lenovo]="54:ee:75"
    [lenovo2]="98:fa:9b"
)

# Vendor aliases used externally → canonical vendor group name
declare -grA _MAC_VENDOR_GROUPS=(
    [apple]="apple"   [samsung]="samsung"
    [dell]="dell"     [lenovo]="lenovo"
    [random]="random" [preserve]="preserve"
)

mac_spoof() {
    local iface="${1}"
    local vendor="${2:-}"   # optional: apple, samsung, dell, lenovo, random, preserve

    # If no vendor given, check prefs
    if [[ -z "${vendor}" ]]; then
        vendor="$(prefs_get last_mac_vendor 2>/dev/null || echo "random")"
        [[ -z "${vendor}" ]] && vendor="random"
    fi

    # "preserve" means user explicitly wants no MAC change
    if [[ "${vendor}" == "preserve" ]]; then
        log "INFO" "MAC: preserve mode — no change"
        prefs_save "last_mac_vendor" "preserve" 2>/dev/null || true
        return 0
    fi

    log "INFO" "MAC randomization for interface: ${iface} (vendor: ${vendor})"

    local original_mac
    original_mac="$(ip link show "${iface}" 2>/dev/null \
        | awk '/link\/ether/ {print $2}')"

    # Method 1: NetworkManager clone
    if _mac_spoof_nm "${iface}" "${original_mac}" "${vendor}"; then
        prefs_save "last_mac_vendor" "${vendor}" "last_interface" "${iface}" 2>/dev/null || true
        return 0
    fi

    # Method 2: ip link direct + optional vendor prefix
    if _mac_spoof_direct "${iface}" "${original_mac}" "${vendor}"; then
        prefs_save "last_mac_vendor" "${vendor}" "last_interface" "${iface}" 2>/dev/null || true
        return 0
    fi

    # Method 3: macchanger fallback (no vendor control)
    if command -v macchanger >/dev/null 2>&1; then
        _mac_spoof_macchanger "${iface}" "${original_mac}"
        prefs_save "last_mac_vendor" "random" "last_interface" "${iface}" 2>/dev/null || true
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

    # Safe parse — no source
    local method="" temp_name="" orig_uuid="" iface="" original_mac=""
    while IFS='=' read -r k v || [[ -n "${k}" ]]; do
        [[ "${k}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${k}" ]] && continue
        k="${k// /}"; v="${v// /}"
        # Strict whitelist
        case "${k}" in
            method)        method="${v//[^a-z_]/}"          ;;
            temp_name)     temp_name="${v//[^a-zA-Z0-9_-]/}" ;;
            orig_uuid)     orig_uuid="${v//[^a-zA-Z0-9_-]/}" ;;
            iface)         iface="${v//[^a-zA-Z0-9_-]/}"     ;;
            original_mac)  original_mac="${v//[^0-9a-fA-F:]/}" ;;
        esac
    done < "${_MAC_STATE_FILE}"

    case "${method}" in
        nm)
            [[ -n "${temp_name}" ]] && {
                nmcli connection down   "${temp_name}" 2>/dev/null || true
                nmcli connection delete "${temp_name}" 2>/dev/null || true
            }
            [[ -n "${orig_uuid}" ]] && \
                nmcli connection up "${orig_uuid}" 2>/dev/null || \
                    log "WARN" "Failed to re-activate original NM connection"
            ;;
        direct|macchanger)
            if [[ -n "${iface}" && -n "${original_mac}" ]]; then
                ip link set "${iface}" down  2>/dev/null || true
                ip link set "${iface}" address "${original_mac}" 2>/dev/null || \
                    log "WARN" "Failed to restore MAC"
                ip link set "${iface}" up    2>/dev/null || true
            fi
            ;;
    esac

    rm -f "${_MAC_STATE_FILE}"
    security_log "MAC" "MAC address configuration restored"
}

# =============================================================================
# GENERATE A VENDOR-PREFIXED RANDOM MAC
# =============================================================================

_mac_generate() {
    local vendor="${1:-random}"
    local prefix=""

    case "${vendor}" in
        apple)   prefix="${_MAC_VENDORS[apple]}"   ;;
        samsung) prefix="${_MAC_VENDORS[samsung]}"  ;;
        dell)    prefix="${_MAC_VENDORS[dell]}"     ;;
        lenovo)  prefix="${_MAC_VENDORS[lenovo]}"   ;;
        *)       prefix="" ;;  # fully random
    esac

    # Generate 3 random octets for host portion
    local suffix
    suffix=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null \
        | tr -d ' \n' \
        | sed 's/../&:/g;s/:$//' \
        || printf '%02x:%02x:%02x' \
            $(( RANDOM % 256 )) $(( RANDOM % 256 )) $(( RANDOM % 256 )) )

    if [[ -n "${prefix}" ]]; then
        # vendor prefix (3 octets) + random suffix (3 octets) = full 6-octet MAC
        echo "${prefix}:${suffix}"
    else
        # Fully random 6 octets with locally-administered + unicast bits enforced
        local full6
        full6=$(od -An -N6 -tx1 /dev/urandom 2>/dev/null \
            | tr -d ' \n' \
            | sed 's/../&:/g;s/:$//' \
            || printf '%02x:%02x:%02x:%02x:%02x:%02x' \
                $(( RANDOM % 256 )) $(( RANDOM % 256 )) $(( RANDOM % 256 )) \
                $(( RANDOM % 256 )) $(( RANDOM % 256 )) $(( RANDOM % 256 )) )
        local first_octet
        first_octet=$(printf '%02x' $(( (0x${full6:0:2} & 0xfe) | 0x02 )))
        echo "${first_octet}:${full6:3}"
    fi
}

# =============================================================================
# SPOOF METHODS
# =============================================================================

_mac_spoof_nm() {
    local iface="${1}" original_mac="${2}" vendor="${3:-random}"

    command -v nmcli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet NetworkManager 2>/dev/null || return 1

    local orig_uuid
    orig_uuid="$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
        | grep ":${iface}$" | cut -d: -f1 | head -1)"
    [[ -z "${orig_uuid}" ]] && return 1

    local temp_name="AM_MAC_$$"
    nmcli connection clone "${orig_uuid}" "${temp_name}" >/dev/null 2>&1 || return 1

    local new_mac
    new_mac="$(_mac_generate "${vendor}")"

    nmcli connection modify "${temp_name}" \
        ethernet.cloned-mac-address        "${new_mac}" 2>/dev/null || true
    nmcli connection modify "${temp_name}" \
        802-11-wireless.cloned-mac-address "${new_mac}" 2>/dev/null || true

    if ! nmcli connection up "${temp_name}" >/dev/null 2>&1; then
        nmcli connection delete "${temp_name}" 2>/dev/null || true
        return 1
    fi

    printf 'method=nm\ntemp_name=%s\norig_uuid=%s\niface=%s\noriginal_mac=%s\n' \
        "${temp_name}" "${orig_uuid}" "${iface}" "${original_mac}" \
        > "${_MAC_STATE_FILE}"
    chmod 600 "${_MAC_STATE_FILE}"

    local confirmed_mac
    confirmed_mac="$(ip link show "${iface}" 2>/dev/null | awk '/link\/ether/ {print $2}')"
    log "INFO" "MAC changed: ${original_mac} → ${confirmed_mac} (vendor: ${vendor}, NM)"
    security_log "MAC" "MAC randomized via NM on ${iface}: ${confirmed_mac}"
    return 0
}

_mac_spoof_direct() {
    local iface="${1}" original_mac="${2}" vendor="${3:-random}"

    local new_mac
    new_mac="$(_mac_generate "${vendor}")"

    ip link set "${iface}" down 2>/dev/null || return 1
    ip link set "${iface}" address "${new_mac}" 2>/dev/null || {
        ip link set "${iface}" up 2>/dev/null || true
        return 1
    }
    ip link set "${iface}" up 2>/dev/null || true

    printf 'method=direct\niface=%s\noriginal_mac=%s\n' \
        "${iface}" "${original_mac}" \
        > "${_MAC_STATE_FILE}"
    chmod 600 "${_MAC_STATE_FILE}"

    local confirmed_mac
    confirmed_mac="$(ip link show "${iface}" 2>/dev/null | awk '/link\/ether/ {print $2}')"
    log "INFO" "MAC changed: ${original_mac} → ${confirmed_mac} (vendor: ${vendor}, direct)"
    security_log "MAC" "MAC randomized via ip-link on ${iface}: ${confirmed_mac}"
    return 0
}

_mac_spoof_macchanger() {
    local iface="${1}" original_mac="${2}"

    ip link set "${iface}" down
    macchanger -r "${iface}" >/dev/null 2>&1 || {
        ip link set "${iface}" up
        return 1
    }
    ip link set "${iface}" up

    printf 'method=macchanger\niface=%s\noriginal_mac=%s\n' \
        "${iface}" "${original_mac}" \
        > "${_MAC_STATE_FILE}"
    chmod 600 "${_MAC_STATE_FILE}"

    local new_mac
    new_mac="$(ip link show "${iface}" 2>/dev/null | awk '/link\/ether/ {print $2}')"
    log "INFO" "MAC changed: ${original_mac} → ${new_mac} (macchanger)"
    security_log "MAC" "MAC randomized via macchanger on ${iface}: ${new_mac}"
    return 0
}


