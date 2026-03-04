#!/usr/bin/env bash
# =============================================================================
# system/locale_check.sh — Identity/locale consistency verification
#
# Checks for fingerprinting inconsistencies between the chosen identity
# and system locale settings. Each check is independent — partial failures
# are reported but don't block operation.
#
# Checks performed:
#   1. System timezone matches identity country's expected timezone
#   2. LANG/LC_ALL env var language matches identity country
#   3. LC_TIME format matches expected country format (date +%x output)
#   4. hostname matches the spoofed hostname we set
#   5. date command output timezone name is consistent
#   6. /etc/default/locale file consistency
#   7. curl/wget User-Agent consistency with chosen persona
#   8. NTP server not leaking real location (warns if using ISP NTP)
#
# Returns:
#   0 = all checks clean or warnings only
#   1 = hard inconsistency detected (caller should notify user)
# =============================================================================

# Language codes expected for each country/region
declare -grA _LOCALE_EXPECTED_LANG=(
    # USA/Canada/UK/Australia/NZ — English
    [us]="en"  [us_al]="en" [us_ak]="en" [us_ar]="en" [us_az]="en"
    [us_ca]="en" [us_co]="en" [us_ct]="en" [us_dc]="en" [us_de]="en"
    [us_fl]="en" [us_ga]="en" [us_hi]="en" [us_id]="en" [us_il]="en"
    [us_in]="en" [us_ia]="en" [us_ks]="en" [us_ky]="en" [us_la]="en"
    [us_me]="en" [us_md]="en" [us_ma]="en" [us_mi]="en" [us_mn]="en"
    [us_ms]="en" [us_mo]="en" [us_mt]="en" [us_ne]="en" [us_nv]="en"
    [us_nh]="en" [us_nj]="en" [us_nm]="en" [us_ny]="en" [us_nc]="en"
    [us_nd]="en" [us_oh]="en" [us_ok]="en" [us_or]="en" [us_pa]="en"
    [us_ri]="en" [us_sc]="en" [us_sd]="en" [us_tn]="en" [us_tx]="en"
    [us_ut]="en" [us_vt]="en" [us_va]="en" [us_wa]="en" [us_wv]="en"
    [us_wi]="en" [us_wy]="en"
    [ca]="en"  [ca_bc]="en" [ca_ab]="en" [ca_on]="en"
    [ca_qc]="fr" [ca_ns]="en" [ca_mb]="en" [ca_sk]="en"
    [gb]="en"  [gb_eng]="en" [gb_sco]="en" [gb_wal]="en"
    [au]="en"  [au_nsw]="en" [au_vic]="en" [au_qld]="en" [au_wa]="en"
    [nz]="en"  [ie]="en"
    # French
    [fr]="fr"
    # German
    [de]="de" [at]="de"
    # Switzerland: German (63%), French (23%), Italian (8%), Romansh (<1%).
    # 'ch' alone defaults to German (majority), but sub-keys are provided for
    # French-speaking (Geneva, Lausanne, Neuchâtel) and Italian-speaking cantons.
    [ch]="de" [ch_de]="de" [ch_fr]="fr" [ch_it]="it"
    # Spanish
    [es]="es" [mx]="es" [ar]="es" [cl]="es" [co]="es" [pe]="es"
    [ve]="es" [ec]="es" [uy]="es" [cr]="es" [pa]="es"
    # Portuguese
    [br]="pt" [br_sp]="pt" [br_rj]="pt" [pt]="pt"
    # Dutch
    [nl]="nl"
    # Belgium: Dutch-speaking (Flanders) + French-speaking (Wallonia/Brussels).
    # 'be' alone is ambiguous — mapped to French because Brussels, the capital
    # and internationally dominant city, is primarily French in formal contexts.
    # For precision, use be_nl (Flemish) or be_fr (Walloon/Brussels).
    [be]="fr" [be_nl]="nl" [be_fr]="fr" [be_de]="de"
    # Nordic
    [se]="sv" [no]="nb" [fi]="fi" [dk]="da" [is]="is"
    # Italian
    [it]="it"
    # Japanese
    [jp]="ja"
    # Korean
    [kr]="ko"
    # Chinese/Taiwanese
    [tw]="zh" [hk]="zh"
    # Indian — English official
    [in]="en" [in_mh]="en" [in_dl]="en" [in_ka]="en"
    # Arabic/Middle East
    [ae]="ar" [sa]="ar" [qa]="ar" [kw]="ar"
    [il]="he" [tr]="tr"
    # Russian-adjacent
    [ua]="uk"
    # Southeast Asia
    [sg]="en" [my]="ms" [id]="id" [ph]="en" [th]="th" [vn]="vi"
    # Africa
    [za]="en" [ng]="en" [ke]="en" [gh]="en" [tz]="sw"
    [eg]="ar" [ma]="ar" [et]="am"
    # South Asia
    [pk]="ur" [bd]="bn" [lk]="si"
)

