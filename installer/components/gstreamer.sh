#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# ============================================================================
# GStreamer Installation Script for Intel SRIOV Toolkit
# Version: 1.0
# ============================================================================
#
# Description:
#   This script downloads and installs GStreamer packages from Intel's
#   Linux overlay repository. It handles the complete installation process
#
# Usage:
#   ./gstreamer.sh
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

# Use persistent installer/deb/gstreamer directory
readonly INSTALL_DIR="$WORK_DIR/deb/gstreamer"
readonly BASE_URL="https://download.01.org/intel-linux-overlay/ubuntu/pool/multimedia/g"
readonly GSTREAMER_VERSION="1.26.5-1ppa1~noble2"
readonly GSTREAMER_BAD_VERSION="1.26.5-1ppa1~noble9"
readonly GSTREAMER_UGLY_VERSION="1.26.5-1ppa1~noble1"
readonly GSTREAMER_RTSP_VERSION="1.26.5-1ppa1~noble1"

# GStreamer core packages
readonly GSTREAMER_CORE_PACKAGES=(
    "gstreamer1.0/gir1.2-gstreamer-1.0_${GSTREAMER_VERSION}_amd64.deb"
    "gstreamer1.0/gstreamer1.0-tools_${GSTREAMER_VERSION}_amd64.deb"
    "gstreamer1.0/libgstreamer1.0-0_${GSTREAMER_VERSION}_amd64.deb"
    "gstreamer1.0/libgstreamer1.0-dev_${GSTREAMER_VERSION}_amd64.deb"
)

# GStreamer plugins base packages
readonly GSTREAMER_BASE_PACKAGES=(
    "gst-plugins-base1.0/gir1.2-gst-plugins-base-1.0_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/gstreamer1.0-alsa_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/gstreamer1.0-gl_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/gstreamer1.0-plugins-base_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/gstreamer1.0-plugins-base-apps_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/gstreamer1.0-x_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/libgstreamer-gl1.0-0_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/libgstreamer-plugins-base1.0-0_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-base1.0/libgstreamer-plugins-base1.0-dev_${GSTREAMER_VERSION}_amd64.deb"
)

# GStreamer plugins good packages
readonly GSTREAMER_GOOD_PACKAGES=(
    "gst-plugins-good1.0/gstreamer1.0-gtk3_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-good1.0/gstreamer1.0-plugins-good_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-good1.0/gstreamer1.0-pulseaudio_${GSTREAMER_VERSION}_amd64.deb"
    "gst-plugins-good1.0/gstreamer1.0-qt5_${GSTREAMER_VERSION}_amd64.deb"
)

# GStreamer plugins bad packages
readonly GSTREAMER_BAD_PACKAGES=(
    "gst-plugins-bad1.0/gir1.2-gst-plugins-bad-1.0_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/gstreamer1.0-opencv_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/gstreamer1.0-plugins-bad_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/gstreamer1.0-plugins-bad-apps_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/libgstreamer-opencv1.0-0_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/libgstreamer-plugins-bad1.0-0_${GSTREAMER_BAD_VERSION}_amd64.deb"
    "gst-plugins-bad1.0/libgstreamer-plugins-bad1.0-dev_${GSTREAMER_BAD_VERSION}_amd64.deb"
)

# GStreamer plugins ugly packages
readonly GSTREAMER_UGLY_PACKAGES=(
    "gst-plugins-ugly1.0/gstreamer1.0-plugins-ugly_${GSTREAMER_UGLY_VERSION}_amd64.deb"
)

# GStreamer RTSP server packages
readonly GSTREAMER_RTSP_PACKAGES=(
    "gst-rtsp-server1.0/gir1.2-gst-rtsp-server-1.0_${GSTREAMER_RTSP_VERSION}_amd64.deb"
    "gst-rtsp-server1.0/gstreamer1.0-rtsp_${GSTREAMER_RTSP_VERSION}_amd64.deb"
    "gst-rtsp-server1.0/libgstrtspserver-1.0-0_${GSTREAMER_RTSP_VERSION}_amd64.deb"
    "gst-rtsp-server1.0/libgstrtspserver-1.0-dev_${GSTREAMER_RTSP_VERSION}_amd64.deb"
)

# Function to check if all required packages exist
check_existing_packages() {
    local missing_packages=()
    local all_packages=()

    # Combine all package arrays
    all_packages+=("${GSTREAMER_CORE_PACKAGES[@]}")
    all_packages+=("${GSTREAMER_BASE_PACKAGES[@]}")
    all_packages+=("${GSTREAMER_GOOD_PACKAGES[@]}")
    all_packages+=("${GSTREAMER_BAD_PACKAGES[@]}")
    all_packages+=("${GSTREAMER_UGLY_PACKAGES[@]}")
    all_packages+=("${GSTREAMER_RTSP_PACKAGES[@]}")

    # Check each package
    for package in "${all_packages[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ ! -f "$INSTALL_DIR/$package_name" ]]; then
            missing_packages+=("$package_name")
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
            echo "GStreamer installation completed successfully."
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
        echo "All GStreamer packages found in $INSTALL_DIR"
        echo "Installing existing packages..."
        cd "$INSTALL_DIR"

        if install_packages_with_retry; then
            echo "GStreamer installation completed successfully using existing packages."
            return 0
        else
            echo "Failed to install existing packages. Will download fresh copies."
            # Remove corrupted packages and continue to fresh download
            rm -rf "$INSTALL_DIR"
        fi
    fi

    # Case 2: Directory exists but some packages missing - download missing ones
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "Some GStreamer packages missing in $INSTALL_DIR"
        echo "Downloading missing packages..."
        cd "$INSTALL_DIR"
    else
        # Case 3: No directory - fresh download
        echo "Setting up installation directory for fresh download..."
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
    echo "Downloading GStreamer core packages..."
    for package in "${GSTREAMER_CORE_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }
        fi
    done

    echo "Downloading GStreamer base packages..."
    for package in "${GSTREAMER_BASE_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }
        fi
    done

    echo "Downloading GStreamer good packages..."
    for package in "${GSTREAMER_GOOD_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }
        fi
    done

    echo "Downloading GStreamer bad packages..."
    for package in "${GSTREAMER_BAD_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }

        fi
    done

    echo "Downloading GStreamer ugly packages..."
    for package in "${GSTREAMER_UGLY_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }
        fi
    done

    echo "Downloading GStreamer RTSP server packages..."
    for package in "${GSTREAMER_RTSP_PACKAGES[@]}"; do
        local package_name
        package_name=$(basename "$package")
        if [[ -f "$package_name" ]]; then
            echo "  $package_name already exists, skipping download"
        else
            echo "  Downloading $package_name"
            wget --no-check-certificate "$BASE_URL/$package" || {
                echo "Error: Failed to download $package_name from $BASE_URL"
                exit 1
            }
        fi
    done

    echo "Installing all packages..."
    if install_packages_with_retry; then
        # Disable error trap before normal cleanup
        trap - ERR
        echo "Cleaning up..."
        cd "$WORK_DIR"

        echo "GStreamer installation completed successfully."
        echo "Downloaded packages preserved in: $INSTALL_DIR"
    else
        echo "Error: Failed to install packages"
        exit 1
    fi
}

main "$@"
