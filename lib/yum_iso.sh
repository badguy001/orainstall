#!/bin/bash
# Configure OS ISO as yum/dnf repository (RHEL 7 single-repo / RHEL 8+ BaseOS+AppStream)

iso_dir_has_repodata() {
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    [[ -f "${dir}/repodata/repomd.xml" ]] || [[ -d "${dir}/repodata" ]]
}

detect_iso_repo_layout() {
    local mount_point="$1"
    local subdir

    if iso_dir_has_repodata "${mount_point}/BaseOS" && iso_dir_has_repodata "${mount_point}/AppStream"; then
        echo "baseos_appstream"
        return 0
    fi

    if iso_dir_has_repodata "${mount_point}/BaseOS"; then
        echo "baseos_only"
        return 0
    fi

    if iso_dir_has_repodata "$mount_point"; then
        echo "single"
        return 0
    fi

    for subdir in "$mount_point"/*; do
        [[ -d "$subdir" ]] || continue
        if iso_dir_has_repodata "$subdir"; then
            basename "$subdir"
            return 0
        fi
    done

    echo "unknown"
    return 0
}

write_orainstall_iso_repo() {
    local mount_point="$1"
    local repo_file="$2"
    local layout="$3"

    case "$layout" in
        baseos_appstream)
            cat > "$repo_file" <<EOF
[orainstall-baseos]
name=Oracle Install ISO BaseOS
baseurl=file://${mount_point}/BaseOS
enabled=1
gpgcheck=0

[orainstall-appstream]
name=Oracle Install ISO AppStream
baseurl=file://${mount_point}/AppStream
enabled=1
gpgcheck=0
EOF
            log_info "ISO repo layout: BaseOS + AppStream (RHEL 8+ style)"
            ;;
        baseos_only)
            cat > "$repo_file" <<EOF
[orainstall-baseos]
name=Oracle Install ISO BaseOS
baseurl=file://${mount_point}/BaseOS
enabled=1
gpgcheck=0
EOF
            log_warn "ISO has BaseOS only (no AppStream); some packages may be unavailable"
            ;;
        single)
            cat > "$repo_file" <<EOF
[orainstall-iso]
name=Oracle Install ISO
baseurl=file://${mount_point}
enabled=1
gpgcheck=0
EOF
            log_info "ISO repo layout: single repository (RHEL 7 and earlier style)"
            ;;
        *)
            local subdir="$layout"
            cat > "$repo_file" <<EOF
[orainstall-iso]
name=Oracle Install ISO
baseurl=file://${mount_point}/${subdir}
enabled=1
gpgcheck=0
EOF
            log_info "ISO repo layout: detected repository at ${mount_point}/${subdir}"
            ;;
    esac
}

refresh_pkg_manager_cache() {
    get_pkg_manager
    case "$PKG_MGR" in
        dnf)
            dnf clean all 2>/dev/null || true
            dnf makecache 2>/dev/null || true
            ;;
        yum)
            yum clean all 2>/dev/null || true
            yum makecache fast 2>/dev/null || yum makecache 2>/dev/null || true
            ;;
    esac
}

setup_yum_from_iso() {
    if [[ -z "${os_iso_file:-}" ]]; then
        return 0
    fi
    [[ -f "$os_iso_file" ]] || die "os_iso_file not found: $os_iso_file"

    log_info "Configuring ISO as package source: $os_iso_file"

    local mount_point="/mnt/orainstall_iso"
    local repo_file="/etc/yum.repos.d/orainstall-iso.repo"
    local layout

    mkdir -p "$mount_point"
    if ! mountpoint -q "$mount_point"; then
        mount -o loop,ro "$os_iso_file" "$mount_point" || die "Failed to mount ISO"
    fi

    if [[ "$OS_FAMILY" == "suse" ]]; then
        zypper -n ar -f "dir:$mount_point" orainstall-iso 2>/dev/null || true
        zypper -n refresh 2>/dev/null || true
    else
        layout=$(detect_iso_repo_layout "$mount_point")
        [[ "$layout" != "unknown" ]] || die "No yum/dnf repository found on ISO mount: $mount_point"

        write_orainstall_iso_repo "$mount_point" "$repo_file" "$layout"
        refresh_pkg_manager_cache
    fi

    log_info "ISO package source configured: $mount_point (layout=${layout:-suse})"
}
