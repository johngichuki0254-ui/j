#!/usr/bin/env bash
# =============================================================================
# modes/disable.sh — Clean, ordered teardown
#
# CRITICAL DESIGN NOTE:
#   This function does NOT call emergency_restore(). They are separate:
#     disable_anonymity()  = clean, ordered shutdown when things are working
#     emergency_restore()  = brute-force recovery when things are broken
#
#   Calling emergency_restore from disable_anonymity caused a state cycle in v3.x
#   and left iptables in inconsistent intermediate states.
# =============================================================================

disable_anonymity() {
    clear
    echo -e "${YELLOW}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║           DISABLING ANONYMITY                        ║
║           Restoring System to Normal State           ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    if [[ "${ANONYMITY_ACTIVE}" != "true" ]]; then
        echo -e "${GREEN}${SYM_CHECK} Anonymity is already inactive.${NC}"
        return 0
    fi

    if is_interactive; then
        read -r -p "$(echo -e "${CYAN}Press Enter to restore system...${NC}")"
    fi

    local total=9 step=0
    _dstep() { ((step++)) || true; echo -e "${CYAN}[${step}/${total}]${NC} $*"; }

    # 1. Stop watchdog first (prevents spurious alerts during teardown)
    _dstep "Stopping security monitor..."
    stop_monitoring

    # 2. Remove firewall killswitch
    _dstep "Removing firewall killswitch..."
    fw_teardown_killswitch

    # 3. Stop Tor
    _dstep "Stopping Tor..."
    tor_stop

    # 4. Destroy namespace (cleans up veth, namespace processes)
    _dstep "Destroying network namespace..."
    ns_destroy

    # 5. Restore MAC
    _dstep "Restoring MAC address..."
    mac_restore

    # 6. Restore kernel settings
    _dstep "Restoring kernel settings..."
    restore_kernel_settings

    # 7. Re-enable IPv6 (if it was enabled before)
    _dstep "Re-enabling IPv6..."
    local was_v6_off
    was_v6_off="$(cat "${_INITIAL_BACKUP}/sysctl/net_ipv6_conf_all_disable_ipv6.val" \
        2>/dev/null || echo '0')"
    if [[ "${was_v6_off}" == "0" ]]; then
        ipv6_enable
    fi

    # 8. Restore DNS
    _dstep "Restoring DNS configuration..."
    dns_restore

    # 9. Restart networking
    _dstep "Restarting network services..."
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 2
    fi

    # Reset terminal title
    printf '\033]0;%s\007' "Terminal"

    # Save clean state
    ANONYMITY_ACTIVE="false"
    CURRENT_MODE="none"
    save_state

    echo ""
    echo -e "${GREEN}${BOLD}${SYM_CHECK} System restored to normal operation.${NC}"
    echo -e "${YELLOW}${SYM_ARROW} A reboot is recommended to fully clear all residual state.${NC}"
    echo ""

    log "INFO" "Anonymity disabled — system restored"
    security_log "MODE" "System restored to normal operation"
}
