#!/usr/bin/env bash
# =============================================================================
# ui/progress.sh — Real-time operation renderer
#
# Provides:
#   - Multi-step pipeline with PASS/FAIL/SKIP per step
#   - Live backend command echo (transparency)
#   - ETA calculation per step
#   - Async spinner for long waits
#   - Real-time Tor bootstrap progress bar
# =============================================================================

declare -g _PIPELINE_TOTAL=0
declare -g _PIPELINE_CURRENT=0
declare -g _PIPELINE_START_TS=0
declare -g _PIPELINE_NAME=""
declare -g SPINNER_PID=""

# =============================================================================
# PIPELINE LIFECYCLE
# =============================================================================

pipeline_start() {
    local name="${1}" total="${2}"
    _PIPELINE_NAME="${name}"
    _PIPELINE_TOTAL="${total}"
    _PIPELINE_CURRENT=0
    _PIPELINE_START_TS=$(date +%s)

    echo ""
    _draw_pipeline_header "${name}"
    echo ""
}

pipeline_step() {
    local label="${1}"
    ((_PIPELINE_CURRENT++)) || true

    local eta=""
    if [[ ${_PIPELINE_CURRENT} -gt 1 ]]; then
        local now elapsed per_step remaining
        now=$(date +%s)
        elapsed=$(( now - _PIPELINE_START_TS ))
        per_step=$(( elapsed / (_PIPELINE_CURRENT - 1) ))
        remaining=$(( per_step * (_PIPELINE_TOTAL - _PIPELINE_CURRENT + 1) ))
        [[ ${remaining} -gt 0 ]] && eta=" ${DIM}[~${remaining}s remaining]${NC}"
    fi

    printf "\n${CYAN}┌─[%02d/%02d]${NC} ${BOLD}%s${NC}%b\n" \
        "${_PIPELINE_CURRENT}" \
        "${_PIPELINE_TOTAL}" \
        "${label}" \
        "${eta}"
}

pipeline_step_ok()   { printf "${CYAN}└─${NC} ${GREEN}${SYM_CHECK} OK${NC}${1:+   ${DIM}${1}${NC}}\n"; }
pipeline_step_fail() { printf "${CYAN}└─${NC} ${RED}${SYM_CROSS} FAILED${NC}${1:+   ${RED}${1}${NC}}\n"; }
pipeline_step_warn() { printf "${CYAN}└─${NC} ${YELLOW}${SYM_WARN} WARNING${NC}${1:+   ${YELLOW}${1}${NC}}\n"; }
pipeline_step_skip() { printf "${CYAN}└─${NC} ${DIM}― SKIPPED${NC}${1:+   ${DIM}${1}${NC}}\n"; }

# Print an indented backend detail line inside the current step
pipeline_detail() {
    printf "  ${DIM}│  %s${NC}\n" "${1}"
}

# Run a command with live transparency — shows cmd description, captures output
# Usage: pipeline_cmd "description" cmd arg1 arg2
pipeline_cmd() {
    local desc="${1}"; shift
    printf "  ${DIM}│  ⟩ %s${NC}\n" "${desc}"

    local output exit_code=0
    output=$("$@" 2>&1) || exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        printf "  ${DIM}│    ${GREEN}✓ done${NC}\n"
    else
        printf "  ${DIM}│    ${RED}✗ exit %d${NC}\n" "${exit_code}"
        if [[ -n "${output}" ]]; then
            echo "${output}" | head -4 | while IFS= read -r line; do
                printf "  ${DIM}│    → %s${NC}\n" "${line}"
            done
        fi
    fi
    return ${exit_code}
}

