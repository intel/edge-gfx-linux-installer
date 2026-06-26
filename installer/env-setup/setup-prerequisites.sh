#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Setup Prerequisites Script
#
# This script:
# - Checks Ubuntu version compatibility (tested on 24.04.4)
# - Installs Intel Edge kernel packages
# - Setup GRUB to boot into Intel Edge kernel by default
# - Installs required system packages for graphics, virtualization, build, and tools
# - Optimizes boot performance (server images only)
# - Setup PPA sources for Intel Edge kernel (public)
#
# Standalone examples:
# - sudo ./setup-prerequisites.sh
# - sudo ./setup-prerequisites.sh edge --proxy http://proxy.example.com:911 --config sriov_xe
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBAL CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Supported Ubuntu version
SUPPORTED_UBUNTU_VERSION="24.04.4"

# User-provided proxy (optional, passed via --proxy flag)
PROXY_URL=""
PACKAGE_SOURCE="edge"
USER_CONFIG=""
SKIP_KERNEL_INSTALL=false

# Package list file (format: one package per line; comments allowed)
PACKAGES_LIST_FILE="$SCRIPT_DIR/env-setup/packages.list"

# GRUB configuration
GRUB_CONFIG="/etc/default/grub"
INTEL_XE_PARAMS="xe.max_vfs=7 xe.force_probe=* modprobe.blacklist=i915 udmabuf.list_limit=8192"
INTEL_I915_PARAMS="i915.enable_guc=3 i915.max_vfs=7 i915.force_probe=* udmabuf.list_limit=8192"
CONSOLE_PARAMS="console=tty0 console=ttyS0,115200n8"
# GPU platform resolved once from --config or auto-detection
GPU_PLATFORM="xe"
# Intel kernel version need to matches edge-kernel.sh package configuration
DEFAULT_KERNEL_VERSION="linux-intel-6.18"
GRUB_TIMEOUT="10"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "\e[34m[INFO]\e[0m $*"
}

log_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $*"
}

log_warning() {
    echo -e "\e[33m[WARNING]\e[0m $*" >&2
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $*" >&2
}

log_section() {
    echo
    echo "=============================================="
    echo "  $*"
    echo "=============================================="
}

run_script() {
    local script_path="$1"
    shift  # Remove first argument, remaining args will be passed to the script
    local script_name
    script_name="$(basename "$script_path")"

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_info "Making $script_name executable..."
        chmod +x "$script_path"
    fi

    log_section "Running $script_name..."
    if "$script_path" "$@"; then
        log_success "$script_name completed successfully"
        return 0
    else
        log_error "$script_name failed with exit code $?"
        return 1
    fi
}

# =============================================================================
# SYSTEM COMPATIBILITY CHECKS
# =============================================================================

check_ubuntu_version() {
    log_info "Checking Ubuntu version compatibility..."

    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS information"
        exit 1
    fi

    local version_id
    version_id=$(grep "VERSION_ID" /etc/os-release | cut -d'"' -f2) || {
        log_error "Failed to extract Ubuntu version"
        exit 1
    }

    log_info "Detected Ubuntu version: $version_id"

    if [[ "$version_id" != "$SUPPORTED_UBUNTU_VERSION" ]]; then
        log_warning "This script is tested on Ubuntu $SUPPORTED_UBUNTU_VERSION"
        log_warning "You are running Ubuntu $version_id"
        echo

        # Countdown timer for user response
        local countdown=10
        local user_choice=""

        echo -n "Are you sure you want to continue? [Y/n] (auto-continue in ${countdown}s): "

        while [[ $countdown -gt 0 ]]; do
            if read -r -t 1 -n 1 user_choice 2>/dev/null; then
                # User provided input
                echo  # New line after user input
                if [[ "$user_choice" =~ ^[Nn]$ ]]; then
                    log_info "Aborted by user"
                    exit 0
                else
                    break
                fi
            fi
            countdown=$((countdown - 1))
            if [[ $countdown -gt 0 ]]; then
                # Update countdown display
                echo -ne "\rAre you sure you want to continue? [Y/n] (auto-continue in ${countdown}s): "
            fi
        done

        if [[ $countdown -eq 0 ]]; then
            echo  # New line after countdown
            log_info "Timeout reached, continuing anyway..."
        fi

        log_info "Continuing with Ubuntu $version_id..."
    else
        log_success "✓ Running on supported Ubuntu version"
    fi
}

