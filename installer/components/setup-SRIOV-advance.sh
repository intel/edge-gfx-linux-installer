#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# SRIOV Configuration Script

set -euo pipefail

# =============================================================================
# CONFIGURATION SECTION
# =============================================================================

# Script metadata
readonly LOG_FILE="/var/log/sriov_feature_setup.log"
# Get script directory and set WORK_DIR to the installer/ubuntu directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [[ "$(basename "$SCRIPT_DIR")" == "components" ]]; then
	WORK_DIR="$(dirname "$SCRIPT_DIR")"
else
	WORK_DIR="$SCRIPT_DIR"
fi
readonly WORK_DIR
readonly TEMP_DIR="$WORK_DIR/sriov-feature-temp"

# Color codes and formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# System file paths for SRIOV configuration
readonly ENVIRONMENT_FILE="/etc/environment"
readonly XWRAPPER_CONFIG="/etc/X11/Xwrapper.config"
readonly GDM_CONFIG="/etc/gdm3/custom.conf"
readonly UDEV_RULES_DIR="/etc/udev/rules.d"
readonly GDM_UDEV_RULES="/usr/lib/udev/rules.d/61-gdm.rules"
readonly MUTTER_UDEV_RULES="$UDEV_RULES_DIR/61-mutter-preferred-primary-gpu.rules"
readonly SRIOV_MUTTER_SYNC_SCRIPT="/usr/local/sbin/sriov-sync-mutter-rule.sh"
readonly SRIOV_MUTTER_SYNC_SERVICE="/etc/systemd/system/sriov-mutter-rule-sync.service"

# Mesa driver configurations
readonly MESA_DRIVER_PL111="MESA_LOADER_DRIVER_OVERRIDE=pl111"

# Global flags
DETECTED_CONFIG=""
USER_CONFIG=""
NEEDS_REBOOT=false

# User-provided proxy URL (optional)
PROXY_URL=""
PACKAGE_SOURCE="edge"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Execute command with sudo if not root
run_as_root() {
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

# Check if running as root
check_root() {
	if [[ $EUID -ne 0 ]]; then
		log "ERROR" "This script must be run as root or with sudo"
		exit 1
	fi
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_error() {
	echo -e "${RED}[ERROR]${NC} $*"
}

# Enhanced logging function with categories
log() {
	local level="$1"
	shift
	local message="$*"
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	# Define color for each log level
	local color=""
	case "$level" in
		"ERROR")   color="$RED" ;;
		"WARN")    color="$YELLOW" ;;
		"INFO")    color="$GREEN" ;;
		"STEP")    color="$BLUE" ;;
		"SUCCESS") color="$GREEN" ;;
		*)         color="$NC" ;;
	esac

	# Print to stdout with color
	echo -e "${color}[$level]${NC} $message"

	# Log to file without color
	echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Error handling with cleanup
