# bentos-distro

<!-- CI badge: add when GitHub Actions workflow ships (Track E — Distro CI Pipeline) -->

BentOS machine image build system and release pipeline. Produces bootable Linux images (kernel + rootfs) for BentOS virtual machines — the substrate that AI agents inhabit.

## What It Is

bentos-distro is the **release pipeline** for BentOS machine images. It takes Alpine Linux packages, a custom kernel config, and BentOS binaries (bentosd, bentos-execd) and produces two artifacts per architecture: a kernel image and an ext4 root filesystem. These are what `bentos-vmm-*` daemons boot.

The end state: CI-built, versioned images published as GitHub Releases. VMM backends download images on demand — like Docker pulling base images. bentos-distro is not a local build tool that ships with the product; it is the factory that produces the product.

## What It Produces

```
output/
+-- arm64/
|   +-- bentos-kernel-arm64           Kernel Image for VZ.fw (bentos-vmm-macos)
|   +-- bentos-rootfs-arm64.img       ext4 rootfs (golden image)
+-- x86_64/                           (planned)
    +-- bentos-kernel-x86_64.bzImage  Kernel for Cloud Hypervisor (bentos-vmm-linux)
    +-- bentos-rootfs-x86_64.img      ext4 rootfs (golden image)
```

Each pair is a complete machine. The VMM loads the kernel and presents the rootfs as a virtio-blk disk. ARM64 (macOS on Apple Silicon) is built and tested. x86-64 follows when bentos-vmm-linux ships.

## Current State

| Milestone | Status | What |
|-----------|--------|------|
| M0 — Kernel | Done | ARM64 kernel from Alpine linux-virt source, BentOS config applied |
| M1 — Rootfs | Done | Alpine base + system packages + kernel modules |
| M2 — Kernel Modules | Done | Selective module install (CUSE, virtiofs, vsock) with depmod |
| M3 — BentOS Binaries | Done | bentosd 7.0MB + bentos 6.4MB ARM64 AOT in rootfs, fuse3-libs, OpenRC service. S310 |
| M6 — bentos-execd | Done | Rust binary baked into rootfs, OpenRC service at default runlevel. S313. (M4-M5 are bentos-vmm-macos milestones, not distro — numbering follows Track E sequence) |
| CI Pipeline | Planned | GitHub Actions building both architectures on push |
| amd64 Support | Planned | x86-64 kernel + rootfs for bentos-vmm-linux |
| Image Versioning | Planned | Semantic versions, published as GitHub Releases |
| Initramfs | Planned | Replace `/etc/modules` workaround with proper initramfs |

## Architecture

### Build Pipeline

Three scripts, one orchestrator:

| Script | What It Does |
|--------|-------------|
| `scripts/build-kernel.sh` | Builds ARM64 kernel inside Docker from Alpine linux-virt source. Applies BentOS config (FUSE built-in, CUSE module, VIRTIO_VSOCK built-in, virtiofs module). Outputs kernel Image + modules. |
| `scripts/build-rootfs.sh` | Two-stage build. Stage 1: cross-compiles bentos-execd (Rust/musl) and bentosd (Dart AOT) for ARM64. Stage 2: assembles ext4 rootfs in Docker — Alpine packages, kernel modules, BentOS binaries, system config. |
| `scripts/build-image.sh` | Orchestrator. Runs kernel then rootfs in sequence. |

All builds run inside Docker containers on `linux/arm64` for reproducibility. The host (macOS) never touches the target filesystem directly.

```
Makefile targets:
  make arm64          # full build (kernel + rootfs)
  make kernel-arm64   # kernel only
  make rootfs-arm64   # rootfs only (requires kernel built first)
  make clean          # remove output/
```

### Dependency Chain

```
bentos-execd (Rust)  --->  build-rootfs.sh  --->  rootfs image
bentosd (Dart AOT)   --->       |
bentos (Dart AOT)    --->       |
                                |
build-kernel.sh  ---> kernel image + modules ---> build-rootfs.sh
                                                   (modules go into rootfs)
```

Kernel must build before rootfs — the rootfs needs kernel modules from the kernel build.

### Release Pipeline (Target Architecture)

Each upstream package (bentos-execd, bentosd) has its own repo and CI. When upstream CI succeeds, it sends a `repository_dispatch` event to bentos-distro, triggering an image rebuild with the latest binaries:

