#!/usr/bin/env bash
# =============================================================================
# ui/identity_wizard.sh — Interactive identity/persona picker
#
# Three flows:
#   1. dialog (TUI) — full graphical menu
#   2. whiptail — same but simpler TUI
#   3. text — plain numbered list fallback
#
# Sets globals: _CHOSEN_LOCATION  _CHOSEN_PERSONA
# =============================================================================

declare -g _CHOSEN_LOCATION=""
declare -g _CHOSEN_PERSONA=""

# =============================================================================
# ENTRY POINT — called from menu or extreme mode setup
# =============================================================================

run_identity_wizard() {
    _CHOSEN_LOCATION=""
    _CHOSEN_PERSONA=""

    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 56); echo ""
    printf "  %-52s\n" "IDENTITY & LOCATION SETUP"
    printf '═%.0s' $(seq 1 56)
    echo -e "${NC}\n"

    echo -e "${DIM}This sets the country your Tor exit appears in,"
    echo -e "your system hostname, timezone, and User-Agent for CLI tools.${NC}\n"

    echo -e "${YELLOW}${BOLD}What this does:${NC}"
    echo -e "  ${GREEN}✓${NC}  Exit IP appears in chosen country"
    echo -e "  ${GREEN}✓${NC}  Hostname spoofed (e.g. MacBook-Pro-A1B2C3)"
    echo -e "  ${GREEN}✓${NC}  Timezone matches chosen country"
    echo -e "  ${GREEN}✓${NC}  curl/wget User-Agent matches chosen persona"
    echo -e "  ${RED}✗${NC}  Browser JS fingerprint is NOT changed"
    echo -e "  ${RED}✗${NC}  State-level Tor selection not possible (Tor is country-level)"
    echo ""

    # ── Show previous settings if they exist ──────────────────────────────
    local prev_loc prev_persona prev_vendor
    prev_loc="$(prefs_get last_location 2>/dev/null || echo "")"
    prev_persona="$(prefs_get last_persona 2>/dev/null || echo "")"
    prev_vendor="$(prefs_get last_mac_vendor 2>/dev/null || echo "")"

    if [[ -n "${prev_loc}" ]]; then
        local prev_display
        prev_display="$(_country_display_name "${prev_loc}" 2>/dev/null || echo "${prev_loc}")"
        echo -e "${CYAN}${BOLD}Your previous settings:${NC}"
        echo -e "  Location:  ${GREEN}${prev_display}${NC} (${prev_loc})"
        [[ -n "${prev_persona}" && "${prev_persona}" != "none" ]] && \
            echo -e "  Persona:   ${GREEN}${prev_persona}${NC}"
        [[ -n "${prev_vendor}" ]] && \
            echo -e "  MAC vendor:${GREEN} ${prev_vendor}${NC}"
        echo ""

        if is_interactive; then
            read -r -p "$(echo -e "${CYAN}Use previous settings? (Y/n): ${NC}")" use_prev
            if [[ ! "${use_prev}" =~ ^[Nn]$ ]]; then
                _CHOSEN_LOCATION="${prev_loc}"
                _CHOSEN_PERSONA="${prev_persona:-none}"
                echo -e "\n${GREEN}${SYM_CHECK} Previous settings loaded.${NC}\n"
                _wizard_confirm_previous
                return $?
            fi
        fi
        echo ""
    fi

    read -r -p "$(echo -e "${CYAN}Press Enter to continue or Ctrl+C to skip...${NC}")"

    # Step 1: Choose region → country/state
    if ! _wizard_choose_location; then
        echo -e "\n${YELLOW}Identity setup skipped.${NC}\n"
        return 1
    fi

    # Step 2: Choose OS persona
    _wizard_choose_persona

    # Step 3: Choose MAC vendor
    _wizard_choose_mac_vendor

    # Confirm
    _wizard_confirm

    return 0
}

# =============================================================================
# CONFIRM PREVIOUS SETTINGS (skip full wizard)
# =============================================================================

