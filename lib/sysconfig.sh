#!/bin/bash
# Kernel parameters, resource limits, HugePages, SELinux, firewall, ZEROCONF

configure_system() {
    configure_kernel_params
    configure_hugepages
    configure_limits
    configure_profiles
    disable_selinux
    disable_firewall
    disable_zeroconf
    configure_logind_remove_ipc
    configure_tmpfiles_oracle
    configure_directories
}

configure_kernel_params() {
    log_info "Configuring kernel parameters..."

    local sysctl_file="/etc/sysctl.d/99-oracle.conf"
    backup_file "$sysctl_file"

    local mem_mib="$memory_for_oracle"
    local shmmax shmall min_free_kbytes
    shmmax=$(( mem_mib * 1024 * 1024 ))
    shmall=$(( shmmax / 4096 ))
    min_free_kbytes=$(calc_min_free_kbytes)

    cat > "$sysctl_file" <<EOF
# Oracle kernel parameters - orainstall
fs.file-max = 6815744
fs.aio-max-nr = 1048576
kernel.shmmni = 4096
kernel.shmmax = $shmmax
kernel.shmall = $shmall
kernel.sem = 250 32000 100 128
vm.min_free_kbytes = $min_free_kbytes
net.ipv4.ip_local_port_range = 9000 65500
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
EOF

    if is_rac; then
        cat >> "$sysctl_file" <<EOF
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.panic_on_oops = 1
EOF
    fi

    sysctl -p "$sysctl_file" 2>/dev/null || sysctl -p 2>/dev/null || log_warn "Some sysctl parameters did not take effect; please check"
}

calc_min_free_kbytes() {
    local numa_nodes mem_kb min_free

    numa_nodes=$(lscpu 2>/dev/null | awk '/^NUMA node\(s\):/ {print $3; exit}')
    if [[ -z "${numa_nodes:-}" || "$numa_nodes" -eq 0 ]]; then
        numa_nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
        numa_nodes="${numa_nodes// /}"
    fi
    if [[ -z "${numa_nodes:-}" || "$numa_nodes" -eq 0 ]]; then
        numa_nodes=1
    fi

    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_kb="${mem_kb:-0}"

    # numa_nodes * 0.4% * physical_memory(KiB)
    min_free=$(( numa_nodes * mem_kb * 4 / 1000 ))
    [[ $min_free -lt 1 ]] && min_free=1

    log_info "vm.min_free_kbytes=${min_free} (numa_nodes=${numa_nodes}, mem_kb=${mem_kb}, 0.4%/node)"
    echo "$min_free"
}

configure_hugepages() {
    log_info "Configuring HugePages (80% memory_for_oracle)..."

    local oracle_mib="$memory_for_oracle"
    local huge_mib=$(( oracle_mib * 80 / 100 ))
    local huge_kb=$(( huge_mib * 1024 ))
    local page_size_kb
    page_size_kb=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
    page_size_kb="${page_size_kb:-2048}"
    local nr_hugepages=$(( huge_kb / page_size_kb ))
    [[ $nr_hugepages -lt 1 ]] && nr_hugepages=1

    local sysctl_file="/etc/sysctl.d/99-oracle-hugepages.conf"
    cat > "$sysctl_file" <<EOF
vm.nr_hugepages = $nr_hugepages
EOF
    sysctl -p "$sysctl_file" 2>/dev/null || true

    # Disable Transparent HugePages (effective at boot; does not modify grub)
    local thp_service="/etc/systemd/system/disable-thp.service"
    if is_systemd; then
        cat > "$thp_service" <<'EOF'
[Unit]
Description=Disable Transparent HugePages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=oracle.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable disable-thp.service 2>/dev/null || true
        systemctl start disable-thp.service 2>/dev/null || true
    else
        local rc_local="/etc/rc.local"
        touch "$rc_local"
        chmod +x "$rc_local"
        grep -q transparent_hugepage "$rc_local" 2>/dev/null || cat >> "$rc_local" <<'EOF'

# Disable Transparent HugePages for Oracle
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi
EOF
    fi

    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    log_info "HugePages: nr_hugepages=$nr_hugepages (page_size=${page_size_kb}KB)"
}

