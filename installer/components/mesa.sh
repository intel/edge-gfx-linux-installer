#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

# ============================================================================
# Mesa Installation Script for Intel SRIOV Toolkit
# Version: 1.0
# ============================================================================
#
# Description:
#   This script downloads, compiles, and installs Mesa 3D graphics library
#   from source with Intel SR-IOV optimizations and Vulkan support
#
# Usage:
#   ./mesa.sh
#
# ============================================================================

set -euo pipefail

# Error cleanup function
cleanup_on_error() {
    echo "Error occurred during Mesa installation."

    # Remove corrupted build directory to ensure fresh build on retry
    if [[ -d "$BUILD_DIR" ]]; then
        echo "  Removing corrupted build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
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
readonly MESA_DIR="$WORK_DIR/source/mesa"
readonly REPO_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
readonly MESA_VERSION="mesa-25.3.4"
readonly BUILD_DIR="$MESA_DIR/build"

# Build dependencies
readonly BUILD_DEPS=(
    "meson-1.7" "ninja-build" "build-essential" "pkg-config" "glslang-tools" "spirv-tools" "libdrm-dev"
    "libx11-dev" "libxxf86vm-dev" "libexpat1-dev" "libflatbuffers-dev"
    "libsensors-dev" "libxext-dev" "libva-dev" "libvdpau-dev" "libvulkan-dev"
    "x11proto-dev" "linux-libc-dev" "libx11-xcb-dev" "libxcb-dri2-0-dev"
    "libxcb-glx0-dev" "libxcb-dri3-dev" "libxcb-present-dev" "libxcb-randr0-dev"
    "libxcb-shm0-dev" "libxcb-sync-dev" "libxrandr-dev" "libxshmfence-dev"
    "libxtensor-dev" "libzstd-dev" "python3" "python3-mako" "python3-yaml"
    "python3-pycparser" "python3-setuptools" "flex" "bison" "libelf-dev"
    "libwayland-dev" "libwayland-egl-backend-dev" "libglvnd-dev" "llvm"
    "libclang-dev" "libclc-18-dev" "libclc-18" "wayland-protocols" "valgrind"
    "libllvmspirvlib-18-dev"
)

# Function to prompt user for recompilation
prompt_recompile() {
    echo "Mesa build directory found in $BUILD_DIR"
    echo "Do you want to recompile and reinstall Mesa? (y/N) [Default: n in 10 seconds]:"

    local response
    if read -t 10 -r response; then
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0  # Recompile
                ;;
            *)
                return 1  # Don't recompile
                ;;
        esac
    else
        printf "\nTimeout reached. Skipping recompilation. \033[0;33m[WARN]\033[0m\n"
        return 1  # Default to not recompile
    fi
}

install_dependencies() {
    echo "Installing Mesa build dependencies..."

    # Update package list first
    echo "  Updating package list..."
    sudo apt-get update -qq

    # Install all dependencies
    echo "  Installing required packages..."
    sudo apt-get install -y "${BUILD_DEPS[@]}"

    echo -e "  Dependencies installed successfully \033[0;32m[SUCCESS]\033[0m"
}

setup_source() {
    echo "Setting up Mesa source code..."

    echo "  Creating source directory..."
    mkdir -p "$(dirname "$MESA_DIR")"

    echo "  Cloning Mesa repository..."
    git clone "$REPO_URL" "$MESA_DIR"

    cd "$MESA_DIR"

    echo "  Checking out $MESA_VERSION..."
    git checkout -b dev "refs/tags/$MESA_VERSION"

    echo -e "  Source setup completed \033[0;32m[SUCCESS]\033[0m"
}

configure_build() {
    echo "Configuring Mesa build..."
    cd "$MESA_DIR"

    echo "  Setting up build directory..."
    mkdir -p "$BUILD_DIR"

    echo "  Running meson configuration..."
    meson setup "$BUILD_DIR" \
        --wrap-mode=nodownload \
        --buildtype=plain \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --libdir=lib/x86_64-linux-gnu \
        -Dpython.bytecompile=-1 \
        -Ddri-drivers-path=/usr/lib/x86_64-linux-gnu/dri \
        -Dplatforms=x11,wayland \
        -Dvulkan-drivers=intel,intel_hasvk,amd,swrast,virtio \
        -Dvulkan-layers=device-select,intel-nullhw,overlay \
        -Dglvnd=enabled \
        -Db_ndebug=true \
        -Dbuild-tests=true \
        -Dtools=drm-shim \
        -Dglx-direct=true \
        -Dgbm=enabled \
        -Dgallium-extra-hud=true \
        -Dlmsensors=enabled \
        -Dllvm=enabled \
        -Dgallium-rusticl=false \
        -Dgallium-va=enabled \
        -Dvideo-codecs=all \
        -Dgallium-drivers=softpipe,r300,r600,virgl,crocus,i915,iris,svga,radeonsi,zink,llvmpipe \
        -Dgles1=disabled \
        -Dgles2=enabled \
        -Dvalgrind=enabled \
        -Dteflon=false \
        -Dlegacy-wayland=bind-wayland-display

    echo -e "  Build configuration completed \033[0;32m[SUCCESS]\033[0m"
}

build_mesa() {
    echo "Building Mesa..."
    cd "$BUILD_DIR"

    echo "  Starting compilation (this may take a while)..."
    ninja

    echo -e "  Mesa compilation completed \033[0;32m[SUCCESS]\033[0m"
}

install_mesa() {
    echo "Installing Mesa..."
    cd "$BUILD_DIR"

    echo "  Installing to system..."
    sudo ninja install

    echo "  Running ldconfig to update library cache..."
    sudo ldconfig

    echo -e "  Mesa installation completed \033[0;32m[SUCCESS]\033[0m"
}

main() {
    echo "Starting Mesa installation process..."

    # Install dependencies first
    install_dependencies

    # Case 1: Build directory exists - ask user for recompile
    if [[ -d "$BUILD_DIR" ]]; then
        if prompt_recompile; then
            echo "Recompiling and reinstalling Mesa..."
            build_mesa
            install_mesa
            echo -e "Mesa recompilation and installation completed successfully! \033[0;32m[SUCCESS]\033[0m"
        else
            echo -e "Skipping Mesa recompilation. Exiting. \033[0;33m[WARN]\033[0m"
            exit 0
        fi

    # Case 2: Source exists but no build directory - configure and build
    elif [[ -d "$MESA_DIR" ]]; then
        echo "Mesa source found but no build directory. Starting build process..."
        configure_build
        build_mesa
        install_mesa
        echo -e "Mesa build and installation completed successfully! \033[0;32m[SUCCESS]\033[0m"

    # Case 3: No source available - clone, configure and build
    else
        echo "No Mesa source found. Cloning repository and starting build process..."
        setup_source
        configure_build
        build_mesa
        install_mesa
        echo -e "Mesa installation completed successfully! \033[0;32m[SUCCESS]\033[0m"
    fi

    # Disable error trap before normal cleanup
    trap - ERR
}

main "$@"