pipeline_finish() {
    local elapsed=$(( $(date +%s) - _PIPELINE_START_TS ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    echo ""
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  ${BOLD}%s${NC} completed in ${GREEN}%dm %02ds${NC}\n" \
        "${_PIPELINE_NAME}" "${mins}" "${secs}"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo ""
}

# =============================================================================
# SPINNER
# =============================================================================

spinner_start() {
    local message="${1}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    (
        local i=0
        while true; do
            printf "\r  ${CYAN}%s${NC}  %s   " "${spin:${i}:1}" "${message}"
            i=$(( (i + 1) % 10 ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    local status="${1}" message="${2}"
    if [[ -n "${SPINNER_PID}" ]] && kill -0 "${SPINNER_PID}" 2>/dev/null; then
        kill "${SPINNER_PID}" 2>/dev/null || true
        wait "${SPINNER_PID}" 2>/dev/null || true
    fi
    SPINNER_PID=""
    case "${status}" in
        pass) printf "\r  ${GREEN}${SYM_CHECK}${NC}  %s\n" "${message}" ;;
        fail) printf "\r  ${RED}${SYM_CROSS}${NC}  %s\n" "${message}" ;;
        warn) printf "\r  ${YELLOW}${SYM_WARN}${NC}  %s\n" "${message}" ;;
    esac
}

# =============================================================================
# TOR BOOTSTRAP PROGRESS BAR
# Polls control port every 2s, draws live percentage bar
# =============================================================================

tor_bootstrap_progress() {
    local timeout="${1:-180}"
    local elapsed=0

    printf "\n  ${CYAN}${BOLD}Tor bootstrap:${NC}\n"

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local pct tag
        pct="$(_tor_bootstrap_pct)"
        tag="$(_tor_bootstrap_tag)"

        local filled=$(( pct / 2 ))
        local empty=$(( 50 - filled ))

        printf "\r  ["
        local i
        for (( i=0; i<filled; i++ )); do printf "${GREEN}█${NC}"; done
        for (( i=0; i<empty;  i++ )); do printf "${DIM}░${NC}"; done
        printf "] ${BOLD}%3d%%${NC}  ${DIM}%-20s${NC}  ${DIM}%3ds${NC}   " \
            "${pct}" "${tag}" "${elapsed}"

        if [[ "${pct}" -ge 100 ]]; then
            printf "\n  ${GREEN}${SYM_CHECK} Circuits established${NC}\n"
            return 0
        fi

        # Check Tor is still alive
        if ! tor_is_running 2>/dev/null; then
            printf "\n  ${RED}${SYM_CROSS} Tor process died${NC}\n"
            return 1
        fi

        sleep 2
        elapsed=$(( elapsed + 2 ))
    done

    printf "\n  ${RED}${SYM_CROSS} Bootstrap timed out after ${timeout}s${NC}\n"
    return 1
}

_tor_bootstrap_pct() {
    local cookie_path="${TOR_DATA_DIR}/control_auth_cookie"
    [[ -f "${cookie_path}" ]] || { echo "0"; return; }
    local cookie resp
    cookie="$(xxd -p -c 256 "${cookie_path}" 2>/dev/null || echo '')"
    [[ -z "${cookie}" ]] && { echo "0"; return; }
    resp="$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' \
        "${cookie}" | nc -w 3 "${NS_TOR_IP}" "${TOR_CONTROL_PORT}" 2>/dev/null || echo '')"
    echo "${resp}" | grep -oP 'PROGRESS=\K[0-9]+' | head -1 || echo "0"
}

_tor_bootstrap_tag() {
    local cookie_path="${TOR_DATA_DIR}/control_auth_cookie"
    [[ -f "${cookie_path}" ]] || { echo "waiting"; return; }
    local cookie resp
    cookie="$(xxd -p -c 256 "${cookie_path}" 2>/dev/null || echo '')"
    [[ -z "${cookie}" ]] && { echo "waiting"; return; }
    resp="$(printf 'AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' \
        "${cookie}" | nc -w 3 "${NS_TOR_IP}" "${TOR_CONTROL_PORT}" 2>/dev/null || echo '')"
    echo "${resp}" | grep -oP 'SUMMARY="\K[^"]+' | head -1 || echo "connecting"
}

# =============================================================================
# HELPERS
# =============================================================================

_draw_pipeline_header() {
    local title="  ${1}  "
    local width=54
    local tlen=${#title}
    local pad=$(( (width - tlen) / 2 ))
    local rpad=$(( width - tlen - pad ))

    printf "${CYAN}${BOLD}╔"
    printf '═%.0s' $(seq 1 ${width})
    printf "╗${NC}\n"

    printf "${CYAN}${BOLD}║${NC}%*s${BOLD}%s${NC}%*s${CYAN}${BOLD}║${NC}\n" \
        ${pad} "" "${title}" ${rpad} ""

    printf "${CYAN}${BOLD}╚"
    printf '═%.0s' $(seq 1 ${width})
    printf "╝${NC}\n"
}

# Legacy compat
show_progress() {
    local current="${1}" total="${2}" message="${3}"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 2 ))
    local empty=$(( 50 - filled ))
    printf "\r${CYAN}["
    for (( i=0; i<filled; i++ )); do printf "█"; done
    for (( i=0; i<empty;  i++ )); do printf "░"; done
    printf "]${NC} ${BOLD}%3d%%${NC} %s " "${pct}" "${message}"
}