_wizard_confirm_previous() {
    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 56); echo ""
    printf "  %-52s\n" "CONFIRM PREVIOUS IDENTITY"
    printf '═%.0s' $(seq 1 56)
    echo -e "${NC}\n"

    local display
    display="$(_country_display_name "${_CHOSEN_LOCATION}" 2>/dev/null || echo "${_CHOSEN_LOCATION}")"
    printf "  %-24s %s\n" "Exit country:" "${display}"
    printf "  %-24s %s\n" "OS Persona:"   "${_CHOSEN_PERSONA:-none}"
    printf "  %-24s %s\n" "Tor ExitNodes:" "${_TOR_CC[${_CHOSEN_LOCATION}]:-{any}}"
    echo ""

    read -r -p "$(echo -e "${CYAN}Apply these settings? (Y/n): ${NC}")" confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then
        _CHOSEN_LOCATION=""
        _CHOSEN_PERSONA=""
        echo -e "\n${YELLOW}Cancelled — running full wizard instead.${NC}\n"
        sleep 1
        # Fall through to full wizard
        _wizard_choose_location || return 1
        _wizard_choose_persona
        _wizard_choose_mac_vendor
        _wizard_confirm
        return $?
    fi

    # Also ask for MAC vendor if not set
    local prev_vendor
    prev_vendor="$(prefs_get last_mac_vendor 2>/dev/null || echo "")"
    if [[ -z "${prev_vendor}" ]]; then
        _wizard_choose_mac_vendor
    else
        _CHOSEN_MAC_VENDOR="${prev_vendor}"
    fi

    return 0
}

# =============================================================================
# STEP 3 — MAC VENDOR
# =============================================================================

declare -g _CHOSEN_MAC_VENDOR="random"

_wizard_choose_mac_vendor() {
    local prev_vendor
    prev_vendor="$(prefs_get last_mac_vendor 2>/dev/null || echo "random")"

    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_MAC_VENDOR=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Step 3: MAC Address Vendor ]" \
            --menu "Choose MAC vendor prefix for your network interface.
Previous: ${prev_vendor}
(Only visible on your local network — not the internet)" 18 64 6 \
            "apple"    "Apple  — looks like a Mac to your router" \
            "samsung"  "Samsung — looks like a Samsung device" \
            "dell"     "Dell   — looks like a Dell laptop" \
            "lenovo"   "Lenovo — looks like a Lenovo laptop" \
            "random"   "Fully random (recommended for maximum anonymity)" \
            "preserve" "No change — keep current MAC" \
            2>&1 >/dev/tty)
    else
        _text_mac_vendor_picker "${prev_vendor}"
    fi
    clear
}

_text_mac_vendor_picker() {
    local prev="${1:-random}"
    echo -e "\n${CYAN}${BOLD}Choose MAC address vendor [previous: ${prev}]:${NC}\n"
    echo "  1) Apple   — looks like a Mac to your router"
    echo "  2) Samsung — looks like a Samsung device"
    echo "  3) Dell    — looks like a Dell laptop"
    echo "  4) Lenovo  — looks like a Lenovo laptop"
    echo "  5) Random  — fully random (recommended)"
    echo "  6) Preserve — no change"
    echo ""
    read -r -p "$(echo -e "${GREEN}Choose [1-6, default=5]: ${NC}")" n
    case "${n}" in
        1) _CHOSEN_MAC_VENDOR="apple"    ;;
        2) _CHOSEN_MAC_VENDOR="samsung"  ;;
        3) _CHOSEN_MAC_VENDOR="dell"     ;;
        4) _CHOSEN_MAC_VENDOR="lenovo"   ;;
        6) _CHOSEN_MAC_VENDOR="preserve" ;;
        *) _CHOSEN_MAC_VENDOR="random"   ;;
    esac
}

# =============================================================================
# STEP 1 — REGION → COUNTRY/STATE
# =============================================================================

_wizard_choose_location() {
    local region
    region="$(_pick_region)" || return 1

    case "${region}" in
        usa)    _pick_usa_state    ;;
        canada) _pick_canada       ;;
        europe) _pick_europe       ;;
        asia)   _pick_asia         ;;
        mideast)_pick_mideast      ;;
        africa) _pick_africa       ;;
        latam)  _pick_latam        ;;
        oceania)_pick_oceania      ;;
        any)    _CHOSEN_LOCATION=""; return 0 ;;
    esac
}

_pick_region() {
    if command -v dialog >/dev/null 2>&1; then
        dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Step 1: Choose Region ]" \
            --menu "Where should your exit IP appear?" 18 58 9 \
            "usa"     "United States (choose state)" \
            "canada"  "Canada (choose province)" \
            "europe"  "Europe" \
            "asia"    "Asia Pacific" \
            "mideast" "Middle East" \
            "africa"  "Africa" \
            "latam"   "Latin America" \
            "oceania" "Australia & New Zealand" \
            "any"     "Any country (Tor chooses)" \
            2>&1 >/dev/tty
    else
        _text_region_picker
    fi
}

# =============================================================================
# USA STATE PICKER
# =============================================================================

