#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Intel Corporation
# All rights reserved.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
COMMON_HELPER="$SCRIPT_DIR/common-helper.sh"

PROXY_URL=""
PACKAGE_SOURCE="edge"
PACKAGE_SOURCE_EXPLICIT=false
SKIP_PPA=false

# Verification of intel Edge Components
readonly LINUX_FIRMWARE_VER="20240318.git3b128b60-0.2.27-1ppa1-noble1"
readonly LINUX_FIRMWARE_PACKAGES=(
	"linux-firmware"
)

readonly WAYLAND_VER="1.23.0-1ppa1~noble1"
readonly WAYLAND_PACKAGES=(
	"libwayland-bin"
	"libwayland-client0"
	"libwayland-cursor0"
	"libwayland-dev"
	"libwayland-server0"
)

readonly WESTON_VER="10.0.0+git20250321-1ppa1~noble6"
readonly WESTON_PACKAGES=(
	"weston"
)

readonly GMMLIB_VER="22.9.0-1ppa1~noble1"
readonly GMMLIB_PACKAGES=(
	"libigdgmm12"
	"libigdgmm-dev"
)
readonly LIBVA_VER="2.23.0-1ppa1~noble1"
readonly LIBVA_PACKAGES=(
	"libva-dev"
	"libva-drm2"
	"libva-glx2"
	"libva-wayland2"
	"libva-x11-2"
	"libva2"
	"va-driver-all"
)

readonly LIBVA_UTILS_VER="2.23.0-1ppa1~noble1"
readonly LIBVA_UTILS_PACKAGES=(
	"vainfo"
)

readonly MEDIA_DRIVER_NON_FREE_VER="25.4.6-1ppa1~noble2"
readonly MEDIA_DRIVER_NON_FREE_PACKAGES=(
	"intel-media-va-driver-non-free"
)

readonly LIBVPL_VER="1:2.16.0-1ppa1~noble1"
readonly LIBVPL_PACKAGES=(
	"libvpl-dev"
	"libvpl2"
	"onevpl-tools"
)

readonly LIBVPL_TOOLS_VER="2:1.5.0~1ppa1-noble1"
readonly LIBVPL_TOOL_PACKAGES=(
	"libvpl-tools"
)

readonly LIBMFX_VER="25.4.6-1ppa1~noble2"
readonly LIBMFX_PACKAGES=(
	"libmfx-gen-dev"
	"libmfx-gen1.2"
)

readonly MESA_VER="25.3.4-1ppa1~noble1"
readonly MESA_PACKAGES=(
	"libegl-mesa0"
	"libegl1-mesa-dev"
	"libgbm-dev"
	"libgbm1"
	"libgl1-mesa-dev"
	"libgl1-mesa-dri"
	"libgles2-mesa-dev"
	"mesa-common-dev"
	"libglx-mesa0"
	"mesa-drm-shim"
	"mesa-libgallium"
	"mesa-opencl-icd"
	"mesa-vulkan-drivers"
)

readonly GSTREAMER_VER="1.26.10-1ppa1~noble1"
readonly GSTREAMER_PACKAGES=(
	"gir1.2-gstreamer-1.0"
	"gstreamer1.0-tools"
	"libgstreamer1.0-0"
	"libgstreamer1.0-dev"
)

readonly GSTREAMER_BASE_VER="1.26.10-1ppa1~noble1"
readonly GSTREAMER_BASE_PACKAGES=(
	"gir1.2-gst-plugins-base-1.0"
	"gstreamer1.0-alsa"
	"gstreamer1.0-gl"
	"gstreamer1.0-plugins-base-apps"
	"gstreamer1.0-plugins-base"
	"gstreamer1.0-x"
	"libgstreamer-gl1.0-0"
	"libgstreamer-plugins-base1.0-0"
	"libgstreamer-plugins-base1.0-dev"
)

readonly GSTREAMER_BAD_VER="1.26.10-1ppa1~noble3"
readonly GSTREAMER_BAD_PACKAGES=(
	"gir1.2-gst-plugins-bad-1.0"
	"gstreamer1.0-opencv"
	"gstreamer1.0-plugins-bad-apps"
	"gstreamer1.0-plugins-bad"
	"libgstreamer-opencv1.0-0"
	"libgstreamer-plugins-bad1.0-0"
	"libgstreamer-plugins-bad1.0-dev"
)

readonly GSTREAMER_GOOD_VER="1.26.10-1ppa1~noble1"
readonly GSTREAMER_GOOD_PACKAGES=(
	"gstreamer1.0-gtk3"
	"gstreamer1.0-plugins-good"
	"gstreamer1.0-pulseaudio"
	"gstreamer1.0-qt5"
	"gstreamer1.0-qt6"
)