detect_ubuntu_flavor() {
    log_info "Detecting Ubuntu flavor..."

    local is_server=false

    # Check if it's Ubuntu Server
    if grep -q "ubuntu-server" /etc/os-release 2>/dev/null || \
       [[ ! -d /usr/share/xsessions ]] || \
       ! systemctl is-active --quiet graphical.target 2>/dev/null; then
        is_server=true
        log_info "Detected: Ubuntu Server image" >&2
    else
        log_info "Detected: Ubuntu Desktop image" >&2
    fi

    printf '%s\n' "$is_server"
}

check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root"
        return 0
    elif sudo -n true 2>/dev/null; then
        log_info "Running with sudo privileges"
        return 0
    else
        log_error "This script requires root or sudo privileges"
        log_info "Please run: sudo $0"
        exit 1
    fi
}

# =============================================================================
# FAST BOOT OPTIMIZATION (SERVER ONLY)
# =============================================================================

# Service management function with enhanced error handling
manage_services() {
    local action="$1"
    shift
    local services=("$@")

    # Validate action parameter
    case "$action" in
        "disable --now"|"mask"|"enable"|"unmask")
            ;; # Valid actions
        *)
            log_error "Invalid action: $action"
            return 1
            ;;
    esac

    local failed_services=()

    for service in "${services[@]}"; do
        # Skip empty service names
        [[ -n "$service" ]] || continue

        # Check if service exists before operating on it
        if systemctl list-unit-files "$service" >/dev/null 2>&1; then
            # Note: action contains flags like "disable --now", so we need word splitting
            # shellcheck disable=SC2086
            if sudo systemctl $action "$service" 2>/dev/null; then
                log_info "Successfully processed: $service ($action)"
            else
                failed_services+=("$service")
                log_warning "Failed to process: $service ($action)"
            fi
        else
            log_info "Service not found (skipping): $service"
        fi
    done

    # Report any failures
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_warning "Some services failed to process: ${failed_services[*]}"
    fi
}

optimize_boot_performance() {
    log_section "BOOT OPTIMIZATION (SERVER ONLY)"

    local is_server
    is_server=$(detect_ubuntu_flavor)

    if [[ "$is_server" != "true" ]]; then
        log_info "Skipping boot optimization - Not a server image"
        log_info "Boot optimization is only applied to Ubuntu Server images"
        return 0
    fi

    log_info "Applying boot optimization for Ubuntu Server..."

    # Network wait services to disable
    local network_services=(
        "systemd-networkd-wait-online.service"
        "NetworkManager-wait-online.service"
    )

    # Boot services to disable
    local boot_services=(
        "pollinate.service"
        "cloud-init.service"
        "cloud-config.service"
        "apt-daily.service"
        "apt-daily-upgrade.service"
        "motd-news.service"
        "fwupd-refresh.service"
        "whoopsie.service"
    )

    # Services to mask (prevent from starting)
    local mask_services=(
        "systemd-networkd-wait-online.service"
        "NetworkManager-wait-online.service"
        "pollinate.service"
        "cloud-init.service"
    )

    log_info "[1/3] Disabling and masking network wait services..."
    manage_services "disable --now" "${network_services[@]}"
    manage_services "mask" "${network_services[@]}"

    log_info "[2/3] Disabling unneeded boot services..."
    manage_services "disable --now" "${boot_services[@]}"

    log_info "[3/3] Masking critical services..."
    manage_services "mask" "${mask_services[@]}"

    log_success "✓ Boot optimization complete!"
    log_info "Changes will take effect after the next reboot."
}

