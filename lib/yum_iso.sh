#!/bin/bash
# Configure OS ISO as yum/dnf repository

setup_yum_from_iso() {
    if [[ -z "${os_iso_file:-}" ]]; then
        return 0
    fi
    [[ -f "$os_iso_file" ]] || die "os_iso_file not found: $os_iso_file"

    log_info "Configuring ISO as package source: $os_iso_file"

    local mount_point="/mnt/orainstall_iso"
    local repo_file="/etc/yum.repos.d/orainstall-iso.repo"

    mkdir -p "$mount_point"
    if ! mountpoint -q "$mount_point"; then
        mount -o loop,ro "$os_iso_file" "$mount_point" || die "Failed to mount ISO"
    fi

    if [[ "$OS_FAMILY" == "suse" ]]; then
        zypper -n ar -f "dir:$mount_point" orainstall-iso 2>/dev/null || true
        zypper -n refresh 2>/dev/null || true
    else
        cat > "$repo_file" <<EOF
[orainstall-iso]
name=Oracle Install ISO
baseurl=file://${mount_point}
enabled=1
gpgcheck=0
EOF
        if [[ "$PKG_MGR" == "dnf" ]]; then
            dnf clean all 2>/dev/null || true
        else
            yum clean all 2>/dev/null || true
        fi
    fi

    log_info "ISO package source configured: $mount_point"
}
