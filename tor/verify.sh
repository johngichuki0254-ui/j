#!/usr/bin/env bash
# =============================================================================
# tor/verify.sh — Tor circuit verification and identity management
# All connections go to NS_TOR_IP (not 127.0.0.1) — Whonix-style architecture.
# =============================================================================

# Wait for Tor to fully bootstrap, with timeout
tor_wait_for_bootstrap() {
    local timeout="${1:-180}"
    local elapsed=0

    log "INFO" "Waiting for Tor to bootstrap (timeout: ${timeout}s)"

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if _tor_check_bootstrap; then
            log "INFO" "Tor bootstrapped successfully (${elapsed}s)"
            return 0
        fi

        if ! tor_is_running; then
            log "ERROR" "Tor process died while waiting for bootstrap"
            return 1
        fi

        sleep 2
        elapsed=$((elapsed + 2))

        if [[ $((elapsed % 20)) -eq 0 ]]; then
            echo -ne "\r${YELLOW}Waiting for Tor circuits... ${elapsed}s${NC}   "
        fi
    done

    echo ""
    log "ERROR" "Tor failed to bootstrap within ${timeout}s"
    return 1
}

_tor_check_bootstrap() {
    # Primary: control port at NS_TOR_IP (inside namespace, accessed from host via veth)
    local cookie_path="${TOR_DATA_DIR}/control_auth_cookie"

    if [[ -f "${cookie_path}" ]]; then
        local cookie
        cookie="$(xxd -p -c 256 "${cookie_path}" 2>/dev/null || echo '')"
        if [[ -n "${cookie}" ]]; then
            local resp
            resp="$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' \
                "${cookie}" \
                | nc -w 3 "${NS_TOR_IP}" "${TOR_CONTROL_PORT}" 2>/dev/null || echo '')"
            if echo "${resp}" | grep -q "PROGRESS=100"; then
                return 0
            fi
        fi
    fi

    # Fallback: try a SOCKS5 connection through Tor's SocksPort
    if timeout 8 curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time 8 \
        "https://check.torproject.org/api/ip" 2>/dev/null | grep -q '"IsTor":true'; then
        return 0
    fi

    return 1
}

get_new_tor_identity() {
    log "INFO" "Requesting new Tor identity"

    if ! tor_is_running; then
        echo -e "${RED}${SYM_CROSS} Tor is not running${NC}"
        return 1
    fi

    local cookie_path="${TOR_DATA_DIR}/control_auth_cookie"
    if [[ -f "${cookie_path}" ]]; then
        local cookie
        cookie="$(xxd -p -c 256 "${cookie_path}" 2>/dev/null || echo '')"
        if [[ -n "${cookie}" ]]; then
            local resp
            resp="$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' \
                "${cookie}" \
                | nc -w 3 "${NS_TOR_IP}" "${TOR_CONTROL_PORT}" 2>/dev/null || echo '')"
            if echo "${resp}" | grep -q "250 OK"; then
                echo -e "${GREEN}${SYM_CHECK} New Tor identity requested${NC}"
                sleep 3
                local new_ip
                new_ip="$(timeout 10 curl -s \
                    --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
                    "https://icanhazip.com" 2>/dev/null || echo 'unknown')"
                echo -e "${GREEN}${SYM_CHECK} New exit IP: ${new_ip}${NC}"
                security_log "IDENTITY" "New Tor identity: ${new_ip}"
                return 0
            fi
        fi
    fi

    # Fallback: reload Tor (less clean but works)
    # NOTE: SIGNAL RELOAD ≠ NEWNYM. We restart properly.
    tor_restart
    echo -e "${YELLOW}${SYM_WARN} Identity reset via restart${NC}"
}

