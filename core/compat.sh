#!/usr/bin/env bash
# =============================================================================
# core/compat.sh — Distro detection and capability matrix
# Sets DISTRO_FAMILY, PKG_MANAGER, FIREWALL_BACKEND, and verifies requirements.
# =============================================================================

# =============================================================================
# DISTRO DETECTION
# =============================================================================

_detect_distro_family() {
    local id="${ID:-}" id_like="${ID_LIKE:-}"

    # If ID/ID_LIKE not already in environment, source os-release
    if [[ -z "${id}" && -z "${id_like}" && -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release 2>/dev/null || true
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
    fi

    # Check ID_LIKE first (e.g. "rhel fedora" → rhel)
    case "${id_like}" in
        *debian*|*ubuntu*) echo "debian"; return 0 ;;
        *rhel*|*fedora*|*centos*) echo "rhel"; return 0 ;;
        *arch*) echo "arch"; return 0 ;;
    esac

    # Fall back to ID
    case "${id}" in
        debian|ubuntu|linuxmint|pop|kali|parrot|mx) echo "debian"; return 0 ;;
        arch|manjaro|endeavouros|artix|garuda)        echo "arch";   return 0 ;;
        fedora|rhel|centos|almalinux|rocky|oracle)    echo "rhel";   return 0 ;;
    esac

    # Last resort: check package managers
    if command -v apt-get >/dev/null 2>&1; then echo "debian"; return 0; fi
    if command -v pacman  >/dev/null 2>&1; then echo "arch";   return 0; fi
    if command -v dnf     >/dev/null 2>&1; then echo "rhel";   return 0; fi

    echo "unknown"
}

_detect_pkg_manager() {
    case "${DISTRO_FAMILY}" in
        debian) echo "apt"    ;;
        arch)   echo "pacman" ;;
        rhel)   echo "dnf"    ;;
        *)
            if   command -v apt-get >/dev/null 2>&1; then echo "apt"
            elif command -v pacman  >/dev/null 2>&1; then echo "pacman"
            elif command -v dnf     >/dev/null 2>&1; then echo "dnf"
            else echo "unknown"; fi
            ;;
    esac
}

_detect_firewall_backend() {
    # nftables is the preferred modern backend.
    # We use nftables if it is present AND does not have known iptables conflicts.
    # On RHEL 8+/Fedora, nftables is default. On Arch, nftables is common.
    # On Debian/Ubuntu we prefer iptables-legacy for broadest compat unless nft is active.

    if command -v nft >/dev/null 2>&1; then
        # Check if nft is actually functional (some installs have the binary but no kernel module)
        if nft list tables >/dev/null 2>&1; then
            # On Debian/Ubuntu check if iptables-legacy is in use
            if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
                local ipt_ver
                ipt_ver=$(iptables --version 2>/dev/null || echo "")
                if echo "${ipt_ver}" | grep -qi "legacy"; then
                    echo "iptables-legacy"
                    return 0
                fi
            fi
            echo "nftables"
            return 0
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        echo "iptables"
        return 0
    fi

    echo "unknown"
}

# =============================================================================
# REQUIRED COMMAND VERIFICATION
# =============================================================================

_check_required_commands() {
    local missing=()
    local required=(
        "ip" "sysctl" "tor" "curl"
    )

    # Firewall commands
    case "${FIREWALL_BACKEND}" in
        nftables)        required+=("nft") ;;
        iptables*)       required+=("iptables" "ip6tables" "iptables-save" "iptables-restore") ;;
    esac

    for cmd in "${required[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}[FATAL] Missing required commands: ${missing[*]}${NC}" >&2
        echo -e "${YELLOW}Run the script once with package install support or install manually.${NC}" >&2
        return 1
    fi
    return 0
}

_check_kernel_features() {
    local problems=()

    # Network namespaces
    if ! ip netns list >/dev/null 2>&1; then
        problems+=("Network namespaces not supported by kernel")
    fi

    # ip_forward
    if [[ ! -f /proc/sys/net/ipv4/ip_forward ]]; then
        problems+=("IPv4 forwarding sysctl missing")
    fi

    # veth support
    if ! ip link add _am_test type veth peer name _am_test2 2>/dev/null; then
        problems+=("veth device creation not supported")
    else
        ip link delete _am_test 2>/dev/null || true
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        log "WARN" "Kernel feature issues: ${problems[*]}"
        for p in "${problems[@]}"; do
            echo -e "${YELLOW}  ${SYM_WARN} ${p}${NC}"
        done
        return 1
    fi
    return 0
}

# =============================================================================
# MAIN CAPABILITY DETECTION — called from main() after initialize()
# =============================================================================

detect_capabilities() {
    log "INFO" "Detecting system capabilities..."

    DISTRO_FAMILY="$(_detect_distro_family)"
    PKG_MANAGER="$(_detect_pkg_manager)"
    FIREWALL_BACKEND="$(_detect_firewall_backend)"

    log "INFO" "Distro family:     ${DISTRO_FAMILY}"
    log "INFO" "Package manager:   ${PKG_MANAGER}"
    log "INFO" "Firewall backend:  ${FIREWALL_BACKEND}"
    log "INFO" "Tor user:          ${TOR_USER}"
    log "INFO" "Tor data dir:      ${TOR_DATA_DIR}"

    if [[ "${DISTRO_FAMILY}" == "unknown" ]]; then
        echo -e "${RED}[FATAL] Unable to detect Linux distribution.${NC}" >&2
        exit 1
    fi

    if [[ "${FIREWALL_BACKEND}" == "unknown" ]]; then
        echo -e "${RED}[FATAL] No supported firewall backend (iptables/nftables) found.${NC}" >&2
        exit 1
    fi

    _check_required_commands || exit 1
    _check_kernel_features   || log "WARN" "Some kernel features missing — namespace mode may fall back"

    log "INFO" "Capability detection complete"
}

# =============================================================================
# INTERFACE / GATEWAY DETECTION
# =============================================================================

detect_interface() {
    local iface
    # Primary: route to 8.8.8.8
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')

    # Fallback: first non-virtual UP interface
    if [[ -z "${iface}" ]]; then
        iface=$(ip -o link show up 2>/dev/null \
            | awk -F': ' '$2 !~ /^(lo|veth|docker|br-|virbr|tun|tap|wg|dummy|anonspace)/ {print $2; exit}')
    fi

    if [[ -z "${iface}" ]]; then
        log "ERROR" "No active network interface found"
        return 1
    fi
    echo "${iface}"
}

detect_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}
