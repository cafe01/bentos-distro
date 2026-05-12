#!/bin/bash
set -euo pipefail

# Build BentOS rootfs inside Docker.
# Produces an ext4 image with Alpine base + kernel modules + BentOS binaries.
# Supports arm64 (Apple Silicon) and amd64 (x86_64) targets.
# Requires: kernel modules from build-kernel.sh in output/{arch}/modules/
#
# Usage: ./scripts/build-rootfs.sh [--arch ARCH] [--output DIR] [--size SIZE_MB] [--no-bentos]
#   --arch ARCH      Target architecture: arm64 (default) or amd64
#   --output DIR     Output directory (default: output/{arch})
#   --size SIZE_MB   Rootfs image size in MB (default: 256)
#   --no-bentos      Skip BentOS binary compile stage (for fast iteration)
# Output: DIR/bentos-rootfs-{arch}.img

DISTRO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Repo root: two levels up from lib/bentos_distro
REPO_ROOT="$(cd "${DISTRO_ROOT}/../.." && pwd)"
TARGET_ARCH="arm64"
OUTPUT_DIR=""
CONFIGS_DIR="${DISTRO_ROOT}/configs"
ALPINE_VERSION="3.21"
ROOTFS_SIZE_MB=256
SKIP_BENTOS=false
CONTAINER_NAME="bentos-rootfs-build"
DART_CONTAINER_NAME="bentos-dart-build"

while [[ $# -gt 0 ]]; do
    case $1 in
        --arch) TARGET_ARCH="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --size) ROOTFS_SIZE_MB="$2"; shift 2 ;;
        --no-bentos) SKIP_BENTOS=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Architecture-specific mappings
case "$TARGET_ARCH" in
    arm64)
        DOCKER_PLATFORM="linux/arm64"
        APK_ARCH="aarch64"
        RUST_TARGET="aarch64-unknown-linux-musl"
        RUST_LINKER="aarch64-linux-musl-gcc"
        CARGO_TARGET_ENV="CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"
        CC_TARGET_ENV="CC_aarch64_unknown_linux_musl"
        ROOTFS_OUTPUT="bentos-rootfs-arm64.img"
        CONSOLE_DEVICE="hvc0"
        ;;
    amd64)
        DOCKER_PLATFORM="linux/amd64"
        APK_ARCH="x86_64"
        RUST_TARGET="x86_64-unknown-linux-musl"
        RUST_LINKER="x86_64-linux-musl-gcc"
        CARGO_TARGET_ENV="CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER"
        CC_TARGET_ENV="CC_x86_64_unknown_linux_musl"
        ROOTFS_OUTPUT="bentos-rootfs-amd64.img"
        CONSOLE_DEVICE="ttyS0"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $TARGET_ARCH (use arm64 or amd64)"
        exit 1
        ;;
esac

OUTPUT_DIR="${OUTPUT_DIR:-${DISTRO_ROOT}/output/${TARGET_ARCH}}"
mkdir -p "$OUTPUT_DIR"

# Check kernel modules exist
if [ ! -d "$OUTPUT_DIR/modules/lib/modules" ]; then
    echo "ERROR: Kernel modules not found at $OUTPUT_DIR/modules/lib/modules/"
    echo "Run build-kernel.sh --arch $TARGET_ARCH first."
    exit 1
fi

echo "=== BentOS Rootfs Build (${TARGET_ARCH}) ==="
echo "Alpine version: ${ALPINE_VERSION}"
echo "Docker platform: ${DOCKER_PLATFORM}"
echo "Rootfs size: ${ROOTFS_SIZE_MB}MB"
echo "Output: ${OUTPUT_DIR}"
echo "Skip BentOS: ${SKIP_BENTOS}"

# ---------------------------------------------------------------------------
# Stage 1: Compile BentOS Dart binaries
# ---------------------------------------------------------------------------

BENTOS_BINS_DIR="${OUTPUT_DIR}/bentos-bins"
EXECD_BIN_DIR="${OUTPUT_DIR}/bentos-execd-bin"

# ---------------------------------------------------------------------------
# Stage 1.5: Compile bentos-execd Rust binary (musl static)
# ---------------------------------------------------------------------------

