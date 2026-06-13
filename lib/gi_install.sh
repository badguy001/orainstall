#!/bin/bash
# Grid Infrastructure silent installation

prepare_gi_media() {
    if ! need_gi; then
        return 0
    fi

    ensure_unzip_dir "/opt/oracle_staging/gi" "$gi_user"
    GI_MEDIA_STAGING_DIR="$UNZIP_STAGING_DIR"
    unzip_media_files "$UNZIP_STAGING_DIR" "$gi_user" "${GI_INSTALL_FILES[@]}"
    GI_INSTALL_DIR="$INSTALL_MEDIA_DIR"
    export GI_INSTALL_DIR
    log_info "GI install directory: $GI_INSTALL_DIR"
}

generate_gi_install_rsp() {
    local rsp_file="$LOG_DIR/gi_install.rsp"

    log_info "Generating GI install response file ($gi_version): $rsp_file"
    render_gi_install_rsp "$rsp_file"

    chown "${gi_user}:${oinstall_group}" "$rsp_file"
    echo "$rsp_file"
}

install_gi_software() {
    if ! need_gi; then
        return 0
    fi
    if [[ "${SKIP_SOFTWARE_INSTALL:-0}" == "1" ]]; then
        log_info "Skipping GI software installation"
        return 0
    fi

    prepare_gi_media
    prepare_asm_disks_for_installer
    configure_asm_udev

    local rsp_file installer_dir
    rsp_file=$(generate_gi_install_rsp)
    installer_dir="$GI_INSTALL_DIR"

    [[ -x "${installer_dir}/runInstaller" ]] || die "GI runInstaller not found: $installer_dir"

    log_info "Starting silent Grid Infrastructure installation..."

    local prereq_flags
    prereq_flags=$(get_installer_prereq_flags "$gi_version")
    log_info "Installer prereq ignore flags ($gi_version): $prereq_flags"


    if ! run_as_grid "cd ${installer_dir} && ./runInstaller -silent -waitforcompletion ${prereq_flags} -responseFile ${rsp_file}" \
            2>&1 | tee -a "$LOG_FILE"; then
        die "GI software installation failed"
    fi

    local ohasd_monitor=0
    if need_gi_ohasd_inittab_fix; then
        start_gi_ohasd_inittab_monitor
        ohasd_monitor=1
    fi
    run_gi_root_scripts
    [[ $ohasd_monitor -eq 1 ]] && stop_gi_ohasd_inittab_monitor

    run_gi_config_tool_all_commands

    configure_gi_user_post_install

    cleanup_staging_dir "${GI_MEDIA_STAGING_DIR:-}"

    log_info "Grid Infrastructure installation complete"
}

run_gi_root_scripts() {
    local inv="/u01/app/oraInventory"
    if [[ -x "${inv}/orainstRoot.sh" ]]; then
        "${inv}/orainstRoot.sh" 2>&1 | tee -a "$LOG_FILE"
    fi
    if [[ -x "${gi_home}/root.sh" ]]; then
        "${gi_home}/root.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    if is_rac; then
        get_rac_node_hostnames
        get_rac_public_ips
        local i host ip local_hn
        local_hn=$(get_local_hostname)
        for i in "${!RAC_NODE_HOSTS[@]}"; do
            host="${RAC_NODE_HOSTS[$i]}"
            [[ "$host" == "$local_hn" ]] && continue
            ip="${RAC_PUBLIC_IPS[$i]}"
            log_info "Running GI root.sh on node $host..."
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" \
                "${inv}/orainstRoot.sh" 2>&1 | tee -a "$LOG_FILE" || true
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" \
                "${gi_home}/root.sh" 2>&1 | tee -a "$LOG_FILE" || true
        done
    fi
}

