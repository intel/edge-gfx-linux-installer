#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Intel Graphics PPA Common Helper
#
# Unified helper for component scripts:
#   - Provides shared APT pinning helpers (sourceable)
#   - Configures Intel Edge Graphics PPA (executable mode)
#
# Usage: sudo ./common-helper.sh [edge]
#
# =============================================================================

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

PPA_SELECTOR="edge"

# =============================================================================
# EDGE PPA CONFIGURATION
# =============================================================================

readonly EDGE_PPA_URL="https://download.01.org/intel-linux-overlay/ubuntu/"
readonly EDGE_SOURCES_FILE="/etc/apt/sources.list.d/edge-ppa.list"
readonly EDGE_GPG_KEY_PATH="/etc/apt/trusted.gpg.d/edge.gpg"
readonly EDGE_PREFERENCES_FILE="/etc/apt/preferences.d/90-intel-graphics-edge"

# When set to 1 by install-host.sh, component scripts will setup the selected
# PPA only once per install session while still supporting individual execution.
readonly PPA_SETUP_ONCE_ENV="INTEL_GFX_PPA_SETUP_ONCE"
readonly PPA_SETUP_SESSION_ENV="INTEL_GFX_PPA_SETUP_SESSION"
readonly DEFAULT_COMPONENT_PIN_PRIORITY="800"

# =============================================================================
# COLOR CODES
# =============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
	echo -e "${GREEN}[INFO]${NC} $*"
}

log_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
	echo -e "${BLUE}[STEP]${NC} $*"
}

log_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_component_banner() {
	local component_title="$1"

	if [[ -z "$component_title" ]]; then
		die "log_component_banner requires: <component_title>"
	fi

	log_info "${BOLD}${PPA_NAME} ${component_title}${NC}"
	log_info "Copyright (c) 2026 Intel Corporation"
	echo
}