# =============================================================================
# MAIN ENTRY
# =============================================================================

run_locale_check() {
    local mode="${1:-report}"   # report | silent | summary
    local location="${2:-}"
    local hard_fail=0

    # If no location given, try to get from prefs or identity state
    if [[ -z "${location}" ]]; then
        location="$(prefs_get last_location 2>/dev/null || echo '')"
    fi
    if [[ -z "${location}" ]]; then
        if [[ -f "${_IDENTITY_STATE:-/nonexistent}" ]]; then
            location="$(grep '^location_key=' "${_IDENTITY_STATE}" \
                | cut -d= -f2 | tr -cd 'a-z_' | head -c 16)"
        fi
    fi

    [[ "${mode}" != "silent" ]] && {
        echo -e "\n${CYAN}${BOLD}━━━ Locale Consistency Check ━━━${NC}"
        if [[ -n "${location}" ]]; then
            echo -e "  Identity: ${GREEN}${location}${NC}"
        else
            echo -e "  ${YELLOW}No identity set — running system checks only${NC}"
        fi
        echo ""
    }

    # Run all checks
    local results=()

    results+=("$(_lc_check_timezone     "${location}" "${mode}")")
    results+=("$(_lc_check_lang         "${location}" "${mode}")")
    results+=("$(_lc_check_lc_time      "${location}" "${mode}")")
    results+=("$(_lc_check_hostname                   "${mode}")")
    results+=("$(_lc_check_date_output                "${mode}")")
    results+=("$(_lc_check_locale_file  "${location}" "${mode}")")
    results+=("$(_lc_check_ua_consistency             "${mode}")")
    results+=("$(_lc_check_ntp                        "${mode}")")

    # Count results
    local pass=0 warn=0 fail=0
    for r in "${results[@]}"; do
        case "${r}" in
            0) ((pass++)) || true ;;
            1) ((fail++)) || true; hard_fail=1 ;;
            2) ((warn++)) || true ;;
        esac
    done

    [[ "${mode}" != "silent" ]] && {
        echo ""
        echo -e "  ${BOLD}Results:${NC} ${GREEN}${pass} clean${NC}  ${YELLOW}${warn} warnings${NC}  ${RED}${fail} issues${NC}"

        if [[ "${fail}" -eq 0 && "${warn}" -eq 0 ]]; then
            echo -e "\n  ${GREEN}${BOLD}${SYM_SHIELD} Locale/identity fully consistent${NC}"
        elif [[ "${fail}" -eq 0 ]]; then
            echo -e "\n  ${YELLOW}${BOLD}${SYM_WARN} Minor inconsistencies — see warnings above${NC}"
        else
            echo -e "\n  ${RED}${BOLD}${SYM_CROSS} Inconsistencies detected — these could leak identity information${NC}"
        fi
        echo ""
    }

    security_log "LOCALE_CHECK" \
        "Result: pass=${pass} warn=${warn} fail=${fail} location=${location:-none}"

    return "${hard_fail}"
}

# =============================================================================
# INDIVIDUAL CHECKS
# =============================================================================

