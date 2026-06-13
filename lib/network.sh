#!/bin/bash
# Network and /etc/hosts configuration

configure_network() {
    log_info "Configuring network and hosts..."

    configure_lo_mtu

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
    local entry hostname pub_ip vip priv_ips priv local_hn
    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname pub_ip vip priv_ips <<< "$entry"
        [[ -z "$hostname" ]] && die "RAC ora_net entry missing hostname"

        pub_ip=$(resolve_host_ip "$hostname" "${pub_ip:-}")
        [[ -n "$pub_ip" ]] || die "Cannot resolve public IP for node $hostname"

        if is_local_ipv4_address "$pub_ip"; then
            local_hn=$(get_local_hostname)
            if [[ "$hostname" != "$local_hn" ]]; then
                log_info "Public IP $pub_ip is on local node; setting hostname to $hostname (was $local_hn)"
                set_system_hostname "$hostname"
            fi
            # set_hosts_entry "$pub_ip" "$(hostname -f 2>/dev/null || echo "$hostname")"
        fi

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

    configure_rac_scan_hosts
}

configure_rac_scan_hosts() {
    local ip

    [[ -n "${scan_name:-}" ]] || return 0
    [[ ${#SCAN_IPS[@]} -gt 0 ]] || return 0

    for ip in "${SCAN_IPS[@]}"; do
        set_hosts_entry "$ip" "$scan_name"
    done

    log_info "SCAN hosts: $scan_name -> ${SCAN_IPS[*]}"
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

build_rac_gi_cluster_nodes() {
    local entry hostname vip
    local nodes=()

    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname _ vip _ <<< "$entry"
        [[ -n "$hostname" ]] || continue
        if [[ -n "${vip:-}" ]]; then
            nodes+=("${hostname}:${hostname}-vip")
        else
            nodes+=("${hostname}:AUTO")
        fi
    done

    [[ ${#nodes[@]} -gt 0 ]] || die "Cannot build GI clusterNodes from ora_net (RAC)"
    local IFS=','
    echo "${nodes[*]}"
}

get_local_rac_net_entry() {
    local entry hostname

    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r hostname _ <<< "$entry"
        if is_local_hostname "$hostname"; then
            echo "$entry"
            return 0
        fi
    done

    for entry in "${ORA_NET_NODES[@]}"; do
        [[ -n "$entry" ]] && { echo "$entry"; return 0; }
    done

    return 1
}

ipv4_network_address() {
    local ip="$1"
    local prefix="$2"
    local o1 o2 o3 o4 ip_num mask_num net_num

    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    ip_num=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    mask_num=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    net_num=$(( ip_num & mask_num ))
    printf "%d.%d.%d.%d\n" \
        $(( (net_num >> 24) & 255 )) \
        $(( (net_num >> 16) & 255 )) \
        $(( (net_num >> 8) & 255 )) \
        $(( net_num & 255 ))
}

find_iface_subnet_for_ip() {
    local target_ip="$1"
    local ifname ip_cidr ip prefix network

    while read -r ifname ip_cidr; do
        [[ -n "$ifname" && -n "$ip_cidr" ]] || continue
        ip="${ip_cidr%%/*}"
        prefix="${ip_cidr##*/}"
        [[ "$ip" == "$target_ip" ]] || continue
        [[ "$prefix" =~ ^[0-9]+$ ]] || prefix=24
        network=$(ipv4_network_address "$ip" "$prefix")
        echo "${ifname}:${network}"
        return 0
    done < <(ip -o -4 addr show 2>/dev/null | awk '{print $2, $4}')

    return 1
}

is_local_ipv4_address() {
    local target_ip="$1"
    [[ -n "$target_ip" ]] || return 1
    find_iface_subnet_for_ip "$target_ip" &>/dev/null
}

build_rac_network_interface_list() {
    local entry hostname pub_ip priv_ips priv_ip ifspec ifname subnet
    local -a iflist=()

    entry=$(get_local_rac_net_entry) || die "Cannot find local RAC node in ora_net"

    IFS=':' read -r hostname pub_ip _ priv_ips <<< "$entry"
    pub_ip=$(resolve_host_ip "$hostname" "${pub_ip:-}")
    [[ -n "$pub_ip" ]] || die "Cannot resolve public IP for RAC node $hostname"

    ifspec=$(find_iface_subnet_for_ip "$pub_ip") || \
        die "Cannot find public network interface for IP $pub_ip (node $hostname)"
    IFS=':' read -r ifname subnet <<< "$ifspec"
    iflist+=("${ifname}:${subnet}:1")

    if [[ -n "${priv_ips:-}" ]]; then
        priv_ip="${priv_ips%%+*}"
        priv_ip="${priv_ip// /}"
        [[ -n "$priv_ip" ]] || die "Invalid private IP in ora_net for node $hostname"
        ifspec=$(find_iface_subnet_for_ip "$priv_ip") || \
            die "Cannot find private network interface for IP $priv_ip (node $hostname)"
        IFS=':' read -r ifname subnet <<< "$ifspec"
        iflist+=("${ifname}:${subnet}:2")
    fi

    local IFS=','
    echo "${iflist[*]}"
}

need_lo_mtu_16436() {
    case "${OS_ID,,}" in
        rhel|centos)
            [[ "$OS_MAJOR" -ge 7 ]]
            ;;
        openeuler|openeuler|kylin)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

configure_lo_mtu() {
    need_lo_mtu_16436 || return 0

    log_info "Setting loopback (lo) MTU to 16436 (OS: ${OS_NAME})"

    if ip link set dev lo mtu 16436 2>/dev/null; then
        log_info "Applied lo MTU 16436 (runtime)"
    else
        log_warn "Failed to set lo MTU 16436 at runtime"
    fi

    persist_lo_mtu_16436
}

persist_lo_mtu_16436() {
    local ifcfg="/etc/sysconfig/network-scripts/ifcfg-lo"

    if [[ -d /etc/sysconfig/network-scripts ]]; then
        if [[ -f "$ifcfg" ]]; then
            backup_file "$ifcfg"
            if grep -q '^MTU=' "$ifcfg" 2>/dev/null; then
                sed -i 's/^MTU=.*/MTU=16436/' "$ifcfg"
            else
                echo "MTU=16436" >> "$ifcfg"
            fi
        else
            cat > "$ifcfg" <<'EOF'
DEVICE=lo
IPADDR=127.0.0.1
NETMASK=255.0.0.0
NETWORK=127.0.0.0
ONBOOT=yes
MTU=16436
EOF
        fi
        log_info "Persisted lo MTU in $ifcfg"
        ifup lo 2>/dev/null || true
        return 0
    fi

    if is_systemd; then
        local unit="/etc/systemd/system/oracle-lo-mtu.service"
        cat > "$unit" <<'EOF'
[Unit]
Description=Set loopback MTU for Oracle
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev lo mtu 16436
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable oracle-lo-mtu.service 2>/dev/null || true
        log_info "Persisted lo MTU via systemd unit: $unit"
    fi
}
