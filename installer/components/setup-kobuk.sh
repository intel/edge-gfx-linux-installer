#!/bin/bash

# Intel Graphics Staging Setup (Kobuk)
# Script that adds PPA, sets priority and install packages

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Intel Graphics PPA
INTEL_PPA="ppa:kobuk-team/intel-graphics-staging"

# Ubuntu 24.04 LTS packages
UBUNTU_PACKAGES="
    software-properties-common
    libmetee5
    intel-gsc
    libigdgmm12
    libigc2
    libigc-tools
    libze-intel-gpu-raytracing
    intel-media-va-driver-non-free
    libze1
    libze-dev
    libva2
    clinfo
    vainfo
    libvpl2
    libvpl-tools
    intel-metrics-discovery
    intel-metrics-discovery-dev
    intel-metrics-library
    intel-metrics-library-dev
    intel-ocloc
    libmfx-gen1
    libxpum-dev
    libxpum1
    libtbb12
    libtbbmalloc2
    intel-opencl-icd
    libze-intel-gpu1
    linux-intel
    xpu-smi
    va-driver-all
"

# Features for ease of use
FEATURE_PACKAGES="
    net-tools
    ovmf
    libxml2-utils
    openssh-server
    openssh-client
    vim
    git
    git-lfs
    libcacard0
    libphodav-3.0-0
    libphodav-3.0-common
    libusbredirhost1t64
    libusbredirparser1t64
    libaio1t64
    libboost-iostreams1.83.0
    libboost-thread1.83.0
    libdaxctl1
    libiscsi7
    libndctl6
    libpmem1
    libpmemobj1
    librados2
    librbd1
    librdmacm1t64
    liburing2
    libfdt1
    libslirp0
    seabios
    ipxe-qemu
    libjack-jackd2-0
    libsdl2-2.0-0
    libvirglrenderer1
    libelf-dev
    libzstd-dev
    zlib1g-dev
    virt-viewer
    bmap-tools
    mesa-utils
    mesa-va-drivers
    weston
    ffmpeg
    bridge-utils
    qemu-kvm
    libdw-dev
    libunwind-dev
    libzxing3
"

# Supported Ubuntu versions
SUPPORTED_VERSIONS=("24.04")

# User-provided proxy URL (optional)
PROXY_URL=""

# =============================================================================
# FUNCTIONS
# =============================================================================

# Logging functions
log_info() {
    echo -e "\e[34m[INFO]\e[0m $*"
}

log_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $*"
}

log_warning() {
    echo -e "\e[33m[WARNING]\e[0m $*"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $*" >&2
}

# Check and validate sudo privileges
check_sudo() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root"
        return 0
    fi

    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo privileges"
        sudo -v || { log_error "Sudo access required"; exit 1; }
    fi
}

