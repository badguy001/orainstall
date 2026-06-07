#!/bin/bash
# Configuration loading, validation, and defaults

# Run mode constants
RUN_MODE_ENV="env"
RUN_MODE_SOFTWARE="software"
RUN_MODE_FULL="full"

# Deployment types
ORA_TYPE_STANDALONE="oracle"
ORA_TYPE_ASM="asm"
ORA_TYPE_RAC="rac"

# Group modes
GROUP_MODE_SIMPLE="simple"
GROUP_MODE_DETAIL="detail"

version_to_path() {
    case "$1" in
        11gR1) echo "11.1.0" ;;
        11gR2) echo "11.2.0" ;;
        12cR1) echo "12.1.0" ;;
        12cR2) echo "12.2.0" ;;
        18c)   echo "18.0.0" ;;
        19c)   echo "19.0.0" ;;
        *)     echo "$1" ;;
    esac
}

version_to_num() {
    version_to_path "$1"
}

parse_size_to_mib() {
    local val="$1"
    local num unit
    if [[ "$val" =~ ^([0-9]+)([MmGg]?[Ii]?[Bb]?)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "${unit^^}" in
            G|GB|GIB) echo $(( num * 1024 )) ;;
            M|MB|MIB|"") echo "$num" ;;
            *) echo "$num" ;;
        esac
    else
        die "Invalid memory size format: $val"
    fi
}

calc_default_memory_for_oracle() {
    local total_kb total_mib system_mib oracle_mib
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_mib=$(( total_kb / 1024 ))

    if [[ $total_mib -le $(( 100 * 1024 )) ]]; then
        oracle_mib=$(( total_mib * 80 / 100 ))
    else
        local total_gib=$(( total_mib / 1024 ))
        system_mib=$(( 20 * 1024 ))
        local extra=$(( (total_gib - 100) / 100 ))
        system_mib=$(( system_mib + extra * 5 * 1024 ))
        oracle_mib=$(( total_mib - system_mib ))
        [[ $oracle_mib -lt 0 ]] && oracle_mib=$(( total_mib * 80 / 100 ))
    fi
    echo "$oracle_mib"
}

