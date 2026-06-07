#!/bin/bash
# Grid Infrastructure silent installation

prepare_gi_media() {
    if ! need_gi; then
        return 0
    fi

    ensure_unzip_dir "/opt/oracle_staging/gi" "$gi_user"
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

    run_as_grid "cd ${installer_dir} && ./runInstaller -silent -waitforcompletion ${prereq_flags} -responseFile ${rsp_file}" \
        2>&1 | tee -a "$LOG_FILE" || die "GI software installation failed"

    run_gi_root_scripts
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
                "${gi_home}/root.sh" 2>&1 | tee -a "$LOG_FILE" || true
        done
    fi
}

create_asm_diskgroups() {
    if ! need_asm_storage; then
        return 0
    fi
    if [[ "$run_mode" == "$RUN_MODE_SOFTWARE" ]]; then
        return 0
    fi

    [[ -x "${gi_home}/bin/asmca" ]] || { log_warn "asmca not found; skipping disk group creation"; return 0; }

    local dg_spec dg_name disks disk_list
    local all_dgs=()

    # OCR disk group may already be created during installation
    if [[ -v ASM_DAT_DGS && ${#ASM_DAT_DGS[@]} -gt 0 ]]; then
        for dg_spec in "${ASM_DAT_DGS[@]}"; do
            [[ -z "$dg_spec" ]] && continue
            all_dgs+=("$dg_spec")
        done
    fi

    if [[ -v ASM_OCR_DGS && ${#ASM_OCR_DGS[@]} -gt 0 ]]; then
        for dg_spec in "${ASM_OCR_DGS[@]}"; do
            [[ -z "$dg_spec" ]] && continue
            dg_name=$(parse_diskgroup_for_asmca "$dg_spec")
            if run_as_grid "${gi_home}/bin/asmcmd lsdg 2>/dev/null | grep -qw ${dg_name}"; then
                log_info "ASM disk group $dg_name already exists"
                continue
            fi
            all_dgs+=("$dg_spec")
        done
    fi

    for dg_spec in "${all_dgs[@]}"; do
        [[ -z "$dg_spec" ]] && continue
        dg_name=$(parse_diskgroup_for_asmca "$dg_spec")
        disk_list=$(get_diskgroup_disks "$dg_spec")

        log_info "Creating ASM disk group: $dg_name disks=$disk_list"
        run_as_grid "
            export ORACLE_HOME=$gi_home
            \$ORACLE_HOME/bin/asmca -silent \
                -createDiskGroup \
                -diskGroupName ${dg_name} \
                -diskList ${disk_list} \
                -redundancy EXTERNAL \
                -au_size 4 \
                -sysAsmPassword ${gi_pwd}
        " 2>&1 | tee -a "$LOG_FILE" || log_warn "Disk group $dg_name creation may have failed"
    done
}
