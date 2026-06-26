#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Host Setup Script
#
# This script provides two installation modes:
# - Standard: Baseline graphics/media/compute/tools setup
# - Virtualization: Standard + Graphics SR-IOV virtualization setup
# =============================================================================

set -euo pipefail

# Script directory for relative path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Proxy URL for network operations (optional)
PROXY_URL=""

# Optional SR-IOV configuration override for virtualization mode.
# When empty, setup-SRIOV-advance.sh auto-detects the environment.
SRIOV_CONFIG=""
AUTOMATED_MODE=false
PACKAGE_SOURCE="edge"
PACKAGE_SOURCE_EXPLICIT=false
SKIP_DKMS_HOOKS=false
DKMS_HOOK_BACKUPS=()

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"

    case "$level" in
        "INFO")  echo -e "${BLUE}[INFO ]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN ]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "STEP")  echo -e "${BOLD}[STEP ]${NC} $message" ;;
    esac
}

show_usage() {
    echo "Usage: $0 {standard|standard-dkms|virtualization|virtualization-dkms} [--proxy URL] [--config CONFIG] [--automated] [--skip-dkms-hooks]"
    echo ""
    echo "Installation Modes:"
    echo "  standard              - Install baseline Intel Graphics, Media, Compute and Display  packages"
    echo "  standard-dkms         - Install baseline packages with DKMS-based kernel module support"
    echo "  virtualization        - Install baseline packages plus Graphics SR-IOV virtualization components (QEMU, SPICE, Mutter)"
    echo "  virtualization-dkms   - Install baseline packages plus Graphics SR-IOV virtualization components (QEMU, SPICE, Mutter) with DKMS-based kernel module support"
    echo ""
    echo "Options:"
    echo "  --proxy URL    - Optional proxy server URL (e.g., http://proxy-example:xxx)"
    echo "  --config TYPE  - Optional SR-IOV config override for virtualization mode"
    echo "                    Valid: sriov_i915 | sriov_xe | baremetal"
    echo "  --automated    - Run non-interactively and skip reboot prompt handling"
    echo "  --skip-dkms-hooks - Temporarily disable kernel DKMS hooks during kernel install (rerun helper for non-DKMS modes)"
    echo "  --edge         - Use Intel Edge package sources from external (default for any user)"
    echo ""
    echo "Examples:"
    echo "  $0 standard                                           # Baseline installation"
    echo "  $0 standard-dkms                                      # Baseline installation with DKMS support"
    echo "  $0 virtualization                                     # Virtualization packages + auto-detect SR-IOV config"
    echo "  $0 virtualization-dkms                                # Virtualization packages with DKMS support + auto-detect SR-IOV config"
    echo "  $0 standard --proxy http://proxy.example.com          # With proxy server"
    echo "  $0 standard-dkms --proxy http://proxy.example.com     # With proxy server and DKMS support"
    echo "  $0 virtualization --config baremetal                  # Force baremetal config"
    echo "  $0 virtualization --config sriov_xe                   # Force guest SR-IOV Xe config"
    echo "  $0 virtualization --automated                         # Non-interactive guest provisioning"
    echo "  $0 virtualization --edge --skip-dkms-hooks            # Rerun without DKMS auto-hook during kernel install"
    echo "  $0 virtualization-dkms --config baremetal             # Virtualization packages with DKMS support and forced baremetal config"
    echo "  $0 virtualization-dkms --config sriov_xe              # Virtualization packages with DKMS support and forced SR-IOV Xe config"
    echo "  $0 virtualization-dkms --automated                    # Virtualization packages with DKMS support and non-interactive guest provisioning"
}

run_script() {
    local script_path="$1"
    shift  # Remove first argument, remaining args will be passed to the script
    local script_name
    script_name="$(basename "$script_path")"

    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "Script not found: $script_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log "INFO" "Making $script_name executable..."
        chmod +x "$script_path"
    fi

    log "STEP" "Running $script_name..."
    if "$script_path" "$@"; then
        log "SUCCESS" "$script_name completed successfully"
        return 0
    else
        log "ERROR" "$script_name failed with exit code $?"
        return 1
    fi
}

