#!/usr/bin/env bash
# =============================================================================
# network/namespace.sh — Whonix-style network namespace isolation
#
# Architecture:
#   HOST:                           NAMESPACE (anonspace):
#   eth0/wlan0 (internet)           veth_tor  (10.200.1.1/24)  ← Tor binds here
#   veth_host  (10.200.1.2/24) ──── (veth pair)
#
# Tor runs INSIDE the namespace, binding its ports to NS_TOR_IP (10.200.1.1).
# The killswitch on the HOST redirects all host TCP/DNS to 10.200.1.1:9040/5353.
# Tor exits through veth_host → host NAT → physical NIC.
# =============================================================================

ns_create() {
    log "INFO" "Creating network namespace: ${NS_NAME}"

    # Clean up any stale namespace first
    ns_destroy 2>/dev/null || true

    # 1. Create the namespace
    ip netns add "${NS_NAME}" || {
        log "ERROR" "Failed to create network namespace"
        return 1
    }

    # 2. Create veth pair on the host
    ip link add "${NS_VETH_HOST}" type veth peer name "${NS_VETH_TOR}" || {
        log "ERROR" "Failed to create veth pair"
        ip netns delete "${NS_NAME}" 2>/dev/null || true
        return 1
    }

    # 3. Move veth_tor into the namespace
    ip link set "${NS_VETH_TOR}" netns "${NS_NAME}" || {
        log "ERROR" "Failed to move veth into namespace"
        ip link delete "${NS_VETH_HOST}" 2>/dev/null || true
        ip netns delete "${NS_NAME}"  2>/dev/null || true
        return 1
    }

    # 4. Configure host side
    ip addr add "${NS_HOST_IP}/24" dev "${NS_VETH_HOST}"
    ip link set "${NS_VETH_HOST}" up

    # 5. Configure namespace side
    ip netns exec "${NS_NAME}" ip addr add "${NS_TOR_IP}/24" dev "${NS_VETH_TOR}"
    ip netns exec "${NS_NAME}" ip link set "${NS_VETH_TOR}" up
    ip netns exec "${NS_NAME}" ip link set lo up

    # 6. Default route in namespace → host veth (Tor's outbound path)
    ip netns exec "${NS_NAME}" ip route add default via "${NS_HOST_IP}"

    # 7. Enable IP forwarding on host so namespace traffic can reach internet
    enable_namespace_forwarding

    # 8. NAT namespace traffic outbound through physical interface
    local iface
    iface="$(detect_interface)"
    _ns_setup_nat "${iface}"

    log "INFO" "Namespace created — Tor veth: ${NS_TOR_IP}, host veth: ${NS_HOST_IP}"
    security_log "NAMESPACE" "Isolated network namespace ${NS_NAME} created"
}

_ns_setup_nat() {
    local iface="${1}"
    case "${FIREWALL_BACKEND}" in
        nftables)
            # Add masquerade to our anonmanager table (created by firewall.sh)
            # This runs AFTER firewall.sh sets up the table
            : # Handled in firewall.sh ns_nat section
            ;;
        iptables*|iptables)
            iptables -t nat -A POSTROUTING \
                -s "${NS_SUBNET}" \
                -o "${iface}" \
                -j MASQUERADE
            ;;
    esac
}

ns_destroy() {
    log "INFO" "Destroying network namespace: ${NS_NAME}"

    # Remove NAT rule
    local iface
    iface="$(detect_interface 2>/dev/null || echo '')"
    if [[ -n "${iface}" ]]; then
        case "${FIREWALL_BACKEND}" in
            iptables*|iptables)
                iptables -t nat -D POSTROUTING \
                    -s "${NS_SUBNET}" -o "${iface}" -j MASQUERADE 2>/dev/null || true
                ;;
        esac
    fi

    # Delete namespace (automatically removes veth_tor inside it)
    if ip netns list 2>/dev/null | grep -q "^${NS_NAME}"; then
        # Kill any processes still running inside the namespace
        local ns_pids
        ns_pids="$(ip netns pids "${NS_NAME}" 2>/dev/null || echo '')"
        if [[ -n "${ns_pids}" ]]; then
            echo "${ns_pids}" | xargs -r kill -TERM 2>/dev/null || true
            sleep 1
            echo "${ns_pids}" | xargs -r kill -KILL 2>/dev/null || true
        fi
        ip netns delete "${NS_NAME}" 2>/dev/null || true
    fi

    # Remove host-side veth if it still exists
    if ip link show "${NS_VETH_HOST}" >/dev/null 2>&1; then
        ip link delete "${NS_VETH_HOST}" 2>/dev/null || true
    fi

    log "INFO" "Namespace destroyed"
}

ns_exists() {
    ip netns list 2>/dev/null | grep -q "^${NS_NAME}"
}

# Execute a command inside the namespace
ns_exec() {
    ip netns exec "${NS_NAME}" "$@"
}
