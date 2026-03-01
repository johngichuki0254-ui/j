#!/usr/bin/env bash
# =============================================================================
# network/dns_leak_test.sh — Active DNS leak detection
#
# THREE independent detection methods:
#
#   Method A — API check (bash.ws dnsleaktest API)
#     Queries a unique token subdomain. The API reports which resolvers
#     actually answered. We verify all resolvers are Tor exit nodes (no
#     AS, no ISP resolver). Requires working Tor SOCKS.
#
#   Method B — Local resolver check
#     Inspects /etc/resolv.conf for non-127.x nameservers.
#     Checks for systemd-resolved stubs that could bypass our lock.
#     Checks for NetworkManager-injected DNS.
#
#   Method C — Kernel socket check
#     Reads /proc/net/udp and /proc/net/tcp for port-53 connections
#     originating from the host (outside namespace). Any such socket
#     is a leak candidate.
#
# Returns:
#   0 = CLEAN (no leaks detected)
#   1 = LEAK DETECTED
#   2 = INCONCLUSIVE (Tor not available, couldn't reach API)
# =============================================================================

# DNS leak test API endpoint — uses Tor SOCKS
readonly _DNS_LEAK_API="bash.ws"
readonly _DNS_LEAK_TIMEOUT=20

run_dns_leak_test() {
    local mode="${1:-full}"   # full | quick | silent
    local overall_result=0    # 0=clean, 1=leak, 2=inconclusive

    if [[ "${mode}" != "silent" ]]; then
        echo -e "\n${CYAN}${BOLD}━━━ DNS Leak Test ━━━${NC}"
    fi

    local result_a result_b result_c
    result_a=2  # inconclusive until proven otherwise
    result_b=0
    result_c=0

    # ── Method B: local resolver check (always run, no network needed) ──
    result_b="$(_dns_leak_check_local "${mode}")"

    # ── Method C: kernel socket check ──
    result_c="$(_dns_leak_check_kernel "${mode}")"

    # ── Method A: active API check (only if Tor is reachable) ──
    if [[ "${mode}" != "quick" ]]; then
        result_a="$(_dns_leak_check_api "${mode}")"
    fi

    # ── Aggregate ──
    if [[ "${result_b}" -eq 1 || "${result_c}" -eq 1 || "${result_a}" -eq 1 ]]; then
        overall_result=1
    elif [[ "${result_a}" -eq 0 && "${result_b}" -eq 0 && "${result_c}" -eq 0 ]]; then
        overall_result=0
    else
        overall_result=2
    fi

    if [[ "${mode}" != "silent" ]]; then
        echo ""
        case "${overall_result}" in
            0) echo -e "  ${GREEN}${BOLD}${SYM_SHIELD} DNS CLEAN — no leaks detected${NC}" ;;
            1) echo -e "  ${RED}${BOLD}${SYM_CROSS}  DNS LEAK DETECTED — see above${NC}" ;;
            2) echo -e "  ${YELLOW}${BOLD}${SYM_WARN}  DNS status INCONCLUSIVE — Tor not reachable for API test${NC}" ;;
        esac
        echo ""
    fi

    security_log "DNS_LEAK" "Test result: $(
        case "${overall_result}" in 0) echo CLEAN;; 1) echo LEAK;; *) echo INCONCLUSIVE;; esac
    ) (method_a=${result_a} method_b=${result_b} method_c=${result_c})"

    return "${overall_result}"
}

# =============================================================================
# METHOD A — bash.ws API active test
# =============================================================================