# Execute command with sudo if not root
run_as_root() {
    if [[ $# -eq 0 ]]; then
        log_error "run_as_root: No command provided"
        return 1
    fi

    # Set proxy environment if configured
    local proxy_env=()
    if [[ -n "${PROXY_URL}" ]]; then
        proxy_env=("http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}")
    fi

    if [[ $EUID -eq 0 ]]; then
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            env "${proxy_env[@]}" "$@"
        else
            "$@"
        fi
    else
        if [[ ${#proxy_env[@]} -gt 0 ]]; then
            sudo env "${proxy_env[@]}" "$@"
        else
            sudo "$@"
        fi
    fi
}

# Detect and validate Ubuntu version
detect_ubuntu_version() {
    log_info "Detecting Ubuntu version..."

    if ! command -v lsb_release >/dev/null 2>&1; then
        log_error "lsb_release not found"
        log_info "Install with: sudo apt update && sudo apt install lsb-release"
        exit 1
    fi

    local ubuntu_version
    ubuntu_version=$(lsb_release -rs) || {
        log_error "Failed to detect Ubuntu version"
        exit 1
    }

    if [[ ! "$ubuntu_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Ubuntu version format: $ubuntu_version"
        exit 1
    fi

    UBUNTU_VERSION="$ubuntu_version"
    log_info "Detected Ubuntu $UBUNTU_VERSION"

    # Check if version is supported
    local supported=false
    for version in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ "$UBUNTU_VERSION" == "$version" ]]; then
            supported=true
            break
        fi
    done

    if [[ "$supported" != "true" ]]; then
        log_error "Ubuntu $UBUNTU_VERSION is not supported"
        log_info "Supported versions: ${SUPPORTED_VERSIONS[*]}"
        exit 1
    fi

    log_success "Ubuntu $UBUNTU_VERSION is supported"
}

# Add Intel Graphics staging PPA
add_intel_ppa() {
    log_info "Adding Intel Graphics staging PPA..."

    # Check if PPA is already added
    local ppa_exists=false
    if ls /etc/apt/sources.list.d/*.list >/dev/null 2>&1; then
        if grep -q "kobuk-team/intel-graphics-staging" /etc/apt/sources.list.d/*.list 2>/dev/null; then
            ppa_exists=true
        fi
    fi

    if [[ "$ppa_exists" == "true" ]]; then
        log_info "Intel Graphics PPA already added"
    else
        if run_as_root add-apt-repository -y "$INTEL_PPA"; then
            log_success "Intel Graphics PPA added"
        else
            log_error "Failed to add Intel Graphics PPA"
            exit 1
        fi
    fi
}

# Set Kobuk PPA priority to 700
set_kobuk_priority() {
    log_info "Setting Kobuk PPA priority to 700..."

    local pref_file="/etc/apt/preferences.d/99-intel-staging.pref"
    local pref_dir
    pref_dir="$(dirname "$pref_file")"

    # Create preferences directory if it doesn't exist
    if [[ ! -d "$pref_dir" ]]; then
        log_info "Creating preferences directory: $pref_dir"
        run_as_root mkdir -p "$pref_dir" || {
            log_error "Failed to create preferences directory"
            return 1
        }
    fi

    # Create preferences configuration
    if run_as_root tee "$pref_file" > /dev/null << 'EOF'; then
Package: *
Pin: release o=LP-PPA-kobuk-team-intel-graphics-staging
Pin-Priority: 700
EOF
        log_success "APT preferences file created: $pref_file"
    else
        log_error "Failed to create APT preferences file"
        return 1
    fi
}

# Update system packages
update_system() {
    log_info "Updating package lists..."

    if run_as_root apt-get update -qq; then
        log_success "Package lists updated"
    else
        log_error "Failed to update package lists"
        exit 1
    fi

    log_info "Upgrading existing packages..."
    if run_as_root apt-get upgrade -y; then
        log_success "System packages upgraded"
    else
        log_warning "Package upgrade had issues (continuing anyway)"
    fi
}

# Check if system is server installation and install desktop if needed
check_and_install_desktop() {
    log_info "Checking system installation type..."

    # Check if ubuntu-desktop is already installed
    if dpkg -l | grep -q "^ii.*ubuntu-desktop"; then
        log_info "Desktop environment already installed"
        return 0
    fi

    # Check if GUI is running (X11 or Wayland)
    if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        log_info "GUI environment detected, desktop packages likely installed"
        return 0
    fi

    # Check if systemd graphical target is active
    if systemctl is-active --quiet graphical.target 2>/dev/null; then
        log_info "Graphical target active, desktop environment present"
        return 0
    fi

    # Check for common desktop manager processes
    if pgrep -x "gdm3|lightdm|sddm|xdm" >/dev/null 2>&1; then
        log_info "Display manager detected, desktop environment present"
        return 0
    fi

    # If none of the above, assume server installation
    log_info "Server installation detected, installing desktop environment..."

    log_warning "This will install a full desktop environment (ubuntu-desktop)"
    log_warning "This may take a significant amount of time and disk space"

    if run_as_root apt-get install -y ubuntu-desktop; then
        log_success "Desktop environment installed successfully"
        log_warning "Reboot recommended after desktop installation"
    else
        log_error "Failed to install desktop environment"
        exit 1
    fi
}

# Generic function to install packages
install_packages() {
    local package_list="$1"
    local description="$2"

    log_info "Installing $description for Ubuntu $UBUNTU_VERSION..."

    # Clean and convert multiline string to simple space-separated list
    local clean_packages
    clean_packages=$(echo "$package_list" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ *//;s/ *$//') || {
        log_error "Failed to process $description package list"
        return 1
    }

    log_info "Installing $description..."

    # shellcheck disable=SC2086
    if run_as_root apt-get install -y $clean_packages; then
        log_success "All $description installed successfully"
    else
        log_error "$description installation failed"
        exit 1
    fi
}

# Verify Kobuk PPA priority
verify_kobuk_priority() {
    log_info "Verifying Kobuk PPA priority..."

    if apt-cache policy | grep -q kobuk; then
        local priority
        priority=$(apt-cache policy | grep -A1 kobuk | grep -o '[0-9]\+' | head -1) || {
            log_warning "Could not parse priority from apt-cache policy"
            return 0
        }

        if [[ "$priority" = "700" ]]; then
            log_success "Kobuk PPA priority verified: 700"
        else
            log_warning "Kobuk PPA priority: $priority (expected 700)"
        fi
    else
        log_warning "Kobuk PPA not found in apt policy"
    fi
}

# Display completion information
show_completion_info() {
    echo ""
    echo "=================================="
    echo "Intel Graphics Setup Complete"
    echo "=================================="
    echo "Ubuntu version: $UBUNTU_VERSION"
    echo "PPA: $INTEL_PPA"
    echo "Priority: 700"
    echo "Installation: Completed"
    echo "=================================="
    log_warning "REBOOT REQUIRED for changes to take effect"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

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
                log_warning "Unexpected argument: $1"
                log_warning "This script takes optional --proxy flag only."
                shift
                ;;
        esac
    done

    log_info "Intel Graphics Staging Setup (Kobuk)"
    echo "====================================="

    # Check prerequisites
    check_sudo
    detect_ubuntu_version

    # Setup PPA and priority
    add_intel_ppa
    set_kobuk_priority
    update_system
    # Check and install desktop if server
    check_and_install_desktop

    # Install main packages
    install_packages "$UBUNTU_PACKAGES" "Intel GPU packages"
    install_packages "$FEATURE_PACKAGES" "Other feature packages"

    # Verify and complete
    verify_kobuk_priority
    show_completion_info

    log_success "Intel Graphics staging setup completed!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
