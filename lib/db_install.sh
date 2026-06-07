#!/bin/bash
# Oracle Database software installation and database creation

prepare_db_media() {
    local staging
    staging=$(ensure_unzip_dir "/opt/oracle_staging/db")
    DB_INSTALL_DIR=$(unzip_media_files "$staging" "${DB_INSTALL_FILES[@]}")
    chown -R "${db_user}:${oinstall_group}" "$staging"
    export DB_INSTALL_DIR
    log_info "DB install directory: $DB_INSTALL_DIR"
}

generate_db_install_rsp() {
    local rsp_file="$LOG_DIR/db_install.rsp"

    log_info "Generating DB software install response file ($db_version): $rsp_file"
    render_db_install_rsp "$rsp_file"

    chown "${db_user}:${oinstall_group}" "$rsp_file"
    echo "$rsp_file"
}

generate_dbca_rsp() {
    local rsp_file="$LOG_DIR/dbca.rsp"
    local mem_target="${memory_for_oracle}"
    local create_as_cdb="false"
    local pdb_name=""
    local num_pdbs=0
    local storage_type="FS"
    local nodelist=""
    local rsp_schema

    if need_asm_storage; then
        storage_type="ASM"
    fi

    if is_cdb_supported && [[ "${DB_CREATE_AS_CDB:-1}" == "1" ]]; then
        create_as_cdb="true"
        pdb_name="${DB_PDB_NAME:-orclpdb}"
        num_pdbs=1
    fi

    if is_rac; then
        nodelist=$(build_rac_nodelist)
    fi

    rsp_schema=$(get_dbca_rsp_schema "$db_version")
    log_info "Generating DBCA response file ($db_version): $rsp_file"

    if is_legacy_db_version; then
        cat > "$rsp_file" <<EOF
responseFileVersion=$rsp_schema
gdbName=$ORACLE_SID
sid=$ORACLE_SID
databaseConfigType=$([ "$ora_type" == "rac" ] && echo "RAC" || echo "SI")
RACOneNodeServiceName=
policyName=Oracle
nodelist=$nodelist
templateName=General_Purpose.dbc
sysPassword=${db_pwd}
systemPassword=${db_pwd}
emConfiguration=NONE
runCVUChecks=false
dbsnmpPassword=${db_pwd}
datafileDestination=$([ "$storage_type" == "ASM" ] && echo "+DATA" || echo "$ORACLE_DATA_DIR")
recoveryAreaDestination=$([ "$storage_type" == "ASM" ] && echo "+FRA" || echo "$ORACLE_FRA_DIR")
storageType=$storage_type
characterSet=${DB_CHARACTERSET}
nationalCharacterSet=${DB_NATIONAL_CHARACTERSET}
registerWithDirService=false
listeners=${LISTENER_PORT:-1521}
sampleSchema=false
memoryPercentage=40
databaseType=MULTIPURPOSE
automaticMemoryManagement=false
totalMemory=$mem_target
EOF
    else
        cat > "$rsp_file" <<EOF
responseFileVersion=$rsp_schema
gdbName=$ORACLE_SID
sid=$ORACLE_SID
databaseConfigType=$([ "$ora_type" == "rac" ] && echo "RAC" || echo "SI")
RACOneNodeServiceName=
policyName=Oracle
createAsContainerDatabase=$create_as_cdb
numberOfPDBs=$num_pdbs
pdbName=$pdb_name
useLocalUndoForPDBs=true
pdbAdminPassword=${db_pwd}
nodelist=$nodelist
templateName=General_Purpose.dbc
sysPassword=${db_pwd}
systemPassword=${db_pwd}
emConfiguration=NONE
emExpressPort=5500
runCVUChecks=false
dbsnmpPassword=${db_pwd}
dvConfiguration=false
olsConfiguration=false
datafileDestination=$([ "$storage_type" == "ASM" ] && echo "+DATA" || echo "$ORACLE_DATA_DIR")
recoveryAreaDestination=$([ "$storage_type" == "ASM" ] && echo "+FRA" || echo "$ORACLE_FRA_DIR")
storageType=$storage_type
characterSet=${DB_CHARACTERSET}
nationalCharacterSet=${DB_NATIONAL_CHARACTERSET}
registerWithDirService=false
listeners=${LISTENER_PORT:-1521}
sampleSchema=false
memoryPercentage=40
databaseType=MULTIPURPOSE
automaticMemoryManagement=false
totalMemory=$mem_target
EOF
    fi

    chown "${db_user}:${oinstall_group}" "$rsp_file"
    echo "$rsp_file"
}

