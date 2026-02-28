#!/usr/bin/env bash
# =============================================================================
# modes/partial.sh — Partial anonymity orchestrator
# System tools work normally. Proxychains routes browser/app traffic via Tor.
# =============================================================================

enable_partial_anonymity() {
    clear
    show_banner

    echo -e "${BLUE}${BOLD}PARTIAL ANONYMITY MODE${NC}"
    echo -e "${DIM}System tools (apt, git, ssh) remain functional.${NC}"
    echo -e "${DIM}Use proxychains4 for apps you want anonymized.${NC}\n"

    if is_interactive; then
        read -r -p "$(echo -e "${CYAN}Press Enter to continue or Ctrl+C to cancel...${NC}")"
    fi

    local iface start_ts
    iface="$(detect_interface)" || return 1
    start_ts=$(date +%s)

    pipeline_start "PARTIAL ANONYMITY SETUP" 8

    # ── Step 1: Packages ──────────────────────────────────────
    pipeline_step "Checking required packages"
    pipeline_detail "Package manager: ${PKG_MANAGER}"
    install_required_packages 2>>"${AM_LOG_FILE}" && \
        pipeline_step_ok "all packages present" || \
        pipeline_step_warn "some packages missing"

    # ── Step 2: Backup ────────────────────────────────────────
    pipeline_step "Snapshotting system state"
    pipeline_detail "Backup: ${AM_BACKUP_DIR}/initial"
    backup_network_state "initial" 2>>"${AM_LOG_FILE}" && \
        pipeline_step_ok "snapshot complete" || {
        pipeline_step_fail "backup failed"
        return 1
    }

    # ── Step 3: IPv6 ─────────────────────────────────────────
    pipeline_step "Disabling IPv6"
    pipeline_detail "Reason: prevents IPv6 leak even in partial mode"
    ipv6_disable 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "IPv6 disabled"

    # ── Step 4: Tor configure ─────────────────────────────────
    pipeline_step "Writing Tor configuration"
    pipeline_detail "SocksPort:   ${NS_TOR_IP}:${TOR_SOCKS_PORT}"
    pipeline_detail "DNSPort:     ${NS_TOR_IP}:${TOR_DNS_PORT}"
    pipeline_detail "TransPort:   ${NS_TOR_IP}:${TOR_TRANS_PORT}"
    if tor_configure 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "torrc written and validated"
    else
        pipeline_step_fail "torrc invalid"
        return 1
    fi

    # ── Step 5: Namespace + Tor start ─────────────────────────
    pipeline_step "Creating namespace and starting Tor"
    pipeline_detail "Namespace: ${NS_NAME} (${NS_TOR_IP})"
    ns_create 2>>"${AM_LOG_FILE}" || {
        pipeline_step_fail "namespace creation failed"
        return 1
    }
    tor_start 2>>"${AM_LOG_FILE}" || {
        pipeline_step_fail "Tor failed to start"
        return 1
    }
    if ! tor_bootstrap_progress 180; then
        pipeline_step_fail "Tor bootstrap timed out"
        return 1
    fi
    pipeline_step_ok "Tor running in namespace"

    # ── Step 6: DNS ───────────────────────────────────────────
    pipeline_step "Securing DNS through Tor"
    pipeline_detail "nameserver 127.0.0.1 → Tor DNSPort"
    dns_secure 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "DNS locked to Tor"

    # ── Step 7: Proxychains ───────────────────────────────────
    pipeline_step "Configuring Proxychains"
    pipeline_detail "socks5 ${NS_TOR_IP} ${TOR_SOCKS_PORT}"
    tor_configure_proxychains 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "proxychains configured"

    # ── Step 8: Monitor ───────────────────────────────────────
    pipeline_step "Starting security watchdog"
    start_monitoring 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "watchdog running"

    ANONYMITY_ACTIVE="true"
    CURRENT_MODE="partial"
    save_state

    local elapsed=$(( $(date +%s) - start_ts ))
    pipeline_finish

    printf '\033]0;%s\007' "${SYM_LOCK} PARTIAL ANONYMITY — AnonManager"
    show_operation_summary "PARTIAL MODE ENABLED" "${elapsed}"

    echo -e "${CYAN}${BOLD}How to use:${NC}"
    echo -e "  ${GREEN}proxychains4 firefox${NC}   ${DIM}# Anonymous browser${NC}"
    echo -e "  ${GREEN}apt update${NC}             ${DIM}# Works normally${NC}"
    echo -e "  ${GREEN}git clone ...${NC}          ${DIM}# Works normally${NC}"
    echo ""
    echo -e "  ${YELLOW}To disable:${NC} ${GREEN}sudo anonmanager --disable${NC}"
    echo ""

    log "INFO" "Partial anonymity mode enabled (${elapsed}s)"
    security_log "MODE" "Partial mode activated"
}