_pick_usa_state() {
    local items=(
        "us"    "Any US state"
        "us_al" "Alabama"       "us_ak" "Alaska"
        "us_az" "Arizona"       "us_ca" "California"
        "us_co" "Colorado"      "us_ct" "Connecticut"
        "us_dc" "Washington DC" "us_fl" "Florida"
        "us_ga" "Georgia"       "us_hi" "Hawaii"
        "us_il" "Illinois"      "us_in" "Indiana"
        "us_ia" "Iowa"          "us_ks" "Kansas"
        "us_ky" "Kentucky"      "us_la" "Louisiana"
        "us_me" "Maine"         "us_md" "Maryland"
        "us_ma" "Massachusetts" "us_mi" "Michigan"
        "us_mn" "Minnesota"     "us_ms" "Mississippi"
        "us_mo" "Missouri"      "us_mt" "Montana"
        "us_ne" "Nebraska"      "us_nv" "Nevada"
        "us_nh" "New Hampshire" "us_nj" "New Jersey"
        "us_nm" "New Mexico"    "us_ny" "New York"
        "us_nc" "North Carolina""us_nd" "North Dakota"
        "us_oh" "Ohio"          "us_ok" "Oklahoma"
        "us_or" "Oregon"        "us_pa" "Pennsylvania"
        "us_ri" "Rhode Island"  "us_sc" "South Carolina"
        "us_sd" "South Dakota"  "us_tn" "Tennessee"
        "us_tx" "Texas"         "us_ut" "Utah"
        "us_vt" "Vermont"       "us_va" "Virginia"
        "us_wa" "Washington"    "us_wv" "West Virginia"
        "us_wi" "Wisconsin"     "us_wy" "Wyoming"
    )

    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ United States — Choose State ]" \
            --menu "All states use {US} Tor exit nodes.\nTimezone and hostname match the state." \
            26 55 18 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "United States — Choose State" "${items[@]}"
    fi
}

# =============================================================================
# CANADA PICKER
# =============================================================================

_pick_canada() {
    local items=(
        "ca"    "Any Canadian province"
        "ca_bc" "British Columbia"
        "ca_ab" "Alberta"
        "ca_on" "Ontario"
        "ca_qc" "Quebec"
        "ca_ns" "Nova Scotia"
        "ca_mb" "Manitoba"
        "ca_sk" "Saskatchewan"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Canada — Choose Province ]" \
            --menu "" 16 50 8 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Canada — Choose Province" "${items[@]}"
    fi
}

# =============================================================================
# EUROPE PICKER
# =============================================================================

_pick_europe() {
    local items=(
        "gb"  "United Kingdom"  "gb_eng" "England, UK"
        "gb_sco" "Scotland, UK" "gb_wal" "Wales, UK"
        "fr"  "France"          "de"  "Germany"
        "nl"  "Netherlands"     "se"  "Sweden"
        "no"  "Norway"          "fi"  "Finland"
        "dk"  "Denmark"         "ch"  "Switzerland"
        "at"  "Austria"         "be"  "Belgium"
        "es"  "Spain"           "it"  "Italy"
        "pt"  "Portugal"        "ie"  "Ireland"
        "pl"  "Poland"          "cz"  "Czech Republic"
        "hu"  "Hungary"         "ro"  "Romania"
        "gr"  "Greece"          "hr"  "Croatia"
        "ua"  "Ukraine"         "bg"  "Bulgaria"
        "sk"  "Slovakia"        "lt"  "Lithuania"
        "lv"  "Latvia"          "ee"  "Estonia"
        "is"  "Iceland"         "lu"  "Luxembourg"
        "mt"  "Malta"           "cy"  "Cyprus"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Europe — Choose Country ]" \
            --menu "" 26 50 18 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Europe — Choose Country" "${items[@]}"
    fi
}

# =============================================================================
# ASIA PICKER
# =============================================================================

_pick_asia() {
    local items=(
        "jp"    "Japan"
        "sg"    "Singapore"       "hk"    "Hong Kong"
        "tw"    "Taiwan"          "kr"    "South Korea"
        "in"    "India (any)"     "in_mh" "Maharashtra, India"
        "in_dl" "Delhi, India"    "in_ka" "Karnataka, India"
        "my"    "Malaysia"        "id"    "Indonesia"
        "ph"    "Philippines"     "th"    "Thailand"
        "vn"    "Vietnam"         "pk"    "Pakistan"
        "bd"    "Bangladesh"      "lk"    "Sri Lanka"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Asia Pacific — Choose Country ]" \
            --menu "" 22 50 14 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Asia Pacific — Choose Country" "${items[@]}"
    fi
}

