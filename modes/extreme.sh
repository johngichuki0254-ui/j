#!/usr/bin/env bash
# =============================================================================
# modes/extreme.sh — Whonix-style full isolation mode orchestrator
#
# Step order is security-critical:
#   1. Install packages
#   2. Backup (atomic, only once)
#   3. Kernel hardening
#   4. Disable IPv6
#   5. Create namespace
#   6. Configure + start Tor in namespace
#   7. Setup firewall killswitch
#   8. Configure DNS
#   9. Proxychains
#  10. MAC randomization
#  11. Start monitor
#  12. Verify
# =============================================================================

enable_extreme_anonymity() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║           EXTREME ANONYMITY MODE                     ║
║           Whonix-Style Namespace Isolation           ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    _show_warning_and_confirm || return 1

    echo -e "\n${CYAN}${BOLD}Starting setup...${NC}\n"

    local iface
    iface="$(detect_interface)" || {
        echo -e "${RED}${SYM_CROSS} No active network interface found${NC}"
        return 1
    }

    local total=12 step=0

    _step() {
        ((step++)) || true
        echo -e "${CYAN}[${step}/${total}]${NC} $*"
    }

    # 1. Packages
    _step "Installing required packages..."
    install_required_packages || {
        echo -e "${YELLOW}${SYM_WARN} Some packages may be missing — continuing${NC}"
    }

    # 2. Backup (atomic — runs only once; safe to call multiple times)
    _step "Snapshotting system state..."
    backup_network_state "initial"

    # 3. Kernel hardening
    _step "Applying kernel security hardening..."
    apply_kernel_hardening

    # 4. Disable IPv6
    _step "Disabling IPv6 (leak prevention)..."
    ipv6_disable

    # 5. Create network namespace
    _step "Creating isolated network namespace..."
    ns_create || {
        echo -e "${RED}${SYM_CROSS} Namespace creation failed — aborting${NC}"
        emergency_restore
        return 1
    }

    # 6. Configure + start Tor in namespace
    _step "Configuring Tor..."
    tor_configure || {
        echo -e "${RED}${SYM_CROSS} Tor config invalid — aborting${NC}"
        emergency_restore
        return 1
    }

    _step "Starting Tor inside namespace..."
    tor_start || {
        echo -e "${RED}${SYM_CROSS} Tor failed to start — aborting${NC}"
        emergency_restore
        return 1
    }

    echo -e "  ${DIM}Waiting for circuits...${NC}"
    if ! tor_wait_for_bootstrap 180; then
        echo -e "${RED}${SYM_CROSS} Tor bootstrap timed out — aborting${NC}"
        emergency_restore
        return 1
    fi
    echo -e "  ${GREEN}${SYM_CHECK} Circuits established${NC}"

    # 7. Killswitch
    _step "Activating killswitch (${FIREWALL_BACKEND})..."
    fw_setup_killswitch || {
        echo -e "${RED}${SYM_CROSS} Killswitch setup failed — aborting${NC}"
        emergency_restore
        return 1
    }

    # 8. DNS
    _step "Locking DNS to Tor..."
    dns_secure

    # 9. Proxychains
    _step "Configuring Proxychains..."
    tor_configure_proxychains

    # 10. MAC randomization
    _step "Randomizing MAC address..."
    mac_spoof "${iface}" || echo -e "  ${YELLOW}${SYM_WARN} MAC spoofing failed (non-critical)${NC}"

    # 11. Monitor
    _step "Starting security watchdog..."
    start_monitoring

    # 12. State
    ANONYMITY_ACTIVE="true"
    CURRENT_MODE="extreme"
    save_state

    # Update terminal title
    printf '\033]0;%s\007' "${SYM_LOCK} EXTREME ANONYMITY — AnonManager"

    echo ""
    echo -e "${GREEN}${BOLD}${SYM_CHECK} Setup complete — running verification${NC}\n"
    sleep 1
    verify_anonymity_comprehensive

    echo -e "${CYAN}${BOLD}Usage:${NC}"
    echo -e "  ${GREEN}proxychains4 firefox${NC}         # Anonymous browsing"
    echo -e "  ${GREEN}torsocks curl example.com${NC}    # CLI over Tor"
    echo -e "  ${GREEN}curl --socks5-hostname ${NS_TOR_IP}:${TOR_SOCKS_PORT} https://check.torproject.org/api/ip${NC}"
    echo ""
    echo -e "${RED}${BOLD}Remember:${NC}"
    echo -e "  ${RED}${SYM_CROSS}${NC} All non-Tor traffic is BLOCKED by the killswitch"
    echo -e "  ${RED}${SYM_CROSS}${NC} Use Tor Browser for best fingerprint protection"
    echo -e "  ${RED}${SYM_CROSS}${NC} Never log into personal accounts"
    echo ""
    echo -e "${YELLOW}To disable: ${GREEN}sudo anonmanager --disable${NC}"

    log "INFO" "Extreme anonymity mode enabled"
    security_log "MODE" "Extreme mode activated on ${iface}"
}

_show_warning_and_confirm() {
    echo -e "${YELLOW}${BOLD}WARNINGS — Read before continuing:${NC}"
    echo -e "  ${RED}${SYM_CROSS}${NC} All non-Tor network traffic will be BLOCKED"
    echo -e "  ${RED}${SYM_CROSS}${NC} apt, git, ssh will not work while active"
    echo -e "  ${RED}${SYM_CROSS}${NC} Docker and other VMs may break"
    echo -e "  ${YELLOW}${SYM_WARN}${NC} NOT a substitute for Tails or Whonix VMs"
    echo -e "  ${YELLOW}${SYM_WARN}${NC} Browser fingerprinting is NOT prevented"
    echo ""

    if is_interactive; then
        local confirm
        read -r -p "$(echo -e "${BOLD}Type ${GREEN}UNDERSTAND${NC}${BOLD} to continue: ${NC}")" confirm
        if [[ "${confirm}" != "UNDERSTAND" ]]; then
            echo -e "${RED}Cancelled.${NC}"
            return 1
        fi
    fi
    return 0
}
