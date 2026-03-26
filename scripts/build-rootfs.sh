#!/bin/bash
set -euo pipefail

# Build BentOS ARM64 rootfs inside Docker.
# Produces an ext4 image with Alpine base + kernel modules + BentOS binaries.
# Requires: kernel modules from build-kernel.sh in output/arm64/modules/
#
# Usage: ./scripts/build-rootfs.sh [--output DIR] [--size SIZE_MB] [--no-bentos]
#   --output DIR     Output directory (default: output/arm64)
#   --size SIZE_MB   Rootfs image size in MB (default: 256)
#   --no-bentos      Skip BentOS binary compile stage (for fast iteration)
# Output: DIR/bentos-rootfs-arm64.img

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${DISTRO_ROOT}/../.." && pwd)"
OUTPUT_DIR="${DISTRO_ROOT}/output/arm64"
CONFIGS_DIR="${DISTRO_ROOT}/configs"
ALPINE_VERSION="3.21"
ROOTFS_SIZE_MB=256
SKIP_BENTOS=false
CONTAINER_NAME="bentos-rootfs-build"
DART_CONTAINER_NAME="bentos-dart-build"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --size) ROOTFS_SIZE_MB="$2"; shift 2 ;;
        --no-bentos) SKIP_BENTOS=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

# Check kernel modules exist
if [ ! -d "$OUTPUT_DIR/modules/lib/modules" ]; then
    echo "ERROR: Kernel modules not found at $OUTPUT_DIR/modules/lib/modules/"
    echo "Run build-kernel.sh first."
    exit 1
fi

echo "=== BentOS Rootfs Build (ARM64) ==="
echo "Alpine version: ${ALPINE_VERSION}"
echo "Rootfs size: ${ROOTFS_SIZE_MB}MB"
echo "Output: ${OUTPUT_DIR}"
echo "Skip BentOS: ${SKIP_BENTOS}"

# ---------------------------------------------------------------------------
# Stage 1: Compile BentOS Dart binaries (ARM64)
# ---------------------------------------------------------------------------

BENTOS_BINS_DIR="${OUTPUT_DIR}/bentos-bins"

if [ "$SKIP_BENTOS" = "false" ]; then
    echo ""
    echo "--- Stage 1: Compiling BentOS Dart binaries (ARM64) ---"

    # bentosd source is at lib/bentosd relative to the repo root.
    BENTOSD_SRC="${REPO_ROOT}/lib/bentosd"
    BENTOS_FUSE_SRC="${REPO_ROOT}/lib/bentos_fuse"

    if [ ! -f "${BENTOSD_SRC}/bin/bentosd.dart" ]; then
        echo "ERROR: lib/bentosd/bin/bentosd.dart not found at ${BENTOSD_SRC}"
        echo "Has G1+G2+G3 been implemented? See hq/workshop/s310-e2e-status.md"
        exit 1
    fi

    mkdir -p "$BENTOS_BINS_DIR"
    docker rm -f "$DART_CONTAINER_NAME" 2>/dev/null || true

    # Use official Dart image on linux/arm64.
    # Mount the entire lib/ directory so path dependencies resolve.
    # dart compile exe produces a self-contained AOT binary.
    docker run --rm \
        --name "$DART_CONTAINER_NAME" \
        --platform linux/arm64 \
        -v "${REPO_ROOT}/lib":/workspace/lib:ro \
        -v "${BENTOS_BINS_DIR}":/output \
        dart:stable \
        /bin/sh -c '
set -e
cd /workspace/lib/bentosd

echo "Installing dependencies..."
dart pub get

echo "Compiling bentosd..."
dart compile exe bin/bentosd.dart -o /output/bentosd

echo "Compiling bentos..."
dart compile exe bin/bentos.dart -o /output/bentos

echo "Build complete:"
ls -lh /output/
'

    echo "Dart binaries compiled:"
    ls -lh "$BENTOS_BINS_DIR/"
else
    echo ""
    echo "--- Stage 1: Skipping BentOS Dart compile (--no-bentos) ---"
    # Create empty bins dir so the rootfs stage doesn't fail
    mkdir -p "$BENTOS_BINS_DIR"
fi