EXECD_SRC="${REPO_ROOT}/lib/bentos_execd"

if [ "$SKIP_BENTOS" = "false" ]; then
    echo ""
    echo "--- Stage 1.5: Compiling bentos-execd (${TARGET_ARCH} musl) ---"

    if [ ! -f "${EXECD_SRC}/Cargo.toml" ]; then
        echo "ERROR: lib/bentos_execd/Cargo.toml not found at ${EXECD_SRC}"
        exit 1
    fi

    mkdir -p "$EXECD_BIN_DIR"

    # Compile on the host using the installed musl toolchain.
    # On native arch (arm64 on Apple Silicon, amd64 on x86_64 runner),
    # this compiles natively with musl libc for a static binary.
    (cd "${EXECD_SRC}" && \
        export "${CARGO_TARGET_ENV}=${RUST_LINKER}" && \
        export "${CC_TARGET_ENV}=${RUST_LINKER}" && \
        cargo build --target "$RUST_TARGET" --release 2>&1)

    EXECD_BIN="${EXECD_SRC}/target/${RUST_TARGET}/release/bentos-execd"
    if [ ! -f "$EXECD_BIN" ]; then
        echo "ERROR: bentos-execd binary not found at ${EXECD_BIN}"
        exit 1
    fi

    cp "$EXECD_BIN" "$EXECD_BIN_DIR/bentos-execd"
    echo "bentos-execd compiled:"
    ls -lh "$EXECD_BIN_DIR/"
else
    echo ""
    echo "--- Stage 1.5: Skipping bentos-execd compile (--no-bentos) ---"
    mkdir -p "$EXECD_BIN_DIR"
fi

if [ "$SKIP_BENTOS" = "false" ]; then
    echo ""
    echo "--- Stage 1: Compiling BentOS Dart binaries (${TARGET_ARCH}) ---"

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

    # Use official Dart image on target platform.
    # Mount the repo root read-only as /src; copy the needed packages to a
    # writable /build directory so dart pub get can write .dart_tool/.
    # dart compile exe produces a self-contained AOT binary (embeds Dart runtime).
    docker run --rm \
        --name "$DART_CONTAINER_NAME" \
        --platform "$DOCKER_PLATFORM" \
        -v "${REPO_ROOT}":/src:ro \
        -v "${BENTOS_BINS_DIR}":/output \
        dart:stable \
        /bin/sh -c '
set -e

echo "Copying workspace to writable build dir..."
mkdir -p /build/lib
cp -r /src/lib/bentosd /build/lib/
cp -r /src/lib/bentos_fuse /build/lib/
cp -r /src/lib/bentos-driver-sdk-dart /build/lib/

# Stub out all other workspace members so pub can resolve without them.
# We list only the packages we care about in a minimal workspace pubspec.
cat > /build/pubspec.yaml << "PUBSPEC"
name: bentos_build
environment:
  sdk: "^3.5.0"
workspace:
  - lib/bentosd
  - lib/bentos_fuse
  - lib/bentos-driver-sdk-dart
PUBSPEC

cd /build
echo "Resolving dependencies..."
dart pub get

echo "Compiling bentosd..."
dart compile exe lib/bentosd/bin/bentosd.dart -o /output/bentosd

echo "Compiling bentos..."
dart compile exe lib/bentosd/bin/bentos.dart -o /output/bentos

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
IMG="/output/${ROOTFS_OUTPUT}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-256}"
SKIP_BENTOS="${SKIP_BENTOS:-false}"
APK_ARCH="${APK_ARCH}"
CONSOLE_DEVICE="${CONSOLE_DEVICE}"
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

echo "--- Installing Alpine base packages (${APK_ARCH}) ---"
apk --root "$ROOTFS" --initdb --arch "$APK_ARCH" \
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
# /etc/modules intentionally omitted — kernel is all-builtin, no modprobe at boot.

mkdir -p "$ROOTFS/etc/network"
cp /configs/etc/network/interfaces "$ROOTFS/etc/network/interfaces"

# DNS (not in configs/ — generated)
echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"

