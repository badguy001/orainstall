#!/bin/bash
# RAC node SSH trust setup (shared key pair on all nodes, hostname-only known_hosts)

setup_ssh_trust() {
    if ! is_rac; then
        return 0
    fi

    log_info "Configuring RAC node SSH trust..."

    get_pkg_manager
    case "$PKG_MGR" in
        dnf|yum) $PKG_MGR install -y sshpass 2>/dev/null || true ;;
        zypper)  zypper -n install sshpass 2>/dev/null || true ;;
    esac

    get_rac_node_hostnames
    get_rac_public_ips

    local i host ip
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        [[ "$host" == "$(get_local_hostname)" ]] && continue
        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" "hostname" 2>/dev/null || \
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" "hostname" 2>/dev/null || \
            log_warn "Cannot connect to node $host; check root_pwd and network"
    done

    #local kh_blob="${LOG_DIR}/rac_known_hosts.blob"
    #build_rac_known_hosts_blob > "$kh_blob"
    #[[ -s "$kh_blob" ]] || log_warn "No RAC host keys collected; check network/DNS and node hostnames"

    local users=("$db_user")
    if need_gi; then
        users+=("$gi_user")
    fi
    users+=("root")

    for u in "${users[@]}"; do
        setup_user_ssh_trust "$u" 
    done

    verify_rac_passwordless_ssh
}

get_user_home_dir() {
    local user="$1"

    if [[ "$user" == "root" ]]; then
        echo "/root"
        return 0
    fi

    getent passwd "$user" 2>/dev/null | cut -d: -f6
}

chown_user_path() {
    local user="$1"
    local path="$2"

    if [[ "$user" == "root" ]]; then
        chown -R "${user}:${user}" "$path" 2>/dev/null || true
    else
        chown -R "${user}:${oinstall_group}" "$path" 2>/dev/null || true
    fi
}

build_rac_known_hosts_blob() {
    local hostname

    get_rac_node_hostnames
    for hostname in "${RAC_NODE_HOSTS[@]}"; do
        [[ -n "$hostname" ]] || continue
        ssh-keyscan -H "$hostname" 2>/dev/null || true
    done
}

# useless function
merge_known_hosts_file() {
    local dest="$1"
    local src="$2"

    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dest")"
    touch "$dest"
    cat "$src" >> "$dest"
    awk 'NF && !seen[$0]++' "$dest" > "${dest}.tmp"
    mv "${dest}.tmp" "$dest"
}

# useless function
append_user_authorized_key() {
    local user="$1"
    local ssh_dir="$2"
    local pub_key="${ssh_dir}/id_rsa.pub"
    local auth_keys="${ssh_dir}/authorized_keys"

    [[ -f "$pub_key" ]] || return 0
    touch "$auth_keys"
    cat "$pub_key" >> "$auth_keys"
    sort -u "$auth_keys" -o "$auth_keys"
    chmod 600 "$auth_keys"
    chown_user_path "$user" "$auth_keys"
}

# useless function
set_user_ssh_key_permissions() {
    local user="$1"
    local ssh_dir="$2"

    chmod 700 "$ssh_dir"
    [[ -f "${ssh_dir}/id_rsa" ]] && chmod 600 "${ssh_dir}/id_rsa"
    [[ -f "${ssh_dir}/id_rsa.pub" ]] && chmod 644 "${ssh_dir}/id_rsa.pub"
    [[ -f "${ssh_dir}/authorized_keys" ]] && chmod 600 "${ssh_dir}/authorized_keys"
    [[ -f "${ssh_dir}/known_hosts" ]] && chmod 644 "${ssh_dir}/known_hosts"
    [[ -f "${ssh_dir}/config" ]] && chmod 600 "${ssh_dir}/config"
    chown_user_path "$user" "$ssh_dir"
}