install_system_packages() {
    log_section "SYSTEM PACKAGE INSTALLATION"

    if [[ ! -f "$PACKAGES_LIST_FILE" ]]; then
        log_error "Package list file not found: $PACKAGES_LIST_FILE"
        exit 1
    fi

    # Load package list and deduplicate for apt command usage.
    local raw_packages
    raw_packages=$(awk '
        $0 ~ /^[[:space:]]*#/ { next }
        NF >= 1 { print $1 }
    ' "$PACKAGES_LIST_FILE") || {
        log_error "Failed to assemble package groups"
        exit 1
    }

    local clean_packages
    clean_packages=$(echo "$raw_packages" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//') || {
        log_error "Failed to process system package list"
        exit 1
    }

    if [[ -z "$clean_packages" ]]; then
        log_warning "No system packages defined. Skipping installation."
        return 0
    fi

    local proxy_env=()
    if [[ -n "${PROXY_URL}" ]]; then
        proxy_env=("http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}")
    fi

    log_info "Updating package list..."
    if [[ $EUID -eq 0 ]]; then
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            env "${proxy_env[@]}" apt-get update -qq || {
                log_error "Failed to update package list"
                exit 1
            }
        else
            apt-get update -qq || {
                log_error "Failed to update package list"
                exit 1
            }
        fi
    else
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            sudo env "${proxy_env[@]}" apt-get update -qq || {
                log_error "Failed to update package list"
                exit 1
            }
        else
            sudo apt-get update -qq || {
                log_error "Failed to update package list"
                exit 1
            }
        fi
    fi

    log_info "Installing system packages..."
    # Note: clean_packages needs word splitting for apt arguments.
    # shellcheck disable=SC2086
    if [[ $EUID -eq 0 ]]; then
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            env "${proxy_env[@]}" apt-get install -y $clean_packages || {
                log_error "System package installation failed"
                exit 1
            }
        else
            apt-get install -y $clean_packages || {
                log_error "System package installation failed"
                exit 1
            }
        fi
    else
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            sudo env "${proxy_env[@]}" apt-get install -y $clean_packages || {
                log_error "System package installation failed"
                exit 1
            }
        else
            sudo apt-get install -y $clean_packages || {
                log_error "System package installation failed"
                exit 1
            }
        fi
    fi

    log_success "✓ System packages installation completed"
}


# =============================================================================
# EDGE KERNEL CONFIGURATION
# =============================================================================

detect_baremetal_gpu_platform() {
    if lsmod | grep -q "^i915\s"; then
        printf '%s\n' "i915"
        return 0
    fi

    if lsmod | grep -q "^xe\s"; then
        printf '%s\n' "xe"
        return 0
    fi

    # Driver might not be loaded yet (common early in provisioning).
    # Infer from which kernel module is listed as available for Intel GPU.
    local gpu_info
    gpu_info=$(lspci -nn | grep -i "VGA\|3D\|Display" | grep "8086:" | head -1)

    if [[ -z "$gpu_info" ]]; then
        gpu_info=$(lspci -nn | grep -i "VGA\|3D\|Display" | head -1)
    fi

    if [[ -n "$gpu_info" ]] && echo "$gpu_info" | grep -q "8086:"; then
        local gpu_pci_addr
        gpu_pci_addr=$(echo "$gpu_info" | awk '{print $1}')
        local candidate_module
        candidate_module=$(lspci -k -s "$gpu_pci_addr" 2>/dev/null \
            | grep "Kernel modules:" \
            | tr ',' '\n' \
            | grep -Eoiw "xe|i915" \
            | head -1 || true)

        if [[ "${candidate_module,,}" == "xe" ]]; then
            printf '%s\n' "xe"
            return 0
        elif [[ "${candidate_module,,}" == "i915" ]]; then
            printf '%s\n' "i915"
            return 0
        fi
    fi

    printf '%s\n' ""
    return 1
}