# Comprehensive 10-point anonymity check
verify_anonymity_comprehensive() {
    clear
    echo -e "${CYAN}${BOLD}"
    printf '%-55s\n' "╔══════════════════════════════════════════════════════╗"
    printf "║  %-51s║\n" "ANONYMITY VERIFICATION — AnonManager v${AM_VERSION}"
    printf '%-55s\n' "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local passed=0 failed=0 warnings=0

    _verify_test() {
        local num="${1}" label="${2}" result="${3}" detail="${4:-}"
        printf "${YELLOW}[%2s/10]${NC} %-40s" "${num}" "${label}"
        case "${result}" in
            pass)
                echo -e "${GREEN}${SYM_CHECK} PASS${NC}${detail:+ — ${detail}}"
                ((passed++)) || true
                ;;
            fail)
                echo -e "${RED}${SYM_CROSS} FAIL${NC}${detail:+ — ${detail}}"
                ((failed++)) || true
                ;;
            warn)
                echo -e "${YELLOW}${SYM_WARN} WARN${NC}${detail:+ — ${detail}}"
                ((warnings++)) || true
                ((passed++)) || true
                ;;
        esac
    }

    # 1. Tor process running
    local t1_result="fail" t1_detail="not running"
    if tor_is_running || pgrep -u "${TOR_USER}" tor >/dev/null 2>&1; then
        t1_result="pass"; t1_detail="running (PID: $(cat "${TOR_PID_FILE}" 2>/dev/null))"
    fi
    _verify_test 1 "Tor process" "${t1_result}" "${t1_detail}"

    # 2. Tor bootstrap / circuits
    local t2_result="fail" t2_detail="not connected"
    if _tor_check_bootstrap; then
        t2_result="pass"; t2_detail="circuits established"
    fi
    _verify_test 2 "Tor circuits" "${t2_result}" "${t2_detail}"

    # 3. Exit IP via Tor
    local exit_ip
    exit_ip="$(timeout 10 curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]' || echo '')"
    local t3_result="fail" t3_detail="failed to connect"
    if [[ -n "${exit_ip}" ]]; then
        t3_result="pass"; t3_detail="exit IP: ${exit_ip}"
    fi
    _verify_test 3 "Tor exit reachable" "${t3_result}" "${t3_detail}"

    # 4. Tor Project verification
    local t4_result="fail"
    if timeout 12 curl -s \
            --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
            "https://check.torproject.org/api/ip" 2>/dev/null | grep -q '"IsTor":true'; then
        t4_result="pass"
    fi
    _verify_test 4 "Tor Project check" "${t4_result}" ""

    # 5. DNS configuration
    local t5_result="fail" t5_detail="resolv.conf not pointing to 127.x.x.x"
    if grep -q "^nameserver 127" /etc/resolv.conf 2>/dev/null; then
        t5_result="pass"; t5_detail="nameserver 127.0.0.1"
    fi
    _verify_test 5 "DNS configuration" "${t5_result}" "${t5_detail}"

    # 6. IPv6 disabled
    local t6_result="fail" t6_detail="IPv6 still enabled"
    if ipv6_is_disabled; then
        t6_result="pass"; t6_detail="disabled"
    fi
    _verify_test 6 "IPv6 disabled" "${t6_result}" "${t6_detail}"

    # 7. Killswitch active
    local t7_result="fail" t7_detail="not active"
    if fw_is_active; then
        t7_result="pass"; t7_detail="${FIREWALL_BACKEND}"
    fi
    _verify_test 7 "Killswitch (${FIREWALL_BACKEND})" "${t7_result}" "${t7_detail}"

    # 8. Network namespace
    local t8_result="fail" t8_detail="namespace missing"
    if ns_exists; then
        t8_result="pass"; t8_detail="${NS_NAME} active"
    fi
    _verify_test 8 "Network namespace" "${t8_result}" "${t8_detail}"

    # 9. WebRTC ports blocked
    local t9_result="warn" t9_detail="verify manually in browser"
    case "${FIREWALL_BACKEND}" in
        nftables)
            nft list table inet anonmanager 2>/dev/null | grep -q "3478" && \
                t9_result="pass" && t9_detail="STUN/TURN ports blocked"
            ;;
        iptables*|iptables)
            iptables -L AM_OUTPUT 2>/dev/null | grep -q "3478" && \
                t9_result="pass" && t9_detail="STUN/TURN ports blocked"
            ;;
    esac
    _verify_test 9 "WebRTC protection" "${t9_result}" "${t9_detail}"

    # 10. MAC randomized
    local t10_result="warn" t10_detail="not randomized"
    if [[ -f "${_MAC_STATE_FILE}" ]]; then
        t10_result="pass"; t10_detail="randomized"
    fi
    _verify_test 10 "MAC randomization" "${t10_result}" "${t10_detail}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}Passed:   ${passed}/10${NC}"
    echo -e "  ${RED}Failed:   ${failed}/10${NC}"
    echo -e "  ${YELLOW}Warnings: ${warnings}/10${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if   [[ ${failed} -eq 0 && ${warnings} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}${SYM_SHIELD} Anonymity: EXCELLENT${NC}"
    elif [[ ${failed} -eq 0 ]]; then
        echo -e "${YELLOW}${BOLD}${SYM_WARN} Anonymity: GOOD (review warnings)${NC}"
    elif [[ ${failed} -le 2 ]]; then
        echo -e "${YELLOW}${BOLD}${SYM_WARN} Anonymity: MODERATE (${failed} tests failed)${NC}"
    else
        echo -e "${RED}${BOLD}${SYM_CROSS} Anonymity: POOR (${failed} critical failures)${NC}"
    fi

    echo ""
    echo -e "${DIM}Manual verification:${NC}"
    echo -e "  ${SYM_ARROW} https://check.torproject.org"
    echo -e "  ${SYM_ARROW} https://ipleak.net"
    echo -e "  ${SYM_ARROW} https://browserleaks.com/webrtc"
    echo ""
}
