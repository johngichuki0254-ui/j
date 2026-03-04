#!/usr/bin/env bash
# =============================================================================
# system/auto_rotate.sh — Automatic Tor identity rotation
#
# Sends SIGNAL NEWNYM to Tor's control port every N minutes.
# Completely separate from the security watchdog (monitor.sh).
# Uses a dedicated PID file so it can be stopped independently.
#
# Default interval: 30 minutes (configurable, stored in user_prefs)
# Minimum interval: 5 minutes (enforced — shorter builds identifiable patterns)
# Maximum interval: 480 minutes (8 hours)
#
# Public API:
#   auto_rotate_start [interval_minutes]  — start the rotation daemon
#   auto_rotate_stop                      — stop it cleanly
#   auto_rotate_status                    — print current status + next rotation
#   auto_rotate_is_running                — silent check, returns 0/1
#   auto_rotate_now                       — force immediate rotation
# =============================================================================

readonly _ROTATE_MIN_INTERVAL=5
readonly _ROTATE_MAX_INTERVAL=480
readonly _ROTATE_DEFAULT_INTERVAL=30
readonly _ROTATE_NEXT_FILE="${AM_CONFIG_DIR}/rotate_next"

auto_rotate_start() {
    local interval="${1:-}"

    # Load from prefs if not given
    if [[ -z "${interval}" ]]; then
        interval="$(prefs_get rotate_interval 2>/dev/null || echo '')"
        [[ -z "${interval}" ]] && interval="${_ROTATE_DEFAULT_INTERVAL}"
    fi

    # Enforce bounds
    interval="${interval//[^0-9]/}"
    [[ -z "${interval}" ]] && interval="${_ROTATE_DEFAULT_INTERVAL}"
    [[ "${interval}" -lt "${_ROTATE_MIN_INTERVAL}" ]]  && interval="${_ROTATE_MIN_INTERVAL}"
    [[ "${interval}" -gt "${_ROTATE_MAX_INTERVAL}" ]]  && interval="${_ROTATE_MAX_INTERVAL}"

    # Stop existing instance
    auto_rotate_stop 2>/dev/null || true

    # Save preference
    prefs_save "rotate_interval" "${interval}" 2>/dev/null || true

    log "INFO" "Starting auto-rotate: interval=${interval}m"

    # Launch daemon in background
    (
        # Propagate SIGTERM/SIGINT to the whole process group so that the
        # sleep subprocess is also killed — prevents orphaned sleep processes.
        trap 'kill 0' TERM INT

        local interval_sec=$(( interval * 60 ))

        while true; do
            # Record next rotation time for status display
            local next_epoch=$(( $(date '+%s') + interval_sec ))
            printf '%s\n' "${next_epoch}" > "${_ROTATE_NEXT_FILE}" 2>/dev/null || true

            # Interruptible sleep: run in background + wait so signals propagate
            sleep "${interval_sec}" &
            wait $! 2>/dev/null || break   # break if woken by signal (TERM/INT)

            # Verify anonymity is still active before rotating
            local active="false"
            if [[ -f "${AM_STATE_FILE}" ]]; then
                active="$(grep '^ANONYMITY_ACTIVE=' "${AM_STATE_FILE}" \
                    | cut -d= -f2 | tr -d '[:space:]' || echo 'false')"
            fi

            if [[ "${active}" != "true" ]]; then
                rm -f "${_ROTATE_NEXT_FILE}"
                break
            fi

            # Send NEWNYM via control port
            _auto_rotate_send_newnym "auto"

        done
    ) &

    local pid=$!
    echo "${pid}" > "${AM_ROTATE_PID_FILE}"
    chmod 600 "${AM_ROTATE_PID_FILE}"

    security_log "AUTO_ROTATE" "Started: interval=${interval}m (PID=${pid})"
    echo -e "  ${GREEN}${SYM_CHECK} Auto-rotate started: new identity every ${interval} minutes${NC}"
    return 0
}

auto_rotate_stop() {
    local pid=""
    if [[ -f "${AM_ROTATE_PID_FILE}" ]]; then
        pid="$(cat "${AM_ROTATE_PID_FILE}" 2>/dev/null | tr -cd '0-9')"
    fi

    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null || true
        # Wait up to 3s for clean exit
        local waited=0
        while kill -0 "${pid}" 2>/dev/null && [[ "${waited}" -lt 3 ]]; do
            sleep 1; ((waited++)) || true
        done
        kill -9 "${pid}" 2>/dev/null || true
        log "INFO" "Auto-rotate stopped (PID=${pid})"
        security_log "AUTO_ROTATE" "Stopped (PID=${pid})"
    fi

    rm -f "${AM_ROTATE_PID_FILE}" "${_ROTATE_NEXT_FILE}"
}

