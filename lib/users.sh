#!/bin/bash
# OS user and group creation (UID/GID starting at 54321)

create_oracle_users() {
    log_info "Creating Oracle users and groups (group_mode=$group_mode db=$db_version)..."

    local next_gid=54321
    local next_uid=54321

    create_group "$oinstall_group" "$next_gid"
    next_gid=$(( next_gid + 1 ))

    # DB groups: 11g only dba/oper; 12c+ detail mode adds backupdba/dgdba/kmdba/racdba
    for g in dba oper; do
        create_group "$g" "$next_gid"
        next_gid=$(( next_gid + 1 ))
    done

    if supports_extended_db_groups && [[ "$group_mode" == "detail" ]]; then
        for g in backupdba dgdba kmdba racdba; do
            create_group "$g" "$next_gid"
            next_gid=$(( next_gid + 1 ))
        done
    fi

    # GI groups: 11g/12c require asmdba/asmoper/asmadmin
    if need_gi; then
        for g in asmdba asmoper asmadmin; do
            create_group "$g" "$next_gid"
            next_gid=$(( next_gid + 1 ))
        done
    fi

    if need_gi; then
        local gi_groups="$oinstall_group"
        read -r _gi_osdba _gi_osoper _gi_osasm <<< "$(get_gi_asm_group_names)"
        gi_groups="$oinstall_group,${_gi_osdba},${_gi_osoper},${_gi_osasm}"
        create_user "$gi_user" "$next_uid" "$oinstall_group" "$gi_groups" "$gi_base"
        next_uid=$(( next_uid + 1 ))
        echo "${gi_user}:${gi_pwd}" | chpasswd
    fi

    local db_groups="$oinstall_group,dba"
    if is_legacy_db_version; then
        if [[ "$group_mode" == "detail" ]]; then
            db_groups="$oinstall_group,dba,oper"
        fi
    elif [[ "$group_mode" == "detail" ]]; then
        if need_gi; then
            db_groups="$oinstall_group,dba,oper,backupdba,dgdba,kmdba,racdba,asmdba"
        else
            db_groups="$oinstall_group,dba,oper,backupdba,dgdba,kmdba,racdba"
        fi
    fi

    create_user "$db_user" "$next_uid" "$oinstall_group" "$db_groups" "$db_base"
    echo "${db_user}:${db_pwd}" | chpasswd

    log_info "User creation complete: gi=$gi_user db=$db_user"
}

create_group() {
    local name="$1"
    local gid="$2"
    if getent group "$name" &>/dev/null; then
        log_info "Group $name already exists"
    else
        groupadd -g "$gid" "$name"
        log_info "Created group: $name (gid=$gid)"
    fi
}

create_user() {
    local name="$1"
    local uid="$2"
    local primary="$3"
    local supplementary="$4"
    local home="$5"

    if id "$name" &>/dev/null; then
        log_info "User $name already exists"
        usermod -aG "$supplementary" "$name" 2>/dev/null || true
    else
        useradd -u "$uid" -g "$primary" -G "$supplementary" \
            -d "$home" -s /bin/bash "$name"
        log_info "Created user: $name (uid=$uid)"
    fi
    mkdir -p "$home"
    chown "${name}:${primary}" "$home"
}
