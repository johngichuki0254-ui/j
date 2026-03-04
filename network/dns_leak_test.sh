#!/usr/bin/env bash
# =============================================================================
# network/dns_leak_test.sh — Active DNS leak detection
#
# THREE independent detection methods:
#
#   Method A — bash.ws API with AS-based resolver classification
#     Generates a unique token, triggers DNS resolution through Tor SOCKS,
#     then queries the bash.ws API for which resolvers answered and what
#     AS (Autonomous System) they belong to. Any resolver whose ASN name
#     matches a known consumer ISP pattern is flagged as a leak.
#
#     WHY: The previous approach of comparing resolver IP to "our real IP"
#     was logically broken:
#       (a) The clearnet is unreachable under the killswitch, so fetching
#           "our IP" via icanhazip.com would always fail (empty result),
#           meaning the leak check never triggered.
#       (b) ISP resolvers never have the same IP as the end user anyway.
#     The correct signal is the resolver's AS: Tor exits resolve DNS via
#     hosting provider infrastructure, never via retail ISP networks.
#
#     API: https://bash.ws/dnsleak/test/<token>?json
#     Response: [{"ip":"...","asn":"AS12345 Provider","type":"dns"|"your_ip"}]
#
#   Method B — Local resolver configuration (offline, always runs)
#     Inspects /etc/resolv.conf for non-127.x nameservers.
#     Detects active systemd-resolved stubs pointing outside Tor.
#     Warns on mDNS in nsswitch.conf.
#
#   Method C — Kernel socket audit, IPv4 + IPv6 (offline, always runs)
#     Reads /proc/net/udp AND /proc/net/udp6 for port-53 sockets
#     bound outside loopback and the namespace veth (10.200.1.x) range.
#     Previous version only checked /proc/net/udp — IPv6 leaks would pass.
#
# Returns:
#   0 = CLEAN (no leaks detected)
#   1 = LEAK DETECTED
#   2 = INCONCLUSIVE (Tor not reachable for API, Methods B+C clean)
# =============================================================================

readonly _DNS_LEAK_API="bash.ws"
readonly _DNS_LEAK_TIMEOUT=25

# ASN name fragments identifying consumer/retail ISP resolvers.
# Tor exit nodes resolve DNS via hosting/datacenter infrastructure — they will
# never appear under these retail ISP ASN names. Any resolver matching these
# patterns means DNS is being resolved by the user's own ISP, i.e. a leak.
readonly _DNS_LEAK_ISP_PATTERNS=(
    # US broadband
    "Comcast" "Xfinity" "AT&T" "Verizon" "Cox Communications" "Charter"
    "Spectrum" "CenturyLink" "Lumen" "Frontier" "Windstream" "Optimum"
    "Cablevision" "RCN" "WideOpenWest" "WOW" "Mediacom" "Suddenlink"
    # US mobile
    "T-Mobile" "Sprint" "Cricket" "Boost Mobile" "MetroPCS" "US Cellular"
    # UK
    "BT Group" "British Telecom" "Sky Broadband" "Virgin Media" "TalkTalk"
    "EE Limited" "Plusnet" "Zen Internet"
    # Europe
    "Deutsche Telekom" "Telefonica" "Orange" "Free SAS" "Bouygues"
    "Proximus" "Belgacom" "KPN" "Ziggo" "Vodafone" "O2" "Swisscom"
    "Sunrise" "Telenet" "UPC" "Telia" "Telenor" "DNA Oyj" "Elisa"
    # Asia-Pacific
    "NTT" "SoftBank" "KDDI" "DoCoMo" "China Telecom" "China Unicom"
    "China Mobile" "Korea Telecom" "KT Corp" "SK Broadband" "LG Uplus"
    "BSNL" "Airtel" "Reliance Jio" "Singtel" "StarHub" "Telstra" "Optus"
    "iiNet" "TPG" "Spark NZ"
    # LATAM
    "Claro" "Telecom Argentina" "Movistar" "Entel"
    # Middle East / Africa
    "Etisalat" "du Telecom" "Saudi Telecom" "Ooredoo" "MTN" "Safaricom"
    # Generic patterns strongly indicating retail ISP
    "Residential" "Home Broadband"
)

# =============================================================================
# PUBLIC API
# =============================================================================

run_dns_leak_test() {
    local mode="${1:-full}"   # full | quick | silent
    local overall_result=0

    [[ "${mode}" != "silent" ]] && \
        echo -e "\n${CYAN}${BOLD}━━━ DNS Leak Test ━━━${NC}"

    local result_a=2 result_b=0 result_c=0

    # B and C are offline — always run
    result_b="$(_dns_leak_check_local  "${mode}")"
    result_c="$(_dns_leak_check_kernel "${mode}")"

    # A requires live Tor SOCKS — skip in quick mode
    [[ "${mode}" != "quick" ]] && result_a="$(_dns_leak_check_api "${mode}")"

    # Aggregate
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
            2) echo -e "  ${YELLOW}${BOLD}${SYM_WARN}  INCONCLUSIVE — offline checks clean, API test unavailable${NC}" ;;
        esac
        echo ""
    fi

    security_log "DNS_LEAK" "result=$(
        case "${overall_result}" in 0) echo CLEAN;; 1) echo LEAK;; *) echo INCONCLUSIVE;; esac
    ) (A=${result_a} B=${result_b} C=${result_c})"

    return "${overall_result}"
}

