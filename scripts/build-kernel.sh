#!/bin/bash
set -euo pipefail

# Build BentOS ARM64 kernel from Alpine linux-virt source inside Docker.
# Runs on Apple Silicon — native ARM64, no cross-compilation.
#
# Usage: ./scripts/build-kernel.sh [--output DIR]
# Output: DIR/bentos-kernel-arm64 (uncompressed Image)

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${DISTRO_ROOT}/output/arm64"
ALPINE_VERSION="3.21"
CONTAINER_NAME="bentos-kernel-build"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

echo "=== BentOS Kernel Build (ARM64) ==="
echo "Alpine version: ${ALPINE_VERSION}"
echo "Output: ${OUTPUT_DIR}"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

cat > /tmp/bentos-kernel-build.sh << 'INNER_SCRIPT'
#!/bin/sh
set -eu

echo "--- Installing build dependencies ---"
apk add --no-cache \
    build-base bc bison flex elfutils-dev linux-headers \
    perl python3 openssl-dev findutils diffutils \
    curl tar xz coreutils sed gzip bash gmp-dev

echo "--- Installing Alpine linux-virt to extract config ---"
apk add --no-cache linux-virt

# Get kernel version from installed modules
KVER_DIR=$(ls /lib/modules/ | head -1)
# Extract x.y.z from "6.12.77-0-virt"
KPATCH=$(echo "$KVER_DIR" | sed 's/-.*//')
KMAJOR=$(echo "$KPATCH" | cut -d. -f1)
echo "Kernel: $KPATCH (modules: $KVER_DIR, major: v${KMAJOR}.x)"

# Find Alpine's kernel config
CONFIG_FILE=""
for f in "/boot/config-virt" "/boot/config-${KVER_DIR}" "/boot/config"; do
    if [ -f "$f" ]; then
        CONFIG_FILE="$f"
        break
    fi
done
echo "Alpine config: ${CONFIG_FILE:-not found}"

echo "--- Downloading kernel source $KPATCH ---"
KSRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KPATCH}.tar.xz"
echo "URL: $KSRC_URL"
curl -fSL "$KSRC_URL" -o /tmp/linux.tar.xz

echo "--- Extracting kernel source ---"
mkdir -p /build
cd /build
tar xf /tmp/linux.tar.xz --strip-components=1
rm /tmp/linux.tar.xz

echo "--- Applying BentOS kernel config ---"
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    echo "Starting from Alpine linux-virt config"
    cp "$CONFIG_FILE" .config
else
    echo "Alpine config not found — using defconfig as base"
    make ARCH=arm64 defconfig
fi

# BentOS-specific config changes
./scripts/config --enable FUSE_FS           # =y built-in (bentosd depends on it)
./scripts/config --module CUSE              # =m module (loaded via /etc/modules)
./scripts/config --enable VIRTIO_VSOCK      # =y built-in (control plane)
./scripts/config --module VIRTIO_FS         # =m module (virtiofs, on demand)

# Verify virtio essentials
for opt in VIRTIO VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE \
           HW_RANDOM_VIRTIO EXT4_FS TMPFS DEVTMPFS NAMESPACES CGROUPS SECCOMP OVERLAY_FS; do
    state=$(./scripts/config --state "CONFIG_$opt" 2>/dev/null || echo "n")
    if [ "$state" = "n" ]; then
        echo "WARNING: CONFIG_$opt not enabled, enabling..."
        ./scripts/config --enable "$opt"
    else
        echo "  CONFIG_$opt = $state"
    fi
done

# Disable GCC plugins (avoids needing mpc-dev headers, not needed for VM kernel)
./scripts/config --disable GCC_PLUGINS

# Disable module signing (Alpine config references buildozer's signing key)
./scripts/config --disable MODULE_SIG
./scripts/config --disable MODULE_SIG_ALL
./scripts/config --set-str MODULE_SIG_KEY ""
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

# Strip unnecessary hardware drivers
for opt in USB_SUPPORT SOUND DRM WLAN BLUETOOTH INPUT_JOYSTICK INPUT_TABLET \
           WIRELESS RFKILL NFC MEDIA_SUPPORT; do
    ./scripts/config --disable "$opt" 2>/dev/null || true
done

# Resolve dependencies
make ARCH=arm64 olddefconfig

echo "--- Building kernel ($(nproc) jobs) ---"
make ARCH=arm64 -j"$(nproc)" Image modules 2>&1

echo "--- Kernel build complete ---"
ls -la arch/arm64/boot/Image
file arch/arm64/boot/Image

echo "--- Config verification ---"
echo "FUSE_FS: $(./scripts/config --file .config --state CONFIG_FUSE_FS)"
echo "CUSE: $(./scripts/config --file .config --state CONFIG_CUSE)"
echo "VIRTIO_VSOCK: $(./scripts/config --file .config --state CONFIG_VIRTIO_VSOCK)"
echo "VIRTIO_FS: $(./scripts/config --file .config --state CONFIG_VIRTIO_FS)"

# Copy outputs
cp arch/arm64/boot/Image /output/bentos-kernel-arm64
cp .config /output/bentos_defconfig_full

# Install modules for rootfs build
make ARCH=arm64 modules_install INSTALL_MOD_PATH=/output/modules
echo "--- Modules installed ---"
find /output/modules -name '*.ko' | head -20

echo "=== Kernel build SUCCESS ==="
echo "Kernel: /output/bentos-kernel-arm64 ($(du -h /output/bentos-kernel-arm64 | cut -f1))"
INNER_SCRIPT

chmod +x /tmp/bentos-kernel-build.sh

echo "--- Starting Docker build ---"
docker run --rm \
    --name "$CONTAINER_NAME" \
    --platform linux/arm64 \
    -v /tmp/bentos-kernel-build.sh:/build.sh:ro \
    -v "$OUTPUT_DIR":/output \
    alpine:${ALPINE_VERSION} \
    /bin/sh /build.sh

echo ""
echo "=== Output ==="
ls -la "$OUTPUT_DIR"/bentos-kernel-arm64 2>/dev/null && echo "Kernel image ready." || echo "ERROR: Kernel image not found"
ls -la "$OUTPUT_DIR"/modules/lib/modules/ 2>/dev/null && echo "Modules ready." || echo "ERROR: Modules not found"
