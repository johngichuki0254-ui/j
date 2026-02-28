#!/usr/bin/env bash
# =============================================================================
# ui/banner.sh — ASCII art, status dashboard, warnings, help
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

show_status_dashboard() {
    clear
    show_banner

    load_state

    echo -e "${BOLD}╔═══════════════════ SYSTEM STATUS ════════════════════╗${NC}"

    # Anonymity status
    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        echo -e "  Status   : ${GREEN}${BOLD}● ACTIVE${NC} ${SYM_LOCK}"
        echo -e "  Mode     : ${MAGENTA}${CURRENT_MODE^^}${NC}"
    else
        echo -e "  Status   : ${DIM}○ INACTIVE${NC} ${SYM_UNLOCK}"
        echo -e "  Mode     : ${DIM}NORMAL${NC}"
    fi

    # Distro / firewall info
    echo -e "  Distro   : ${CYAN}${DISTRO_FAMILY}${NC}  Firewall: ${CYAN}${FIREWALL_BACKEND}${NC}"

    # Tor
    if tor_is_running 2>/dev/null; then
        local exit_ip
        exit_ip="$(timeout 5 curl -s \
            --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
            "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]' || echo 'N/A')"
        echo -e "  Tor      : ${GREEN}Running${NC} ${SYM_CHECK}  Exit: ${GREEN}${exit_ip}${NC}"
    else
        echo -e "  Tor      : ${DIM}Stopped${NC} ${SYM_CROSS}"
    fi

    # Namespace
    if ns_exists 2>/dev/null; then
        echo -e "  Namespace: ${GREEN}${NS_NAME} active${NC} ${SYM_SHIELD}"
    else
        echo -e "  Namespace: ${DIM}Inactive${NC}"
    fi

    # Killswitch
    if fw_is_active 2>/dev/null; then
        echo -e "  Killswitch: ${GREEN}Enabled${NC} ${SYM_SHIELD}"
    else
        echo -e "  Killswitch: ${DIM}Disabled${NC}"
    fi

    # DNS
    if grep -q "^nameserver 127" /etc/resolv.conf 2>/dev/null; then
        echo -e "  DNS      : ${GREEN}Tor${NC}"
    else
        echo -e "  DNS      : ${YELLOW}System${NC}"
    fi

    # IPv6
    if ipv6_is_disabled 2>/dev/null; then
        echo -e "  IPv6     : ${GREEN}Disabled${NC}"
    else
        echo -e "  IPv6     : ${YELLOW}Enabled${NC}"
    fi

    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

view_logs() {
    clear
    echo -e "${CYAN}${BOLD}═══ Main Log (last 40 lines) ═══${NC}"
    echo -e "${DIM}"
    tail -40 "${AM_LOG_FILE}" 2>/dev/null || echo "(no logs)"
    echo -e "${NC}"
    echo -e "${CYAN}${BOLD}═══ Security Log (last 20 lines) ═══${NC}"
    echo -e "${DIM}"
    tail -20 "${AM_SECURITY_LOG}" 2>/dev/null || echo "(no security logs)"
    echo -e "${NC}"
}

show_help() {
    clear
    show_banner
    cat << EOF
${BOLD}USAGE${NC}
  sudo anonmanager [OPTION]

${BOLD}OPTIONS${NC}
  (none)       Interactive menu
  --extreme    Enable Whonix-style extreme anonymity
  --partial    Enable partial anonymity (balanced)
  --disable    Disable and fully restore system
  --status     Show live status dashboard
  --verify     Run 10-point anonymity verification
  --newid      Request new Tor exit identity
  --restore    Emergency restore (broken system recovery)
  --logs       View activity and security logs
  --help, -h   Show this help

${BOLD}ARCHITECTURE${NC}
  Tor runs inside an isolated network namespace (${NS_NAME}).
  Tor binds to ${NS_TOR_IP} (namespace veth interface).
  Host traffic is redirected to ${NS_TOR_IP}:${TOR_TRANS_PORT}/${TOR_DNS_PORT} via firewall.
  Killswitch drops all non-Tor traffic (no LAN bypass in extreme mode).

${BOLD}SUPPORTED DISTROS${NC}
  Debian/Ubuntu, Arch Linux, RHEL/Fedora/AlmaLinux

${BOLD}FIREWALL BACKENDS${NC}
  Detected automatically: nftables (preferred) or iptables

${BOLD}LOGS${NC}
  Main:     ${AM_LOG_FILE}
  Security: ${AM_SECURITY_LOG}
  Config:   ${AM_CONFIG_DIR}

${BOLD}EXAMPLES${NC}
  sudo anonmanager --extreme          # Enable full isolation
  sudo anonmanager --verify           # Test anonymity
  sudo anonmanager --disable          # Clean restore
  proxychains4 firefox                # Anonymous browsing

${BOLD}${RED}IMPORTANT${NC}
  ${SYM_WARN} Not a substitute for Tails OS or Whonix VMs
  ${SYM_WARN} Incompatible with active VPNs
  ${SYM_WARN} All changes are fully reversed on disable/exit
EOF
}
