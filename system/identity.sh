#!/usr/bin/env bash
# =============================================================================
# system/identity.sh — Country exit selection + OS persona management
#
# HONEST DOCUMENTATION — what this actually does vs does not do:
#
#   DOES:
#     - Sets Tor ExitNodes to a specific country → websites see that country's IP
#     - For USA: sets ExitNodes to specific US states via city-level selection
#     - Changes hostname to match chosen OS persona (local network only)
#     - Changes system timezone to match chosen country
#     - Sets User-Agent for curl/wget (CLI tools only)
#     - Randomizes MAC with matching vendor prefix (Apple, Dell, etc.)
#
#   DOES NOT:
#     - Fool browser JavaScript fingerprinting (canvas, WebGL, fonts, navigator.platform)
#     - Hide from IP-to-country databases that Tor exit is a Tor exit
#     - Make non-Tor-Browser browsers report correct OS in JS
# =============================================================================

# =============================================================================
# COUNTRY DATABASE
# Format: [cc]="Display Name|Timezone|Hostname prefix"
# For USA states: [us_XX]="State, USA|Timezone|Hostname prefix"
# =============================================================================

declare -grA _COUNTRY_DB=(
    # ── USA (with states) ──────────────────────────────────────────────────
    [us]="United States (any state)|America/New_York|MacBook-Pro"
    [us_al]="Alabama, USA|America/Chicago|MacBook-Pro"
    [us_ak]="Alaska, USA|America/Anchorage|MacBook-Air"
    [us_ar]="Arkansas, USA|America/Chicago|MacBook-Pro"
    [us_az]="Arizona, USA|America/Phoenix|MacBook-Pro"
    [us_ca]="California, USA|America/Los_Angeles|MacBook-Pro"
    [us_co]="Colorado, USA|America/Denver|MacBook-Air"
    [us_ct]="Connecticut, USA|America/New_York|MacBook-Pro"
    [us_dc]="Washington DC, USA|America/New_York|MacBook-Pro"
    [us_de]="Delaware, USA|America/New_York|MacBook-Air"
    [us_fl]="Florida, USA|America/New_York|MacBook-Air"
    [us_ga]="Georgia, USA|America/New_York|MacBook-Pro"
    [us_hi]="Hawaii, USA|Pacific/Honolulu|MacBook-Air"
    [us_id]="Idaho, USA|America/Denver|MacBook-Pro"
    [us_il]="Illinois, USA|America/Chicago|MacBook-Pro"
    [us_in]="Indiana, USA|America/Indiana/Indianapolis|MacBook-Air"
    [us_ia]="Iowa, USA|America/Chicago|MacBook-Pro"
    [us_ks]="Kansas, USA|America/Chicago|MacBook-Air"
    [us_ky]="Kentucky, USA|America/New_York|MacBook-Pro"
    [us_la]="Louisiana, USA|America/Chicago|MacBook-Air"
    [us_me]="Maine, USA|America/New_York|MacBook-Pro"
    [us_md]="Maryland, USA|America/New_York|MacBook-Air"
    [us_ma]="Massachusetts, USA|America/New_York|MacBook-Pro"
    [us_mi]="Michigan, USA|America/Detroit|MacBook-Air"
    [us_mn]="Minnesota, USA|America/Chicago|MacBook-Pro"
    [us_ms]="Mississippi, USA|America/Chicago|MacBook-Air"
    [us_mo]="Missouri, USA|America/Chicago|MacBook-Pro"
    [us_mt]="Montana, USA|America/Denver|MacBook-Air"
    [us_ne]="Nebraska, USA|America/Chicago|MacBook-Pro"
    [us_nv]="Nevada, USA|America/Los_Angeles|MacBook-Air"
    [us_nh]="New Hampshire, USA|America/New_York|MacBook-Pro"
    [us_nj]="New Jersey, USA|America/New_York|MacBook-Air"
    [us_nm]="New Mexico, USA|America/Denver|MacBook-Pro"
    [us_ny]="New York, USA|America/New_York|MacBook-Pro"
    [us_nc]="North Carolina, USA|America/New_York|MacBook-Air"
    [us_nd]="North Dakota, USA|America/Chicago|MacBook-Pro"
    [us_oh]="Ohio, USA|America/New_York|MacBook-Air"
    [us_ok]="Oklahoma, USA|America/Chicago|MacBook-Pro"
    [us_or]="Oregon, USA|America/Los_Angeles|MacBook-Air"
    [us_pa]="Pennsylvania, USA|America/New_York|MacBook-Pro"
    [us_ri]="Rhode Island, USA|America/New_York|MacBook-Air"
    [us_sc]="South Carolina, USA|America/New_York|MacBook-Pro"
    [us_sd]="South Dakota, USA|America/Chicago|MacBook-Air"
    [us_tn]="Tennessee, USA|America/Chicago|MacBook-Pro"
    [us_tx]="Texas, USA|America/Chicago|MacBook-Air"
    [us_ut]="Utah, USA|America/Denver|MacBook-Pro"
    [us_vt]="Vermont, USA|America/New_York|MacBook-Air"
    [us_va]="Virginia, USA|America/New_York|MacBook-Pro"
    [us_wa]="Washington State, USA|America/Los_Angeles|MacBook-Air"
    [us_wv]="West Virginia, USA|America/New_York|MacBook-Pro"
    [us_wi]="Wisconsin, USA|America/Chicago|MacBook-Air"
    [us_wy]="Wyoming, USA|America/Denver|MacBook-Pro"
    [us_dc]="Washington DC, USA|America/New_York|MacBook-Pro"

    # ── Canada ─────────────────────────────────────────────────────────────
    [ca]="Canada (any)|America/Toronto|MacBook-Pro"
    [ca_bc]="British Columbia, Canada|America/Vancouver|MacBook-Pro"
    [ca_ab]="Alberta, Canada|America/Edmonton|MacBook-Air"
    [ca_on]="Ontario, Canada|America/Toronto|MacBook-Pro"
    [ca_qc]="Quebec, Canada|America/Toronto|MacBook-Air"
    [ca_ns]="Nova Scotia, Canada|America/Halifax|MacBook-Pro"
    [ca_mb]="Manitoba, Canada|America/Winnipeg|MacBook-Air"
    [ca_sk]="Saskatchewan, Canada|America/Regina|MacBook-Pro"

    # ── Europe ─────────────────────────────────────────────────────────────
    [gb]="United Kingdom|Europe/London|MacBook-Pro"
    [gb_eng]="England, UK|Europe/London|MacBook-Pro"
    [gb_sco]="Scotland, UK|Europe/London|MacBook-Air"
    [gb_wal]="Wales, UK|Europe/London|MacBook-Pro"
    [fr]="France|Europe/Paris|MacBook-Air"
    [de]="Germany|Europe/Berlin|MacBook-Pro"
    [nl]="Netherlands|Europe/Amsterdam|MacBook-Air"
    [se]="Sweden|Europe/Stockholm|MacBook-Pro"
    [no]="Norway|Europe/Oslo|MacBook-Air"
    [fi]="Finland|Europe/Helsinki|MacBook-Pro"
    [dk]="Denmark|Europe/Copenhagen|MacBook-Air"
    [ch]="Switzerland|Europe/Zurich|Mac-Pro"
    [at]="Austria|Europe/Vienna|MacBook-Pro"
    [be]="Belgium|Europe/Brussels|MacBook-Air"
    [es]="Spain|Europe/Madrid|MacBook-Pro"
    [it]="Italy|Europe/Rome|MacBook-Air"
    [pt]="Portugal|Europe/Lisbon|MacBook-Pro"
    [pl]="Poland|Europe/Warsaw|MacBook-Air"
    [cz]="Czech Republic|Europe/Prague|MacBook-Pro"
    [hu]="Hungary|Europe/Budapest|MacBook-Air"
    [ro]="Romania|Europe/Bucharest|MacBook-Pro"
    [ie]="Ireland|Europe/Dublin|MacBook-Air"
    [gr]="Greece|Europe/Athens|MacBook-Pro"
    [hr]="Croatia|Europe/Zagreb|MacBook-Air"
    [ua]="Ukraine|Europe/Kiev|MacBook-Pro"
    [bg]="Bulgaria|Europe/Sofia|MacBook-Air"
    [sk]="Slovakia|Europe/Bratislava|MacBook-Pro"
    [lt]="Lithuania|Europe/Vilnius|MacBook-Air"
    [lv]="Latvia|Europe/Riga|MacBook-Pro"
    [ee]="Estonia|Europe/Tallinn|MacBook-Air"
    [is]="Iceland|Atlantic/Reykjavik|MacBook-Pro"
    [lu]="Luxembourg|Europe/Luxembourg|MacBook-Air"
    [mt]="Malta|Europe/Malta|MacBook-Pro"
    [cy]="Cyprus|Asia/Nicosia|MacBook-Air"

    # ── Asia-Pacific ────────────────────────────────────────────────────────
    [jp]="Japan|Asia/Tokyo|MacBook-Pro"
    [au]="Australia|Australia/Sydney|MacBook-Pro"
    [au_nsw]="New South Wales, Australia|Australia/Sydney|MacBook-Pro"
    [au_vic]="Victoria, Australia|Australia/Melbourne|MacBook-Air"
    [au_qld]="Queensland, Australia|Australia/Brisbane|MacBook-Pro"
    [au_wa]="Western Australia|Australia/Perth|MacBook-Air"
    [nz]="New Zealand|Pacific/Auckland|MacBook-Air"
    [sg]="Singapore|Asia/Singapore|Mac-Pro"
    [hk]="Hong Kong|Asia/Hong_Kong|MacBook-Pro"
    [tw]="Taiwan|Asia/Taipei|MacBook-Air"
    [kr]="South Korea|Asia/Seoul|MacBook-Pro"
    [in]="India|Asia/Kolkata|MacBook-Pro"
    [in_mh]="Maharashtra, India|Asia/Kolkata|MacBook-Pro"
    [in_dl]="Delhi, India|Asia/Kolkata|MacBook-Air"
    [in_ka]="Karnataka, India|Asia/Kolkata|MacBook-Pro"
    [my]="Malaysia|Asia/Kuala_Lumpur|MacBook-Air"
    [id]="Indonesia|Asia/Jakarta|MacBook-Pro"
    [ph]="Philippines|Asia/Manila|MacBook-Air"
    [th]="Thailand|Asia/Bangkok|MacBook-Pro"
    [vn]="Vietnam|Asia/Ho_Chi_Minh|MacBook-Air"
    [pk]="Pakistan|Asia/Karachi|MacBook-Pro"
    [bd]="Bangladesh|Asia/Dhaka|MacBook-Air"
    [lk]="Sri Lanka|Asia/Colombo|MacBook-Pro"

    # ── Middle East ─────────────────────────────────────────────────────────
    [ae]="United Arab Emirates|Asia/Dubai|MacBook-Pro"
    [sa]="Saudi Arabia|Asia/Riyadh|MacBook-Air"
    [il]="Israel|Asia/Jerusalem|MacBook-Pro"
    [tr]="Turkey|Europe/Istanbul|MacBook-Air"
    [qa]="Qatar|Asia/Qatar|MacBook-Pro"
    [kw]="Kuwait|Asia/Kuwait|MacBook-Air"

    # ── Africa ─────────────────────────────────────────────────────────────
    [za]="South Africa|Africa/Johannesburg|MacBook-Pro"
    [ng]="Nigeria|Africa/Lagos|MacBook-Air"
    [ke]="Kenya|Africa/Nairobi|MacBook-Pro"
    [eg]="Egypt|Africa/Cairo|MacBook-Air"
    [gh]="Ghana|Africa/Accra|MacBook-Pro"
    [tz]="Tanzania|Africa/Dar_es_Salaam|MacBook-Air"
    [ma]="Morocco|Africa/Casablanca|MacBook-Pro"
    [et]="Ethiopia|Africa/Addis_Ababa|MacBook-Air"

    # ── Latin America ───────────────────────────────────────────────────────
    [br]="Brazil|America/Sao_Paulo|MacBook-Air"
    [br_sp]="São Paulo, Brazil|America/Sao_Paulo|MacBook-Pro"
    [br_rj]="Rio de Janeiro, Brazil|America/Sao_Paulo|MacBook-Air"
    [mx]="Mexico|America/Mexico_City|MacBook-Pro"
    [ar]="Argentina|America/Argentina/Buenos_Aires|MacBook-Air"
    [cl]="Chile|America/Santiago|MacBook-Pro"
    [co]="Colombia|America/Bogota|MacBook-Air"
    [pe]="Peru|America/Lima|MacBook-Pro"
    [ve]="Venezuela|America/Caracas|MacBook-Air"
    [ec]="Ecuador|America/Guayaquil|MacBook-Pro"
    [uy]="Uruguay|America/Montevideo|MacBook-Air"
    [cr]="Costa Rica|America/Costa_Rica|MacBook-Pro"
    [pa]="Panama|America/Panama|MacBook-Air"
)

