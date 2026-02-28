#!/usr/bin/env bash
# =============================================================================
# system/monitor.sh — Background security watchdog
# Uses a named pipe so alerts reach the main process without wall(1).
# =============================================================================

readonly _MONITOR_PIPE="${AM_CONFIG_DIR}/monitor.pipe"
readonly _MONITOR_PID_FILE="${AM_CONFIG_DIR}/monitor.pid"
readonly _MONITOR_INTERVAL=30  # seconds between checks

start_monitoring() {
    if [[ -f "${_MONITOR_PID_FILE}" ]]; then
        local existing
        existing="$(cat "${_MONITOR_PID_FILE}" 2>/dev/null || echo '')"
        if [[ -n "${existing}" ]] && kill -0 "${existing}" 2>/dev/null; then
            log "INFO" "Monitor already running (PID: ${existing})"
            return 0
        fi
        rm -f "${_MONITOR_PID_FILE}"
    fi

    # Create named pipe for alert delivery
    [[ -p "${_MONITOR_PIPE}" ]] || mkfifo "${_MONITOR_PIPE}"
    chmod 600 "${_MONITOR_PIPE}"

    # Launch monitor in background subshell
    (
        while true; do
            sleep "${_MONITOR_INTERVAL}"

            # Only check if anonymity is supposed to be active
            [[ "${ANONYMITY_ACTIVE}" == "true" ]] || continue

            _monitor_check_tor
            _monitor_check_firewall
            _monitor_check_dns
            _monitor_check_ipv6
            _monitor_check_namespace
        done
    ) &

    local monitor_pid=$!
    MONITORING_PID="${monitor_pid}"
    echo "${monitor_pid}" > "${_MONITOR_PID_FILE}"
    chmod 600 "${_MONITOR_PID_FILE}"
    log "INFO" "Security monitor started (PID: ${monitor_pid})"
}

stop_monitoring() {
    local pid=""
    if [[ -f "${_MONITOR_PID_FILE}" ]]; then
        pid="$(cat "${_MONITOR_PID_FILE}" 2>/dev/null || echo '')"
    fi
    if [[ -z "${pid}" && -n "${MONITORING_PID:-}" ]]; then
        pid="${MONITORING_PID}"
    fi

    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
        log "INFO" "Monitor stopped (PID: ${pid})"
    fi

    rm -f "${_MONITOR_PID_FILE}"
    MONITORING_PID=""
}

_monitor_alert() {
    local category="${1}"; shift
    local message="$*"
    security_log "ALERT:${category}" "${message}"
    # Try to write to pipe non-blocking; never block if nobody is reading
    if [[ -p "${_MONITOR_PIPE}" ]]; then
        echo "[ALERT:${category}] ${message}" >> "${_MONITOR_PIPE}" 2>/dev/null || true
    fi
    # Also broadcast via logger if available
    if command -v logger >/dev/null 2>&1; then
        logger -p syslog.warning -t anonmanager "ALERT:${category} ${message}" 2>/dev/null || true
    fi
}

_monitor_check_tor() {
    if [[ -f "${TOR_PID_FILE}" ]]; then
        local pid
        pid="$(cat "${TOR_PID_FILE}" 2>/dev/null || echo '')"
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            _monitor_alert "TOR" "Tor process (PID ${pid}) died unexpectedly — killswitch is still active but NO TRAFFIC FLOWS"
        fi
    elif ! pgrep -u "${TOR_USER}" tor >/dev/null 2>&1; then
        _monitor_alert "TOR" "Tor process not found — anonymity may be broken"
    fi
}

_monitor_check_firewall() {
    case "${FIREWALL_BACKEND}" in
        nftables)
            if ! nft list table inet anonmanager >/dev/null 2>&1; then
                _monitor_alert "FIREWALL" "nftables anonmanager table disappeared — killswitch inactive!"
            fi
            ;;
        iptables*|iptables)
            if ! iptables -L AM_OUTPUT >/dev/null 2>&1; then
                _monitor_alert "FIREWALL" "iptables AM_OUTPUT chain missing — killswitch inactive!"
            fi
            ;;
    esac
}

_monitor_check_dns() {
    if ! grep -q "^nameserver 127" /etc/resolv.conf 2>/dev/null; then
        _monitor_alert "DNS" "resolv.conf no longer points to 127.x.x.x — DNS leak risk!"
    fi
}

_monitor_check_ipv6() {
    local v6_status
    v6_status="$(timeout 1 sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '0')"
    if [[ "${v6_status}" == "0" ]]; then
        _monitor_alert "IPV6" "IPv6 was re-enabled — leak risk!"
    fi
}

_monitor_check_namespace() {
    if ! ip netns list 2>/dev/null | grep -q "^${NS_NAME}"; then
        _monitor_alert "NAMESPACE" "Network namespace '${NS_NAME}' has disappeared!"
    fi
}
