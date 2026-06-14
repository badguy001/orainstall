#!/bin/bash
# Oracle automated installation main entry
#
# Supports: Oracle standalone / ASM standalone / RAC
# Supported OS: RHEL 6-9, CentOS, Rocky, Oracle Linux, openEuler, Kylin V10, openSUSE
# Supported versions: 11gR1/R2, 12cR1/R2, 18c, 19c
#
# Usage:
#   cp config/oracle.conf.example config/oracle.conf
#   vi config/oracle.conf
#   ./install_oracle.sh

set -euo pipefail
set +H  # Disable history expansion to avoid issues with ! in passwords
set -x    # Debug: print executed commands

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/os_detect.sh
source "$SCRIPT_DIR/lib/os_detect.sh"
# shellcheck source=lib/prereqs.sh
source "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/sysconfig.sh
source "$SCRIPT_DIR/lib/sysconfig.sh"
# shellcheck source=lib/users.sh
source "$SCRIPT_DIR/lib/users.sh"
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"
# shellcheck source=lib/udev.sh
source "$SCRIPT_DIR/lib/udev.sh"
# shellcheck source=lib/ntp.sh
source "$SCRIPT_DIR/lib/ntp.sh"
# shellcheck source=lib/yum_iso.sh
source "$SCRIPT_DIR/lib/yum_iso.sh"
# shellcheck source=lib/ssh_setup.sh
source "$SCRIPT_DIR/lib/ssh_setup.sh"
# shellcheck source=lib/rsp.sh
source "$SCRIPT_DIR/lib/rsp.sh"
# shellcheck source=lib/emagent_fix.sh
source "$SCRIPT_DIR/lib/emagent_fix.sh"
# shellcheck source=lib/db_sysliblist_fix.sh
source "$SCRIPT_DIR/lib/db_sysliblist_fix.sh"
# shellcheck source=lib/gi_ohasd_fix.sh
source "$SCRIPT_DIR/lib/gi_ohasd_fix.sh"
# shellcheck source=lib/gi_install.sh
source "$SCRIPT_DIR/lib/gi_install.sh"
# shellcheck source=lib/db_install.sh
source "$SCRIPT_DIR/lib/db_install.sh"
# shellcheck source=lib/patch.sh
source "$SCRIPT_DIR/lib/patch.sh"

NODE_ENV_ONLY=0
SKIP_PREREQS=0
SKIP_SYSCONFIG=0

usage() {
    cat <<EOF
Oracle automated installation script (standalone / ASM standalone / RAC)

Usage: $0 [options] [config file]

Options:
  -h, --help            Show help
  -c, --config FILE     Specify config file (default: config/oracle.conf)
  --node-env-only       Configure environment on this node only (for RAC remote nodes)
  --skip-prereqs        Skip prerequisite package installation
  --skip-sysconfig      Skip system parameter configuration
  --verify-only         Verify installation only

Run modes (config file run_mode):
  env       Configure environment only
  software  Install software only (GI + DB)
  full      Install software and create database

See config/oracle.conf.example for configuration details

EOF
}

configure_environment() {
    if [[ $SKIP_PREREQS -eq 0 ]]; then
        setup_yum_from_iso
        install_prerequisites
        create_oracle_users
    else
        log_info "Skipping prerequisite package installation"
    fi

    if [[ $SKIP_SYSCONFIG -eq 0 ]]; then
        configure_ntp
        configure_network
        configure_system
        if need_asm_storage; then
            configure_asm_udev
        fi
    else
        log_info "Skipping system parameter configuration"
    fi
}

install_software_stack() {
    archive_oracle_cvu_tmp_dirs
    if need_gi; then
        install_gi_software
    fi
    install_db_software
    upgrade_opatch
    apply_patches
}

create_database_stack() {
    create_database
    # configure_listener
    # setup_autostart
}

main() {
    local config_file="$SCRIPT_DIR/config/oracle.conf"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            --node-env-only)
                NODE_ENV_ONLY=1
                shift
                ;;
            --skip-prereqs)
                SKIP_PREREQS=1
                shift
                ;;
            --skip-sysconfig)
                SKIP_SYSCONFIG=1
                shift
                ;;
            --verify-only)
                require_root
                load_and_validate_config "$config_file"
                detect_os
                verify_installation
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                config_file="$1"
                shift
                ;;
        esac
    done

    require_root
    load_and_validate_config "$config_file"

    log_info "========== Oracle automated installation started =========="
    log_info "ora_type=$ora_type run_mode=$run_mode db_version=$db_version"

    detect_os
    check_oracle_version_compat


    configure_environment

    if is_rac && [[ $NODE_ENV_ONLY -eq 0 ]]; then
        setup_ssh_trust
    fi
    
    if [[ $NODE_ENV_ONLY -eq 1 ]]; then
        log_info "Node environment configuration complete (node-env-only)"
        exit 0
    fi

    if is_rac; then
        dispatch_env_to_rac_nodes
    fi

    if [[ "$run_mode" == "$RUN_MODE_ENV" ]]; then
        log_info "run_mode=env; environment configuration complete"
        print_summary
        exit 0
    fi

    export SKIP_SOFTWARE_INSTALL=0
    install_software_stack

    if [[ "$run_mode" == "$RUN_MODE_FULL" ]]; then
        create_database_stack
    fi

    configure_oracle_env_after_install

    if [[ "$run_mode" == "$RUN_MODE_SOFTWARE" ]]; then
        log_info "run_mode=software; software installation complete"
        print_summary
        exit 0
    fi

    verify_installation
    print_summary

    log_info "========== Installation process finished =========="
}

main "$@"
