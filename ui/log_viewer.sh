#!/usr/bin/env bash
# =============================================================================
# ui/log_viewer.sh — Real-time log viewer with severity coloring
#
# Features:
#   - Color-coded severity (INFO=dim, WARN=yellow, ERROR=red, SECURITY=magenta)
#   - Live tail mode (refreshes every second)
#   - Filter by severity
#   - Shows backend commands that ran
#   - Timestamp display
# =============================================================================

# =============================================================================
# STATIC LOG VIEW (snapshot)
# =============================================================================

view_logs() {
    clear
    _log_header "ACTIVITY LOG"

    echo -e "\n${CYAN}${BOLD}Main Log${NC} ${DIM}(${AM_LOG_FILE})${NC}\n"
    _render_log_file "${AM_LOG_FILE}" 50

    echo -e "\n${CYAN}${BOLD}Security Log${NC} ${DIM}(${AM_SECURITY_LOG})${NC}\n"
    _render_log_file "${AM_SECURITY_LOG}" 30

    echo ""
    echo -e "${DIM}Press 'l' for live mode, any other key to return...${NC}"
    read -r -s -n 1 key
    if [[ "${key}" == "l" || "${key}" == "L" ]]; then
        view_logs_live
    fi
}

# =============================================================================
# LIVE LOG TAIL (streaming)
# =============================================================================

view_logs_live() {
    clear
    _log_header "LIVE LOG — press Ctrl+C to stop"
    echo -e "${DIM}Streaming from ${AM_LOG_FILE}${NC}\n"

    local _live_running=1
    trap '_live_running=0' INT

    tail -f "${AM_LOG_FILE}" 2>/dev/null | while IFS= read -r line; do
        [[ "${_live_running}" -eq 0 ]] && break
        _colorize_log_line "${line}"
    done

    # Restore default INT handler
    trap - INT
    echo -e "\n${DIM}Stopped.${NC}"
}

# =============================================================================
# OPERATION SUMMARY — shown after enable/disable completes
# =============================================================================

show_operation_summary() {
    local operation="${1}"   # "ENABLED" | "DISABLED" | "RESTORED"
    local duration="${2:-0}"

    echo ""
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${BOLD}Operation Summary${NC} — %s\n" "${operation}"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    echo ""
    printf "  %-28s %s\n" "Operation:"  "${operation}"
    printf "  %-28s %s\n" "Duration:"   "${duration}s"
    printf "  %-28s %s\n" "Timestamp:"  "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  %-28s %s\n" "Mode:"       "${CURRENT_MODE^^}"
    printf "  %-28s %s\n" "Distro:"     "${DISTRO_FAMILY}"
    printf "  %-28s %s\n" "Firewall:"   "${FIREWALL_BACKEND}"

    echo ""

    # Show last 10 relevant log lines
    printf "  ${DIM}Recent log entries:${NC}\n"
    grep -E "\[INFO\]|\[WARN\]|\[ERROR\]|\[SECURITY\]" "${AM_LOG_FILE}" 2>/dev/null \
        | tail -10 \
        | while IFS= read -r line; do
            printf "  "
            _colorize_log_line "${line}"
        done

    echo ""
}

# =============================================================================
# BACKEND TRANSPARENCY PANEL
# Shows what the script actually DID to the system
# =============================================================================