# ---------------------------------------------------------------------------
# Stage 2: Build rootfs image
# ---------------------------------------------------------------------------

echo ""
echo "--- Stage 2: Building rootfs image ---"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

cat > /tmp/bentos-rootfs-build.sh << 'INNER_SCRIPT'
#!/bin/sh
set -eu

ALPINE_VERSION="3.21"
ROOTFS="/tmp/rootfs"
IMG="/output/bentos-rootfs-arm64.img"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-256}"
SKIP_BENTOS="${SKIP_BENTOS:-false}"
REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main"
REPO_COMMUNITY="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community"

echo "--- Installing build tools ---"
apk add --no-cache e2fsprogs e2fsprogs-extra apk-tools alpine-keys openssl

echo "--- Creating ext4 image (${ROOTFS_SIZE_MB}MB) ---"
truncate -s "${ROOTFS_SIZE_MB}M" "$IMG"
mkfs.ext4 -L bentos-root -q "$IMG"

echo "--- Mounting rootfs ---"
mkdir -p "$ROOTFS"
mount -o loop "$IMG" "$ROOTFS"

echo "--- Installing Alpine base packages ---"
apk --root "$ROOTFS" --initdb --arch aarch64 \
    --repository "$REPO_MAIN" \
    --repository "$REPO_COMMUNITY" \
    --allow-untrusted \
    add \
    alpine-base \
    bash \
    openssh-server \
    shadow \
    sudo \
    musl-utils \
    busybox-openrc \
    busybox-mdev-openrc \
    openrc \
    fuse3

echo "--- Configuring system files ---"

# Copy config files from configs/ — single source of truth
cp /configs/etc/hostname "$ROOTFS/etc/hostname"
cp /configs/etc/hosts "$ROOTFS/etc/hosts"
cp /configs/etc/securetty "$ROOTFS/etc/securetty"
cp /configs/etc/modules "$ROOTFS/etc/modules"

mkdir -p "$ROOTFS/etc/network"
cp /configs/etc/network/interfaces "$ROOTFS/etc/network/interfaces"

# DNS (not in configs/ — generated)
echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"

# Inittab — getty on hvc0 (VZ.fw virtio-console)
cat > "$ROOTFS/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
hvc0::respawn:/sbin/getty 38400 hvc0
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# fstab
cat > "$ROOTFS/etc/fstab" << 'EOF'
/dev/vda    /       ext4    rw,relatime   0 1
devtmpfs    /dev    devtmpfs rw,nosuid    0 0
proc        /proc   proc    rw,nosuid,nodev,noexec 0 0
sysfs       /sys    sysfs   rw,nosuid,nodev,noexec 0 0
tmpfs       /tmp    tmpfs   rw,nosuid,nodev 0 0
tmpfs       /run    tmpfs   rw,nosuid,nodev,mode=0755 0 0
EOF

# Root password
echo "root:bentos" | chroot "$ROOTFS" chpasswd 2>/dev/null || {
    HASH=$(openssl passwd -6 bentos)
    sed -i "s|^root:[^:]*|root:${HASH}|" "$ROOTFS/etc/shadow"
}

echo "--- Installing kernel modules (selective) ---"
if [ -d /modules/lib/modules ]; then
    KVER=$(ls /modules/lib/modules/ | head -1)
    MODDIR="$ROOTFS/lib/modules/$KVER"
    mkdir -p "$MODDIR/kernel"

    NEEDED_MODULES="
        kernel/fs/fuse/cuse.ko.gz
        kernel/fs/fuse/virtiofs.ko.gz
        kernel/net/vmw_vsock/vsock.ko.gz
        kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.gz
        kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko.gz
        kernel/net/vmw_vsock/vsock_diag.ko.gz
        kernel/net/vmw_vsock/vsock_loopback.ko.gz
    "
    SRCMOD="/modules/lib/modules/$KVER"
    for mod in $NEEDED_MODULES; do
        src="$SRCMOD/$mod"
        if [ -f "$src" ]; then
            dst="$MODDIR/$mod"
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            echo "  Installed: $mod"
        else
            echo "  WARNING: $mod not found"
        fi
    done

    for f in modules.order modules.builtin modules.builtin.modinfo; do
        [ -f "$SRCMOD/$f" ] && cp "$SRCMOD/$f" "$MODDIR/"
    done

    apk --root "$ROOTFS" --repository "$REPO_MAIN" --repository "$REPO_COMMUNITY" \
        --allow-untrusted add kmod
    chroot "$ROOTFS" depmod "$KVER" 2>/dev/null || echo "WARNING: depmod failed"
    echo "Installed modules:"
    find "$MODDIR" -name '*.ko*' -type f
