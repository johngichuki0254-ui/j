#!/usr/bin/env bash
# =============================================================================
# tor/bridges.sh — Pluggable transport bridge management
#
# Supports: obfs4, meek-azure, snowflake, vanilla (direct bridges)
#
# Bridge lines are stored in /etc/anonmanager/bridges (chmod 600).
# This file is SEPARATE from torrc — we write it into torrc only when
# bridges are enabled. On disable, we remove bridge lines from torrc.
#
# Bridge line format (same as Tor spec):
#   obfs4 <ip:port> <fingerprint> cert=<cert> iat-mode=0
#   meek_lite 0.0.2.0:1 <fingerprint> url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com
#   snowflake 192.0.2.3:1 <fingerprint> fingerprint=<fp> url=https://...
#
# Public API:
#   bridges_enable              — write bridge config to torrc, reload Tor
#   bridges_disable             — remove bridge config from torrc, reload Tor
#   bridges_are_enabled         — check current state
#   bridges_list                — show stored bridges
#   bridges_add <line>          — add one bridge line
#   bridges_remove <index>      — remove bridge by line number
#   bridges_clear               — remove all bridges
#   bridges_test [transport]    — test connectivity through bridges
# =============================================================================

bridges_enable() {
    if ! bridges_have_any; then
        echo -e "  ${YELLOW}${SYM_WARN} No bridges configured. Use the bridge wizard to add bridges.${NC}"
        return 1
    fi

    log "INFO" "Enabling Tor bridges"

    # Append bridge config block to torrc
    _bridges_write_to_torrc

    # Persist preference
    prefs_save "bridges_enabled" "true" 2>/dev/null || true

    # Reload Tor to pick up new config
    if tor_is_running 2>/dev/null; then
        echo -e "  ${CYAN}Reloading Tor with bridge configuration...${NC}"
        kill -HUP "$(cat "${TOR_PID_FILE}" 2>/dev/null)" 2>/dev/null || true
        sleep 3
        if tor_wait_for_bootstrap 60 2>/dev/null; then
            echo -e "  ${GREEN}${SYM_CHECK} Tor reconnected via bridges${NC}"
        else
            echo -e "  ${YELLOW}${SYM_WARN} Bridge connection is taking longer than usual — this is normal for obfs4/meek${NC}"
        fi
    fi

    security_log "BRIDGES" "Bridges enabled"
}

bridges_disable() {
    log "INFO" "Disabling Tor bridges"

    _bridges_remove_from_torrc

    prefs_save "bridges_enabled" "false" 2>/dev/null || true

    if tor_is_running 2>/dev/null; then
        kill -HUP "$(cat "${TOR_PID_FILE}" 2>/dev/null)" 2>/dev/null || true
        sleep 2
    fi

    echo -e "  ${GREEN}${SYM_CHECK} Bridges disabled — Tor using direct connection${NC}"
    security_log "BRIDGES" "Bridges disabled"
}

bridges_are_enabled() {
    grep -q '^UseBridges 1' /etc/tor/torrc 2>/dev/null
}

bridges_have_any() {
    [[ -f "${AM_BRIDGES_FILE}" ]] && \
        grep -qvE '^[[:space:]]*#|^[[:space:]]*$' "${AM_BRIDGES_FILE}" 2>/dev/null
}

bridges_list() {
    if [[ ! -f "${AM_BRIDGES_FILE}" ]] || ! bridges_have_any; then
        echo -e "  ${DIM}No bridges configured.${NC}"
        return 0
    fi

    echo -e "  ${BOLD}Configured bridges:${NC}"
    local i=0
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        ((i++)) || true
        local transport
        transport="$(echo "${line}" | awk '{print $1}')"
        local addr
        addr="$(echo "${line}" | awk '{print $2}')"
        printf "  %2d) ${CYAN}%-12s${NC} %s\n" "${i}" "${transport}" "${addr}"
    done < "${AM_BRIDGES_FILE}"
}

bridges_add() {
    local bridge_line="${1:-}"
    [[ -z "${bridge_line}" ]] && return 1

    # Validate — basic sanity check on bridge line format
    if ! _bridges_validate_line "${bridge_line}"; then
        echo -e "  ${RED}${SYM_CROSS} Invalid bridge line format${NC}"
        echo -e "  ${DIM}Expected: <transport> <ip:port> <fingerprint> [options]${NC}"
        return 1
    fi

    # Sanitize — strip control characters
    bridge_line="$(echo "${bridge_line}" | tr -cd '[:print:]' | head -c 512)"

    mkdir -p "$(dirname "${AM_BRIDGES_FILE}")"
    echo "${bridge_line}" >> "${AM_BRIDGES_FILE}"
    chmod 600 "${AM_BRIDGES_FILE}"

    echo -e "  ${GREEN}${SYM_CHECK} Bridge added${NC}"
    log "INFO" "Bridge added: $(echo "${bridge_line}" | awk '{print $1, $2}')"
    security_log "BRIDGES" "Bridge added: $(echo "${bridge_line}" | awk '{print $1, $2}')"
}