configure_limits() {
    log_info "Configuring user resource limits..."

    local limits_file="/etc/security/limits.d/99-oracle.conf"
    backup_file "$limits_file"

    local users=("$db_user")
    if need_gi; then
        users+=("$gi_user")
    fi

    : > "$limits_file"
    for u in "${users[@]}"; do
        cat >> "$limits_file" <<EOF
$u   soft   nofile    1024
$u   hard   nofile    65536
$u   soft   nproc     2047
$u   hard   nproc     16384
$u   soft   stack     10240
$u   hard   stack     32768
$u   hard   memlock   unlimited
$u   soft   memlock   unlimited
EOF
    done
}

configure_directories() {
    log_info "Creating directories and setting permissions..."

    local dirs=("$db_base" "$db_home" "$ORACLE_DATA_DIR" "$ORACLE_FRA_DIR")
    if need_gi; then
        dirs+=("$gi_base" "$gi_home")
    fi

    local d owner
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        owner="$db_user"
        if need_gi && { [[ "$d" == "$gi_base" || "$d" == "$gi_home" ]]; }; then
            owner="$gi_user"
        fi
        chown "${owner}:${oinstall_group}" "$d" 2>/dev/null || true
        chmod 775 "$d"
    done

    configure_orainventory_directory
}

configure_orainventory_directory() {
    local inv="/u01/app/oraInventory"

    if [[ -e "$inv" ]]; then
        log_info "oraInventory already exists; skipping ownership/permission changes: $inv"
        return 0
    fi

    mkdir -p "$inv"
    if need_gi; then
        chown "${gi_user}:${oinstall_group}" "$inv"
        log_info "Created oraInventory with ownership ${gi_user}:${oinstall_group}"
    else
        chown "${db_user}:${oinstall_group}" "$inv"
        log_info "Created oraInventory with ownership ${db_user}:${oinstall_group}"
    fi
    chmod 775 "$inv"
}

# Append or replace a marked block at the end of .bash_profile (preserve existing content)
write_profile_block() {
    local profile_file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local owner="$4"
    local group="$5"

    mkdir -p "$(dirname "$profile_file")"
    touch "$profile_file"

    if grep -qF "$begin_marker" "$profile_file" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        awk -v begin="$begin_marker" -v end="$end_marker" '
            $0 == begin { skip=1; next }
            $0 == end { skip=0; next }
            !skip { print }
        ' "$profile_file" > "$tmp"
        mv "$tmp" "$profile_file"
    fi

    {
        echo ""
        echo "$begin_marker"
        cat
        echo "$end_marker"
    } >> "$profile_file"

    chown "${owner}:${group}" "$profile_file"
    chmod 644 "$profile_file"
}

write_db_user_profile() {
    local db_profile="/home/$db_user/.bash_profile"
    local db_home_dir
    db_home_dir=$(getent passwd "$db_user" 2>/dev/null | cut -d: -f6)
    [[ -n "$db_home_dir" ]] && db_profile="${db_home_dir}/.bash_profile"

    write_profile_block "$db_profile" \
        "# >>> orainstall db environment >>>" \
        "# <<< orainstall db environment <<<" \
        "$db_user" "$oinstall_group" <<EOF
# Oracle DB Environment - orainstall
export ORACLE_BASE=$db_base
export ORACLE_HOME=$db_home
export ORACLE_SID=$ORACLE_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export NLS_LANG=AMERICAN_AMERICA.${DB_CHARACTERSET}
export NLS_DATE_FORMAT="YYYY-MM-DD HH24:MI:SS"
EOF
}

write_gi_user_profile() {
    local gi_profile="/home/$gi_user/.bash_profile"
    local gi_home_dir asm_sid
    gi_home_dir=$(getent passwd "$gi_user" 2>/dev/null | cut -d: -f6)
    [[ -n "$gi_home_dir" ]] && gi_profile="${gi_home_dir}/.bash_profile"

    asm_sid="${GI_ASM_SID:-}"
    if [[ -z "$asm_sid" ]] && declare -F get_local_asm_sid_from_oratab &>/dev/null; then
        asm_sid=$(get_local_asm_sid_from_oratab) || true
    fi

    write_profile_block "$gi_profile" \
        "# >>> orainstall gi environment >>>" \
        "# <<< orainstall gi environment <<<" \
        "$gi_user" "$oinstall_group" <<EOF
# Oracle GI Environment - orainstall
export ORACLE_BASE=$gi_base
export ORACLE_HOME=$gi_home
$( [[ -n "$asm_sid" ]] && echo "export ORACLE_SID=${asm_sid}" )
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
EOF
}