log_component_completion() {
	local success_label="$1"
	local detail_message="$2"

	if [[ -z "$success_label" || -z "$detail_message" ]]; then
		die "log_component_completion requires: <success_label> <detail_message>"
	fi

	log_success "${BOLD}${success_label} completed successfully!${NC}"
	log_info "$detail_message"
	echo
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

die() {
	log_error "$*"
	exit 1
}

run_cmd() {
	local cmd="$*"
	if ! eval "$cmd"; then
		die "Command failed: $cmd"
	fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
	if [[ $EUID -ne 0 ]]; then
		die "This script must be run as root"
	fi
}

setup_selected_ppa() {
	local ppa_script="$1"
	local ppa_selector="$2"
	local ppa_name="$3"
	local ppa_script_name
	local marker_file=""

	if [[ -z "$ppa_script" || -z "$ppa_selector" || -z "$ppa_name" ]]; then
		die "setup_selected_ppa requires: <ppa_script> <ppa_selector> <ppa_name>"
	fi

	ppa_script_name=$(basename "$ppa_script")

	if [[ "${!PPA_SETUP_ONCE_ENV:-0}" == "1" ]]; then
		marker_file="/tmp/intel-gfx-ppa-${ppa_selector}-${!PPA_SETUP_SESSION_ENV:-default}.done"
		if [[ -f "$marker_file" ]]; then
			log_info "$ppa_name setup already completed in this install-host session, skipping"
			return 0
		fi
	fi

	if is_selected_ppa_already_configured "$ppa_selector"; then
		log_info "$ppa_name already configured and up to date, skipping setup"
		if [[ -n "$marker_file" ]]; then
			: > "$marker_file"
		fi
		return 0
	fi

	log_step "Setting up $ppa_name"

	if [[ ! -f "$ppa_script" ]]; then
		die "PPA script not found: $ppa_script"
	fi

	log_info "Executing $ppa_script_name..."
	if ! bash "$ppa_script" "$ppa_selector"; then
		die "Failed to setup $ppa_name"
	fi

	if [[ -n "$marker_file" ]]; then
		: > "$marker_file"
	fi

	log_success "$ppa_name setup completed"
}

update_package_cache() {
	log_step "Updating package cache"
	run_cmd "apt update"
	log_success "Package cache updated"
}

repair_apt_state_if_needed() {
	if apt-get check >/dev/null 2>&1; then
		return 0
	fi

	log_warning "Detected broken package state; running apt-get install -f to repair"
	if DEBIAN_FRONTEND=noninteractive apt-get install -f -y; then
		log_success "Package state repaired successfully"
	else
		die "Failed to repair package state with apt-get install -f"
	fi
}

get_installed_version() {
	local package_name="$1"

	if dpkg -l "$package_name" 2>/dev/null | grep -q "^ii"; then
		dpkg -l "$package_name" 2>/dev/null | grep "^ii" | awk '{print $3}' || echo "unknown"
	else
		echo "-"
	fi
}

resolve_package_version_from_origin() {
	local package_name="$1"
	local pin_origin="$2"

	if [[ -z "$package_name" || -z "$pin_origin" ]]; then
		die "resolve_package_version_from_origin requires: <package_name> <pin_origin>"
	fi

	apt-cache madison "$package_name" 2>/dev/null | awk -F'|' -v origin="$pin_origin" '
		{
			repo=$3
			ver=$2
			gsub(/^[ \t]+|[ \t]+$/, "", repo)
			gsub(/^[ \t]+|[ \t]+$/, "", ver)
			if (index(repo, origin) > 0) {
				print ver
				exit
			}
		}
	' || true
}

install_component_packages() {
	local component_name="$1"
	local pin_origin="$2"
	shift 2

	if [[ -z "$component_name" || -z "$pin_origin" || $# -eq 0 ]]; then
		die "install_component_packages requires: <component_name> <pin_origin> <package...>"
	fi

	log_step "Installing $component_name packages"
	log_info "Installing based on selected PPA and pin priority"

	local available_packages=()
	local install_targets=()
	local package_spec package_name requested_version resolved_version target_version installed_version
	declare -A target_versions
	target_versions=()

	for package_spec in "$@"; do
		package_name="${package_spec%%=*}"
		requested_version=""
		if [[ "$package_spec" == *"="* ]]; then
			requested_version="${package_spec#*=}"
		fi

		if [[ -n "$requested_version" ]]; then
			resolved_version=$(apt-cache madison "$package_name" 2>/dev/null | awk -F'|' -v version="$requested_version" '
				{
					ver=$2
					gsub(/^[ \t]+|[ \t]+$/, "", ver)
					if (ver == version) {
						print ver
						exit
					}
				}
			') || true
		else
			resolved_version=$(resolve_package_version_from_origin "$package_name" "$pin_origin")
		fi

		if [[ -n "$resolved_version" ]]; then
			if [[ -n "$requested_version" ]]; then
				log_info "Resolved package $package_name requested version in apt metadata: $resolved_version"
			else
				log_info "Resolved package $package_name from origin $pin_origin: $resolved_version"
			fi

			available_packages+=("$package_name")

			target_version=""
			if [[ -n "$requested_version" ]]; then
				target_version="$requested_version"
			else
				target_version="$resolved_version"
			fi

			if [[ -n "$target_version" ]]; then
				install_targets+=("${package_name}=${target_version}")
				target_versions["$package_name"]="$target_version"
			else
				install_targets+=("$package_name")
			fi
		else
			log_warning "Package $package_name: Not found, skipping"
		fi
	done

	if [[ ${#available_packages[@]} -eq 0 ]]; then
		die "No $component_name packages found in repositories"
	fi

	local already_installed=true
	for package_name in "${available_packages[@]}"; do
		installed_version=$(get_installed_version "$package_name")
		if [[ "$installed_version" == "-" ]]; then
			already_installed=false
			break
		fi

		target_version="${target_versions[$package_name]:-}"
		if [[ -n "$target_version" && "$installed_version" != "$target_version" ]]; then
			already_installed=false
			break
		fi
	done

	if [[ "$already_installed" == true ]]; then
		log_info "All available $component_name packages are already installed; skipping installation"
		return 0
	fi

	log_info "Installing $component_name packages with apt-get..."
	if DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "${install_targets[@]}"; then
		log_success "$component_name installation completed"
	else
		die "Failed to install $component_name packages"
	fi
}

prepare_component_install() {
	local ppa_script="$1"
	local ppa_selector="$2"
	local ppa_name="$3"
	local preferences_file="$4"
	local pin_origin="$5"
	local pin_priority="$6"
	shift 6

	if [[ -z "$ppa_script" || -z "$ppa_selector" || -z "$ppa_name" || -z "$preferences_file" || -z "$pin_origin" || -z "$pin_priority" ]]; then
		die "prepare_component_install requires: <ppa_script> <ppa_selector> <ppa_name> <preferences_file> <pin_origin> <pin_priority> -- <package...>"
	fi

	if [[ $# -gt 0 && "$1" == "--" ]]; then
		shift
	fi

	if [[ $# -eq 0 ]]; then
		die "prepare_component_install requires package names after --"
	fi

	check_root
	setup_selected_ppa "$ppa_script" "$ppa_selector" "$ppa_name"
	set_selected_ppa_priority_with_context "$preferences_file" "$pin_origin" "$ppa_name" "$pin_priority"
	update_package_cache
	repair_apt_state_if_needed
	install_component_packages "$ppa_name" "$pin_origin" "$@"
}

verify_component_packages() {
	local component_name="$1"
	local version_label="$2"
	shift 2

	if [[ -z "$component_name" ]]; then
		die "verify_component_packages requires: <component_name> [<version_label>] -- <pkg=version...> -- <package...>"
	fi

	local binary_name="${1:-}"
	local binary_version_command="${2:-}"
	shift 2 || true

	local version_pairs=()
	while [[ $# -gt 0 && "$1" != "--" ]]; do
		version_pairs+=("$1")
		shift
	done

	if [[ $# -gt 0 && "$1" == "--" ]]; then
		shift
	fi

	local packages=("$@")
	if [[ ${#packages[@]} -eq 0 ]]; then
		die "verify_component_packages requires package names after --"
	fi

	log_step "Verifying $component_name installation"
	if [[ -n "$version_label" && "$version_label" != "-" ]]; then
		log_info "$version_label"
	fi

	if [[ -n "$binary_name" && "$binary_name" != "-" && -n "$binary_version_command" && "$binary_version_command" != "-" ]]; then
		if command -v "$binary_name" >/dev/null 2>&1; then
			local version
			version=$(eval "$binary_version_command" 2>/dev/null || echo "unknown")
			log_success "$binary_name version: $version"
		else
			log_warning "$binary_name not found"
		fi
	fi

	declare -A preferred_versions=()
	local version_pair package_name preferred_version installed_version match_status
	for version_pair in "${version_pairs[@]}"; do
		package_name="${version_pair%%=*}"
		preferred_version="${version_pair#*=}"
		preferred_versions["$package_name"]="$preferred_version"
	done

	log_info "$component_name version comparison table:"
	printf '\n%-35s %-22s %-22s %-10s\n' "Package" "Installed version" "Preferred version" "Match"
	printf '%-35s %-22s %-22s %-10s\n' "-----------------------------------" "----------------------" "----------------------" "----------"

	for package_name in "${packages[@]}"; do
		installed_version=$(get_installed_version "$package_name")
		preferred_version="${preferred_versions[$package_name]:-}"

		if [[ "$installed_version" == "$preferred_version" ]]; then
			match_status="yes"
		else
			match_status="no"
		fi

		[[ -z "$installed_version" ]] && installed_version="-"
		[[ -z "$preferred_version" ]] && preferred_version="-"
		[[ -z "$match_status" ]] && match_status="-"

		printf '%-35s %-22s %-22s %-10s\n' "$package_name" "$installed_version" "$preferred_version" "$match_status"
	done
}

verify_component_packages_by_groups() {
	local component_name="$1"
	local version_label="$2"
	local binary_name="$3"
	local binary_version_command="$4"
	shift 4

	if [[ -z "$component_name" ]]; then
		die "verify_component_packages_by_groups requires: <component_name> <version_label> <binary_name> <binary_version_command> --group <version> -- <package...>"
	fi

	local version_pairs=()
	local packages=()
	local preferred_version package_name

	while [[ $# -gt 0 ]]; do
		if [[ "$1" != "--group" ]]; then
			die "verify_component_packages_by_groups expected --group, got: $1"
		fi
		shift

		if [[ $# -eq 0 ]]; then
			die "verify_component_packages_by_groups missing version after --group"
		fi
		preferred_version="$1"
		shift

		if [[ $# -eq 0 || "$1" != "--" ]]; then
			die "verify_component_packages_by_groups requires -- after each group version"
		fi
		shift

		if [[ $# -eq 0 ]]; then
			die "verify_component_packages_by_groups requires package names after group separator"
		fi

		while [[ $# -gt 0 && "$1" != "--group" ]]; do
			package_name="$1"
			packages+=("$package_name")
			version_pairs+=("${package_name}=${preferred_version}")
			shift
		done
	done

	if [[ ${#packages[@]} -eq 0 ]]; then
		die "verify_component_packages_by_groups requires at least one package"
	fi

	verify_component_packages "$component_name" "$version_label" "$binary_name" "$binary_version_command" "${version_pairs[@]}" -- "${packages[@]}"
}

set_selected_ppa_priority() {
	local pin_priority="$1"

	if [[ -z "$pin_priority" ]]; then
		die "set_selected_ppa_priority requires: <pin_priority>"
	fi

	set_selected_ppa_priority_with_context "$PREFERENCES_FILE" "$PPA_PIN_ORIGIN" "$PPA_NAME" "$pin_priority"
}


command_exists() {
	command -v "$1" >/dev/null 2>&1
}

detect_ubuntu_codename() {
	local codename

	if command_exists lsb_release; then
		codename=$(lsb_release -cs)
	elif [[ -f /etc/os-release ]]; then
		codename=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
	else
		log_warning "Cannot detect Ubuntu version, defaulting to noble"
		codename="noble"
	fi

	echo "$codename"
}

ensure_tool() {
	local tool="$1"
	if ! command_exists "$tool"; then
		log_info "Installing $tool..."
		run_cmd "apt install -y $tool"
	fi
}

parse_args() {
	if [[ $# -ge 1 ]]; then
		case "$1" in
			edge)
				PPA_SELECTOR="$1"
				;;
			*)
				echo -e "\033[0;31m[ERROR]\033[0m Unsupported PPA selector: $1 (expected: edge)" >&2
				exit 1
				;;
		esac
	fi

	if [[ $# -ge 2 ]]; then
		echo -e "\033[0;31m[ERROR]\033[0m Unexpected arguments: $*" >&2
		exit 1
	fi
}

# shellcheck disable=SC2034
ppa_configure_component_context() {
	local selector="$1"
	local helper_script="$2"

	case "$selector" in
		edge)
			PREFERENCES_FILE="$EDGE_PREFERENCES_FILE"
			PPA_SCRIPT="$helper_script"
			PPA_NAME="Intel Edge Graphics PPA"
			PPA_PIN_ORIGIN="download.01.org"
			;;
		*)
			die "Unsupported PPA selector: $selector"
			;;
	esac
}

get_component_context() {
	local selector="$1"

	ppa_configure_component_context "$selector" "$0"
	cat << EOF
PREFERENCES_FILE=${PREFERENCES_FILE}
PPA_SCRIPT=${PPA_SCRIPT}
PPA_NAME=${PPA_NAME}
PPA_PIN_ORIGIN=${PPA_PIN_ORIGIN}
EOF
}

emit_shell_assignment() {
	local name="$1"
	local value="$2"

	printf '%s=%q\n' "$name" "$value"
}

emit_shell_function() {
	local function_name="$1"

	declare -f "$function_name"
	printf '\n'
}

emit_component_runtime() {
	emit_shell_assignment "COMPONENT_PIN_PRIORITY" "$DEFAULT_COMPONENT_PIN_PRIORITY"
	emit_shell_assignment "RED" "$RED"
	emit_shell_assignment "GREEN" "$GREEN"
	emit_shell_assignment "YELLOW" "$YELLOW"
	emit_shell_assignment "BLUE" "$BLUE"
	emit_shell_assignment "BOLD" "$BOLD"
	emit_shell_assignment "NC" "$NC"

	emit_shell_function "log_info"
	emit_shell_function "log_warning"
	emit_shell_function "log_error"
	emit_shell_function "log_step"
	emit_shell_function "log_success"
	emit_shell_function "log_component_banner"
	emit_shell_function "log_component_completion"
	emit_shell_function "die"
	emit_shell_function "run_cmd"
}

init_component_context() {
	local helper_script="$1"
	shift || true

	if [[ -z "$helper_script" ]]; then
		die "init_component_context requires: <helper_script> [edge]"
	fi

	parse_args "$@"
	ppa_configure_component_context "$PPA_SELECTOR" "$helper_script"

	emit_shell_assignment "PPA_SELECTOR" "$PPA_SELECTOR"
	emit_shell_assignment "PREFERENCES_FILE" "$PREFERENCES_FILE"
	emit_shell_assignment "PPA_SCRIPT" "$PPA_SCRIPT"
	emit_shell_assignment "PPA_NAME" "$PPA_NAME"
	emit_shell_assignment "PPA_PIN_ORIGIN" "$PPA_PIN_ORIGIN"
	emit_component_runtime
}

set_selected_ppa_priority_with_context() {
	local preferences_file="$1"
	local pin_origin="$2"
	local ppa_name="$3"
	local pin_priority="$4"

	if [[ -z "$preferences_file" || -z "$pin_origin" || -z "$ppa_name" || -z "$pin_priority" ]]; then
		die "set_selected_ppa_priority_with_context requires: <preferences_file> <pin_origin> <ppa_name> <pin_priority>"
	fi

	log_step "Setting high priority for packages from $ppa_name"
	log_info "Updating shared preferences file: $preferences_file"

	upsert_pin_block "$preferences_file" "SELECTED_PPA_PRIORITY" "$pin_origin" "$pin_priority" "*"

	log_success "Selected PPA priority set to $pin_priority with repo-wide pinning"
}

remove_ppa_if_matching() {
	local ppa_label="$1"
	local ppa_url="$2"
	local sources_file="$3"
	local gpg_key_file="$4"
	local preferences_file="$5"

	local removed_any=0

	if [[ -f "$sources_file" ]]; then
		if grep -Fq "$ppa_url" "$sources_file"; then
			log_warning "Found configured $ppa_label matching $ppa_url; removing it"
		else
			log_warning "Found configured $ppa_label with different URL; removing to enforce single-source mode"
		fi
		rm -f "$sources_file"
		removed_any=1
	fi

	if [[ -f "$gpg_key_file" ]]; then
		rm -f "$gpg_key_file"
		removed_any=1
	fi

	if [[ -f "$preferences_file" ]]; then
		rm -f "$preferences_file"
		removed_any=1
	fi

	if [[ "$removed_any" -eq 1 ]]; then
		log_info "Removed conflicting $ppa_label artifacts"
	fi
}

repository_file_matches_url() {
	local sources_file="$1"
	local ppa_url="$2"

	[[ -f "$sources_file" ]] && grep -Fq "$ppa_url" "$sources_file"
}

repository_file_contains_line() {
	local sources_file="$1"
	local expected_line="$2"

	[[ -f "$sources_file" ]] && grep -Fxq "$expected_line" "$sources_file"
}

expected_edge_repo_codename() {
	local ubuntu_codename
	ubuntu_codename=$(detect_ubuntu_codename)

	case "$ubuntu_codename" in
		noble|jammy)
			echo "$ubuntu_codename"
			;;
		*)
			echo "noble"
			;;
	esac
}

edge_sources_match_expected() {
	local repo_codename
	repo_codename=$(expected_edge_repo_codename)

	if [[ "$repo_codename" == "jammy" ]]; then
		repository_file_contains_line "$EDGE_SOURCES_FILE" "deb ${EDGE_PPA_URL} jammy multimedia main non-free kernels" && \
			repository_file_contains_line "$EDGE_SOURCES_FILE" "deb-src ${EDGE_PPA_URL} jammy multimedia main non-free kernels"
		return
	fi

	repository_file_contains_line "$EDGE_SOURCES_FILE" "deb ${EDGE_PPA_URL} noble multimedia main non-free kernels" && \
		repository_file_contains_line "$EDGE_SOURCES_FILE" "deb-src ${EDGE_PPA_URL} noble multimedia main non-free kernels"
}

is_selected_ppa_already_configured() {
	local selector="$1"

	case "$selector" in
		edge)
			edge_sources_match_expected && [[ -f "$EDGE_GPG_KEY_PATH" ]]
			;;
		*)
			return 1
			;;
	esac
}

cleanup_selected_ppa_if_url_drift() {
	local selected_selector="$1"

	case "$selected_selector" in
		edge)
			if [[ -f "$EDGE_SOURCES_FILE" ]] && ! edge_sources_match_expected; then
				log_warning "Edge PPA source drift detected; removing stale Edge PPA artifacts"
				remove_ppa_if_matching "Intel Edge Graphics PPA" "$EDGE_PPA_URL" "$EDGE_SOURCES_FILE" "$EDGE_GPG_KEY_PATH" "$EDGE_PREFERENCES_FILE"
			fi
			;;
		*)
			die "Unsupported PPA selector: $selected_selector"
			;;
	esac
}

cleanup_conflicting_ppa() {
	local selected_selector="$1"

	cleanup_selected_ppa_if_url_drift "$selected_selector"

	case "$selected_selector" in
		edge)
			remove_ppa_if_matching "Intel Edge Graphics PPA" "$EDGE_PPA_URL" "$EDGE_SOURCES_FILE" "$EDGE_GPG_KEY_PATH" "$EDGE_PREFERENCES_FILE"
			;;
		*)
			die "Unsupported PPA selector: $selected_selector"
			;;
	esac
}

# =============================================================================
# COMMON PIN HELPERS (shared in this script)
# =============================================================================

ensure_preferences_file() {
	local preferences_file="$1"

	if [[ ! -f "$preferences_file" ]]; then
		printf '%s\n' \
			"# Intel graphics component priorities" \
			"# Managed by installer/components/common-helper.sh" \
			"" > "$preferences_file"
		chmod 0644 "$preferences_file"
	fi
}

upsert_pin_block() {
	local preferences_file="$1"
	local block_id="$2"
	local pin_origin="$3"
	local pin_priority="$4"
	shift 4

	local begin_marker="# BEGIN ${block_id}"
	local end_marker="# END ${block_id}"
	local tmp_file

	ensure_preferences_file "$preferences_file"

	tmp_file=$(mktemp)
	awk -v begin="$begin_marker" -v end="$end_marker" '
		$0 == begin { skip = 1; next }
		$0 == end   { skip = 0; next }
		!skip       { print }
	' "$preferences_file" > "$tmp_file"

	{
		echo "$begin_marker"
		for package_pattern in "$@"; do
			printf 'Package: %s\nPin: origin %s\nPin-Priority: %s\n\n' "$package_pattern" "$pin_origin" "$pin_priority"
		done
		echo "$end_marker"
		echo
	} >> "$tmp_file"

	mv "$tmp_file" "$preferences_file"
	chmod 0644 "$preferences_file"
}

# =============================================================================
# EDGE PPA FUNCTIONS
# =============================================================================

setup_edge_gpg_key() {
	log_step "Setting up GPG key for Intel Edge Graphics PPA"

	ensure_tool curl
	ensure_tool wget

	if ! curl --head --silent --fail "$EDGE_PPA_URL" > /dev/null; then
		die "Edge PPA URL is not accessible: $EDGE_PPA_URL"
	fi

	local html_content gpg_key gpg_filename
	html_content=$(curl --silent "$EDGE_PPA_URL")
	gpg_key=$(echo "$html_content" | grep -ioP '(?<=href=")[^"]*\.gpg' | head -1)

	if [[ -z "$gpg_key" ]]; then
		die "No GPG key found at the Edge PPA URL"
	fi

	gpg_filename=$(basename "$gpg_key")
	log_info "Found GPG key: $gpg_filename"
	run_cmd "wget '${EDGE_PPA_URL}${gpg_filename}' -O '$EDGE_GPG_KEY_PATH' --no-check-certificate"
	log_success "Edge GPG key installed: $EDGE_GPG_KEY_PATH"
}

setup_edge_repository() {
	local ubuntu_codename="$1"

	log_step "Setting up Intel Edge Graphics PPA repository"
	log_info "Detected Ubuntu codename: $ubuntu_codename"

	case "$ubuntu_codename" in
		noble)
			run_cmd "echo 'deb ${EDGE_PPA_URL} noble multimedia main non-free kernels' | tee '$EDGE_SOURCES_FILE'"
			run_cmd "echo 'deb-src ${EDGE_PPA_URL} noble multimedia main non-free kernels' | tee -a '$EDGE_SOURCES_FILE'"
			;;
		jammy)
			run_cmd "echo 'deb ${EDGE_PPA_URL} jammy multimedia main non-free kernels' | tee '$EDGE_SOURCES_FILE'"
			run_cmd "echo 'deb-src ${EDGE_PPA_URL} jammy multimedia main non-free kernels' | tee -a '$EDGE_SOURCES_FILE'"
			;;
		*)
			log_warning "Unsupported Ubuntu version: $ubuntu_codename, using noble configuration"
			run_cmd "echo 'deb ${EDGE_PPA_URL} noble multimedia main non-free kernels' | tee '$EDGE_SOURCES_FILE'"
			run_cmd "echo 'deb-src ${EDGE_PPA_URL} noble multimedia main non-free kernels' | tee -a '$EDGE_SOURCES_FILE'"
			;;
	esac

	log_info "Edge PPA repository added: $EDGE_SOURCES_FILE"
}

configure_edge_ppa() {
	local source_matches=false
	if repository_file_matches_url "$EDGE_SOURCES_FILE" "$EDGE_PPA_URL"; then
		source_matches=true
	fi

	if [[ "$source_matches" == true && -f "$EDGE_GPG_KEY_PATH" ]]; then
		log_info "Intel Edge Graphics PPA already configured, skipping setup"
		return 0
	fi

	if [[ -f "$EDGE_SOURCES_FILE" && "$source_matches" != true ]]; then
		log_warning "Edge PPA source URL drift detected; rewriting sources to match EDGE_PPA_URL"
	fi

	log_info "Updating package list..."
	run_cmd "apt update"

	local ubuntu_codename
	ubuntu_codename=$(detect_ubuntu_codename)

	setup_edge_repository "$ubuntu_codename"
	setup_edge_gpg_key

	log_info "Updating package list with new Edge PPA..."
	run_cmd "apt update"

	log_success "Intel Edge Graphics PPA configured successfully"
}

# =============================================================================

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

configure_ppa() {
	cleanup_conflicting_ppa "$PPA_SELECTOR"

	case "$PPA_SELECTOR" in
		edge)
			configure_edge_ppa
			;;
	esac
}

invoke_helper_command() {
	local command="${1:-}"
	shift || true

	case "$command" in
		check-root)
			check_root
			;;
		setup-selected-ppa)
			setup_selected_ppa "$@"
			;;
		update-package-cache)
			update_package_cache
			;;
		install-component-packages)
			install_component_packages "$@"
			;;
		prepare-component-install)
			prepare_component_install "$@"
			;;
		verify-component-packages)
			verify_component_packages "$@"
			;;
		verify-component-packages-by-groups)
			verify_component_packages_by_groups "$@"
			;;
		set-selected-ppa-priority)
			set_selected_ppa_priority_with_context "$@"
			;;
		get-component-context)
			get_component_context "$@"
			;;
		init-component-context)
			init_component_context "$@"
			;;
		*)
			die "Unsupported helper command: $command"
			;;
	esac
}

main() {
	parse_args "$@"

	log_info "${BOLD}Intel Graphics PPA Configuration${NC}"
	log_info "Copyright (c) 2026 Intel Corporation"
	log_info "Selected PPA: $PPA_SELECTOR"
	echo

	check_root
	configure_ppa

	log_success "${BOLD}PPA configuration completed for: $PPA_SELECTOR${NC}"
	echo
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	if [[ "${1:-}" == "--invoke" ]]; then
		shift
		invoke_helper_command "$@"
		exit 0
	fi

	main "$@"
fi
