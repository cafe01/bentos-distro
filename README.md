# bentos-distro

Build system for BentOS machine images. Takes Alpine packages + BentOS binaries + config files and produces two files per architecture: a kernel image and a root filesystem. These are what `bentos-vmm-*` daemons boot.

## What It Produces

```
output/
+-- arm64/
|   +-- bentos-kernel-arm64.gz        Kernel for VZ.fw (bentos-vmm-macos)
|   +-- bentos-rootfs-arm64.img       ext4 rootfs (golden image)
+-- x86_64/
    +-- bentos-kernel-x86_64.bzImage  Kernel for Cloud Hypervisor (bentos-vmm-linux)
    +-- bentos-rootfs-x86_64.img      ext4 rootfs (golden image)
```

Each pair is a complete machine. The VMM loads the kernel and presents the rootfs as a virtio-blk disk. Track E starts with ARM64 (macOS development on Apple Silicon). x86-64 follows when bentos-vmm-linux is built.

## Architecture

A BentOS machine image has two mandatory components:

### Kernel Image

Custom Linux kernel compiled from Alpine's `linux-virt` source with BentOS-specific config changes. The delta from stock `linux-virt` is small:

| Config | Setting | Why |
|--------|---------|-----|
| `CONFIG_FUSE_FS` | `=y` (built-in) | Load-bearing. bentosd depends on it. Must be immediate. |
| `CONFIG_CUSE` | `=m` (module) | Device nodes in `/dev/`. Loaded after boot via `/etc/modules`. |
| `CONFIG_VIRTIO_VSOCK` | `=y` (built-in) | Guest-to-host control plane (bentosd <-> bentos-vmm-*). |
| `CONFIG_VIRTIO_FS` | `=m` (module) | Host filesystem sharing via virtiofs. Optional, loaded on demand. |

Everything else inherited from `linux-virt`: virtio drivers (blk, net, console, rng), namespaces, cgroups, seccomp, overlayfs, ext4. Physical hardware drivers stripped.

| Property | ARM64 | x86-64 |
|----------|-------|--------|
| Source | Alpine `linux-virt` | Alpine `linux-virt` |
| Format | Uncompressed `Image` or `Image.gz` | `bzImage` |
| VMM loads via | `VZLinuxBootLoader(kernelURL:)` | `cloud-hypervisor --kernel` |
| Virtio transport | MMIO | PCI |
| Size | ~5-10 MB | ~5-10 MB |

### Root Filesystem

ext4 disk image containing everything that makes a machine BentOS. Built by running `apk` against a target directory, copying BentOS binaries, and applying config.

**Bill of materials by subsystem:**

