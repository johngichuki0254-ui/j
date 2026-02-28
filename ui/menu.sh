#!/usr/bin/env bash
# =============================================================================
# ui/menu.sh — Interactive menu with dialog/whiptail/text fallback
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

_get_status_label() {
    if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
        echo "ACTIVE — ${CURRENT_MODE^^}"
    else
        echo "INACTIVE"
    fi
}

_menu_dialog() {
    while true; do
        load_state
        local status_label
        status_label="$(_get_status_label)"

        local choice
        choice=$(dialog --clear \
            --backtitle "AnonManager v${AM_VERSION} | Status: ${status_label}" \
            --title "[ Main Menu ]" \
            --menu "Select an action:" 20 65 11 \
            1 "Enable Extreme Anonymity (Whonix-style)" \
            2 "Enable Partial Anonymity (balanced)" \
            3 "Disable Anonymity / Restore System" \
            4 "Status Dashboard" \
            5 "Verify Anonymity (10-point check)" \
            6 "Get New Tor Identity" \
            7 "View Logs" \
            8 "Emergency Restore" \
            0 "Exit" \
            2>&1 >/dev/tty) || break

        clear
        case "${choice}" in
            1) enable_extreme_anonymity; read -r -p "Press Enter..."  ;;
            2) enable_partial_anonymity; read -r -p "Press Enter..."  ;;
            3) disable_anonymity;        read -r -p "Press Enter..."  ;;
            4) show_status_dashboard;    read -r -p "Press Enter..."  ;;
            5) verify_anonymity_comprehensive; read -r -p "Press Enter..." ;;
            6) get_new_tor_identity;     echo ""; read -r -p "Press Enter..." ;;
            7) view_logs;                read -r -p "Press Enter..."  ;;
            8)
                dialog --yesno "Emergency restore will attempt to recover a broken system.\n\nContinue?" 8 55
                if [[ $? -eq 0 ]]; then
                    clear
                    emergency_restore
                    read -r -p "Press Enter..."
                fi
                ;;
            0|"")
                load_state
                if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
                    dialog --yesno "Anonymity is still ACTIVE.\n\nExit without disabling?" 8 45
                    [[ $? -eq 0 ]] && break
                else
                    break
                fi
                ;;
        esac
    done
    clear
}

_menu_whiptail() {
    while true; do
        load_state
        local status_label
        status_label="$(_get_status_label)"

        local choice
        choice=$(whiptail --clear \
            --backtitle "AnonManager v${AM_VERSION}" \
            --title "Main Menu | ${status_label}" \
            --menu "Choose action:" 20 65 9 \
            "1" "Enable Extreme Anonymity" \
            "2" "Enable Partial Anonymity" \
            "3" "Disable Anonymity" \
            "4" "Status Dashboard" \
            "5" "Verify Anonymity" \
            "6" "New Tor Identity" \
            "7" "View Logs" \
            "8" "Emergency Restore" \
            "0" "Exit" \
            3>&1 1>&2 2>&3) || break

        clear
        case "${choice}" in
            1) enable_extreme_anonymity; read -r -p "Press Enter..." ;;
            2) enable_partial_anonymity; read -r -p "Press Enter..." ;;
            3) disable_anonymity;        read -r -p "Press Enter..." ;;
            4) show_status_dashboard;    read -r -p "Press Enter..." ;;
            5) verify_anonymity_comprehensive; read -r -p "Press Enter..." ;;
            6) get_new_tor_identity;     echo ""; read -r -p "Press Enter..." ;;
            7) view_logs;                read -r -p "Press Enter..." ;;
            8) emergency_restore;        read -r -p "Press Enter..." ;;
            0) break ;;
        esac
    done
    clear
}

_menu_text() {
    while true; do
        show_status_dashboard

        echo -e "${BOLD}╔══════════════════ MAIN MENU ══════════════════╗${NC}"
        echo -e "${GREEN}  1)${NC} Enable Extreme Anonymity"
        echo -e "${GREEN}  2)${NC} Enable Partial Anonymity"
        echo -e "${GREEN}  3)${NC} Disable Anonymity"
        echo -e "${CYAN}  4)${NC} Verify Anonymity"
        echo -e "${CYAN}  5)${NC} Get New Tor Identity"
        echo -e "${CYAN}  6)${NC} View Logs"
        echo -e "${RED}  7)${NC} Emergency Restore"
        echo -e "${RED}  0)${NC} Exit"
        echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"
        echo ""
        read -r -p "$(echo -e "${GREEN}Choose [0-7]: ${NC}")" choice

        echo ""
        case "${choice}" in
            1) enable_extreme_anonymity; read -r -p "Press Enter..." ;;
            2) enable_partial_anonymity; read -r -p "Press Enter..." ;;
            3) disable_anonymity;        read -r -p "Press Enter..." ;;
            4) verify_anonymity_comprehensive; read -r -p "Press Enter..." ;;
            5) get_new_tor_identity;     echo ""; read -r -p "Press Enter..." ;;
            6) view_logs;                read -r -p "Press Enter..." ;;
            7)
                read -r -p "Type RESTORE to confirm: " confirm
                if [[ "${confirm}" == "RESTORE" ]]; then
                    emergency_restore
                    read -r -p "Press Enter..."
                fi
                ;;
            0)
                load_state
                if [[ "${ANONYMITY_ACTIVE}" == "true" ]]; then
                    echo -e "${YELLOW}${SYM_WARN} Anonymity still ACTIVE${NC}"
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
