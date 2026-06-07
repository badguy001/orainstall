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
    asm_disk_string="${asm_disk_string:-}"
    ignore_disk_wwid="${ignore_disk_wwid:-0}"
    case "${ignore_disk_wwid,,}" in
        1|true|yes) ignore_disk_wwid=1 ;;
        *) ignore_disk_wwid=0 ;;
    esac
    disks_use_by_asm="${disks_use_by_asm:-}"
    asm_diskgroup_name="${asm_diskgroup_name:-OCR}"
    asm_diskgroup_disks="${asm_diskgroup_disks:-}"
    asm_diskgroup_redundancy="${asm_diskgroup_redundancy:-EXTERNAL}"
    asm_diskgroup_ausize="${asm_diskgroup_ausize:-4}"
    asm_passwd="${asm_passwd:-}"

    if need_gi && [[ -z "$asm_passwd" ]]; then
        asm_passwd=$(generate_alphanumeric_password 16)
        log_info "Auto-generated asm_passwd (see log)"
        log_secret "asm_passwd" "$asm_passwd"
    fi

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
    fi

    if [[ "$ora_type" == "asm" || "$ora_type" == "rac" ]]; then
        [[ -n "${disks_use_by_asm:-}" ]]      || die "disks_use_by_asm is required for asm/rac mode"
        [[ -n "${asm_diskgroup_disks:-}" ]]   || die "asm_diskgroup_disks is required for asm/rac mode"
        [[ -n "${asm_disk_string:-}" ]]       || die "asm_disk_string is required for asm/rac mode"
    fi

    # Parse ora_net
    parse_ora_net

    # Parse ASM disk and disk group configuration
    parse_asm_config

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
    export asm_disk_string ignore_disk_wwid disks_use_by_asm asm_diskgroup_name
    export asm_diskgroup_disks asm_diskgroup_redundancy asm_diskgroup_ausize asm_passwd
}

parse_ora_net() {
    ORA_NET_NODES=()
    if [[ -z "${ora_net:-}" ]]; then
        return 0
    fi

    local IFS=','
    read -ra ORA_NET_NODES <<< "$ora_net"
}

parse_asm_diskgroup_ausize() {
    local val="${1:-4}"
    val="${val// /}"

    case "$val" in
        ''|*[!0-9]*)
            die "Invalid asm_diskgroup_ausize: $val (numeric MB value, example: 4)"
            ;;
    esac
    echo "$val"
}

validate_asm_diskgroup_disks() {
    local disk_entry disk_name wwid asm_disk_name dg_disk dg_path known_path
    local -a known_asm_paths=()
    local found=0

    for disk_entry in "${ASM_DISK_ENTRIES[@]}"; do
        [[ -z "$disk_entry" ]] && continue
        IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
        asm_disk_name="${asm_disk_name:-$disk_name}"
        known_path=$(normalize_asm_disk_dev_path "$asm_disk_name")
        known_asm_paths+=("$known_path")
    done

    for dg_disk in "${ASM_DISKGROUP_DISK_LIST[@]}"; do
        dg_path=$(normalize_asm_disk_dev_path "$dg_disk")
        found=0
        for known_path in "${known_asm_paths[@]}"; do
            if [[ "$dg_path" == "$known_path" ]]; then
                found=1
                break
            fi
        done
        [[ $found -eq 1 ]] || die "asm_diskgroup_disks entry not found in disks_use_by_asm: $dg_disk"
    done
}

parse_asm_config() {
    ASM_DISK_ENTRIES=()
    ASM_DISKGROUP_DISK_LIST=()

    if [[ -n "${disks_use_by_asm:-}" ]]; then
        local IFS='+'
        read -ra ASM_DISK_ENTRIES <<< "$disks_use_by_asm"
    fi

    if [[ -n "${asm_diskgroup_disks:-}" ]]; then
        local disk_spec dg_path
        IFS=',' read -ra _dg_disk_specs <<< "$asm_diskgroup_disks"
        for disk_spec in "${_dg_disk_specs[@]}"; do
            [[ -z "${disk_spec// /}" ]] && continue
            dg_path=$(normalize_asm_disk_dev_path "$disk_spec") || \
                die "Invalid asm_diskgroup_disks entry: $disk_spec"
            ASM_DISKGROUP_DISK_LIST+=("$dg_path")
        done
    fi

    case "${asm_diskgroup_redundancy^^}" in
        NORMAL|HIGH|EXTERNAL) asm_diskgroup_redundancy="${asm_diskgroup_redundancy^^}" ;;
        *) die "Invalid asm_diskgroup_redundancy: $asm_diskgroup_redundancy (NORMAL|HIGH|EXTERNAL)" ;;
    esac

    ASM_DISKGROUP_AUSIZE_MB=$(parse_asm_diskgroup_ausize "$asm_diskgroup_ausize")

    if need_asm_storage && [[ ${#ASM_DISK_ENTRIES[@]} -gt 0 && ${#ASM_DISKGROUP_DISK_LIST[@]} -gt 0 ]]; then
        validate_asm_diskgroup_disks
    fi

    export ASM_DISK_ENTRIES ASM_DISKGROUP_DISK_LIST ASM_DISKGROUP_AUSIZE_MB
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

is_asm_standalone() {
    [[ "$ora_type" == "asm" ]]
}
