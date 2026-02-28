#!/usr/bin/env bash
# =============================================================================
# ui/menu.sh — Interactive menu with live HUD and backend transparency
# =============================================================================

show_main_menu() {
    if command -v dialog >/dev/null 2>&1 && is_interactive; then
        _menu_dialog
    elif command -v whiptail >/dev/null 2>&1 && is_interactive; then
        _menu_whiptail
    else
        _menu_text
    fi
}

# =============================================================================
# DIALOG MENU
# =============================================================================

_menu_dialog() {
    while true; do
        load_state

        local status_label
        if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
            status_label="● ACTIVE — ${CURRENT_MODE^^}"
        else
            status_label="○ INACTIVE"
        fi

        local choice
        choice=$(dialog --clear \
            --colors \
            --backtitle "AnonManager v${AM_VERSION}  |  ${status_label}  |  $(date '+%H:%M:%S')" \
            --title "[ Main Menu ]" \
            --menu "Select an action:" 22 68 12 \
            "1" "🔒  Enable Extreme Anonymity  (Whonix-style, all traffic)" \
            "2" "🛡  Enable Partial Anonymity  (browser only, tools work)" \
            "3" "🔓  Disable Anonymity         (restore system)" \
            ""  "────────────────────────────────────────────────────" \
            "4" "📊  Status Dashboard" \
            "5" "🔍  Verify Anonymity          (10-point check)" \
            "6" "🔄  Get New Tor Identity" \
            "7" "🔎  Backend Report            (what changed on system)" \
            "8" "📋  View Logs                 (live or static)" \
            ""  "────────────────────────────────────────────────────" \
            "9" "🚨  Emergency Restore" \
            "0" "Exit" \
            2>&1 >/dev/tty) || break

        clear
        case "${choice}" in
            1) enable_extreme_anonymity;           _pause ;;
            2) enable_partial_anonymity;           _pause ;;
            3) disable_anonymity;                  _pause ;;
            4) show_status_dashboard;              _pause ;;
            5) verify_anonymity_comprehensive;     _pause ;;
            6) get_new_tor_identity; echo ""; _pause ;;
            7) show_backend_report;                        ;;
            8) view_logs;                                  ;;
            9)
                dialog --yesno \
                    "Emergency restore will attempt to recover a broken system.\n\nThis will:\n  • Flush all anonmanager firewall rules\n  • Destroy the network namespace\n  • Restore DNS from backup\n  • Re-enable IPv6 if it was on\n\nContinue?" \
                    14 58
                if [[ $? -eq 0 ]]; then
                    clear
                    emergency_restore
                    _pause
                fi
                ;;
            0|"")
                load_state
                if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
                    dialog --yesno \
                        "⚠  Anonymity is still ACTIVE.\n\nExiting without disabling means:\n  • Killswitch remains active\n  • Your traffic is still routed through Tor\n  • System will NOT be restored\n\nExit anyway?" \
                        12 52
                    [[ $? -eq 0 ]] && break
                else
                    break
                fi
                ;;
        esac
    done
    clear
}

# =============================================================================
# WHIPTAIL MENU
# =============================================================================

_menu_whiptail() {
    while true; do
        load_state
        local status_label
        [[ "${ANONYMITY_ACTIVE}" == "true" ]] && \
            status_label="ACTIVE — ${CURRENT_MODE^^}" || \
            status_label="INACTIVE"

        local choice
        choice=$(whiptail --clear \
            --backtitle "AnonManager v${AM_VERSION}" \
            --title "Main Menu | ${status_label}" \
            --menu "Choose action:" 22 65 11 \
            "1" "Enable Extreme Anonymity (all traffic)" \
            "2" "Enable Partial Anonymity (browser only)" \
            "3" "Disable Anonymity / Restore System" \
            "4" "Status Dashboard" \
            "5" "Verify Anonymity (10-point check)" \
            "6" "New Tor Identity" \
            "7" "Backend Report (what changed)" \
            "8" "View Logs (live or static)" \
            "9" "Emergency Restore" \
            "0" "Exit" \
            3>&1 1>&2 2>&3) || break

        clear
        case "${choice}" in
            1) enable_extreme_anonymity;       _pause ;;
            2) enable_partial_anonymity;       _pause ;;
            3) disable_anonymity;              _pause ;;
            4) show_status_dashboard;          _pause ;;
            5) verify_anonymity_comprehensive; _pause ;;
            6) get_new_tor_identity; echo ""; _pause ;;
            7) show_backend_report;                    ;;
            8) view_logs;                              ;;
            9) emergency_restore;              _pause ;;
            0) break ;;
        esac
    done
    clear
}