# Tor country codes — maps our extended keys to Tor's 2-letter ISO codes
# For USA states: Tor supports {US} only (not state-level, Tor doesn't do that)
# We set ExitNodes to {US} and rely on Tor's random selection within the country
declare -grA _TOR_CC=(
    [us]="{US}" [us_al]="{US}" [us_ak]="{US}" [us_ar]="{US}" [us_az]="{US}" [us_ca]="{US}"
    [us_co]="{US}" [us_ct]="{US}" [us_dc]="{US}" [us_de]="{US}" [us_fl]="{US}" [us_ga]="{US}"
    [us_hi]="{US}" [us_id]="{US}" [us_il]="{US}" [us_in]="{US}" [us_ia]="{US}" [us_ks]="{US}"
    [us_ky]="{US}" [us_la]="{US}" [us_me]="{US}" [us_md]="{US}" [us_ma]="{US}" [us_mi]="{US}"
    [us_la]="{US}" [us_me]="{US}" [us_md]="{US}" [us_ma]="{US}" [us_mi]="{US}"
    [us_mn]="{US}" [us_ms]="{US}" [us_mo]="{US}" [us_mt]="{US}" [us_ne]="{US}"
    [us_nv]="{US}" [us_nh]="{US}" [us_nj]="{US}" [us_nm]="{US}" [us_ny]="{US}"
    [us_nc]="{US}" [us_nd]="{US}" [us_oh]="{US}" [us_ok]="{US}" [us_or]="{US}"
    [us_pa]="{US}" [us_ri]="{US}" [us_sc]="{US}" [us_sd]="{US}" [us_tn]="{US}"
    [us_tx]="{US}" [us_ut]="{US}" [us_vt]="{US}" [us_va]="{US}" [us_wa]="{US}"
    [us_wv]="{US}" [us_wi]="{US}" [us_wy]="{US}" [us_dc]="{US}"
    [ca]="{CA}" [ca_bc]="{CA}" [ca_ab]="{CA}" [ca_on]="{CA}" [ca_qc]="{CA}"
    [ca_ns]="{CA}" [ca_mb]="{CA}" [ca_sk]="{CA}"
    [gb]="{GB}" [gb_eng]="{GB}" [gb_sco]="{GB}" [gb_wal]="{GB}"
    [fr]="{FR}" [de]="{DE}" [nl]="{NL}" [se]="{SE}" [no]="{NO}" [fi]="{FI}"
    [dk]="{DK}" [ch]="{CH}" [at]="{AT}" [be]="{BE}" [es]="{ES}" [it]="{IT}"
    [pt]="{PT}" [pl]="{PL}" [cz]="{CZ}" [hu]="{HU}" [ro]="{RO}" [ie]="{IE}"
    [gr]="{GR}" [hr]="{HR}" [ua]="{UA}" [bg]="{BG}" [sk]="{SK}" [lt]="{LT}"
    [lv]="{LV}" [ee]="{EE}" [is]="{IS}" [lu]="{LU}" [mt]="{MT}" [cy]="{CY}"
    [jp]="{JP}" [au]="{AU}" [au_nsw]="{AU}" [au_vic]="{AU}" [au_qld]="{AU}"
    [au_wa]="{AU}" [nz]="{NZ}" [sg]="{SG}" [hk]="{HK}" [tw]="{TW}"
    [kr]="{KR}" [in]="{IN}" [in_mh]="{IN}" [in_dl]="{IN}" [in_ka]="{IN}"
    [my]="{MY}" [id]="{ID}" [ph]="{PH}" [th]="{TH}" [vn]="{VN}"
    [pk]="{PK}" [bd]="{BD}" [lk]="{LK}"
    [ae]="{AE}" [sa]="{SA}" [il]="{IL}" [tr]="{TR}" [qa]="{QA}" [kw]="{KW}"
    [za]="{ZA}" [ng]="{NG}" [ke]="{KE}" [eg]="{EG}" [gh]="{GH}"
    [tz]="{TZ}" [ma]="{MA}" [et]="{ET}"
    [br]="{BR}" [br_sp]="{BR}" [br_rj]="{BR}" [mx]="{MX}" [ar]="{AR}"
    [cl]="{CL}" [co]="{CO}" [pe]="{PE}" [ve]="{VE}" [ec]="{EC}"
    [uy]="{UY}" [cr]="{CR}" [pa]="{PA}"
)

