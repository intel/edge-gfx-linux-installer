# Edge Graphics Linux Installer 

## Introduction
The Edge Graphics Linux installer includes all necessary graphics software components for 
- Intel(R) Arc(TM) Discrete GPUs on Intel (R) Xeon Server Platform

The installer includes quick setup scripts to install the Intel Graphics PPA and compute, media, and tools packages, with optional virtualization packages.

## License
The Edge Graphics Linux installer is distributed under the MIT [license](license.md).

## Supported Platforms
- [Intel(R) Xeon Emerald Rapids](https://www.intel.com/content/www/us/en/ark/products/codename/130707/products-formerly-emerald-rapids.html) with [Intel(R) Arc(TM) Pro B60 Discrete GPU](https://www.intel.com/content/www/us/en/products/sku/243916/intel-arc-pro-b60-graphics/specifications.html)

## Supported Host Operating System

- Ubuntu 24.04.4 LTS

## Software Ingredients

| GPU Domain | Software Components | Description |
| --- | --- | --- |
| Kernel | 1. Intel(R) XE KMD Driver<br>2. GuC Firmware<br>3. HuC Firmware<br>4. DMC Firmware | The Intel® XE KMD provides the kernel-level graphics driver GPU initialization, scheduling, power management, and low-level gpu hardware control.<br><br>The Graphics Micro Controller (GuC) is the firmware used for GPU scheduling, context submission, and power management.<br><br>The HuC is the specialized firmware used for hardware video encoding and content protection.<br><br>The Display Micro Controller (DMC) firmware used for controlling display subsystem power management. |
| Media | 1. Intel(R) Media Driver<br>2. Intel(R) Gmmlib<br>3. Libva<br>4. Libva-utils<br>5. Libvpl-disp<br>6. Libvpl-tools<br>7. Gstreamer1.0 | The Intel(R) Media Driver for VAAPI is a new VA-API (Video Acceleration API) user mode driver supporting hardware accelerated decoding, encoding, and video post processing for GEN based graphics hardware.<br><br>The Intel® Video Processing Library (Intel® VPL) is part of a multilayer media portfolio that provides advanced access to specialized media hardware, plus encode, decode, and video processing features on Intel GPUs.<br><br>GStreamer is a multimedia framework with plugins that integrate Intel® VA-API and VPL to deliver comprehensive end-to-end media pipeline solutions |
| Graphics | 1. Intel(R) Mesa3d IRIS Driver | Delivers user-space 3D graphics acceleration and rendering support for Linux graphics and display workloads. |
| Compute-Runtime | 1. Intel(R) OpenCL ICD<br>2. Intel(R) Gmmlib<br>3. Intel(R) Graphics System Controller (igsc)<br>4. Intel® Graphics Compiler<br>5. Intel® level zero Gpu<br>6. Intel® Level Zero Gpu Ray Tracing | Provides GPU compute runtime capabilities for OpenCL and Level Zero based workloads, including compiler and device-management dependencies. |
| Graphics SR-IOV Virtualization | 1. Qemu<br>2. Mutter | QEMU is an open-source virtualization and emulation platform that runs virtual machines across different computer architectures. It integrated with Intel® Edge features to supports Graphics SR-IOV and Display Virtualization for simultaneous multi-OS environments and cross-platform compatibility.<br><br>Mutter provides Display virtualization with zero copy solution used for Wayland. |
| Tools | 1. Metrics Library & Metrics discovery<br>2. XPU Manager<br>3. Graphics SR-IOV Toolkit | Supplies telemetry, monitoring, manageability, and deployment utilities used for validation and operational workflows. |

## Prerequisites

- Download and Install Ubuntu 24.04.4 LTS on the system. Please refer to [Ubuntu website](https://ubuntu.com/)

## Clone With Submodules

```bash
git clone --recurse-submodules https://github.com/intel-sandbox/edge-gfx-linux-installer.git
cd edge-gfx-linux-installer
```

If already cloned:

```bash
git submodule update --init --recursive
```

## Host Installation

Run the host installer:

```bash
sudo ./installer/install-host.sh standard
```

Supported profiles:

- `standard`: Installs the core PPA with graphics, media, display, and compute packages. This profile supports bare-metal graphics, video conferencing, AI inference, digital signage, gaming, and other common workloads.  
- `virtualization`: Installs custom packages for Graphics SR-IOV use cases, including Intelligent Desktop Virtualization (IDV) solutions.

### Usage Examples

Use this profile for installing the baseline graphics, media and compute packages.

```bash
sudo ./installer/install-host.sh standard
```

Use this profile for installing Intel distribution Qemu, Mutter for display virtualization and custom gstreamer packages:
Please refer to sriov-toolkit folder for more details.

```bash
sudo ./installer/install-host.sh virtualization
```