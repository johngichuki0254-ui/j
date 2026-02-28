#!/usr/bin/env bash
# =============================================================================
# network/ipv6.sh — Complete IPv6 disable / restore
# =============================================================================

ipv6_disable() {
    log "INFO" "Disabling IPv6 system-wide"

    timeout 2 sysctl -w net.ipv6.conf.all.disable_ipv6=1     >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.all.accept_ra=0         >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.accept_ra=0     >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.all.autoconf=0          >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.autoconf=0      >/dev/null 2>&1 || true

    # Per-interface disable
    for iface_path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        echo 1 > "${iface_path}" 2>/dev/null || true
    done

    # Disable in NM connections
    if command -v nmcli >/dev/null 2>&1 && \
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        while IFS= read -r con; do
            [[ -z "${con}" ]] && continue
            nmcli connection modify "${con}" ipv6.method "disabled" 2>/dev/null || true
        done < <(nmcli -t -f NAME connection show --active 2>/dev/null)
    fi

    security_log "IPV6" "IPv6 disabled system-wide"
}

ipv6_enable() {
    log "INFO" "Re-enabling IPv6"

    timeout 2 sysctl -w net.ipv6.conf.all.disable_ipv6=0     >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.all.accept_ra=1         >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.accept_ra=1     >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.all.autoconf=1          >/dev/null 2>&1 || true
    timeout 2 sysctl -w net.ipv6.conf.default.autoconf=1      >/dev/null 2>&1 || true

    for iface_path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        echo 0 > "${iface_path}" 2>/dev/null || true
    done

    log "INFO" "IPv6 re-enabled"
}

ipv6_is_disabled() {
    local val
    val="$(timeout 1 sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '0')"
    [[ "${val}" == "1" ]]
}
