#!/bin/bash
# Common function library

set -euo pipefail
set +H  # Disable history expansion to avoid issues with ! in passwords

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE=""
LOG_DIR=""

log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        mkdir -p "$log_dir" 2>/dev/null || true
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || echo "$msg" >&2
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# Log passwords safely without shell expansion of special characters
log_secret() {
    local key="$1"
    local value="$2"
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] ${key}=${value}"
    printf '%s\n' "$msg" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        mkdir -p "$log_dir" 2>/dev/null || true
        printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || printf '%s\n' "$msg" >&2
    fi
}

generate_strong_password() {
    local len="${1:-16}"
    local password=""

    # tr|head may return non-zero under pipefail due to SIGPIPE, causing set -e to exit
    password=$(tr -dc 'A-Za-z0-9@#%^_-' </dev/urandom 2>/dev/null | head -c "$len" || true)

    if [[ ${#password} -lt "$len" ]] && command -v openssl &>/dev/null; then
        password=$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len" || true)
    fi

    if [[ ${#password} -lt 8 ]]; then
        password=$(date +%s%N | sha256sum 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len" || true)
    fi

    [[ -n "$password" ]] || die "Failed to generate random password"
    printf '%s' "$password"
}

die() {
    log_error "$@"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

backup_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        cp -a "$f" "${f}.bak.$(date '+%Y%m%d%H%M%S')}"
    fi
    return 0
}

append_unique_line() {
    local file="$1"
    local line="$2"
    if ! grep -qF "$line" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
    fi
    return 0
}

# Resolve to absolute path (required before su -, which changes working directory)
abs_path() {
    local path="$1"
    [[ -n "$path" ]] || return 1

    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
        return 0
    fi

    if command -v readlink &>/dev/null; then
        local resolved
        resolved=$(readlink -f "$path" 2>/dev/null) || true
        if [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    fi

    local dir base
    dir=$(dirname "$path")
    base=$(basename "$path")
    if [[ "$dir" == "." ]]; then
        printf '%s/%s\n' "$(pwd)" "$base"
    else
        printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
    fi
}

run_as_user() {
    local user="$1"
    local cmd="$2"
    su - "$user" -c "$cmd"
}

run_as_oracle() {
    run_as_user "$ORACLE_USER" "$1"
}

run_as_grid() {
    run_as_user "$GI_USER" "$1"
}

get_oracle_version_num() {
    version_to_num "$ORACLE_VERSION"
}

get_gi_version_num() {
    version_to_num "${gi_version:-$ORACLE_VERSION}"
}

# runInstaller / setup.sh prereq ignore flags (vary by version)
# 11gR1/R2: -ignoreSysPrereqs -ignorePrereq
# 12cR1/R2, 18c, 19c: -ignorePrereqFailure
get_installer_prereq_flags() {
    local version="$1"

    case "$version" in
        11gR1|11gR2)
            echo "-ignoreSysPrereqs -ignorePrereq"
            ;;
        12cR1|12cR2|18c|19c)
            echo "-ignorePrereqFailure"
            ;;
        *)
            log_warn "Unknown Oracle version $version, defaulting to -ignorePrereqFailure"
            echo "-ignorePrereqFailure"
            ;;
    esac
}

is_cdb_supported() {
    [[ "$ORACLE_VERSION" != "11gR1" && "$ORACLE_VERSION" != "11gR2" ]]
}

# 11g uses DBA_GROUP/OPER_GROUP; 12c+ uses OSDBA_GROUP and extended groups
is_legacy_db_version() {
    case "${1:-$db_version}" in
        11gR1|11gR2) return 0 ;;
        *) return 1 ;;
    esac
}

supports_extended_db_groups() {
    case "${1:-$db_version}" in
        12cR1|12cR2|18c|19c) return 0 ;;
        *) return 1 ;;
    esac
}

is_legacy_gi_version() {
    case "${1:-${gi_version:-}}" in
        11gR2) return 0 ;;
        *) return 1 ;;
    esac
}

get_db_install_rsp_schema() {
    case "${1:-$db_version}" in
        11gR1|11gR2) echo "/oracle/install/rspfmt_dbinstall_response_schema_v11_2_0" ;;
        12cR1|12cR2) echo "/oracle/install/rspfmt_dbinstall_response_schema_v12_0_0" ;;
        18c)         echo "/oracle/install/rspfmt_dbinstall_response_schema_v18.0.0" ;;
        19c)         echo "/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0" ;;
        *)           echo "/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0" ;;
    esac
}

get_gi_install_rsp_schema() {
    case "${1:-${gi_version:-}}" in
        11gR2)       echo "/oracle/install/rspfmt_ginstall_response_schema_v11_2_0" ;;
        12cR1|12cR2) echo "/oracle/install/rspfmt_ginstall_response_schema_v12_0_0" ;;
        18c)         echo "/oracle/install/rspfmt_ginstall_response_schema_v18.0.0" ;;
        19c)         echo "/oracle/install/rspfmt_ginstall_response_schema_v19.0.0" ;;
        *)           echo "/oracle/install/rspfmt_ginstall_response_schema_v19.0.0" ;;
    esac
}

