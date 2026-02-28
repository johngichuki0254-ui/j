#!/usr/bin/env bash
# =============================================================================
# ui/banner.sh — Banner, live HUD, status dashboard, warnings, help
#
# Key UX improvements:
#   - Non-blocking IP fetch (shows N/A immediately, updates async)
#   - Connection quality indicator
#   - Clear visual separation between ACTIVE/INACTIVE states
#   - Actionable status — tells user what to do next
# =============================================================================

show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║   █████╗ ███╗   ██╗ ██████╗ ███╗   ██╗               ║
║  ██╔══██╗████╗  ██║██╔═══██╗████╗  ██║               ║
║  ███████║██╔██╗ ██║██║   ██║██╔██╗ ██║               ║
║  ██╔══██║██║╚██╗██║██║   ██║██║╚██╗██║               ║
║  ██║  ██║██║ ╚████║╚██████╔╝██║ ╚████║               ║
║  ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═══╝               ║
║                                                       ║
║   MANAGER v4.0  —  Whonix-Style Tor Isolation         ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# =============================================================================
# LIVE HUD — compact single-line status bar
# Shown at top of menu, refreshes on each menu render
# =============================================================================

show_hud() {
    local ts
    ts="$(date '+%H:%M:%S')"

    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        printf "${GREEN}${BOLD} ● ACTIVE %-8s ${NC}" "${CURRENT_MODE^^}"
        printf "${DIM}│${NC} "
        # Tor running?
        if tor_is_running 2>/dev/null; then
            printf "${GREEN}Tor ✓${NC}"
        else
            printf "${RED}Tor ✗${NC}"
        fi
        printf " ${DIM}│${NC} "
        # Killswitch?
        if fw_is_active 2>/dev/null; then
            printf "${GREEN}KS ✓${NC}"
        else
            printf "${RED}KS ✗${NC}"
        fi
        printf " ${DIM}│${NC} "
        # DNS?
        if grep -q "^nameserver 127" /etc/resolv.conf 2>/dev/null; then
            printf "${GREEN}DNS ✓${NC}"
        else
            printf "${RED}DNS ✗${NC}"
        fi
        printf " ${DIM}│ %s${NC}\n" "${ts}"
    else
        printf "${DIM} ○ INACTIVE       │ %s${NC}\n" "${ts}"
    fi
}

# =============================================================================
# FULL STATUS DASHBOARD
# =============================================================================

