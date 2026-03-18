#!/bin/bash

# =============================================================================
# Setup Prerequisites Script
# Combines fast-boot, git configuration, and GRUB setup for Intel environment
#
# This script:
# - Checks Ubuntu version compatibility (tested on 24.04.4)
# - Optimizes boot performance (server images only)
# - Configures Git (with optional proxy settings if --proxy flag provided)
# - Sets up GRUB for Intel Xe SR-IOV support
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBAL CONFIGURATION
# =============================================================================

# Supported Ubuntu version
SUPPORTED_UBUNTU_VERSION="24.04.4"

# User-provided proxy (optional, passed via --proxy flag)
PROXY_URL=""

# Git settings
DEFAULT_EDITOR="vim"
DEFAULT_BRANCH="main"
CACHE_TIMEOUT="3600"

# GRUB configuration
GRUB_CONFIG="/etc/default/grub"
INTEL_XE_PARAMS="xe.max_vfs=24 xe.force_probe=* modprobe.blacklist=i915 udmabuf.list_limit=8192"
CONSOLE_PARAMS="console=tty0 console=ttyS0,115200n8"
DEFAULT_KERNEL_VERSION="6.17.0-1007-intel"
GRUB_TIMEOUT="10"

# Global variables for user info
TARGET_USER=""
TARGET_HOME=""
USER_NAME=""
USER_EMAIL=""

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

# =============================================================================
# GIT CONFIGURATION
# =============================================================================