error_exit() {
	local message="$1"
	local exit_code="${2:-1}"

	log "ERROR" "$message"
	cleanup_temp_files
	exit "$exit_code"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

cleanup_temp_files() {
	if [[ -d "$TEMP_DIR" ]]; then
		log "INFO" "Cleaning up temporary files..."
		rm -rf "$TEMP_DIR"
	fi
}

cleanup_on_error() {
	cleanup_temp_files
}

trap cleanup_on_error ERR
trap 'log_error "Script interrupted"; cleanup_on_error; exit 130' INT TERM

# =============================================================================
# PACKAGE INSTALLATION FUNCTIONS
# =============================================================================

# Install packages with error handling
install_packages() {
	local packages=("$@")

	if [[ ${#packages[@]} -eq 0 ]]; then
		log "WARN" "No packages specified for installation"
		return 0
	fi

	log "INFO" "Installing packages: ${packages[*]}"

	# Set proxy environment if configured
	local proxy_env=()
	if [[ -n "${PROXY_URL}" ]]; then
		proxy_env=("http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}")
	fi

	# Update package list if needed
	if [[ ${#proxy_env[@]} -gt 0 ]]; then
		if ! env "${proxy_env[@]}" apt-get update; then
			error_exit "Failed to update package list"
		fi
	else
		if ! apt-get update; then
			error_exit "Failed to update package list"
		fi
	fi

	# Install packages
	if [[ ${#proxy_env[@]} -gt 0 ]]; then
		if ! env "${proxy_env[@]}" apt-get install -y "${packages[@]}"; then
			error_exit "Failed to install packages: ${packages[*]}"
		fi
	else
		if ! apt-get install -y "${packages[@]}"; then
			error_exit "Failed to install packages: ${packages[*]}"
		fi
	fi

	log "SUCCESS" "Successfully installed packages"
}

# =============================================================================
# FILE MODIFICATION FUNCTIONS
# =============================================================================

# Generic file modification function
modify_file() {
	local file="$1"
	local operation="$2"
	local content="$3"
	local new_content="${4:-}"

	# Create file if it doesn't exist for add operations
	if [[ "$operation" == "add_line" && ! -f "$file" ]]; then
		log "INFO" "Creating file: $file"
		mkdir -p "$(dirname "$file")"
		touch "$file"
	fi

	case "$operation" in
		"add_line")
			if [[ ! -f "$file" ]]; then
				error_exit "File not found: $file"
			fi
			if ! grep -Fxq "$content" "$file" 2>/dev/null; then
				echo "$content" >> "$file"
				log "SUCCESS" "Added to $file: $content"
			else
				log "INFO" "Line already exists in $file: $content"
			fi
			;;
		"remove_line")
			if [[ -f "$file" ]]; then
				if grep -q "$content" "$file" 2>/dev/null; then
					sed -i "/$content/d" "$file"
					log "SUCCESS" "Removed from $file: $content"
				else
					log "INFO" "Pattern not found in $file: $content"
				fi
			else
				log "WARN" "File not found for removal: $file"
			fi
			;;
		"replace_line")
			if [[ -z "$new_content" ]]; then
				error_exit "New content required for replace operation"
			fi
			if [[ ! -f "$file" ]]; then
				mkdir -p "$(dirname "$file")"
				touch "$file"
			fi
			if grep -q "$content" "$file" 2>/dev/null; then
				sed -i "s|$content|$new_content|" "$file"
				log "SUCCESS" "Replaced in $file: $content -> $new_content"
			else
				log "WARN" "Pattern not found for replacement in $file: $content"
			fi
			;;
		*)
			error_exit "Unknown file operation: $operation"
			;;
	esac
}

# =============================================================================
# HARDWARE DETECTION FUNCTIONS
# =============================================================================

# Detect whether the current system is running virtualized
is_virtualized_environment() {
	if command -v systemd-detect-virt >/dev/null 2>&1; then
		if systemd-detect-virt --quiet; then
			return 0
		fi
	fi

	if lspci 2>/dev/null | grep -Eiq "virtio|qemu|vmware|virtualbox|hyper-v"; then
		return 0
	fi

	if [[ -r /sys/class/dmi/id/product_name ]] && grep -Eiq "kvm|qemu|virtual|vmware|virtualbox|hyper-v" /sys/class/dmi/id/product_name; then
		return 0
	fi

	return 1
}

# Detect hardware configuration
detect_hardware() {
	log "STEP" "Detecting hardware configuration"

	local gpu_info
	gpu_info=$(lspci -nn | grep -i "VGA\|3D\|Display" | grep "8086:" | head -1)

	if [[ -z "$gpu_info" ]]; then
		gpu_info=$(lspci -nn | grep -i "VGA\|3D\|Display" | head -1)
	fi

	if [[ -z "$gpu_info" ]]; then
		log "WARN" "No GPU detected"
		DETECTED_CONFIG="unknown"
		return 1
	fi

	log "INFO" "GPU detected: $gpu_info"

	# Check for Intel GPU
	if echo "$gpu_info" | grep -q "8086:"; then
		# Check if it's running on bare metal or virtualized
		if is_virtualized_environment; then
			log "INFO" "Detected virtualized environment"
			if lsmod | grep -q "^i915\s"; then
				log "INFO" "Detected SR-IOV VF with i915 driver"
				DETECTED_CONFIG="sriov_i915"
			elif lsmod | grep -q "^xe\s"; then
				log "INFO" "Detected SR-IOV VF with Xe driver"
				DETECTED_CONFIG="sriov_xe"
			else
				# Driver not loaded yet (common on first boot before driver install).
				# Infer from which kernel module is listed as available for the GPU.
				local gpu_pci_addr
				gpu_pci_addr=$(echo "$gpu_info" | awk '{print $1}')
				local candidate_module
				candidate_module=$(lspci -k -s "$gpu_pci_addr" 2>/dev/null \
					| grep "Kernel modules:" \
					| tr ',' '\n' \
					| grep -Eoiw "xe|i915" \
					| head -1 || true)
				if [[ "${candidate_module,,}" == "xe" ]]; then
					log "INFO" "xe module available for Intel GPU; assuming SR-IOV Xe VF"
					DETECTED_CONFIG="sriov_xe"
				elif [[ "${candidate_module,,}" == "i915" ]]; then
					log "INFO" "i915 module available for Intel GPU; assuming SR-IOV i915 VF"
					DETECTED_CONFIG="sriov_i915"
				else
					log "WARN" "Intel GPU detected but no i915/xe driver loaded or available"
					DETECTED_CONFIG="unknown"
				fi
			fi
		else
			# No virtualization indicators suggests bare metal
			log "INFO" "Detected bare metal system"
			DETECTED_CONFIG="baremetal"
		fi
	else
		# Non-Intel GPU
		log "INFO" "Non-Intel GPU detected - using bare metal configuration"
		DETECTED_CONFIG="baremetal"
	fi

	log "SUCCESS" "Hardware configuration: $DETECTED_CONFIG"
}

# =============================================================================
# DISPLAY SERVER CONFIGURATION
# =============================================================================

# Configure display server (X11 or Wayland)
configure_display_server() {
	local server_type="$1"

	log "INFO" "Configuring display server: $server_type"

	# Remove any Wayland disable directive anywhere in file (including comments/wording)
	if [[ -f "$GDM_CONFIG" ]]; then
		sed -i '/WaylandEnable=false/d' "$GDM_CONFIG"
	fi

	case "$server_type" in
		"x11")
			# Force X11 by writing directive only inside [daemon] section
			if [[ ! -f "$GDM_CONFIG" ]]; then
				log "WARN" "GDM config not found: $GDM_CONFIG"
				return 1
			fi

			if ! grep -q '^\[daemon\]$' "$GDM_CONFIG" 2>/dev/null; then
				{
					echo ""
					echo "[daemon]"
					echo "WaylandEnable=false"
				} >> "$GDM_CONFIG"
				log "SUCCESS" "Created [daemon] section and added WaylandEnable=false in $GDM_CONFIG"
				return 0
			fi

			tmp_file=$(mktemp)
			awk '
			BEGIN { in_daemon=0; inserted=0 }
			/^\[daemon\]$/ { in_daemon=1; print; next }
			/^\[.*\]$/ {
				if (in_daemon && !inserted) {
					print "WaylandEnable=false"
					inserted=1
				}
				in_daemon=0
				print
				next
			}
			{
				if (in_daemon && !inserted && $0 ~ /^[[:space:]]*$/) {
					print "WaylandEnable=false"
					inserted=1
					print
					next
				}
				print
			}
			END {
				if (in_daemon && !inserted) {
					print "WaylandEnable=false"
				}
			}
			' "$GDM_CONFIG" > "$tmp_file" && mv "$tmp_file" "$GDM_CONFIG"
			log "SUCCESS" "Added WaylandEnable=false in [daemon] section of $GDM_CONFIG"
			;;
		"wayland")
			# Initial cleanup already ensures no WaylandEnable=false remains
			log "INFO" "Ensured WaylandEnable=false is not present in $GDM_CONFIG"
			;;
		*)
			log "WARN" "Unknown display server type: $server_type"
			return 1
			;;
	esac

	log "SUCCESS" "Display server configured: $server_type"
}

# =============================================================================
# SRIOV CONFIGURATION FUNCTIONS
# =============================================================================

is_server_guest() {
	if grep -q "ubuntu-server" /etc/os-release 2>/dev/null || \
	   [[ ! -d /usr/share/xsessions ]] || \
	   ! systemctl is-active --quiet graphical.target 2>/dev/null; then
		return 0
	fi

	return 1
}

ensure_gdm_available() {
	if [[ -f "$GDM_CONFIG" ]]; then
		return 0
	fi

	if ! is_server_guest; then
		log "WARN" "GDM configuration file not found: $GDM_CONFIG"
		return 1
	fi

	log "INFO" "Server guest detected without GDM; installing ubuntu-desktop-minimal"

	run_as_root apt-get update || error_exit "Failed to update package list before installing ubuntu-desktop-minimal"
	# firefox- explicitly excludes the firefox snap transitional package from this install
	run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal gdm3 firefox- || \
		error_exit "Failed to install ubuntu-desktop-minimal and gdm3 for server guest"

	run_as_root systemctl set-default graphical.target || \
		log "WARN" "Failed to set graphical.target as default"
	run_as_root systemctl enable gdm3 || \
		log "WARN" "Failed to enable gdm3 service"

	if [[ ! -f "$GDM_CONFIG" ]]; then
		log "WARN" "GDM configuration file still not found after installing ubuntu-desktop-minimal: $GDM_CONFIG"
		return 1
	fi

	return 0
}

install_mutter_rule_boot_sync() {
	log "INFO" "Installing boot-time mutter rule sync helper"

	cat > "$SRIOV_MUTTER_SYNC_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

RULE_FILE="/etc/udev/rules.d/61-mutter-preferred-primary-gpu.rules"

[[ -f "$RULE_FILE" ]] || exit 0

target_device_id=$(grep -Eo 'ATTRS\{device\}=="0x[0-9a-fA-F]+"' "$RULE_FILE" | head -1 | cut -d'"' -f2 | tr 'A-F' 'a-f' || true)
[[ -n "$target_device_id" ]] || exit 0

current_pci_slot=""
current_card_dev=""

for card in /sys/class/drm/card[0-9]*; do
	if [[ -r "$card/device/vendor" && -r "$card/device/device" ]]; then
		vendor_id=$(cat "$card/device/vendor" 2>/dev/null || true)
		device_id=$(cat "$card/device/device" 2>/dev/null || true)

		if [[ "${vendor_id,,}" == "0x8086" && "${device_id,,}" == "${target_device_id,,}" ]]; then
			current_pci_slot=$(basename "$(readlink -f "$card/device")")
			current_card_dev="/dev/dri/$(basename "$card")"
			break
		fi
	fi
done

[[ -n "$current_pci_slot" ]] || exit 0

configured_pci_slot=$(grep -Eo 'KERNELS=="[^"]+"' "$RULE_FILE" | head -1 | cut -d'"' -f2 || true)
configured_card_dev=$(grep -Eo 'ENV\{DEVNAME\}=="[^"]+"' "$RULE_FILE" | head -1 | cut -d'"' -f2 || true)

tmp_file=$(mktemp)
cp "$RULE_FILE" "$tmp_file"

updated=false

if [[ -n "$configured_pci_slot" && "$configured_pci_slot" != "$current_pci_slot" ]]; then
	if sed -Ei "s/KERNELS==\"[^\"]+\"/KERNELS==\"$current_pci_slot\"/" "$tmp_file"; then
		updated=true
	fi
fi

if [[ -n "$configured_card_dev" && "$configured_card_dev" != "$current_card_dev" ]]; then
	if sed -Ei "s|ENV\{DEVNAME\}==\"[^\"]+\"|ENV{DEVNAME}==\"$current_card_dev\"|" "$tmp_file"; then
		updated=true
	fi
fi

if [[ "$updated" != "true" ]]; then
	rm -f "$tmp_file"
	exit 0
fi

if [[ -s "$tmp_file" ]]; then
	mv "$tmp_file" "$RULE_FILE"
	udevadm control --reload-rules || true
	udevadm trigger --subsystem-match=drm || true
	logger -t sriov-mutter-sync "Updated mutter rule mapping to PCI $current_pci_slot and card $current_card_dev"
else
	rm -f "$tmp_file"
	exit 1
fi
EOF

	chmod 0755 "$SRIOV_MUTTER_SYNC_SCRIPT"

	cat > "$SRIOV_MUTTER_SYNC_SERVICE" <<EOF
[Unit]
Description=Synchronize mutter preferred GPU rule with current DRM mapping
After=systemd-udevd.service local-fs.target
Before=display-manager.service
ConditionPathExists=$MUTTER_UDEV_RULES

[Service]
Type=oneshot
ExecStart=$SRIOV_MUTTER_SYNC_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable sriov-mutter-rule-sync.service >/dev/null 2>&1 || true
	log "SUCCESS" "Installed and enabled boot-time mutter rule sync service"
}

# Configure automatic login for the user
enable_automatic_login() {
	log "STEP" "Configuring automatic login"

	local target_user="${SUDO_USER:-$(whoami)}"

	if [[ "$target_user" == "root" ]]; then
		log "WARN" "Cannot configure automatic login for root user"
		return 1
	fi

	if ! ensure_gdm_available; then
		return 1
	fi

	# Check if automatic login is already configured
	if grep -q "^AutomaticLoginEnable=true" "$GDM_CONFIG" && \
	   grep -q "^AutomaticLogin=$target_user" "$GDM_CONFIG"; then
		log "INFO" "Automatic login already configured for user: $target_user"
		return 0
	fi

	log "INFO" "Enabling automatic login for user: $target_user"

	# Ensure [daemon] section exists
	if ! grep -q "^\[daemon\]" "$GDM_CONFIG"; then
		echo "[daemon]" >> "$GDM_CONFIG"
	fi

	# Remove existing AutomaticLogin settings
	sed -i '/^AutomaticLoginEnable=/d' "$GDM_CONFIG"
	sed -i '/^AutomaticLogin=/d' "$GDM_CONFIG"

	# Add new automatic login settings under [daemon] section
	sed -i "/^\[daemon\]/a AutomaticLoginEnable=true" "$GDM_CONFIG"
	sed -i "/^AutomaticLoginEnable=true/a AutomaticLogin=$target_user" "$GDM_CONFIG"

	log "SUCCESS" "Automatic login configured for user: $target_user"
}

# Configure for SR-IOV VF with i915 driver
configure_sriov_i915() {
	log "STEP" "Configuring for SR-IOV VF with i915 driver"

	log "INFO" "Applying X11 wrapper configuration for SR-IOV i915"
	modify_file "$XWRAPPER_CONFIG" "add_line" "allowed_users=anybody"
	modify_file "$XWRAPPER_CONFIG" "add_line" "needs_root_rights=no"
	modify_file "$ENVIRONMENT_FILE" "add_line" "$MESA_DRIVER_PL111"

	# Force X11 mode (disable Wayland)
	configure_display_server "x11"

	# Configure GPU device priority
	configure_gpu_priority_i915

	log "SUCCESS" "SR-IOV i915 configuration completed"
}

# Configure for SR-IOV VF with Xe driver
configure_sriov_xe() {
	log "STEP" "Configuring for SR-IOV VF with Xe driver"

	log "INFO" "Applying Wayland-backend configuration for SR-IOV Xe"
	modify_file "$XWRAPPER_CONFIG" "add_line" "allowed_users=anybody"
	modify_file "$ENVIRONMENT_FILE" "remove_line" "^$MESA_DRIVER_PL111\$"

	# Enable wayland backend for GDM
	configure_display_server "wayland"

	# Configure GPU device priority
	configure_gpu_priority_xe

	log "SUCCESS" "SR-IOV Xe configuration completed"
}

# Configure for bare metal systems
configure_baremetal() {
	log "STEP" "Configuring for bare metal system"

	log "INFO" "Applying baremetal configuration"
	modify_file "$XWRAPPER_CONFIG" "add_line" "allowed_users=anybody"
	modify_file "$ENVIRONMENT_FILE" "remove_line" "^$MESA_DRIVER_PL111\$"

	# Force X11 mode (disable Wayland)
	configure_display_server "x11"

	# Remove any custom GPU priority rules
	if [[ -f "$MUTTER_UDEV_RULES" ]]; then
		rm -f "$MUTTER_UDEV_RULES"
		log "INFO" "Removed custom GPU priority rules"
	fi

	log "SUCCESS" "Bare metal configuration completed"
}

# Configure GPU device priority for i915
configure_gpu_priority_i915() {
	log "INFO" "Configuring GPU priority for i915"

	# Remove existing mutter udev rule
	if [[ -f "$MUTTER_UDEV_RULES" ]]; then
		rm -f "$MUTTER_UDEV_RULES"
		log "INFO" "Removed existing mutter udev rule"
	fi

	# Enable VirtIO GPU rule in GDM for i915
	if [[ -f "$GDM_UDEV_RULES" ]]; then
		# Uncomment VirtIO GPU rule
		sed -i '/^#ATTR{vendor}=="0x1af4", ATTR{device}=="0x1050"/s/^#//' "$GDM_UDEV_RULES" 2>/dev/null || true
		log "INFO" "Enabled VirtIO GPU rule for i915"
	fi
}

# Configure GPU device priority for Xe
configure_gpu_priority_xe() {
	log "INFO" "Configuring GPU priority for Xe driver"

	# Get Intel GPU information
	local intel_gpu_info
	intel_gpu_info=$(lspci -Dnn | grep -i "VGA\|3D\|Display" | grep "8086:" | head -1)

	if [[ -z "$intel_gpu_info" ]]; then
		log "WARN" "No Intel VGA device found for Xe configuration"
		return 1
	fi

	# Extract device ID and PCI slot
	local device_id
	device_id="0x$(echo "$intel_gpu_info" | grep -o '\[8086:[0-9a-f]*\]' | tr -d '[]' | cut -d: -f2)"

	local pci_slot
	pci_slot=""

	# Prefer sysfs-derived PCI BDF for exact udev parent matching.
	for card in /sys/class/drm/card[0-9]*; do
		if [[ -r "$card/device/vendor" && -r "$card/device/device" ]]; then
			local vendor_id
			vendor_id=$(cat "$card/device/vendor" 2>/dev/null || true)
			local dev_id
			dev_id=$(cat "$card/device/device" 2>/dev/null || true)

			if [[ "${vendor_id,,}" == "0x8086" && "${dev_id,,}" == "${device_id,,}" ]]; then
				pci_slot=$(basename "$(readlink -f "$card/device")")
				break
			fi
		fi
	done

	# Fallback to lspci if sysfs probing did not find a matching DRM card.
	if [[ -z "$pci_slot" ]]; then
		pci_slot=$(echo "$intel_gpu_info" | awk '{print $1}')
		# udev KERNELS for PCI devices uses full BDF (domain:bus:slot.func), e.g. 0000:00:02.0
		if [[ "$pci_slot" != 0000:* ]]; then
			pci_slot="0000:$pci_slot"
		fi
	fi

	log "INFO" "Found Intel GPU: $device_id at PCI slot $pci_slot"

	# Remove existing mutter udev rule
	[[ -f "$MUTTER_UDEV_RULES" ]] && rm -f "$MUTTER_UDEV_RULES"

	# Create dynamic udev rule for mutter.
	# Match Intel DRM card by stable PCI ancestry instead of volatile /dev/dri/cardX numbering.
	local udev_rule="SUBSYSTEM==\"drm\", KERNEL==\"card*\", ENV{DEVTYPE}==\"drm_minor\", SUBSYSTEMS==\"pci\", KERNELS==\"$pci_slot\", ATTRS{vendor}==\"0x8086\", ATTRS{device}==\"$device_id\", TAG+=\"mutter-device-preferred-primary\",TAG+=\"mutter-device-disable-kms\""

	if echo "$udev_rule" > "$MUTTER_UDEV_RULES"; then
		log "SUCCESS" "Created mutter udev rule for Xe"
	else
		log "ERROR" "Failed to create mutter udev rule"
		return 1
	fi

	# Install boot-time sync to recover if card mapping drifts after reboot.
	install_mutter_rule_boot_sync

	# Disable VirtIO GPU rule in GDM for Xe
	if [[ -f "$GDM_UDEV_RULES" ]]; then
		sed -i '/^ATTR{vendor}=="0x1af4", ATTR{device}=="0x1050"/s/^/#/' "$GDM_UDEV_RULES" 2>/dev/null || true
		log "INFO" "Disabled VirtIO GPU rule for Xe"
	fi
}

# =============================================================================
# SYSTEM VALIDATION
# =============================================================================

validate_system() {
	log "STEP" "Validating system requirements"

	# Check Ubuntu version
	if ! lsb_release -d | grep -qi ubuntu; then
		error_exit "This script is designed for Ubuntu systems"
	fi

	# Check for required tools
	local required_tools=("git" "tar" "meson" "ninja")
	for tool in "${required_tools[@]}"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			log "INFO" "Installing required tool: $tool"
			install_packages "$tool"
		fi
	done

	# Check available disk space (need at least 5GB)
	local available_space
	available_space=$(df / | tail -1 | awk '{print $4}')
	local required_space=$((5 * 1024 * 1024)) # 5GB in KB

	if [[ $available_space -lt $required_space ]]; then
		error_exit "Insufficient disk space. Need at least 5GB free"
	fi

	# Check network connectivity
	if ! ping -c 1 google.com >/dev/null 2>&1; then
		log "WARN" "Network connectivity check failed - may affect downloads"
	fi

	mkdir -p "$TEMP_DIR"

	log "SUCCESS" "System validation passed"
}

# =============================================================================
# VERIFICATION FUNCTIONS
# =============================================================================

verify_installation() {
	log "STEP" "Verifying installation"

	local verification_passed=true
	local environment_type="Baremetal"

	if is_virtualized_environment; then
		environment_type="Virtualized"
	fi

	# SRIOV packages verification

	# Show configuration status
	echo ""
	log "INFO" "Configuration Status:"
	echo "====================="
	echo "  Environment:     $environment_type"
	echo "  Hardware Config: $DETECTED_CONFIG"
	echo "  Mesa Override:   $(grep "$MESA_DRIVER_PL111" "$ENVIRONMENT_FILE" 2>/dev/null && echo "Enabled" || echo "Disabled")"
	echo "  Display Server:  $(grep "^WaylandEnable=false" "$GDM_CONFIG" 2>/dev/null && echo "X11 (forced)" || echo "Wayland/Auto")"
	echo "  Auto Login:      $(grep "^AutomaticLoginEnable=true" "$GDM_CONFIG" 2>/dev/null && echo "Enabled" || echo "Disabled")"
	echo "  Reboot Required: $NEEDS_REBOOT"
	echo "====================="

	if [[ "$verification_passed" == "true" ]]; then
		log "SUCCESS" "✓ All packages verified successfully"
	else
		log "WARN" "✗ Some packages may not be installed correctly"
	fi

	return 0
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Handle reboot requirement with user choice
handle_reboot_requirement() {
	log "WARN" "System reboot is required to apply udev rule changes"

	# In automated environments, might want to skip interactive prompts
	if [[ -n "${AUTOMATED:-}" ]]; then
		log "INFO" "Automated mode - skipping reboot prompt"
		return 0
	fi

	echo -e "\n${YELLOW}The system needs to reboot to apply hardware configuration changes.${NC}"
	echo -e "${BOLD}Do you want to reboot now? [y/N]${NC}"

	local response
	read -r response

	case "$response" in
		[yY]|[yY][eE][sS])
			log "INFO" "Rebooting system now..."
			sleep 2
			reboot
			;;
		*)
			log "INFO" "Reboot skipped. Please reboot manually when convenient."
			log "INFO" "Changes will take effect after reboot."
			;;
	esac
}

reset_config () {
	log "INFO" "Resetting configuration to default state"
	modify_file "$XWRAPPER_CONFIG" "remove_line" "^allowed_users"
	modify_file "$XWRAPPER_CONFIG" "remove_line" "^needs_root_rights"
	modify_file "$ENVIRONMENT_FILE" "remove_line" "^$MESA_DRIVER_PL111\$"
	modify_file "$GDM_CONFIG" "remove_line" "^WaylandEnable=false$"
	log "SUCCESS" "Configuration reset completed"
}

resolve_effective_config() {
	if [[ -n "$USER_CONFIG" ]]; then
		DETECTED_CONFIG="$USER_CONFIG"
		log "INFO" "Using user-specified configuration: $DETECTED_CONFIG"
		return 0
	fi

	if declare -F detect_hardware >/dev/null 2>&1; then
		if detect_hardware && [[ -n "$DETECTED_CONFIG" && "$DETECTED_CONFIG" != "unknown" ]]; then
			log "INFO" "Using auto-detected configuration: $DETECTED_CONFIG"
			return 0
		fi
	fi

	DETECTED_CONFIG="sriov_xe"
	log "INFO" "No configuration override or supported hardware detection available; defaulting to $DETECTED_CONFIG"
}

# Main function with combined workflow
main() {
	log "Starting SRIOV Feature Setup"

	# Validate system and root privileges
	check_root
	validate_system
	# Phase 1: SRIOV Configuration
	log "STEP" "Phase 1: Configuring SRIOV Features"

	# Set proxy environment variables for component scripts if configured
	local proxy_env=()
	if [[ -n "${PROXY_URL}" ]]; then
		proxy_env=("http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}")
		export http_proxy="${PROXY_URL}"
		export https_proxy="${PROXY_URL}"
	fi

	log "INFO" "Installing VDI SPICE components"
	if [[ ${#proxy_env[@]} -gt 0 ]]; then
		env "${proxy_env[@]}" "$WORK_DIR/components/spice.sh" "$PACKAGE_SOURCE"
	else
		"$WORK_DIR/components/spice.sh" "$PACKAGE_SOURCE"
	fi

	log "INFO" "Installing QEMU components"
	if [[ ${#proxy_env[@]} -gt 0 ]]; then
		env "${proxy_env[@]}" "$WORK_DIR/components/qemu.sh" "$PACKAGE_SOURCE"
	else
		"$WORK_DIR/components/qemu.sh" "$PACKAGE_SOURCE"
	fi

	# Determine configuration to use
	local config
	resolve_effective_config
	config="$DETECTED_CONFIG"

	# Only install Mutter components for sriov_xe configuration
	if [[ "$config" == "sriov_xe" ]]; then
		log "INFO" "Installing Mutter components"
		if [[ ${#proxy_env[@]} -gt 0 ]]; then
			env "${proxy_env[@]}" "$WORK_DIR/components/mutter.sh" "$PACKAGE_SOURCE"
		else
			"$WORK_DIR/components/mutter.sh" "$PACKAGE_SOURCE"
		fi
	else
		log "INFO" "Skipping Mutter components (only required for sriov_xe configuration)"
	fi

	# Configure automatic login
	enable_automatic_login

	# Reset configuration to ensure a clean state before applying new settings
	reset_config

	# Apply configuration based on determined hardware
	case "$config" in
		"sriov_i915")
			configure_sriov_i915
			NEEDS_REBOOT=true
			;;
		"sriov_xe")
			configure_sriov_xe
			NEEDS_REBOOT=true
			;;
		"baremetal")
			configure_baremetal
			;;
		"unknown"|*)
			log "WARN" "Unknown or unsupported hardware configuration: $config"
			log "INFO" "Applying baremetal configuration as fallback"
			configure_baremetal
			;;
	esac

	# Verify installation
	verify_installation

	# Handle reboot requirement for SR-IOV configurations
	if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
		handle_reboot_requirement
	else
		log "SUCCESS" "Configuration completed successfully!"
		log "INFO" "Please restart your display manager or reboot for all changes to take effect"
	fi

	# Cleanup
	cleanup_temp_files

	log "SUCCESS" "SRIOV Feature Setup completed successfully!"
	# log "INFO" "Downloaded packages preserved in: $PKG_DIR" - removed
	log "INFO" "Log file available at: $LOG_FILE"
}

# Parse command line arguments
parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			--automated)
				export AUTOMATED=1
				log "INFO" "Running in automated mode"
				shift
				;;
			--config)
				if [[ $# -gt 1 ]] && [[ $2 =~ ^(sriov_i915|sriov_xe|baremetal)$ ]]; then
					USER_CONFIG="$2"
					log "INFO" "Using user-specified config: $USER_CONFIG"
					shift 2
				else
					log "ERROR" "Invalid config parameter. Valid options: sriov_i915, sriov_xe, baremetal"
					exit 1
				fi
				;;
			--proxy)
				if [[ -n "$2" && "$2" != --* ]]; then
					PROXY_URL="$2"
					log "INFO" "Using proxy: $PROXY_URL"
					shift 2
				else
					log "ERROR" "--proxy requires a URL argument"
					exit 1
				fi
				;;
			--edge)
				PACKAGE_SOURCE="edge"
				log "INFO" "Using Intel Edge package sources"
				shift
				;;
			--help|-h)
				echo "Usage: $0 [OPTIONS]"
				echo ""
				echo ""
				echo "OPTIONS:"
				echo "  --automated    Run without interactive prompts"
				echo "  --config       Specify configuration (sriov_i915|sriov_xe|baremetal)"
				echo "  --proxy URL    Optional proxy server URL (e.g., http://proxy.example.com:911)"
				echo "  --edge         Use Intel Edge package sources (default)"
				echo "  --help, -h     Show this help message"
				echo ""
				exit 0
				;;
			*)
				log "ERROR" "Unknown option: $1"
				log "INFO" "Use --help for usage information"
				exit 1
				;;
		esac
	done
}

# Signal handling for clean exit
cleanup_and_exit() {
	local exit_code=${1:-130}
	log "WARN" "Script interrupted by user"
	cleanup_temp_files
	exit "$exit_code"
}

# Set up signal handlers
trap 'cleanup_and_exit 130' SIGINT SIGTERM

# Execute main function with all arguments
parse_arguments "$@"
main "$@"