```
[bentos-execd CI succeeds] --repository_dispatch--\
                                                   +--> [bentos-distro CI] --> build kernel + rootfs
[bentosd CI succeeds] -------repository_dispatch--/            |                 (arm64 + amd64)
                                                               |
                                                               v
                                                      [GitHub Releases]
                                                        bentos-alpine-6.12-arm64-20260327-42.tar.gz
                                                        bentos-alpine-6.12-amd64-20260327-42.tar.gz
                                                               |
                                                               v
                                                    [bentos-vmm-* backends]
                                                      download on demand
```

Cross-repo trigger: upstream repo CI posts `repository_dispatch` to bentos-distro on success. bentos-distro CI rebuilds the image and publishes as versioned GitHub Releases.

### VMM Image Consumption (Target Architecture)

VMM backends do **not** ship with images baked in. They download versioned images from GitHub Releases on demand:

```
bentos-vmm images list              # list available versions from GitHub Releases
bentos-vmm images pull v0.1.0       # download kernel + rootfs to ~/.bentos/images/
bentos-vmm images current           # show what's cached locally
```

Machine creation references an image via standard URI schemes:

```
# Dev mode (bundled next to binary):
POST /machines { boot: "bundled://bentos-arm64-Image" }

# Local filesystem (explicit path):
POST /machines { boot: "file:///Users/me/.bentos/images/bentos-alpine-6.12-arm64-20260327-42/kernel" }

# Remote download (GitHub Releases):
POST /machines { boot: "https://github.com/anthropics/bentos/releases/download/build-42/bentos-alpine-6.12-arm64-20260327-42.tar.gz" }
```

The `boot` config in `BentosVmConfig` accepts `bundled://`, `file://`, or `https://` URIs. No custom URI scheme — standard protocols cover all cases. `bentos-vmm images pull` downloads from HTTPS into local cache (`~/.bentos/images/`), and `boot` resolves from cache via version string or explicit `file://` path.

## Image Contents

### Kernel

Custom Linux kernel compiled from Alpine's `linux-virt` source. The delta from stock is small:

| Config | Setting | Why |
|--------|---------|-----|
| `CONFIG_FUSE_FS` | `=y` (built-in) | bentosd depends on FUSE. Must be immediate at boot. |
| `CONFIG_CUSE` | `=m` (module) | Device nodes in `/dev/`. Loaded after boot via `/etc/modules`. |
| `CONFIG_VIRTIO_VSOCK` | `=y` (built-in) | Guest-to-host control plane (bentosd <-> bentos-vmm-*). |
| `CONFIG_VIRTIO_FS` | `=m` (module) | Host filesystem sharing via virtiofs. Loaded on demand. |

Everything else inherited from `linux-virt`: virtio drivers (blk, net, console, rng), namespaces, cgroups, seccomp, overlayfs, ext4. Physical hardware drivers stripped.

| Property | ARM64 | x86-64 (planned) |
|----------|-------|--------|
| Source | Alpine `linux-virt` | Alpine `linux-virt` |
| Format | Uncompressed `Image` | `bzImage` |
| VMM loads via | `VZLinuxBootLoader(kernelURL:)` | `cloud-hypervisor --kernel` |
| Virtio transport | MMIO | PCI |
| Size | ~19 MB | ~5-10 MB |

### Root Filesystem

ext4 disk image (~38 MB after shrink). Contains everything that makes a machine BentOS.

**Alpine base layer:**

```
alpine-base          musl + BusyBox + apk-tools + Alpine config
bash                 Agent login shell (LLMs expect bash)
openssh-server       Console sessions into the machine
shadow               useradd, usermod — full POSIX user tools
sudo                 Controlled privilege escalation
musl-utils           ldd, getent, getconf
fuse3                FUSE/CUSE kernel interface
```

**BentOS layer:**

| Binary | Location | What |
|--------|----------|------|
| bentos-execd | `/usr/sbin/bentos-execd` | Exec-over-vsock guest agent (528 KB Rust static binary) |
| bentosd | `/usr/bin/bentosd` | Device/driver orchestration daemon (Dart AOT) |
| bentos | `/usr/bin/bentos` | Guest-side CLI client to bentosd (Dart AOT) |

**Kernel modules** (selectively installed, not the full tree):