# useless function
write_user_ssh_rac_config() {
    local user="$1"
    local ssh_dir="$2"
    local config_file="${ssh_dir}/config"
    local host_line tmp

    get_rac_node_hostnames
    [[ ${#RAC_NODE_HOSTS[@]} -gt 0 ]] || return 0

    host_line="${RAC_NODE_HOSTS[*]}"
    touch "$config_file"

    if grep -q '# >>> orainstall rac ssh >>>' "$config_file" 2>/dev/null; then
        tmp=$(mktemp)
        awk '
            $0 == "# >>> orainstall rac ssh >>>" { skip=1; next }
            $0 == "# <<< orainstall rac ssh <<<" { skip=0; next }
            !skip { print }
        ' "$config_file" > "$tmp"
        mv "$tmp" "$config_file"
    fi

    {
        echo ""
        echo "# >>> orainstall rac ssh >>>"
        echo "Host ${host_line}"
        echo "    BatchMode yes"
        echo "# <<< orainstall rac ssh <<<"
    } >> "$config_file"

    chmod 600 "$config_file"
    chown_user_path "$user" "$config_file"
}

# useless function
finalize_user_ssh_dir() {
    local user="$1"
    local ssh_dir="$2"
    local kh_blob="$3"

    append_user_authorized_key "$user" "$ssh_dir"
    if [[ -f "$kh_blob" ]]; then
        merge_known_hosts_file "${ssh_dir}/known_hosts" "$kh_blob"
    fi
    write_user_ssh_rac_config "$user" "$ssh_dir"
    set_user_ssh_key_permissions "$user" "$ssh_dir"
}

deploy_user_ssh_trust_all_nodes() {
    local user="$1"
    local host="$2"
    local kh_blob="$3"
    local id_file="$4"
    local pub_file="$5"
    local user_group=""
    local ssh_dir home

    [[ -n "$host" ]] || return 0
    home=$(get_user_home_dir "$user")
    [[ -n "$home" ]] || return 0
    ssh_dir="${home}/.ssh"
    if [[ "$user" == "root" ]]; then
        user_group="root:root"
    else
        user_group="${user}:${oinstall_group}"
    fi
    [[ -f "${id_file}" && -f "${pub_file}" ]] || {
        log_warn "Missing SSH keys for ${user}; skip deploy to ${host}"
        return 0
    }

    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
        "mkdir -p '${ssh_dir}' && chown -R '${user_group}' '${ssh_dir}' && chmod 700 '${ssh_dir}'" 2>/dev/null || {
        log_warn "Failed to prepare remote ssh_dir on ${host} for user ${user}"
        return 0
    }
    if [[ ! "$host" == "$(get_local_hostname)" ]]; then
        log_info "Backup remote id_file and pub_file on ${host} for user ${user}"
        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
            "[[ -f '${id_file}' ]] && mv -f '${id_file}' '${id_file}_$(date +%Y%m%d%H%M%S)' || true " 2>/dev/null || {
            log_warn "Failed to backup remote id_file on ${host} for user ${user}"
            return 0
        }
        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
            "[[ -f '${pub_file}' ]] && mv -f '${pub_file}' '${pub_file}_$(date +%Y%m%d%H%M%S)' || true " 2>/dev/null || {
            log_warn "Failed to backup remote pub_file on ${host} for user ${user}"
            return 0
        }
    fi 
    # copy id_file and pub_file to host
    sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no \
        "${id_file}" "${pub_file}" "root@${host}:${ssh_dir}" 2>/dev/null || {
        log_warn "Failed to copy SSH keys to ${host} for user ${user}"
        return 0
    }
    # append pub_file to authorized_keys
    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
        "cat '${pub_file}' >> '${ssh_dir}/authorized_keys'" 2>/dev/null || {
        log_warn "Failed to add public key to authorized_keys on ${host} for user ${user}"
        return 0
    }
    # read local file $kh_blob and append to known_hosts
    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
        "cat >> '${ssh_dir}/known_hosts'" < "$kh_blob" 2>/dev/null || {
        die "Failed to append known_hosts on ${host} for user ${user}"
    }
    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
        "chown '${user_group}' '${id_file}' '${pub_file}' '${ssh_dir}/authorized_keys' '${ssh_dir}/known_hosts' && chmod 600 '${id_file}' '${pub_file}' '${ssh_dir}/authorized_keys' '${ssh_dir}/known_hosts'" 2>/dev/null || {
        die "Failed to set permissions on ${host} for user ${user}"
    }
    log_info "SSH trust deployed to ${host} for user ${user}"
    return 0
}

setup_user_ssh_trust() {
    local user="$1"
    local kh_blob="/tmp/orainstall_known_hosts_$(date +%Y%m%d%H%M%S)"
    local home ssh_dir local_hn host ip

    home=$(get_user_home_dir "$user")
    [[ -n "$home" ]] || die "Home directory not found for user: $user"

    ssh_dir="${home}/.ssh"
    id_file="${ssh_dir}/id_rsa"
    pub_file="${ssh_dir}/id_rsa.pub"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown_user_path "$user" "$ssh_dir"

    if [[ ! -f "${id_file}" ]]; then
        ssh-keygen -t rsa -b 4096 -N "" -f "${id_file}" -q
    fi

    # finalize_user_ssh_dir "$user" "$ssh_dir" "$kh_blob"

    get_rac_node_hostnames
    get_rac_public_ips
    local_hn=$(get_local_hostname)
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        su - "$user" -c "ssh-keyscan '$host' >> '$kh_blob' 2>/dev/null"
    done
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        deploy_user_ssh_trust_all_nodes "$user" "$host" "$kh_blob" "$id_file" "$pub_file"
    done

    log_info "SSH trust configured for: $user (shared key on all nodes)"
}

run_passwordless_ssh_check() {
    local user="$1"
    local from_label="$2"
    local remote_ip="$3"
    local target="$4"

    if [[ "$from_label" == "local" ]]; then
        su - "$user" -c "ssh -o BatchMode=yes -o ConnectTimeout=10 '${target}' hostname" >/dev/null 2>&1
        return $?
    fi

    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${remote_ip}" \
        "su - '${user}' -c \"ssh -o BatchMode=yes -o ConnectTimeout=10 '${target}' hostname\"" >/dev/null 2>&1
}

verify_rac_passwordless_ssh() {
    local user host from_host remote_ip local_hn
    local users=("$db_user")
    local failed=0

    need_gi && users+=("$gi_user")
    get_rac_node_hostnames
    get_rac_public_ips
    local_hn=$(get_local_hostname)

    for user in "${users[@]}"; do
        for i in "${!RAC_NODE_HOSTS[@]}"; do
            from_host="${RAC_NODE_HOSTS[$i]}"
            remote_ip="${RAC_PUBLIC_IPS[$i]}"
            if [[ "$from_host" == "$local_hn" ]]; then
                from_label="local"
            else
                from_label="remote"
            fi

            for host in "${RAC_NODE_HOSTS[@]}"; do
                if run_passwordless_ssh_check "$user" "$from_label" "$remote_ip" "$host"; then
                    log_info "Passwordless SSH OK: ${user}@${from_host} -> ${host}"
                else
                    log_warn "Passwordless SSH check failed: ${user}@${from_host} -> ${host}"
                    failed=1
                fi
            done
        done
    done

    [[ $failed -eq 0 ]] || die "RAC SSH trust verification failed (shared keys / authorized_keys / known_hosts)"
}

dispatch_env_to_rac_nodes() {
    if ! is_rac; then
        return 0
    fi

    log_info "Syncing environment to remote RAC nodes (before SSH trust setup)..."
    local local_hn script_path host ip
    local_hn=$(get_local_hostname)
    script_path="$SCRIPT_DIR/install_oracle.sh"

    get_rac_node_hostnames
    get_rac_public_ips

    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        [[ "$host" == "$local_hn" ]] && continue

        log_info "Syncing environment configuration to node: $host"
        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no root@${ip} "mv -f /tmp/orainstall /tmp/orainstall_$(date +%Y%m%d%H%M%S)" || true
        sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no -r \
            "$SCRIPT_DIR" "root@${ip}:/tmp/orainstall" 2>/dev/null || \
            sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no -r \
            "$SCRIPT_DIR" "root@${host}:/tmp/orainstall" 2>/dev/null || \
            die "Cannot copy scripts to node $host"

        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" \
            "cd /tmp/orainstall && ./install_oracle.sh --node-env-only -c config/oracle.conf" 2>&1 || \
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
            "cd /tmp/orainstall && ./install_oracle.sh --node-env-only -c config/oracle.conf" 2>&1 | tee -a "$LOG_FILE"
    done
}