# OS Persona user-agents — for CLI tools only, NOT browsers
declare -grA _OS_PERSONAS=(
    [macos_safari]="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
    [macos_chrome]="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    [windows_chrome]="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    [windows_edge]="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
    [ubuntu_firefox]="Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
    [iphone_safari]="Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"
    [android_chrome]="Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36"
)

readonly _IDENTITY_STATE="${AM_CONFIG_DIR}/identity_state"

# =============================================================================
# PUBLIC API
# =============================================================================

identity_apply() {
    local key="${1:-}"       # e.g. "us_ny", "fr", "in"
    local persona="${2:-}"   # e.g. "macos_safari", "windows_chrome"

    [[ -z "${key}" ]] && return 0

    log "INFO" "Applying identity: location=${key} persona=${persona:-none}"
    _identity_backup

    _apply_exit_country "${key}"

    if [[ -n "${persona}" && "${persona}" != "none" ]]; then
        _apply_persona "${persona}" "${key}"
    fi

    # Save state — write safely, no shell evaluation on read
    printf 'location_key=%s\nos_persona=%s\n' "${key}" "${persona:-none}" \
        > "${_IDENTITY_STATE}"
    chmod 600 "${_IDENTITY_STATE}"

    # Persist as user preference so wizard pre-fills next time
    prefs_save \
        "last_location" "${key}" \
        "last_persona"  "${persona:-none}" 2>/dev/null || true

    security_log "IDENTITY" "Identity applied: location=${key} persona=${persona:-none}"
}

