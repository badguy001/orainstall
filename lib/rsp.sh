#!/bin/bash
# Silent install response file template selection and rendering
# Principle: keep all template parameters intact; only update existing key=value lines that need values

get_db_install_rsp_template() {
    local ver="${1:-$db_version}"
    case "$ver" in
        11gR1|11gR2) echo "${SCRIPT_DIR}/config/templates/db_install_11.2.rsp" ;;
        12cR1)       echo "${SCRIPT_DIR}/config/templates/db_install_12.1.rsp" ;;
        12cR2)       echo "${SCRIPT_DIR}/config/templates/db_install_12.2.rsp" ;;
        18c|19c)     echo "${SCRIPT_DIR}/config/templates/db_install_19.rsp" ;;
        *) die "Unsupported db_version response template: $ver" ;;
    esac
}

get_gi_install_rsp_template() {
    local ver="${1:-${gi_version:-}}"
    case "$ver" in
        11gR2)       echo "${SCRIPT_DIR}/config/templates/grid_install_11.2.rsp" ;;
        12cR1)       echo "${SCRIPT_DIR}/config/templates/grid_install_12.1.rsp" ;;
        12cR2)       echo "${SCRIPT_DIR}/config/templates/gridsetup_12.2.rsp" ;;
        18c|19c)     echo "${SCRIPT_DIR}/config/templates/gridsetup_19.rsp" ;;
        *) die "Unsupported gi_version response template: $ver" ;;
    esac
}

resolve_rsp_template() {
    local bundled="$1"
    local install_dir="${2:-}"
    local media_names=("${@:3}")

    if [[ -f "$bundled" ]]; then
        echo "$bundled"
        return 0
    fi

    if [[ -n "$install_dir" && -d "$install_dir" ]]; then
        local name found
        for name in "${media_names[@]}"; do
            found=$(find "$install_dir" -type f -name "$name" 2>/dev/null | head -1)
            if [[ -n "$found" ]]; then
                log_info "Using response template from install media: $found"
                echo "$found"
                return 0
            fi
        done
    fi

    die "Response file template not found: $bundled (place in config/templates/ or install media response directory)"
}

rsp_escape_sed() {
    printf '%s' "$1" | sed 's/[\\/&|]/\\&/g'
}

rsp_escape_sed_key() {
    printf '%s' "$1" | sed 's/[[\\.*^$|&]/\\&/g'
}

# Replace only when key= line exists in template; do not add or remove lines
rsp_set_param() {
    local file="$1"
    local key="$2"
    local value="${3-}"

    if ! grep -qF "${key}=" "$file" 2>/dev/null; then
        return 0
    fi

    local escaped_key escaped_val
    escaped_key=$(rsp_escape_sed_key "$key")
    escaped_val=$(rsp_escape_sed "$value")
    sed -i "s|^${escaped_key}=.*|${key}=${escaped_val}|" "$file"
}

get_db_group_values() {
    DB_RSP_DBA_GROUP="dba"
    DB_RSP_OPER_GROUP="oper"
    DB_RSP_BACKUP_GROUP="backupdba"
    DB_RSP_DG_GROUP="dgdba"
    DB_RSP_KM_GROUP="kmdba"
    DB_RSP_RAC_GROUP="racdba"

    if [[ "$group_mode" == "simple" ]]; then
        DB_RSP_OPER_GROUP="dba"
        DB_RSP_BACKUP_GROUP="dba"
        DB_RSP_DG_GROUP="dba"
        DB_RSP_KM_GROUP="dba"
        DB_RSP_RAC_GROUP="dba"
    fi
}

set_db_rsp_common_params() {
    local dest="$1"
    local cluster_nodes="${2:-}"

    rsp_set_param "$dest" "oracle.install.option" "INSTALL_DB_SWONLY"
    rsp_set_param "$dest" "ORACLE_HOSTNAME" "$(hostname -s)"
    rsp_set_param "$dest" "UNIX_GROUP_NAME" "$oinstall_group"
    rsp_set_param "$dest" "INVENTORY_LOCATION" "/u01/app/oraInventory"
    rsp_set_param "$dest" "SELECTED_LANGUAGES" "en"
    rsp_set_param "$dest" "ORACLE_HOME" "$db_home"
    rsp_set_param "$dest" "ORACLE_BASE" "$db_base"
    rsp_set_param "$dest" "oracle.install.db.InstallEdition" "EE"
    rsp_set_param "$dest" "oracle.install.db.CLUSTER_NODES" "$cluster_nodes"
    rsp_set_param "$dest" "oracle.install.db.isRACOneInstall" "false"
    rsp_set_param "$dest" "SECURITY_UPDATES_VIA_MYORACLESUPPORT" "false"
    rsp_set_param "$dest" "DECLINE_SECURITY_UPDATES" "true"
    rsp_set_param "$dest" "oracle.installer.autoupdates.option" "SKIP_UPDATES"
    rsp_set_param "$dest" "oracle.install.db.rootconfig.executeRootScript" "false"
}

