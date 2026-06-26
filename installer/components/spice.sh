#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# =============================================================================
# Intel Edge Graphics SPICE Setup Script
#
# This script:
# - Calls common-helper.sh with edge selector to set up the selected Intel PPA
# - Sets high priority (800) for SPICE components from selected PPA
# - Installs SPICE packages using apt-get install
# - Verifies installed SPICE versions against preferred targets
#
# Usage: sudo ./spice.sh [edge]
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

# Preferred SPICE versions
readonly SPICE_VERSION="0.15.2-1ppa1~noble7"
readonly SPICE_GTK_VERSION="0.42-1ppa1~noble4"

# SPICE package names for installation
readonly SPICE_PACKAGES=(
	"libspice-server1"
	"libspice-server-dev"
)

readonly SPICE_GTK_PACKAGES=(
	"libspice-client-glib-2.0-8"
	"libspice-client-gtk-3.0-5"
	"spice-client-glib-usb-acl-helper"
	"spice-client-gtk"
)

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

main() {
	log_component_banner "SPICE Debian Setup"
	bash "$COMMON_PIN_HELPER" --invoke prepare-component-install "$PPA_SCRIPT" "$PPA_SELECTOR" "$PPA_NAME" "$PREFERENCES_FILE" "$PPA_PIN_ORIGIN" "$COMPONENT_PIN_PRIORITY" -- "${SPICE_PACKAGES[@]}" "${SPICE_GTK_PACKAGES[@]}"
	bash "$COMMON_PIN_HELPER" --invoke verify-component-packages-by-groups "$PPA_NAME" "-" "-" "-" --group "$SPICE_VERSION" -- "${SPICE_PACKAGES[@]}" --group "$SPICE_GTK_VERSION" -- "${SPICE_GTK_PACKAGES[@]}"
	log_component_completion "SPICE Debian setup" "SPICE components have been installed with priority $COMPONENT_PIN_PRIORITY from $PPA_NAME"
}

main "$@"