show_status_dashboard() {
    clear
    show_banner
    load_state

    # ── Status block ──────────────────────────────────────────
    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗"
        echo -e "║  ${SYM_LOCK}  ANONYMITY ACTIVE — ${CURRENT_MODE^^} MODE$(printf '%*s' $((28 - ${#CURRENT_MODE})) '')║"
        echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${DIM}╔══════════════════════════════════════════════════════╗"
        echo -e "║  ${SYM_UNLOCK}  ANONYMITY INACTIVE                                  ║"
        echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""

    # ── Two-column layout ─────────────────────────────────────
    local col1=() col2=()

    # Left column — network
    _status_row "Distro"     "${DISTRO_FAMILY}"    col1
    _status_row "Firewall"   "${FIREWALL_BACKEND}" col1

    if tor_is_running 2>/dev/null; then
        _status_row_ok "Tor" "running (PID: $(cat "${TOR_PID_FILE}" 2>/dev/null || echo '?'))" col1
    else
        _status_row_bad "Tor" "stopped" col1
    fi

    if ns_exists 2>/dev/null; then
        _status_row_ok "Namespace" "${NS_NAME} active" col1
    else
        _status_row_off "Namespace" "inactive" col1
    fi

    # Right column — security
    if fw_is_active 2>/dev/null; then
        _status_row_ok "Killswitch" "enabled" col2
    else
        _status_row_off "Killswitch" "disabled" col2
    fi

    if grep -q "^nameserver 127" /etc/resolv.conf 2>/dev/null; then
        _status_row_ok "DNS" "→ Tor (127.0.0.1)" col2
    else
        _status_row_bad "DNS" "→ system (leak risk)" col2
    fi

    if ipv6_is_disabled 2>/dev/null; then
        _status_row_ok "IPv6" "disabled" col2
    else
        _status_row_bad "IPv6" "enabled (leak risk)" col2
    fi

    if [[ -f "${AM_CONFIG_DIR}/mac_state" ]]; then
        _status_row_ok "MAC" "randomized" col2
    else
        _status_row_off "MAC" "not randomized" col2
    fi

    # Print rows side by side
    local max=$(( ${#col1[@]} > ${#col2[@]} ? ${#col1[@]} : ${#col2[@]} ))
    for (( i=0; i<max; i++ )); do
        printf "  %-38b  %b\n" "${col1[$i]:-}" "${col2[$i]:-}"
    done

    echo ""

    # ── Exit IP (non-blocking — shows stale or N/A instantly) ─
    _show_exit_ip_async

    # ── Next action hint ──────────────────────────────────────
    echo ""
    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        echo -e "  ${DIM}Next: ${GREEN}proxychains4 <app>${NC}${DIM} to use anonymity  |  ${YELLOW}[3]${NC}${DIM} to disable${NC}"
    else
        echo -e "  ${DIM}Next: ${GREEN}[1]${NC}${DIM} to enable extreme mode  |  ${GREEN}[2]${NC}${DIM} for partial mode${NC}"
    fi
    echo ""
}

# =============================================================================
# EXIT IP DISPLAY (non-blocking)
# Shows cached IP instantly, fetches real one in background
# =============================================================================

readonly _IP_CACHE_FILE="${AM_CONFIG_DIR}/exit_ip.cache"
declare -g _IP_FETCH_PID=""

_show_exit_ip_async() {
    local cached_ip cached_ts

    if [[ -f "${_IP_CACHE_FILE}" ]]; then
        cached_ip=$(cut -d'|' -f1 "${_IP_CACHE_FILE}" 2>/dev/null || echo "")
        cached_ts=$(cut -d'|' -f2 "${_IP_CACHE_FILE}" 2>/dev/null || echo "")
    fi

    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        printf "  ${CYAN}${BOLD}Exit IP :${NC}  "
        if [[ -n "${cached_ip}" ]]; then
            echo -e "${GREEN}${cached_ip}${NC}  ${DIM}(as of ${cached_ts})${NC}"
        else
            echo -e "${DIM}fetching...${NC}"
        fi

        # Kill any previous background fetch before spawning a new one
        if [[ -n "${_IP_FETCH_PID}" ]] && kill -0 "${_IP_FETCH_PID}" 2>/dev/null; then
            kill "${_IP_FETCH_PID}" 2>/dev/null || true
        fi

        # Spawn a single background fetch — result appears on next dashboard render
        (
            local ip
            ip=$(timeout 8 curl -s \
                --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
                "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "${ip}" && "${ip}" =~ ^[0-9a-fA-F:.]+$ ]]; then
                echo "${ip}|$(date '+%H:%M:%S')" > "${_IP_CACHE_FILE}"
            fi
        ) &
        _IP_FETCH_PID=$!
    fi
}

# =============================================================================
# WARNING SCREEN — scannable format, not a wall of text
# =============================================================================

show_warning_screen() {
    clear
    echo -e "${RED}${BOLD}"
    printf '━%.0s' $(seq 1 56); echo ""
    printf "  %-52s\n" "⚠  BEFORE YOU CONTINUE — READ THIS"
    printf '━%.0s' $(seq 1 56); echo ""
    echo -e "${NC}"

    # What it DOES — green
    echo -e "${GREEN}${BOLD}  WHAT THIS TOOL DOES:${NC}"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Routes ALL traffic through Tor"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Blocks non-Tor traffic (killswitch)"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Prevents DNS leaks"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Disables IPv6 (leak prevention)"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Randomizes MAC address"
    echo -e "  ${GREEN}${SYM_CHECK}${NC}  Fully reverses all changes on disable"
    echo ""

    # What it DOES NOT DO — red
    echo -e "${RED}${BOLD}  WHAT THIS TOOL DOES NOT DO:${NC}"
    echo -e "  ${RED}${SYM_CROSS}${NC}  Prevent browser fingerprinting"
    echo -e "  ${RED}${SYM_CROSS}${NC}  Protect you if you log into personal accounts"
    echo -e "  ${RED}${SYM_CROSS}${NC}  Hide that you are using Tor from your ISP"
    echo -e "  ${RED}${SYM_CROSS}${NC}  Protect against a compromised machine"
    echo -e "  ${RED}${SYM_CROSS}${NC}  Defeat nation-state correlation attacks"
    echo ""

    # Breaking changes — yellow
    echo -e "${YELLOW}${BOLD}  WHILE ACTIVE (extreme mode):${NC}"
    echo -e "  ${YELLOW}${SYM_WARN}${NC}  apt, git, ssh, pip will NOT work"
    echo -e "  ${YELLOW}${SYM_WARN}${NC}  Docker networking will break"
    echo -e "  ${YELLOW}${SYM_WARN}${NC}  VPNs are incompatible"
    echo ""

    # Confirmation
    if is_interactive; then
        printf "${BOLD}  Type ${GREEN}UNDERSTAND${NC}${BOLD} to continue, or Enter to cancel: ${NC}"
        local confirm
        read -r confirm
        if [[ "${confirm}" != "UNDERSTAND" ]]; then
            echo -e "\n${YELLOW}Cancelled.${NC}\n"
            return 1
        fi
    fi
    return 0
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    clear
    show_banner
    cat << EOF
${BOLD}USAGE${NC}
  sudo anonmanager [OPTION]

${BOLD}OPTIONS${NC}
  (none)        Interactive menu
  --extreme     Enable Whonix-style extreme anonymity
  --partial     Enable partial anonymity (balanced)
  --disable     Disable and fully restore system
  --status      Show live status dashboard
  --verify      Run 10-point anonymity verification
  --newid       Request new Tor exit identity
  --restore     Emergency restore (broken system recovery)
  --logs        View activity and security logs
  --help, -h    Show this help

${BOLD}ARCHITECTURE${NC}
  Tor runs inside an isolated network namespace (${NS_NAME}).
  All host traffic is DNAT'd to Tor's TransPort at ${NS_TOR_IP}:${TOR_TRANS_PORT}.
  DNS is redirected to Tor's DNSPort at ${NS_TOR_IP}:${TOR_DNS_PORT}.
  Killswitch drops everything that doesn't go through Tor.

${CYAN}${BOLD}Traffic flow:${NC}
  App → iptables DNAT → ${NS_TOR_IP}:${TOR_TRANS_PORT} → Tor (namespace)
                                     → veth_host → NAT → Internet

${BOLD}DISTRO SUPPORT${NC}
  Debian/Ubuntu  (apt,    iptables or nftables)
  Arch Linux     (pacman, nftables preferred)
  RHEL/Fedora    (dnf,    nftables + EPEL)

${BOLD}LOGS${NC}
  Main:      ${AM_LOG_FILE}
  Security:  ${AM_SECURITY_LOG}
  Config:    ${AM_CONFIG_DIR}

${BOLD}${RED}IMPORTANT${NC}
  ${SYM_WARN} All changes are FULLY REVERSED on --disable or script exit
  ${SYM_WARN} Not a substitute for Tails OS or Whonix VMs
  ${SYM_WARN} Use Tor Browser for browser fingerprint protection
EOF
}

# =============================================================================
# HELPERS
# =============================================================================

_status_row() {
    local label="${1}" val="${2}"
    local -n _arr="${3}"
    _arr+=("${DIM}${label}:${NC} ${val}")
}

_status_row_ok() {
    local label="${1}" val="${2}"
    local -n _arr="${3}"
    _arr+=("${GREEN}${SYM_CHECK}${NC} ${label}: ${GREEN}${val}${NC}")
}

_status_row_bad() {
    local label="${1}" val="${2}"
    local -n _arr="${3}"
    _arr+=("${RED}${SYM_CROSS}${NC} ${label}: ${RED}${val}${NC}")
}

_status_row_off() {
    local label="${1}" val="${2}"
    local -n _arr="${3}"
    _arr+=("${DIM}− ${label}: ${val}${NC}")
}