identity_restore() {
    log "INFO" "Restoring original identity"
    _restore_hostname
    _restore_timezone
    _restore_ua
    rm -f "${_IDENTITY_STATE}"
    security_log "IDENTITY" "Identity restored to original"
}

identity_is_active() {
    [[ -f "${_IDENTITY_STATE}" ]]
}

identity_summary() {
    [[ -f "${_IDENTITY_STATE}" ]] || { echo "none"; return; }
    local key persona
    key=$(grep    "^location_key=" "${_IDENTITY_STATE}" | cut -d= -f2)
    persona=$(grep "^os_persona="  "${_IDENTITY_STATE}" | cut -d= -f2)
    local display
    display="$(_country_display_name "${key}")"
    echo "${display} | persona: ${persona:-none}"
}

# =============================================================================
# EXIT COUNTRY
# =============================================================================

_apply_exit_country() {
    local key="${1}"
    local tor_cc="${_TOR_CC[${key}]:-}"

    if [[ -z "${tor_cc}" ]]; then
        log "WARN" "No Tor CC mapping for key '${key}' — using any exit"
        return 0
    fi

    log "INFO" "Setting Tor ExitNodes: ${tor_cc}"

    if [[ -f /etc/tor/torrc ]]; then
        # Remove any previous ExitNodes/StrictNodes lines
        sed -i '/^## Identity:/d' /etc/tor/torrc 2>/dev/null || true
        sed -i '/^ExitNodes /d'   /etc/tor/torrc 2>/dev/null || true
        sed -i '/^StrictNodes /d' /etc/tor/torrc 2>/dev/null || true

        cat >> /etc/tor/torrc << EOF

## Identity: exit country — managed by anonmanager
ExitNodes ${tor_cc}
StrictNodes 1
EOF
        log "INFO" "ExitNodes → ${tor_cc} ($(_country_display_name "${key}"))"
    else
        log "WARN" "torrc not found — ExitNodes will be applied on next tor_configure call"
    fi
}

