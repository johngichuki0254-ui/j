#!/usr/bin/env bash
# =============================================================================
# system/hardening.sh — Kernel sysctl security hardening
# Every sysctl write is individually timeout-guarded. Failures are logged,
# not silently swallowed. No || true on security-relevant keys.
# =============================================================================

# List of settings to apply with justifications
declare -rA _HARDENING_SETTINGS=(
    # Prevent kernel pointer leaks via /proc
    ["kernel.kptr_restrict"]="2"
    # Restrict dmesg to root
    ["kernel.dmesg_restrict"]="1"
    # Block unprivileged eBPF (side-channel risk)
    ["kernel.unprivileged_bpf_disabled"]="1"
    # JIT hardening against BPF spraying
    ["net.core.bpf_jit_harden"]="2"
    # TCP timestamps leak uptime (correlation attack vector)
    ["net.ipv4.tcp_timestamps"]="0"
    # Don't respond to ICMP echo (reduces fingerprinting)
    ["net.ipv4.icmp_echo_ignore_all"]="1"
    # Disable ICMP redirects (routing hijack prevention)
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.default.accept_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["net.ipv6.conf.default.accept_redirects"]="0"
    # Disable IP source routing
    ["net.ipv4.conf.all.accept_source_route"]="0"
    ["net.ipv4.conf.default.accept_source_route"]="0"
    ["net.ipv6.conf.all.accept_source_route"]="0"
    # SYN flood protection
    ["net.ipv4.tcp_syncookies"]="1"
    # Reverse path filtering (prevents spoofed packets)
    ["net.ipv4.conf.all.rp_filter"]="1"
    ["net.ipv4.conf.default.rp_filter"]="1"
    # Prevent IP forwarding on host (namespace handles its own)
    # Note: we explicitly enable it for the namespace veth later
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv4.conf.default.send_redirects"]="0"
    # Log suspicious packets
    ["net.ipv4.conf.all.log_martians"]="1"
    ["net.ipv4.conf.default.log_martians"]="1"
)

apply_kernel_hardening() {
    log "INFO" "Applying kernel security hardening"
    local failed=0

    for key in "${!_HARDENING_SETTINGS[@]}"; do
        local val="${_HARDENING_SETTINGS[${key}]}"
        if ! timeout 2 sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            log "WARN" "Hardening: could not set ${key}=${val} (may not be supported on this kernel)"
            ((failed++)) || true
        fi
    done

    if [[ ${failed} -gt 0 ]]; then
        log "WARN" "Kernel hardening: ${failed} settings could not be applied (non-fatal)"
    else
        log "INFO" "Kernel hardening: all settings applied"
    fi

    security_log "HARDENING" "Kernel sysctl hardening applied (${failed} skipped)"
}

restore_kernel_settings() {
    log "INFO" "Restoring original kernel settings from backup"
    _restore_sysctl "${_INITIAL_BACKUP}"
}

# Enable IP forwarding specifically for the namespace veth
enable_namespace_forwarding() {
    timeout 2 sysctl -w net.ipv4.ip_forward=1          >/dev/null 2>&1 || \
        log "WARN" "Could not enable ip_forward"
    timeout 2 sysctl -w net.ipv4.conf.all.forwarding=1  >/dev/null 2>&1 || \
        log "WARN" "Could not enable conf.all.forwarding"
}
