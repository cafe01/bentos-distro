#!/bin/bash
set -euo pipefail

# Build BentOS kernel from Alpine linux-virt source inside Docker.
# Supports arm64 (Apple Silicon) and amd64 (x86_64) targets.
#
# Usage: ./scripts/build-kernel.sh [--arch ARCH] [--output DIR]
#   --arch ARCH    Target architecture: arm64 (default) or amd64
#   --output DIR   Output directory (default: output/{arch})
# Output: DIR/bentos-kernel-{arch} (Image for arm64, bzImage for amd64)

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="arm64"
OUTPUT_DIR=""
ALPINE_VERSION="3.21"
CONTAINER_NAME="bentos-kernel-build"

while [[ $# -gt 0 ]]; do
    case $1 in
        --arch) TARGET_ARCH="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Architecture-specific mappings
case "$TARGET_ARCH" in
    arm64)
        DOCKER_PLATFORM="linux/arm64"
        KERNEL_ARCH="arm64"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        KERNEL_OUTPUT="bentos-kernel-arm64"
        ;;
    amd64)
        DOCKER_PLATFORM="linux/amd64"
        KERNEL_ARCH="x86_64"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        KERNEL_OUTPUT="bentos-kernel-amd64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $TARGET_ARCH (use arm64 or amd64)"
        exit 1
        ;;
esac

OUTPUT_DIR="${OUTPUT_DIR:-${DISTRO_ROOT}/output/${TARGET_ARCH}}"
mkdir -p "$OUTPUT_DIR"

echo "=== BentOS Kernel Build (${TARGET_ARCH}) ==="
echo "Alpine version: ${ALPINE_VERSION}"
echo "Docker platform: ${DOCKER_PLATFORM}"
echo "Kernel arch: ${KERNEL_ARCH}"
echo "Output: ${OUTPUT_DIR}"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Pass architecture variables into the inner script via environment
cat > /tmp/bentos-kernel-build.sh << 'INNER_SCRIPT'
#!/bin/sh
set -eu

# These come from the outer script via -e flags
KERNEL_ARCH="${KERNEL_ARCH}"
KERNEL_IMAGE="${KERNEL_IMAGE}"
KERNEL_OUTPUT="${KERNEL_OUTPUT}"

# Resolve make ARCH= value (kernel uses arm64, not aarch64; x86_64, not amd64)
MAKE_ARCH="$KERNEL_ARCH"
if [ "$KERNEL_ARCH" = "x86_64" ]; then
    MAKE_ARCH="x86"
fi

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
    make ARCH="$MAKE_ARCH" defconfig
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
make ARCH="$MAKE_ARCH" olddefconfig

echo "--- Building kernel ($(nproc) jobs) ---"
make ARCH="$MAKE_ARCH" -j"$(nproc)" "${KERNEL_IMAGE##*/}" modules 2>&1

echo "--- Kernel build complete ---"
ls -la "$KERNEL_IMAGE"
file "$KERNEL_IMAGE"

echo "--- Config verification ---"
echo "FUSE_FS: $(./scripts/config --file .config --state CONFIG_FUSE_FS)"
echo "CUSE: $(./scripts/config --file .config --state CONFIG_CUSE)"
echo "VIRTIO_VSOCK: $(./scripts/config --file .config --state CONFIG_VIRTIO_VSOCK)"
echo "VIRTIO_FS: $(./scripts/config --file .config --state CONFIG_VIRTIO_FS)"

# Copy outputs
cp "$KERNEL_IMAGE" "/output/${KERNEL_OUTPUT}"
cp .config /output/bentos_defconfig_full

# Install modules for rootfs build
make ARCH="$MAKE_ARCH" modules_install INSTALL_MOD_PATH=/output/modules
echo "--- Modules installed ---"
find /output/modules -name '*.ko' | head -20

echo "=== Kernel build SUCCESS ==="
echo "Kernel: /output/${KERNEL_OUTPUT} ($(du -h "/output/${KERNEL_OUTPUT}" | cut -f1))"
INNER_SCRIPT

chmod +x /tmp/bentos-kernel-build.sh

echo "--- Starting Docker build ---"
docker run --rm \
    --name "$CONTAINER_NAME" \
    --platform "$DOCKER_PLATFORM" \
    -e "KERNEL_ARCH=$KERNEL_ARCH" \
    -e "KERNEL_IMAGE=$KERNEL_IMAGE" \
    -e "KERNEL_OUTPUT=$KERNEL_OUTPUT" \
    -v /tmp/bentos-kernel-build.sh:/build.sh:ro \
    -v "$OUTPUT_DIR":/output \
    alpine:${ALPINE_VERSION} \
    /bin/sh /build.sh

echo ""
echo "=== Output ==="
ls -la "$OUTPUT_DIR"/${KERNEL_OUTPUT} 2>/dev/null && echo "Kernel image ready." || echo "ERROR: Kernel image not found"
ls -la "$OUTPUT_DIR"/modules/lib/modules/ 2>/dev/null && echo "Modules ready." || echo "ERROR: Modules not found"