configure_profiles() {
    log_info "Configuring user environment variables (pre-install)..."
    write_db_user_profile
    if need_gi; then
        write_gi_user_profile
    fi
}

configure_oracle_env_after_install() {
    log_info "Configuring Oracle user environment after install..."

    [[ -d "$db_home" ]] || log_warn "DB_HOME does not exist, skipping db user environment: $db_home"
    if [[ -d "$db_home" ]]; then
        write_db_user_profile
        log_info "Configured $db_user: ORACLE_BASE=$db_base ORACLE_HOME=$db_home"
    fi

    if need_gi; then
        [[ -d "$gi_home" ]] || log_warn "GI_HOME does not exist, skipping gi user environment: $gi_home"
        if [[ -d "$gi_home" ]]; then
            write_gi_user_profile
            log_info "Configured $gi_user: ORACLE_BASE=$gi_base ORACLE_HOME=$gi_home"
        fi
    fi
}

disable_selinux() {
    if command -v getenforce &>/dev/null; then
        local mode
        mode=$(getenforce)
        if [[ "$mode" != "Disabled" ]]; then
            log_info "Disabling SELinux (current: $mode)"
            setenforce 0 2>/dev/null || true
            if [[ -f /etc/selinux/config ]]; then
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
            fi
        fi
    fi
}

disable_firewall() {
    log_info "Disabling and stopping firewall..."
    if is_systemd && systemctl list-unit-files 2>/dev/null | grep firewalld 1>/dev/null; then
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
    elif [[ -x /sbin/chkconfig ]]; then
        service iptables stop 2>/dev/null || true
        chkconfig iptables off 2>/dev/null || true
        service ip6tables stop 2>/dev/null || true
        chkconfig ip6tables off 2>/dev/null || true
    elif [[ "$OS_FAMILY" == "suse" ]]; then
        systemctl stop SuSEfirewall2 2>/dev/null || true
        systemctl disable SuSEfirewall2 2>/dev/null || true
    fi
}

disable_zeroconf() {
    log_info "Disabling ZEROCONF (169.254.0.0)..."
    local zc_conf="/etc/sysconfig/network-scripts/ifcfg-*"
    for f in $zc_conf; do
        [[ -f "$f" ]] || continue
        if grep -q "^IPV6_AUTOCONF" "$f" 2>/dev/null; then
            sed -i 's/^IPV6_AUTOCONF=.*/IPV6_AUTOCONF=no/' "$f"
        else
            echo "IPV6_AUTOCONF=no" >> "$f"
        fi
        if grep -q "^NOZEROCONF" "$f" 2>/dev/null; then
            sed -i 's/^NOZEROCONF=.*/NOZEROCONF=yes/' "$f"
        else
            echo "NOZEROCONF=yes" >> "$f"
        fi
    done

    # NetworkManager
    if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
        if ! grep -q '\[main\]' /etc/NetworkManager/NetworkManager.conf; then
            echo -e "[main]\nno-auto-default=*" >> /etc/NetworkManager/NetworkManager.conf
        fi
    fi

    # Remove existing zeroconf route
    ip route del 169.254.0.0/16 dev lo 2>/dev/null || true
}