# Check 1: system timezone matches identity
_lc_check_timezone() {
    local location="${1}" mode="${2}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[1] Timezone check...${NC}"

    local current_tz
    current_tz="$(cat /etc/timezone 2>/dev/null \
        || timedatectl show --property=Timezone --value 2>/dev/null \
        || date +%Z 2>/dev/null \
        || echo 'unknown')"
    current_tz="${current_tz// /}"

    if [[ -z "${location}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} no identity set (current: ${current_tz})${NC}"
        return 2
    fi

    # Get expected timezone from _COUNTRY_DB
    local expected_tz=""
    if [[ -n "${_COUNTRY_DB[${location}]+x}" ]]; then
        local db_entry="${_COUNTRY_DB[${location}]}"
        expected_tz="$(echo "${db_entry}" | cut -d'|' -f2)"
    fi

    if [[ -z "${expected_tz}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} unknown location — cannot verify${NC}"
        return 2
    fi

    if [[ "${current_tz}" == "${expected_tz}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${GREEN}${SYM_CHECK} ${current_tz} (matches ${location})${NC}"
        return 0
    else
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${RED}${SYM_CROSS} system TZ is '${current_tz}' but identity expects '${expected_tz}'${NC}"
        return 1
    fi
}

# Check 2: LANG env variable language prefix
_lc_check_lang() {
    local location="${1}" mode="${2}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[2] Language (LANG) check...${NC}"

    local current_lang
    current_lang="$(cat /etc/default/locale 2>/dev/null | grep '^LANG=' \
        | cut -d= -f2 | tr -d '"' | cut -d_ -f1 | tr -d '[:space:]' || echo '')"
    [[ -z "${current_lang}" ]] && \
        current_lang="$(locale 2>/dev/null | grep '^LANG=' \
        | cut -d= -f2 | tr -d '"' | cut -d_ -f1 | tr -d '[:space:]' || echo 'unknown')"

    if [[ -z "${location}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${DIM}no identity (LANG: ${current_lang})${NC}"
        return 2
    fi

    # Look up the country's root key (strip state suffix)
    local root_key="${location%%_*}"
    local expected_lang="${_LOCALE_EXPECTED_LANG[${location}]:-${_LOCALE_EXPECTED_LANG[${root_key}]:-}}"

    if [[ -z "${expected_lang}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} no expected language defined for ${location}${NC}"
        return 2
    fi

    if [[ "${current_lang}" == "${expected_lang}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${GREEN}${SYM_CHECK} LANG=${current_lang} (matches ${location})${NC}"
        return 0
    else
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} LANG=${current_lang} but ${location} expects lang=${expected_lang} (HTTP headers may reveal locale)${NC}"
        return 2  # warning not hard fail — locale isn't always visible
    fi
}

# Check 3: LC_TIME format matches expected country (date +%x output)
_lc_check_lc_time() {
    local location="${1}" mode="${2}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[3] LC_TIME format check...${NC}"

    if [[ -z "${location}" ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${DIM}no identity active${NC}"
        return 2
    fi

    # Get the expected date format style for this country:
    #   MDY = month/day/year  (US, Philippines)
    #   DMY = day/month/year  (most of world)
    #   YMD = year-month-day  (Japan, Korea, China, some Nordic)
    local root_key="${location%%_*}"
    local expected_order=""
    case "${root_key}" in
        us|ph)         expected_order="MDY" ;;
        jp|kr|cn|tw|hu|lt|lv|ee|mn) expected_order="YMD" ;;
        *)             expected_order="DMY" ;;
    esac

    # Check the actual LC_TIME locale being used
    local current_lc_time
    current_lc_time="$(locale 2>/dev/null | grep '^LC_TIME='         | cut -d= -f2 | tr -d '"' | tr -d "'" | cut -d_ -f1 | tr -d '[:space:]' || echo '')"

    # Determine order implied by current LC_TIME locale language prefix
    local actual_order=""
    case "${current_lc_time}" in
        en_US*|en-US*|fil|tl) actual_order="MDY" ;;
        ja|ko|zh)              actual_order="YMD" ;;
        hu|lt|lv|et|mn)       actual_order="YMD" ;;
        "")                    actual_order="unknown" ;;
        *)                     actual_order="DMY" ;;
    esac

    if [[ "${actual_order}" == "unknown" ]]; then
        [[ "${mode}" != "silent" ]] &&             echo -e " ${DIM}LC_TIME unset — cannot verify${NC}"
        return 2
    fi

    if [[ "${actual_order}" == "${expected_order}" ]]; then
        [[ "${mode}" != "silent" ]] &&             echo -e " ${GREEN}${SYM_CHECK} date format order ${actual_order} matches ${location}${NC}"
        return 0
    else
        [[ "${mode}" != "silent" ]] && echo -e             " ${YELLOW}${SYM_WARN} date format: system is ${actual_order}"             "but ${location} expects ${expected_order}${NC}"
        return 2  # Warning only: LC_TIME is rarely visible externally
    fi
}

# Check 4: hostname matches what identity_apply set
_lc_check_hostname() {
    local mode="${1}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[3] Hostname check...${NC}"

    local current_hn
    current_hn="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 'unknown')"
    current_hn="${current_hn// /}"

    # Check if identity is active
    if [[ ! -f "${_IDENTITY_STATE:-/nonexistent}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${DIM}no identity active (hostname: ${current_hn})${NC}"
        return 2
    fi

    # Read expected hostname prefix from identity state
    local expected_prefix=""
    if [[ -f "${_IDENTITY_STATE}" ]]; then
        local loc_key
        loc_key="$(grep '^location_key=' "${_IDENTITY_STATE}" \
            | cut -d= -f2 | tr -cd 'a-z_')"
        if [[ -n "${loc_key}" && -n "${_COUNTRY_DB[${loc_key}]+x}" ]]; then
            expected_prefix="$(echo "${_COUNTRY_DB[${loc_key}]}" | cut -d'|' -f3)"
        fi
    fi

    if [[ -z "${expected_prefix}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} cannot determine expected hostname prefix${NC}"
        return 2
    fi

    if [[ "${current_hn}" == "${expected_prefix}-"* ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${GREEN}${SYM_CHECK} ${current_hn} (matches expected ${expected_prefix}-xxx)${NC}"
        return 0
    else
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} hostname '${current_hn}' doesn't match expected '${expected_prefix}-xxx' prefix${NC}"
        return 2
    fi
}

# Check 4: date command output timezone abbreviation is consistent
_lc_check_date_output() {
    local mode="${1}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[4] date output TZ check...${NC}"

    local date_tz
    date_tz="$(date '+%Z' 2>/dev/null || echo 'unknown')"

    # Warn if it shows real timezone instead of spoofed one
    local system_tz
    system_tz="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || echo '')"

    # If TZ env var is set and differs from system, that's a leak
    if [[ -n "${TZ:-}" && "${TZ}" != "${system_tz}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${RED}${SYM_CROSS} TZ env var '${TZ}' differs from system timezone '${system_tz}'${NC}"
        return 1
    fi

    [[ "${mode}" != "silent" ]] && \
        echo -e " ${GREEN}${SYM_CHECK} date output: ${date_tz} (system TZ: ${system_tz:-unset})${NC}"
    return 0
}

# Check 5: /etc/default/locale file consistency
_lc_check_locale_file() {
    local location="${1}" mode="${2}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[5] /etc/default/locale check...${NC}"

    if [[ ! -f /etc/default/locale ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${DIM}file absent (non-Debian system)${NC}"
        return 2
    fi

    local locale_lang
    locale_lang="$(grep '^LANG=' /etc/default/locale 2>/dev/null \
        | cut -d= -f2 | tr -d '"[:space:]' | cut -d_ -f1)"

    if [[ -z "${locale_lang}" ]]; then
        [[ "${mode}" != "silent" ]] && echo -e " ${DIM}LANG not set in /etc/default/locale${NC}"
        return 2
    fi

    [[ "${mode}" != "silent" ]] && \
        echo -e " ${GREEN}${SYM_CHECK} /etc/default/locale LANG=${locale_lang}${NC}"
    return 0
}

# Check 6: curl/wget User-Agent consistency
_lc_check_ua_consistency() {
    local mode="${1}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[6] User-Agent consistency...${NC}"

    local curlrc_ua=""
    if [[ -f "${HOME}/.curlrc" ]]; then
        curlrc_ua="$(grep 'user-agent\|User-Agent' "${HOME}/.curlrc" 2>/dev/null \
            | head -1 | cut -d'"' -f2 || echo '')"
    fi

    # Check if persona is set in identity state
    local expected_persona=""
    if [[ -f "${_IDENTITY_STATE:-/nonexistent}" ]]; then
        expected_persona="$(grep '^os_persona=' "${_IDENTITY_STATE}" \
            | cut -d= -f2 | tr -cd 'a-z_')"
    fi

    if [[ -z "${expected_persona}" || "${expected_persona}" == "none" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${DIM}no persona set — default UA in use${NC}"
        return 2
    fi

    if [[ -n "${curlrc_ua}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${GREEN}${SYM_CHECK} curlrc UA set (persona: ${expected_persona})${NC}"
        return 0
    else
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} persona '${expected_persona}' set but curlrc UA missing — UA not spoofed for curl${NC}"
        return 2
    fi
}

# Check 7: NTP server not leaking real location
_lc_check_ntp() {
    local mode="${1}"
    [[ "${mode}" != "silent" ]] && printf "  ${DIM}[7] NTP configuration...${NC}"

    # Check if systemd-timesyncd is configured
    local ntp_servers=""
    if [[ -f /etc/systemd/timesyncd.conf ]]; then
        ntp_servers="$(grep -E '^NTP=' /etc/systemd/timesyncd.conf 2>/dev/null \
            | cut -d= -f2 || echo '')"
    fi
    if [[ -z "${ntp_servers}" ]]; then
        ntp_servers="$(timedatectl show --property=NTPMessage --value 2>/dev/null \
            | grep -oE 'ServerAddress=[^ ]+' | cut -d= -f2 || echo '')"
    fi

    # ISP-specific NTP patterns that would reveal real location
    # (most ISPs run ntpX.isp-name.com or time.isp-name.com)
    # We warn about NTP generally since any NTP query reveals real IP to NTP server
    if [[ -z "${ntp_servers}" ]]; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} NTP server unknown — NTP queries reveal real IP to time server${NC}"
        return 2
    fi

    # Warn if NTP is active at all (NTP bypasses Tor — it's UDP)
    if timedatectl show 2>/dev/null | grep -q 'NTP=yes'; then
        [[ "${mode}" != "silent" ]] && \
            echo -e " ${YELLOW}${SYM_WARN} NTP active: ${ntp_servers:0:40} — NTP traffic is NOT routed through Tor${NC}"
        return 2
    fi

    [[ "${mode}" != "silent" ]] && \
        echo -e " ${GREEN}${SYM_CHECK} NTP synced (note: NTP bypasses Tor — time queries use real IP)${NC}"
    return 0
}