| Subsystem | Packages / Components | Size |
|-----------|----------------------|------|
| Alpine base | musl, BusyBox, apk-tools, OpenRC | ~6 MB |
| System packages | bash, shadow, openssh-server, sudo, networking, ifupdown | ~5 MB |
| Kernel modules | cuse.ko, virtiofs.ko in `/lib/modules/` | ~1-2 MB |
| BentOS binaries | bentosd, bentos-agent (Dart AOT), bentos CLI | ~30-50 MB |
| Container runtime | containerd, runc | ~30-40 MB |
| Config + user homes | /etc/*, /home/alfred/, /etc/skel/ | <1 MB |
| **Total** | | **~70-100 MB** |

**What's NOT in the rootfs:** No compilers, no dev tools, no desktop software, no GUI, no databases, no web servers, no man pages, no pre-attached devices. The machine starts closed.

## Rootfs Composition

### Package Layer (Alpine)

```
alpine-base          musl + BusyBox + apk-tools + Alpine config
bash                 Agent login shell (LLMs expect bash)
openssh-server       Console sessions into the machine
shadow               useradd, usermod, chfn — full POSIX user tools
sudo                 Controlled privilege escalation
networking           virtio-net interface configuration
ifupdown             Interface up/down scripts
musl-utils           ldd, getent, getconf
fuse3                FUSE/CUSE kernel interface (bentosd FFI dependency)
containerd           Container runtime for driver processes
runc                 OCI container executor
busybox-initscripts  Boot-time scripts (mount /proc, /sys, /dev)
bsd-finger           Agent discovery (finger, fingerd)
```

### BentOS Layer

| File | What |
|------|------|
| `/usr/bin/bentosd` | Device/driver orchestration daemon (Dart AOT) |
| `/usr/bin/bentos-agent` | Agent executable (Dart AOT) |
| `/usr/bin/bentos` | CLI client to bentosd |

### Init Configuration (OpenRC)

| File | What |
|------|------|
| `/etc/init.d/bentosd` | OpenRC service with `supervise-daemon`, depends on `net` |
| `/etc/init.d/bentos-agent.*` | Per-agent service, depends on `bentosd` |
| `/etc/init.d/containerd` | Container runtime service |
| `/etc/modules` | `cuse` — loaded at boot by the modules service |
| `/etc/runlevels/default/` | Symlinks enabling bentosd, agents, sshd, containerd |

### User Model

| File | What |
|------|------|
| `/etc/passwd` | System users + pre-configured agents (alfred) |
| `/etc/shadow` | Password hashes (agents: locked — `!` or `*`) |
| `/etc/group` | Groups: `agents`, `bentos`, `fuse` |
| `/etc/skel/.bashrc` | Agent shell configuration |
| `/etc/skel/.profile` | Agent environment |
| `/etc/skel/.plan` | finger plan file (empty) |
| `/etc/skel/.project` | finger project file (empty) |
| `/etc/skel/.mem/` | Memory graph root |
| `/etc/skel/office/` | Agent workspace |
| `/home/alfred/` | Pre-forged agent home (from skel) |

### System Configuration

| File | What |
|------|------|
| `/etc/bentos/config.yaml` | bentosd configuration (defaults) |
| `/etc/network/interfaces` | `eth0` via DHCP (virtio-net) |
| `/etc/hostname` | Machine identity (overridden per instance) |
| `/etc/hosts` | Localhost resolution |
| `/etc/resolv.conf` | DNS (host-provided) |
| `/etc/bentos-release` | Image version, Alpine version, kernel version, build date, image hash |

## Baked vs. Runtime

| Baked into the image | Configured at boot/runtime |
|---------------------|---------------------------|
| All Alpine packages | Network IP address (DHCP) |
| BentOS binaries | SSH host keys (generated at first boot) |
| OpenRC service definitions | Machine-specific hostname |
| `/etc/skel/` template | Agent SSH authorized_keys |
| `/etc/passwd` (system + pre-configured agents) | Runtime agent creation (`useradd`) |
| Kernel modules | Device attachments (`bentos device attach`) |
| `/etc/bentos/config.yaml` (defaults) | Per-machine config overrides |

The image is a template. Many machines boot from it. Runtime config makes each instance unique.

## Per-Architecture Build

Same package list, same config files, different binaries:

| | ARM64 (macOS) | x86-64 (Linux/hosted) |
|---|---|---|
| Alpine packages | aarch64 binaries | x86_64 binaries |
| Dart AOT binaries | ARM64 target | x86-64 target |
| Kernel defconfig | `arch/arm64/configs/bentos_defconfig` | `arch/x86/configs/bentos_defconfig` |
| Kernel output | `Image` or `Image.gz` | `bzImage` |

Config files are architecture-independent. The build pipeline maintains one set of configs and injects per-arch binaries.

## Boot Sequence (what happens after VMM starts the machine)

```
1. VMM loads kernel + presents rootfs as /dev/vda
2. Kernel boots:
   - Probes virtio bus (blk, net, console, vsock, entropy)
   - Mounts /dev/vda as root (ext4)
   - Starts /sbin/init (OpenRC)
3. OpenRC sysinit:
   - Mount /proc, /sys, /dev, /run
   - Set hostname
4. OpenRC boot:
   - Load modules from /etc/modules (cuse.ko)
   - Configure networking (eth0 via DHCP on virtio-net)
5. OpenRC default:
   - Start containerd
   - Start bentosd (supervised, depends on net)
   - Start sshd
   - Start bentos-agent.alfred (supervised, depends on bentosd, runs as user alfred)
6. bentosd:
   - Opens FUSE/CUSE kernel interface
   - Connects vsock to bentos-vmm-* on port 5000
   - Waits for device attach commands
7. Machine is running. Agents are inhabiting. /dev/ is empty. Starts closed.
```

From `vm.start()` to bentosd connected: under 2 seconds on Apple Silicon.

## Key References

| Document | What it covers |
|----------|---------------|
| `university/cs/linux-distros/lessons/06-the-kernel.md` | Kernel config: what's built-in, what's module, what's excluded |
| `university/cs/linux-distros/lessons/07-the-decision.md` | Why Alpine won (evidence-based, revised from Debian) |
| `university/cs/linux-distros/lessons/09-from-distro-to-machine-image.md` | Full BOM, build pipeline, per-arch, boot sequence |
| `university/cs/linux-distros/lessons/05-base-system.md` | Base packages, BusyBox vs GNU, FHS layout |
| `university/cs/linux-distros/lessons/08-user-management.md` | Agent user model, GECOS, groups, skel, presence |
| `university/cs/linux-distros/lessons/03-init-systems.md` | OpenRC, service supervision, boot sequence |
| `university/cs/apple-virtualization/lessons/12-the-boot-pipeline.md` | Boot pipeline from VMM perspective, bundled:// convention |
| `hq/console-virtualization-intel.md` | Guest stack architecture, VMM abstraction layer |