set_db_rsp_group_params() {
    local dest="$1"

    if is_legacy_db_version; then
        rsp_set_param "$dest" "oracle.install.db.DBA_GROUP" "$DB_RSP_DBA_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OPER_GROUP" "$DB_RSP_OPER_GROUP"
    elif [[ "$db_version" == "12cR1" ]]; then
        rsp_set_param "$dest" "oracle.install.db.DBA_GROUP" "$DB_RSP_DBA_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OPER_GROUP" "$DB_RSP_OPER_GROUP"
        rsp_set_param "$dest" "oracle.install.db.BACKUPDBA_GROUP" "$DB_RSP_BACKUP_GROUP"
        rsp_set_param "$dest" "oracle.install.db.DGDBA_GROUP" "$DB_RSP_DG_GROUP"
        rsp_set_param "$dest" "oracle.install.db.KMDBA_GROUP" "$DB_RSP_KM_GROUP"
    else
        rsp_set_param "$dest" "oracle.install.db.OSDBA_GROUP" "$DB_RSP_DBA_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OSOPER_GROUP" "$DB_RSP_OPER_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OSBACKUPDBA_GROUP" "$DB_RSP_BACKUP_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OSDGDBA_GROUP" "$DB_RSP_DG_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OSKMDBA_GROUP" "$DB_RSP_KM_GROUP"
        rsp_set_param "$dest" "oracle.install.db.OSRACDBA_GROUP" "$DB_RSP_RAC_GROUP"
    fi
}

# In INSTALL_DB_SWONLY mode, starterdb fields still participate in XSD validation and need valid enum values
set_db_rsp_swonly_schema_fixes() {
    local dest="$1"
    local mem_limit="${memory_for_oracle:-2048}"
    local storage_type="FILE_SYSTEM_STORAGE"

    if need_asm_storage; then
        storage_type="ASM_STORAGE"
    fi

    # Official template comments use GENERAL_PURPOSE/TRANSACTION_PROCESSING which are not valid enum values
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.type" "GENERAL_PURPOSE"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.memoryOption" "false"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.memoryLimit" "$mem_limit"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.storageType" "$storage_type"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.control" "DB_CONTROL"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.installExampleSchemas" "false"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.enableSecuritySettings" "true"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.automatedBackup.enable" "false"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.characterSet" "${DB_CHARACTERSET:-AL32UTF8}"
    rsp_set_param "$dest" "oracle.install.db.ConfigureAsContainerDB" "false"
    rsp_set_param "$dest" "oracle.install.db.config.starterdb.managementOption" "NONE"
}

render_db_install_rsp() {
    local dest="$1"
    local template cluster_nodes=""

    get_db_group_values
    template=$(resolve_rsp_template \
        "$(get_db_install_rsp_template)" \
        "${DB_INSTALL_DIR:-}" \
        "db_install_11.2.rsp" "db_install_12.1.rsp" "db_install_12.2.rsp" \
        "db_install_19.rsp" "db_install.rsp")

    if is_rac; then
        cluster_nodes=$(build_rac_nodelist)
    fi

    log_info "DB response template ($db_version): $template -> $dest"
    cp -a "$template" "$dest"

    set_db_rsp_common_params "$dest" "$cluster_nodes"
    set_db_rsp_group_params "$dest"
    set_db_rsp_swonly_schema_fixes "$dest"
}