# =============================================================================
# PERSONA — hostname + timezone + UA
# =============================================================================

_apply_persona() {
    local persona="${1}" key="${2}"

    local entry="${_COUNTRY_DB[${key}]:-}"
    local tz="" hostname_prefix="MacBook-Pro"

    if [[ -n "${entry}" ]]; then
        tz=$(echo "${entry}"             | cut -d'|' -f2)
        hostname_prefix=$(echo "${entry}" | cut -d'|' -f3)
    fi

    # Random suffix: 6 chars, uppercase alphanumeric
    local suffix
    suffix=$(tr -dc 'A-Z0-9' < /dev/urandom 2>/dev/null | head -c 6 \
             || printf '%06d' $((RANDOM % 999999)))

    _apply_hostname "${hostname_prefix}-${suffix}"
    [[ -n "${tz}" ]] && _apply_timezone "${tz}"
    _apply_ua "${persona}"
}

# =============================================================================
# HOSTNAME
# =============================================================================

_apply_hostname() {
    local new_hn="${1}"
    local orig_hn
    orig_hn=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "localhost")
    echo "${orig_hn}" > "${AM_CONFIG_DIR}/original_hostname"

    hostname "${new_hn}" 2>/dev/null || true
    echo "${new_hn}" > /etc/hostname

    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new_hn}/" /etc/hosts
    fi
    log "INFO" "Hostname: ${orig_hn} → ${new_hn}"
}

