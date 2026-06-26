#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Intel Edge Graphics Mutter DEB Setup Script
#
# This script:
# - Calls common-helper.sh with edge selector to set up the selected Intel PPA
# - Sets high priority (800) for Mutter components from the selected PPA
# - Installs Mutter binary packages using apt-get install
# - Prefers a specific Mutter version and falls back to latest from selected PPA
#
# Usage: sudo ./mutter.sh [edge]
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

# Preferred Mutter version for Noble package train
readonly MUTTER_VERSION="46.2-1.0.24.04.14-1ppa1~noble2"

# Mutter package names for priority and installation
readonly MUTTER_PACKAGES=(
	"gir1.2-mutter-14"
	"libmutter-14-0"
	"libmutter-14-dev"
	"libmutter-test-14"
	"mutter-14-tests"
	"mutter-common"
	"mutter"
)

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

main() {
	log_component_banner "Mutter Debian Setup"

	bash "$COMMON_PIN_HELPER" --invoke prepare-component-install "$PPA_SCRIPT" "$PPA_SELECTOR" "$PPA_NAME" "$PREFERENCES_FILE" "$PPA_PIN_ORIGIN" "$COMPONENT_PIN_PRIORITY" -- "${MUTTER_PACKAGES[@]}"
	bash "$COMMON_PIN_HELPER" --invoke verify-component-packages-by-groups "$PPA_NAME" "-" "-" "-" --group "$MUTTER_VERSION" -- "${MUTTER_PACKAGES[@]}"
	log_component_completion "Mutter Debian setup" "Mutter packages installed with priority $COMPONENT_PIN_PRIORITY from $PPA_NAME"
}

main "$@"
