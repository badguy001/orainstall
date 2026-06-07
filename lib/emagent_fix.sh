#!/bin/bash
# 11gR2 EM agent ins_emagent.mk fix for newer Linux (RHEL/CentOS 7/8, openEuler, Kylin)

EMAGENT_MONITOR_PID=""
EMAGENT_FIX_APPLIED=0

need_11g_emagent_fix() {
    is_legacy_db_version || return 1

    case "${OS_ID,,}" in
        rhel|centos)
            [[ "$OS_MAJOR" -eq 7 || "$OS_MAJOR" -eq 8 ]]
            ;;
        openeuler|openeuler|kylin)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apply_ins_emagent_mk_fix() {
    local mk_file="${db_home}/sysman/lib/ins_emagent.mk"

    [[ -f "$mk_file" ]] || return 1

    if grep -q 'MK_EMAGENT_NMECTL) -lnnz11' "$mk_file" 2>/dev/null; then
        EMAGENT_FIX_APPLIED=1
        return 0
    fi

    if ! grep -q 'MK_EMAGENT_NMECTL)' "$mk_file" 2>/dev/null; then
        return 1
    fi

    sed -i 's/\$(MK_EMAGENT_NMECTL)/\$(MK_EMAGENT_NMECTL) -lnnz11/g' "$mk_file"
    chown "${db_user}:${oinstall_group}" "$mk_file" 2>/dev/null || true
    EMAGENT_FIX_APPLIED=1
    log_info "Applied 11g EM agent fix: $mk_file (\$(MK_EMAGENT_NMECTL) -lnnz11)"
    return 0
}

monitor_ins_emagent_mk() {
    local mk_file="${db_home}/sysman/lib/ins_emagent.mk"
    local timeout="${1:-7200}"
    local elapsed=0
    local interval=1

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "$mk_file" ]]; then
            apply_ins_emagent_mk_fix && return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "Timed out waiting for $mk_file (11g EM agent fix monitor)"
    return 1
}

start_emagent_mk_monitor() {
    need_11g_emagent_fix || return 0

    log_info "Starting ins_emagent.mk monitor for 11g EM agent fix (OS: ${OS_NAME})"
    monitor_ins_emagent_mk &
    EMAGENT_MONITOR_PID=$!
    log_info "11g EM agent monitor started (pid=$EMAGENT_MONITOR_PID, watch=${db_home}/sysman/lib/ins_emagent.mk)"
}

stop_emagent_mk_monitor() {
    if [[ -n "${EMAGENT_MONITOR_PID:-}" ]] && kill -0 "$EMAGENT_MONITOR_PID" 2>/dev/null; then
        kill "$EMAGENT_MONITOR_PID" 2>/dev/null || true
        wait "$EMAGENT_MONITOR_PID" 2>/dev/null || true
    fi
    EMAGENT_MONITOR_PID=""

    if [[ "${EMAGENT_FIX_APPLIED:-0}" -eq 0 ]]; then
        apply_ins_emagent_mk_fix 2>/dev/null || true
    fi
}
