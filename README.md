# Edge Graphics Linux Installer 

## Introduction
The Edge Graphics Linux Installer provides an integrated solution for deploying Intel® graphics software on supported Linux platforms. It bundles the required kernel drivers, firmware, media, compute, and graphics user-space components into a streamlined installation workflow.

The installer includes automated setup scripts to simplify deployment of Intel® Graphics packages, including optional virtualization components, Edge SR-IOV Toolkit and Edge Gfx DKMS Installer, enabling the custom edge software across supported systems.

## License
The Edge Graphics Linux installer is distributed under the MIT [license](license.md).

## Supported Platforms

| Platforms | Milestone Release | DKMS support | Kernel Support |
| --- | --- | --- | --- |
| Intel® Alder Lake | No | Yes | *v6.18 |
| Intel® Raptor Lake | No | Yes | *v6.18 |
| Intel® Meteor Lake | Yes | Yes | v6.18 |
| Intel® Amston Lake | Yes | Yes | v6.18 |
| Intel® Twinlake | No | Yes | *v6.18 |
| Intel® Bartlett Lake | Yes | Yes | v6.18 |
| Intel® Arrow Lake | Yes | Yes | v6.18 |
| Intel® Panther Lake | Yes | No | v6.18 |
| Intel® Wildcat Lake | Yes | No | v6.18 |
| Intel® Xeon Emerald Rapid + Intel® Arc™ Pro B60 Discrete GPU | No | No | *v6.18 |
| Intel® Bartlett Lake + Intel® Arc™ Pro B60 Discrete GPU | No | No | *v6.18 |

> **Disclaimer:** All listed platforms are supported. Platforms marked with `*v6.18` and `**without Milestone Release**` have been validated exclusively for GFX SR-IOV functionality and should not be considered as having full platform-level validation.

## Supported Host Operating System

- Ubuntu 24.04.4 LTS

## Software Ingredients

| GPU Domain | Software Components | Description |
| --- | --- | --- |
| Kernel | 1. Intel® XE KMD Driver<br>2. Intel® i915 KMD Driver <br>3. GuC Firmware<br>4. HuC Firmware<br>5. DMC Firmware | The Intel® XE/i915 KMD provides the kernel-level graphics driver GPU initialization, scheduling, power management, and low-level gpu hardware control.<br><br>The Graphics Micro Controller (GuC) is the firmware used for GPU scheduling, context submission, and power management.<br><br>The HuC is the specialized firmware used for hardware video encoding and content protection.<br><br>The Display Micro Controller (DMC) firmware used for controlling display subsystem power management. |
| Media | 1. Intel® Media Driver<br>2. Intel® Gmmlib<br>3. Libva<br>4. Libva-utils<br>5. Libvpl-disp<br>6. Libvpl-tools<br>7. Gstreamer1.0 | The Intel® Media Driver for VAAPI is a new VA-API (Video Acceleration API) user mode driver supporting hardware accelerated decoding, encoding, and video post processing for GEN based graphics hardware.<br><br>The Intel® Video Processing Library (Intel® VPL) is part of a multilayer media portfolio that provides advanced access to specialized media hardware, plus encode, decode, and video processing features on Intel GPUs.<br><br>GStreamer is a multimedia framework with plugins that integrate Intel® VA-API and VPL to deliver comprehensive end-to-end media pipeline solutions |
| Graphics | 1. Intel® Mesa3d IRIS Driver | Delivers user-space 3D graphics acceleration and rendering support for Linux graphics and display workloads. |
| Compute-Runtime | 1. Intel® OpenCL ICD<br>2. Intel® Gmmlib<br>3. Intel® Graphics System Controller (igsc)<br>4. Intel® Graphics Compiler<br>5. Intel® level zero GPU | Provides GPU compute runtime capabilities for OpenCL and Level Zero based workloads, including compiler and device-management dependencies. |
| Graphics SR-IOV Virtualization | 1. Qemu<br>2. Mutter | QEMU is an open-source virtualization and emulation platform that runs virtual machines across different computer architectures. It integrated with Intel® Edge features to supports Graphics SR-IOV and Display Virtualization for simultaneous multi-OS environments and cross-platform compatibility.<br><br>Mutter provides Display virtualization with zero copy solution used for Wayland. |
| Tools | 1. Graphics SR-IOV Toolkit <br>2. Graphics SR-IOV DKMS | Supplies deployment utilities used for validation and operational workflows as well as framework to rebuilds the kernel modules whenever a new kernel is installed |

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
sudo ./installer/install-host.sh [standard|standard-dkms|virtualization|virtualization-dkms]
```

Supported profiles:

| Profile | Description |
| --- | --- |
| `standard` | Installs the core PPA with graphics, media, display, and compute packages. Supports bare-metal graphics, video conferencing, AI inference, digital signage, gaming, and other common workloads. |
| `virtualization` | Installs custom packages for Graphics SR-IOV use cases, including Intelligent Desktop Virtualization (IDV) solutions. Refer to the `sriov-toolkit` folder for more details. |
| `standard-dkms` | Installs the core PPA with graphics, media, display, and compute packages with additional DKMS packages for xe/i915 SR-IOV kernel module rebuilds whenever a new kernel v6.18 is installed. |
| `virtualization-dkms` | Installs custom packages for Graphics SR-IOV use cases, including Intelligent Desktop Virtualization (IDV) solutions, with additional DKMS packages for xe/i915 SR-IOV kernel module rebuilds whenever a new kernel v6.18 is installed. |

