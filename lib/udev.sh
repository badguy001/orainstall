#!/bin/bash
# ASM disk udev rules

configure_asm_udev() {
    if ! need_asm_storage; then
        return 0
    fi
    if [[ -z "${asm_ocr_dg:-}" && -z "${asm_dat_dg:-}" ]]; then
        return 0
    fi

    log_info "Configuring ASM udev rules..."

    local all_dgs=()
    [[ -v ASM_OCR_DGS && ${#ASM_OCR_DGS[@]} -gt 0 ]] && all_dgs+=("${ASM_OCR_DGS[@]}")
    [[ -v ASM_DAT_DGS && ${#ASM_DAT_DGS[@]} -gt 0 ]] && all_dgs+=("${ASM_DAT_DGS[@]}")

    local udev_file="/etc/udev/rules.d/99-oracle-asm.rules"
    backup_file "$udev_file"
    : > "$udev_file"

    local dg_spec dg_name disk_spec disk_entry
    local disk_name wwid asm_disk_name real_disk scsi_id_path

    for dg_spec in "${all_dgs[@]}"; do
        [[ -z "$dg_spec" ]] && continue
        IFS=':' read -r dg_name disk_specs <<< "$dg_spec"
        [[ -z "$disk_specs" ]] && continue

        local IFS='+'
        read -ra disk_entries <<< "$disk_specs"
        for disk_entry in "${disk_entries[@]}"; do
            [[ -z "$disk_entry" ]] && continue
            IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
            asm_disk_name="${asm_disk_name:-$disk_name}"

            if [[ -z "$disk_name" && -z "$wwid" ]]; then
                die "Disk configuration error: at least one of disk_name or WWID is required"
            fi

            real_disk=$(find_disk_by_name_or_wwid "$disk_name" "$wwid") || \
                die "Disk not found: name=$disk_name wwid=$wwid"

            if [[ -z "$wwid" ]]; then
                wwid=$(get_disk_wwid "$real_disk")
            fi
            [[ -n "$wwid" ]] || die "Cannot get disk WWID: $real_disk"

            if [[ "$use_multipathd" == "1" ]]; then
                echo "KERNEL==\"${real_disk}\", SUBSYSTEM==\"block\", PROGRAM==\"/usr/bin/scsi_id --whitelisted --replace-letters --device=/dev/\$name\", RESULT==\"${wwid}\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"${oinstall_group}\", MODE=\"0660\"" >> "$udev_file"
            else
                echo "KERNEL==\"${real_disk}\", SUBSYSTEM==\"block\", PROGRAM==\"/usr/bin/scsi_id --whitelisted --replace-letters --device=/dev/\$name\", RESULT==\"${wwid}\", SYMLINK+=\"${asm_disk_name}\", OWNER=\"${gi_user}\", GROUP=\"${oinstall_group}\", MODE=\"0660\"" >> "$udev_file"
            fi

            log_info "udev: ${asm_disk_name} -> /dev/${real_disk} (WWID=$wwid)"
        done
    done

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true
    sleep 2
}

prepare_asm_disks_for_installer() {
    if ! need_asm_storage; then
        return 0
    fi

    ASM_DISKS_FOR_OCR=()
    ASM_DISKS_FOR_DATA=()

    if [[ -v ASM_OCR_DGS && ${#ASM_OCR_DGS[@]} -gt 0 ]]; then
        collect_dg_disks ASM_OCR_DGS ASM_DISKS_FOR_OCR
    fi
    if [[ -v ASM_DAT_DGS && ${#ASM_DAT_DGS[@]} -gt 0 ]]; then
        collect_dg_disks ASM_DAT_DGS ASM_DISKS_FOR_DATA
    fi
}

collect_dg_disks() {
    local -n dg_arr=$1
    local -n out_arr=$2
    local dg_spec dg_name disk_specs disk_entry disk_name wwid asm_disk_name

    for dg_spec in "${dg_arr[@]}"; do
        [[ -z "$dg_spec" ]] && continue
        IFS=':' read -r dg_name disk_specs <<< "$dg_spec"
        local IFS='+'
        read -ra disk_entries <<< "$disk_specs"
        for disk_entry in "${disk_entries[@]}"; do
            IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
            asm_disk_name="${asm_disk_name:-$disk_name}"
            out_arr+=("/dev/${asm_disk_name}")
        done
    done
}

parse_diskgroup_for_asmca() {
    local dg_spec="$1"
    local dg_name disk_specs
    IFS=':' read -r dg_name disk_specs <<< "$dg_spec"
    echo "$dg_name"
}

get_diskgroup_disks() {
    local dg_spec="$1"
    local dg_name disk_specs disk_entry disk_name wwid asm_disk_name disks=()
    IFS=':' read -r dg_name disk_specs <<< "$dg_spec"
    local IFS='+'
    read -ra disk_entries <<< "$disk_specs"
    for disk_entry in "${disk_entries[@]}"; do
        IFS=',' read -r disk_name wwid asm_disk_name <<< "$disk_entry"
        asm_disk_name="${asm_disk_name:-$disk_name}"
        disks+=("/dev/${asm_disk_name}")
    done
    echo "${disks[*]}"
}
