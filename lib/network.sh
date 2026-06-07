#!/bin/bash
# Network and /etc/hosts configuration

configure_network() {
    log_info "Configuring network and hosts..."

    case "$ora_type" in
        oracle|asm)
            configure_standalone_hosts
            ;;
        rac)
            configure_rac_hosts
            ;;
    esac
}

configure_standalone_hosts() {
    local entry hostname ip local_hn
    local_hn=$(get_local_hostname)

    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname ip _ <<< "$entry"
        [[ -z "$hostname" ]] && continue
        ip=$(resolve_host_ip "$hostname" "${ip:-}")
        [[ -n "$ip" ]] || die "Cannot resolve IP for host $hostname (check ora_net or network configuration)"
        set_hosts_entry "$ip" "$hostname"

        # Sync system hostname when configured hostname differs (required for Oracle install)
        if [[ "$hostname" != "$local_hn" ]]; then
            log_info "System hostname $local_hn differs from config $hostname; setting to $hostname"
            set_system_hostname "$hostname"
            set_hosts_entry "$ip" "$(hostname -f 2>/dev/null || echo "$hostname")"
        fi

        log_info "hosts: $hostname -> $ip"
    done

    # Use local host when ora_net is not configured
    if [[ ${#ORA_NET_NODES[@]} -eq 0 ]]; then
        local hn ip
        hn=$(get_local_hostname)
        ip=$(detect_local_ip)
        [[ -n "$ip" ]] || die "Cannot auto-detect local IP"
        set_hosts_entry "$ip" "$hn"
        set_hosts_entry "$ip" "$(hostname -f 2>/dev/null || echo "$hn")"
    fi
}

set_system_hostname() {
    local name="$1"
    if command -v hostnamectl &>/dev/null; then
        hostnamectl set-hostname "$name"
    else
        hostname "$name"
        if [[ -f /etc/sysconfig/network ]]; then
            sed -i "s/^HOSTNAME=.*/HOSTNAME=$name/" /etc/sysconfig/network
        fi
    fi
}

configure_rac_hosts() {
    local entry hostname pub_ip vip priv_ips priv
    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname pub_ip vip priv_ips <<< "$entry"
        [[ -z "$hostname" ]] && die "RAC ora_net entry missing hostname"

        pub_ip=$(resolve_host_ip "$hostname" "${pub_ip:-}")
        [[ -n "$pub_ip" ]] || die "Cannot resolve public IP for node $hostname"

        set_hosts_entry "$pub_ip" "$hostname"
        [[ -n "$vip" ]] && set_hosts_entry "$vip" "${hostname}-vip"

        if [[ -n "${priv_ips:-}" ]]; then
            local IFS='+'
            read -ra priv_arr <<< "$priv_ips"
            local idx=1
            for priv in "${priv_arr[@]}"; do
                set_hosts_entry "$priv" "${hostname}priv${idx}"
                idx=$(( idx + 1 ))
            done
        fi

        log_info "RAC node: $hostname pub=$pub_ip vip=${vip:-N/A} priv=${priv_ips:-N/A}"
    done
}

set_hosts_entry() {
    local ip="$1"
    local name="$2"
    if [[ -z "$ip" || -z "$name" ]]; then
        return 0
    fi

    backup_file /etc/hosts
    if grep -qE "[[:space:]]${name}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
        sed -i "/[[:space:]]${name}\([[:space:]]\|\$\)/d" /etc/hosts
    fi
    echo "$ip   $name" >> /etc/hosts
}

get_rac_node_hostnames() {
    local entry hostname
    RAC_NODE_HOSTS=()
    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname _ <<< "$entry"
        RAC_NODE_HOSTS+=("$hostname")
    done
}

get_rac_public_ips() {
    local entry hostname pub_ip
    RAC_PUBLIC_IPS=()
    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname pub_ip _ <<< "$entry"
        pub_ip=$(resolve_host_ip "$hostname" "${pub_ip:-}")
        RAC_PUBLIC_IPS+=("$pub_ip")
    done
}

get_local_node_index() {
    local hn i
    hn=$(get_local_hostname)
    get_rac_node_hostnames
    for i in "${!RAC_NODE_HOSTS[@]}"; do
        [[ "${RAC_NODE_HOSTS[$i]}" == "$hn" ]] && { echo "$i"; return 0; }
    done
    echo "0"
}

build_rac_nodelist() {
    get_rac_node_hostnames
    local IFS=','
    echo "${RAC_NODE_HOSTS[*]}"
}
