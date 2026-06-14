#!/bin/bash
# 11gR2 DB sysliblist -laio fix for RHEL/CentOS 8, openEuler, Kylin

SYSLIBLIST_MONITOR_PID=""
SYSLIBLIST_FIX_APPLIED=0

need_11g_sysliblist_fix() {
    [[ "$db_version" == "11gR2" ]] || return 1

    case "${OS_ID,,}" in
        rhel|centos)
            [[ "$OS_MAJOR" -eq 8 ]]
            ;;
        openeuler|openeuler|kylin)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apply_sysliblist_fix() {
    local file="${db_home}/lib/sysliblist"
    local old_libs="-ldl -lm -lpthread -lnsl -lirc -lipgo -lsvml"
    local new_libs="${old_libs} -laio"

    [[ -f "$file" ]] || return 1

    if grep -qF "${new_libs}" "$file" 2>/dev/null; then
        SYSLIBLIST_FIX_APPLIED=1
        return 0
    fi

    if ! grep -qF "$old_libs" "$file" 2>/dev/null; then
        return 1
    fi

    sed -i "s/${old_libs}/${new_libs}/g" "$file"
    chown "${db_user}:${oinstall_group}" "$file" 2>/dev/null || true
    SYSLIBLIST_FIX_APPLIED=1
    log_info "Applied 11gR2 sysliblist fix: $file (append -laio)"
    return 0
}

monitor_sysliblist() {
    local file="${db_home}/lib/sysliblist"
    local timeout="${1:-7200}"
    local elapsed=0
    local interval=1

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "$file" ]]; then
            apply_sysliblist_fix && return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "Timed out waiting for $file (11gR2 sysliblist fix monitor)"
    return 1
}

start_sysliblist_monitor() {
    need_11g_sysliblist_fix || return 0

    log_info "Starting sysliblist monitor for 11gR2 DB install (OS: ${OS_NAME})"
    monitor_sysliblist &
    SYSLIBLIST_MONITOR_PID=$!
    log_info "11gR2 sysliblist monitor started (pid=$SYSLIBLIST_MONITOR_PID, watch=${db_home}/lib/sysliblist)"
}

stop_sysliblist_monitor() {
    if [[ -n "${SYSLIBLIST_MONITOR_PID:-}" ]] && kill -0 "$SYSLIBLIST_MONITOR_PID" 2>/dev/null; then
        kill "$SYSLIBLIST_MONITOR_PID" 2>/dev/null || true
        wait "$SYSLIBLIST_MONITOR_PID" 2>/dev/null || true
    fi
    SYSLIBLIST_MONITOR_PID=""

    if [[ "${SYSLIBLIST_FIX_APPLIED:-0}" -eq 0 ]]; then
        apply_sysliblist_fix 2>/dev/null || true
    fi
}