# =============================================================================
# TEXT MENU (no dialog/whiptail)
# =============================================================================

_menu_text() {
    while true; do
        show_status_dashboard

        # Live HUD line
        show_hud

        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"

        if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
            echo -e "${GREEN}${BOLD}║  ${SYM_LOCK}  ANONYMITY IS ACTIVE — BE CAREFUL              ║${NC}"
        else
            echo -e "║                                                      ║"
        fi

        echo -e "${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}  1)${NC}  Enable Extreme Anonymity    ${DIM}(all traffic → Tor)${NC}"
        echo -e "${GREEN}  2)${NC}  Enable Partial Anonymity    ${DIM}(browser only)${NC}"
        echo -e "${YELLOW}  3)${NC}  Disable Anonymity           ${DIM}(restore system)${NC}"
        echo -e "${BOLD}  ────────────────────────────────────────────────────${NC}"
        echo -e "${CYAN}  4)${NC}  Verify Anonymity            ${DIM}(10-point check)${NC}"
        echo -e "${CYAN}  5)${NC}  Get New Tor Identity"
        echo -e "${CYAN}  6)${NC}  Backend Report              ${DIM}(what changed on system)${NC}"
        echo -e "${CYAN}  7)${NC}  View Logs                   ${DIM}(live or static)${NC}"
        echo -e "${BOLD}  ────────────────────────────────────────────────────${NC}"
        echo -e "${RED}  8)${NC}  Emergency Restore"
        echo -e "${RED}  0)${NC}  Exit"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -r -p "$(echo -e "  ${GREEN}Choose [0-8]: ${NC}")" choice
        echo ""

        case "${choice}" in
            1) enable_extreme_anonymity;       _pause ;;
            2) enable_partial_anonymity;       _pause ;;
            3) disable_anonymity;              _pause ;;
            4) verify_anonymity_comprehensive; _pause ;;
            5) get_new_tor_identity; echo ""; _pause ;;
            6) show_backend_report;                    ;;
            7) view_logs;                              ;;
            8)
                echo -e "${RED}${SYM_WARN} Emergency Restore${NC}"
                echo -e "${DIM}This will flush all firewall rules, destroy the namespace,"
                echo -e "restore DNS, and restart networking.${NC}"
                echo ""
                read -r -p "Type RESTORE to confirm, or Enter to cancel: " confirm
                if [[ "${confirm}" == "RESTORE" ]]; then
                    emergency_restore
                    _pause
                fi
                ;;
            0)
                load_state
                if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
                    echo -e "${YELLOW}${SYM_WARN} Anonymity is still ACTIVE.${NC}"
                    echo -e "${DIM}Exiting will NOT restore your system automatically.${NC}"
                    echo -e "${DIM}Use option 3 (Disable) to cleanly restore first.${NC}"
                    echo ""
                    read -r -p "Exit anyway? (y/N): " yn
                    [[ "${yn}" =~ ^[Yy]$ ]] || continue
                fi
                echo -e "${GREEN}Goodbye.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

_pause() {
    echo ""
    read -r -p "$(echo -e "${DIM}Press Enter to continue...${NC}")"
}
