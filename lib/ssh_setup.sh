#!/bin/bash
# RAC node SSH trust setup

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

get_rac_ssh_targets() {
    local entry hostname pub_ip vip priv_ips priv
    local -a targets=()

    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname pub_ip vip priv_ips <<< "$entry"
        [[ -n "$hostname" ]] && targets+=("$hostname")
        pub_ip=$(resolve_host_ip "$hostname" "${pub_ip:-}")
        [[ -n "$pub_ip" ]] && targets+=("$pub_ip")
        [[ -n "${vip:-}" ]] && targets+=("${hostname}-vip" "$vip")
        if [[ -n "${priv_ips:-}" ]]; then
            local IFS='+'
            read -ra priv_arr <<< "$priv_ips"
            local idx=1
            for priv in "${priv_arr[@]}"; do
                priv="${priv// /}"
                [[ -n "$priv" ]] && targets+=("${hostname}priv${idx}" "$priv")
                idx=$(( idx + 1 ))
            done
        fi
    done

    [[ -n "${scan_name:-}" ]] && targets+=("$scan_name")
    if [[ ${#SCAN_IPS[@]} -gt 0 ]]; then
        local scan_ip
        for scan_ip in "${SCAN_IPS[@]}"; do
            targets+=("$scan_ip")
        done
    fi

    printf '%s\n' "${targets[@]}" | awk 'NF && !seen[$0]++'
}

build_rac_known_hosts_blob() {
    local target

    while read -r target; do
        [[ -n "$target" ]] || continue
        ssh-keyscan -H "$target" 2>/dev/null || true
    done < <(get_rac_ssh_targets)
}

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

write_user_ssh_rac_config() {
    local user="$1"
    local home="$2"
    local ssh_dir="$3"
    local config_file="${4:-${ssh_dir}/config}"
    local targets host_line tmp

    targets=$(get_rac_ssh_targets | tr '\n' ' ')
    [[ -n "${targets// /}" ]] || return 0

    host_line="${targets//  / }"
    config_file="${config_file:-${ssh_dir}/config}"
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
        echo "    StrictHostKeyChecking no"
        echo "    BatchMode yes"
        echo "# <<< orainstall rac ssh <<<"
    } >> "$config_file"

    chmod 600 "$config_file"
    chown_user_path "$user" "$config_file"
}

populate_user_known_hosts() {
    local user="$1"
    local home="$2"
    local ssh_dir="$3"
    local known_hosts="${4:-${ssh_dir}/known_hosts}"
    local kh_blob="${LOG_DIR}/rac_known_hosts.blob"

    build_rac_known_hosts_blob > "$kh_blob"
    [[ -s "$kh_blob" ]] || log_warn "No RAC host keys collected for ${user}; check network/DNS"

    known_hosts="${known_hosts:-${ssh_dir}/known_hosts}"
    merge_known_hosts_file "$known_hosts" "$kh_blob"
    chmod 644 "$known_hosts"
    chown_user_path "$user" "$known_hosts"
}

apply_rac_ssh_client_config_local() {
    local user="$1"
    local home ssh_dir

    home=$(get_user_home_dir "$user")
    [[ -n "$home" ]] || return 0
    ssh_dir="${home}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown_user_path "$user" "$ssh_dir"

    populate_user_known_hosts "$user" "$home" "$ssh_dir"
    write_user_ssh_rac_config "$user" "$home" "$ssh_dir"
    log_info "RAC SSH client config applied locally for: $user"
}

apply_rac_ssh_client_config_remote() {
    local user="$1"
    local remote_ip="$2"
    local kh_blob="${LOG_DIR}/rac_known_hosts.blob"
    local targets host_line

    [[ -n "$remote_ip" ]] || return 0
    targets=$(get_rac_ssh_targets | tr '\n' ' ')
    host_line="${targets//  / }"
    [[ -s "$kh_blob" ]] || build_rac_known_hosts_blob > "$kh_blob"

    sshpass -p "$root_pwd" scp -o StrictHostKeyChecking=no \
        "$kh_blob" "root@${remote_ip}:/tmp/orainstall_known_hosts" 2>/dev/null || \
        log_warn "Failed to copy known_hosts blob to ${remote_ip}"

    sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${remote_ip}" \
        "USER=${user} OINSTALL_GROUP=${oinstall_group} HOSTS='${host_line}' bash -s" <<'REMOTE_EOF' \
        || log_warn "Failed to apply RAC SSH client config on ${remote_ip} for user ${user}"
set -eu

if [[ "$USER" == root ]]; then
    home="/root"
    owner_group="${USER}:${USER}"
else
    home=$(getent passwd "$USER" 2>/dev/null | cut -d: -f6 || true)
    owner_group="${USER}:${OINSTALL_GROUP}"
fi

[[ -n "$home" ]] || exit 0
ssh_dir="${home}/.ssh"
config_file="${ssh_dir}/config"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

if [[ -f /tmp/orainstall_known_hosts ]]; then
    touch "${ssh_dir}/known_hosts"
    cat /tmp/orainstall_known_hosts >> "${ssh_dir}/known_hosts"
    awk 'NF && !seen[$0]++' "${ssh_dir}/known_hosts" > "${ssh_dir}/known_hosts.tmp"
    mv "${ssh_dir}/known_hosts.tmp" "${ssh_dir}/known_hosts"
    chmod 644 "${ssh_dir}/known_hosts"
    rm -f /tmp/orainstall_known_hosts
fi

if grep -q '# >>> orainstall rac ssh >>>' "$config_file" 2>/dev/null; then
    awk '
        $0 == "# >>> orainstall rac ssh >>>" { skip=1; next }
        $0 == "# <<< orainstall rac ssh <<<" { skip=0; next }
        !skip { print }
    ' "$config_file" > "${config_file}.tmp"
    mv "${config_file}.tmp" "$config_file"
fi

{
    echo ""
    echo "# >>> orainstall rac ssh >>>"
    echo "Host ${HOSTS}"
    echo "    StrictHostKeyChecking no"
    echo "    BatchMode yes"
    echo "# <<< orainstall rac ssh <<<"
} >> "$config_file"

chmod 600 "$config_file"
chown -R "$owner_group" "$ssh_dir"
REMOTE_EOF
}

setup_user_ssh_trust() {
    local user="$1"
    local home ssh_dir
    local host ip local_hn

    home=$(get_user_home_dir "$user")
    [[ -n "$home" ]] || die "Home directory not found for user: $user"

    ssh_dir="${home}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown_user_path "$user" "$ssh_dir"

    if [[ ! -f "${ssh_dir}/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -N "" -f "${ssh_dir}/id_rsa" -q
    fi
    chmod 600 "${ssh_dir}/id_rsa"
    chown_user_path "$user" "${ssh_dir}/id_rsa"

    local_hn=$(get_local_hostname)
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        for target in "$host" "$ip"; do
            [[ -z "$target" ]] && continue
            if [[ "$user" == "root" ]]; then
                sshpass -p "$root_pwd" ssh-copy-id -o StrictHostKeyChecking=no \
                    -i "${ssh_dir}/id_rsa.pub" "root@${target}" 2>/dev/null || true
            else
                sshpass -p "$root_pwd" ssh -o StrictHostKeyChecking=no "root@${target}" \
                    "mkdir -p ${ssh_dir} && chown ${user}:${user} ${ssh_dir} && chmod 700 ${ssh_dir}" 2>/dev/null || true
                sshpass -p "$root_pwd" ssh-copy-id -o StrictHostKeyChecking=no \
                    -i "${ssh_dir}/id_rsa.pub" "${user}@${target}" 2>/dev/null || true
            fi
        done
    done

    cat "${ssh_dir}/id_rsa.pub" >> "${ssh_dir}/authorized_keys"
    sort -u "${ssh_dir}/authorized_keys" -o "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown_user_path "$user" "${ssh_dir}/authorized_keys"

    apply_rac_ssh_client_config_local "$user"

    for i in "${!RAC_NODE_HOSTS[@]}"; do
        host="${RAC_NODE_HOSTS[$i]}"
        ip="${RAC_PUBLIC_IPS[$i]}"
        [[ "$host" == "$local_hn" ]] && continue
        apply_rac_ssh_client_config_remote "$user" "$ip"
    done

    log_info "SSH trust configured for: $user"
}

verify_rac_passwordless_ssh() {
    local user local_hn host
    local users=("$db_user")
    local failed=0

    need_gi && users+=("$gi_user")
    local_hn=$(get_local_hostname)

    for user in "${users[@]}"; do
        for host in "${RAC_NODE_HOSTS[@]}"; do
            [[ "$host" == "$local_hn" ]] && continue
            if su - "$user" -c "ssh -o BatchMode=yes -o ConnectTimeout=10 '${host}' hostname" >/dev/null 2>&1; then
                log_info "Passwordless SSH OK: ${user}@${host}"
            else
                die "Passwordless SSH check failed: ${user}@${host} (GI install may fail)"
                failed=1
            fi
        done
    done

    [[ $failed -eq 0 ]] || log_warn "Fix RAC SSH trust before GI installation (known_hosts / keys)"
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
