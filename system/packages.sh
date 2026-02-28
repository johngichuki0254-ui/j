#!/usr/bin/env bash
# =============================================================================
# system/packages.sh — Distro-agnostic package installation abstraction
# =============================================================================

# Package name mapping: canonical_name → "apt_name pacman_name dnf_name"
# Fields are space-separated in a single string, split at runtime.
declare -rA _PKG_MAP=(
    [tor]="tor tor tor"
    [proxychains]="proxychains4 proxychains-ng proxychains-ng"
    [macchanger]="macchanger macchanger macchanger"
    [torsocks]="torsocks torsocks torsocks"
    [curl]="curl curl curl"
    [ipset]="ipset ipset ipset"
    [iproute2]="iproute2 iproute2 iproute2"
    [iptables]="iptables iptables iptables"
    [nftables]="nftables nftables nftables"
    [conntrack]="conntrack conntrack-tools conntrack-tools"
    [xxd]="xxd xxd vim-common"
    [nc]="netcat-openbsd openbsd-netcat nmap-ncat"
    [dig]="dnsutils bind-tools bind-utils"
    [dialog]="dialog dialog dialog"
    [psmisc]="psmisc psmisc psmisc"
)

# Resolve canonical package name → distro-specific name
_pkg_resolve() {
    local canonical="${1}"
    local entry="${_PKG_MAP[${canonical}]:-}"

    if [[ -z "${entry}" ]]; then
        # Unknown canonical name — try it literally
        echo "${canonical}"
        return 0
    fi

    # Split: field 1=apt, 2=pacman, 3=dnf
    read -r apt_name pacman_name dnf_name <<< "${entry}"

    case "${PKG_MANAGER}" in
        apt)    echo "${apt_name}"    ;;
        pacman) echo "${pacman_name}" ;;
        dnf)    echo "${dnf_name}"    ;;
        *)      echo "${canonical}"   ;;
    esac
}

# Check if a package is already installed
_pkg_installed() {
    local pkg="${1}"
    case "${PKG_MANAGER}" in
        apt)
            dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "^install ok installed"
            ;;
        pacman)
            pacman -Qi "${pkg}" >/dev/null 2>&1
            ;;
        dnf)
            rpm -q "${pkg}" >/dev/null 2>&1
            ;;
        *)
            command -v "${pkg}" >/dev/null 2>&1
            ;;
    esac
}

_pkg_install_apt() {
    local packages=("$@")
    local to_install=()

    for pkg in "${packages[@]}"; do
        _pkg_installed "${pkg}" || to_install+=("${pkg}")
    done

    [[ ${#to_install[@]} -eq 0 ]] && return 0

    log "INFO" "apt: installing ${to_install[*]}"
    if ! timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | \
            grep -v "^Get:\|^Hit:\|^Ign:" | head -5; then
        log "WARN" "apt-get update had warnings (continuing)"
    fi

    if ! timeout 300 env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --no-install-recommends "${to_install[@]}" 2>&1 | \
            grep -v "^Selecting\|^Preparing\|^Unpacking\|^Setting up"; then
        log "ERROR" "apt-get install failed for: ${to_install[*]}"
        return 1
    fi
}

_pkg_install_pacman() {
    local packages=("$@")
    local to_install=()

    for pkg in "${packages[@]}"; do
        _pkg_installed "${pkg}" || to_install+=("${pkg}")
    done

    [[ ${#to_install[@]} -eq 0 ]] && return 0

    log "INFO" "pacman: installing ${to_install[*]}"
    timeout 300 pacman -S --needed --noconfirm "${to_install[@]}" 2>&1 | \
        grep -v "^warning: .* is up to date" || {
        log "ERROR" "pacman install failed for: ${to_install[*]}"
        return 1
    }
}

_pkg_install_dnf() {
    local packages=("$@")
    local to_install=()

    # RHEL/AlmaLinux need EPEL for proxychains-ng and torsocks
    if [[ "${DISTRO_FAMILY}" == "rhel" ]]; then
        if ! rpm -q epel-release >/dev/null 2>&1; then
            log "INFO" "dnf: enabling EPEL repository (required for torsocks/proxychains-ng)"
            timeout 120 dnf install -y epel-release 2>&1 | tail -3 || {
                log "WARN" "Failed to install EPEL — some packages may not be available"
            }
        fi
    fi

    for pkg in "${packages[@]}"; do
        _pkg_installed "${pkg}" || to_install+=("${pkg}")
    done

    [[ ${#to_install[@]} -eq 0 ]] && return 0

    log "INFO" "dnf: installing ${to_install[*]}"
    timeout 300 dnf install -y "${to_install[@]}" 2>&1 | tail -5 || {
        log "ERROR" "dnf install failed for: ${to_install[*]}"
        return 1
    }
}

# =============================================================================
# PUBLIC API
# =============================================================================

# pkg_install <canonical_name> [<canonical_name> ...]
pkg_install() {
    local canonicals=("$@")
    local resolved=()

    for c in "${canonicals[@]}"; do
        resolved+=("$(_pkg_resolve "${c}")")
    done

    case "${PKG_MANAGER}" in
        apt)    _pkg_install_apt    "${resolved[@]}" ;;
        pacman) _pkg_install_pacman "${resolved[@]}" ;;
        dnf)    _pkg_install_dnf    "${resolved[@]}" ;;
        *)
            log "ERROR" "Unknown package manager: ${PKG_MANAGER}"
            return 1
            ;;
    esac
}

install_required_packages() {
    log "INFO" "Ensuring all required packages are installed"
    echo -e "${CYAN}Checking required packages...${NC}"

    pkg_install tor curl iproute2 conntrack ipset \
                proxychains macchanger torsocks \
                xxd nc dig dialog psmisc

    # Ensure correct firewall tools
    case "${FIREWALL_BACKEND}" in
        nftables)   pkg_install nftables ;;
        iptables*)  pkg_install iptables ;;
    esac

    # Re-detect TOR_USER after tor package install
    TOR_USER="$(detect_tor_user)"
    TOR_DATA_DIR="$(detect_tor_data_dir)"

    log "INFO" "Package installation complete"
}
