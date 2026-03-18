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
    echo "Usage: $0 {standard|virtualization} [--proxy URL] [--config CONFIG] [--automated]"
    echo ""
    echo "Installation Modes:"
    echo "  standard       - Install baseline Intel Graphics, Media, Compute, and Tools packages"
    echo "  virtualization - Install baseline packages plus Graphics SR-IOV virtualization components (QEMU, SPICE, Mutter)"
    echo ""
    echo "Options:"
    echo "  --proxy URL    - Optional proxy server URL (e.g., http://proxy-dmz.intel.com:911)"
    echo "  --config TYPE  - Optional SR-IOV config override for virtualization mode"
    echo "                    Valid: sriov_i915 | sriov_xe | baremetal"
    echo "  --automated    - Run non-interactively and skip reboot prompt handling"
    echo ""
    echo "Examples:"
    echo "  $0 standard                                    # Baseline installation"
    echo "  $0 virtualization                              # Virtualization packages + auto-detect SR-IOV config"
    echo "  $0 standard --proxy http://proxy.example.com   # With proxy server"
    echo "  $0 virtualization --config baremetal           # Force baremetal config"
    echo "  $0 virtualization --config sriov_xe            # Force guest SR-IOV Xe config"
    echo "  $0 virtualization --automated                  # Non-interactive guest provisioning"
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

run_standard_setup() {
    log "STEP" "Starting Standard Installation Mode"
    echo ""

    # Build proxy arguments
    local proxy_args=()
    if [[ -n "$PROXY_URL" ]]; then
        proxy_args=("--proxy" "$PROXY_URL")
    fi

    # Run prerequisites setup
    run_script "$SCRIPT_DIR/env-setup/setup-prerequisites.sh" "${proxy_args[@]}" || {
        log "ERROR" "Prerequisites setup failed"
        return 1
    }

    # Run Kobuk setup
    run_script "$SCRIPT_DIR/components/setup-kobuk.sh" "${proxy_args[@]}" || {
        log "ERROR" "Kobuk setup failed"
        return 1
    }

    echo ""
    log "SUCCESS" "Standard installation completed successfully (baseline graphics/media/compute/tools)!"
}

run_virtualization_setup() {
    log "STEP" "Starting Virtualization Installation Mode"
    echo ""

    # Build proxy arguments
    local proxy_args=()
    if [[ -n "$PROXY_URL" ]]; then
        proxy_args=("--proxy" "$PROXY_URL")
    fi

    # Run prerequisites setup
    run_script "$SCRIPT_DIR/env-setup/setup-prerequisites.sh" "${proxy_args[@]}" || {
        log "ERROR" "Prerequisites setup failed"
        return 1
    }

    echo ""

    # Run Kobuk setup
    run_script "$SCRIPT_DIR/components/setup-kobuk.sh" "${proxy_args[@]}" || {
        log "ERROR" "Kobuk setup failed"
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
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    case "$mode" in
        "standard")
            run_standard_setup
            ;;
        "virtualization")
            run_virtualization_setup
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
