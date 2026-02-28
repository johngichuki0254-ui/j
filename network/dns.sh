#!/usr/bin/env bash
# =============================================================================
# network/dns.sh — Symlink-safe DNS configuration to route through Tor
# =============================================================================

dns_secure() {
    log "INFO" "Securing DNS through Tor"

    local iface
    iface="$(detect_interface)"

    # Stop systemd-resolved stub from interfering
    _dns_stop_resolved

    # Method 1: NetworkManager (if active)
    _dns_configure_nm "${iface}" 2>/dev/null || true

    # Method 2: resolv.conf (authoritative, always done last)
    _dns_lock_resolv

    log "INFO" "DNS secured → Tor at 127.0.0.1"
    security_log "DNS" "DNS locked to Tor resolver (127.0.0.1)"
}

dns_restore() {
    log "INFO" "Restoring DNS configuration"

    # Remove immutable flag
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # Restore from backup
    _restore_resolv "${_INITIAL_BACKUP}" 2>/dev/null || true

    # Re-enable systemd-resolved if it was active before
    local resolved_was_active
    resolved_was_active="$(cat "${_INITIAL_BACKUP}/systemd/systemd-resolved.active" 2>/dev/null || echo 'unknown')"
    if [[ "${resolved_was_active}" == "active" ]]; then
        systemctl start systemd-resolved 2>/dev/null || true
    fi

    log "INFO" "DNS restored"
}

_dns_stop_resolved() {
    # Temporarily disable systemd-resolved stub — it would override our resolv.conf
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log "INFO" "Stopping systemd-resolved stub for Tor DNS"
        systemctl stop systemd-resolved 2>/dev/null || true
    fi
}

_dns_configure_nm() {
    local iface="${1}"
    if ! command -v nmcli >/dev/null 2>&1; then return 0; fi
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then return 0; fi

    local con
    con="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | grep ":${iface}$" | cut -d: -f1 | head -1 || echo '')"

    if [[ -n "${con}" ]]; then
        nmcli connection modify "${con}" ipv4.dns "127.0.0.1" 2>/dev/null || true
        nmcli connection modify "${con}" ipv4.ignore-auto-dns yes 2>/dev/null || true
        nmcli connection modify "${con}" ipv6.method "disabled" 2>/dev/null || true
        nmcli connection up "${con}" 2>/dev/null || true
    fi
}

_dns_lock_resolv() {
    # Remove immutable flag if previously set
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # If it's a symlink, remove it — we will use a real file
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf << 'EOF'
# AnonManager — Tor DNS (127.0.0.1)
# This file is temporarily managed by anonmanager.
# It will be restored on disable/exit.
nameserver 127.0.0.1
options edns0 single-request-reopen
EOF

    chmod 644 /etc/resolv.conf

    # Make immutable so other daemons can't overwrite it
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        log "INFO" "resolv.conf locked immutable"
    else
        log "WARN" "Could not set immutable flag on resolv.conf (non-fatal)"
    fi
}