get_dbca_rsp_schema() {
    case "${1:-$db_version}" in
        11gR1|11gR2) echo "/oracle/assistants/rspfmt_dbca_response_schema_v11.2.0" ;;
        12cR1|12cR2) echo "/oracle/assistants/rspfmt_dbca_response_schema_v12.0.0" ;;
        18c)         echo "/oracle/assistants/rspfmt_dbca_response_schema_v18.0.0" ;;
        19c)         echo "/oracle/assistants/rspfmt_dbca_response_schema_v19.0.0" ;;
        *)           echo "/oracle/assistants/rspfmt_dbca_response_schema_v19.0.0" ;;
    esac
}

# Return the three ASM groups for GI response files (11g fixed asmdba/asmoper/asmadmin)
get_gi_asm_group_names() {
    if is_legacy_gi_version; then
        echo "asmdba asmoper asmadmin"
    elif [[ "$group_mode" == "simple" ]]; then
        echo "dba asmoper asmadmin"
    else
        echo "asmdba asmoper asmadmin"
    fi
}

remote_exec() {
    local host="$1"
    local cmd="$2"
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${host}" "$cmd"
}

remote_copy() {
    local src="$1"
    local host="$2"
    local dest="$3"
    scp -o StrictHostKeyChecking=no -r "$src" "root@${host}:${dest}"
}

get_local_hostname() {
    hostname -s
}

find_disk_by_name_or_wwid() {
    local disk_name="${1:-}"
    local wwid="${2:-}"

    if [[ -n "$wwid" ]]; then
        local dev
        dev=$(ls -l /dev/disk/by-id/ 2>/dev/null | grep -F "$wwid" | awk '{print $NF}' | head -1)
        if [[ -n "$dev" ]]; then
            basename "$(readlink -f "/dev/disk/by-id/${dev}")"
            return 0
        fi
        dev=$(multipath -ll 2>/dev/null | awk -v w="$wwid" '$0 ~ w {print $1; exit}')
        [[ -n "$dev" ]] && { echo "$dev"; return 0; }
    fi

    if [[ -n "$disk_name" ]]; then
        [[ -b "/dev/${disk_name}" ]] && { echo "$disk_name"; return 0; }
        [[ -b "$disk_name" ]] && { basename "$disk_name"; return 0; }
    fi

    return 1
}

get_disk_wwid() {
    local disk="$1"
    local wwid
    wwid=$(/usr/lib/udev/scsi_id -g -u "/dev/${disk}" 2>/dev/null || true)
    [[ -n "$wwid" ]] || wwid=$(/lib/udev/scsi_id -g -u "/dev/${disk}" 2>/dev/null || true)
    echo "$wwid"
}

is_local_hostname() {
    local name="$1"
    local local_s local_f local_h
    local_s=$(hostname -s 2>/dev/null || true)
    local_f=$(hostname -f 2>/dev/null || true)
    local_h=$(hostname 2>/dev/null || true)
    [[ "$name" == "$local_s" || "$name" == "$local_f" || "$name" == "$local_h" ]]
}

resolve_host_ip() {
    local hostname="$1"
    local ip="${2:-}"

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    if is_local_hostname "$hostname"; then
        detect_local_ip
        return 0
    fi

    ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1; exit}')
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    # Standalone/asm: auto-detect local IP when IP is empty
    if [[ "${ora_type:-oracle}" == "oracle" || "${ora_type:-}" == "asm" ]]; then
        log_info "Host $hostname has no IP and DNS/hosts did not resolve; auto-detecting local IP"
        detect_local_ip
        return 0
    fi

    echo ""
}

detect_local_ip() {
    local gw dev ip
    gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if [[ -n "$gw" ]]; then
        dev=$(ip route get "$gw" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
        if [[ -n "$dev" ]]; then
            ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
            [[ -n "$ip" ]] && { echo "$ip"; return 0; }
        fi
    fi

    ip=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {
        split($2,a,"/"); print a[1], $NF
    }' | while read -r addr ifname; do
        if [[ "$ifname" != "lo" && "$addr" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
            echo "$addr"; exit 0
        fi
    done)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }

    ip=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]; exit}')
    echo "$ip"
}

is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    return 1
}

ensure_unzip_dir() {
    local base="$1"
    mkdir -p "$base"
    echo "$base"
}

unzip_media_files() {
    local dest="$1"
    shift
    local f zipdir

    [[ $# -gt 0 ]] || die "No install files specified"

    mkdir -p "$dest"
    for f in "$@"; do
        f=$(echo "$f" | xargs)
        [[ -f "$f" ]] || die "Install file not found: $f"
        log_info "Extracting: $f -> $dest"
        unzip -qo "$f" -d "$dest"
    done

    # Find runInstaller root directory
    if [[ -x "${dest}/runInstaller" ]]; then
        echo "$dest"
    elif [[ -x "${dest}/grid/runInstaller" ]]; then
        echo "${dest}/grid"
    elif [[ -x "${dest}/database/runInstaller" ]]; then
        echo "${dest}/database"
    else
        zipdir=$(find "$dest" -maxdepth 3 -name runInstaller -type f 2>/dev/null | head -1)
        if [[ -n "$zipdir" ]]; then
            dirname "$zipdir"
            return 0
        fi
        die "runInstaller not found after extraction: $dest"
    fi
}