dns_leak_quick() {
    run_dns_leak_test "quick" 2>/dev/null
}

# =============================================================================
# METHOD A — bash.ws API with AS-based resolver classification
# =============================================================================

_dns_leak_check_api() {
    local mode="${1}"

    if ! _dns_leak_tor_reachable; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "  ${YELLOW}${SYM_WARN}  [A] Tor SOCKS not reachable — API test skipped${NC}"
        return 2
    fi

    # Unique token prevents any caching of test results
    local token
    token="$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 16 \
             || printf '%s' "$(date +%s%N)" | sha256sum | cut -c1-16)"

    [[ "${mode}" != "silent" ]] && \
        printf "  ${DIM}[A] API test (token: %s)...${NC}\n" "${token}"

    # Step 1: Force DNS resolution of our unique subdomain through Tor.
    # The HTTPS response does not matter — only the DNS lookup reaching bash.ws.
    timeout "${_DNS_LEAK_TIMEOUT}" curl -sf \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time "${_DNS_LEAK_TIMEOUT}" \
        "https://${token}.${_DNS_LEAK_API}/" \
        >/dev/null 2>&1 || true
    # Allow 2s for DNS log to propagate on the server side
    sleep 2

    # Step 2: Retrieve resolver list from bash.ws API
    # Endpoint: /dnsleak/test/<token>?json
    # Returns: [{"ip":"x.x.x.x","country_name":"...","asn":"AS#### Name","type":"dns"}]
    local api_response
    api_response="$(timeout "${_DNS_LEAK_TIMEOUT}" curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time "${_DNS_LEAK_TIMEOUT}" \
        "https://${_DNS_LEAK_API}/dnsleak/test/${token}?json" \
        2>/dev/null || echo '')"

    if [[ -z "${api_response}" ]] || ! echo "${api_response}" | grep -q '"ip"'; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "  ${YELLOW}${SYM_WARN}  [A] No parseable API response${NC}"
        return 2
    fi

    # Step 3: Classify each DNS resolver entry by ASN
    local leak_found=0 resolver_count=0

    while IFS= read -r obj; do
        [[ -z "${obj}" ]] && continue
        # Only process DNS resolver entries (type == "dns"), not "your_ip"
        echo "${obj}" | grep -q '"type":"dns"' || continue

        local rip rasn
        rip="$(echo  "${obj}" | grep -oE '"ip":"[^"]*"'  | head -1 | cut -d'"' -f4)"
        rasn="$(echo "${obj}" | grep -oE '"asn":"[^"]*"' | head -1 | cut -d'"' -f4)"
        [[ -z "${rip}" ]] && continue
        ((resolver_count++)) || true

        # ASN-based classification: is this resolver on a retail ISP network?
        local isp_match=""
        for pattern in "${_DNS_LEAK_ISP_PATTERNS[@]}"; do
            if echo "${rasn}" | grep -qi "${pattern}"; then
                isp_match="${pattern}"
                break
            fi
        done

        if [[ -n "${isp_match}" ]]; then
            leak_found=1
            [[ "${mode}" != "silent" ]] && echo -e \
                "  ${RED}${SYM_CROSS}  LEAK: ${rip} resolved by ISP AS${NC}" \
                "\n  ${RED}      ASN: ${rasn}${NC}" \
                "\n  ${RED}      Matched pattern: '${isp_match}'${NC}"
        else
            [[ "${mode}" != "silent" ]] && echo -e \
                "  ${GREEN}${SYM_CHECK} ${rip} — ${rasn:-unknown ASN} (non-ISP)${NC}"
        fi
    done < <(echo "${api_response}" | grep -oE '\{[^}]+\}')

    if [[ "${resolver_count}" -eq 0 ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "  ${YELLOW}${SYM_WARN}  [A] No DNS resolvers found in API response${NC}"
        return 2
    fi

    [[ "${leak_found}" -eq 1 ]] && return 1
    return 0
}

# =============================================================================
# METHOD B — Local resolver configuration (offline)
# =============================================================================

_dns_leak_check_local() {
    local mode="${1}"
    local leak=0

    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[B] Local resolver check...${NC}"

    # resolv.conf must only list 127.x or ::1 nameservers
    local bad_ns
    bad_ns="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null \
              | grep -v '^nameserver 127\.' \
              | grep -v '^nameserver ::1' || true)"
    if [[ -n "${bad_ns}" ]]; then
        leak=1
        [[ "${mode}" != "silent" ]] && \
            echo -e "\n  ${RED}${SYM_CROSS}  Non-Tor nameserver in resolv.conf:${NC}"
        while IFS= read -r ns; do
            [[ -n "${ns}" ]] && [[ "${mode}" != "silent" ]] && \
                echo -e "  ${RED}      ${ns}${NC}"
        done <<< "${bad_ns}"
    fi

    # systemd-resolved: check what DNS server it is forwarding to
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        local stub_dns
        stub_dns="$(resolvectl status 2>/dev/null \
            | grep -E 'DNS Servers:' | head -1 \
            | sed 's/.*DNS Servers: *//' | awk '{print $1}' || echo '')"
        if [[ -n "${stub_dns}" ]] && ! echo "${stub_dns}" | grep -qE '^127\.|^::1$'; then
            leak=1
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${RED}${SYM_CROSS}  systemd-resolved forwarding to non-Tor DNS: ${stub_dns}${NC}"
        elif [[ -n "${stub_dns}" ]]; then
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${YELLOW}${SYM_WARN}  systemd-resolved active (stub → Tor — acceptable)${NC}"
        fi
    fi

    # mDNS in nsswitch.conf leaks .local hostname queries outside Tor
    if grep -qE 'mdns' /etc/nsswitch.conf 2>/dev/null; then
        [[ "${mode}" != "silent" ]] && \
            echo -e "\n  ${YELLOW}${SYM_WARN}  mDNS in /etc/nsswitch.conf — .local hostname queries bypass Tor${NC}"
    fi

    [[ "${leak}" -eq 0 ]] && \
        [[ "${mode}" != "silent" ]] && echo -e " ${GREEN}${SYM_CHECK} clean${NC}"

    return "${leak}"
}

# =============================================================================
# METHOD C — Kernel socket audit (IPv4 + IPv6)
# =============================================================================

_dns_leak_check_kernel() {
    local mode="${1}"
    local leak=0

    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[C] Kernel socket audit (IPv4+IPv6)...${NC}"

    _dns_leak_scan_proc "/proc/net/udp"  "ipv4" "${mode}" || leak=1
    _dns_leak_scan_proc "/proc/net/udp6" "ipv6" "${mode}" || leak=1

    [[ "${leak}" -eq 0 ]] && \
        [[ "${mode}" != "silent" ]] && echo -e " ${GREEN}${SYM_CHECK} no rogue port-53 sockets${NC}"

    return "${leak}"
}

_dns_leak_scan_proc() {
    local proc_file="${1}" family="${2}" mode="${3}"
    local found=0

    [[ -r "${proc_file}" ]] || return 0

    while IFS=' ' read -r _ local_addr _rest; do
        # Skip header
        [[ "${local_addr}" == "local_address" ]] && continue
        [[ -z "${local_addr}" ]] && continue

        local hex_ip="${local_addr%%:*}"
        local hex_port="${local_addr##*:}"

        # Only interested in port 53 = 0x0035
        [[ "${hex_port^^}" == "0035" ]] || continue

        if [[ "${family}" == "ipv4" ]]; then
            # /proc/net/udp uses little-endian hex: AABBCCDD = DD.CC.BB.AA
            local decoded
            decoded="$(printf '%d.%d.%d.%d' \
                "0x${hex_ip:6:2}" "0x${hex_ip:4:2}" \
                "0x${hex_ip:2:2}" "0x${hex_ip:0:2}" 2>/dev/null)" || continue
            # Allow loopback (127.x) and namespace veth (10.200.1.x)
            [[ "${decoded}" == "127."* ]]     && continue
            [[ "${decoded}" == "10.200.1."* ]] && continue
            # All other addresses are unexpected DNS sockets
            found=1
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${RED}${SYM_CROSS}  Port-53 socket on ${decoded} (IPv4) — leak candidate${NC}"

        else
            # /proc/net/udp6: 32 hex chars, little-endian groups of 4 bytes
            # IPv6 loopback ::1 = 00000000000000000000000001000000
            [[ "${hex_ip}" == "00000000000000000000000001000000" ]] && continue
            # All-zeros = 0.0.0.0 equivalent — skip unbound sockets
            [[ "${hex_ip}" == "00000000000000000000000000000000" ]] && continue
            found=1
            [[ "${mode}" != "silent" ]] && \
                echo -e "\n  ${RED}${SYM_CROSS}  Port-53 socket on IPv6 addr [${hex_ip:0:8}...] — leak candidate${NC}"
        fi
    done < "${proc_file}"

    return "${found}"
}

# =============================================================================
# HELPER
# =============================================================================

_dns_leak_tor_reachable() {
    timeout 10 curl -s \
        --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
        --max-time 10 \
        "https://check.torproject.org/api/ip" 2>/dev/null | grep -q '"IsTor":true'
}
