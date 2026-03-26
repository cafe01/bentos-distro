#!/bin/bash
set -euo pipefail

# Orchestrator: build kernel + rootfs for BentOS ARM64.
# Usage: ./scripts/build-image.sh [--output DIR]

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${DISTRO_ROOT}/output/arm64"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "========================================"
echo "  BentOS Image Build (ARM64)"
echo "========================================"
echo ""

# Step 1: Kernel
echo ">>> Step 1/2: Building kernel..."
"${DISTRO_ROOT}/scripts/build-kernel.sh" --output "$OUTPUT_DIR"
echo ""

# Step 2: Rootfs (includes kernel modules — M2)
echo ">>> Step 2/2: Building rootfs..."
"${DISTRO_ROOT}/scripts/build-rootfs.sh" --output "$OUTPUT_DIR"
echo ""

echo "========================================"
echo "  Build Complete"
echo "========================================"
echo ""
echo "Kernel: ${OUTPUT_DIR}/bentos-kernel-arm64"
echo "Rootfs: ${OUTPUT_DIR}/bentos-rootfs-arm64.img"
echo "Config: ${OUTPUT_DIR}/bentos_defconfig_full"
echo ""
echo "Kernel size: $(du -h "${OUTPUT_DIR}/bentos-kernel-arm64" | cut -f1)"
echo "Rootfs size: $(du -h "${OUTPUT_DIR}/bentos-rootfs-arm64.img" | cut -f1)"
echo ""
echo "To boot: use bentos-vmm-macos with these artifacts."
