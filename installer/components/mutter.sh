#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# ============================================================================
# Mutter Installation Script for Intel SRIOV Toolkit
# Version: 1.0
# ============================================================================
#
# Description:
#   This script downloads and installs Mutter ubuntu Launchpad packages and
#   its dependencies from Intel's OOT patchset
#
# Usage:
#   ./mutter.sh
#
# ============================================================================

set -euo pipefail

# Error cleanup function
cleanup_on_error() {
    echo "Error occurred during Mutter installation."

    # Remove corrupted build directory to ensure fresh build on retry
    if [[ -d "$MUTTER_DIR" ]]; then
        echo "  Removing corrupted source directory: $MUTTER_DIR"
        rm -rf "$MUTTER_DIR"
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

# Use persistent source directory
readonly MUTTER_DIR="$WORK_DIR/source/mutter"
readonly REPO_URL="https://git.launchpad.net/ubuntu/+source/mutter"
readonly TARGET_BRANCH="noble-updates"
readonly COMMIT_HASH="49f3015f81c81e2191b06ee0718eaaf5e5d15f7f"
readonly CHANGELOG_MSG="Add Intel SRIOV udev flag patch for GPU KMS disable functionality"

# Function to check if mutter packages are built
check_existing_packages() {
    local parent_dir
    parent_dir="$(dirname "$MUTTER_DIR")"
    if [[ -d "$parent_dir" ]] && ls "$parent_dir"/*.deb 1> /dev/null 2>&1; then
        return 0  # Packages exist
    else
        return 1  # No packages found
    fi
}

# Function to prompt user for rebuild
prompt_rebuild() {
    echo "Mutter packages found in $(dirname "$MUTTER_DIR")"

    # Show current Mutter version if available
    if command -v mutter >/dev/null 2>&1; then
        echo "Current Mutter version installed on system:"
        local mutter_info
        mutter_info=$(mutter --version 2>/dev/null || echo "  Unable to retrieve Mutter version info")
        echo "  $mutter_info"
        echo ""
    else
        echo "Note: Mutter not currently installed on the system"
        echo ""
    fi

    echo "Do you want to rebuild and reinstall Mutter? (y/N) [Default: n in 10 seconds]:"

    local response
    if read -t 10 -r response; then
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0  # Rebuild
                ;;
            *)
                return 1  # Don't rebuild
                ;;
        esac
    else
        printf "\nTimeout reached. Skipping rebuild. \033[0;33m[WARN]\033[0m\n"
        return 1  # Default to not rebuild
    fi
}

setup_source() {
    echo "Setting up Mutter source code..."

    echo "  Creating source directory..."
    mkdir -p "$(dirname "$MUTTER_DIR")"

    echo "  Cloning mutter repository..."
    git clone "$REPO_URL" "$MUTTER_DIR"
    cd "$MUTTER_DIR"

    echo "  Checking out $TARGET_BRANCH branch..."
    git checkout -b "$TARGET_BRANCH" "origin/ubuntu/$TARGET_BRANCH"

    echo "  Resetting to commit $COMMIT_HASH..."
    git reset --hard "$COMMIT_HASH"

    echo -e "  Source setup completed \033[0;32m[SUCCESS]\033[0m"
}

apply_patches() {
    echo "Applying Intel SRIOV patches..."
    cd "$MUTTER_DIR"

    local patch_dir="$WORK_DIR/components/mutter-OOT-patches"
    local patch_check_output=""

    if [[ ! -d "$patch_dir" ]]; then
        if [[ -d "$SCRIPT_DIR/mutter-OOT-patches" ]]; then
            patch_dir="$SCRIPT_DIR/mutter-OOT-patches"
        elif [[ -d "$WORK_DIR/installer/components/mutter-OOT-patches" ]]; then
            patch_dir="$WORK_DIR/installer/components/mutter-OOT-patches"
        else
            echo "  Error: Patch directory not found"
            echo "  Checked:"
            echo "    - $WORK_DIR/components/mutter-OOT-patches"
            echo "    - $SCRIPT_DIR/mutter-OOT-patches"
            echo "    - $WORK_DIR/installer/components/mutter-OOT-patches"
            return 1
        fi
    fi

    mapfile -t patch_files < <(find "$patch_dir" -name "*.patch" -type f | sort)

    if [[ ${#patch_files[@]} -eq 0 ]]; then
        echo "  No patch files found in $patch_dir"
        return 0
    fi

    echo "  Found ${#patch_files[@]} patch file(s) to apply..."

    for patch_file in "${patch_files[@]}"; do
        echo "  Applying $(basename "$patch_file")..."

        # Skip if patch is already applied
        if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            echo "    Patch already applied, skipping"
            continue
        fi

        patch_check_output=$(git apply --check "$patch_file" 2>&1 || true)
        if [[ -z "$patch_check_output" ]]; then
            git apply "$patch_file"
            echo "    Applied successfully with git apply"
            continue
        fi

        echo "    git apply --check failed:"
        echo "    $patch_check_output"

        if patch -p1 --dry-run < "$patch_file" >/dev/null 2>&1 && patch -p1 < "$patch_file"; then
            echo "    Applied successfully with patch command"
        else
            echo "    Error: Failed to apply $(basename "$patch_file")"
            echo "    Tip: inspect target file and compare hunk context near the failed lines"
            return 1
        fi
    done

    # Configure git user for commit
    git config --local user.name "ECG Developer"
    git config --local user.email "ecg.sse.pid.gmdc.mys.graphics@intel.com"

    git add -A
    git commit -m "Apply Intel SRIOV patches"
    echo -e "  All patches applied and committed to git \033[0;32m[SUCCESS]\033[0m"
}

update_changelog() {
    echo "Updating package changelog..."
    cd "$MUTTER_DIR"
    if ! command -v dch >/dev/null 2>&1; then
        echo "  Installing devscripts (provides dch)..."
        sudo apt-get update
        sudo apt-get install -y devscripts
    fi
    # Set environment variables to avoid dch warnings and prompts
    export DEBEMAIL="intel-sriov-toolkit@localhost"
    export EMAIL="intel-sriov-toolkit@localhost"
    # Use environment variables for automatic mode (no prompts)
    dch -D noble -i "$CHANGELOG_MSG"

    echo -e "  Changelog updated \033[0;32m[SUCCESS]\033[0m"
}

build_package() {
    echo "Building Mutter package..."
    cd "$MUTTER_DIR"

    if ! command -v mk-build-deps >/dev/null 2>&1 || ! command -v debuild >/dev/null 2>&1 || ! command -v equivs-build >/dev/null 2>&1; then
        echo "  Installing build tooling (devscripts, equivs)..."
        sudo apt-get update
        sudo apt-get install -y devscripts equivs
    fi

    echo "  Resolving meson package conflicts..."
    sudo apt-get remove -y meson-1.7 || true

    echo "  Installing build dependencies..."
    sudo mk-build-deps -i -s sudo -t "apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --allow-downgrades --allow-remove-essential --allow-change-held-packages -y" debian/control

    echo "  Building binary packages..."
    debuild -b -uc -us

    echo -e "  Package build completed \033[0;32m[SUCCESS]\033[0m"
}

install_packages() {
    echo "Installing built packages..."
    # debuild places .deb files in parent directory of source
    cd "$(dirname "$MUTTER_DIR")"

    if ! ls ./*.deb 1> /dev/null 2>&1; then
        echo "  No .deb files found in $(pwd)"
        echo "  Checking for .deb files in work directory..."
        cd "$WORK_DIR"
        if ! ls ./*.deb 1> /dev/null 2>&1; then
            echo "  Error: No .deb files found to install"
            return 1
        fi
    fi

    echo "  Getting list of installed mutter packages..."
    local installed_packages=()
    mapfile -t installed_packages < <(apt list --installed 2>/dev/null | grep mutter | cut -d'/' -f1)

    if [[ ${#installed_packages[@]} -eq 0 ]]; then
        echo "  No mutter packages currently installed"
        return 0
    fi

    echo "  Found ${#installed_packages[@]} installed mutter package(s): ${installed_packages[*]}"

    local debs_to_install=()
    for deb_file in ./*.deb; do
        local package_name
        package_name=$(basename "$deb_file" | cut -d'_' -f1)
        if [[ " ${installed_packages[*]} " =~ [[:space:]]${package_name}[[:space:]] ]]; then
            debs_to_install+=("$deb_file")
        fi
    done

    if [[ ${#debs_to_install[@]} -eq 0 ]]; then
        echo "  No matching .deb files found for installed packages"
        return 0
    fi

    # Copy packages to persistent deb/mutter directory
    local deb_dir="$WORK_DIR/deb/mutter"
    echo "  Copying ${#debs_to_install[@]} package(s) to $deb_dir..."
    mkdir -p "$deb_dir"
    cp "${debs_to_install[@]}" "$deb_dir/"
    echo -e "  Packages copied to persistent directory \033[0;32m[SUCCESS]\033[0m"

    echo "  Installing ${#debs_to_install[@]} matching package(s)..."
    sudo dpkg -i "${debs_to_install[@]}"

    echo -e "  Package installation completed \033[0;32m[SUCCESS]\033[0m"
}

# Function to check if deb packages exist and compare versions
check_deb_packages() {
    local deb_dir="$WORK_DIR/deb/mutter"
    if [[ ! -d "$deb_dir" ]] || ! ls "$deb_dir"/*.deb 1> /dev/null 2>&1; then
        return 1  # No packages found
    fi

    # Get list of installed mutter packages (same logic as install_packages)
    local installed_packages=()
    mapfile -t installed_packages < <(apt list --installed 2>/dev/null | grep mutter | cut -d'/' -f1)

    if [[ ${#installed_packages[@]} -eq 0 ]]; then
        return 1  # No mutter packages installed, so deb packages are not relevant
    fi

    # Check if deb packages match installed packages
    local matching_debs=()
    for deb_file in "$deb_dir"/*.deb; do
        local package_name
        package_name=$(basename "$deb_file" | cut -d'_' -f1)
        if [[ " ${installed_packages[*]} " =~ [[:space:]]${package_name}[[:space:]] ]]; then
            matching_debs+=("$deb_file")
        fi
    done

    if [[ ${#matching_debs[@]} -gt 0 ]]; then
        return 0  # Matching packages exist
    else
        return 1  # No matching packages found
    fi
}

# Function to prompt user for package reinstall
prompt_reinstall() {
    local deb_dir="$WORK_DIR/deb/mutter"
    echo "Mutter packages found in $deb_dir"

    # Check version differences
    local version_diff=false
    for deb_file in "$deb_dir"/*.deb; do
        local package_name
        package_name=$(basename "$deb_file" | cut -d'_' -f1)

        # Get installed version
        local installed_version
        installed_version=$(dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || echo "not-installed")

        # Get deb version
        local deb_version
        deb_version=$(dpkg-deb -f "$deb_file" Version)

        if [[ "$installed_version" != "$deb_version" ]]; then
            echo "  $package_name: installed=$installed_version, available=$deb_version"
            version_diff=true
        fi
    done

    if [[ "$version_diff" == "false" ]]; then
        echo "  All package versions match installed versions"
    fi

    echo ""
    echo "Do you want to reinstall Mutter packages? (y/N) [Default: n in 10 seconds]:"

    local response
    if read -t 10 -r response; then
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0  # Reinstall
                ;;
            *)
                return 1  # Don't reinstall
                ;;
        esac
    else
        printf "\nTimeout reached. Skipping reinstall. \033[0;33m[WARN]\033[0m\n"
        return 1  # Default to not reinstall
    fi
}

# Function to install packages from deb directory
install_deb_packages() {
    local deb_dir="$WORK_DIR/deb/mutter"
    echo "Installing packages from $deb_dir..."

    cd "$deb_dir"
    sudo dpkg -i ./*.deb || {
        echo "Detected package dependency issues. Attempting automatic recovery..."
        sudo apt-get install -f -y || {
            echo "Error: Failed to resolve dependencies"
            return 1
        }
        sudo dpkg -i ./*.deb
    }

    echo -e "Package reinstallation completed \033[0;32m[SUCCESS]\033[0m"
}

main() {
    echo "Starting Mutter installation process..."

    # Check if deb packages exist first
    if check_deb_packages; then
        if prompt_reinstall; then
            install_deb_packages
            echo -e "Mutter package reinstallation completed successfully! \033[0;32m[SUCCESS]\033[0m"
            return 0
        else
            echo -e "Skipping Mutter package reinstallation. Exiting. \033[0;33m[WARN]\033[0m"
            exit 0
        fi
    fi

    # Case 1: Packages exist - ask user for rebuild
    if [[ -d "$MUTTER_DIR" ]] && check_existing_packages; then
        if prompt_rebuild; then
            echo "Rebuilding and reinstalling Mutter..."
            cd "$MUTTER_DIR"
            build_package
            install_packages
            echo -e "Mutter rebuild and installation completed successfully! \033[0;32m[SUCCESS]\033[0m"
        else
            echo -e "Skipping Mutter rebuild. Exiting. \033[0;33m[WARN]\033[0m"
            exit 0
        fi
    # Case 2: Source exists but no packages - build packages
    elif [[ -d "$MUTTER_DIR" ]]; then
        echo "Mutter source found but no packages. Starting build process..."
        apply_patches
        update_changelog
        build_package
        install_packages
        echo -e "Mutter build and installation completed successfully! \033[0;32m[SUCCESS]\033[0m"
    # Case 3: No source available - clone, patch, and build
    else
        echo "No Mutter source found. Cloning repository and starting build process..."
        setup_source
        apply_patches
        update_changelog
        build_package
        install_packages
        echo -e "Mutter installation completed successfully! \033[0;32m[SUCCESS]\033[0m"
    fi

    # Disable error trap before cleanup
    trap - ERR
    echo "Source code and packages preserved in: $(dirname "$MUTTER_DIR")"
    echo "Debian packages available in: $WORK_DIR/deb/mutter"
}

main "$@"
