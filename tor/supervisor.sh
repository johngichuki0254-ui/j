#!/usr/bin/env bash
# =============================================================================
# tor/supervisor.sh — Tor process supervisor for namespace mode
#
# systemd CANNOT manage a process inside a foreign network namespace,
# so we manage it ourselves. This module handles start/stop/restart
# and integrates with monitor.sh for watchdog restarts.
# =============================================================================

tor_start() {
    log "INFO" "Starting Tor inside namespace: ${NS_NAME}"

    # Kill any stale managed Tor process
    tor_stop 2>/dev/null || true

    # Also stop the system Tor service if running (prevent conflict)
    if systemctl is-active --quiet tor 2>/dev/null; then
        log "INFO" "Stopping system tor.service to avoid port conflict"
        systemctl stop tor 2>/dev/null || true
    fi

    # Remove stale lock file from previous run
    rm -f "${TOR_DATA_DIR}/lock" 2>/dev/null || true

    # Ensure data dir is owned correctly
    chown -R "${TOR_USER}:${TOR_USER}" "${TOR_DATA_DIR}" 2>/dev/null || true
    chmod 700 "${TOR_DATA_DIR}"

    # Launch Tor inside the namespace as TOR_USER
    # stdout/stderr go to our log file
    ip netns exec "${NS_NAME}" \
        sudo -u "${TOR_USER}" \
        tor -f /etc/tor/torrc \
        >> "${AM_LOG_FILE}" 2>&1 &

    local tor_pid=$!

    # Verify the process is still alive after 2 seconds
    sleep 2
    if ! kill -0 "${tor_pid}" 2>/dev/null; then
        log "ERROR" "Tor process died immediately after launch"
        return 1
    fi

    echo "${tor_pid}" > "${TOR_PID_FILE}"
    chmod 600 "${TOR_PID_FILE}"

    log "INFO" "Tor launched in namespace (PID: ${tor_pid})"
    return 0
}

tor_stop() {
    local pid=""

    if [[ -f "${TOR_PID_FILE}" ]]; then
        pid="$(cat "${TOR_PID_FILE}" 2>/dev/null || echo '')"
    fi

    # Also find any tor processes owned by TOR_USER as safety net
    local user_pids
    user_pids="$(pgrep -u "${TOR_USER}" tor 2>/dev/null || echo '')"

    for p in ${pid} ${user_pids}; do
        [[ -z "${p}" ]] && continue
        if kill -0 "${p}" 2>/dev/null; then
            kill -TERM "${p}" 2>/dev/null || true
        fi
    done

    # Wait up to 5 seconds for clean exit
    local waited=0
    while [[ ${waited} -lt 5 ]]; do
        if [[ -z "$(pgrep -u "${TOR_USER}" tor 2>/dev/null)" ]]; then
            break
        fi
        sleep 1
        ((waited++)) || true
    done

    # Force kill if still running
    pgrep -u "${TOR_USER}" tor 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true

    rm -f "${TOR_PID_FILE}"
    log "INFO" "Tor stopped"
}

tor_restart() {
    log "INFO" "Restarting Tor (new identity circuit)"
    tor_stop
    sleep 1
    tor_start
}

# Called by monitor.sh watchdog
tor_watchdog_restart() {
    local pid=""
    [[ -f "${TOR_PID_FILE}" ]] && pid="$(cat "${TOR_PID_FILE}" 2>/dev/null || echo '')"

    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        security_log "WATCHDOG" "Tor down — attempting supervised restart"
        if ns_exists; then
            tor_start && log "INFO" "Watchdog: Tor restarted successfully"
        else
            security_log "WATCHDOG" "Namespace gone — cannot restart Tor"
        fi
    fi
}

tor_is_running() {
    local pid=""
    [[ -f "${TOR_PID_FILE}" ]] && pid="$(cat "${TOR_PID_FILE}" 2>/dev/null || echo '')"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}