resolve_kernel_platform() {
    if [[ -z "${USER_CONFIG:-}" ]]; then
        local auto_platform=""
        if auto_platform="$(detect_baremetal_gpu_platform)" && [[ -n "$auto_platform" ]]; then
            GPU_PLATFORM="$auto_platform"
            log_info "No --config provided"
            log_info "Auto-detected loaded GPU module based on current kernel '$GPU_PLATFORM'"
        else
            GPU_PLATFORM="xe"
            log_warning "No --config provided and no 'xe'/'i915' module loaded; defaulting to 'xe'"
        fi
        return 0
    fi

    case "$USER_CONFIG" in
        sriov_xe)
            GPU_PLATFORM="xe"
            log_info "Using kernel parameter platform 'xe' from config: $USER_CONFIG"
            ;;
        sriov_i915)
            GPU_PLATFORM="i915"
            log_info "Using kernel parameter platform 'i915' from config: ${USER_CONFIG}"
            ;;
        baremetal)
            local detected_platform=""
            if detected_platform="$(detect_baremetal_gpu_platform)" && [[ -n "$detected_platform" ]]; then
                GPU_PLATFORM="$detected_platform"
                log_info "Detected baremetal kernel module '$GPU_PLATFORM'; using corresponding kernel parameters"
            else
                GPU_PLATFORM="xe"
                log_warning "Config 'baremetal': neither 'xe' nor 'i915' kernel module is loaded; defaulting to 'xe'"
            fi
            ;;
        *)
            log_error "Unknown config override: $USER_CONFIG"
            exit 1
            ;;
    esac
}

install_edge_kernel() {
    local package_source="${1:-edge}"

    # Run Intel kernel setup
    log_section "INTEL KERNEL INSTALLATION"
    run_script "$SCRIPT_DIR/components/edge-kernel.sh" "$package_source" || {
        log_error "Intel kernel setup failed"
        return 1
    }
}

# =============================================================================
# GRUB CONFIGURATION
# =============================================================================

backup_grub_config() {
    if [[ -f "$GRUB_CONFIG" ]]; then
        local backup_file
        backup_file="${GRUB_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)" || {
            log_error "Failed to generate backup filename"
            exit 1
        }
        cp "$GRUB_CONFIG" "$backup_file"
        log_info "Backed up existing GRUB config to: $backup_file"
    else
        log_error "GRUB config file not found: $GRUB_CONFIG"
        exit 1
    fi
}

configure_grub_kernel_default() {
    log_info "Verifying target Intel kernel version..."

    # Validate kernel version is configured
    if [[ -z "$DEFAULT_KERNEL_VERSION" ]]; then
        log_error "No target Intel kernel configured"
        exit 1
    fi

    local configured_kernel="$DEFAULT_KERNEL_VERSION"

    if [[ ! -d "/boot" ]]; then
        log_warning "/boot directory not found. Keeping configured target: $configured_kernel"
        log_warning "⚠ DEFAULT_KERNEL_VERSION install status: unknown (boot directory unavailable)"
    else
        # 1) Exact filename check (already an exact kernel string).
        if [[ -f "/boot/vmlinuz-$configured_kernel" ]]; then
            log_success "✓ Intel kernel is available in /boot: $configured_kernel"
            log_success "✓ DEFAULT_KERNEL_VERSION is installed: $configured_kernel"
        else
            # 2) Train/package style check (example: linux-intel-6.18 -> 6.18).
            local configured_train="${configured_kernel#linux-intel-}"
            local matched_installed_kernel=""
            matched_installed_kernel=$(find /boot -maxdepth 1 -type f -name "vmlinuz-*${configured_train}*intel*" 2>/dev/null | \
                sed 's|.*/vmlinuz-||' | sort -V | tail -1) || matched_installed_kernel=""

            if [[ -z "$matched_installed_kernel" ]]; then
                log_warning "No matching Intel kernel found in /boot for target: $configured_kernel"
                log_warning "Intel kernel may not be installed yet"
                log_warning "⚠ DEFAULT_KERNEL_VERSION is not installed: $configured_kernel"
            else
                DEFAULT_KERNEL_VERSION="$matched_installed_kernel"
                log_success "✓ Intel kernel is available in /boot: $DEFAULT_KERNEL_VERSION"
                log_success "✓ DEFAULT_KERNEL_VERSION is installed (resolved): $DEFAULT_KERNEL_VERSION"
            fi
        fi
    fi

    # Configure GRUB default using verified kernel
    log_info "Configuring default kernel selection..."
    local target_kernel="Advanced options for Ubuntu>Ubuntu, with Linux $DEFAULT_KERNEL_VERSION"

    # Update or add GRUB_DEFAULT
    if grep -q "^GRUB_DEFAULT=" "$GRUB_CONFIG"; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$target_kernel\"|" "$GRUB_CONFIG"
        log_info "Updated GRUB_DEFAULT to Intel kernel"
    else
        echo "GRUB_DEFAULT=\"$target_kernel\"" >> "$GRUB_CONFIG"
        log_info "Added GRUB_DEFAULT for Intel kernel"
    fi
}