readonly GSTREAMER_UGLY_VER="1.26.10-1ppa1~noble1"
readonly GSTREAMER_UGLY_PACKAGES=(
	"gstreamer1.0-plugins-ugly"
)

readonly GSTREAMER_RTSP_VER="1.26.5-1ppa1~noble2"
readonly GSTREAMER_RTSP_PACKAGES=(
	"gir1.2-gst-rtsp-server-1.0"
	"gstreamer1.0-rtsp"
	"libgstrtspserver-1.0-0"
	"libgstrtspserver-1.0-dev"
)

readonly FFMPEG_VER="7:8.0.0-1ppa1~noble1"
readonly FFMPEG_LIB_VER="7:8.0.0-1ppa1~noble1"
readonly FFMPEG_PACKAGES=(
	"ffmpeg"
	"libavcodec-dev"
	"libavcodec-extra62"
	"libavcodec-extra"
	"libavdevice-dev"
	"libavdevice62"
	"libavfilter-dev"
	"libavfilter-extra11"
	"libavfilter-extra"
	"libavformat-dev"
	"libavformat-extra62"
	"libavformat-extra"
	"libavutil-dev"
	"libavutil60"
	"libswresample-dev"
	"libswresample6"
	"libswscale-dev"
	"libswscale9"
)

readonly FFMPEG_LIBRARY_PACKAGES=(
	"libavcodec-extra62"
	"libavdevice62"
	"libavfilter-extra11"
	"libavformat-extra62"
	"libavutil60"
	"libswresample6"
	"libswscale9"
)

readonly EDGE_KERNEL_RELEASE_PATTERN="*6.18-intel*"

show_usage() {
	cat <<EOF
Usage: sudo $0 [--proxy URL] [--edge] [--skip-PPA]

Options:
  --proxy URL   Configure proxy for current session and persist in /etc/environment
  --edge        Use Intel Edge package source (default)
  --skip-PPA    Skip PPA setup and install directly
  -h, --help    Show this help message

Notes:
	--skip-PPA can be used with --edge.
EOF
}

parse_baremetal_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--proxy)
				if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
					PROXY_URL="$2"
					shift 2
				else
					echo "[ERROR] --proxy requires a URL argument" >&2
					show_usage
					exit 1
				fi
				;;
			--edge)
				if [[ "$PACKAGE_SOURCE_EXPLICIT" == true && "$PACKAGE_SOURCE" != "edge" ]]; then
					echo "[ERROR] --edge and --internal cannot be used together" >&2
					exit 1
				fi
				PACKAGE_SOURCE="edge"
				PACKAGE_SOURCE_EXPLICIT=true
				shift
				;;
			--skip-PPA)
				SKIP_PPA=true
				shift
				;;
			-h|--help)
				show_usage
				exit 0
				;;
			*)
				echo "[ERROR] Unknown option: $1" >&2
				show_usage
				exit 1
				;;
		esac
	done

}

configure_proxy() {
	if [[ -z "$PROXY_URL" ]]; then
		return 0
	fi

	export http_proxy="$PROXY_URL"
	export https_proxy="$PROXY_URL"
	export HTTP_PROXY="$PROXY_URL"
	export HTTPS_PROXY="$PROXY_URL"
	log_info "Exported proxy to current session: $PROXY_URL"

	log_info "Persisting proxy to /etc/environment..."
	if ! grep -q "^http_proxy=" /etc/environment; then
		echo "http_proxy=$PROXY_URL" | tee -a /etc/environment > /dev/null
	else
		sed -i "s|^http_proxy=.*|http_proxy=$PROXY_URL|" /etc/environment
	fi

	if ! grep -q "^https_proxy=" /etc/environment; then
		echo "https_proxy=$PROXY_URL" | tee -a /etc/environment > /dev/null
	else
		sed -i "s|^https_proxy=.*|https_proxy=$PROXY_URL|" /etc/environment
	fi

	log_success "Proxy persisted to /etc/environment for system-wide use"
}

setup_selected_package_source() {
	ppa_configure_component_context "$PACKAGE_SOURCE" "$COMMON_HELPER"
	setup_selected_ppa "$COMMON_HELPER" "$PACKAGE_SOURCE" "$PPA_NAME"
}

