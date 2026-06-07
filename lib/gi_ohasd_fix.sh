#!/bin/bash
# 11gR2 GI init.ohasd workaround for RHEL/CentOS 7/8, openEuler, Kylin

GI_OHASD_MONITOR_PID=""
GI_OHASD_RUN_FLAG=""

need_gi_ohasd_inittab_fix() {
    is_legacy_gi_version || return 1

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

inittab_has_init_ohasd() {
    [[ -f /etc/inittab ]] && grep -q '/etc/init.d/init.ohasd' /etc/inittab 2>/dev/null
}

init_ohasd_already_run() {
    [[ -n "${GI_OHASD_RUN_FLAG:-}" && -f "$GI_OHASD_RUN_FLAG" ]]
}

run_init_ohasd_once() {
    init_ohasd_already_run && return 0
    inittab_has_init_ohasd || return 1
    [[ -x /etc/init.d/init.ohasd ]] || return 1

    : > "$GI_OHASD_RUN_FLAG"
    log_info "Running /etc/init.d/init.ohasd run (11gR2 GI workaround, once only)"
    /etc/init.d/init.ohasd run >/dev/null 2>&1 </dev/null
}

monitor_inittab_init_ohasd() {
    local timeout="${1:-14400}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if init_ohasd_already_run; then
            return 0
        fi
        if inittab_has_init_ohasd; then
            run_init_ohasd_once && return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_warn "Timed out waiting for init.ohasd entry in /etc/inittab (11gR2 GI workaround monitor)"
}

start_gi_ohasd_inittab_monitor() {
    need_gi_ohasd_inittab_fix || return 0

    GI_OHASD_RUN_FLAG="${LOG_DIR}/gi_init_ohasd_run_done"
    rm -f "$GI_OHASD_RUN_FLAG"

    log_info "Starting /etc/inittab init.ohasd monitor for 11gR2 GI (OS: ${OS_NAME})"
    monitor_inittab_init_ohasd &
    GI_OHASD_MONITOR_PID=$!
    log_info "11gR2 GI init.ohasd monitor started (pid=$GI_OHASD_MONITOR_PID)"
}

stop_gi_ohasd_inittab_monitor() {
    if [[ -n "${GI_OHASD_MONITOR_PID:-}" ]] && kill -9 "$GI_OHASD_MONITOR_PID" 2>/dev/null; then
        kill "$GI_OHASD_MONITOR_PID" 2>/dev/null || true
        wait "$GI_OHASD_MONITOR_PID" 2>/dev/null || true
    fi
    GI_OHASD_MONITOR_PID=""

    # kill_init_ohasd_processes
}

kill_init_ohasd_processes() {
    local pids pid

    if command -v pgrep &>/dev/null; then
        pids=$(pgrep -f '/etc/init.d/init.ohasd' 2>/dev/null || true)
    else
        pids=$(ps -eo pid=,args= 2>/dev/null | grep '/etc/init.d/init.ohasd' | grep -v grep | awk '{print $1}' || true)
    fi

    [[ -n "$pids" ]] || return 0

    for pid in $pids; do
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        kill -0 "$pid" 2>/dev/null || continue
        log_info "Stopping init.ohasd process (pid=$pid)"
        kill "$pid" 2>/dev/null || true
    done
}
