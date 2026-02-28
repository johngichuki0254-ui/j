#!/usr/bin/env bash
# =============================================================================
# system/backup.sh — Atomic, comprehensive system state snapshots
#
# Strategy:
#   1. Write entirely to <backup>.tmp/
#   2. Only rename to <backup>/ on 100% completion
#   3. Any partial backup is deleted on failure
#   4. Restore is symmetrically safe
# =============================================================================

readonly _INITIAL_BACKUP="${AM_BACKUP_DIR}/initial"

# =============================================================================
# ATOMIC BACKUP
# =============================================================================

backup_network_state() {
    local checkpoint="${1:-initial}"
    local dest="${AM_BACKUP_DIR}/${checkpoint}"
    local tmp="${dest}.tmp"

    # If initial backup already exists and is complete, skip
    if [[ "${checkpoint}" == "initial" && -d "${dest}" && -f "${dest}/.complete" ]]; then
        log "INFO" "Initial backup already exists — skipping"
        return 0
    fi

    log "INFO" "Creating backup: ${checkpoint}"

    # Clean any partial previous attempt
    rm -rf "${tmp}"
    mkdir -p "${tmp}"/{sysctl,nm,systemd,network,resolv}

    # --- Firewall ---
    _backup_firewall "${tmp}"

    # --- Sysctl (with timeout to prevent hangs) ---
    _backup_sysctl "${tmp}"

    # --- DNS / resolv.conf (symlink-aware) ---
    _backup_resolv "${tmp}"

    # --- Network state ---
    local iface
    iface="$(detect_interface 2>/dev/null || echo 'unknown')"
    echo "${iface}" > "${tmp}/interface"
    ip route show       > "${tmp}/network/routes4.txt"  2>/dev/null || true
    ip -6 route show    > "${tmp}/network/routes6.txt"  2>/dev/null || true
    ip addr show        > "${tmp}/network/addresses.txt" 2>/dev/null || true
    ip netns list       > "${tmp}/network/netns.txt"    2>/dev/null || true

    # --- NetworkManager active connection ---
    _backup_nm "${tmp}" "${iface}"

    # --- Systemd service states ---
    _backup_systemd_states "${tmp}"

    # --- Tor / proxychains configs ---
    [[ -f /etc/tor/torrc ]]          && cp -p /etc/tor/torrc          "${tmp}/torrc.original"
    [[ -f /etc/proxychains4.conf ]]  && cp -p /etc/proxychains4.conf  "${tmp}/proxychains4.conf"
    [[ -f /etc/proxychains.conf ]]   && cp -p /etc/proxychains.conf   "${tmp}/proxychains.conf"

    # --- Mark complete, then atomic rename ---
    touch "${tmp}/.complete"
    rm -rf "${dest}"
    mv "${tmp}" "${dest}"
    chmod -R 700 "${dest}"

    log "INFO" "Backup complete: ${checkpoint}"
}

_backup_firewall() {
    local dest="${1}"
    case "${FIREWALL_BACKEND}" in
        nftables)
            nft list ruleset > "${dest}/nftables.rules" 2>/dev/null || \
                echo "# empty" > "${dest}/nftables.rules"
            ;;
        iptables*|iptables)
            iptables-save  > "${dest}/iptables.rules"   2>/dev/null || true
            ip6tables-save > "${dest}/ip6tables.rules"  2>/dev/null || true
            ipset save     > "${dest}/ipset.rules"      2>/dev/null || true
            ;;
    esac
}

_backup_sysctl() {
    local dest="${1}"

    # Keys we specifically modify — back these up individually (with timeout)
    local keys=(
        "net.ipv6.conf.all.disable_ipv6"
        "net.ipv6.conf.default.disable_ipv6"
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.forwarding"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.icmp_echo_ignore_all"
        "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.conf.default.accept_redirects"
        "net.ipv4.conf.all.accept_source_route"
        "net.ipv4.conf.default.accept_source_route"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.default.rp_filter"
        "net.ipv4.tcp_syncookies"
        "net.ipv6.conf.all.accept_redirects"
        "net.ipv6.conf.default.accept_redirects"
        "net.ipv6.conf.all.accept_source_route"
        "net.ipv6.conf.all.accept_ra"
        "net.ipv6.conf.default.accept_ra"
        "net.ipv6.conf.all.autoconf"
        "net.ipv6.conf.default.autoconf"
        "kernel.kptr_restrict"
        "kernel.dmesg_restrict"
        "kernel.unprivileged_bpf_disabled"
        "net.core.bpf_jit_harden"
    )

    for key in "${keys[@]}"; do
        local safe_name="${key//\./_}"
        # timeout 2 per key to avoid hangs on restricted kernels
        timeout 2 sysctl -n "${key}" > "${dest}/sysctl/${safe_name}.val" 2>/dev/null || \
            echo "UNKNOWN" > "${dest}/sysctl/${safe_name}.val"
    done
}