# Inittab — getty on architecture-appropriate console device
# arm64 (VZ.fw): hvc0 (virtio-console)
# amd64 (Cloud Hypervisor): ttyS0 (serial console)
cat > "$ROOTFS/etc/inittab" << EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
${CONSOLE_DEVICE}::respawn:/sbin/getty 38400 ${CONSOLE_DEVICE}
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

echo "--- Kernel modules: skipped (all-builtin kernel) ---"
# Custom kernel ships everything we need as =y. No /lib/modules in rootfs,
# no kmod package, no depmod, no /etc/modules. If a future driver needs to
# be loadable at runtime, restore selective install here.

echo "--- Installing BentOS binaries ---"
if [ "$SKIP_BENTOS" = "false" ] && [ -f /bentos-bins/bentosd ]; then
    install -m 0755 /bentos-bins/bentosd "$ROOTFS/usr/bin/bentosd"
    install -m 0755 /bentos-bins/bentos  "$ROOTFS/usr/bin/bentos"
    echo "Installed: /usr/bin/bentosd ($(du -h /bentos-bins/bentosd | cut -f1))"
    echo "Installed: /usr/bin/bentos ($(du -h /bentos-bins/bentos | cut -f1))"
else
    echo "Skipping BentOS binaries (--no-bentos or binaries not found)"
fi

echo "--- Installing bentos-execd binary and OpenRC service ---"
if [ "$SKIP_BENTOS" = "false" ] && [ -f /execd-bin/bentos-execd ]; then
    mkdir -p "$ROOTFS/usr/sbin"
    install -m 0755 /execd-bin/bentos-execd "$ROOTFS/usr/sbin/bentos-execd"
    echo "Installed: /usr/sbin/bentos-execd ($(du -h /execd-bin/bentos-execd | cut -f1))"
else
    echo "Skipping bentos-execd binary (--no-bentos or binary not found)"
fi

if [ -f /configs/etc/init.d/bentos-execd ]; then
    install -m 0755 /configs/etc/init.d/bentos-execd "$ROOTFS/etc/init.d/bentos-execd"
    echo "Installed: /etc/init.d/bentos-execd"
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
# 'modules' OpenRC service intentionally omitted — kernel is all-builtin.
chroot "$ROOTFS" rc-update add sysctl boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add hostname boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add bootmisc boot 2>/dev/null || true
chroot "$ROOTFS" rc-update add syslog boot 2>/dev/null || true

chroot "$ROOTFS" rc-update add networking default 2>/dev/null || true
chroot "$ROOTFS" rc-update add sshd default 2>/dev/null || true

if [ -f "$ROOTFS/etc/init.d/bentos-execd" ] && [ "$SKIP_BENTOS" = "false" ]; then
    chroot "$ROOTFS" rc-update add bentos-execd default 2>/dev/null || true
    echo "Enabled: bentos-execd in default runlevel"
fi

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
    --platform "$DOCKER_PLATFORM" \
    --privileged \
    -e "ROOTFS_SIZE_MB=${ROOTFS_SIZE_MB}" \
    -e "SKIP_BENTOS=${SKIP_BENTOS}" \
    -e "APK_ARCH=${APK_ARCH}" \
    -e "CONSOLE_DEVICE=${CONSOLE_DEVICE}" \
    -e "ROOTFS_OUTPUT=${ROOTFS_OUTPUT}" \
    -v /tmp/bentos-rootfs-build.sh:/build.sh:ro \
    -v "$OUTPUT_DIR":/output \
    -v "$OUTPUT_DIR/modules":/modules:ro \
    -v "$CONFIGS_DIR":/configs:ro \
    -v "$BENTOS_BINS_DIR":/bentos-bins:ro \
    -v "$EXECD_BIN_DIR":/execd-bin:ro \
    alpine:${ALPINE_VERSION} \
    /bin/sh /build.sh

echo ""
echo "=== Output ==="
ls -la "$OUTPUT_DIR"/${ROOTFS_OUTPUT} 2>/dev/null && echo "Rootfs image ready." || echo "ERROR: Rootfs image not found"
