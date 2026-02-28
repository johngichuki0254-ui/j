#!/usr/bin/env bash
# =============================================================================
# ui/progress.sh — Terminal progress indicators
# =============================================================================

show_spinner() {
    local pid="${1}" message="${2}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "${pid}" 2>/dev/null; do
        local char="${spin:${i}:1}"
        printf "\r${CYAN}%s${NC} %s " "${char}" "${message}"
        i=$(( (i + 1) % 10 ))
        sleep 0.1
    done
    printf "\r${GREEN}${SYM_CHECK}${NC} %s\n" "${message}"
}

show_progress() {
    local current="${1}" total="${2}" message="${3}"
    local percent=$(( current * 100 / total ))
    local filled=$(( percent / 2 ))
    local empty=$(( 50 - filled ))

    printf "\r${CYAN}["
    printf '%0.s█' $(seq 1 ${filled})
    printf '%0.s ' $(seq 1 ${empty})
    printf "]${NC} %3d%% %s " "${percent}" "${message}"
}