install_db_software() {
    if [[ "${SKIP_SOFTWARE_INSTALL:-0}" == "1" ]]; then
        log_info "Skipping DB software installation"
        return 0
    fi

    prepare_db_media
    local rsp_file installer_dir
    rsp_file=$(generate_db_install_rsp)
    installer_dir="$DB_INSTALL_DIR"

    local installer="${installer_dir}/runInstaller"
    [[ -x "$installer" ]] || installer="${installer_dir}/setup.sh"
    [[ -x "$installer" ]] || die "DB installer not found: $installer_dir"

    log_info "Starting silent Oracle Database software installation..."

    local prereq_flags install_cmd installer_tmp tmp_env tmp_flags
    prereq_flags=$(get_installer_prereq_flags "$db_version")
    log_info "Installer prereq ignore flags ($db_version): $prereq_flags"

    installer_tmp="${db_base}/tmp"
    ensure_installer_tmp_dir "$installer_tmp" "$db_user" "$oinstall_group"
    tmp_env=$(installer_temp_env "$installer_tmp")
    tmp_flags=$(runinstaller_tmp_flags "$installer_tmp")

    if [[ "$(basename "$installer")" == "setup.sh" ]]; then
        install_cmd="${tmp_env} && cd ${installer_dir} && ./setup.sh -silent -waitforcompletion ${prereq_flags} -responseFile ${rsp_file}"
    else
        install_cmd="${tmp_env} && cd ${installer_dir} && ./runInstaller -silent -waitforcompletion ${prereq_flags} ${tmp_flags} -responseFile ${rsp_file}"
    fi

    local emagent_monitor=0
    if need_11g_emagent_fix; then
        start_emagent_mk_monitor
        emagent_monitor=1
    fi

    if run_as_oracle "$install_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        install_rc=0
    else
        install_rc=1
    fi

    if [[ $emagent_monitor -eq 1 ]]; then
        stop_emagent_mk_monitor
    fi

    [[ $install_rc -eq 0 ]] || die "DB software installation failed"

    run_db_root_scripts
    log_info "Oracle Database software installation complete"
}

run_db_root_scripts() {
    local inv="/u01/app/oraInventory"
    if [[ -x "${inv}/orainstRoot.sh" ]]; then
        "${inv}/orainstRoot.sh" 2>&1 | tee -a "$LOG_FILE"
    fi
    if [[ -x "${db_home}/root.sh" ]]; then
        "${db_home}/root.sh" 2>&1 | tee -a "$LOG_FILE"
    fi

    if is_rac; then
        get_rac_public_ips
        get_rac_node_hostnames
        local i host ip local_hn
        local_hn=$(get_local_hostname)
        for i in "${!RAC_NODE_HOSTS[@]}"; do
            host="${RAC_NODE_HOSTS[$i]}"
            [[ "$host" == "$local_hn" ]] && continue
            ip="${RAC_PUBLIC_IPS[$i]}"
            log_info "Running DB root.sh on node $host..."
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" \
                "${db_home}/root.sh" 2>&1 | tee -a "$LOG_FILE" || true
        done
    fi
}