# =============================================================================
# MIDDLE EAST PICKER
# =============================================================================

_pick_mideast() {
    local items=(
        "ae" "UAE"          "sa" "Saudi Arabia"
        "il" "Israel"       "tr" "Turkey"
        "qa" "Qatar"        "kw" "Kuwait"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Middle East — Choose Country ]" \
            --menu "" 14 48 6 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Middle East — Choose Country" "${items[@]}"
    fi
}

# =============================================================================
# AFRICA PICKER
# =============================================================================

_pick_africa() {
    local items=(
        "za" "South Africa"  "ng" "Nigeria"
        "ke" "Kenya"         "eg" "Egypt"
        "gh" "Ghana"         "tz" "Tanzania"
        "ma" "Morocco"       "et" "Ethiopia"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Africa — Choose Country ]" \
            --menu "" 16 48 8 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Africa — Choose Country" "${items[@]}"
    fi
}

# =============================================================================
# LATIN AMERICA PICKER
# =============================================================================

_pick_latam() {
    local items=(
        "br"    "Brazil (any)"      "br_sp" "São Paulo, Brazil"
        "br_rj" "Rio de Janeiro"    "mx"    "Mexico"
        "ar"    "Argentina"         "cl"    "Chile"
        "co"    "Colombia"          "pe"    "Peru"
        "ve"    "Venezuela"         "ec"    "Ecuador"
        "uy"    "Uruguay"           "cr"    "Costa Rica"
        "pa"    "Panama"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Latin America — Choose Country ]" \
            --menu "" 20 52 12 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Latin America — Choose Country" "${items[@]}"
    fi
}

# =============================================================================
# OCEANIA PICKER
# =============================================================================

_pick_oceania() {
    local items=(
        "au"     "Australia (any)"
        "au_nsw" "New South Wales, Australia"
        "au_vic" "Victoria, Australia"
        "au_qld" "Queensland, Australia"
        "au_wa"  "Western Australia"
        "nz"     "New Zealand"
    )
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_LOCATION=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Oceania — Choose Location ]" \
            --menu "" 14 52 6 "${items[@]}" 2>&1 >/dev/tty)
    else
        _text_list_picker "Oceania — Choose Location" "${items[@]}"
    fi
}

# =============================================================================
# STEP 2 — PERSONA
# =============================================================================

_wizard_choose_persona() {
    if command -v dialog >/dev/null 2>&1; then
        _CHOSEN_PERSONA=$(dialog --clear \
            --backtitle "AnonManager — Identity Setup" \
            --title "[ Step 2: Choose OS Persona ]" \
            --menu "Affects curl/wget User-Agent only. NOT browsers." 18 64 8 \
            "macos_safari"   "macOS Ventura — Safari  (recommended for Mac persona)" \
            "macos_chrome"   "macOS Ventura — Chrome" \
            "windows_chrome" "Windows 11 — Chrome 120" \
            "windows_edge"   "Windows 11 — Edge 120" \
            "ubuntu_firefox" "Ubuntu Linux — Firefox 121" \
            "iphone_safari"  "iPhone 15 — Mobile Safari" \
            "android_chrome" "Android 14 — Chrome Mobile" \
            "none"           "No persona change" \
            2>&1 >/dev/tty)
    else
        _text_persona_picker
    fi
    clear
}

# =============================================================================
# STEP 3 — CONFIRM
# =============================================================================