configure_grub_timeout() {
    log_info "Configuring GRUB timeout..."

    # Enable GRUB menu by commenting out hidden timeout
    if grep -q "^GRUB_TIMEOUT_STYLE=hidden" "$GRUB_CONFIG"; then
        sed -i "s|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|" "$GRUB_CONFIG"
        log_info "Disabled hidden GRUB menu"
    fi

    # Set timeout
    if grep -q "^GRUB_TIMEOUT=" "$GRUB_CONFIG"; then
        sed -i "s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=$GRUB_TIMEOUT|" "$GRUB_CONFIG"
    else
        echo "GRUB_TIMEOUT=$GRUB_TIMEOUT" >> "$GRUB_CONFIG"
    fi
    log_info "Set GRUB timeout to $GRUB_TIMEOUT seconds"
}

configure_grub_parameters() {
    local effective_platform
    local platform_params

    effective_platform="${GPU_PLATFORM:-xe}"

    case "$effective_platform" in
        xe)
            platform_params="$INTEL_XE_PARAMS"
            log_info "Configuring kernel parameters for Intel Xe SR-IOV..."
            ;;
        i915)
            platform_params="$INTEL_I915_PARAMS"
            log_info "Configuring kernel parameters for Intel i915..."
            ;;
        *)
            log_error "Unknown GPU platform: $effective_platform (expected: xe or i915)"
            exit 1
            ;;
    esac

    local all_params="$platform_params $CONSOLE_PARAMS"

    # Update or add kernel command line parameters
    if grep -q "^GRUB_CMDLINE_LINUX=" "$GRUB_CONFIG"; then
        # Replace existing parameters completely
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$all_params\"|" "$GRUB_CONFIG"
        log_info "Updated kernel command line parameters"
    else
        echo "GRUB_CMDLINE_LINUX=\"$all_params\"" >> "$GRUB_CONFIG"
        log_info "Added kernel command line parameters"
    fi

    log_info "Kernel parameters configured:"
    log_info "  - Platform ($effective_platform): $platform_params"
    log_info "  - Console: $CONSOLE_PARAMS"
}

update_grub() {
    log_info "Updating GRUB configuration..."

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
        log_success "GRUB configuration updated successfully"
    else
        log_error "update-grub command not found"
        exit 1
    fi
}

configure_grub() {
    log_section "GRUB CONFIGURATION"

    # Show current configuration
    log_info "Current kernel: $(uname -r)"

    # Backup existing configuration
    backup_grub_config

    # Verify kernel version and configure GRUB default
    configure_grub_kernel_default

    # Configure additional GRUB settings
    configure_grub_timeout
    configure_grub_parameters

    # Apply changes
    update_grub

    log_success "✓ GRUB configuration completed!"
}

# =============================================================================
# PPA CONFIGURATION
# =============================================================================

setup_ppa_source() {
    local package_source="${1:-edge}"

    log_section "PPA CONFIGURATION"

    # Source common-helper.sh to leverage its PPA management functions
    local common_helper_script="$SCRIPT_DIR/components/common-helper.sh"
    if [[ ! -f "$common_helper_script" ]]; then
        log_error "common-helper.sh not found: $common_helper_script"
        return 1
    fi

    # Export PPA_SELECTOR based on package_source for common-helper.sh
    case "$package_source" in
        edge)
            export PPA_SELECTOR="edge"
            log_info "Setting up Intel Edge Graphics PPA"
            ;;
        *)
            log_warning "Unknown package source: $package_source, defaulting to edge"
            export PPA_SELECTOR="edge"
            ;;
    esac

    # Source and execute PPA configuration from common-helper.sh
    # shellcheck disable=SC1090
    source "$common_helper_script"

    # Use common-helper's PPA setup functionality
    if ! setup_selected_ppa "$common_helper_script" "$PPA_SELECTOR" "Intel Graphics PPA ($PPA_SELECTOR)"; then
        log_error "Failed to setup PPA"
        return 1
    fi

    log_success "✓ PPA configuration completed"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