set_gi_rsp_params() {
    local dest="$1"
    local install_option="$2"
    local cluster_nodes="$3"
    local scan_name="$4"
    local cluster_name_cfg="$5"
    local asm_osdba="$6"
    local asm_osoper="$7"
    local asm_osasm="$8"
    local asm_disk_string="$9"

    rsp_set_param "$dest" "oracle.install.option" "$install_option"
    rsp_set_param "$dest" "ORACLE_HOSTNAME" "$(hostname -s)"
    rsp_set_param "$dest" "ORACLE_BASE" "$gi_base"
    rsp_set_param "$dest" "ORACLE_HOME" "$gi_home"
    rsp_set_param "$dest" "INVENTORY_LOCATION" "/u01/app/oraInventory"
    rsp_set_param "$dest" "SELECTED_LANGUAGES" "en"
    rsp_set_param "$dest" "oracle.install.asm.OSDBA" "$asm_osdba"
    rsp_set_param "$dest" "oracle.install.asm.OSOPER" "$asm_osoper"
    rsp_set_param "$dest" "oracle.install.asm.OSASM" "$asm_osasm"
    rsp_set_param "$dest" "oracle.install.crs.config.gpnp.scanName" "$scan_name"
    rsp_set_param "$dest" "oracle.install.crs.config.gpnp.scanPort" "1521"
    rsp_set_param "$dest" "oracle.install.crs.config.clusterName" "$cluster_name_cfg"
    rsp_set_param "$dest" "oracle.install.crs.config.gpnp.configureGNS" "false"
    rsp_set_param "$dest" "oracle.install.crs.config.autoConfigureClusterNodeVIP" "false"
    rsp_set_param "$dest" "oracle.install.crs.config.clusterNodes" "$cluster_nodes"
    rsp_set_param "$dest" "oracle.install.crs.config.storageOption" "ASM"
    rsp_set_param "$dest" "oracle.install.asm.storageOption" "ASM"
    rsp_set_param "$dest" "oracle.install.asm.SYSASMPassword" "$gi_pwd"
    rsp_set_param "$dest" "oracle.install.asm.diskGroup.name" "OCR"
    rsp_set_param "$dest" "oracle.install.asm.diskGroup.disks" "$asm_disk_string"
    rsp_set_param "$dest" "oracle.install.asm.diskGroup.diskDiscoveryString" \
        "/dev/oracleasm/*,/dev/asm*,/dev/*oracle*,/dev/*asm*,/dev/*OCR*,/dev/*DATA*"
    rsp_set_param "$dest" "oracle.install.asm.monitorPassword" "$gi_pwd"
    rsp_set_param "$dest" "oracle.install.crs.configureRHPS" "false"
    rsp_set_param "$dest" "oracle.install.crs.config.ignoreDownNodes" "false"
    rsp_set_param "$dest" "oracle.install.config.managementOption" "NONE"
    rsp_set_param "$dest" "oracle.install.config.omsPort" "0"
    rsp_set_param "$dest" "oracle.install.asm.configureASMLib" "false"
    rsp_set_param "$dest" "oracle.install.asm.configureAFD" "false"
    rsp_set_param "$dest" "oracle.install.config.emExpressPort" "5500"
    rsp_set_param "$dest" "oracle.installer.autoupdates.option" "SKIP_UPDATES"
    rsp_set_param "$dest" "AUTOMATIC_UPDATES_ENABLED" "false"
    rsp_set_param "$dest" "SECURITY_UPDATES_VIA_MYORACLESUPPORT" "false"
    rsp_set_param "$dest" "DECLINE_SECURITY_UPDATES" "true"
    rsp_set_param "$dest" "oracle.install.crs.rootconfig.executeRootScript" "false"
}

render_gi_install_rsp() {
    local dest="$1"
    local template install_option cluster_nodes scan_name cluster_name_cfg
    local asm_osdba asm_osoper asm_osasm asm_disk_string=""

    template=$(resolve_rsp_template \
        "$(get_gi_install_rsp_template)" \
        "${GI_INSTALL_DIR:-}" \
        "grid_install_11.2.rsp" "grid_install_12.1.rsp" "gridsetup_12.2.rsp" \
        "gridsetup_19.rsp" "gridsetup.rsp" "grid_install.rsp")

    read -r asm_osdba asm_osoper asm_osasm <<< "$(get_gi_asm_group_names)"

    if [[ ${#ASM_DISKS_FOR_OCR[@]} -gt 0 ]]; then
        asm_disk_string=$(IFS=','; echo "${ASM_DISKS_FOR_OCR[*]}")
    elif [[ ${#ASM_DISKS_FOR_DATA[@]} -gt 0 ]]; then
        asm_disk_string=$(IFS=','; echo "${ASM_DISKS_FOR_DATA[*]}")
    fi

    install_option="HA_CONFIG"
    cluster_nodes="$(hostname -s)"
    scan_name=""
    cluster_name_cfg="$(hostname -s)"

    if is_rac; then
        install_option="CRS_CONFIG"
        cluster_nodes=$(build_rac_nodelist)
        scan_name="${cluster_name}-scan"
        cluster_name_cfg="$cluster_name"
    fi

    log_info "GI response template ($gi_version): $template -> $dest"
    cp -a "$template" "$dest"

    set_gi_rsp_params "$dest" "$install_option" "$cluster_nodes" "$scan_name" \
        "$cluster_name_cfg" "$asm_osdba" "$asm_osoper" "$asm_osasm" "$asm_disk_string"
}