```
cuse.ko.gz                              CUSE device nodes
virtiofs.ko.gz                          Host filesystem sharing
vsock.ko.gz + virtio transport modules  Guest-host communication
```

**Init (OpenRC):**

| Service | Runlevel | What |
|---------|----------|------|
| bentos-execd | default | Exec agent on vsock — runs before bentosd and networking |
| bentosd | default | Device daemon, depends on net |
| sshd | default | SSH access |
| networking | default | eth0 via DHCP on virtio-net |
| modules | boot | Loads `cuse` from `/etc/modules` |

**What's NOT in the rootfs:** No compilers, no dev tools, no GUI, no databases, no web servers. The machine starts closed.

### Config Files

System config lives in `configs/` — the single source of truth for everything baked into the rootfs:

```
configs/
+-- etc/
    +-- hostname              Machine identity (overridden per instance)
    +-- hosts                 Localhost resolution
    +-- modules               Kernel modules to load at boot (cuse)
    +-- securetty             Secure TTY list
    +-- network/
    |   +-- interfaces        eth0 via DHCP
    +-- init.d/
        +-- bentos-execd      OpenRC service for exec agent
        +-- bentosd           OpenRC service for device daemon
```

## Building Locally

**Prerequisites:** Docker (with `linux/arm64` platform support — native on Apple Silicon, QEMU on x86).

### Full Image Build

```bash
cd lib/bentos_distro

# Build everything: kernel + rootfs (includes bentos-execd and bentosd compilation)
bash scripts/build-image.sh

# Or via Make
make arm64
```

### Individual Steps

```bash
# Kernel only (must run first — rootfs depends on modules)
bash scripts/build-kernel.sh

# Rootfs only (requires kernel modules in output/arm64/modules/)
bash scripts/build-rootfs.sh

# Rootfs without BentOS binaries (fast iteration on Alpine config)
bash scripts/build-rootfs.sh --no-bentos

# Custom output directory
bash scripts/build-image.sh --output /tmp/bentos-build

# Custom rootfs size
bash scripts/build-rootfs.sh --size 512
```

### Build Requirements for BentOS Binaries

The rootfs build compiles BentOS binaries inside Docker:

- **bentos-execd**: Requires Rust with `aarch64-unknown-linux-musl` target and musl-cross linker on the host (cross-compiled outside Docker).
- **bentosd / bentos**: Compiled inside a `dart:stable` Docker container targeting `linux/arm64`.

Use `--no-bentos` to skip binary compilation when iterating on the base image.

### Output

```bash
output/arm64/
+-- bentos-kernel-arm64          # Kernel Image (~19 MB)
+-- bentos-rootfs-arm64.img      # ext4 rootfs (~38 MB)
+-- bentos_defconfig_full        # Full kernel .config for reference
+-- modules/                     # Kernel modules (consumed by rootfs build)
+-- bentos-bins/                 # Dart AOT binaries (intermediate)
+-- bentos-execd-bin/            # Rust binary (intermediate)
```

## Boot Sequence

What happens after `bentos-vmm-macos` starts a machine with these artifacts:

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
   - Start bentos-execd (vsock listener on port 5100)
   - Start bentosd (FUSE/CUSE + vsock to host)
   - Start sshd
6. Machine is running. /dev/ is empty. Starts closed.
```

From `vm.start()` to bentos-execd connected: under 2 seconds on Apple Silicon.

## What's Next

- **CI Pipeline**: GitHub Actions workflow building arm64 images. Triggered by `repository_dispatch` from upstream bentos-execd and bentosd repo CIs.
- **amd64 Support**: x86-64 kernel (`bzImage`) + rootfs for bentos-vmm-linux (Cloud Hypervisor backend).
- **Image Versioning**: Content-descriptive naming: `bentos-alpine-6.12-arm64-20260327-42.tar.gz` (distro + kernel + arch + date + build). GitHub Release tag = build key. Filename IS the metadata.
- **VMM Image Management**: `bentos-vmm images list/pull/current` — backends download images from releases instead of requiring local builds.
- **Initramfs**: Replace the `/etc/modules` workaround with a proper initramfs for cleaner module loading.
- **Full BentOS Rootfs**: Container runtime (containerd + runc), agent user model (`/etc/skel/`, `/home/alfred/`), `bentos-agent` binary.
