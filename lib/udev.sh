#!/bin/bash
# ASM disk udev rules

append_asm_udev_rule() {
    local real_disk="$1"
    local wwid="$2"
    local asm_disk_name="$3"
    local disk_name="$4"
    local udev_file="$5"
    local scsi_id_cmd=$(get_scsi_id_cmd)

    if [[ -n "$wwid" ]]; then
        if [[ "$use_multipathd" == "1" ]]; then
            echo "SUBSYSTEM==\"block\", ENV{DM_NAME}==\"${disk_name}\", PROGRAM==\"${scsi_id_cmd} --whitelisted --device=/dev/\$name\", RESULT==\"${wwid}\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"asmadmin\", MODE=\"0660\"" >> "$udev_file"
        else
            echo "KERNEL==\"${real_disk}\", SUBSYSTEM==\"block\", PROGRAM==\"${scsi_id_cmd} --whitelisted --device=/dev/\$name\", RESULT==\"${wwid}\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"asmadmin\", MODE=\"0660\"" >> "$udev_file"
        fi
        log_info "udev: ${asm_disk_name} -> /dev/${real_disk} (WWID=$wwid)"
    else
        local kernel_name="${disk_name:-$real_disk}"
        if [[ "$use_multipathd" == "1" ]]; then
            echo "SUBSYSTEM==\"block\", ENV{DM_NAME}==\"${disk_name}\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"asmadmin\", MODE=\"0660\"" >> "$udev_file"
        else
            echo "KERNEL==\"${kernel_name}\", SUBSYSTEM==\"block\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"asmadmin\", MODE=\"0660\"" >> "$udev_file"
        fi
        log_warn "udev: WWID unavailable, using disk name rule: ${kernel_name} -> ${asm_disk_name}"
    fi
}

configure_asm_udev() {
    if ! need_asm_storage; then
        return 0
    fi
    if [[ -z "${disks_use_by_asm:-}" ]]; then
        return 0
    fi

    log_info "Configuring ASM udev rules..."

    local udev_file="/etc/udev/rules.d/99-oracle-asm.rules"
    backup_file "$udev_file"
    : > "$udev_file"

    local disk_entry disk_name wwid asm_disk_name real_disk

    for disk_entry in "${ASM_DISK_ENTRIES[@]}"; do
        [[ -z "$disk_entry" ]] && continue
        IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
        asm_disk_name="${asm_disk_name:-$disk_name}"

        if [[ -z "$disk_name" && -z "$wwid" ]]; then
            die "Disk configuration error: at least one of disk_name or WWID is required"
        fi

        #real_disk=$(find_disk_by_name_or_wwid "$disk_name" "$wwid") || \
        #    die "Disk not found: name=$disk_name wwid=$wwid"
        real_disk="$disk_name"

        if [[ -z "$wwid" ]]; then
            wwid=$(get_disk_wwid "$real_disk")
        fi
        if [[ -z "$wwid" ]]; then
            if [[ "$ignore_disk_wwid" == "1" ]]; then
                append_asm_udev_rule "$real_disk" "" "$asm_disk_name" "$disk_name" "$udev_file"
                continue
            fi
            die "Cannot get disk WWID: $real_disk (set ignore_disk_wwid=1 to use disk_name rule)"
        fi

        append_asm_udev_rule "$real_disk" "$wwid" "$asm_disk_name" "$disk_name" "$udev_file"
    done

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true
    sleep 2

    verify_asm_udev_disks
}

verify_asm_disk_dev() {
    local asm_disk_name="$1"
    local dev_path expected_user expected_group
    local owner group mode dev_type link_target
    local retry max_retry=5

    dev_path=$(normalize_asm_disk_dev_path "$asm_disk_name") || \
        die "Invalid asm_disk_name: $asm_disk_name"

    expected_user="${gi_user}"
    expected_group="asmadmin"

    for (( retry=1; retry <= max_retry; retry++ )); do
        [[ -e "$dev_path" ]] && break
        [[ $retry -lt $max_retry ]] && sleep 1
    done
    [[ -e "$dev_path" ]] || die "ASM disk device not found: $dev_path (asm_disk_name=$asm_disk_name)"

    if [[ -L "$dev_path" ]]; then
        link_target=$(readlink -f "$dev_path" 2>/dev/null || readlink "$dev_path" 2>/dev/null || true)
        log_info "ASM disk $dev_path is a symlink -> ${link_target:-unknown}"
    fi

    dev_type=$(stat -L -c '%F' "$dev_path" 2>/dev/null) || \
        die "Cannot stat ASM disk: $dev_path"
    [[ "$dev_type" == "block special file" ]] || \
        die "ASM disk path is not a block device: $dev_path (type=$dev_type)"

    owner=$(stat -L -c '%U' "$dev_path" 2>/dev/null) || \
        die "Cannot read owner for ASM disk: $dev_path"
    group=$(stat -L -c '%G' "$dev_path" 2>/dev/null) || \
        die "Cannot read group for ASM disk: $dev_path"
    mode=$(stat -L -c '%a' "$dev_path" 2>/dev/null) || \
        die "Cannot read mode for ASM disk: $dev_path"

    [[ "$owner" == "$expected_user" ]] || \
        die "ASM disk $dev_path owner is $owner, expected $expected_user"
    [[ "$group" == "$expected_group" ]] || \
        die "ASM disk $dev_path group is $group, expected $expected_group"
    [[ "$mode" == "660" ]] || \
        die "ASM disk $dev_path mode is $mode, expected 660"

    log_info "ASM disk verified: $dev_path ($owner:$group mode=$mode)"
}

verify_asm_udev_disks() {
    local disk_entry disk_name wwid asm_disk_name dev_path

    log_info "Verifying ASM udev disk paths (owner=${gi_user}:asmadmin mode=660)..."

    for disk_entry in "${ASM_DISK_ENTRIES[@]}"; do
        [[ -z "$disk_entry" ]] && continue
        IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
        asm_disk_name="${asm_disk_name:-$disk_name}"

        dev_path=$(normalize_asm_disk_dev_path "$asm_disk_name") || \
            die "Invalid asm_disk_name in config: $asm_disk_name"

        verify_asm_disk_dev "$asm_disk_name"
    done
}

prepare_asm_disks_for_installer() {
    # ASM_DISKGROUP_DISK_LIST is populated by parse_asm_config in config.sh
    :
}
