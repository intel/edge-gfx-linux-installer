#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Intel Edge Graphics Kernel DEB Setup Script
#
# This script:
# - Calls common-helper.sh with edge selector to set up the selected Intel PPA
# - Sets high priority (800) for Intel kernel components from selected PPA
# - Installs linux-intel-6.18 kernel packages using apt-get install
# - Verifies installed kernel package versions and running kernel
#
# Usage: sudo ./edge-kernel.sh [edge]
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION SECTION
# =============================================================================

# Get script directory for locating sibling scripts
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
COMMON_PIN_HELPER="$SCRIPT_DIR/common-helper.sh"

# Component runtime context is provided by common-helper.
if [[ ! -f "$COMMON_PIN_HELPER" ]]; then
	echo -e "\033[0;31m[ERROR]\033[0m Common helper not found: $COMMON_PIN_HELPER" >&2
	exit 1
fi

eval "$(bash "$COMMON_PIN_HELPER" --invoke init-component-context "$COMMON_PIN_HELPER" "$@")"

# Target Intel kernel train.
readonly EDGE_KERNEL_VERSION="260427t075939z-r2"

# Candidate package names for apt-based installation. Some repos publish
# meta-package names while others publish direct image/header names.
readonly EDGE_KERNEL_APT_PACKAGES=(
	"linux-image-6.18-intel"
	"linux-headers-6.18-intel"
)

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

main() {
	log_component_banner "Intel Kernel Debian Setup"

	if ! bash "$COMMON_PIN_HELPER" --invoke prepare-component-install "$PPA_SCRIPT" "$PPA_SELECTOR" "$PPA_NAME" "$PREFERENCES_FILE" "$PPA_PIN_ORIGIN" "$COMPONENT_PIN_PRIORITY" -- "${EDGE_KERNEL_APT_PACKAGES[@]}"; then
		die "Intel kernel 6.18 packages are not available via apt for selector: $PPA_SELECTOR"
	fi

	log_info "Intel kernel 6.18 installed via apt metadata"

	bash "$COMMON_PIN_HELPER" --invoke verify-component-packages-by-groups "$PPA_NAME" "-" "-" "-" --group "$EDGE_KERNEL_VERSION" -- "${EDGE_KERNEL_APT_PACKAGES[@]}"
	log_component_completion "Intel Kernel Debian setup" "Intel kernel train ${EDGE_KERNEL_VERSION} installed with priority $COMPONENT_PIN_PRIORITY from $PPA_NAME"
}

main "$@"