_backup_resolv() {
    local dest="${1}"

    if [[ -L /etc/resolv.conf ]]; then
        # It's a symlink (systemd-resolved, NetworkManager, etc.)
        local real_path
        real_path="$(readlink -f /etc/resolv.conf 2>/dev/null || echo '')"
        echo "symlink"    > "${dest}/resolv/type"
        echo "${real_path}" > "${dest}/resolv/symlink_target"
        readlink /etc/resolv.conf > "${dest}/resolv/symlink_relative"
        if [[ -f "${real_path}" ]]; then
            cp -p "${real_path}" "${dest}/resolv/content"
        fi
    elif [[ -f /etc/resolv.conf ]]; then
        echo "file" > "${dest}/resolv/type"
        cp -p /etc/resolv.conf "${dest}/resolv/content"
        # Save chattr flags
        lsattr /etc/resolv.conf > "${dest}/resolv/lsattr" 2>/dev/null || true
    fi
}

_backup_nm() {
    local dest="${1}" iface="${2}"

    if ! command -v nmcli >/dev/null 2>&1; then return 0; fi
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then return 0; fi

    local active_uuid
    active_uuid="$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
        | grep ":${iface}$" | cut -d: -f1 | head -1 || echo '')"

    if [[ -n "${active_uuid}" ]]; then
        echo "${active_uuid}" > "${dest}/nm/active_uuid"
        nmcli connection show "${active_uuid}" > "${dest}/nm/active_details.txt" 2>/dev/null || true
    fi

    nmcli connection show > "${dest}/nm/connections.list" 2>/dev/null || true
}

_backup_systemd_states() {
    local dest="${1}"
    local services=("systemd-resolved" "tor" "NetworkManager")
    for svc in "${services[@]}"; do
        systemctl is-enabled "${svc}" > "${dest}/systemd/${svc}.enabled" 2>/dev/null || \
            echo "not-found" > "${dest}/systemd/${svc}.enabled"
        systemctl is-active "${svc}"  > "${dest}/systemd/${svc}.active"  2>/dev/null || \
            echo "inactive" > "${dest}/systemd/${svc}.active"
    done
}

# =============================================================================
# ATOMIC RESTORE
# =============================================================================

emergency_restore() {
    log "INFO" "=== EMERGENCY RESTORE INITIATED ==="
    security_log "RESTORE" "Emergency restore triggered"

    # Stop monitoring first so it doesn't re-alert during restore
    stop_monitoring 2>/dev/null || true

    # Kill our Tor instance (if running in namespace)
    _tor_kill_safe

    # Destroy namespace (kills any processes inside it)
    ns_destroy 2>/dev/null || true

    local src="${_INITIAL_BACKUP}"

    if [[ ! -d "${src}" || ! -f "${src}/.complete" ]]; then
        log "WARN" "No complete initial backup found — applying safe defaults"
        _restore_safe_defaults
        ANONYMITY_ACTIVE="false"
        CURRENT_MODE="none"
        save_state
        return 0
    fi

    # 1. Restore firewall
    _restore_firewall "${src}"

    # 2. Restore DNS
    _restore_resolv "${src}"

    # 3. Restore sysctl
    _restore_sysctl "${src}"

    # 4. Restore NM connection
    _restore_nm "${src}"

    # 5. Restore systemd service states
    _restore_systemd_states "${src}"

    # 6. Re-enable IPv6 if it was on
    local ipv6_was
    ipv6_was="$(cat "${src}/sysctl/net_ipv6_conf_all_disable_ipv6.val" 2>/dev/null || echo '0')"
    if [[ "${ipv6_was}" == "0" ]]; then
        ipv6_enable 2>/dev/null || true
    fi

    # 7. Restart networking
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 2
    fi

    ANONYMITY_ACTIVE="false"
    CURRENT_MODE="none"
    save_state

    log "INFO" "=== EMERGENCY RESTORE COMPLETE ==="
    echo -e "${GREEN}${SYM_CHECK} System restored to pre-anonymity state.${NC}"
}

_restore_firewall() {
    local src="${1}"
    case "${FIREWALL_BACKEND}" in
        nftables)
            if [[ -f "${src}/nftables.rules" ]]; then
                nft flush ruleset 2>/dev/null || true
                nft -f "${src}/nftables.rules" 2>/dev/null || log "WARN" "nft restore had errors"
            else
                nft flush ruleset 2>/dev/null || true
            fi
            ;;
        iptables*|iptables)
            if [[ -s "${src}/iptables.rules" ]]; then
                iptables-restore  < "${src}/iptables.rules"  2>/dev/null || \
                    log "WARN" "iptables restore failed — flushing to ACCEPT"
            fi
            if [[ -s "${src}/ip6tables.rules" ]]; then
                ip6tables-restore < "${src}/ip6tables.rules" 2>/dev/null || true
            else
                ip6tables -P INPUT   ACCEPT 2>/dev/null || true
                ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
                ip6tables -P FORWARD ACCEPT 2>/dev/null || true
                ip6tables -F 2>/dev/null || true
            fi
            if [[ -f "${src}/ipset.rules" ]]; then
                ipset restore < "${src}/ipset.rules" 2>/dev/null || true
            fi
            ;;
    esac
}

