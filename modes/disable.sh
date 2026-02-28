#!/usr/bin/env bash
# =============================================================================
# modes/disable.sh — Clean ordered teardown using pipeline renderer
#
# CRITICAL: Does NOT call emergency_restore(). They are separate:
#   disable_anonymity()  = clean ordered shutdown when things work
#   emergency_restore()  = brute-force recovery when things are broken
# =============================================================================

disable_anonymity() {
    clear
    show_banner

    if [[ "${ANONYMITY_ACTIVE}" != "true" ]]; then
        echo -e "\n${GREEN}${SYM_CHECK} Anonymity is already inactive. Nothing to do.${NC}\n"
        return 0
    fi

    echo -e "${YELLOW}${BOLD}DISABLING ANONYMITY — Restoring system to normal state${NC}\n"
    echo -e "${DIM}All changes made by AnonManager will be reversed.${NC}\n"

    if is_interactive; then
        read -r -p "$(echo -e "${CYAN}Press Enter to continue or Ctrl+C to cancel...${NC}")"
    fi

    local start_ts
    start_ts=$(date +%s)

    pipeline_start "SYSTEM RESTORE" 9

    # ── Step 1: Stop monitor ──────────────────────────────────
    pipeline_step "Stopping security watchdog"
    pipeline_detail "Reason: prevents false alerts during teardown"
    stop_monitoring 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "monitor stopped"

    # ── Step 2: Firewall killswitch ───────────────────────────
    pipeline_step "Removing firewall killswitch (${FIREWALL_BACKEND})"
    pipeline_detail "Removing AM_OUTPUT chain and NAT rules"
    pipeline_detail "Restoring IPv6 table policies to ACCEPT"
    if fw_teardown_killswitch 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "firewall rules removed"
    else
        pipeline_step_warn "teardown had errors — check logs"
    fi

    # ── Step 3: Stop Tor ──────────────────────────────────────
    pipeline_step "Stopping Tor process"
    pipeline_detail "Sending SIGTERM to managed Tor (PID: $(cat "${TOR_PID_FILE}" 2>/dev/null || echo '?'))"
    pipeline_detail "Waiting up to 5s for clean exit"
    tor_stop 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "Tor stopped"

    # ── Step 4: Destroy namespace ─────────────────────────────
    pipeline_step "Destroying network namespace"
    pipeline_detail "Namespace: ${NS_NAME}"
    pipeline_detail "Removing veth pair: ${NS_VETH_HOST} ↔ ${NS_VETH_TOR}"
    pipeline_detail "Killing any remaining processes inside namespace"
    ns_destroy 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "namespace destroyed"

    # ── Step 5: Restore MAC ───────────────────────────────────
    pipeline_step "Restoring MAC address"
    if [[ -f "${AM_CONFIG_DIR}/mac_state" ]]; then
        local saved_iface saved_method
        saved_iface=$(grep "^iface=" "${AM_CONFIG_DIR}/mac_state" | cut -d= -f2)
        saved_method=$(grep "^method=" "${AM_CONFIG_DIR}/mac_state" | cut -d= -f2)
        pipeline_detail "Interface: ${saved_iface:-unknown}  Method: ${saved_method:-unknown}"
        mac_restore 2>>"${AM_LOG_FILE}"
        pipeline_step_ok "original MAC restored"
    else
        pipeline_step_skip "MAC was not randomized"
    fi

    # ── Step 6: Restore kernel settings ──────────────────────
    pipeline_step "Restoring kernel sysctl settings"
    pipeline_detail "Restoring from backup: ${AM_BACKUP_DIR}/initial/sysctl/"
    restore_kernel_settings 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "kernel settings restored"

    # ── Step 7: Restore IPv6 ──────────────────────────────────
    pipeline_step "Restoring IPv6 state"
    local was_v6_off
    was_v6_off="$(cat "${_INITIAL_BACKUP}/sysctl/net_ipv6_conf_all_disable_ipv6.val" \
        2>/dev/null || echo '0')"
    if [[ "${was_v6_off}" == "0" ]]; then
        pipeline_detail "Was enabled before — re-enabling"
        ipv6_enable 2>>"${AM_LOG_FILE}"
        pipeline_step_ok "IPv6 re-enabled"
    else
        pipeline_detail "Was already disabled before — leaving disabled"
        pipeline_step_skip "IPv6 was off before AnonManager ran"
    fi

    # ── Step 8: Restore DNS ───────────────────────────────────
    pipeline_step "Restoring DNS configuration"
    pipeline_detail "Removing chattr +i from /etc/resolv.conf"
    pipeline_detail "Restoring from backup (symlink or file)"
    pipeline_detail "Re-enabling systemd-resolved if it was active"
    dns_restore 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "DNS restored"

    # ── Step 9: Restart networking ────────────────────────────
    pipeline_step "Restarting network services"
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        pipeline_detail "Restarting NetworkManager"
        systemctl restart NetworkManager 2>>"${AM_LOG_FILE}" || true
        sleep 2
        pipeline_step_ok "NetworkManager restarted"
    else
        pipeline_step_skip "NetworkManager not active"
    fi

    # ── Save state ────────────────────────────────────────────
    ANONYMITY_ACTIVE="false"
    CURRENT_MODE="none"
    save_state

    # Reset terminal title
    printf '\033]0;%s\007' "Terminal"

    local elapsed=$(( $(date +%s) - start_ts ))
    pipeline_finish

    show_operation_summary "SYSTEM RESTORED" "${elapsed}"

    echo -e "${GREEN}${BOLD}${SYM_CHECK} System fully restored to pre-anonymity state.${NC}"
    echo -e "${YELLOW}${SYM_WARN} A reboot is recommended to fully clear kernel state.${NC}"
    echo ""

    log "INFO" "Anonymity disabled — system restored (${elapsed}s)"
    security_log "MODE" "System restored to normal operation"
}