create_database() {
    if [[ "$run_mode" != "$RUN_MODE_FULL" ]]; then
        log_info "Skipping database creation in current run mode"
        return 0
    fi

    [[ -x "${db_home}/bin/dbca" ]] || die "dbca not found; install Oracle software first"

    local rsp_file
    rsp_file=$(generate_dbca_rsp)

    log_info "Starting DBCA silent database creation SID=$ORACLE_SID ..."

    if is_rac && [[ -x "${gi_home}/bin/srvctl" ]]; then
        run_as_oracle "
            export ORACLE_HOME=$db_home
            export ORACLE_SID=$ORACLE_SID
            \$ORACLE_HOME/bin/dbca -silent -createDatabase -responseFile $rsp_file
        " 2>&1 | tee -a "$LOG_FILE" || die "RAC DBCA database creation failed"
    else
        run_as_oracle "
            export ORACLE_HOME=$db_home
            export ORACLE_SID=$ORACLE_SID
            \$ORACLE_HOME/bin/dbca -silent -createDatabase -responseFile $rsp_file
        " 2>&1 | tee -a "$LOG_FILE" || die "DBCA database creation failed"
    fi

    log_info "Database $ORACLE_SID created successfully"
}

configure_listener() {
    if [[ "$run_mode" != "$RUN_MODE_FULL" ]]; then
        return 0
    fi
    if is_rac; then
        return 0
    fi

    log_info "Configuring and starting listener..."

    local tns_admin="${db_home}/network/admin"
    mkdir -p "$tns_admin"
    chown -R "${db_user}:${oinstall_group}" "$tns_admin"

    local listener_ora="${tns_admin}/listener.ora"
    if [[ ! -f "$listener_ora" ]]; then
        cat > "$listener_ora" <<EOF
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = $(hostname -f))(PORT = ${LISTENER_PORT:-1521}))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $ORACLE_SID)
      (ORACLE_HOME = $db_home)
      (SID_NAME = $ORACLE_SID)
    )
  )
EOF
        chown "${db_user}:${oinstall_group}" "$listener_ora"
    fi

    run_as_oracle "
        export ORACLE_HOME=$db_home
        \$ORACLE_HOME/bin/lsnrctl start
    " 2>&1 | tee -a "$LOG_FILE" || log_warn "Listener start may have failed"
}

verify_installation() {
    if [[ "$run_mode" != "$RUN_MODE_FULL" ]]; then
        return 0
    fi

    log_info "Verifying installation..."

    if is_rac && [[ -x "${gi_home}/bin/srvctl" ]]; then
        run_as_grid "${gi_home}/bin/crsctl check crs" 2>&1 | tee -a "$LOG_FILE" || true
        run_as_oracle "${gi_home}/bin/srvctl status database -d $ORACLE_SID" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    run_as_oracle "
        export ORACLE_HOME=$db_home
        export ORACLE_SID=$ORACLE_SID
        \$ORACLE_HOME/bin/sqlplus -s / as sysdba <<SQL
whenever sqlerror exit failure
select 'Oracle Version: ' || banner from v\\\$version where rownum=1;
select 'Database Status: ' || open_mode from v\\\$database;
exit;
SQL
    " 2>&1 | tee -a "$LOG_FILE" && log_info "Installation verification passed" || log_warn "Verification did not fully pass"
}

print_summary() {
    cat <<EOF

================================================================================
 Oracle Automated Installation Complete
================================================================================
  Deployment type : $ora_type
  Run mode        : $run_mode
  Operating system: $OS_NAME
  DB version      : $db_version
EOF

    if need_gi; then
        cat <<EOF
  GI version      : $gi_version
  GI_HOME         : $gi_home
EOF
    fi

    if is_rac; then
        cat <<EOF
  Cluster name    : $cluster_name
EOF
    fi

    cat <<EOF
  ORACLE_SID      : $ORACLE_SID
  DB_HOME         : $db_home
  Log file        : $LOG_FILE

  User passwords (keep secure; see log for details):
EOF

    if need_gi; then
        echo "    ${gi_user}: (see log gi_pwd)"
    fi
    echo "    ${db_user}: (see log db_pwd)"

    cat <<EOF

  Connection example:
    su - $db_user
EOF

    if [[ "$run_mode" == "$RUN_MODE_FULL" ]]; then
        echo "    sqlplus / as sysdba"
    fi

    if need_gi; then
        cat <<EOF

  Grid management:
    su - $gi_user
    crsctl check crs
EOF
    fi

    cat <<EOF

================================================================================

EOF
}