_restore_hostname() {
    local f="${AM_CONFIG_DIR}/original_hostname"
    [[ -f "${f}" ]] || return 0
    local orig
    orig=$(cat "${f}" 2>/dev/null || echo "localhost")
    hostname "${orig}" 2>/dev/null || true
    echo "${orig}" > /etc/hostname
    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${orig}/" /etc/hosts
    fi
    rm -f "${f}"
    log "INFO" "Hostname restored: ${orig}"
}

# =============================================================================
# TIMEZONE
# =============================================================================

_apply_timezone() {
    local tz="${1}"

    # Validate tz exists
    [[ -f "/usr/share/zoneinfo/${tz}" ]] || {
        log "WARN" "Timezone not found on this system: ${tz}"
        return 0
    }

    local orig_tz
    orig_tz=$(cat /etc/timezone 2>/dev/null \
              || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' \
              || echo "UTC")
    echo "${orig_tz}" > "${AM_CONFIG_DIR}/original_timezone"

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "${tz}" 2>/dev/null \
            && log "INFO" "Timezone → ${tz}" \
            || { ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
                 echo "${tz}" > /etc/timezone
                 log "INFO" "Timezone → ${tz} (symlink fallback)"; }
    else
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
        echo "${tz}" > /etc/timezone
        log "INFO" "Timezone → ${tz} (symlink)"
    fi
}

_restore_timezone() {
    local f="${AM_CONFIG_DIR}/original_timezone"
    [[ -f "${f}" ]] || return 0
    local orig
    orig=$(cat "${f}" 2>/dev/null || echo "UTC")
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "${orig}" 2>/dev/null || true
    elif [[ -f "/usr/share/zoneinfo/${orig}" ]]; then
        ln -sf "/usr/share/zoneinfo/${orig}" /etc/localtime
        echo "${orig}" > /etc/timezone
    fi
    rm -f "${f}"
    log "INFO" "Timezone restored: ${orig}"
}

# =============================================================================
# USER-AGENT (curl/wget only — browsers are not affected)
# =============================================================================

_apply_ua() {
    local persona="${1}"
    local ua="${_OS_PERSONAS[${persona}]:-}"
    [[ -z "${ua}" ]] && return 0

    # Backup existing curlrc/wgetrc
    [[ -f "${HOME}/.curlrc"  ]] && cp "${HOME}/.curlrc"  "${AM_CONFIG_DIR}/original_curlrc"  || true
    [[ -f "${HOME}/.wgetrc"  ]] && cp "${HOME}/.wgetrc"  "${AM_CONFIG_DIR}/original_wgetrc"  || true

    # Write — one line only, no shell expansion in the file
    printf 'user-agent = "%s"\n' "${ua}" > "${HOME}/.curlrc"
    printf 'user_agent = %s\n'   "${ua}" > "${HOME}/.wgetrc"

    log "INFO" "User-Agent set (curl/wget): ${persona}"
}

_restore_ua() {
    local cf="${AM_CONFIG_DIR}/original_curlrc"
    local wf="${AM_CONFIG_DIR}/original_wgetrc"

    if [[ -f "${cf}" ]]; then
        cp "${cf}" "${HOME}/.curlrc"; rm -f "${cf}"
    else
        sed -i '/^user-agent/d' "${HOME}/.curlrc" 2>/dev/null || true
    fi

    if [[ -f "${wf}" ]]; then
        cp "${wf}" "${HOME}/.wgetrc"; rm -f "${wf}"
    else
        sed -i '/^user_agent/d' "${HOME}/.wgetrc" 2>/dev/null || true
    fi

    log "INFO" "User-Agent restored"
}

# =============================================================================
# BACKUP
# =============================================================================

_identity_backup() {
    local d="${AM_BACKUP_DIR}/identity"
    mkdir -p "${d}"
    hostname 2>/dev/null > "${d}/hostname" \
        || cat /etc/hostname > "${d}/hostname" 2>/dev/null || true
    (cat /etc/timezone 2>/dev/null \
     || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' \
     || echo "UTC") > "${d}/timezone"
    grep "127.0.1.1" /etc/hosts > "${d}/hosts_line" 2>/dev/null || true
    [[ -f "${HOME}/.curlrc" ]] && cp "${HOME}/.curlrc" "${d}/curlrc" || true
    log "INFO" "Identity backup: ${d}"
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

_country_display_name() {
    local key="${1}"
    local entry="${_COUNTRY_DB[${key}]:-}"
    [[ -z "${entry}" ]] && echo "Unknown (${key})" && return
    echo "${entry}" | cut -d'|' -f1
}

# list_countries: prints sorted grouped table
list_countries() {
    echo ""
    printf "  ${CYAN}${BOLD}%-12s %s${NC}\n" "Code" "Location"
    printf "  ${DIM}%-12s %s${NC}\n"          "────" "────────"

    local prev_region=""
    for key in $(echo "${!_COUNTRY_DB[@]}" | tr ' ' '\n' | sort); do
        local name
        name=$(echo "${_COUNTRY_DB[$key]}" | cut -d'|' -f1)

        # Print region headers
        local region=""
        case "${key}" in
            us*)  region="── United States ─────────────────────" ;;
            ca*)  region="── Canada ────────────────────────────" ;;
            gb*)  region="── United Kingdom ────────────────────" ;;
            au*)  region="── Australia ────────────────────────" ;;
            br*)  region="── Brazil ───────────────────────────" ;;
            in*)  region="── India ────────────────────────────" ;;
        esac
        if [[ -n "${region}" && "${region}" != "${prev_region}" ]]; then
            echo -e "\n  ${CYAN}${DIM}${region}${NC}"
            prev_region="${region}"
        fi

        printf "  ${GREEN}%-12s${NC} %s\n" "${key}" "${name}"
    done
    echo ""
}

