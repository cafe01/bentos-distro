#!/bin/bash
set -euo pipefail

# Orchestrator: build kernel + rootfs for BentOS.
# Usage: ./scripts/build-image.sh [--arch ARCH] [--output DIR]
#   --arch ARCH    Target architecture: arm64 (default) or amd64

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="arm64"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --arch) TARGET_ARCH="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

OUTPUT_DIR="${OUTPUT_DIR:-${DISTRO_ROOT}/output/${TARGET_ARCH}}"

echo "========================================"
echo "  BentOS Image Build (${TARGET_ARCH})"
echo "========================================"
echo ""

# Step 1: Kernel
echo ">>> Step 1/2: Building kernel..."
"${DISTRO_ROOT}/scripts/build-kernel.sh" --arch "$TARGET_ARCH" --output "$OUTPUT_DIR"
echo ""

# Step 2: Rootfs (includes kernel modules)
echo ">>> Step 2/2: Building rootfs..."
"${DISTRO_ROOT}/scripts/build-rootfs.sh" --arch "$TARGET_ARCH" --output "$OUTPUT_DIR"
echo ""

# Determine output filenames
case "$TARGET_ARCH" in
    arm64) KERNEL="bentos-kernel-arm64"; ROOTFS="bentos-rootfs-arm64.img" ;;
    amd64) KERNEL="bentos-kernel-amd64"; ROOTFS="bentos-rootfs-amd64.img" ;;
    *) echo "ERROR: Unsupported architecture: $TARGET_ARCH"; exit 1 ;;
esac

echo "========================================"
echo "  Build Complete"
echo "========================================"
echo ""
echo "Kernel: ${OUTPUT_DIR}/${KERNEL}"
echo "Rootfs: ${OUTPUT_DIR}/${ROOTFS}"
echo "Config: ${OUTPUT_DIR}/bentos_defconfig_full"
echo ""
echo "Kernel size: $(du -h "${OUTPUT_DIR}/${KERNEL}" | cut -f1)"
echo "Rootfs size: $(du -h "${OUTPUT_DIR}/${ROOTFS}" | cut -f1)"