get_target_user_info() {
    # Determine target user and home directory
    if [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_USER="$SUDO_USER"
        local target_home
        target_home=$(getent passwd "$SUDO_USER" | cut -d: -f6) || {
            log_error "Failed to get home directory for user: $SUDO_USER"
            exit 1
        }
        TARGET_HOME="$target_home"
        log_info "Configuring for user: $TARGET_USER (home: $TARGET_HOME)"
    elif [[ $EUID -eq 0 ]]; then
        log_error "Running as root but no target user specified"
        log_info "Please run with sudo to configure for the calling user"
        exit 1
    else
        TARGET_USER="$USER"
        TARGET_HOME="$HOME"
        log_info "Configuring for current user: $TARGET_USER"
    fi

    # Verify target home directory exists and is accessible
    if [[ ! -d "$TARGET_HOME" ]]; then
        log_error "Target user home directory does not exist: $TARGET_HOME"
        exit 1
    fi

    if [[ ! -r "$TARGET_HOME" ]]; then
        log_error "Cannot access target user home directory: $TARGET_HOME"
        exit 1
    fi
}

get_user_input() {
    log_info "Git Configuration Setup"

    # Default values
    local default_name="ECG Developer"
    local default_email="ecg.sse.pid.gmdc.mys.graphics@intel.com"

    # Ask user if they want to input custom user/email with countdown timer
    local countdown=10
    local user_choice=""

    echo "=========================================="
    echo "        Git Configuration Check          "
    echo "=========================================="
    echo ""
    echo "Current system is using default Git credentials."
    echo "For proper commit attribution, it's recommended to configure"
    echo "your personal username and email address."
    echo ""
    echo -n "Would you like to configure your Git credentials now? [Y/n]"

    while [[ $countdown -gt 0 ]]; do
        if read -r -t 1 -n 1 user_choice 2>/dev/null; then
            # User provided input
            echo  # New line after user input
            break
        fi
        countdown=$((countdown - 1))
        if [[ $countdown -gt 0 ]]; then
            # Update countdown display
            echo -ne "\rDo you want to enter your own name and email? [y/N] (auto-continue in ${countdown}s): "
        fi
    done

    if [[ $countdown -eq 0 ]]; then
        echo  # New line after countdown
        log_info "Timeout reached, using default configuration"
        USER_NAME="$default_name"
        USER_EMAIL="$default_email"
    elif [[ "$user_choice" =~ ^[Yy]$ ]]; then
        echo "=========================================="
        echo "    GitHub Configuration Setup Wizard    "
        echo "=========================================="

        echo "This script will help you configure your Git username and email address."
        echo "These credentials will be used for all your Git commits."
        echo ""
        # Get name
        local current_name
        current_name=$(git config --global user.name 2>/dev/null) || current_name=""
        if [[ -n "$current_name" ]]; then
            read -r -p "Your name [$current_name]: " USER_NAME
            USER_NAME=${USER_NAME:-$current_name}
        else
            read -r -p "Your name: " USER_NAME
        fi

        # Get email
        local current_email
        current_email=$(git config --global user.email 2>/dev/null) || current_email=""
        if [[ -n "$current_email" ]]; then
            read -r -p "Your email [$current_email]: " USER_EMAIL
            USER_EMAIL=${USER_EMAIL:-$current_email}
        else
            read -r -p "Your email: " USER_EMAIL
        fi

        # Validate email format
        if [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_error "Invalid email format: $USER_EMAIL"
            exit 1
        fi
    else
        # Use defaults
        USER_NAME="$default_name"
        USER_EMAIL="$default_email"
        log_info "Using default configuration"
    fi

    log_info "Configuration - Name: $USER_NAME, Email: $USER_EMAIL"
}

install_git_prerequisites() {
    log_info "Checking and installing Git prerequisites..."

    local packages_to_install=()

    # Check if git is installed
    if ! command -v git >/dev/null 2>&1; then
        log_info "Git not found, will install"
        packages_to_install+=("git")
    else
        log_info "✓ Git is already installed"
    fi

    # Check if git-lfs is installed
    if ! command -v git-lfs >/dev/null 2>&1; then
        log_info "Git LFS not found, will install"
        packages_to_install+=("git-lfs")
    else
        log_info "✓ Git LFS is already installed"
    fi

    # Install packages if needed
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log_info "Installing packages: ${packages_to_install[*]}"

        # Set proxy environment variables if proxy is configured
        local proxy_env=()
        if [[ -n "${PROXY_URL}" ]]; then
            proxy_env=("http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}")
        fi

        # Update package list first
        log_info "Updating package list..."
        if [[ $EUID -eq 0 ]]; then
            if [[ ${#proxy_env[@]} -gt 0 ]]; then
                env "${proxy_env[@]}" apt-get update -qq
            else
                apt-get update -qq
            fi
        else
            if [[ ${#proxy_env[@]} -gt 0 ]]; then
                sudo env "${proxy_env[@]}" apt-get update -qq
            else
                sudo apt-get update -qq
            fi
        fi

        # Install packages
        if [[ $EUID -eq 0 ]]; then
            if [[ ${#proxy_env[@]} -gt 0 ]]; then
                env "${proxy_env[@]}" apt-get install -y "${packages_to_install[@]}"
            else
                apt-get install -y "${packages_to_install[@]}"
            fi
        else
            if [[ ${#proxy_env[@]} -gt 0 ]]; then
                sudo env "${proxy_env[@]}" apt-get install -y "${packages_to_install[@]}"
            else
                sudo apt-get install -y "${packages_to_install[@]}"
            fi
        fi

        log_success "✓ Prerequisites installed successfully"
    else
        log_info "✓ All Git prerequisites are already installed"
    fi
}

backup_existing_git_config() {
    local gitconfig_path="$TARGET_HOME/.gitconfig"
    if [[ -f "$gitconfig_path" ]]; then
        local backup_file
        backup_file="$TARGET_HOME/.gitconfig.backup.$(date +%Y%m%d-%H%M%S)" || {
            log_error "Failed to generate backup filename"
            exit 1
        }
        cp "$gitconfig_path" "$backup_file"
        log_info "Backed up existing config to: $backup_file"
    fi
}

create_gitconfig() {
    log_info "Creating .gitconfig in $TARGET_HOME..."

    # Prepare proxy configuration lines
    local proxy_config=""
    if [[ -n "${PROXY_URL}" ]]; then
        proxy_config="
[http]
    proxy = $PROXY_URL
    sslVerify = true

[https]
    proxy = $PROXY_URL
    sslVerify = true
"
    fi

    cat > "$TARGET_HOME/.gitconfig" << EOF
# Git configuration for Intel environment
# Generated on $(date)

[user]
    name = $USER_NAME
    email = $USER_EMAIL
$proxy_config
[core]
    editor = $DEFAULT_EDITOR
    autocrlf = input
    longpaths = true

[init]
    defaultBranch = $DEFAULT_BRANCH

[push]
    default = simple

[pull]
    rebase = false

[credential]
    helper = cache --timeout=$CACHE_TIMEOUT

[color]
    ui = auto

# Git LFS configuration
[filter "lfs"]
    clean = git-lfs clean -- %f
    smudge = git-lfs smudge -- %f
    process = git-lfs filter-process
    required = true

# Useful aliases
[alias]
    st = status
    co = checkout
    br = branch
    ci = commit
    lg = log --oneline --graph --all
    last = log -1 HEAD
    unstage = reset HEAD --

[merge]
    tool = vimdiff

[diff]
    tool = vimdiff
EOF

    # Set proper ownership if running as root
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.gitconfig"
        log_info "Set ownership of .gitconfig to $TARGET_USER"
    fi

    log_success "✓ Git configuration created at $TARGET_HOME/.gitconfig"
}

handle_default_credentials_cleanup() {
    local default_name="ECG Developer"
    local default_email="ecg.sse.pid.gmdc.mys.graphics@intel.com"

    # Only perform cleanup if defaults were used
    if [[ "$USER_NAME" == "$default_name" && "$USER_EMAIL" == "$default_email" ]]; then
        log_warning "Default credentials detected - removing .gitconfig with placeholder values"

        local gitconfig_path="$TARGET_HOME/.gitconfig"

        # Delete the current .gitconfig that contains default values
        if [[ -f "$gitconfig_path" ]]; then
            rm -f "$gitconfig_path"
            log_info "Deleted .gitconfig with default credentials"
        fi

        # Find and restore the most recent backup
        local backup_file
        backup_file=$(find "$TARGET_HOME" -maxdepth 1 -name ".gitconfig.backup.*" -type f 2>/dev/null | sort | tail -1)

        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            cp "$backup_file" "$gitconfig_path"

            # Set proper ownership if running as root
            if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
                chown "$TARGET_USER:$TARGET_USER" "$gitconfig_path"
            fi

            log_success "✓ Restored backup .gitconfig from: $(basename "$backup_file")"
        else
            log_warning "   No .gitconfig configured - no backup found"
            log_warning "   Please configure your Git identity with:"
            log_warning "   git config --global user.name 'Your Name'"
            log_warning "   git config --global user.email 'your.email@intel.com'"
        fi
        return 0  # Indicate cleanup was performed
    fi
    return 1  # Indicate no cleanup was needed
}

setup_git_lfs() {
    log_info "Setting up Git LFS..."

    # Check if git-lfs is available
    if ! command -v git-lfs >/dev/null 2>&1; then
        log_error "git-lfs not found. This should have been installed earlier."
        return 1
    fi

    # Install LFS for the target user
    if [[ $EUID -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        # Run as target user with proper environment
        log_info "Installing Git LFS for user: $TARGET_USER"
        if sudo -u "$TARGET_USER" -H git lfs install; then
            log_success "✓ Git LFS configured for $TARGET_USER"
        else
            log_error "Failed to configure Git LFS"
            return 1
        fi
    else
        # Run as current user
        log_info "Installing Git LFS for current user"
        if git lfs install; then
            log_success "✓ Git LFS configured"
        else
            log_error "Failed to configure Git LFS"
            return 1
        fi
    fi
}

configure_git() {
    log_section "GIT CONFIGURATION"

    # Determine target user and home directory
    get_target_user_info

    # Install prerequisites (git and git-lfs)
    install_git_prerequisites

    # Check if .gitconfig already exists with valid configuration
    local gitconfig_path="$TARGET_HOME/.gitconfig"
    local skip_config_creation=false

    if [[ -f "$gitconfig_path" ]]; then
        log_info "Checking existing .gitconfig for valid configuration..."

        # Check if both name and email are configured
        local existing_name existing_email existing_lfs
        existing_name=$(git config --global user.name 2>/dev/null || echo "")
        existing_email=$(git config --global user.email 2>/dev/null || echo "")
        existing_lfs=$(git lfs version 2>/dev/null && git config --global filter.lfs.clean 2>/dev/null || echo "")

        if [[ -n "$existing_name" && -n "$existing_email" && -n "$existing_lfs" ]]; then
            log_info "Found valid Git configuration:"
            log_info "  Name: $existing_name"
            log_info "  Email: $existing_email"
            log_info "Skipping .gitconfig backup and recreation"
            skip_config_creation=true
        fi
    fi

    if [[ "$skip_config_creation" == "false" ]]; then
        # Get user input
        get_user_input

        # Backup existing config
        backup_existing_git_config

        # Create new config
        create_gitconfig
    fi

    # Setup Git LFS
    setup_git_lfs

    # Handle cleanup of default credentials if used
    if ! handle_default_credentials_cleanup; then
        log_success "Git configuration completed!"
    else
        log_warning "Default credentials removed."
    fi
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

detect_kernel_version() {
    log_info "Detecting available Intel kernels..."

    # Look for Intel kernels in /boot using find instead of ls
    local intel_kernels
    if [[ -d "/boot" ]]; then
        intel_kernels=$(find /boot -maxdepth 1 -name "vmlinuz-*intel" -type f 2>/dev/null | \
                       sed 's|.*/vmlinuz-||' | sort -V | tail -1) || intel_kernels=""
    else
        intel_kernels=""
    fi

    if [[ -n "$intel_kernels" ]]; then
        DEFAULT_KERNEL_VERSION="$intel_kernels"
        log_info "Detected Intel kernel: $DEFAULT_KERNEL_VERSION"
    else
        log_warning "No Intel kernel found, using default: $DEFAULT_KERNEL_VERSION"
    fi
}

configure_grub_default() {
    log_info "Configuring default kernel selection..."

    # Validate kernel version is set
    if [[ -z "$DEFAULT_KERNEL_VERSION" ]]; then
        log_error "No kernel version specified"
        exit 1
    fi

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

configure_kernel_parameters() {
    log_info "Configuring kernel parameters for Intel Xe SR-IOV..."

    local all_params="$INTEL_XE_PARAMS $CONSOLE_PARAMS"

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
    log_info "  - Intel Xe: $INTEL_XE_PARAMS"
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

    # Detect best kernel version
    detect_kernel_version

    # Configure GRUB settings
    configure_grub_default
    configure_grub_timeout
    configure_kernel_parameters

    # Apply changes
    update_grub

    log_success "✓ GRUB configuration completed!"
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

    if [[ -n "${PROXY_URL}" ]]; then
        echo "✓ Git configured with proxy settings"
    else
        echo "✓ Git configured"
    fi

    echo "✓ GRUB configured for Intel Xe SR-IOV"
    echo ""
    echo "Next steps:"
    echo "1. Install SAI and ECG components"
    echo "2. Reboot the system"
    echo "3. Verify Intel Xe driver loads: lsmod | grep xe"
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
                    log_info "Usage: sudo $0 [--proxy URL]"
                    exit 1
                fi
                ;;
            --help|-h)
                echo "Usage: sudo $0 [--proxy URL]"
                echo ""
                echo "Options:"
                echo "  --proxy URL    Optional proxy server URL (e.g., http://proxy.example.com:911)"
                echo "  --help, -h     Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_info "Usage: sudo $0 [--proxy URL]"
                exit 1
                ;;
        esac
    done

    log_section "SETUP PREREQUISITES FOR INTEL ENVIRONMENT"

    # System checks
    check_ubuntu_version
    check_privileges

    # Execute setup steps
    optimize_boot_performance
    configure_git
    configure_grub

    # Final summary
    show_final_summary

    log_success "All prerequisites setup completed successfully!"
}

# Run main function
main "$@"