configure_logind_remove_ipc() {
    local logind_conf="/etc/systemd/logind.conf"

    [[ -f "$logind_conf" ]] || return 0
    grep -q 'RemoveIPC' "$logind_conf" 2>/dev/null || return 0

    backup_file "$logind_conf"

    # Active or commented RemoveIPC= lines -> RemoveIPC=no
    sed -i '/RemoveIPC=/s/.*/RemoveIPC=no/' "$logind_conf"

    # RemoveIPC mentioned only in comments without a key line: add explicit setting
    if ! grep -q '^RemoveIPC=no' "$logind_conf" 2>/dev/null; then
        if grep -q '^\[Login\]' "$logind_conf" 2>/dev/null; then
            sed -i '/^\[Login\]/a RemoveIPC=no' "$logind_conf"
        else
            printf '\n[Login]\nRemoveIPC=no\n' >> "$logind_conf"
        fi
    fi

    log_info "Set RemoveIPC=no in $logind_conf"

    if is_systemd && systemctl list-unit-files 2>/dev/null | grep systemd-logind; then
        systemctl restart systemd-logind 2>/dev/null || log_warn "Failed to restart systemd-logind; reboot or restart manually for RemoveIPC change"
    fi
}

configure_tmpfiles_oracle() {
    if ! is_systemd; then
        return 0
    fi

    local tmpfiles_dir="/etc/tmpfiles.d"
    local tmpfiles_file="${tmpfiles_dir}/99-oracle.conf"

    mkdir -p "$tmpfiles_dir"
    [[ -f "$tmpfiles_file" ]] && backup_file "$tmpfiles_file"

    cat > "$tmpfiles_file" <<'EOF'
# Oracle temporary files - exclude from systemd tmpfiles cleanup
x /tmp/.oracle*
x /var/tmp/.oracle*
x /usr/tmp/.oracle*
EOF

    log_info "Configured systemd tmpfiles.d: $tmpfiles_file"

    # if command -v systemd-tmpfiles &>/dev/null; then
    #     systemd-tmpfiles --create "$tmpfiles_file" 2>/dev/null || true
    # fi

    if systemctl list-unit-files 2>/dev/null | grep systemd-tmpfiles-clean.timer; then
        systemctl restart systemd-tmpfiles-clean.timer 2>/dev/null || \
            log_warn "Failed to restart systemd-tmpfiles-clean.timer"
    fi
}

setup_autostart() {
    if [[ "${ENABLE_AUTOSTART:-1}" != "1" ]]; then
        return 0
    fi
    log_info "Configuring Oracle autostart on boot..."

    if need_gi && [[ -x "${gi_home}/bin/crsctl" ]]; then
        log_info "RAC/ASM cluster autostart is managed by CRS"
        return 0
    fi

    if is_systemd; then
        local unit="/etc/systemd/system/oracle-${ORACLE_SID}.service"
        cat > "$unit" <<EOF
[Unit]
Description=Oracle Database $ORACLE_SID
After=network.target disable-thp.service

[Service]
Type=forking
User=$db_user
Environment=ORACLE_HOME=$db_home
Environment=ORACLE_SID=$ORACLE_SID
ExecStart=$db_home/bin/dbstart \$ORACLE_HOME
ExecStop=$db_home/bin/dbshut \$ORACLE_HOME
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "oracle-${ORACLE_SID}.service" 2>/dev/null || true

        local dbs_file="/etc/oratab"
        if [[ -f "$dbs_file" ]]; then
            sed -i "s|^${ORACLE_SID}:.*:N|${ORACLE_SID}:${db_home}:Y|" "$dbs_file" 2>/dev/null || true
        fi
    else
        local init_script="/etc/init.d/oracle_${ORACLE_SID}"
        cat > "$init_script" <<EOF
#!/bin/bash
# chkconfig: 345 99 10
ORACLE_HOME=$db_home
ORACLE_SID=$ORACLE_SID
export ORACLE_HOME ORACLE_SID
PATH=\$ORACLE_HOME/bin:\$PATH
case "\$1" in
    start)
        su - $db_user -c "\$ORACLE_HOME/bin/lsnrctl start"
        su - $db_user -c "\$ORACLE_HOME/bin/dbstart \$ORACLE_HOME"
        ;;
    stop)
        su - $db_user -c "\$ORACLE_HOME/bin/dbshut \$ORACLE_HOME"
        su - $db_user -c "\$ORACLE_HOME/bin/lsnrctl stop"
        ;;
    *) echo "Usage: \$0 {start|stop}"; exit 1 ;;
esac
EOF
        chmod +x "$init_script"
        chkconfig --add "oracle_${ORACLE_SID}" 2>/dev/null || true
        chkconfig "oracle_${ORACLE_SID}" on 2>/dev/null || true
    fi
}