disable_dkms_kernel_hooks() {
    local hook
    local backup

    for hook in /etc/kernel/postinst.d/dkms /etc/kernel/header_postinst.d/dkms; do
        if [[ -f "$hook" ]]; then
            backup="${hook}.install-host-disabled.$$"
            mv "$hook" "$backup" || {
                log "ERROR" "Failed to disable DKMS hook: $hook"
                return 1
            }
            DKMS_HOOK_BACKUPS+=("${hook}::${backup}")
            log "INFO" "Temporarily disabled DKMS hook: $hook"
        fi
    done

    return 0
}

restore_dkms_kernel_hooks() {
    local entry
    local original
    local backup

    for entry in "${DKMS_HOOK_BACKUPS[@]:-}"; do
        original="${entry%%::*}"
        backup="${entry##*::}"
        if [[ -f "$backup" ]]; then
            mv "$backup" "$original" || {
                log "WARN" "Failed to restore DKMS hook: $original (backup: $backup)"
                continue
            }
            log "INFO" "Restored DKMS hook: $original"
        fi
    done

    DKMS_HOOK_BACKUPS=()
    return 0
}

install_OCL_packages() {
    log "OPENCL COMPONENTS INSTALLATION"

    local tmp_dir
    tmp_dir=$(mktemp -d) || {
        log "ERROR" "Failed to create temporary directory"
        return 1
    }
    log "INFO" "Downloading OpenCL packages to: $tmp_dir"

    local urls=(
        "https://github.com/intel/intel-graphics-compiler/releases/download/v2.32.7/intel-igc-core-2_2.32.7+21184_amd64.deb"
        "https://github.com/intel/intel-graphics-compiler/releases/download/v2.32.7/intel-igc-opencl-2_2.32.7+21184_amd64.deb"
        "https://github.com/intel/compute-runtime/releases/download/26.14.37833.4/intel-ocloc_26.14.37833.4-0_amd64.deb"
        "https://github.com/intel/compute-runtime/releases/download/26.14.37833.4/intel-opencl-icd_26.14.37833.4-0_amd64.deb"
        "https://github.com/intel/compute-runtime/releases/download/26.14.37833.4/libze-intel-gpu1_26.14.37833.4-0_amd64.deb"
    )

    for url in "${urls[@]}"; do
        if ! wget -q --show-progress -P "$tmp_dir" "$url"; then
            log "ERROR" "Failed to download: $url"
            rm -rf "$tmp_dir"
            return 1
        fi
    done

    log "INFO" "Installing OpenCL packages..."
    if ! dpkg -i "$tmp_dir"/*.deb; then
        log "ERROR" "Failed to install OpenCL packages"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
    log "SUCCESS" "OpenCL packages installed and temporary files removed"
}

run_baseline_setup() {
    local package_source="$1"
    local source_arg="--edge"

    # Run baremetal setup
    run_script "$SCRIPT_DIR/components/setup-baremetal.sh" "$source_arg" --skip-PPA || {
        log "ERROR" "Baseline graphics/media/compute/tools setup failed"
        return 1
    }

    # Install Compute Runtime and related components
    install_OCL_packages || {
        log "ERROR" "OpenCL components installation failed"
        return 1
    }
}

run_standard_setup() {
    local package_source="${1:-edge}"

    log "STEP" "Starting Standard Installation Mode"
    echo ""

    run_baseline_setup "$package_source" || return 1

    echo ""
    log "SUCCESS" "Standard installation completed successfully (baseline graphics/media/compute/tools)!"
}

run_standard_dkms_setup() {
    local package_source="${1:-edge}"

    log "STEP" "Starting Standard DKMS Installation Mode"
    echo ""

    run_baseline_setup "$package_source" || return 1

    run_script "$SCRIPT_DIR/components/setup-dkms.sh" || {
        log "ERROR" "DKMS setup failed"
        return 1
    }

    echo ""
    log "SUCCESS" "Standard DKMS installation completed successfully (baseline + DKMS build)!"
}

run_virtualization_setup() {
    local package_source="${1:-edge}"

    log "STEP" "Starting Virtualization Installation Mode"
    echo ""

    run_baseline_setup "$package_source" || return 1

    echo ""

    # Run SRIOV setup with optional configuration override
    local sriov_script="$SCRIPT_DIR/components/setup-SRIOV-advance.sh"
    local sriov_args=()

    if [[ ! -f "$sriov_script" ]]; then
        log "ERROR" "SRIOV script not found: $sriov_script"
        return 1
    fi

    if [[ ! -x "$sriov_script" ]]; then
        log "INFO" "Making setup-SRIOV-advance.sh executable..."
        chmod +x "$sriov_script"
    fi

    if [[ -n "$SRIOV_CONFIG" ]]; then
        sriov_args=("--config" "$SRIOV_CONFIG")
        log "STEP" "Running SRIOV setup with config override: $SRIOV_CONFIG"
    else
        log "STEP" "Running SRIOV setup with auto-detected configuration"
    fi

    if [[ "$AUTOMATED_MODE" == true ]]; then
        sriov_args+=("--automated")
    fi

	if [[ "$package_source" == "edge" ]]; then
		sriov_args+=("--edge")
	fi

    if [[ -n "$PROXY_URL" ]]; then
        sriov_args+=("--proxy" "$PROXY_URL")
    fi

    if "$sriov_script" "${sriov_args[@]}"; then
        log "SUCCESS" "SRIOV setup completed successfully"
    else
        log "ERROR" "SRIOV setup failed"
        return 1
    fi

    echo ""
    log "SUCCESS" "Virtualization installation completed successfully!"
}

run_virtualization_dkms_setup() {
    local package_source="${1:-edge}"

    log "STEP" "Starting Virtualization DKMS Installation Mode"
    echo ""

    run_baseline_setup "$package_source" || return 1

    run_script "$SCRIPT_DIR/components/setup-dkms.sh" || {
        log "ERROR" "DKMS setup failed"
        return 1
    }

    echo ""

    # Run SRIOV setup with optional configuration override
    local sriov_script="$SCRIPT_DIR/components/setup-SRIOV-advance.sh"
    local sriov_args=()

    if [[ ! -f "$sriov_script" ]]; then
        log "ERROR" "SRIOV script not found: $sriov_script"
        return 1
    fi

    if [[ ! -x "$sriov_script" ]]; then
        log "INFO" "Making setup-SRIOV-advance.sh executable..."
        chmod +x "$sriov_script"
    fi

    if [[ -n "$SRIOV_CONFIG" ]]; then
        sriov_args=("--config" "$SRIOV_CONFIG")
        log "STEP" "Running SRIOV setup with config override: $SRIOV_CONFIG"
    else
        log "STEP" "Running SRIOV setup with auto-detected configuration"
    fi

    if [[ "$AUTOMATED_MODE" == true ]]; then
        sriov_args+=("--automated")
    fi

    if [[ "$package_source" == "edge" ]]; then
        sriov_args+=("--edge")
    fi

    if [[ -n "$PROXY_URL" ]]; then
        sriov_args+=("--proxy" "$PROXY_URL")
    fi

    if "$sriov_script" "${sriov_args[@]}"; then
        log "SUCCESS" "SRIOV setup completed successfully"
    else
        log "ERROR" "SRIOV setup failed"
        return 1
    fi

    echo ""
    log "SUCCESS" "Virtualization DKMS installation completed successfully!"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    # Check if running as root (with sudo)
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run with root privileges"
        log "INFO" "Please run with sudo: sudo $0 $*"
        exit 1
    fi

    # Check command line arguments
    if [[ $# -lt 1 ]]; then
        log "ERROR" "Invalid number of arguments"
        show_usage
        exit 1
    fi

    # Parse mode and optional flags
    local mode="$1"

    # Validate that mode is one of the valid modes
    case "$mode" in
        "standard"|"standard-dkms"|"virtualization"|"virtualization-dkms"|"help"|"-h"|"--help")
            # Valid mode, continue processing
            ;;
        *)
            log "ERROR" "Invalid or missing installation mode: $mode"
            show_usage
            exit 1
            ;;
    esac

    shift

    # Parse optional arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proxy)
                if [[ -n "$2" && "$2" != --* ]]; then
                    PROXY_URL="$2"
                    log "INFO" "Using proxy: $PROXY_URL"
                    shift 2
                else
                    log "ERROR" "--proxy requires a URL argument"
                    show_usage
                    exit 1
                fi
                ;;
            --config)
                if [[ -n "$2" && "$2" =~ ^(sriov_i915|sriov_xe|baremetal)$ ]]; then
                    SRIOV_CONFIG="$2"
                    log "INFO" "Using SRIOV config override: $SRIOV_CONFIG"
                    shift 2
                else
                    log "ERROR" "--config requires one of: sriov_i915, sriov_xe, baremetal"
                    show_usage
                    exit 1
                fi
                ;;
            --automated)
                AUTOMATED_MODE=true
                log "INFO" "Running in automated mode"
                shift
                ;;
            --skip-dkms-hooks)
                SKIP_DKMS_HOOKS=true
                log "INFO" "DKMS kernel hooks will be temporarily disabled during kernel install"
                shift
                ;;
            --edge)
                PACKAGE_SOURCE="edge"
                PACKAGE_SOURCE_EXPLICIT=true
                log "INFO" "Using Intel Edge package sources"
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ "$PACKAGE_SOURCE" == "edge" && "$PACKAGE_SOURCE_EXPLICIT" == false ]]; then
        log "INFO" "No source flag specified; defaulting to Intel Edge package sources"
    fi

    if [[ "$SKIP_DKMS_HOOKS" == true && ( "$mode" == "standard-dkms" || "$mode" == "virtualization-dkms" ) ]]; then
        log "WARN" "--skip-dkms-hooks is ignored for DKMS modes"
        SKIP_DKMS_HOOKS=false
    fi

    local -a proxy_args=()
    local -a config_args=()

    if [[ -n "$PROXY_URL" ]]; then
        proxy_args=("--proxy" "$PROXY_URL")
    fi

    if [[ -n "$SRIOV_CONFIG" ]]; then
        config_args=("--config" "$SRIOV_CONFIG")
    fi

    if [[ "$mode" == "standard" || "$mode" == "virtualization" ]]; then
        if [[ "$SKIP_DKMS_HOOKS" != true ]]; then
            SKIP_DKMS_HOOKS=true
            log "INFO" "Auto-enabling DKMS hook bypass for non-DKMS mode: $mode"
        fi
    fi

    # Configure proxy for all child processes and system-wide via /etc/environment
    # so it persists across the installation and future commands.
    if [[ -n "$PROXY_URL" ]]; then
        # Export to current process and child processes
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"
        export HTTPS_PROXY="$PROXY_URL"
        log "INFO" "Exported proxy to current session: $PROXY_URL"

        # Persist to /etc/environment for system-wide availability
        log "INFO" "Persisting proxy to /etc/environment..."
        if ! grep -q "^http_proxy=" /etc/environment; then
            echo "http_proxy=$PROXY_URL" | tee -a /etc/environment > /dev/null
        else
            sed -i "s|^http_proxy=.*|http_proxy=$PROXY_URL|" /etc/environment
        fi
        if ! grep -q "^https_proxy=" /etc/environment; then
            echo "https_proxy=$PROXY_URL" | tee -a /etc/environment > /dev/null
        else
            sed -i "s|^https_proxy=.*|https_proxy=$PROXY_URL|" /etc/environment
        fi
        log "SUCCESS" "Proxy persisted to /etc/environment for system-wide use"
    fi

   if [[ "$SKIP_DKMS_HOOKS" == true ]]; then
        disable_dkms_kernel_hooks || {
            log "ERROR" "Failed to disable DKMS kernel hooks"
            return 1
        }
    fi

    # Run prerequisites setup
    if ! run_script "$SCRIPT_DIR/env-setup/setup-prerequisites.sh" "$PACKAGE_SOURCE" "${proxy_args[@]}" "${config_args[@]}"; then
        if [[ "$SKIP_DKMS_HOOKS" == true ]]; then
            restore_dkms_kernel_hooks
        fi
        log "ERROR" "Prerequisites setup failed"
        return 1
    fi

    if [[ "$SKIP_DKMS_HOOKS" == true ]]; then
        restore_dkms_kernel_hooks
    fi

    case "$mode" in
        "standard")
            run_standard_setup "$PACKAGE_SOURCE"
            ;;
        "standard-dkms")
            run_standard_dkms_setup "$PACKAGE_SOURCE"
            ;;
        "virtualization")
            run_virtualization_setup "$PACKAGE_SOURCE"
            ;;
        "virtualization-dkms")
            run_virtualization_dkms_setup "$PACKAGE_SOURCE"
            ;;
        "help"|"-h"|"--help")
            show_usage
            exit 0
            ;;
        *)
            log "ERROR" "Invalid mode: $mode"
            show_usage
            exit 1
            ;;
    esac
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

main "$@"