_restore_resolv() {
    local src="${1}"
    local rtype
    rtype="$(cat "${src}/resolv/type" 2>/dev/null || echo 'file')"

    # Always remove immutable flag first
    chattr -i /etc/resolv.conf 2>/dev/null || true

    case "${rtype}" in
        symlink)
            local rel_target
            rel_target="$(cat "${src}/resolv/symlink_relative" 2>/dev/null || echo '')"
            if [[ -n "${rel_target}" ]]; then
                rm -f /etc/resolv.conf
                ln -sf "${rel_target}" /etc/resolv.conf
            fi
            ;;
        file)
            if [[ -f "${src}/resolv/content" ]]; then
                rm -f /etc/resolv.conf
                cp -p "${src}/resolv/content" /etc/resolv.conf
                chmod 644 /etc/resolv.conf
            fi
            ;;
    esac
}

_restore_sysctl() {
    local src="${1}"
    local sysctl_dir="${src}/sysctl"
    [[ -d "${sysctl_dir}" ]] || return 0

    for val_file in "${sysctl_dir}"/*.val; do
        [[ -f "${val_file}" ]] || continue
        local safe_name val key
        safe_name="$(basename "${val_file}" .val)"
        key="${safe_name//_/.}"
        val="$(cat "${val_file}" 2>/dev/null || echo '')"
        [[ "${val}" == "UNKNOWN" || -z "${val}" ]] && continue
        timeout 2 sysctl -w "${key}=${val}" >/dev/null 2>&1 || \
            log "WARN" "sysctl restore failed: ${key}=${val}"
    done
}

_restore_nm() {
    local src="${1}"
    [[ -f "${src}/nm/active_uuid" ]] || return 0
    local uuid
    uuid="$(cat "${src}/nm/active_uuid")"
    nmcli connection up "${uuid}" >/dev/null 2>&1 || \
        log "WARN" "Failed to re-activate NM connection ${uuid}"
}

_restore_systemd_states() {
    local src="${1}"
    local svc

    for svc in systemd-resolved tor; do
        local enabled_file="${src}/systemd/${svc}.enabled"
        local active_file="${src}/systemd/${svc}.active"
        [[ -f "${enabled_file}" ]] || continue

        local was_enabled was_active
        was_enabled="$(cat "${enabled_file}" 2>/dev/null || echo 'unknown')"
        was_active="$(cat "${active_file}"   2>/dev/null || echo 'unknown')"

        case "${was_enabled}" in
            enabled)  systemctl enable "${svc}"  2>/dev/null || true ;;
            disabled) systemctl disable "${svc}" 2>/dev/null || true ;;
        esac

        case "${was_active}" in
            active)   systemctl start "${svc}" 2>/dev/null || true ;;
            inactive) systemctl stop  "${svc}" 2>/dev/null || true ;;
        esac
    done
}

_restore_safe_defaults() {
    log "INFO" "Applying safe defaults (no backup available)"

    case "${FIREWALL_BACKEND}" in
        nftables)
            # Remove only our table if it exists
            nft delete table inet anonmanager 2>/dev/null || true
            ;;
        iptables*|iptables)
            # Remove our chains if they exist
            iptables -D OUTPUT -j AM_OUTPUT    2>/dev/null || true
            iptables -t nat -D OUTPUT -j AM_NAT_OUTPUT 2>/dev/null || true
            iptables -F AM_OUTPUT   2>/dev/null || true
            iptables -X AM_OUTPUT   2>/dev/null || true
            iptables -t nat -F AM_NAT_OUTPUT 2>/dev/null || true
            iptables -t nat -X AM_NAT_OUTPUT 2>/dev/null || true
            # Ensure ACCEPT policies
            iptables -P INPUT   ACCEPT 2>/dev/null || true
            iptables -P OUTPUT  ACCEPT 2>/dev/null || true
            iptables -P FORWARD ACCEPT 2>/dev/null || true
            ip6tables -P INPUT   ACCEPT 2>/dev/null || true
            ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
            ip6tables -P FORWARD ACCEPT 2>/dev/null || true
            ;;
    esac

    # Restore IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0     >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true

    # Unimmute resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Restart NM
    systemctl restart NetworkManager 2>/dev/null || true
}

# Safe tor kill — only kills our managed process
_tor_kill_safe() {
    if [[ -f "${TOR_PID_FILE}" ]]; then
        local pid
        pid="$(cat "${TOR_PID_FILE}" 2>/dev/null || echo '')"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            sleep 1
            kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
        fi
        rm -f "${TOR_PID_FILE}"
    fi
}
