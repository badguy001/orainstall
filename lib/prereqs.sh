#!/bin/bash
# System prerequisite package installation

install_packages_individually() {
    local pkg

    for pkg in "$@"; do
        [[ -n "$pkg" ]] || continue
        case "$PKG_MGR" in
            dnf|yum)
                if $PKG_MGR install -y "$pkg" >>"$LOG_FILE" 2>&1; then
                    log_info "Installed package: $pkg"
                else
                    log_warn "Failed to install package: $pkg"
                fi
                ;;
            zypper)
                if zypper -n install "$pkg" >>"$LOG_FILE" 2>&1; then
                    log_info "Installed package: $pkg"
                else
                    log_warn "Failed to install package: $pkg"
                fi
                ;;
            *)
                log_warn "Unknown package manager: $PKG_MGR (skip $pkg)"
                ;;
        esac
    done
}

install_prerequisites() {
    get_pkg_manager
    install_base_packages
    if [[ "$USE_ORACLE_PREINSTALL_RPM" == "1" && "$OS_FAMILY" == "redhat" && $OS_MAJOR -ge 7 ]]; then
        install_oracle_preinstall_rpm
    else
        install_manual_packages
    fi
    install_extra_packages
}

install_base_packages() {
    case "$PKG_MGR" in
        dnf|yum)
            install_packages_individually bc expect unzip tar wget openssh-clients openssh-server \
                smartmontools net-tools nfs-utils
            ;;
        zypper)
            install_packages_individually bc expect unzip tar wget openssh
            ;;
    esac
}

install_oracle_preinstall_rpm() {
    local pkg=""
    case "$db_version" in
        18c) pkg="oracle-database-preinstall-18c" ;;
        19c) pkg="oracle-database-preinstall-19c" ;;
        12cR2|12cR1) pkg="oracle-database-preinstall-12c" ;;
        *)
            log_warn "No matching preinstall RPM; falling back to manual package install"
            install_manual_packages
            return
            ;;
    esac

    log_info "Installing Oracle preinstall package: $pkg"
    if ! $PKG_MGR install -y "$pkg" >>"$LOG_FILE" 2>&1; then
        log_warn "Cannot install $pkg; falling back to manual package install"
        install_manual_packages
    else
        log_info "Installed package: $pkg"
    fi

    if need_gi; then
        local gi_pkg=""
        case "$gi_version" in
            19c) gi_pkg="oracle-database-preinstall-19c" ;;
            18c) gi_pkg="oracle-database-preinstall-18c" ;;
            12cR2|12cR1) gi_pkg="oracle-database-preinstall-12c" ;;
        esac
        [[ -n "$gi_pkg" ]] && install_packages_individually "$gi_pkg"
    fi
}

install_manual_packages() {
    log_info "Manually installing Oracle prerequisite packages ($OS_NAME)..."

    local pkgs=()

    if [[ "$OS_FAMILY" == "redhat" ]]; then
        case $OS_MAJOR in
            6)
                pkgs=(
                    binutils compat-libcap1 compat-libstdc++-33 compat-libstdc++-33.i686
                    gcc gcc-c++ glibc glibc.i686 glibc-devel glibc-devel.i686
                    ksh libaio libaio.i686 libaio-devel libaio-devel.i686
                    libgcc libgcc.i686 libstdc++ libstdc++.i686 libstdc++-devel libstdc++-devel.i686
                    libXext libXtst libX11 libXau libXi libXrender libXrender-devel
                    make sysstat unixODBC unixODBC-devel device-mapper-multipath psmisc elfutils-libelf-devel
                )
                ;;
            7)
                pkgs=(
                    binutils compat-libcap1 compat-libstdc++-33
                    gcc gcc-c++ glibc glibc-devel ksh libaio libaio-devel
                    libX11 libXau libXi libXtst libXrender libXrender-devel
                    libgcc libstdc++ libstdc++-devel libxcb libibverbs
                    make sysstat smartmontools net-tools nfs-utils unzip
                    policycoreutils-python device-mapper-multipath psmisc elfutils-libelf-devel
                )
                ;;
            8|9)
                pkgs=(
                    binutils gcc gcc-c++ glibc glibc-devel ksh libaio libaio-devel
                    libX11 libXau libXi libXtst libXrender libXrender-devel
                    libgcc libstdc++ libstdc++-devel libxcb libnsl
                    make sysstat smartmontools net-tools nfs-utils unzip
                    policycoreutils-python-utils device-mapper-multipath psmisc elfutils-libelf-devel
                )
                ;;
        esac
        install_packages_individually "${pkgs[@]}"
    elif [[ "$OS_FAMILY" == "suse" ]]; then
        pkgs=(
            binutils gcc gcc-c++ glibc glibc-devel libaio1 libaio-devel
            libstdc++6 libstdc++-devel make sysstat ksh unzip psmisc elfutils-libelf-devel
            libcap1 libcap-devel libopenssl1_0_0
        )
        install_packages_individually "${pkgs[@]}"
    fi
}

install_extra_packages() {
    if [[ "$use_multipathd" == "1" ]]; then
        case "$PKG_MGR" in
            dnf|yum) install_packages_individually device-mapper-multipath ;;
            zypper)  install_packages_individually multipath-tools ;;
        esac
        systemctl enable multipathd 2>/dev/null || chkconfig multipathd on 2>/dev/null || true
        systemctl start multipathd 2>/dev/null || service multipathd start 2>/dev/null || true
    fi

    if [[ "$OS_FAMILY" == "redhat" && $OS_MAJOR -ge 8 ]]; then
        if [[ ! -f /usr/lib64/libnsl.so.1 && ! -f /lib64/libnsl.so.1 ]]; then
            install_packages_individually libnsl
        fi
    fi

    # cvuqdisk
    if [[ ! -x /usr/sbin/cvuqdisk ]]; then
        local cvu_rpm search_dir
        for search_dir in "${GI_INSTALL_DIR:-}" "${DB_INSTALL_DIR:-}" /opt/software; do
            [[ -n "$search_dir" && -d "$search_dir" ]] || continue
            cvu_rpm=$(find "$search_dir" -name "cvuqdisk-*.rpm" 2>/dev/null | head -1)
            [[ -n "$cvu_rpm" ]] && break
        done
        if [[ -n "${cvu_rpm:-}" ]]; then
            log_info "Installing cvuqdisk: $cvu_rpm"
            rpm -Uvh "$cvu_rpm" 2>/dev/null || true
        fi
    fi
}
