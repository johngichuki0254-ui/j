#!/usr/bin/env bash
# =============================================================================
# system/session_log.sh — Structured anonymity session history
#
# Every Enable/Disable cycle writes a session record to:
#   /etc/anonmanager/sessions/YYYY-MM-DD_HH-MM-SS_<mode>.log
#
# Each record is a simple key=value file (same safe-parse pattern as state.sh).
# Never stores web content, URLs, or anything traffic-related.
# Stores: timestamps, mode, exit IP, identity, duration, check results.
#
# Public API:
#   session_start <mode>          — call at Enable
#   session_end                   — call at Disable
#   session_record_exit_ip <ip>   — call after Tor connects
#   session_record_identity       — call after identity_apply
#   show_session_history [N]      — display last N sessions (default 10)
#   session_purge [days]          — delete sessions older than N days
# =============================================================================

readonly _SESSION_CURRENT="${AM_CONFIG_DIR}/current_session"

# =============================================================================
# SESSION LIFECYCLE
# =============================================================================

session_start() {
    local mode="${1:-unknown}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local ts_file
    ts_file="$(date '+%Y-%m-%d_%H-%M-%S')"

    mkdir -p "${AM_SESSIONS_DIR}"
    chmod 700 "${AM_SESSIONS_DIR}"

    # Write current session descriptor — overwritten on next start
    cat > "${_SESSION_CURRENT}" << EOF
session_id=${ts_file}_${mode}
mode=${mode//[^a-z]/}
start_time=${ts}
start_epoch=$(date '+%s')
exit_ip=unknown
identity_location=none
identity_persona=none
dns_leak_result=pending
end_time=
end_epoch=
duration_seconds=
EOF
    chmod 600 "${_SESSION_CURRENT}"
    log "INFO" "Session started: mode=${mode}"
    security_log "SESSION" "Session started (mode=${mode})"
}

session_record_exit_ip() {
    local ip="${1:-unknown}"
    # Validate — only dotted-decimal IPv4 or IPv6
    ip="$(echo "${ip}" | grep -oE '^[0-9a-fA-F.:]{7,45}$' || echo 'unknown')"
    [[ -f "${_SESSION_CURRENT}" ]] || return 0
    _session_set_field "exit_ip" "${ip}"
    log "INFO" "Session exit IP recorded: ${ip}"
}

session_record_identity() {
    [[ -f "${_SESSION_CURRENT}" ]] || return 0
    local loc persona
    loc="$(prefs_get last_location 2>/dev/null || echo 'none')"
    persona="$(prefs_get last_persona 2>/dev/null || echo 'none')"
    _session_set_field "identity_location" "${loc//[^a-z_]/}"
    _session_set_field "identity_persona"  "${persona//[^a-z_]/}"
}

session_record_dns_result() {
    local result="${1:-unknown}"
    [[ -f "${_SESSION_CURRENT}" ]] || return 0
    case "${result}" in
        0) _session_set_field "dns_leak_result" "clean" ;;
        1) _session_set_field "dns_leak_result" "LEAK" ;;
        *) _session_set_field "dns_leak_result" "inconclusive" ;;
    esac
}

session_end() {
    [[ -f "${_SESSION_CURRENT}" ]] || return 0

    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local epoch
    epoch="$(date '+%s')"

    # Read start epoch for duration calculation
    local start_epoch=0
    while IFS='=' read -r k v || [[ -n "${k}" ]]; do
        [[ "${k}" =~ ^start_epoch ]] && start_epoch="${v//[^0-9]/}"
    done < "${_SESSION_CURRENT}"

    local duration=$(( epoch - start_epoch ))

    _session_set_field "end_time"        "${ts}"
    _session_set_field "end_epoch"       "${epoch}"
    _session_set_field "duration_seconds" "${duration}"

    # Read session_id for archive filename
    local session_id
    session_id="$(grep '^session_id=' "${_SESSION_CURRENT}" \
        | cut -d= -f2 | tr -cd 'a-zA-Z0-9_-' | head -c 64)"
    [[ -z "${session_id}" ]] && session_id="$(date '+%Y-%m-%d_%H-%M-%S')_unknown"

    # Archive to sessions dir
    cp "${_SESSION_CURRENT}" "${AM_SESSIONS_DIR}/${session_id}.log"
    chmod 600 "${AM_SESSIONS_DIR}/${session_id}.log"
    rm -f "${_SESSION_CURRENT}"

    log "INFO" "Session ended: duration=${duration}s"
    security_log "SESSION" "Session ended (duration=${duration}s)"
}

# =============================================================================
# DISPLAY HISTORY
# =============================================================================