else
    echo "WARNING: No kernel modules found at /modules/lib/modules"
fi

echo "--- Installing BentOS binaries ---"
if [ "$SKIP_BENTOS" = "false" ] && [ -f /bentos-bins/bentosd ]; then
    install -m 0755 /bentos-bins/bentosd "$ROOTFS/usr/bin/bentosd"
    install -m 0755 /bentos-bins/bentos  "$ROOTFS/usr/bin/bentos"
    echo "Installed: /usr/bin/bentosd ($(du -h /bentos-bins/bentosd | cut -f1))"
    echo "Installed: /usr/bin/bentos ($(du -h /bentos-bins/bentos | cut -f1))"
else
    echo "Skipping BentOS binaries (--no-bentos or binaries not found)"
fi

echo "--- Installing bentosd OpenRC service ---"
if [ -f /configs/etc/init.d/bentosd ]; then
    install -m 0755 /configs/etc/init.d/bentosd "$ROOTFS/etc/init.d/bentosd"
    echo "Installed: /etc/init.d/bentosd"
fi

echo "--- Enabling services ---"
chroot "$ROOTFS" rc-update add devfs sysinit 2>/dev/null || true
chroot "$ROOTFS" rc-update add dmesg sysinit 2>/dev/null || true
chroot "$ROOTFS" rc-update add mdev sysinit 2>/dev/null || true

chroot "$ROOTFS" rc-update add hwclock boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add modules boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add sysctl boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add hostname boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add bootmisc boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add syslog boot 2>/dev/null || true

chroot "$ROOTFS" rc-update add networking default 2>/dev/null || true
chroot "$ROOTFS" rc-update add sshd default 2>/dev/null || true

if [ -f "$ROOTFS/etc/init.d/bentosd" ] && [ "$SKIP_BENTOS" = "false" ]; then
    chroot "$ROOTFS" rc-update add bentosd default 2>/dev/null || true
    echo "Enabled: bentosd in default runlevel"
fi

chroot "$ROOTFS" rc-update add mount-ro shutdown 2>/dev/null || true
chroot "$ROOTFS" rc-update add killprocs shutdown 2>/dev/null || true
chroot "$ROOTFS" rc-update add savecache shutdown 2>/dev/null || true

mkdir -p "$ROOTFS/etc/ssh"

echo "--- Cleaning up ---"
rm -rf "$ROOTFS/var/cache/apk/"*

echo "--- Unmounting and finalizing ---"
umount "$ROOTFS"

e2fsck -fy "$IMG" || true
resize2fs -M "$IMG"

echo "=== Rootfs build SUCCESS ==="
ls -la "$IMG"
echo "Image size: $(du -h "$IMG" | cut -f1)"

INNER_SCRIPT

chmod +x /tmp/bentos-rootfs-build.sh

echo "--- Starting rootfs Docker build ---"
docker run --rm \
    --name "$CONTAINER_NAME" \
    --platform linux/arm64 \
    --privileged \
    -e "ROOTFS_SIZE_MB=${ROOTFS_SIZE_MB}" \
    -e "SKIP_BENTOS=${SKIP_BENTOS}" \
    -v /tmp/bentos-rootfs-build.sh:/build.sh:ro \
    -v "$OUTPUT_DIR":/output \
    -v "$OUTPUT_DIR/modules":/modules:ro \
    -v "$CONFIGS_DIR":/configs:ro \
    -v "$BENTOS_BINS_DIR":/bentos-bins:ro \
    alpine:${ALPINE_VERSION} \
    /bin/sh /build.sh

echo ""
echo "=== Output ==="
ls -la "$OUTPUT_DIR"/bentos-rootfs-arm64.img 2>/dev/null && echo "Rootfs image ready." || echo "ERROR: Rootfs image not found"
