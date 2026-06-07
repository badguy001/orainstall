#!/bin/bash
# NTP time synchronization (slew mode)

configure_ntp() {
    if [[ -z "${ntp_servers:-}" ]]; then
        return 0
    fi

    log_info "Configuring NTP time sync (slew mode): $ntp_servers"

    local servers=()
    IFS=',' read -ra servers <<< "$ntp_servers"

    if is_systemd && command -v chronyd &>/dev/null; then
        configure_chrony_slew "${servers[@]}"
    elif command -v ntpd &>/dev/null || command -v ntp &>/dev/null; then
        configure_ntpd_slew "${servers[@]}"
    else
        case "$PKG_MGR" in
            dnf|yum) $PKG_MGR install -y chrony 2>/dev/null || $PKG_MGR install -y ntp 2>/dev/null || true ;;
            zypper)  zypper -n install chrony 2>/dev/null || true ;;
        esac
        if command -v chronyd &>/dev/null; then
            configure_chrony_slew "${servers[@]}"
        else
            configure_ntpd_slew "${servers[@]}"
        fi
    fi
}

configure_chrony_slew() {
    local servers=("$@")
    local conf="/etc/chrony.conf"
    backup_file "$conf"

    : > "${conf}.orainstall"
    for s in "${servers[@]}"; do
        s=$(echo "$s" | xargs)
        echo "server $s iburst" >> "${conf}.orainstall"
    done
    cat >> "${conf}.orainstall" <<'EOF'
makestep 1.0 -1
rtcsync
driftfile /var/lib/chrony/drift
EOF

    # slew: do not use makestep large jumps; allow only smooth adjustment
    sed -i 's/^makestep.*/makestep 0.1 -1/' "${conf}.orainstall" 2>/dev/null || true

    cat "${conf}.orainstall" > "$conf"
    systemctl enable chronyd 2>/dev/null || true
    systemctl restart chronyd 2>/dev/null || true
    chronyc -a makestep 2>/dev/null || true
    log_info "chrony configured (slew mode)"
}

configure_ntpd_slew() {
    local servers=("$@")
    local conf="/etc/ntp.conf"
    backup_file "$conf"

    {
        for s in "${servers[@]}"; do
            s=$(echo "$s" | xargs)
            echo "server $s iburst"
        done
        echo "tinker panic 0"
        echo "disable monitor"
    } > "${conf}.orainstall"

    cat "${conf}.orainstall" > "$conf"

    # slew: -x disables panic, -g allows large offset but uses slew
    if is_systemd; then
        mkdir -p /etc/systemd/system/ntpd.service.d
        cat > /etc/systemd/system/ntpd.service.d/oracle.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/ntpd -u ntp:ntp -g -x
EOF
        systemctl daemon-reload
        systemctl enable ntpd 2>/dev/null || systemctl enable ntp 2>/dev/null || true
        systemctl restart ntpd 2>/dev/null || systemctl restart ntp 2>/dev/null || true
    else
        service ntpd restart 2>/dev/null || service ntp restart 2>/dev/null || true
        chkconfig ntpd on 2>/dev/null || true
    fi
    log_info "ntpd configured (slew mode -x)"
}