_wizard_confirm() {
    clear
    echo -e "${CYAN}${BOLD}"
    printf '═%.0s' $(seq 1 56); echo ""
    printf "  %-52s\n" "IDENTITY SETUP — CONFIRM"
    printf '═%.0s' $(seq 1 56)
    echo -e "${NC}\n"

    local loc_display="Any (Tor chooses)"
    [[ -n "${_CHOSEN_LOCATION}" ]] && \
        loc_display="$(_country_display_name "${_CHOSEN_LOCATION}" 2>/dev/null \
                       || echo "${_CHOSEN_LOCATION}")"

    printf "  %-24s %s\n" "Exit country:" "${loc_display}"
    printf "  %-24s %s\n" "OS Persona:"   "${_CHOSEN_PERSONA:-none}"
    printf "  %-24s %s\n" "MAC vendor:"   "${_CHOSEN_MAC_VENDOR:-random}"

    if [[ -n "${_CHOSEN_LOCATION}" ]]; then
        local tor_cc="${_TOR_CC[${_CHOSEN_LOCATION}]:-unknown}"
        printf "  %-24s %s\n" "Tor ExitNodes:" "${tor_cc}"
        echo ""
        if [[ "${_CHOSEN_LOCATION}" =~ ^us_ ]]; then
            echo -e "  ${YELLOW}${BOLD}Note on US states:${NC}"
            echo -e "  ${YELLOW}Tor exits at country level ({US}), not state level.${NC}"
            echo -e "  ${YELLOW}Timezone + hostname will match ${loc_display}.${NC}"
            echo -e "  ${YELLOW}The IP will be from somewhere in the USA.${NC}"
        fi
    fi

    echo -e "\n  ${DIM}Settings will be remembered for next session.${NC}"
    echo ""
    read -r -p "$(echo -e "${CYAN}Apply this identity? (Y/n): ${NC}")" confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then
        _CHOSEN_LOCATION=""
        _CHOSEN_PERSONA=""
        _CHOSEN_MAC_VENDOR="random"
        echo -e "\n${YELLOW}Cancelled.${NC}\n"
        return 1
    fi

    # Save MAC vendor preference immediately on confirm
    prefs_save "last_mac_vendor" "${_CHOSEN_MAC_VENDOR:-random}" 2>/dev/null || true

    return 0
}

# =============================================================================
# TEXT FALLBACKS (no dialog/whiptail)
# =============================================================================

_text_region_picker() {
    echo -e "${CYAN}${BOLD}Choose region:${NC}\n"
    echo "  1) United States (with states)"
    echo "  2) Canada (with provinces)"
    echo "  3) Europe"
    echo "  4) Asia Pacific"
    echo "  5) Middle East"
    echo "  6) Africa"
    echo "  7) Latin America"
    echo "  8) Australia & New Zealand"
    echo "  9) Any (Tor chooses)"
    echo ""
    read -r -p "$(echo -e "${GREEN}Choose [1-9]: ${NC}")" n
    case "${n}" in
        1) echo "usa"     ;;
        2) echo "canada"  ;;
        3) echo "europe"  ;;
        4) echo "asia"    ;;
        5) echo "mideast" ;;
        6) echo "africa"  ;;
        7) echo "latam"   ;;
        8) echo "oceania" ;;
        *) echo "any"     ;;
    esac
}

# Generic text list picker
# Usage: _text_list_picker "Title" key1 "Label 1" key2 "Label 2" ...
_text_list_picker() {
    local title="${1}"; shift
    local keys=() labels=()

    # Parse alternating key/label pairs
    while [[ $# -ge 2 ]]; do
        keys+=("${1}"); labels+=("${2}"); shift 2
    done

    echo -e "\n${CYAN}${BOLD}${title}:${NC}\n"
    local i
    for (( i=0; i<${#keys[@]}; i++ )); do
        printf "  %3d) %s\n" $(( i + 1 )) "${labels[$i]}"
    done
    echo ""
    read -r -p "$(echo -e "${GREEN}Choose [1-${#keys[@]}]: ${NC}")" n
    if [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#keys[@]} )); then
        _CHOSEN_LOCATION="${keys[$(( n - 1 ))]}"
    else
        _CHOSEN_LOCATION=""
    fi
}

_text_persona_picker() {
    echo -e "\n${CYAN}${BOLD}Choose OS persona (curl/wget UA only — NOT browsers):${NC}\n"
    echo "  1) macOS Ventura — Safari  (recommended for Mac persona)"
    echo "  2) macOS Ventura — Chrome"
    echo "  3) Windows 11 — Chrome 120"
    echo "  4) Windows 11 — Edge 120"
    echo "  5) Ubuntu Linux — Firefox 121"
    echo "  6) iPhone 15 — Mobile Safari"
    echo "  7) Android 14 — Chrome Mobile"
    echo "  8) No persona"
    echo ""
    read -r -p "$(echo -e "${GREEN}Choose [1-8]: ${NC}")" n
    case "${n}" in
        1) _CHOSEN_PERSONA="macos_safari"   ;;
        2) _CHOSEN_PERSONA="macos_chrome"   ;;
        3) _CHOSEN_PERSONA="windows_chrome" ;;
        4) _CHOSEN_PERSONA="windows_edge"   ;;
        5) _CHOSEN_PERSONA="ubuntu_firefox" ;;
        6) _CHOSEN_PERSONA="iphone_safari"  ;;
        7) _CHOSEN_PERSONA="android_chrome" ;;
        *) _CHOSEN_PERSONA="none"           ;;
    esac
}