list_personas() {
    echo ""
    printf "  ${CYAN}${BOLD}%-20s %s${NC}\n" "Persona key" "Description"
    printf "  ${DIM}%-20s %s${NC}\n"          "───────────" "───────────"
    printf "  ${GREEN}%-20s${NC} %s\n" "macos_safari"   "macOS — Safari 17  (affects curl/wget only)"
    printf "  ${GREEN}%-20s${NC} %s\n" "macos_chrome"   "macOS — Chrome 120 (affects curl/wget only)"
    printf "  ${GREEN}%-20s${NC} %s\n" "windows_chrome" "Windows 11 — Chrome 120"
    printf "  ${GREEN}%-20s${NC} %s\n" "windows_edge"   "Windows 11 — Edge 120"
    printf "  ${GREEN}%-20s${NC} %s\n" "ubuntu_firefox" "Ubuntu Linux — Firefox 121"
    printf "  ${GREEN}%-20s${NC} %s\n" "iphone_safari"  "iPhone 15 — Mobile Safari"
    printf "  ${GREEN}%-20s${NC} %s\n" "android_chrome" "Android 14 Pixel — Chrome Mobile"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  Browsers are NOT affected by persona selection.${NC}"
    echo -e "  ${YELLOW}   Change User-Agent inside your browser settings.${NC}"
    echo -e "  ${YELLOW}   JS fingerprinting will still reveal real hardware.${NC}"
    echo ""
}
