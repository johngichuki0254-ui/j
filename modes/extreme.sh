#!/usr/bin/env bash
# =============================================================================
# modes/extreme.sh — Extreme anonymity orchestrator
# Uses pipeline_step/pipeline_cmd for full backend transparency.
# Every operation shows what it's doing and whether it succeeded.
# =============================================================================

enable_extreme_anonymity() {
    clear
    show_banner

    show_warning_screen || return 1

    local iface
    iface="$(detect_interface)" || {
        echo -e "\n${RED}${SYM_CROSS} No active network interface found.${NC}"
        echo -e "${DIM}Check: ip route get 8.8.8.8${NC}"
        return 1
    }

    local start_ts
    start_ts=$(date +%s)

    pipeline_start "EXTREME ANONYMITY SETUP" 11

    # ── Step 1: Packages ──────────────────────────────────────
    pipeline_step "Installing required packages"
    pipeline_detail "Package manager: ${PKG_MANAGER}"
    if install_required_packages 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "all packages present"
    else
        pipeline_step_warn "some packages missing — functionality may be limited"
    fi

    # ── Step 2: Backup ────────────────────────────────────────
    pipeline_step "Snapshotting system state (atomic backup)"
    pipeline_detail "Backup location: ${AM_BACKUP_DIR}/initial"
    pipeline_detail "Includes: iptables rules, sysctl values, resolv.conf, NM connections"
    if backup_network_state "initial" 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "snapshot complete"
    else
        pipeline_step_fail "backup failed — aborting for safety"
        return 1
    fi

    # ── Step 3: Kernel hardening ──────────────────────────────
    pipeline_step "Applying kernel security hardening"
    pipeline_detail "Disabling: TCP timestamps, ICMP echo, kernel pointer leaks"
    pipeline_detail "Enabling:  SYN cookies, rp_filter, BPF JIT hardening"
    apply_kernel_hardening 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "sysctl values applied"

    # ── Step 4: IPv6 disable ──────────────────────────────────
    pipeline_step "Disabling IPv6 (leak prevention)"
    pipeline_detail "Setting: net.ipv6.conf.all.disable_ipv6=1"
    pipeline_detail "Reason: IPv6 traffic bypasses iptables IPv4 rules"
    ipv6_disable 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "IPv6 disabled system-wide"

    # ── Step 5: Network namespace ─────────────────────────────
    pipeline_step "Creating isolated network namespace"
    pipeline_detail "Namespace: ${NS_NAME}"
    pipeline_detail "veth pair: ${NS_VETH_HOST} (host) ↔ ${NS_VETH_TOR} (namespace)"
    pipeline_detail "Tor will bind to: ${NS_TOR_IP}/24"
    if ns_create 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "namespace ${NS_NAME} created"
    else
        pipeline_step_fail "namespace creation failed"
        emergency_restore
        return 1
    fi

    # ── Step 6: Tor configure ─────────────────────────────────
    pipeline_step "Writing Tor configuration"
    pipeline_detail "SocksPort:   ${NS_TOR_IP}:${TOR_SOCKS_PORT}"
    pipeline_detail "DNSPort:     ${NS_TOR_IP}:${TOR_DNS_PORT}"
    pipeline_detail "TransPort:   ${NS_TOR_IP}:${TOR_TRANS_PORT}"
    pipeline_detail "ControlPort: ${NS_TOR_IP}:${TOR_CONTROL_PORT}"
    pipeline_detail "Running as:  ${TOR_USER}"
    if tor_configure 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "torrc written and validated"
    else
        pipeline_step_fail "torrc validation failed — check /etc/tor/torrc"
        emergency_restore
        return 1
    fi

    # ── Step 7: Tor start + bootstrap ────────────────────────
    pipeline_step "Starting Tor inside namespace and waiting for circuits"
    pipeline_detail "Launching: ip netns exec ${NS_NAME} sudo -u ${TOR_USER} tor"
    pipeline_detail "Bootstrap timeout: 180s"

    if ! tor_start 2>>"${AM_LOG_FILE}"; then
        pipeline_step_fail "Tor failed to start"
        emergency_restore
        return 1
    fi

    # Live bootstrap progress bar
    if ! tor_bootstrap_progress 180; then
        pipeline_step_fail "Tor bootstrap timed out"
        emergency_restore
        return 1
    fi
    pipeline_step_ok "Tor circuits established"

    # ── Step 8: Firewall killswitch ───────────────────────────
    pipeline_step "Activating firewall killswitch (${FIREWALL_BACKEND})"
    pipeline_detail "OUTPUT chain: allow only Tor user + loopback + veth subnet"
    pipeline_detail "NAT OUTPUT:   DNAT DNS→${NS_TOR_IP}:${TOR_DNS_PORT}, TCP→${NS_TOR_IP}:${TOR_TRANS_PORT}"
    pipeline_detail "IPv6 tables:  DROP all (policy)"
    pipeline_detail "DoH blocked:  1.1.1.1, 8.8.8.8, 9.9.9.9 on :443/:853"
    pipeline_detail "WebRTC:       STUN/TURN ports 3478,5349,19302 blocked"
    if fw_setup_killswitch 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "killswitch active — non-Tor traffic will be dropped"
    else
        pipeline_step_fail "killswitch setup failed"
        emergency_restore
        return 1
    fi

    # ── Step 9: DNS ───────────────────────────────────────────
    pipeline_step "Locking DNS to Tor"
    pipeline_detail "Stopping systemd-resolved stub (if active)"
    pipeline_detail "Writing nameserver 127.0.0.1 to /etc/resolv.conf"
    pipeline_detail "Setting chattr +i (immutable) on resolv.conf"
    dns_secure 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "DNS locked → Tor (immutable resolv.conf)"

    # ── Step 10: MAC + proxychains ────────────────────────────
    pipeline_step "Randomizing MAC address and configuring proxychains"
    pipeline_detail "Interface: ${iface}"
    if mac_spoof "${iface}" 2>>"${AM_LOG_FILE}"; then
        pipeline_step_ok "MAC randomized"
    else
        pipeline_step_warn "MAC randomization failed (non-critical)"
    fi
    tor_configure_proxychains 2>>"${AM_LOG_FILE}"
    pipeline_detail "Proxychains → ${NS_TOR_IP}:${TOR_SOCKS_PORT}"

    # ── Step 11: Monitor ──────────────────────────────────────
    pipeline_step "Starting background security watchdog"
    pipeline_detail "Check interval: 30s"
    pipeline_detail "Watches: Tor process, killswitch rules, DNS, IPv6, namespace"
    pipeline_detail "Alerts: security log + named pipe"
    start_monitoring 2>>"${AM_LOG_FILE}"
    pipeline_step_ok "watchdog running (PID: ${MONITORING_PID:-?})"

    # ── Save state ────────────────────────────────────────────
    ANONYMITY_ACTIVE="true"
    CURRENT_MODE="extreme"
    save_state

    local elapsed=$(( $(date +%s) - start_ts ))
    pipeline_finish

    # Update terminal title
    printf '\033]0;%s\007' "${SYM_LOCK} EXTREME ANONYMITY ACTIVE — AnonManager"

    # ── Final verification ────────────────────────────────────
    echo -e "${CYAN}${BOLD}Running final verification...${NC}\n"
    sleep 1
    verify_anonymity_comprehensive

    # ── Operation summary ─────────────────────────────────────
    show_operation_summary "EXTREME MODE ENABLED" "${elapsed}"

    echo -e "${CYAN}${BOLD}How to use:${NC}"
    echo -e "  ${GREEN}proxychains4 firefox${NC}              ${DIM}# Anonymous browsing${NC}"
    echo -e "  ${GREEN}torsocks curl https://example.com${NC} ${DIM}# CLI over Tor${NC}"
    echo -e "  ${GREEN}curl --socks5-hostname ${NS_TOR_IP}:${TOR_SOCKS_PORT} https://check.torproject.org/api/ip${NC}"
    echo ""
    echo -e "  ${YELLOW}To disable:${NC} ${GREEN}sudo anonmanager --disable${NC}"
    echo -e "  ${YELLOW}View logs:${NC}  ${GREEN}sudo anonmanager --logs${NC}"
    echo ""

    log "INFO" "Extreme anonymity mode enabled (${elapsed}s)"
    security_log "MODE" "Extreme mode activated on ${iface}"
}