show_session_history() {
    local limit="${1:-10}"
    limit="${limit//[^0-9]/}"
    [[ -z "${limit}" || "${limit}" -eq 0 ]] && limit=10

    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 58); echo ""
    printf "  %-54s\n" "SESSION HISTORY — Last ${limit} sessions"
    printf '═%.0s' $(seq 1 58)
    echo -e "${NC}\n"

    if [[ ! -d "${AM_SESSIONS_DIR}" ]]; then
        echo -e "  ${DIM}No session history yet.${NC}\n"
        return 0
    fi

    local sessions=()
    while IFS= read -r f; do
        sessions+=("${f}")
    done < <(ls -t "${AM_SESSIONS_DIR}"/*.log 2>/dev/null | head -"${limit}")

    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo -e "  ${DIM}No session history yet.${NC}\n"
        return 0
    fi

    local total="${#sessions[@]}"
    echo -e "  Showing ${total} session(s). Newest first.\n"

    printf "  ${BOLD}%-20s %-10s %-18s %-15s %-8s${NC}\n" \
        "START TIME" "MODE" "EXIT IP" "LOCATION" "DURATION"
    printf "  ${DIM}%-20s %-10s %-18s %-15s %-8s${NC}\n" \
        "--------------------" "----------" "------------------" \
        "---------------" "--------"

    local count=0
    for f in "${sessions[@]}"; do
        [[ -f "${f}" ]] || continue
        local start_time="" mode="" exit_ip="" loc="" dur="" dns_result=""
        while IFS='=' read -r k v || [[ -n "${k}" ]]; do
            k="${k// /}"; v="${v// /}"
            case "${k}" in
                start_time)          start_time="${v}" ;;
                mode)                mode="${v}" ;;
                exit_ip)             exit_ip="${v}" ;;
                identity_location)   loc="${v}" ;;
                duration_seconds)    dur="${v}" ;;
                dns_leak_result)     dns_result="${v}" ;;
            esac
        done < "${f}"

        # Format duration
        local dur_fmt="—"
        if [[ -n "${dur}" && "${dur}" =~ ^[0-9]+$ ]]; then
            local h=$(( dur / 3600 ))
            local m=$(( (dur % 3600) / 60 ))
            local s=$(( dur % 60 ))
            dur_fmt="$(printf '%dh %02dm %02ds' "${h}" "${m}" "${s}")"
            [[ "${h}" -eq 0 ]] && dur_fmt="$(printf '%dm %02ds' "${m}" "${s}")"
        fi

        # Mode color
        local mode_color="${NC}"
        case "${mode}" in
            extreme) mode_color="${RED}" ;;
            partial) mode_color="${YELLOW}" ;;
        esac

        # DNS indicator
        local dns_indicator=""
        case "${dns_result}" in
            clean)        dns_indicator=" ${GREEN}✓dns${NC}" ;;
            LEAK)         dns_indicator=" ${RED}✗DNS_LEAK${NC}" ;;
            inconclusive) dns_indicator=" ${YELLOW}?dns${NC}" ;;
        esac

        printf "  %-20s ${mode_color}%-10s${NC} %-18s %-15s %-8s%s\n" \
            "${start_time:0:19}" \
            "${mode:-unknown}" \
            "${exit_ip:-unknown}" \
            "${loc:-none}" \
            "${dur_fmt}" \
            "${dns_indicator}"

        ((count++)) || true
    done

    echo ""

    # Show stats
    _session_stats "${limit}"

    echo -e "\n  ${DIM}Sessions stored in: ${AM_SESSIONS_DIR}${NC}"
    echo ""
    read -r -p "$(echo -e "${CYAN}Press Enter to return...${NC}")" _
}

_session_stats() {
    local limit="${1}"
    local total_dur=0 count=0 leak_count=0

    for f in "${AM_SESSIONS_DIR}"/*.log; do
        [[ -f "${f}" ]] || continue
        local dur="" dns=""
        while IFS='=' read -r k v || [[ -n "${k}" ]]; do
            k="${k// /}"; v="${v// /}"
            case "${k}" in
                duration_seconds) dur="${v}" ;;
                dns_leak_result)  dns="${v}" ;;
            esac
        done < "${f}"
        [[ "${dur}" =~ ^[0-9]+$ ]] && (( total_dur += dur )) || true
        [[ "${dns}" == "LEAK" ]] && (( leak_count++ )) || true
        (( count++ )) || true
    done

    local avg=0
    [[ "${count}" -gt 0 ]] && avg=$(( total_dur / count ))
    local avg_m=$(( avg / 60 )) avg_s=$(( avg % 60 ))

    echo ""
    echo -e "  ${BOLD}Session statistics (all time):${NC}"
    printf "  %-28s %s\n" "Total sessions:" "${count}"
    printf "  %-28s %dm %02ds\n" "Average duration:" "${avg_m}" "${avg_s}"
    if [[ "${leak_count}" -gt 0 ]]; then
        printf "  %-28s ${RED}%d${NC}\n" "Sessions with DNS leaks:" "${leak_count}"
    else
        printf "  %-28s ${GREEN}%d${NC}\n" "Sessions with DNS leaks:" "0"
    fi
}

# =============================================================================
# MAINTENANCE
# =============================================================================

session_purge() {
    local days="${1:-90}"
    days="${days//[^0-9]/}"
    [[ -z "${days}" ]] && days=90

    [[ -d "${AM_SESSIONS_DIR}" ]] || return 0

    local count=0
    while IFS= read -r f; do
        rm -f "${f}"
        ((count++)) || true
    done < <(find "${AM_SESSIONS_DIR}" -name "*.log" -mtime "+${days}" 2>/dev/null)

    [[ "${count}" -gt 0 ]] && log "INFO" "Session purge: removed ${count} sessions older than ${days} days"
}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_session_set_field() {
    local key="${1}" val="${2}"
    [[ -f "${_SESSION_CURRENT}" ]] || return 0

    # Sanitize value — allow printable ASCII only, no newlines
    val="$(echo "${val}" | tr -cd '[:print:]' | head -c 128)"

    local tmp="${_SESSION_CURRENT}.tmp"
    if grep -q "^${key}=" "${_SESSION_CURRENT}" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${val}|" "${_SESSION_CURRENT}" > "${tmp}"
        mv "${tmp}" "${_SESSION_CURRENT}"
    else
        echo "${key}=${val}" >> "${_SESSION_CURRENT}"
    fi
}