load_and_validate_config() {
    local config_file="${1:-$SCRIPT_DIR/config/oracle.conf}"
    [[ -f "$config_file" ]] || die "Config file not found: $config_file (copy config/oracle.conf.example)"

    # shellcheck source=/dev/null
    source "$config_file"

    LOG_DIR="${LOG_DIR:-/var/log/orainstall}"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/install_$(date '+%Y%m%d_%H%M%S').log"
    log_info "Log file: $LOG_FILE"

    # Required fields
    [[ -n "${ora_type:-}" ]]     || die "ora_type is required (oracle|asm|rac)"
    [[ -n "${db_version:-}" ]]   || die "db_version is required"
    [[ -n "${db_install_file:-}" ]] || die "db_install_file is required"

    case "$ora_type" in
        oracle|asm|rac) ;;
        *) die "Invalid ora_type: $ora_type (oracle|asm|rac)" ;;
    esac

    case "$db_version" in
        11gR1|11gR2|12cR1|12cR2|18c|19c) ;;
        *) die "Unsupported db_version: $db_version" ;;
    esac

    if [[ "$ora_type" == "asm" || "$ora_type" == "rac" ]]; then
        [[ -n "${gi_version:-}" ]]      || die "gi_version is required for asm/rac mode"
        [[ -n "${gi_install_file:-}" ]] || die "gi_install_file is required for asm/rac mode"
        case "$gi_version" in
            11gR2|12cR1|12cR2|18c|19c) ;;
            *) die "Unsupported gi_version: $gi_version" ;;
        esac
    fi

    run_mode="${run_mode:-full}"
    case "$run_mode" in
        env|software|full) ;;
        *) die "Invalid run_mode: $run_mode (env|software|full)" ;;
    esac

    gi_user="${gi_user:-grid}"
    db_user="${db_user:-oracle}"
    oinstall_group="${oinstall_group:-oinstall}"
    group_mode="${group_mode:-simple}"
    use_multipathd="${use_multipathd:-0}"
    cluster_name="${cluster_name:-${cluser_name:-}}"

    if need_gi && [[ -z "${gi_pwd:-}" ]]; then
        gi_pwd=$(generate_strong_password 16)
        log_info "Auto-generated gi user password (see log)"
        log_secret "gi_pwd" "$gi_pwd"
    fi
    if [[ -z "${db_pwd:-}" ]]; then
        db_pwd=$(generate_strong_password 16)
        log_info "Auto-generated db user password (see log)"
        log_secret "db_pwd" "$db_pwd"
    fi

    # GI-related variables may be unset in standalone mode; avoid set -u errors
    gi_pwd="${gi_pwd:-}"
    gi_version="${gi_version:-}"
    gi_install_file="${gi_install_file:-}"
    root_pwd="${root_pwd:-}"
    ntp_servers="${ntp_servers:-}"
    os_iso_file="${os_iso_file:-}"
    patch_files="${patch_files:-}"
    opatch_files="${opatch_files:-}"

    local db_ver_path gi_ver_path
    db_ver_path=$(version_to_path "$db_version")
    gi_ver_path=$(version_to_path "${gi_version:-$db_version}")

    db_base="${db_base:-/u01/app/oracle}"
    db_home="${db_home:-${db_base}/product/${db_ver_path}/dbhome_1}"
    gi_base="${gi_base:-/u01/app/grid}"
    gi_home="${gi_home:-/u01/app/${gi_ver_path}/grid}"

    # Legacy config variable names
    ORACLE_VERSION="$db_version"
    ORACLE_BASE="$db_base"
    ORACLE_HOME="$db_home"
    ORACLE_USER="$db_user"
    ORACLE_PASSWORD="$db_pwd"
    ORACLE_GROUP="$oinstall_group"
    GI_USER="$gi_user"
    GI_PWD="${gi_pwd:-}"
    GI_HOME="$gi_home"
    GI_BASE="$gi_base"

    ORACLE_SID="${ORACLE_SID:-orcl}"
    ORACLE_DATA_DIR="${ORACLE_DATA_DIR:-/u01/oradata}"
    ORACLE_FRA_DIR="${ORACLE_FRA_DIR:-/u01/fast_recovery_area}"
    DB_CHARACTERSET="${DB_CHARACTERSET:-AL32UTF8}"
    DB_NATIONAL_CHARACTERSET="${DB_NATIONAL_CHARACTERSET:-AL16UTF16}"
    DB_CREATE_AS_CDB="${DB_CREATE_AS_CDB:-1}"
    DB_PDB_NAME="${DB_PDB_NAME:-orclpdb}"
    LISTENER_PORT="${LISTENER_PORT:-1521}"
    ENABLE_AUTOSTART="${ENABLE_AUTOSTART:-1}"
    USE_ORACLE_PREINSTALL_RPM="${USE_ORACLE_PREINSTALL_RPM:-1}"

    if [[ -z "${memory_for_oracle:-}" && -n "${memroy_for_oracle:-}" ]]; then
        memory_for_oracle="$memroy_for_oracle"
    fi
    if [[ -z "${memory_for_oracle:-}" ]]; then
        memory_for_oracle=$(calc_default_memory_for_oracle)
        log_info "Auto-calculated memory_for_oracle=${memory_for_oracle}MiB"
    else
        memory_for_oracle=$(parse_size_to_mib "$memory_for_oracle")
    fi

    if [[ "$ora_type" == "rac" ]]; then
        [[ -n "${root_pwd:-}" ]]       || die "root_pwd is required for rac mode"
        [[ -n "${cluster_name:-}" ]]    || die "cluster_name (cluser_name) is required for rac mode"
        [[ -n "${ora_net:-}" ]]         || die "ora_net is required for rac mode"
        [[ -n "${asm_ocr_dg:-}" ]]      || die "asm_ocr_dg is required for rac mode"
    fi

    if [[ "$ora_type" == "asm" ]]; then
        [[ -n "${asm_dat_dg:-}" ]] || die "asm_dat_dg is required for standalone asm mode"
    fi

    # Parse ora_net
    parse_ora_net

    # Parse ASM disk groups
    parse_asm_diskgroups

    # Parse install file lists
    IFS=',' read -ra DB_INSTALL_FILES <<< "${db_install_file}"
    GI_INSTALL_FILES=()
    if [[ -n "${gi_install_file}" ]]; then
        IFS=',' read -ra GI_INSTALL_FILES <<< "${gi_install_file}"
    fi

    PATCH_ENTRIES=()
    if [[ -n "${patch_files:-}" ]]; then
        IFS=',' read -ra PATCH_ENTRIES <<< "${patch_files}"
    fi

    OPATCH_ENTRIES=()
    if [[ -n "${opatch_files:-}" ]]; then
        IFS=',' read -ra OPATCH_ENTRIES <<< "${opatch_files}"
    fi

    export ora_type db_version gi_version run_mode gi_user gi_pwd db_user db_pwd
    export db_home db_base gi_home gi_base memory_for_oracle group_mode oinstall_group
    export use_multipathd cluster_name root_pwd ntp_servers os_iso_file patch_files opatch_files
}

parse_ora_net() {
    ORA_NET_NODES=()
    if [[ -z "${ora_net:-}" ]]; then
        return 0
    fi

    local IFS=','
    read -ra ORA_NET_NODES <<< "$ora_net"
}

parse_asm_diskgroups() {
    ASM_OCR_DGS=()
    ASM_DAT_DGS=()

    if [[ -n "${asm_ocr_dg:-}" ]]; then
        local IFS='#'
        read -ra ASM_OCR_DGS <<< "$asm_ocr_dg"
    fi
    if [[ -n "${asm_dat_dg:-}" ]]; then
        local IFS='#'
        read -ra ASM_DAT_DGS <<< "$asm_dat_dg"
    fi

    export ASM_OCR_DGS ASM_DAT_DGS
}

need_gi() {
    [[ "$ora_type" == "asm" || "$ora_type" == "rac" ]]
}

need_asm_storage() {
    [[ "$ora_type" == "asm" || "$ora_type" == "rac" ]]
}

is_rac() {
    [[ "$ora_type" == "rac" ]]
}
