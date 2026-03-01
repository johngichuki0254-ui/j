#!/usr/bin/env bash
# =============================================================================
# system/prefs.sh — User preferences persistence across sessions
#
# Survives disable/restore cycles. Stores the user's last-used choices
# so the wizard can pre-fill them on next run.
#
# SECURITY: file is NEVER sourced or eval'd. Values are read with grep/cut
# and validated against a strict whitelist before use.
#
# Stored preferences:
#   last_location   — e.g. "us_ny", "fr", "in_mh"
#   last_persona    — e.g. "macos_safari", "windows_chrome"
#   last_mac_vendor — e.g. "apple", "dell", "random"
#   last_interface  — e.g. "eth0", "wlan0"
#   wizard_skip     — "true"/"false" — skip wizard on enable if prefs exist
# =============================================================================

# Allowed preference keys and their validation patterns
declare -grA _PREF_PATTERNS=(
    [last_location]="^[a-z]{2}(_[a-z]{2,4})?$"
    [last_persona]="^(macos_safari|macos_chrome|windows_chrome|windows_edge|ubuntu_firefox|iphone_safari|android_chrome|none)$"
    [last_mac_vendor]="^(apple|samsung|dell|lenovo|random|preserve)$"
    [last_interface]="^[a-zA-Z0-9_-]{1,16}$"
    [wizard_skip]="^(true|false)$"
)

# In-memory prefs cache (populated by prefs_load)
declare -gA _PREFS_CACHE=()

# =============================================================================
# PUBLIC API
# =============================================================================

# Load prefs from disk into _PREFS_CACHE
# Safe parse: no source, no eval, strict whitelist
prefs_load() {
    _PREFS_CACHE=()
    [[ -f "${AM_PREFS_FILE}" ]] || return 0
    [[ -r "${AM_PREFS_FILE}" ]] || return 0

    local key value
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]] && continue

        # Strip whitespace — character class only, no subshell
        key="${key// /}"
        value="${value// /}"

        # Whitelist check
        [[ -z "${_PREF_PATTERNS[${key}]+x}" ]] && continue

        # Pattern validation
        local pat="${_PREF_PATTERNS[${key}]}"
        [[ "${value}" =~ ${pat} ]] || continue

        _PREFS_CACHE["${key}"]="${value}"
    done < "${AM_PREFS_FILE}"

    log "INFO" "User preferences loaded (${#_PREFS_CACHE[@]} keys)"
}

# Save one or more key=value pairs to prefs file
# Usage: prefs_save key value [key value ...]
prefs_save() {
    # Merge new values into cache first
    while [[ $# -ge 2 ]]; do
        local k="${1}" v="${2}"; shift 2

        # Validate key is allowed
        [[ -z "${_PREF_PATTERNS[${k}]+x}" ]] && {
            log "WARN" "prefs_save: unknown key '${k}' — ignored"
            continue
        }
        # Validate value matches pattern
        local pat="${_PREF_PATTERNS[${k}]}"
        [[ "${v}" =~ ${pat} ]] || {
            log "WARN" "prefs_save: invalid value '${v}' for key '${k}' — ignored"
            continue
        }
        _PREFS_CACHE["${k}"]="${v}"
    done

    # Write full cache atomically
    local tmp="${AM_PREFS_FILE}.tmp"
    {
        echo "# AnonManager user preferences — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# This file persists across sessions. Edit with care."
        for k in "${!_PREFS_CACHE[@]}"; do
            printf '%s=%s\n' "${k}" "${_PREFS_CACHE[${k}]}"
        done
    } > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${AM_PREFS_FILE}"

    log "INFO" "User preferences saved"
}

# Get a preference value. Returns empty string if not set.
# Usage: val=$(prefs_get last_location)
prefs_get() {
    local key="${1:-}"
    [[ -z "${key}" ]] && return 0
    echo "${_PREFS_CACHE[${key}]:-}"
}

# Check if any preferences exist
prefs_exist() {
    [[ ${#_PREFS_CACHE[@]} -gt 0 ]]
}

# Print a human-readable summary of current preferences
prefs_summary() {
    if [[ ${#_PREFS_CACHE[@]} -eq 0 ]]; then
        echo "  No saved preferences"
        return
    fi

    local loc persona vendor iface
    loc="$(prefs_get last_location)"
    persona="$(prefs_get last_persona)"
    vendor="$(prefs_get last_mac_vendor)"
    iface="$(prefs_get last_interface)"

    [[ -n "${loc}" ]]     && echo "  Last location:    ${loc} ($(_country_display_name "${loc}" 2>/dev/null || echo "${loc}"))"
    [[ -n "${persona}" ]] && echo "  Last persona:     ${persona}"
    [[ -n "${vendor}" ]]  && echo "  Last MAC vendor:  ${vendor}"
    [[ -n "${iface}" ]]   && echo "  Last interface:   ${iface}"
}

# Clear all preferences
prefs_clear() {
    _PREFS_CACHE=()
    rm -f "${AM_PREFS_FILE}"
    log "INFO" "User preferences cleared"
}