install_package_group() {
	local group_name="$1"
	local version="$2"
	shift 2

	if [[ $# -eq 0 ]]; then
		log_error "No packages defined for group: $group_name"
		exit 1
	fi

	local package_name
	local resolved_version
	local install_version
	local -a install_targets=()

	for package_name in "$@"; do
		resolved_version=$(apt-cache madison "$package_name" 2>/dev/null | awk -F'|' -v expected_version="$version" '
			{
				ver=$2
				gsub(/^[ \t]+|[ \t]+$/, "", ver)
				if (ver == expected_version) {
					print ver
					exit
				}
			}
		') || true

		if [[ -z "$resolved_version" ]]; then
			install_version=$(resolve_package_version_from_origin "$package_name" "$PPA_PIN_ORIGIN")
			if [[ -z "$install_version" ]]; then
				log_error "Required version not found for $package_name in group $group_name: $version"
				log_error "No fallback version found for $package_name from PPA origin: $PPA_PIN_ORIGIN"
				exit 1
			fi

			log_warning "Exact version $version not found for $package_name in $group_name; using latest $PPA_NAME version: $install_version"
		else
			install_version="$resolved_version"
		fi

		install_targets+=("${package_name}=${install_version}")
	done

	log_step "Installing $group_name packages"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "${install_targets[@]}"
	log_success "Installed $group_name packages"
}

install_baremetal_packages() {
	apt install -y libdrm-dev libdrm2
	install_package_group "GMMLib" "$GMMLIB_VER" "${GMMLIB_PACKAGES[@]}"
	install_package_group "LibVA" "$LIBVA_VER" "${LIBVA_PACKAGES[@]}"
	install_package_group "LibVA Utils" "$LIBVA_UTILS_VER" "${LIBVA_UTILS_PACKAGES[@]}"
	install_package_group "Mesa" "$MESA_VER" "${MESA_PACKAGES[@]}"
	install_package_group "Media Driver Non-Free" "$MEDIA_DRIVER_NON_FREE_VER" "${MEDIA_DRIVER_NON_FREE_PACKAGES[@]}"
	install_package_group "Wayland" "$WAYLAND_VER" "${WAYLAND_PACKAGES[@]}"
	install_package_group "Weston" "$WESTON_VER" "${WESTON_PACKAGES[@]}"
	install_package_group "LibVPL" "$LIBVPL_VER" "${LIBVPL_PACKAGES[@]}"
	install_package_group "LibVPL Tools" "$LIBVPL_TOOLS_VER" "${LIBVPL_TOOL_PACKAGES[@]}"
	install_package_group "LibMFX" "$LIBMFX_VER" "${LIBMFX_PACKAGES[@]}"
	install_package_group "GStreamer" "$GSTREAMER_VER" "${GSTREAMER_PACKAGES[@]}"
	install_package_group "GStreamer Base" "$GSTREAMER_BASE_VER" "${GSTREAMER_BASE_PACKAGES[@]}"
	install_package_group "GStreamer Bad" "$GSTREAMER_BAD_VER" "${GSTREAMER_BAD_PACKAGES[@]}"
	install_package_group "GStreamer Good" "$GSTREAMER_GOOD_VER" "${GSTREAMER_GOOD_PACKAGES[@]}"
	install_package_group "GStreamer Ugly" "$GSTREAMER_UGLY_VER" "${GSTREAMER_UGLY_PACKAGES[@]}"
	install_package_group "GStreamer RTSP" "$GSTREAMER_RTSP_VER" "${GSTREAMER_RTSP_PACKAGES[@]}"
	install_package_group "FFmpeg" "$FFMPEG_VER" "${FFMPEG_PACKAGES[@]}"
	install_package_group "FFmpeg Libraries" "$FFMPEG_LIB_VER" "${FFMPEG_LIBRARY_PACKAGES[@]}"
	install_package_group "Linux Firmware" "$LINUX_FIRMWARE_VER" "${LINUX_FIRMWARE_PACKAGES[@]}"
}

fix_mesa_profile_script() {
	local profile_script="/etc/profile.d/mesa_driver.sh"

	if [[ ! -f "$profile_script" ]]; then
		log_info "mesa_driver.sh not found in /etc/profile.d, skipping removal"
		return 0
	fi

	rm -f "$profile_script"
	log_success "Removed $profile_script"
}

verify_baremetal_packages() {
	bash "$COMMON_HELPER" --invoke verify-component-packages-by-groups "$PPA_NAME" "-" "-" "-" \
		--group "$WAYLAND_VER" -- "${WAYLAND_PACKAGES[@]}" \
		--group "$WESTON_VER" -- "${WESTON_PACKAGES[@]}" \
		--group "$GMMLIB_VER" -- "${GMMLIB_PACKAGES[@]}" \
		--group "$LIBVA_VER" -- "${LIBVA_PACKAGES[@]}" \
		--group "$LIBVA_UTILS_VER" -- "${LIBVA_UTILS_PACKAGES[@]}" \
		--group "$MEDIA_DRIVER_NON_FREE_VER" -- "${MEDIA_DRIVER_NON_FREE_PACKAGES[@]}" \
		--group "$LIBVPL_VER" -- "${LIBVPL_PACKAGES[@]}" \
		--group "$LIBVPL_TOOLS_VER" -- "${LIBVPL_TOOL_PACKAGES[@]}" \
		--group "$LIBMFX_VER" -- "${LIBMFX_PACKAGES[@]}" \
		--group "$MESA_VER" -- "${MESA_PACKAGES[@]}" \
		--group "$GSTREAMER_VER" -- "${GSTREAMER_PACKAGES[@]}" \
		--group "$GSTREAMER_BASE_VER" -- "${GSTREAMER_BASE_PACKAGES[@]}" \
		--group "$GSTREAMER_BAD_VER" -- "${GSTREAMER_BAD_PACKAGES[@]}" \
		--group "$GSTREAMER_GOOD_VER" -- "${GSTREAMER_GOOD_PACKAGES[@]}" \
		--group "$GSTREAMER_UGLY_VER" -- "${GSTREAMER_UGLY_PACKAGES[@]}" \
		--group "$GSTREAMER_RTSP_VER" -- "${GSTREAMER_RTSP_PACKAGES[@]}" \
		--group "$FFMPEG_VER" -- "${FFMPEG_PACKAGES[@]}" \
		--group "$FFMPEG_LIB_VER" -- "${FFMPEG_LIBRARY_PACKAGES[@]}" \
		--group "$LINUX_FIRMWARE_VER" -- "${LINUX_FIRMWARE_PACKAGES[@]}"
}

overwrite_bmg_gfx_firmware() {
	local firmware_dir="/lib/firmware/xe"
	local firmware_ref="20260519"
	local firmware_list_url="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/xe?h=${firmware_ref}"
	local firmware_file_base_url="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/xe"
	local list_file
	local fw
	local fw_url
	local -a firmware_files=()

	log_info "Fetching BMG firmware manifest from kernel.org (${firmware_ref})"
	list_file=$(mktemp)
	run_cmd "wget -qO '$list_file' '$firmware_list_url'"

	while IFS= read -r fw; do
		firmware_files+=("$fw")
	done < <(grep -oE '(bmg_guc[^"&?<>[:space:]]+|bmg_huc[^"&?<>[:space:]]+|fan_control[^"&?<>[:space:]]+)' "$list_file" | sed 's#.*/##' | sort -u)

	rm -f "$list_file"

	if [[ ${#firmware_files[@]} -eq 0 ]]; then
		die "No BMG firmware files found at $firmware_list_url"
	fi

	log_info "Installing ${#firmware_files[@]} BMG firmware file(s) to $firmware_dir"
	run_cmd "mkdir -p '$firmware_dir'"

	for fw in "${firmware_files[@]}"; do
		fw_url="${firmware_file_base_url}/${fw}?h=${firmware_ref}"
		run_cmd "wget -qO '$firmware_dir/$fw' '$fw_url'"
	done

	log_success "BMG firmware files installed to $firmware_dir"
}

update_edge_kernel_initramfs() {
	log_info "Updating initramfs for installed edge-kernel releases (${EDGE_KERNEL_RELEASE_PATTERN})"
	local -a edge_kernel_releases=()
	local kernel_release

	while IFS= read -r kernel_release; do
		edge_kernel_releases+=("$kernel_release")
	done < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name "$EDGE_KERNEL_RELEASE_PATTERN" -printf '%f\n' | sort -u)

	if [[ ${#edge_kernel_releases[@]} -eq 0 ]]; then
		log_warning "No installed edge-kernel releases matched ${EDGE_KERNEL_RELEASE_PATTERN}; skipping initramfs update"
		return 0
	fi

	for kernel_release in "${edge_kernel_releases[@]}"; do
		run_cmd "update-initramfs -u -k '$kernel_release'"
	done

	log_success "Initramfs updated for installed edge-kernel releases"
}

main() {
	if [[ ! -f "$COMMON_HELPER" ]]; then
		echo "[ERROR] Common helper not found: $COMMON_HELPER" >&2
		exit 1
	fi

	# shellcheck source=installer/components/common-helper.sh
	source "$COMMON_HELPER"

	parse_baremetal_args "$@"
	ppa_configure_component_context "$PACKAGE_SOURCE" "$COMMON_HELPER"
	bash "$COMMON_HELPER" --invoke check-root

	log_component_banner "Baremetal Setup"
	configure_proxy
	local completion_message

	if [[ "$SKIP_PPA" == true ]]; then
		log_info "--skip-PPA selected, skipping PPA setup"
		completion_message="Installed baremetal packages without PPA setup"
	else
		setup_selected_package_source
		completion_message="Installed baremetal packages using $PPA_NAME"
	fi

	bash "$COMMON_HELPER" --invoke update-package-cache
	install_baremetal_packages
	fix_mesa_profile_script
	overwrite_bmg_gfx_firmware
	update_edge_kernel_initramfs
	verify_baremetal_packages
	log_component_completion "Baremetal setup" "$completion_message"
}

main "$@"
