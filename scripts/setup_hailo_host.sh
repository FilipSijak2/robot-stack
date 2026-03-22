#!/usr/bin/env bash
# setup_hailo_host.sh - Run ONCE on the Raspberry Pi host (Ubuntu 24.04 arm64).
#
# Installs the Hailo AI Kit runtime on the host:
#   1. Kernel headers (required to build the PCIe driver)
#   2. hailort-pcie-driver - PCIe kernel module + udev rules + firmware
#   3. hailort             - userspace runtime library (libhailort.so)
#   4. hailo-tappas-core   - GStreamer hailonet plugin + Python bindings
#
# Packages are downloaded from the Raspberry Pi Debian archive, which hosts
# Ubuntu-compatible arm64 debs for HailoRT and TAPPAS Core.
# (Reference: https://ubuntu.com/blog/hackers-guide-to-the-raspberry-pi-ai-kit-on-ubuntu)
#
# After this, the ai_kit container bind-mounts the host libs - no
# downloading or installation happens inside the container.
#
# Usage:
#   chmod +x scripts/setup_hailo_host.sh
#   sudo ./scripts/setup_hailo_host.sh
#   sudo reboot
#
# Verify after reboot:
#   hailortcli fw-control identify

set -euo pipefail

# Versions tested on Ubuntu 24.04 arm64 with the AI Kit (Hailo-8L).
# Source: https://ubuntu.com/blog/hackers-guide-to-the-raspberry-pi-ai-kit-on-ubuntu
HAILORT_VERSION="4.17.0"
TAPPAS_VERSION="3.28.2"
RPI_ARCHIVE="http://archive.raspberrypi.com/debian/pool/main"

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this script with sudo." >&2
  exit 1
fi

# Only supported on arm64
if [ "$(uname -m)" != "aarch64" ]; then
  echo "ERROR: This script is for arm64 (Raspberry Pi) only." >&2
  exit 1
fi

echo "=== Installing Hailo AI Kit runtime on Ubuntu host ==="
echo "    HailoRT:     ${HAILORT_VERSION}"
echo "    TAPPAS Core: ${TAPPAS_VERSION}"
echo

# --- 1. Kernel headers + build tools (needed for PCIe driver build) ---
echo "[1/5] Installing kernel headers and build tools..."
# Allow update to partially fail (e.g. third-party repos like librealsense
# returning 403). Standard Ubuntu repos will still be refreshed correctly.
apt-get update -qq || true
# Only the essentials for compiling/installing the PCIe driver.
# GStreamer/OpenCV/etc. come bundled with the hailo-tappas-core .deb in step 4.
apt-get install -y --no-install-recommends \
  "linux-headers-$(uname -r)" \
  dkms \
  build-essential \
  git \
  wget

# --- 2. Build and install the PCIe kernel driver from source ---
# Hailo does not provide this driver as an Ubuntu binary package.
# We install from the matching source release so it aligns with HailoRT.
echo "[2/5] Building and installing Hailo PCIe driver..."
DRIVER_DIR="/usr/src/hailo_pci-${HAILORT_VERSION}"
if [ -d "${DRIVER_DIR}" ]; then
  echo "  Driver source already present at ${DRIVER_DIR}, skipping clone."
else
  git -c advice.detachedHead=false clone --depth 1 --branch "v${HAILORT_VERSION}" \
    https://github.com/hailo-ai/hailort-drivers.git \
    "${DRIVER_DIR}"
fi

# Download firmware (required at boot)
cd "${DRIVER_DIR}"
./download_firmware.sh
mkdir -p /lib/firmware/hailo
cp -f hailo8_fw.*.bin /lib/firmware/hailo/hailo8_fw.bin

# Build/install driver from the PCIe subdirectory.
PCIE_DIR="${DRIVER_DIR}/linux/pcie"
if [ ! -d "${PCIE_DIR}" ]; then
  echo "ERROR: Missing PCIe driver directory: ${PCIE_DIR}" >&2
  exit 1
fi

cd "${PCIE_DIR}"
make all
make install
if ! modprobe hailo_pci 2>/dev/null; then
  modprobe hailo1x_pci || true
fi
cp -f 51-hailo-udev.rules /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger
cd - >/dev/null

# --- 3. Download debs from Raspberry Pi archive ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[3/5] Downloading HailoRT and TAPPAS packages from RPi archive..."
wget -q --show-progress \
  -O "${TMP_DIR}/hailort.deb" \
  "${RPI_ARCHIVE}/h/hailort/hailort_${HAILORT_VERSION}_arm64.deb"

wget -q --show-progress \
  -O "${TMP_DIR}/hailo-tappas-core.deb" \
  "${RPI_ARCHIVE}/h/hailo-tappas-core-${TAPPAS_VERSION}/hailo-tappas-core-${TAPPAS_VERSION}_${TAPPAS_VERSION}_arm64.deb"

# --- 4. Install debs ---
echo "[4/5] Installing HailoRT and TAPPAS Core..."
apt-get install -y "${TMP_DIR}/hailort.deb"
apt-get install -y "${TMP_DIR}/hailo-tappas-core.deb"

# --- 5. Done ---
echo
echo "[5/5] Installation complete. A reboot is required."
echo
echo "    sudo reboot"
echo
echo "After reboot, verify with:"
echo "    ls /dev/hailo*              # expects /dev/hailo0"
echo "    hailortcli fw-control identify"