auto_rotate_is_running() {
    [[ -f "${AM_ROTATE_PID_FILE}" ]] || return 1
    local pid
    pid="$(cat "${AM_ROTATE_PID_FILE}" 2>/dev/null | tr -cd '0-9')"
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

auto_rotate_status() {
    if auto_rotate_is_running; then
        local interval
        interval="$(prefs_get rotate_interval 2>/dev/null || echo "${_ROTATE_DEFAULT_INTERVAL}")"
        local next_epoch="" time_remaining=""

        if [[ -f "${_ROTATE_NEXT_FILE}" ]]; then
            next_epoch="$(cat "${_ROTATE_NEXT_FILE}" 2>/dev/null | tr -cd '0-9')"
            local now_epoch
            now_epoch="$(date '+%s')"
            if [[ -n "${next_epoch}" && "${next_epoch}" -gt "${now_epoch}" ]]; then
                local remaining=$(( next_epoch - now_epoch ))
                local rm=$(( remaining / 60 ))
                local rs=$(( remaining % 60 ))
                time_remaining="$(printf '%dm %02ds' "${rm}" "${rs}")"
            else
                time_remaining="imminent"
            fi
        fi

        echo -e "  ${GREEN}${SYM_CHECK} Auto-rotate: ACTIVE (interval: ${interval}m)"
        [[ -n "${time_remaining}" ]] && \
            echo -e "  ${DIM}Next rotation in: ${time_remaining}${NC}"
    else
        echo -e "  ${DIM}Auto-rotate: OFF${NC}"
    fi
}

auto_rotate_now() {
    echo -e "  ${CYAN}Requesting immediate new Tor identity...${NC}"
    _auto_rotate_send_newnym "manual"
}

# =============================================================================
# CONFIGURATION UI
# =============================================================================

auto_rotate_configure() {
    local current_interval
    current_interval="$(prefs_get rotate_interval 2>/dev/null || echo "${_ROTATE_DEFAULT_INTERVAL}")"
    local is_running=false
    auto_rotate_is_running && is_running=true

    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 56); echo ""
    printf "  %-52s\n" "AUTO-ROTATE CONFIGURATION"
    printf '═%.0s' $(seq 1 56)
    echo -e "${NC}\n"

    echo -e "  Current status: $(auto_rotate_is_running \
        && echo "${GREEN}RUNNING${NC}" || echo "${DIM}STOPPED${NC}")"
    echo -e "  Current interval: ${current_interval} minutes"
    echo ""
    echo -e "  ${DIM}Why this matters: Long-running Tor circuits can be fingerprinted."
    echo -e "  Regular identity rotation limits how long any single circuit is used."
    echo -e "  Minimum: ${_ROTATE_MIN_INTERVAL}m — Maximum: ${_ROTATE_MAX_INTERVAL}m${NC}"
    echo ""

    echo "  Options:"
    echo "    1) Start / change interval"
    echo "    2) Stop auto-rotate"
    echo "    3) Force rotate now"
    echo "    0) Back"
    echo ""
    read -r -p "$(echo -e "${CYAN}Choice: ${NC}")" choice

    case "${choice}" in
        1)
            read -r -p "$(echo -e "${CYAN}Interval in minutes [${_ROTATE_MIN_INTERVAL}-${_ROTATE_MAX_INTERVAL}, default ${current_interval}]: ${NC}")" new_interval
            [[ -z "${new_interval}" ]] && new_interval="${current_interval}"
            auto_rotate_start "${new_interval}"
            ;;
        2)
            auto_rotate_stop
            echo -e "  ${GREEN}${SYM_CHECK} Auto-rotate stopped${NC}"
            ;;
        3)
            auto_rotate_now
            ;;
        *) return 0 ;;
    esac
    echo ""
    read -r -p "$(echo -e "${DIM}Press Enter...${NC}")" _
}

# =============================================================================
# INTERNAL
# =============================================================================

_auto_rotate_send_newnym() {
    local trigger="${1:-auto}"
    local cookie_path="${TOR_DATA_DIR}/control_auth_cookie"

    if [[ ! -f "${cookie_path}" ]]; then
        log "WARN" "Auto-rotate: control cookie not found — cannot rotate"
        return 1
    fi

    local cookie
    cookie="$(xxd -p -c 256 "${cookie_path}" 2>/dev/null || echo '')"
    [[ -z "${cookie}" ]] && return 1

    local resp
    resp="$(printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "${cookie}" \
        | nc -w 3 "${NS_TOR_IP}" "${TOR_CONTROL_PORT}" 2>/dev/null || echo '')"

    # Tor returns "250 OK" for immediate rotation or "250 RATE_LIMITED" when the
    # request is queued (Tor enforces >= 10s between consecutive NEWNYMs).
    # Both are successful outcomes — RATE_LIMITED means Tor will rotate shortly.
    if echo "${resp}" | grep -qE "250 OK|250 RATE_LIMITED"; then
        if echo "${resp}" | grep -q "RATE_LIMITED"; then
            log "INFO" "Auto-rotate: NEWNYM queued (rate-limited — will fire in <10s)"
            security_log "AUTO_ROTATE" "NEWNYM queued/rate-limited (trigger=${trigger})"
        else
            log "INFO" "Auto-rotate: NEWNYM accepted (trigger=${trigger})"
            security_log "AUTO_ROTATE" "NEWNYM sent (trigger=${trigger})"
        fi
        # Tor requires at least 10 seconds to build new circuits after NEWNYM.
        # Waiting 15s gives new circuits time to establish before checking exit IP.
        sleep 15
        local new_ip
        new_ip="$(timeout 12 curl -s \
            --socks5-hostname "${NS_TOR_IP}:${TOR_SOCKS_PORT}" \
            "https://icanhazip.com" 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
        security_log "AUTO_ROTATE" "Exit IP after rotation: ${new_ip}"
        return 0
    else
        log "WARN" "Auto-rotate: NEWNYM failed (resp: ${resp:0:80})"
        return 1
    fi
}
