#!/usr/bin/env bash
# =============================================================================
# network/firewall.sh — Killswitch with iptables AND nftables backends
#
# Killswitch rules:
#   HOST OUTPUT: only allow → Tor (NS_TOR_IP ports), DHCP, loopback
#   HOST NAT:    redirect DNS→5353@NS_TOR_IP, TCP→9040@NS_TOR_IP
#   IPv6:        fully blocked (DROP all)
#
# CRITICAL: LAN ranges are NOT in the allowlist in extreme mode.
#           Only loopback and the veth subnet pass through.
# =============================================================================

fw_setup_killswitch() {
    log "INFO" "Setting up killswitch (backend: ${FIREWALL_BACKEND})"

    case "${FIREWALL_BACKEND}" in
        nftables)        _fw_nftables_setup ;;
        iptables-legacy) _fw_iptables_setup "iptables-legacy" ;;
        iptables)        _fw_iptables_setup "iptables" ;;
        *)
            log "ERROR" "Unknown firewall backend: ${FIREWALL_BACKEND}"
            return 1
            ;;
    esac

    security_log "KILLSWITCH" "Killswitch activated (backend: ${FIREWALL_BACKEND})"
}

fw_teardown_killswitch() {
    log "INFO" "Tearing down killswitch"

    case "${FIREWALL_BACKEND}" in
        nftables)        _fw_nftables_teardown ;;
        iptables-legacy|iptables) _fw_iptables_teardown ;;
    esac

    security_log "KILLSWITCH" "Killswitch deactivated"
}

# =============================================================================
# NFTABLES BACKEND
# =============================================================================

_fw_nftables_setup() {
    local tor_uid
    tor_uid="$(id -u "${TOR_USER}" 2>/dev/null || echo '0')"
    local iface
    iface="$(detect_interface)"

    # Remove stale table if present
    nft delete table inet anonmanager 2>/dev/null || true

    # Write complete ruleset atomically
    nft -f - << NFTEOF
table inet anonmanager {

    # ----------------------------------------------------------------
    # IPv4 NAT: redirect host traffic into the namespace Tor ports
    # ----------------------------------------------------------------
    chain nat_output {
        type nat hook output priority -100; policy accept;

        # Tor process owns its own traffic — never redirect
        meta skuid ${tor_uid} return

        # Loopback — never redirect
        oif lo return

        # Namespace veth traffic — never redirect
        ip daddr ${NS_SUBNET} return

        # Redirect DNS (UDP+TCP) to Tor's DNSPort
        ip protocol udp udp dport 53 dnat ip to ${NS_TOR_IP}:${TOR_DNS_PORT}
        ip protocol tcp tcp dport 53 dnat ip to ${NS_TOR_IP}:${TOR_DNS_PORT}

        # Redirect all TCP to Tor's TransPort
        ip protocol tcp tcp flags & (fin|syn|rst|ack) == syn \
            dnat ip to ${NS_TOR_IP}:${TOR_TRANS_PORT}
    }

    # ----------------------------------------------------------------
    # NAT masquerade for namespace traffic outbound
    # ----------------------------------------------------------------
    chain nat_postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oif "${iface}" ip saddr ${NS_SUBNET} masquerade
    }

    # ----------------------------------------------------------------
    # OUTPUT filter: killswitch
    # ----------------------------------------------------------------
    chain output {
        type filter hook output priority 0; policy drop;

        # Loopback always allowed
        oif lo accept

        # Established/related traffic
        ct state established,related accept

        # Tor process can reach internet directly (it needs to)
        meta skuid ${tor_uid} accept

        # Traffic to/from namespace veth (Tor's access point)
        ip daddr ${NS_SUBNET} accept
        ip saddr ${NS_SUBNET} accept

        # DHCP (must happen before killswitch catches it)
        ip protocol udp udp dport 67-68 accept
        ip protocol udp udp sport 67-68 accept

        # Block DoH (DNS-over-HTTPS bypass attempts)
        ip protocol tcp tcp dport { 443, 853 } ip daddr {
            1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4,
            9.9.9.9, 149.112.112.112, 94.140.14.14
        } drop

        # Block WebRTC STUN/TURN (IP leak vector in browsers)
        ip protocol udp udp dport { 3478, 5349, 19302 } drop
        ip protocol tcp tcp dport { 3478, 5349 } drop

        # Block mDNS (local network leak)
        ip protocol udp udp dport 5353 ip daddr != ${NS_TOR_IP} drop

        # Log and drop everything else
        log prefix "AM_BLOCKED: " level warn
        drop
    }

    # ----------------------------------------------------------------
    # INPUT filter: minimal
    # ----------------------------------------------------------------
    chain input {
        type filter hook input priority 0; policy drop;
        ct state invalid drop
        ct state established,related accept
        iif lo accept
        # Allow DHCP responses
        ip protocol udp udp sport 67-68 accept
    }

    # ----------------------------------------------------------------
    # FORWARD: block everything (not a router)
    # ----------------------------------------------------------------
    chain forward {
        type filter hook forward priority 0; policy drop;
        # Allow namespace traffic to reach internet
        iif "${NS_VETH_HOST}" accept
        oif "${NS_VETH_HOST}" accept
    }
}

# ----------------------------------------------------------------
# IPv6: complete block
# ----------------------------------------------------------------
table ip6 anonmanager_v6 {
    chain output {
        type filter hook output priority 0; policy drop;
        oif lo accept
    }
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
}
NFTEOF

    log "INFO" "nftables killswitch installed"
}

