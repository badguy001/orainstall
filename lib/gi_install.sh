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

    local ohasd_monitor=0
    if need_gi_ohasd_inittab_fix; then
        start_gi_ohasd_inittab_monitor
        ohasd_monitor=1
    fi

    if ! run_as_grid "cd ${installer_dir} && ./runInstaller -silent -waitforcompletion ${prereq_flags} -responseFile ${rsp_file}" \
            2>&1 | tee -a "$LOG_FILE"; then
        [[ $ohasd_monitor -eq 1 ]] && stop_gi_ohasd_inittab_monitor
        die "GI software installation failed"
    fi

    run_gi_root_scripts

    [[ $ohasd_monitor -eq 1 ]] && stop_gi_ohasd_inittab_monitor

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
