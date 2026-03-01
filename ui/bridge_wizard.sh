#!/usr/bin/env bash
# =============================================================================
# ui/bridge_wizard.sh — Interactive bridge configuration wizard
#
# Provides a guided UI for:
#   1. Choosing transport type (obfs4, snowflake, meek, vanilla)
#   2. Adding bridge lines manually (paste from bridges.torproject.org)
#   3. Using built-in public bridges as a fallback
#   4. Viewing, testing, and removing existing bridges
#   5. Enabling/disabling bridges in the active Tor config
# =============================================================================

run_bridge_wizard() {
    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 58); echo ""
    printf "  %-54s\n" "BRIDGE CONFIGURATION"
    printf '═%.0s' $(seq 1 58)
    echo -e "${NC}\n"

    echo -e "${DIM}Bridges allow Tor to work in countries where it is blocked."
    echo -e "Pluggable transports disguise Tor traffic as innocent-looking HTTPS.${NC}\n"

    echo -e "${YELLOW}${BOLD}Transport types:${NC}"
    printf "  %-12s %s\n" "obfs4"     "Best choice: disguises traffic as random bytes"
    printf "  %-12s %s\n" "snowflake" "Uses WebRTC — hard to block, slower"
    printf "  %-12s %s\n" "meek"      "Uses CDNs (Azure/Amazon) — very hard to block, slower"
    printf "  %-12s %s\n" "vanilla"   "Plain Tor bridge — only helps if Tor IPs are blocked"
    echo ""

    # Show current status
    if bridges_are_enabled; then
        echo -e "  Status: ${GREEN}${BOLD}BRIDGES ENABLED${NC}"
    else
        echo -e "  Status: ${DIM}Bridges disabled (using direct Tor connection)${NC}"
    fi

    if bridges_have_any; then
        echo -e "  Configured bridges:"
        bridges_list
    else
        echo -e "  ${DIM}No bridges configured${NC}"
    fi
    echo ""

    if command -v dialog >/dev/null 2>&1; then
        _bridge_wizard_dialog
    else
        _bridge_wizard_text
    fi
}

_bridge_wizard_dialog() {
    local choice
    choice=$(dialog --clear \
        --backtitle "AnonManager — Bridge Configuration" \
        --title "[ Bridge Management ]" \
        --menu "Choose action:" 18 64 8 \
        "1" "Add bridges manually (paste from torproject.org)" \
        "2" "Use built-in obfs4 bridges (public, less private)" \
        "3" "Use built-in snowflake bridge" \
        "4" "Enable bridges in Tor config" \
        "5" "Disable bridges (use direct Tor)" \
        "6" "Test bridge connectivity" \
        "7" "Remove a bridge" \
        "8" "Clear all bridges" \
        2>&1 >/dev/tty)
    clear
    _bridge_dispatch "${choice}"
}

_bridge_wizard_text() {
    echo "  1) Add bridges manually"
    echo "  2) Use built-in obfs4 bridges (public, less private)"
    echo "  3) Use built-in snowflake bridge"
    echo "  4) Enable bridges in Tor config"
    echo "  5) Disable bridges"
    echo "  6) Test bridge connectivity"
    echo "  7) Remove a bridge"
    echo "  8) Clear all bridges"
    echo "  0) Back"
    echo ""
    read -r -p "$(echo -e "${CYAN}Choice: ${NC}")" choice
    _bridge_dispatch "${choice}"
}

_bridge_dispatch() {
    local choice="${1:-0}"
    case "${choice}" in
        1) _bridge_add_manual ;;
        2) bridges_use_builtin "obfs4" ;;
        3) bridges_use_builtin "snowflake" ;;
        4)
            bridges_enable
            prefs_save "bridges_enabled" "true" 2>/dev/null || true
            ;;
        5)
            bridges_disable
            prefs_save "bridges_enabled" "false" 2>/dev/null || true
            ;;
        6) bridges_test ;;
        7) _bridge_remove_interactive ;;
        8)
            read -r -p "$(echo -e "${RED}Clear ALL bridges? (y/N): ${NC}")" confirm
            [[ "${confirm}" =~ ^[Yy]$ ]] && bridges_clear
            ;;
        *) return 0 ;;
    esac
    echo ""
    read -r -p "$(echo -e "${DIM}Press Enter to continue...${NC}")" _
}

_bridge_add_manual() {
    clear
    echo -e "${CYAN}${BOLD}Add Bridge Lines${NC}\n"
    echo -e "${DIM}Get bridge lines from: https://bridges.torproject.org"
    echo -e "Choose obfs4 for best results."
    echo -e "Paste one bridge line at a time. Empty line to finish.${NC}\n"
    echo -e "Format: ${YELLOW}obfs4 <ip:port> <fingerprint> cert=<cert> iat-mode=0${NC}\n"

    local count=0
    while true; do
        read -r -p "$(echo -e "${CYAN}Bridge line (empty to finish): ${NC}")" line
        [[ -z "${line}" ]] && break
        if bridges_add "${line}"; then
            ((count++)) || true
        fi
    done

    echo -e "\n  ${GREEN}${SYM_CHECK} Added ${count} bridge(s)${NC}"
    if [[ "${count}" -gt 0 ]]; then
        read -r -p "$(echo -e "${CYAN}Enable bridges now? (Y/n): ${NC}")" enable_now
        if [[ ! "${enable_now}" =~ ^[Nn]$ ]]; then
            bridges_enable
        fi
    fi
}

_bridge_remove_interactive() {
    echo -e "\n${BOLD}Current bridges:${NC}"
    bridges_list

    if ! bridges_have_any; then
        return 0
    fi

    read -r -p "$(echo -e "${CYAN}Bridge number to remove (empty to cancel): ${NC}")" idx
    [[ -z "${idx}" ]] && return 0
    bridges_remove "${idx}"
}
