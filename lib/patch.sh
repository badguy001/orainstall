#!/bin/bash
# Oracle patch installation and OPatch upgrade

opatch_backup_suffix() {
    date '+%Y%m%d_%H%M%S'
}

gi_software_installed() {
    need_gi && [[ -d "$gi_home" && -x "${gi_home}/OPatch/opatch" ]]
}

find_opatch_dir_in_staging() {
    local staging="$1"

    if [[ -d "$staging/OPatch" && -f "$staging/OPatch/opatch" ]]; then
        echo "$staging/OPatch"
        return 0
    fi

    local opatch_bin
    opatch_bin=$(find "$staging" -type f -name opatch -path '*/OPatch/opatch' 2>/dev/null | head -1)
    if [[ -n "$opatch_bin" ]]; then
        dirname "$opatch_bin"
        return 0
    fi

    return 1
}

verify_opatch() {
    local oracle_home="$1"
    local run_user="$2"

    [[ -x "${oracle_home}/OPatch/opatch" ]] || \
        die "OPatch binary not found after upgrade: ${oracle_home}/OPatch/opatch"

    log_info "Verifying OPatch for $oracle_home (user=$run_user)"
    run_as_user "$run_user" "
        export ORACLE_HOME=${oracle_home}
        export PATH=\$ORACLE_HOME/OPatch:\$PATH
        \$ORACLE_HOME/OPatch/opatch version
    " 2>&1 | tee -a "$LOG_FILE" || die "OPatch verification failed for $oracle_home"

    log_info "OPatch verification passed for $oracle_home"
}

