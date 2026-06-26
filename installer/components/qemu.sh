#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Intel Edge Graphics QEMU Setup Script
#
# This script:
# - Calls common-helper.sh with edge selector to set up the selected Intel PPA
# - Sets high priority (800) for QEMU components from the selected PPA
# - Calls spice.sh with the same selector for SPICE component installation
# - Updates and installs QEMU and related components
#
# Usage: sudo ./qemu.sh [edge]
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

# Preferred versions (from original qemu.sh)
readonly QEMU_VERSION="4:9.1.0+git20260114-ppa1-noble5"

# QEMU package names for priority and installation
readonly QEMU_PACKAGES=(
	"qemu-block-extra"
	"qemu-block-supplemental"
	"qemu-guest-agent"
	"qemu-system-arm"
	"qemu-system-common"
	"qemu-system-data"
	"qemu-system-gui"
	"qemu-system-mips"
	"qemu-system-misc"
	"qemu-system-modules-opengl"
	"qemu-system-modules-spice"
	"qemu-system-ppc"
	"qemu-system-s390x"
	"qemu-system-sparc"
	"qemu-system-x86-xen"
	"qemu-system-x86"
	"qemu-system-xen"
	"qemu-system"
	"qemu-user-static"
	"qemu-user"
	"qemu-utils"
)

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

main() {
	log_component_banner "QEMU Setup"

	bash "$SCRIPT_DIR/spice.sh" "$PPA_SELECTOR"
	bash "$COMMON_PIN_HELPER" --invoke prepare-component-install "$PPA_SCRIPT" "$PPA_SELECTOR" "$PPA_NAME" "$PREFERENCES_FILE" "$PPA_PIN_ORIGIN" "$COMPONENT_PIN_PRIORITY" -- "${QEMU_PACKAGES[@]}"
	bash "$COMMON_PIN_HELPER" --invoke verify-component-packages-by-groups "$PPA_NAME" "-" "-" "-" --group "$QEMU_VERSION" -- "${QEMU_PACKAGES[@]}"
	log_component_completion "QEMU Debian setup" "QEMU and SPICE components have been installed with priority $COMPONENT_PIN_PRIORITY from $PPA_NAME"
}

# Execute main function
main "$@"