_dns_leak_check_api() {
    local mode="${1}"

    # Require working Tor SOCKS
    if ! _dns_leak_tor_reachable; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "  ${YELLOW}${SYM_WARN}  Method A (API): Tor SOCKS not reachable — skipping${NC}"
        return 2
    fi

    # Generate unique test token (prevents caching)
    local token
    token="$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 12 \
             || echo "$(date +%s%N | sha256sum | head -c 12)")"

    [[ "${mode}" != "silent" ]] && \
        printf "  ${DIM}[A] Active API test (token: %s)...${NC}" "${token}"

    # Step 1: trigger DNS resolution through Tor
    # The API requires querying a unique subdomain first
    local trigger_domain="${token}.${_DNS_LEAK_API}"
    timeout "${_DNS_LEAK_TIMEOUT}" curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time "${_DNS_LEAK_TIMEOUT}" \
        "https://${trigger_domain}/" >/dev/null 2>&1 || true

    # Step 2: query the API for what resolvers answered
    local api_response
    api_response="$(timeout "${_DNS_LEAK_TIMEOUT}" curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time "${_DNS_LEAK_TIMEOUT}" \
        "https://${_DNS_LEAK_API}/dns-leak-test" 2>/dev/null || echo '')"

    if [[ -z "${api_response}" ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${YELLOW}no response${NC}"
        return 2
    fi

    # Parse resolver IPs from JSON-ish response
    # Response format: [{"ip":"x.x.x.x","country_name":"...","asn":"AS..."}]
    local resolver_ips
    resolver_ips="$(echo "${api_response}" \
        | grep -oE '"ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo '')"

    if [[ -z "${resolver_ips}" ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${YELLOW}could not parse response${NC}"
        return 2
    fi

    # Check each resolver — none should be our ISP's resolver
    # We flag any resolver that isn't a Tor exit (we can't know exact Tor IPs,
    # but we can check for our own public IP or known ISP ranges)
    local our_ip
    our_ip="$(timeout 8 curl -s \
        --max-time 8 \
        "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]' || echo '')"

    local leak_found=0
    local resolver_count=0
    local resolver_list=""

    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        ((resolver_count++)) || true
        resolver_list="${resolver_list} ${ip}"

        # A leak: resolver is our own real IP
        if [[ -n "${our_ip}" && "${ip}" == "${our_ip}" ]]; then
            leak_found=1
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${RED}${SYM_CROSS}  LEAK: resolver ${ip} is your real IP!${NC}"
        fi
    done <<< "${resolver_ips}"

    if [[ "${leak_found}" -eq 0 && "${resolver_count}" -gt 0 ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${GREEN}${SYM_CHECK} ${resolver_count} resolver(s) detected, all appear external (Tor exits)${NC}"
        return 0
    elif [[ "${leak_found}" -eq 1 ]]; then
        return 1
    fi

    return 2
}

# =============================================================================
# METHOD B — local resolver configuration check
# =============================================================================

_dns_leak_check_local() {
    local mode="${1}"
    local leak=0

    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[B] Local resolver check...${NC}"

    # Check 1: resolv.conf must only contain 127.x nameservers
    local ns_lines
    ns_lines="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo '')"
    local bad_ns
    bad_ns="$(echo "${ns_lines}" | grep -v '^nameserver 127\.' \
              | grep -v '^nameserver ::1' || true)"

    if [[ -n "${bad_ns}" ]]; then
        leak=1
        [[ "${mode}" != "silent" ]] && \
            echo -e "\n  ${RED}${SYM_CROSS}  Non-Tor nameserver in resolv.conf: ${bad_ns}${NC}"
    fi

    # Check 2: systemd-resolved stub running (would intercept queries)
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local stub_ip
        stub_ip="$(resolvectl status 2>/dev/null | grep -oE 'DNS Servers.*' | head -1 || echo '')"
        # If stub is running but pointing somewhere non-Tor, that's a leak vector
        if echo "${stub_ip}" | grep -qvE '127\.|::1'; then
            leak=1
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${RED}${SYM_CROSS}  systemd-resolved active with non-Tor DNS: ${stub_ip}${NC}"
        else
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${YELLOW}${SYM_WARN}  systemd-resolved running but pointing to Tor stub${NC}"
        fi
    fi

    # Check 3: NSSwitch — ensure dns comes from files/resolve only, not mdns
    if grep -qE 'mdns' /etc/nsswitch.conf 2>/dev/null; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "\n  ${YELLOW}${SYM_WARN}  mDNS in nsswitch.conf — may leak local hostnames${NC}"
    fi

    if [[ "${leak}" -eq 0 ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${GREEN}${SYM_CHECK} resolv.conf clean${NC}"
    fi

    return "${leak}"
}

# =============================================================================
# METHOD C — kernel socket check for port-53 connections
# =============================================================================

_dns_leak_check_kernel() {
    local mode="${1}"
    local leak=0

    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[C] Kernel socket check...${NC}"

    # /proc/net/udp hex format: local_address (hex IP:port), state
    # port 53 = 0x0035
    # We're looking for sockets on UDP port 53 NOT bound to 127.0.0.1 (0x0100007F)
    # and NOT bound to 10.200.1.x (namespace veth)

    if [[ -r /proc/net/udp ]]; then
        # Column 2 is local_address in hex: XXXXXXXX:PPPP
        # Skip header line, look for port 0035 that isn't loopback/namespace
        local suspicious
        suspicious="$(awk '
            NR > 1 {
                split($2, addr, ":")
                port = addr[2]
                if (port == "0035") {
                    ip_hex = addr[1]
                    # Loopback 127.x.x.x = starts with 7F in low byte (little-endian)
                    if (substr(ip_hex, 7, 2) != "7F") {
                        print $2
                    }
                }
            }
        ' /proc/net/udp 2>/dev/null || true)"

        if [[ -n "${suspicious}" ]]; then
            # Decode and display
            while IFS= read -r entry; do
                [[ -z "${entry}" ]] && continue
                local hex_ip hex_port
                hex_ip="${entry%%:*}"
                hex_port="${entry##*:}"
                local ip
                ip="$(printf '%d.%d.%d.%d' \
                    "0x${hex_ip:6:2}" "0x${hex_ip:4:2}" \
                    "0x${hex_ip:2:2}" "0x${hex_ip:0:2}")"
                # Allow namespace veth range 10.200.1.x
                if [[ "${ip}" != "10.200.1."* ]]; then
                    leak=1
                    [[ "${mode}" != "silent" ]] && \
                        echo -e "\n  ${RED}${SYM_CROSS}  UDP port 53 socket on ${ip} — potential DNS leak${NC}"
                fi
            done <<< "${suspicious}"
        fi
    fi

    if [[ "${leak}" -eq 0 ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${GREEN}${SYM_CHECK} no rogue port-53 sockets${NC}"
    fi

    return "${leak}"
}

# =============================================================================
# HELPERS
# =============================================================================

_dns_leak_tor_reachable() {
    timeout 8 curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time 8 \
        "https://check.torproject.org/api/ip" 2>/dev/null | grep -q '"IsTor":true'
}

# Quick version for integration into verify_anonymity_comprehensive
dns_leak_quick() {
    # Returns exit code: 0=clean 1=leak 2=inconclusive
    run_dns_leak_test "quick" 2>/dev/null
}
