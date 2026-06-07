#!/bin/bash
# RAC node SSH trust setup

setup_ssh_trust() {
    if ! is_rac; then
        return 0
    fi

    log_info "Configuring RAC node SSH trust..."

    # Install sshpass
    get_pkg_manager
    case "$PKG_MGR" in
        dnf|yum) $PKG_MGR install -y sshpass 2>/dev/null || true ;;
        zypper)  zypper -n install sshpass 2>/dev/null || true ;;
    esac

    get_rac_node_hostnames
    get_rac_public_ips

    # Install sshpass
    case "$PKG_MGR" in
        dnf|yum) $PKG_MGR install -y sshpass 2>/dev/null || true ;;
        zypper)  zypper -n install sshpass 2>/dev/null || true ;;
    esac

    local i host ip
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        [[ "$host" == "$(get_local_hostname)" ]] && continue
        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" "hostname" 2>/dev/null || \
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" "hostname" 2>/dev/null || \
            log_warn "Cannot connect to node $host; check root_pwd and network"
    done

    local users=("$db_user")
    if need_gi; then
        users+=("$gi_user")
    fi
    users+=("root")

    for u in "${users[@]}"; do
        setup_user_ssh_trust "$u"
    done
}

setup_user_ssh_trust() {
    local user="$1"
    local home ssh_dir key_file
    local host ip

    if [[ "$user" == "root" ]]; then
        home="/root"
    else
        home=$(getent passwd "$user" | cut -d: -f6)
    fi
    ssh_dir="${home}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ ! -f "${ssh_dir}/id_rsa" ]]; then
        ssh-keygen -t rsa -N "" -f "${ssh_dir}/id_rsa" -q
    fi
    chmod 600 "${ssh_dir}/id_rsa"
    chown -R "${user}:${user}" "$ssh_dir" 2>/dev/null || true

    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        for target in "$host" "$ip"; do
            [[ -z "$target" ]] && continue
            if [[ "$user" == "root" ]]; then
                sshpass -p "$root_pwd" ssh-copy-id -o StrictHostKeyChecking=no \
                    -i "${ssh_dir}/id_rsa.pub" "root@${target}" 2>/dev/null || true
            else
                # Create user on remote and copy key first
                sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${target}" \
                    "mkdir -p ${ssh_dir} && chown ${user}:${user} ${ssh_dir}" 2>/dev/null || true
                sshpass -p "$root_pwd" ssh-copy-id -o StrictHostKeyChecking=no \
                    -i "${ssh_dir}/id_rsa.pub" "${user}@${target}" 2>/dev/null || true
            fi
        done
    done

    # Add local key to authorized_keys as well
    cat "${ssh_dir}/id_rsa.pub" >> "${ssh_dir}/authorized_keys"
    sort -u "${ssh_dir}/authorized_keys" -o "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown "${user}:${user}" "${ssh_dir}/authorized_keys" 2>/dev/null || true

    log_info "SSH trust configured for: $user"
}

dispatch_env_to_rac_nodes() {
    if ! is_rac; then
        return 0
    fi

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
        sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no -r \
            "$SCRIPT_DIR" "root@${ip}:/tmp/orainstall" 2>/dev/null || \
            sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no -r \
            "$SCRIPT_DIR" "root@${host}:/tmp/orainstall" 2>/dev/null || \
            die "Cannot copy scripts to node $host"

        sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${ip}" \
            "cd /tmp/orainstall && ./install_oracle.sh --node-env-only -c config/oracle.conf" 2>/dev/null || \
            sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${host}" \
            "cd /tmp/orainstall && ./install_oracle.sh --node-env-only -c config/oracle.conf" 2>&1 | tee -a "$LOG_FILE"
    done
}