bridges_remove() {
    local index="${1:-}"
    index="${index//[^0-9]/}"
    [[ -z "${index}" ]] && return 1
    [[ ! -f "${AM_BRIDGES_FILE}" ]] && return 1

    # Count non-comment, non-empty lines to find correct line number
    local actual_line=0 i=0
    while IFS= read -r line; do
        ((actual_line++)) || true
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        ((i++)) || true
        if [[ "${i}" -eq "${index}" ]]; then
            sed -i "${actual_line}d" "${AM_BRIDGES_FILE}"
            echo -e "  ${GREEN}${SYM_CHECK} Bridge ${index} removed${NC}"
            return 0
        fi
    done < "${AM_BRIDGES_FILE}"

    echo -e "  ${RED}${SYM_CROSS} Bridge ${index} not found${NC}"
    return 1
}

bridges_clear() {
    if [[ -f "${AM_BRIDGES_FILE}" ]]; then
        rm -f "${AM_BRIDGES_FILE}"
        echo -e "  ${GREEN}${SYM_CHECK} All bridges cleared${NC}"
        log "INFO" "All bridges cleared"
    fi
}

bridges_test() {
    local transport="${1:-}"
    echo -e "\n  ${CYAN}Testing bridge connectivity...${NC}"

    if ! bridges_have_any; then
        echo -e "  ${RED}${SYM_CROSS} No bridges to test${NC}"
        return 1
    fi

    if ! bridges_are_enabled; then
        echo -e "  ${YELLOW}${SYM_WARN} Bridges not currently enabled in torrc${NC}"
        echo -e "  ${DIM}(Testing what would happen if you enabled them)${NC}"
    fi

    # Test reachability of first bridge IP
    local first_bridge
    first_bridge="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${AM_BRIDGES_FILE}" \
        2>/dev/null | head -1)"
    local bridge_addr
    bridge_addr="$(echo "${first_bridge}" | awk '{print $2}' | cut -d: -f1)"
    local bridge_port
    bridge_port="$(echo "${first_bridge}" | awk '{print $2}' | cut -d: -f2)"

    if [[ -n "${bridge_addr}" && -n "${bridge_port}" ]]; then
        printf "  Testing TCP reach to %s:%s... " "${bridge_addr}" "${bridge_port}"
        if timeout 8 nc -z -w 5 "${bridge_addr}" "${bridge_port}" 2>/dev/null; then
            echo -e "${GREEN}${SYM_CHECK} reachable${NC}"
        else
            echo -e "${RED}${SYM_CROSS} unreachable (may be blocked, or obfs4 just ignores plain TCP)${NC}"
        fi
    fi

    # If obfs4proxy is available, we can try more
    if command -v obfs4proxy >/dev/null 2>&1; then
        echo -e "  ${GREEN}${SYM_CHECK} obfs4proxy installed${NC}"
    else
        echo -e "  ${YELLOW}${SYM_WARN} obfs4proxy not installed (apt install obfs4proxy)${NC}"
    fi
}

# =============================================================================
# TORRC INTEGRATION
# =============================================================================

_bridges_write_to_torrc() {
    # Remove any existing bridge block
    _bridges_remove_from_torrc

    # Build bridge section
    local bridge_block
    bridge_block="$(cat << 'BRIDGEMARK'

## ----------------------------------------------------------------
## Bridge configuration — managed by AnonManager
## ----------------------------------------------------------------
UseBridges 1
BRIDGEMARK
    )"

    # Add ClientTransportPlugin lines for each transport found
    local transports=()
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        local t
        t="$(echo "${line}" | awk '{print $1}')"
        local found=false
        for existing in "${transports[@]:-}"; do
            [[ "${existing}" == "${t}" ]] && found=true && break
        done
        "${found}" || transports+=("${t}")
    done < "${AM_BRIDGES_FILE}"

    for transport in "${transports[@]:-}"; do
        local plugin_path=""
        case "${transport}" in
            obfs4)       plugin_path="$(command -v obfs4proxy 2>/dev/null || echo '/usr/bin/obfs4proxy')" ;;
            meek_lite)   plugin_path="$(command -v obfs4proxy 2>/dev/null || echo '/usr/bin/obfs4proxy')" ;;
            snowflake)   plugin_path="$(command -v snowflake-client 2>/dev/null || echo '/usr/bin/snowflake-client')" ;;
        esac
        [[ -n "${plugin_path}" ]] && \
            bridge_block+=$'\n'"ClientTransportPlugin ${transport} exec ${plugin_path}"
    done

    # Add bridge lines
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        bridge_block+=$'\n'"Bridge ${line}"
    done < "${AM_BRIDGES_FILE}"

    # Append to torrc
    {
        echo ""
        echo "${bridge_block}"
        echo "## END AnonManager bridge configuration"
    } >> /etc/tor/torrc

    log "INFO" "Bridge config written to torrc"
}