show_final_summary() {
    log_section "SETUP COMPLETE"

    echo "Summary of changes:"
    echo "✓ System compatibility verified"

    local is_server
    is_server=$(detect_ubuntu_flavor)
    if [[ "$is_server" == "true" ]]; then
        echo "✓ Boot optimization applied (server image)"
    else
        echo "• Boot optimization skipped (desktop image)"
    fi

    if [[ ! -d "/boot" ]]; then
        echo "⚠ DEFAULT_KERNEL_VERSION install status: unknown (boot directory unavailable)"
    elif [[ -f "/boot/vmlinuz-$DEFAULT_KERNEL_VERSION" ]]; then
        echo "✓ DEFAULT_KERNEL_VERSION installed: $DEFAULT_KERNEL_VERSION"
    else
        echo "⚠ DEFAULT_KERNEL_VERSION not found in /boot: $DEFAULT_KERNEL_VERSION"
    fi

    echo "✓ GRUB configured for Intel ${GPU_PLATFORM^^} SR-IOV"
    echo ""
    echo "Next steps:"
    echo "1. Install Edge Overlay Components"
    echo "2. Reboot the system"
    echo "3. Verify Intel ${GPU_PLATFORM^^} driver loads: lsmod | grep ${GPU_PLATFORM}"
    echo ""
    log_warning "IMPORTANT: Reboot required for all changes to take effect"
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --proxy)
                if [[ -n "$2" && "$2" != --* ]]; then
                    PROXY_URL="$2"
                    log_info "Using proxy: $PROXY_URL"
                    shift 2
                else
                    log_error "--proxy requires a URL argument"
                    log_info "Usage: sudo $0 [edge] [--proxy URL] [--config CONFIG] [--skip-kernel]"
                    exit 1
                fi
                ;;
            --config)
                if [[ -n "$2" && "$2" =~ ^(sriov_i915|sriov_xe|baremetal)$ ]]; then
                    USER_CONFIG="$2"
                    log_info "Using configuration override: $USER_CONFIG"
                    shift 2
                else
                    log_error "--config requires one of: sriov_i915, sriov_xe, baremetal"
                    exit 1
                fi
                ;;
            --skip-kernel)
                SKIP_KERNEL_INSTALL=true
                log_info "Skipping kernel installation inside setup-prerequisites"
                shift
                ;;
            --help|-h)
                echo "Usage: sudo $0 [edge] [--proxy URL] [--config CONFIG] [--skip-kernel]"
                echo ""
                echo "Options:"
                echo "  edge              Use Intel Edge package source (default)"
                echo "  --proxy URL       Optional proxy server URL (e.g., http://proxy.example.com:911)"
                echo "  --config CONFIG   Use SR-IOV config override (sriov_i915|sriov_xe|baremetal)"
                echo "  --skip-kernel     Skip edge-kernel.sh invocation (used by install-host orchestrator)"
                echo "  --help, -h        Show this help message"
                exit 0
                ;;
            edge)
                PACKAGE_SOURCE="$1"
                log_info "Using package source: $PACKAGE_SOURCE"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                log_info "Usage: sudo $0 [edge] [--proxy URL] [--config CONFIG] [--skip-kernel]"
                exit 1
                ;;
        esac
    done

    if [[ "$PACKAGE_SOURCE" == "edge" ]]; then
        log_info "No package source provided; defaulting to edge"
    fi

    # Resolve GPU platform once from --config or runtime module detection.
    resolve_kernel_platform

    log_section "SETUP PREREQUISITES FOR INTEL ENVIRONMENT"

    # System checks
    check_ubuntu_version
    check_privileges

    setup_ppa_source "$PACKAGE_SOURCE"

    # Execute setup steps
    if [[ "$SKIP_KERNEL_INSTALL" == "true" ]]; then
        log_info "Skipping edge-kernel.sh in setup-prerequisites (already handled by caller)"
    else
        install_edge_kernel "$PACKAGE_SOURCE"
    fi
    install_system_packages
    # Boot optimization is only applied to server images,
    # it will detect and skip if running on desktop
    optimize_boot_performance
    configure_grub
    # Final summary
    show_final_summary

    log_success "All prerequisites setup completed successfully!"
}

# Run main function
main "$@"
