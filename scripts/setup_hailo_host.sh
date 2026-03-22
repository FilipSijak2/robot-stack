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
HAILORT_DRIVERS_COMMIT="f840b6219230ec9a350444dbb903adbf0f63a373"
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
echo "    Driver rev:  ${HAILORT_DRIVERS_COMMIT}"
echo "    TAPPAS Core: ${TAPPAS_VERSION}"
echo

# --- 0. Wait for any background apt/dpkg process to finish ---
echo "[0/5] Waiting for dpkg lock (unattended-upgrades may be running)..."
systemctl stop unattended-upgrades 2>/dev/null || true
# Wait up to 120 s for the lock to be released
LOCK_TIMEOUT=120
LOCK_ELAPSED=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  if [ "${LOCK_ELAPSED}" -ge "${LOCK_TIMEOUT}" ]; then
    echo "ERROR: dpkg lock still held after ${LOCK_TIMEOUT}s. Try: sudo killall unattended-upgrades" >&2
    exit 1
  fi
  echo "  dpkg locked — waiting (${LOCK_ELAPSED}s)..."
  sleep 5
  LOCK_ELAPSED=$((LOCK_ELAPSED + 5))
done
echo "  Lock free, continuing."

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
  pciutils \
  wget

# --- 2. Build and install the PCIe kernel driver from source ---
# Hailo does not provide this driver as an Ubuntu binary package.
# We install from the matching source release so it aligns with HailoRT.
echo "[2/5] Building and installing Hailo PCIe driver..."
DRIVER_DIR="/usr/src/hailo_pci-${HAILORT_VERSION}"
if [ -d "${DRIVER_DIR}" ]; then
  CURRENT_REV="$(git -C "${DRIVER_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [ "${CURRENT_REV}" = "${HAILORT_DRIVERS_COMMIT}" ]; then
    echo "  Driver source already at the expected revision, reusing ${DRIVER_DIR}."
  else
    BACKUP_DIR="${DRIVER_DIR}.bak.$(date +%s)"
    echo "  Moving existing driver source to ${BACKUP_DIR} to avoid stale builds."
    mv "${DRIVER_DIR}" "${BACKUP_DIR}"
  fi
fi

if [ ! -d "${DRIVER_DIR}" ]; then
  git clone https://github.com/hailo-ai/hailort-drivers.git "${DRIVER_DIR}"
  git -C "${DRIVER_DIR}" -c advice.detachedHead=false checkout "${HAILORT_DRIVERS_COMMIT}"
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
depmod -a
printf '%s\n' hailo_pci > /etc/modules-load.d/hailo-pci.conf
if ! modprobe hailo_pci; then
  echo "ERROR: Failed to load hailo_pci after installation." >&2
  echo "Kernel: $(uname -r)" >&2
  echo "Installed Hailo modules under /lib/modules:" >&2
  find "/lib/modules/$(uname -r)" -type f \( -name 'hailo*.ko' -o -name 'hailo*.ko.xz' -o -name 'hailo*.ko.zst' \) 2>/dev/null >&2 || true
  echo "Check: dmesg | tail -n 100" >&2
  exit 1
fi
if ! modinfo hailo_pci >/dev/null 2>&1; then
  echo "ERROR: hailo_pci was not installed into the current kernel modules path." >&2
  echo "Kernel: $(uname -r)" >&2
  echo "Installed Hailo modules under /lib/modules:" >&2
  find "/lib/modules/$(uname -r)" -type f \( -name 'hailo*.ko' -o -name 'hailo*.ko.xz' -o -name 'hailo*.ko.zst' \) 2>/dev/null >&2 || true
  exit 1
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
# Use dpkg -i (not apt-get install) to avoid the _apt sandbox permission issue
# with root-owned temp files.
dpkg -i "${TMP_DIR}/hailort.deb" || true

# hailo-tappas-core deps are pinned to Debian Bookworm (RPi OS) exact versions
# which differ slightly from Ubuntu 24.04 (e.g. libbsd0, libdrm2). These are
# build-time -dev packages; the runtime .so files install fine regardless.
# --force-depends bypasses the version check; apt -f install fixes what it can.
dpkg -i --force-depends "${TMP_DIR}/hailo-tappas-core.deb" || true
apt-get install -f -y || true

# --- 5. Done ---
echo
echo "[5/5] Installation complete. A reboot is required."
echo
echo "    sudo reboot"
echo
echo "After reboot, verify with:"
echo "    ls /dev/hailo*              # expects /dev/hailo0"
echo "    hailortcli fw-control identify"
if [ ! -e /dev/hailo0 ]; then
  echo
  echo "WARNING: /dev/hailo0 is not present yet." >&2
  echo "Run these checks after reboot if it is still missing:" >&2
  echo "    sudo modprobe hailo_pci" >&2
  echo "    sudo dmesg | grep -i hailo" >&2
  echo "    lspci -nn | grep -Ei '1e60|hailo'" >&2
fi