_fw_nftables_teardown() {
    nft delete table inet  anonmanager     2>/dev/null || true
    nft delete table ip6   anonmanager_v6  2>/dev/null || true
    log "INFO" "nftables killswitch removed"
}

# =============================================================================
# IPTABLES BACKEND (also handles iptables-legacy)
# =============================================================================

_fw_iptables_setup() {
    local tor_uid
    tor_uid="$(id -u "${TOR_USER}" 2>/dev/null || echo '0')"
    local iface
    iface="$(detect_interface)"

    # ---- Clean up any previous AM chains ----
    _fw_iptables_teardown 2>/dev/null || true

    # ---- Create chains ----
    iptables -N AM_OUTPUT
    iptables -t nat -N AM_NAT_OUTPUT
    iptables -t nat -N AM_NAT_POSTROUTING

    # ---- Hook into main chains ----
    iptables -I OUTPUT 1 -j AM_OUTPUT
    iptables -t nat -I OUTPUT 1 -j AM_NAT_OUTPUT
    iptables -t nat -A POSTROUTING -j AM_NAT_POSTROUTING

    # ===== AM_OUTPUT (filter) =====

    # Loopback
    iptables -A AM_OUTPUT -o lo -j ACCEPT

    # Established
    iptables -A AM_OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Tor process
    iptables -A AM_OUTPUT -m owner --uid-owner "${tor_uid}" -j ACCEPT

    # Traffic to/from namespace veth
    iptables -A AM_OUTPUT -d "${NS_SUBNET}" -j ACCEPT
    iptables -A AM_OUTPUT -s "${NS_SUBNET}" -j ACCEPT

    # DHCP
    iptables -A AM_OUTPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT

    # Block DoH bypass (DNS-over-HTTPS to known resolvers)
    local doh_ips=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" "9.9.9.9" "149.112.112.112")
    for ip in "${doh_ips[@]}"; do
        iptables -A AM_OUTPUT -p tcp -m multiport --dports 443,853 \
            -d "${ip}" -j REJECT --reject-with tcp-reset
    done

    # Block WebRTC STUN/TURN
    iptables -A AM_OUTPUT -p udp -m multiport --dports 3478,5349,19302 -j REJECT
    iptables -A AM_OUTPUT -p tcp -m multiport --dports 3478,5349 \
        -j REJECT --reject-with tcp-reset

    # Log + DROP everything else (the actual killswitch)
    iptables -A AM_OUTPUT -j LOG --log-prefix "AM_BLOCKED: " --log-level 4
    iptables -A AM_OUTPUT -j DROP

    # ===== AM_NAT_OUTPUT =====

    # Don't redirect Tor's own traffic
    iptables -t nat -A AM_NAT_OUTPUT -m owner --uid-owner "${tor_uid}" -j RETURN

    # Don't redirect loopback
    iptables -t nat -A AM_NAT_OUTPUT -o lo -j RETURN

    # Don't redirect namespace subnet traffic
    iptables -t nat -A AM_NAT_OUTPUT -d "${NS_SUBNET}" -j RETURN

    # Redirect DNS → Tor DNSPort on NS_TOR_IP
    iptables -t nat -A AM_NAT_OUTPUT -p udp --dport 53 \
        -j DNAT --to-destination "${NS_TOR_IP}:${TOR_DNS_PORT}"
    iptables -t nat -A AM_NAT_OUTPUT -p tcp --dport 53 \
        -j DNAT --to-destination "${NS_TOR_IP}:${TOR_DNS_PORT}"

    # Redirect all TCP SYNs → Tor TransPort on NS_TOR_IP
    iptables -t nat -A AM_NAT_OUTPUT \
        -p tcp --syn \
        -j DNAT --to-destination "${NS_TOR_IP}:${TOR_TRANS_PORT}"

    # ===== AM_NAT_POSTROUTING =====
    # Namespace traffic masquerade
    iptables -t nat -A AM_NAT_POSTROUTING \
        -s "${NS_SUBNET}" -o "${iface}" -j MASQUERADE

    # ===== IPv6: Full block =====
    ip6tables -P INPUT   DROP 2>/dev/null || true
    ip6tables -P OUTPUT  DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    # Allow loopback only
    ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

    log "INFO" "iptables killswitch installed"
}

_fw_iptables_teardown() {
    # Unhook from main chains (loop in case rule was inserted multiple times)
    while iptables -C OUTPUT -j AM_OUTPUT 2>/dev/null; do
        iptables -D OUTPUT -j AM_OUTPUT
    done
    while iptables -t nat -C OUTPUT -j AM_NAT_OUTPUT 2>/dev/null; do
        iptables -t nat -D OUTPUT -j AM_NAT_OUTPUT
    done
    while iptables -t nat -C POSTROUTING -j AM_NAT_POSTROUTING 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j AM_NAT_POSTROUTING
    done

    # Flush + delete chains
    iptables -F AM_OUTPUT              2>/dev/null || true
    iptables -X AM_OUTPUT              2>/dev/null || true
    iptables -t nat -F AM_NAT_OUTPUT   2>/dev/null || true
    iptables -t nat -X AM_NAT_OUTPUT   2>/dev/null || true
    iptables -t nat -F AM_NAT_POSTROUTING 2>/dev/null || true
    iptables -t nat -X AM_NAT_POSTROUTING 2>/dev/null || true

    # Restore IPv6 defaults
    ip6tables -P INPUT   ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -F 2>/dev/null || true

    log "INFO" "iptables killswitch removed"
}

fw_is_active() {
    case "${FIREWALL_BACKEND}" in
        nftables)
            nft list table inet anonmanager >/dev/null 2>&1
            ;;
        iptables*|iptables)
            iptables -L AM_OUTPUT >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}