run_gi_config_tool_all_commands() {
    local asm_pwd_rsp config_tool

    if ! need_gi || ! is_legacy_gi_version; then
        return 0
    fi

    [[ -n "${asm_passwd:-}" ]] || die "asm_passwd is required for 11g ASM configToolAllCommands"

    asm_pwd_rsp=$(generate_asm_password_rsp)
    asm_pwd_rsp=$(abs_path "$asm_pwd_rsp") || die "Invalid ASM password response file path: $asm_pwd_rsp"
    [[ -f "$asm_pwd_rsp" ]] || die "ASM password response file not found: $asm_pwd_rsp"

    config_tool="${gi_home}/cfgtoollogs/configToolAllCommands"
    if [[ ! -f "$config_tool" ]]; then
        log_warn "configToolAllCommands not found; skipping ASM/listener configuration: $config_tool"
        return 0
    fi
    if [[ ! -x "$config_tool" ]]; then
        chmod +x "$config_tool" 2>/dev/null || true
    fi

    log_info "Running configToolAllCommands for 11g ASM standalone (RESPONSE_FILE=$asm_pwd_rsp)"
    run_as_grid "
        export ORACLE_HOME=${gi_home}
        \${ORACLE_HOME}/cfgtoollogs/configToolAllCommands RESPONSE_FILE=${asm_pwd_rsp}
    " 2>&1 | tee -a "$LOG_FILE" || die "configToolAllCommands failed (11g ASM standalone)"

    relocate_asm_spfile_to_filesystem
}

