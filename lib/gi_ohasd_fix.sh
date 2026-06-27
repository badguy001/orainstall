#!/bin/bash
# 11gR2 GI ohasd workaround for systemd systems.

need_gi_ohasd_systemd_service() {
    is_legacy_gi_version && is_systemd
}

install_gi_ohasd_systemd_service() {
    local unit="/etc/systemd/system/oracle-ohasd.service"

    need_gi_ohasd_systemd_service || return 0

    log_info "Preparing oracle-ohasd.service for 11gR2 GI (OS: ${OS_NAME})"

    cat > "$unit" <<'EOF'
# Copyright (c) 2014, 2019, Oracle and/or its affiliates. All rights reserved.
#
# Oracle OHASD startup

[Unit]
Description=Oracle High Availability Services
After=network-online.target remote-fs.target autofs.service
Wants=network-online.target remote-fs.target

[Service]
ExecStart=/etc/init.d/init.ohasd run >/dev/null 2>&1 </dev/null
ExecStop=/etc/init.d/init.ohasd stop >/dev/null 2>&1 </dev/null
TimeoutStopSec=60min
Type=simple
Restart=always

# Do not kill any processes except init.ohasd after ExecStop, unless the
# stop command times out.
KillMode=process
SendSIGKILL=yes

# Allow continuous restarts
StartLimitBurst=0

[Install]
WantedBy=multi-user.target graphical.target
EOF

    chmod 644 "$unit"
    systemctl daemon-reload
    systemctl enable oracle-ohasd.service 2>/dev/null || true
    systemctl reset-failed oracle-ohasd.service 2>/dev/null || true
    systemctl start oracle-ohasd.service || die "Failed to start oracle-ohasd.service"
}

install_gi_ohasd_systemd_service_remote() {
    local remote_ip="$1"

    need_gi_ohasd_systemd_service || return 0
    [[ -n "$remote_ip" ]] || return 0

    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${remote_ip}" "bash -s" <<'REMOTE_EOF' || \
        die "Failed to prepare oracle-ohasd.service on ${remote_ip}"
set -e

cat > /etc/systemd/system/oracle-ohasd.service <<'EOF'
# Copyright (c) 2014, 2019, Oracle and/or its affiliates. All rights reserved.
#
# Oracle OHASD startup

[Unit]
Description=Oracle High Availability Services
After=network-online.target remote-fs.target autofs.service
Wants=network-online.target remote-fs.target

[Service]
ExecStart=/etc/init.d/init.ohasd run >/dev/null 2>&1 </dev/null
ExecStop=/etc/init.d/init.ohasd stop >/dev/null 2>&1 </dev/null
TimeoutStopSec=60min
Type=simple
Restart=always

# Do not kill any processes except init.ohasd after ExecStop, unless the
# stop command times out.
KillMode=process
SendSIGKILL=yes

# Allow continuous restarts
StartLimitBurst=0

[Install]
WantedBy=multi-user.target graphical.target
EOF

chmod 644 /etc/systemd/system/oracle-ohasd.service
systemctl daemon-reload
systemctl enable oracle-ohasd.service 2>/dev/null || true
systemctl reset-failed oracle-ohasd.service 2>/dev/null || true
systemctl start oracle-ohasd.service
REMOTE_EOF
}
