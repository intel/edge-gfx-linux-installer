#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# ============================================================================
# SPICE and SPICE-gtk Installation Script for Intel SRIOV Toolkit
# Version: 1.0
# ============================================================================
#
# Description:
#   This script downloads and installs SPICE and SPICE-gtk packages from Intel's
#   Linux overlay repository. It handles the complete installation process
#
# Usage:
#   ./spice.sh
#
# ============================================================================

set -euo pipefail

# Error cleanup function
cleanup_on_error() {
    echo "Error occurred during installation."

    # Remove corrupted/incomplete download directory to ensure fresh download on retry
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "  Removing corrupted installation directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    exit 1
}

# Set up error trap
trap cleanup_on_error ERR

# Get script directory and set WORK_DIR to the installer directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [[ "$(basename "$SCRIPT_DIR")" == "components" ]]; then
    WORK_DIR="$(dirname "$SCRIPT_DIR")"
else
    WORK_DIR="$SCRIPT_DIR"
fi

# Use persistent installer/deb/spice directory
readonly INSTALL_DIR="$WORK_DIR/deb/qemu"
readonly SPICE_URL="https://download.01.org/intel-linux-overlay/ubuntu/pool/main/s/spice"
readonly SPICE_GTK_URL="https://download.01.org/intel-linux-overlay/ubuntu/pool/main/s/spice-gtk"
readonly SPICE_VERSION="0.15.2-1ppa1~noble7"
readonly SPICE_GTK_VERSION="0.42-1ppa1~noble3"

# SPICE packages to download
readonly SPICE_PACKAGES=(
    "libspice-server1_${SPICE_VERSION}_amd64.deb"
)

# SPICE-gtk packages to download
readonly SPICE_GTK_PACKAGES=(
    "libspice-client-glib-2.0-8_${SPICE_GTK_VERSION}_amd64.deb"
    "libspice-client-gtk-3.0-5_${SPICE_GTK_VERSION}_amd64.deb"
    "spice-client-glib-usb-acl-helper_${SPICE_GTK_VERSION}_amd64.deb"
    "spice-client-gtk_${SPICE_GTK_VERSION}_amd64.deb"
)

# Function to check if all required packages exist
check_existing_packages() {
    local missing_packages=()
    local all_packages=()

    # Combine all package arrays
    all_packages+=("${SPICE_PACKAGES[@]}")
    all_packages+=("${SPICE_GTK_PACKAGES[@]}")

    # Check each package
    for package in "${all_packages[@]}"; do
        if [[ ! -f "$INSTALL_DIR/$package" ]]; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0  # All packages exist
    else
        return 1  # Some packages missing
    fi
}

# Function to install packages with retry logic
install_packages_with_retry() {
    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        echo "Installing all packages... (Attempt $attempt of $max_attempts)"

        if sudo dpkg -i ./*.deb; then
            echo "SPICE and SPICE-gtk installation completed successfully."
            return 0
        else
            echo "Detected package dependency issues. Attempting automatic recovery..."
            if sudo apt-get install -f -y; then
                echo "Dependencies resolved. Retrying installation..."
                attempt=$((attempt + 1))
            else
                echo "Error: Failed to resolve dependencies"
                return 1
            fi
        fi
    done

    echo "Error: Failed to install packages after $max_attempts attempts"
    return 1
}

main() {
    # Case 1: Directory exists and all packages exist - just install
    if [[ -d "$INSTALL_DIR" ]] && check_existing_packages; then
        echo "All SPICE and SPICE-gtk packages found in $INSTALL_DIR"
        echo "Installing existing packages..."
        cd "$INSTALL_DIR"

        if install_packages_with_retry; then
            echo "SPICE and SPICE-gtk installation completed successfully using existing packages."
            return 0
        else
            echo "Failed to install existing packages. Will download fresh copies."
            # Remove corrupted packages and continue to fresh download
            rm -rf "$INSTALL_DIR"
        fi
    fi

    # Case 2: Directory exists but some packages missing - download missing ones
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "Some SPICE/SPICE-gtk packages missing in $INSTALL_DIR"
        echo "Downloading missing packages..."
        cd "$INSTALL_DIR"
    else
        # Case 3: No directory - fresh download
        echo "Setting up installation directory for fresh download..."
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    echo "Downloading SPICE packages..."
    for package in "${SPICE_PACKAGES[@]}"; do
        if [[ -f "$package" ]]; then
            echo "  $package already exists, skipping download"
        else
            echo "  Downloading $package"
            wget --no-check-certificate "$SPICE_URL/$package" || {
                echo "Error: Failed to download $package from $SPICE_URL"
                exit 1
            }
        fi
    done

    echo "Downloading SPICE-gtk packages..."
    for package in "${SPICE_GTK_PACKAGES[@]}"; do
        if [[ -f "$package" ]]; then
            echo "  $package already exists, skipping download"
        else
            echo "  Downloading $package"
            wget --no-check-certificate "$SPICE_GTK_URL/$package" || {
                echo "Error: Failed to download $package from $SPICE_GTK_URL"
                exit 1
            }
        fi
    done

    if install_packages_with_retry; then
        # Disable error trap before normal cleanup
        trap - ERR
        echo "Cleaning up..."
        cd "$WORK_DIR"

        echo "SPICE and SPICE-gtk installation completed successfully."
        echo "Downloaded packages preserved in: $INSTALL_DIR"
    else
        echo "Error: Failed to install packages"
        exit 1
    fi
}

main "$@"