relocate_asm_spfile_to_filesystem() {
    if ! is_asm_standalone || ! is_legacy_gi_version; then
        return 0
    fi

    [[ -x "${gi_home}/bin/srvctl" ]] || {
        log_warn "srvctl not found; skipping ASM spfile relocation"
        return 0
    }

    local srvctl_out spfile_path local_spfile="${gi_home}/dbs/spfile+ASM.ora"

    if ! srvctl_out=$(run_as_grid "
        export ORACLE_HOME=${gi_home}
        export PATH=\$ORACLE_HOME/bin:\$PATH
        \$ORACLE_HOME/bin/srvctl config asm
    " 2>/dev/null); then
        log_warn "Failed to query srvctl config asm; skipping ASM spfile relocation"
        return 0
    fi

    spfile_path=$(printf '%s\n' "$srvctl_out" | awk -F: '
        /^[Ss][Pp]file[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    ')

    [[ -n "$spfile_path" ]] || {
        log_warn "ASM spfile not found in srvctl config asm output; skipping relocation"
        return 0
    }

    if [[ "$spfile_path" != +* ]]; then
        log_info "ASM spfile already on filesystem: $spfile_path"
        return 0
    fi

    log_info "ASM spfile on disk group: $spfile_path; copying to $local_spfile"

    mkdir -p "${gi_home}/dbs"
    chown "${gi_user}:${oinstall_group}" "${gi_home}/dbs" 2>/dev/null || true

    run_as_grid "
        set -e
        export ORACLE_HOME=${gi_home}
        export PATH=\$ORACLE_HOME/bin:\$PATH
        export ORACLE_SID='+ASM'
        mkdir -p ${gi_home}/dbs
        [[ -x \$ORACLE_HOME/bin/asmcmd ]] || exit 1
        \$ORACLE_HOME/bin/asmcmd spcopy -u '${spfile_path}' '${local_spfile}'
        \$ORACLE_HOME/bin/srvctl modify asm -p '${local_spfile}'
        \$ORACLE_HOME/bin/srvctl stop asm -f
        \$ORACLE_HOME/bin/srvctl start asm
    " 2>&1 | tee -a "$LOG_FILE" || die "Failed to relocate ASM spfile to ${local_spfile}"

    log_info "ASM spfile relocated to filesystem: ${local_spfile}"
}

generate_asm_password_rsp() {
    local rsp_file="$LOG_DIR/asm_password.rsp"

    log_info "Generating ASM password response file: $rsp_file"
    cat > "$rsp_file" <<EOF
oracle.assistants.asm|S_ASMPASSWORD=${asm_passwd}
oracle.assistants.asm|S_ASMMONITORPASSWORD=${asm_passwd}
EOF

    chown "${gi_user}:${oinstall_group}" "$rsp_file"
    chmod 600 "$rsp_file"
    echo "$rsp_file"
}

get_local_asm_sid_from_oratab() {
    local line sid home

    [[ -f /etc/oratab ]] || return 1

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        sid="${line%%:*}"
        home="${line#*:}"
        home="${home%%:*}"
        [[ "$sid" == +* ]] || continue
        if [[ -n "${gi_home:-}" && "$home" != "$gi_home" ]]; then
            continue
        fi
        echo "$sid"
        return 0
    done < /etc/oratab

    return 1
}

resolve_crs_alert_trace_dir() {
    local hostname="$1"
    local d

    if is_legacy_gi_version; then
        d="${gi_home}/log/${hostname}"
        [[ -d "$d" ]] && { echo "$d"; return 0; }
    fi

    d="${gi_base}/diag/crs/${hostname}/crs/trace"
    [[ -d "$d" ]] && { echo "$d"; return 0; }

    d="${gi_home}/log/${hostname}"
    [[ -d "$d" ]] && { echo "$d"; return 0; }

    return 1
}

resolve_asm_alert_trace_dir() {
    local asm_sid="$1"
    local d

    for d in \
        "${gi_base}/diag/asm/+ASM/${asm_sid}/trace" \
        "${gi_base}/diag/asm/+asm/${asm_sid}/trace"; do
        [[ -d "$d" ]] && { echo "$d"; return 0; }
    done

    return 1
}

create_gi_user_home_symlink() {
    local gi_home_dir="$1"
    local link_name="$2"
    local target_dir="$3"

    [[ -n "$gi_home_dir" && -n "$link_name" && -e "$target_dir" ]] || return 1

    target_dir=$(abs_path "$target_dir") || return 1
    ln -sfn "$target_dir" "${gi_home_dir}/${link_name}"
    chown -h "${gi_user}:${oinstall_group}" "${gi_home_dir}/${link_name}" 2>/dev/null || true
    log_info "Created symlink ~/${link_name} -> ${target_dir}"
}

configure_gi_user_post_install() {
    local gi_home_dir asm_sid hostname crs_trace_dir asm_trace_dir

    gi_home_dir=$(getent passwd "$gi_user" 2>/dev/null | cut -d: -f6)
    [[ -n "$gi_home_dir" ]] || gi_home_dir="/home/$gi_user"

    log_info "Configuring ${gi_user} post-install environment and alert log symlinks"

    if asm_sid=$(get_local_asm_sid_from_oratab); then
        export GI_ASM_SID="$asm_sid"
        log_info "Local ASM instance SID from /etc/oratab: ${GI_ASM_SID}"
        write_gi_user_profile
    else
        log_warn "Local ASM instance SID not found in /etc/oratab; skipping ORACLE_SID in gi user profile"
    fi

    hostname=$(get_local_hostname)

    if crs_trace_dir=$(resolve_crs_alert_trace_dir "$hostname"); then
        create_gi_user_home_symlink "$gi_home_dir" "crs_trace" "$crs_trace_dir"
        create_gi_user_home_symlink "$gi_home_dir" `basename "$crs_trace_dir"/alert*log` "$crs_trace_dir"/alert*log
    else
        log_warn "CRS alert trace directory not found for hostname=${hostname}"
    fi

    if [[ -n "${asm_sid:-}" ]]; then
        if asm_trace_dir=$(resolve_asm_alert_trace_dir "$asm_sid"); then
            create_gi_user_home_symlink "$gi_home_dir" "${asm_sid}_trace" "$asm_trace_dir"
            create_gi_user_home_symlink "$gi_home_dir" `basename "$asm_trace_dir"/alert*log` "$asm_trace_dir"/alert*log
        else
            log_warn "ASM alert trace directory not found for ASM SID=${asm_sid}"
        fi
    fi
}