_bridges_remove_from_torrc() {
    [[ -f /etc/tor/torrc ]] || return 0
    # Remove the managed block between our markers
    python3 - << 'PYEOF' 2>/dev/null || \
    sed -i '/## Bridge configuration — managed by AnonManager/,/## END AnonManager bridge configuration/d' \
        /etc/tor/torrc
import re, sys
with open('/etc/tor/torrc', 'r') as f:
    content = f.read()
# Remove our managed bridge block
cleaned = re.sub(
    r'\n## --.*\n## Bridge configuration — managed by AnonManager\n.*?## END AnonManager bridge configuration\n',
    '\n',
    content,
    flags=re.DOTALL
)
with open('/etc/tor/torrc', 'w') as f:
    f.write(cleaned)
PYEOF
    log "INFO" "Bridge config removed from torrc"
}

# =============================================================================
# VALIDATION
# =============================================================================

_bridges_validate_line() {
    local line="${1}"
    # Must start with a known transport keyword or an IP for vanilla bridges
    # Format: <transport_or_ip> <ip:port> [fingerprint] [options]
    echo "${line}" | grep -qE '^(obfs4|obfs3|meek_lite|meek|snowflake|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) '
}

# Built-in public bridges for users who can't reach bridges.torproject.org
bridges_use_builtin() {
    local transport="${1:-obfs4}"
    echo -e "  ${CYAN}Loading built-in ${transport} bridges...${NC}"

    # These are Tor Project's publicly posted default bridges
    # Updated periodically — users should get fresh bridges when possible
    case "${transport}" in
        obfs4)
            bridges_clear 2>/dev/null || true
            # Public obfs4 bridges from torproject.org/bridges
            bridges_add "obfs4 85.31.186.98:443 011F2599C0E9B27EE74B353155E244813763C3E5 cert=ayq0XzCwhpdysn5o0EyDUbmSOx3X/oTEbzDMvK8sB52RdPSmHUeqng9Kur2nj9BiQkqOjw iat-mode=0" 2>/dev/null
            bridges_add "obfs4 85.31.186.26:443 91A6354697E6B02A386312F68D82CF86824D3606 cert=RFRpXLG6CWxBgkOUjBJFLPqQ9NVGJjORLjF6hF5z8h1e3Gj2oKHh9jIFKjj6RmkNOg iat-mode=0" 2>/dev/null
            bridges_add "obfs4 193.11.166.194:27015 2D82C2E354D531A68469ADF7F878255145E6CB44 cert=4TLQPJrTSaDffMK7Nbao6LC7G9OcahNAsHFW3tRkAVUJp91oM0/0c3Mk5h8SqnnHwIQR6A iat-mode=0" 2>/dev/null
            echo -e "  ${GREEN}${SYM_CHECK} 3 built-in obfs4 bridges loaded${NC}"
            echo -e "  ${YELLOW}${SYM_WARN} These are public bridges — for better anonymity, get private bridges from bridges.torproject.org${NC}"
            ;;
        snowflake)
            bridges_clear 2>/dev/null || true
            bridges_add "snowflake 192.0.2.3:1 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net.global.prod.fastly.net/ front=cdn.sstatic.net ice=stun:stun.l.google.com:19302,stun:stun.antisip.com:3478,stun:stun.blueface.ie:3478,stun:stun.dus.net:3478,stun:stun.epygi.com:3478,stun:stun.sonetel.net:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.voys.nl:3478" 2>/dev/null
            echo -e "  ${GREEN}${SYM_CHECK} Snowflake bridge loaded${NC}"
            if ! command -v snowflake-client >/dev/null 2>&1; then
                echo -e "  ${YELLOW}${SYM_WARN} snowflake-client not installed (apt install snowflake-client)${NC}"
            fi
            ;;
        *)
            echo -e "  ${RED}${SYM_CROSS} Unknown transport: ${transport}${NC}"
            echo -e "  ${DIM}Supported: obfs4, snowflake${NC}"
            return 1
            ;;
    esac
}
