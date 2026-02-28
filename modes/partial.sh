#!/usr/bin/env bash
# =============================================================================
# modes/partial.sh — Browser-privacy mode (system tools remain functional)
# DNS goes through Tor; system traffic is unrestricted.
# =============================================================================

enable_partial_anonymity() {
    clear
    echo -e "${BLUE}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║           PARTIAL ANONYMITY MODE                     ║
║           Browser Privacy (System Tools Work)        ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "${YELLOW}System tools (apt, git, ssh) remain functional.${NC}"
    echo -e "${YELLOW}Use proxychains4 for applications you want anonymized.${NC}"
    echo ""

    if is_interactive; then
        read -r -p "$(echo -e "${CYAN}Press Enter to continue...${NC}")"
    fi

    local iface
    iface="$(detect_interface)" || return 1

    local total=8 step=0
    _pstep() { ((step++)) || true; echo -e "${CYAN}[${step}/${total}]${NC} $*"; }

    _pstep "Installing packages..."
    install_required_packages 2>/dev/null || true

    _pstep "Snapshotting system state..."
    backup_network_state "initial"

    _pstep "Disabling IPv6..."
    ipv6_disable

    _pstep "Configuring Tor..."
    tor_configure || { echo -e "${RED}Tor config failed${NC}"; return 1; }

    _pstep "Starting Tor..."
    tor_start || { echo -e "${RED}Tor start failed${NC}"; return 1; }

    echo -e "  ${DIM}Waiting for circuits...${NC}"
    tor_wait_for_bootstrap 180 || {
        echo -e "${RED}Tor bootstrap timed out${NC}"
        return 1
    }

    _pstep "Securing DNS..."
    dns_secure

    _pstep "Configuring Proxychains..."
    tor_configure_proxychains

    _pstep "Starting monitor..."
    start_monitoring

    ANONYMITY_ACTIVE="true"
    CURRENT_MODE="partial"
    save_state

    printf '\033]0;%s\007' "${SYM_LOCK} PARTIAL ANONYMITY — AnonManager"

    echo ""
    echo -e "${GREEN}${BOLD}${SYM_CHECK} Partial anonymity active${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}Usage:${NC}"
    echo -e "  ${GREEN}proxychains4 firefox${NC}     # Tor-routed browsing"
    echo -e "  ${GREEN}apt update${NC}               # Normal system tools work"
    echo -e "  ${GREEN}git clone ...${NC}            # Normal"
    echo ""
    echo -e "${YELLOW}To disable: ${GREEN}sudo anonmanager --disable${NC}"

    log "INFO" "Partial anonymity mode enabled"
    security_log "MODE" "Partial mode activated"
}
