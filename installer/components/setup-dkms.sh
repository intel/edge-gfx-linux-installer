#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# DKMS Setup Script
#
# This script:
# - Initializes/updates the sriov-dkms git submodule
# - Verifies sriov-dkms/scripts content exists
# - Derives the DKMS version from edge-kernel.sh kernel train
# - Runs dkms build for edge-gfx-dkms inside sriov-dkms directory
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON_HELPER="$SCRIPT_DIR/common-helper.sh"
EDGE_KERNEL_SCRIPT="$SCRIPT_DIR/edge-kernel.sh"
SRIOV_DKMS_DIR="$REPO_ROOT/sriov-dkms"
SRIOV_DKMS_SCRIPTS_DIR="$SRIOV_DKMS_DIR/scripts"

if [[ ! -f "$COMMON_HELPER" ]]; then
	echo -e "\033[0;31m[ERROR]\033[0m Common helper not found: $COMMON_HELPER" >&2
	exit 1
fi

# Reuse shared logging and helpers from common-helper.
eval "$(bash "$COMMON_HELPER" --invoke init-component-context "$COMMON_HELPER" "$@")"

extract_kernel_train() {
	local apt_package

	apt_package=$(awk '
		/^readonly[[:space:]]+EDGE_KERNEL_APT_PACKAGES=\(/ {in_block=1; next}
		in_block && /^\)/ {in_block=0}
		in_block && $0 ~ /^[[:space:]]*"linux-(image|headers)-/ {
			line=$0
			sub(/^[[:space:]]*"linux-(image|headers)-/, "", line)
			sub(/".*/, "", line)
			print line
			exit
		}
	' "$EDGE_KERNEL_SCRIPT")

	if [[ -z "$apt_package" ]]; then
		die "Unable to determine kernel train from EDGE_KERNEL_APT_PACKAGES in $EDGE_KERNEL_SCRIPT"
	fi

	echo "$apt_package"
}


update_sriov_submodule() {
	log_step "Initializing/updating sriov-dkms submodule"
	run_cmd "git -C '$REPO_ROOT' submodule update --init --recursive sriov-dkms"

	if [[ ! -d "$SRIOV_DKMS_DIR" ]]; then
		die "sriov-dkms directory not found after submodule update: $SRIOV_DKMS_DIR"
	fi

	if [[ ! -d "$SRIOV_DKMS_SCRIPTS_DIR" ]]; then
		die "sriov-dkms scripts directory not found: $SRIOV_DKMS_SCRIPTS_DIR"
	fi

	if [[ ! -f "$SRIOV_DKMS_SCRIPTS_DIR/dkms-pre-build.sh" || ! -f "$SRIOV_DKMS_SCRIPTS_DIR/dkms-post-install.sh" ]]; then
		die "Expected DKMS helper scripts are missing in $SRIOV_DKMS_SCRIPTS_DIR"
	fi

	log_success "sriov-dkms submodule is available with scripts"
}

ensure_dkms_installed() {
	if command -v dkms >/dev/null 2>&1; then
		return 0
	fi

	log_warning "dkms command not found; installing dkms package"
	if [[ $EUID -eq 0 ]]; then
		run_cmd "apt-get update"
		run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y dkms"
	else
		run_cmd "sudo apt-get update"
		run_cmd "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y dkms"
	fi

	if ! command -v dkms >/dev/null 2>&1; then
		die "dkms command not found after installation attempt"
	fi
}

build_dkms_module() {
	local module_version="$1"
	local target_kernel_release="$2"
	local module_name="edge-gfx-dkms"
	local i915_mod_path
	local expected_mod_path="/lib/modules/${target_kernel_release}/updates/dkms/i915.ko"

	log_step "Running DKMS build for module ${module_name}, version ${module_version}, kernel ${target_kernel_release}"

	ensure_dkms_installed

	pushd "$SRIOV_DKMS_DIR" >/dev/null
	if [[ $EUID -eq 0 ]]; then
		if dkms status -m "$module_name" -v "$module_version" >/dev/null 2>&1; then
			run_cmd "dkms remove -m '$module_name' -v '$module_version' --all || true"
		fi
		run_cmd "dkms add '$SRIOV_DKMS_DIR'"
		run_cmd "dkms build -m '$module_name' -v '$module_version' -k '$target_kernel_release'"
		run_cmd "dkms install -m '$module_name' -v '$module_version' -k '$target_kernel_release'"
		i915_mod_path="$(modinfo -k "$target_kernel_release" -F filename i915)"
	else
		if sudo dkms status -m "$module_name" -v "$module_version" >/dev/null 2>&1; then
			run_cmd "sudo dkms remove -m '$module_name' -v '$module_version' --all || true"
		fi
		run_cmd "sudo dkms add '$SRIOV_DKMS_DIR'"
		run_cmd "sudo dkms build -m '$module_name' -v '$module_version' -k '$target_kernel_release'"
		run_cmd "sudo dkms install -m '$module_name' -v '$module_version' -k '$target_kernel_release'"
		i915_mod_path="$(sudo modinfo -k "$target_kernel_release" -F filename i915)"
	fi
	popd >/dev/null

	if [[ "$i915_mod_path" != "$expected_mod_path" ]]; then
		die "i915 module path verification failed. Expected: $expected_mod_path, Got: $i915_mod_path"
	fi

	log_success "DKMS build completed for ${module_name} version ${module_version} on kernel ${target_kernel_release}"
	log_success "DKMS install completed and verified: $i915_mod_path"
}

main() {
	if [[ ! -f "$EDGE_KERNEL_SCRIPT" ]]; then
		die "edge-kernel script not found: $EDGE_KERNEL_SCRIPT"
	fi

	log_component_banner "DKMS Setup"
	update_sriov_submodule

	local kernel_train
	local module_version
	local target_kernel_release
	kernel_train=$(extract_kernel_train)
	module_version=$(extract_module_version)
	target_kernel_release=$(extract_target_kernel_release "$kernel_train")
	log_info "Detected EDGE kernel train from edge-kernel.sh: $kernel_train"

	build_dkms_module "$module_version" "$target_kernel_release"
	log_component_completion "DKMS setup" "DKMS build completed for edge-gfx-dkms"
}

extract_module_version() {
	local module_version

	module_version=$(awk -F'"' '/^PACKAGE_VERSION=/{print $2; exit}' "$SRIOV_DKMS_DIR/dkms.conf")
	if [[ -z "$module_version" ]]; then
		die "Unable to determine PACKAGE_VERSION from $SRIOV_DKMS_DIR/dkms.conf"
	fi

	echo "$module_version"
}

extract_target_kernel_release() {
	local kernel_train="$1"
	local target_kernel_release

	target_kernel_release=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name "*${kernel_train}*" -printf '%f\n' | sort -V | tail -n1)
	if [[ -z "$target_kernel_release" ]]; then
		die "Unable to find installed kernel release matching train '$kernel_train' under /lib/modules"
	fi

	echo "$target_kernel_release"
}
main "$@"