upgrade_opatch_db() {
    local opatch_zip
    opatch_zip=$(abs_path "$1") || die "Invalid OPatch file path: $1"
    [[ -f "$opatch_zip" ]] || die "OPatch file not found: $opatch_zip"

    [[ -d "$db_home" ]] || { log_warn "DB ORACLE_HOME does not exist; skipping OPatch upgrade"; return 0; }

    local backup_name
    backup_name="OPatch_$(opatch_backup_suffix)"

    log_info "Upgrading DB OPatch: $opatch_zip -> $db_home (user=$db_user)"

    run_as_user "$db_user" "
        set -e
        if [[ -d ${db_home}/OPatch ]]; then
            mv ${db_home}/OPatch ${db_home}/${backup_name}
        fi
        unzip -qo '${opatch_zip}' -d ${db_home}
        if [[ ! -d ${db_home}/OPatch ]]; then
            opatch_src=\$(find ${db_home} -maxdepth 4 -type f -name opatch -path '*/OPatch/opatch' 2>/dev/null | head -1)
            if [[ -n \"\$opatch_src\" ]]; then
                opatch_src=\$(dirname \"\$opatch_src\")
                rm -rf ${db_home}/OPatch 2>/dev/null || true
                mv \"\$opatch_src\" ${db_home}/OPatch
            fi
        fi
        chmod +x ${db_home}/OPatch/opatch 2>/dev/null || true
    " 2>&1 | tee -a "$LOG_FILE" || die "DB OPatch upgrade failed: $opatch_zip"

    verify_opatch "$db_home" "$db_user"
}

upgrade_opatch_gi() {
    local opatch_zip
    opatch_zip=$(abs_path "$1") || die "Invalid OPatch file path: $1"
    [[ -f "$opatch_zip" ]] || die "OPatch file not found: $opatch_zip"

    [[ -d "$gi_home" ]] || { log_warn "GI ORACLE_HOME does not exist; skipping OPatch upgrade"; return 0; }

    local staging backup_name opatch_dir
    ensure_unzip_dir "/opt/oracle_staging/opatch_gi_$(basename "$opatch_zip" .zip)_$(opatch_backup_suffix)" "$gi_user"
    staging="$UNZIP_STAGING_DIR"
    backup_name="OPatch_$(opatch_backup_suffix)"

    log_info "Upgrading GI OPatch: $opatch_zip -> $gi_home (root backup/move, user=$gi_user extract)"

    if [[ -d "${gi_home}/OPatch" ]]; then
        mv "${gi_home}/OPatch" "${gi_home}/${backup_name}"
        log_info "Backed up GI OPatch: ${gi_home}/${backup_name}"
    else
        log_warn "No existing OPatch at ${gi_home}/OPatch; proceeding with fresh install"
    fi

    run_as_user "$gi_user" "unzip -qo '${opatch_zip}' -d '${staging}'" 2>&1 | tee -a "$LOG_FILE" || \
        die "GI OPatch extraction failed: $opatch_zip"

    opatch_dir=$(find_opatch_dir_in_staging "$staging") || \
        die "OPatch directory not found in: $opatch_zip (staging=$staging)"

    rm -rf "${gi_home}/OPatch"
    mv "$opatch_dir" "${gi_home}/OPatch"
    # no need to chown and chmod, because the opatch is already owned by the gi_user
    # chown -R "${gi_user}:${oinstall_group}" "${gi_home}/OPatch"
    # chmod +x "${gi_home}/OPatch/opatch" 2>/dev/null || true

    verify_opatch "$gi_home" "$gi_user"
}

upgrade_opatch() {
    if [[ ${#OPATCH_ENTRIES[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "${SKIP_SOFTWARE_INSTALL:-0}" == "1" ]]; then
        return 0
    fi

    log_info "Upgrading OPatch..."

    local entry opatch_file target
    for entry in "${OPATCH_ENTRIES[@]}"; do
        entry=$(echo "$entry" | xargs)
        [[ -z "$entry" ]] && continue

        opatch_file="${entry%%:*}"
        target="${entry##*:}"

        opatch_file=$(abs_path "$opatch_file") || die "Invalid OPatch file path: ${entry%%:*}"
        [[ -f "$opatch_file" ]] || die "OPatch file not found: $opatch_file"

        case "$target" in
            gi)
                if need_gi; then
                    upgrade_opatch_gi "$opatch_file"
                else
                    log_warn "Skipping GI OPatch upgrade (GI not in deployment): $opatch_file"
                fi
                ;;
            db)
                upgrade_opatch_db "$opatch_file"
                ;;
            gidb|dbgi)
                if need_gi; then
                    upgrade_opatch_gi "$opatch_file"
                fi
                upgrade_opatch_db "$opatch_file"
                ;;
            *)
                log_warn "Unknown OPatch target: $target (gi|db|gidb); skipping $opatch_file"
                ;;
        esac
    done

    log_info "OPatch upgrade complete"
}

apply_patches() {
    if [[ ${#PATCH_ENTRIES[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "${SKIP_SOFTWARE_INSTALL:-0}" == "1" ]]; then
        return 0
    fi

    log_info "Applying patches..."

    local entry patch_file target staging
    for entry in "${PATCH_ENTRIES[@]}"; do
        entry=$(echo "$entry" | xargs)
        [[ -z "$entry" ]] && continue

        patch_file="${entry%%:*}"
        target="${entry##*:}"

        patch_file=$(abs_path "$patch_file") || die "Invalid patch file path: ${entry%%:*}"
        [[ -f "$patch_file" ]] || die "Patch file not found: $patch_file"

        ensure_unzip_dir "/opt/oracle_staging/patch_$(basename "$patch_file" .zip)"
        staging="$UNZIP_STAGING_DIR"
        log_info "Extracting patch: $patch_file -> $staging"
        unzip -qo "$patch_file" -d "$staging"

        case "$target" in
            gi)
                chown -R "$gi_user:$oinstall_group" "$staging"
                apply_patch_subdirs_to_home "$staging" "$gi_home" "$gi_user"
                ;;
            db)
                chown -R "$db_user:$oinstall_group" "$staging"
                apply_patch_subdirs_to_home "$staging" "$db_home" "$db_user"
                ;;
            gidb)
                if gi_software_installed; then
                    chown -R "$gi_user:$oinstall_group" "$staging"
                    apply_patch_auto_subdirs_to_home "$staging" "$gi_home"
                    chown -R "$db_user:$oinstall_group" "$staging"
                    apply_patch_auto_subdirs_to_home "$staging" "$db_home"
                else
                    chown -R "$db_user:$oinstall_group" "$staging"
                    apply_patch_level2_subdirs_to_home "$staging" "$db_home" "$db_user"
                fi
                ;;
            *)
                log_warn "Unknown patch target: $target (gi|db|gidb); skipping $patch_file"
                ;;
        esac
    done

    log_info "Patch application complete"
}

apply_patch_auto_subdirs_to_home() {
    local staging="$1"
    local oracle_home="$2"

    [[ -d "$oracle_home" ]] || { log_warn "ORACLE_HOME does not exist; skipping patch: $oracle_home"; return 0; }

    if [[ ! -x "${oracle_home}/OPatch/opatch" ]]; then
        log_warn "OPatch not found: ${oracle_home}/OPatch/opatch"
        return 0
    fi

    staging=$(abs_path "$staging") || die "Invalid patch staging directory: $staging"

    local subdir found=0
    for subdir in "$staging"/*/; do
        [[ -d "$subdir" ]] || continue
        subdir="${subdir%/}"
        subdir=$(abs_path "$subdir") || continue

        found=1
        log_info "Applying patch (opatch auto) to $oracle_home (root, dir=$subdir)"

        ORACLE_HOME="$oracle_home" \
            "${oracle_home}/OPatch/opatch" auto "$subdir" -oh "$oracle_home" \
            2>&1 | tee -a "$LOG_FILE" || log_warn "opatch auto may have failed: $subdir -> $oracle_home"
    done

    if [[ "$found" -eq 0 ]]; then
        log_warn "No patch subdirectories found in: $staging"
    fi
}

apply_patch_subdirs_to_home() {
    local staging="$1"
    local oracle_home="$2"
    local run_user="$3"

    [[ -d "$oracle_home" ]] || { log_warn "ORACLE_HOME does not exist; skipping patch: $oracle_home"; return 0; }

    if [[ ! -x "${oracle_home}/OPatch/opatch" ]]; then
        log_warn "OPatch not found: ${oracle_home}/OPatch/opatch"
        return 0
    fi

    local subdir found=0
    for subdir in "$staging"/*/; do
        [[ -d "$subdir" ]] || continue
        subdir="${subdir%/}"
        subdir=$(abs_path "$subdir") || continue

        found=1
        log_info "Applying patch to $oracle_home (user=$run_user, dir=$subdir)"

        run_as_user "$run_user" "
            export ORACLE_HOME=${oracle_home}
            \$ORACLE_HOME/OPatch/opatch apply '${subdir}' -oh ${oracle_home}
        " 2>&1 | tee -a "$LOG_FILE" || log_warn "opatch apply may have failed: $subdir -> $oracle_home"
    done

    if [[ "$found" -eq 0 ]]; then
        log_warn "No patch subdirectories found in: $staging"
    fi
}

apply_patch_level2_subdirs_to_home() {
    local staging="$1"
    local oracle_home="$2"
    local run_user="$3"

    [[ -d "$oracle_home" ]] || { log_warn "ORACLE_HOME does not exist; skipping patch: $oracle_home"; return 0; }

    if [[ ! -x "${oracle_home}/OPatch/opatch" ]]; then
        log_warn "OPatch not found: ${oracle_home}/OPatch/opatch"
        return 0
    fi

    staging=$(abs_path "$staging") || die "Invalid patch staging directory: $staging"

    local level1 subdir found=0
    for level1 in "$staging"/*/; do
        [[ -d "$level1" ]] || continue
        for subdir in "$level1"/*/; do
            [[ -d "$subdir" ]] || continue
            subdir="${subdir%/}"
            subdir=$(abs_path "$subdir") || continue

            found=1
            log_info "Applying patch to $oracle_home (user=$run_user, dir=$subdir)"

            run_as_user "$run_user" "
                export ORACLE_HOME=${oracle_home}
                \$ORACLE_HOME/OPatch/opatch apply '${subdir}' -oh ${oracle_home}
            " 2>&1 | tee -a "$LOG_FILE" || log_warn "opatch apply may have failed: $subdir -> $oracle_home"
        done
    done

    if [[ "$found" -eq 0 ]]; then
        log_warn "No level-2 patch subdirectories found in: $staging"
    fi
}
