#!/bin/bash
# Multi-OS detection

detect_os() {
    OS_FAMILY=""
    OS_ID=""
    OS_VERSION=""
    OS_MAJOR=0
    OS_MINOR=0

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
        OS_NAME="${NAME:-$OS_ID}"
    fi

    case "${OS_ID,,}" in
        rhel|centos|rocky|ol|oraclelinux|openEuler|openeuler|kylin)
            OS_FAMILY="redhat"
            ;;
        opensuse*|sles|suse)
            OS_FAMILY="suse"
            ;;
        *)
            if [[ -f /etc/redhat-release ]]; then
                OS_FAMILY="redhat"
                OS_ID="rhel"
            elif [[ -f /etc/SuSE-release ]] || [[ -f /etc/SUSE-brand ]]; then
                OS_FAMILY="suse"
                OS_ID="opensuse"
            else
                die "Unsupported operating system: ${OS_ID:-unknown}"
            fi
            ;;
    esac

    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
    OS_MINOR=$(echo "$OS_VERSION" | cut -d. -f2)
    OS_MAJOR="${OS_MAJOR:-0}"
    OS_MINOR="${OS_MINOR:-0}"

    # Handle RHEL 6/7/8 without VERSION_ID
    if [[ $OS_MAJOR -eq 0 && -f /etc/redhat-release ]]; then
        local release
        release=$(cat /etc/redhat-release)
        OS_MAJOR=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        OS_NAME="$release"
    fi

    # Kylin V10
    if [[ "${OS_ID,,}" == "kylin" ]]; then
        OS_NAME="Kylin V10"
    fi

    export OS_FAMILY OS_ID OS_VERSION OS_MAJOR OS_MINOR OS_NAME
    log_info "Detected OS: $OS_NAME (family=$OS_FAMILY, major=$OS_MAJOR)"
}

get_pkg_manager() {
    case "$OS_FAMILY" in
        redhat)
            if [[ $OS_MAJOR -ge 8 ]] && command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        suse)
            PKG_MGR="zypper"
            ;;
        *)
            die "Unknown OS family: $OS_FAMILY"
            ;;
    esac
    export PKG_MGR
    log_info "Package manager: $PKG_MGR"
}

check_oracle_version_compat() {
    case "$OS_FAMILY" in
        redhat)
            case "$OS_MAJOR" in
                6)
                    case "$db_version" in
                        11gR1|11gR2|12cR1|12cR2) ;;
                        *) log_warn "RHEL 6 primarily supports 11g/12c; current: $db_version" ;;
                    esac
                    ;;
                7)
                    case "$db_version" in
                        11gR1|11gR2|12cR1|12cR2|18c|19c) ;;
                        *) die "RHEL 7 does not support Oracle version: $db_version" ;;
                    esac
                    ;;
                8|9)
                    case "$db_version" in
                        18c|19c|12cR1|12cR2|11gR2)
                            [[ "$db_version" != "18c" && "$db_version" != "19c" ]] && \
                                log_warn "Installing $db_version on RHEL $OS_MAJOR may require additional compatibility packages"
                            ;;
                        11gR1) log_warn "11gR1 on RHEL $OS_MAJOR may not be certified" ;;
                        *) die "RHEL $OS_MAJOR does not support Oracle version: $db_version" ;;
                    esac
                    ;;
                *)
                    log_warn "RHEL major version $OS_MAJOR is not fully tested"
                    ;;
            esac
            ;;
        suse)
            log_warn "For Oracle on openSUSE, refer to the Oracle certification matrix"
            ;;
    esac

    export RHEL_MAJOR="$OS_MAJOR"
}

is_systemd() {
    [[ $OS_MAJOR -ge 7 ]] && command -v systemctl &>/dev/null
}
