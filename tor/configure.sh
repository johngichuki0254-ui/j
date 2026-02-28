#!/usr/bin/env bash
# =============================================================================
# tor/configure.sh — Tor configuration generator
#
# CRITICAL: All listening ports bind to NS_TOR_IP (10.200.1.1), NOT 127.0.0.1.
# This is what makes the Whonix-style architecture work:
#   - Host redirects DNS/TCP → 10.200.1.1:{5353,9040}
#   - Tor listens on 10.200.1.1 inside the namespace
#   - Traffic leaves through veth → host NAT → internet
# =============================================================================

tor_configure() {
    log "INFO" "Generating Tor configuration"

    # Backup original if not already backed up
    if [[ -f /etc/tor/torrc && ! -f "${_INITIAL_BACKUP}/torrc.original" ]]; then
        cp -p /etc/tor/torrc "${_INITIAL_BACKUP}/torrc.original" 2>/dev/null || true
    fi

    # Ensure data dir exists and is owned by TOR_USER
    mkdir -p "${TOR_DATA_DIR}"
    chown -R "${TOR_USER}:${TOR_USER}" "${TOR_DATA_DIR}" 2>/dev/null || true
    chmod 700 "${TOR_DATA_DIR}"

    cat > /etc/tor/torrc << EOF
## AnonManager v${AM_VERSION} — Tor Configuration
## Generated: $(date)
## DO NOT EDIT MANUALLY — managed by anonmanager

User ${TOR_USER}
DataDirectory ${TOR_DATA_DIR}
PidFile ${TOR_PID_FILE}

## ----------------------------------------------------------------
## Listening ports — bound to namespace veth IP, NOT 127.0.0.1
## This is essential for the Whonix-style host→namespace routing
## ----------------------------------------------------------------
SocksPort  ${NS_TOR_IP}:${TOR_SOCKS_PORT}  IsolateDestAddr IsolateDestPort IsolateClientProtocol
DNSPort    ${NS_TOR_IP}:${TOR_DNS_PORT}
TransPort  ${NS_TOR_IP}:${TOR_TRANS_PORT}  IsolateClientAddr
ControlPort ${NS_TOR_IP}:${TOR_CONTROL_PORT}

## Access control
SocksPolicy accept ${NS_SUBNET}
SocksPolicy reject *

## ----------------------------------------------------------------
## DNS/onion address mapping
## ----------------------------------------------------------------
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit

## ----------------------------------------------------------------
## Security hardening
## ----------------------------------------------------------------
AvoidDiskWrites 1
SafeLogging 1
DisableDebuggerAttachment 1
ClientRejectInternalAddresses 1
WarnUnsafeSocks 1
CookieAuthentication 1

## ----------------------------------------------------------------
## Circuit management
## ----------------------------------------------------------------
CircuitBuildTimeout 60
LearnCircuitBuildTimeout 0
NewCircuitPeriod 30
MaxCircuitDirtiness 600
UseEntryGuards 1
NumEntryGuards 8
EnforceDistinctSubnets 1
StrictNodes 1

## ----------------------------------------------------------------
## Performance
## ----------------------------------------------------------------
NumCPUs 2
MaxMemInQueues 256 MB
EOF

    # Add pluggable transport support if obfs4proxy available
    if command -v obfs4proxy >/dev/null 2>&1; then
        cat >> /etc/tor/torrc << 'EOF'

## ----------------------------------------------------------------
## Pluggable transports (bridges) — disabled by default
## Uncomment and add bridge lines for censored networks
## ----------------------------------------------------------------
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
## UseBridges 1
## Bridge obfs4 <ip:port> <fingerprint> cert=<cert> iat-mode=0
EOF
    fi

    # Validate the config before we try to use it
    if ! su -s /bin/bash "${TOR_USER}" -c "tor --verify-config -f /etc/tor/torrc" \
            >/dev/null 2>&1; then
        log "ERROR" "Tor configuration validation failed"
        return 1
    fi

    log "INFO" "Tor configuration written and validated"
}

tor_configure_proxychains() {
    local config_file
    config_file="$(ls /etc/proxychains4.conf /etc/proxychains.conf 2>/dev/null | head -1)"
    [[ -z "${config_file}" ]] && config_file="/etc/proxychains4.conf"

    cat > "${config_file}" << EOF
## AnonManager — Proxychains configuration
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000
quiet_mode

[ProxyList]
socks5 ${NS_TOR_IP} ${TOR_SOCKS_PORT}
EOF

    log "INFO" "Proxychains configured → ${NS_TOR_IP}:${TOR_SOCKS_PORT}"
}
