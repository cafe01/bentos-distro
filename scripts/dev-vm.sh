#!/bin/bash
# dev-vm.sh — boot a BentOS distro image in vfkit for development.
#
# Codifies the vfkit invocation that turns kernel + rootfs (from output/{arch}/)
# into a running Linux VM on macOS. Used for bentosd dev loops on Apple Silicon:
# OrbStack lacked FUSE/CUSE, so we run our own distro on vfkit (Apple's
# Virtualization.framework CLI — same layer as lib/bentos_vmm_macos, but
# the working third-party version).
#
# Usage:
#   ./scripts/dev-vm.sh                          # arm64, defaults from output/
#   ./scripts/dev-vm.sh --arch arm64
#   ./scripts/dev-vm.sh --mount-workspace        # virtiofs mount of repo root
#   ./scripts/dev-vm.sh --memory 2048 --cpus 4
#   KERNEL=path ROOTFS=path ./scripts/dev-vm.sh  # override via env
#
# Inside the VM:
#   - login: root / bentos
#   - bentos workspace (with --mount-workspace) at /workspace
#   - SSH: VM gets a DHCP address on the vfkit NAT bridge; from host
#     `ssh root@<vm-ip>` once you've set up keys.
#
# Console: vfkit attaches stdio. Ctrl-A x to exit (vfkit's serial handler),
# or `poweroff` from inside the VM.
#
# Prereq: brew install vfkit. Kernel + rootfs from `make arm64` in this dir.

set -euo pipefail

# --- defaults ----------------------------------------------------------------
ARCH="arm64"
CPUS="2"
MEMORY="1024"
MOUNT_WORKSPACE="false"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DISTRO_DIR/../.." && pwd)"

# --- args --------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)             ARCH="$2"; shift 2 ;;
        --cpus)             CPUS="$2"; shift 2 ;;
        --memory)           MEMORY="$2"; shift 2 ;;
        --mount-workspace)  MOUNT_WORKSPACE="true"; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- locate artifacts --------------------------------------------------------
OUT_DIR="$DISTRO_DIR/output/$ARCH"
KERNEL="${KERNEL:-$OUT_DIR/bentos-kernel-$ARCH}"
ROOTFS="${ROOTFS:-$OUT_DIR/bentos-rootfs-$ARCH.img}"

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: kernel not found at $KERNEL" >&2
    echo "  Build it: (cd $DISTRO_DIR && make kernel-$ARCH)" >&2
    exit 1
fi
if [ ! -f "$ROOTFS" ]; then
    echo "ERROR: rootfs not found at $ROOTFS" >&2
    echo "  Build it: (cd $DISTRO_DIR && make rootfs-$ARCH)" >&2
    exit 1
fi

command -v vfkit >/dev/null 2>&1 || {
    echo "ERROR: vfkit not installed. Run: brew install vfkit" >&2; exit 1; }

# --- working dir for ephemeral artifacts -------------------------------------
WORK_DIR="${TMPDIR:-/tmp}/bentos-dev-vm"
mkdir -p "$WORK_DIR"

# vfkit currently requires an initrd (its Go binding passes it unconditionally
# to the VZ.framework Linux bootloader). With an all-builtin kernel we don't
# need it functionally — a 1-byte stub satisfies the API.
INITRD="$WORK_DIR/initrd.stub"
if [ ! -f "$INITRD" ]; then
    printf '' | gzip -c > "$INITRD"
fi

# vfkit operates on the rootfs in-place. Copy to a working file so re-runs
# don't accumulate state in output/ (which is also CI-built and gitignored).
WORK_ROOTFS="$WORK_DIR/rootfs-$ARCH.img"
if [ ! -f "$WORK_ROOTFS" ] || [ "$ROOTFS" -nt "$WORK_ROOTFS" ]; then
    echo "--- Copying rootfs to working dir (preserves output/ as immutable artifact) ---"
    cp "$ROOTFS" "$WORK_ROOTFS"
fi

# --- kernel cmdline ----------------------------------------------------------
# arm64 (VZ.fw): console is hvc0 (virtio-console). Kernel mounts /dev/vda ext4.
# All drivers needed (virtio_blk, ext4, virtio_net, virtio_console) are =y.
CMDLINE="console=hvc0 root=/dev/vda rw rootfstype=ext4 quiet"

# --- assemble vfkit invocation ----------------------------------------------
VFKIT_ARGS=(
    --cpus "$CPUS"
    --memory "$MEMORY"
    --bootloader "linux,kernel=$KERNEL,initrd=$INITRD,cmdline=\"$CMDLINE\""
    --device "virtio-blk,path=$WORK_ROOTFS"
    --device "virtio-net,nat"
    --device "virtio-rng"
    --device "virtio-vsock,port=5100,socketURL=$WORK_DIR/vsock-5100.sock"
    --device "virtio-serial,stdio"
)

if [ "$MOUNT_WORKSPACE" = "true" ]; then
    VFKIT_ARGS+=(--device "virtio-fs,sharedDir=$REPO_ROOT,mountTag=workspace")
    echo "--- workspace mount: $REPO_ROOT  ->  mount tag 'workspace'"
    echo "    inside VM: mkdir -p /workspace && mount -t virtiofs workspace /workspace"
fi

echo "--- BentOS dev VM (vfkit) ---"
echo "  arch:    $ARCH"
echo "  kernel:  $KERNEL"
echo "  rootfs:  $WORK_ROOTFS  (working copy)"
echo "  cpus:    $CPUS"
echo "  memory:  $MEMORY MiB"
echo "  vsock:   $WORK_DIR/vsock-5100.sock  (bentos-execd)"
echo "  cmdline: $CMDLINE"
echo
echo "  login: root / bentos   |   exit: Ctrl-A x  (or 'poweroff' inside)"
echo

exec vfkit "${VFKIT_ARGS[@]}"