show_backend_report() {
    clear
    _log_header "BACKEND TRANSPARENCY REPORT"

    echo -e "\n${YELLOW}${BOLD}What AnonManager changed on your system:${NC}\n"

    # --- Firewall ---
    echo -e "${CYAN}${BOLD}Firewall (${FIREWALL_BACKEND}):${NC}"
    case "${FIREWALL_BACKEND}" in
        nftables)
            if nft list table inet anonmanager >/dev/null 2>&1; then
                echo -e "  ${GREEN}${SYM_CHECK}${NC} Table ${BOLD}inet anonmanager${NC} is active"
                local rule_count
                rule_count=$(nft list table inet anonmanager 2>/dev/null | grep -c ";" || echo "?")
                echo -e "  ${DIM}  Rules loaded: ~${rule_count}${NC}"
            else
                echo -e "  ${DIM}  No anonmanager table${NC}"
            fi
            ;;
        iptables*|iptables)
            if iptables -L AM_OUTPUT >/dev/null 2>&1; then
                local rule_count
                rule_count=$(iptables -L AM_OUTPUT 2>/dev/null | grep -c "^[A-Z]" || echo "0")
                echo -e "  ${GREEN}${SYM_CHECK}${NC} Chain ${BOLD}AM_OUTPUT${NC} active — ${rule_count} rules"
            else
                echo -e "  ${DIM}  AM_OUTPUT chain not present${NC}"
            fi
            ;;
    esac

    # --- Namespace ---
    echo -e "\n${CYAN}${BOLD}Network Namespace:${NC}"
    if ip netns list 2>/dev/null | grep -q "^${NS_NAME}"; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Namespace ${BOLD}${NS_NAME}${NC} exists"
        echo -e "  ${DIM}  Tor veth: ${NS_TOR_IP} (inside namespace)${NC}"
        echo -e "  ${DIM}  Host veth: ${NS_HOST_IP}${NC}"
        # Show processes in namespace
        local ns_pids
        ns_pids=$(ip netns pids "${NS_NAME}" 2>/dev/null | tr '\n' ' ' || echo "none")
        echo -e "  ${DIM}  PIDs inside: ${ns_pids}${NC}"
    else
        echo -e "  ${DIM}  Namespace not active${NC}"
    fi

    # --- Tor ---
    echo -e "\n${CYAN}${BOLD}Tor Process:${NC}"
    if [[ -f "${TOR_PID_FILE}" ]]; then
        local tor_pid
        tor_pid=$(cat "${TOR_PID_FILE}" 2>/dev/null || echo "")
        if [[ -n "${tor_pid}" ]] && kill -0 "${tor_pid}" 2>/dev/null; then
            echo -e "  ${GREEN}${SYM_CHECK}${NC} Running (PID: ${BOLD}${tor_pid}${NC})"
            echo -e "  ${DIM}  SocksPort:  ${NS_TOR_IP}:${TOR_SOCKS_PORT}${NC}"
            echo -e "  ${DIM}  DNSPort:    ${NS_TOR_IP}:${TOR_DNS_PORT}${NC}"
            echo -e "  ${DIM}  TransPort:  ${NS_TOR_IP}:${TOR_TRANS_PORT}${NC}"
            echo -e "  ${DIM}  ControlPort:${NS_TOR_IP}:${TOR_CONTROL_PORT}${NC}"
        else
            echo -e "  ${RED}${SYM_CROSS}${NC} PID file exists but process ${tor_pid} is not running"
        fi
    else
        echo -e "  ${DIM}  Not managed by anonmanager${NC}"
    fi

    # --- DNS ---
    echo -e "\n${CYAN}${BOLD}DNS Configuration:${NC}"
    if [[ -f /etc/resolv.conf ]]; then
        local ns_line
        ns_line=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | head -3)
        echo -e "  ${DIM}/etc/resolv.conf:${NC}"
        echo "${ns_line}" | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
        # Check if immutable
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q "i"; then
            echo -e "  ${GREEN}${SYM_CHECK}${NC} File is ${BOLD}immutable${NC} (chattr +i)"
        fi
    fi

    # --- IPv6 ---
    echo -e "\n${CYAN}${BOLD}IPv6:${NC}"
    local v6
    v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "unknown")
    if [[ "${v6}" == "1" ]]; then
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Disabled (disable_ipv6=1)"
    else
        echo -e "  ${YELLOW}${SYM_WARN}${NC} Enabled (disable_ipv6=0)"
    fi

    # --- Sysctl changes ---
    echo -e "\n${CYAN}${BOLD}Kernel Hardening (changed values):${NC}"
    local hardened_keys=(
        "net.ipv4.tcp_timestamps"
        "net.ipv4.icmp_echo_ignore_all"
        "kernel.kptr_restrict"
        "kernel.dmesg_restrict"
        "net.core.bpf_jit_harden"
    )
    for key in "${hardened_keys[@]}"; do
        local val
        val=$(sysctl -n "${key}" 2>/dev/null || echo "N/A")
        echo -e "  ${DIM}${key} = ${BOLD}${val}${NC}"
    done

    # --- MAC ---
    echo -e "\n${CYAN}${BOLD}MAC Address:${NC}"
    if [[ -f "${AM_CONFIG_DIR}/mac_state" ]]; then
        # Parse safely with grep/cut — NEVER source this file (injection risk)
        local mac_method mac_iface mac_original mac_current
        mac_method=$(grep "^method=" "${AM_CONFIG_DIR}/mac_state" \
            | cut -d= -f2 | tr -cd '[:alnum:]_-' | head -c 32)
        mac_iface=$(grep "^iface=" "${AM_CONFIG_DIR}/mac_state" \
            | cut -d= -f2 | tr -cd '[:alnum:]_.-' | head -c 32)
        mac_original=$(grep "^original_mac=" "${AM_CONFIG_DIR}/mac_state" \
            | cut -d= -f2 | tr -cd '[:xdigit:]:' | head -c 17)
        mac_current=$(ip link show "${mac_iface:-lo}" 2>/dev/null \
            | awk '/link\/ether/ {print $2}' || echo "unknown")
        echo -e "  ${GREEN}${SYM_CHECK}${NC} Randomized via ${BOLD}${mac_method:-unknown}${NC}"
        echo -e "  ${DIM}  Interface:    ${mac_iface:-unknown}${NC}"
        echo -e "  ${DIM}  Original MAC: ${mac_original:-unknown}${NC}"
        echo -e "  ${DIM}  Current MAC:  ${mac_current}${NC}"
    else
        echo -e "  ${DIM}  Not randomized${NC}"
    fi

    echo ""
    read -r -p "$(echo -e "${DIM}Press Enter to return...${NC}")"
}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_render_log_file() {
    local file="${1}" lines="${2:-40}"

    if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        echo -e "  ${DIM}(no entries yet)${NC}"
        return
    fi

    tail -"${lines}" "${file}" | while IFS= read -r line; do
        _colorize_log_line "${line}"
    done
}

_colorize_log_line() {
    local line="${1}"
    case "${line}" in
        *\[FATAL\]*)    printf "${RED}${BOLD}%s${NC}\n"    "${line}" ;;
        *\[ERROR\]*)    printf "${RED}%s${NC}\n"           "${line}" ;;
        *\[WARN\]*)     printf "${YELLOW}%s${NC}\n"        "${line}" ;;
        *\[SECURITY\]*) printf "${MAGENTA}${BOLD}%s${NC}\n" "${line}" ;;
        *\[ALERT\]*)    printf "${RED}${BOLD}%s${NC}\n"    "${line}" ;;
        *\[INFO\]*)     printf "${DIM}%s${NC}\n"           "${line}" ;;
        *)              printf "${DIM}%s${NC}\n"           "${line}" ;;
    esac
}

_log_header() {
    local title="${1}"
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 56)
    printf "\n  %s\n" "${title}"
    printf '═%.0s' $(seq 1 56)
    echo -e "${NC}"
}
