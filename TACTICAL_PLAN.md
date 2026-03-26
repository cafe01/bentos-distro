# bentos-distro: Tactical Plan

> Implementor: John (SWE)
> Owner: Cafe (CTO)
> Status: M0+M1+M2 complete (S309)
> Blocks: bentos-vmm-macos M3 (boot a VM) — needs kernel + rootfs artifacts

Two outputs: (1) ARM64 kernel image, (2) ARM64 rootfs image.
Goal: `bentos-vmm-macos` boots a real BentOS machine from these artifacts.

x86-64 deferred until bentos-vmm-linux exists.

---

## Milestones

### M0: Kernel — ARM64 Image

Build a bootable ARM64 Linux kernel from Alpine's `linux-virt` with BentOS config changes.

- [x] **M0.1** Obtain Alpine `linux-virt` kernel source and config
  - Alpine packages the config as `linux-virt` in their aports tree
  - Clone aports or extract config from an existing Alpine `linux-virt` package
  - Identify the kernel version (currently 6.12.x LTS branch)
- [x] **M0.2** Create `bentos_defconfig` for ARM64
  - Start from Alpine's `linux-virt` ARM64 config
  - Apply BentOS changes:

  | Option | From | To | Why |
  |--------|------|----|-----|
  | `CONFIG_FUSE_FS` | `=m` | `=y` | Built-in — bentosd depends on it at boot |
  | `CONFIG_CUSE` | `=n` or absent | `=m` | Module — device model, loaded via /etc/modules |
  | `CONFIG_VIRTIO_VSOCK` | absent or `=m` | `=y` | Built-in — guest-to-host control plane |
  | `CONFIG_VIRTIO_FS` | absent or `=m` | `=m` | Module — virtiofs, loaded on demand |

  - Verify these are already `=y` (should be from `linux-virt`):
    - `CONFIG_VIRTIO=y`, `CONFIG_VIRTIO_PCI=y`, `CONFIG_VIRTIO_MMIO=y`
    - `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_NET=y`, `CONFIG_VIRTIO_CONSOLE=y`
    - `CONFIG_HW_RANDOM_VIRTIO=y`
    - `CONFIG_EXT4_FS=y`, `CONFIG_TMPFS=y`, `CONFIG_DEVTMPFS=y`
    - `CONFIG_NAMESPACES=y`, `CONFIG_CGROUPS=y`, `CONFIG_SECCOMP=y`
    - `CONFIG_OVERLAY_FS=y`
  - Strip anything not needed: USB, sound, GPU/DRM, physical NICs, physical storage, wireless, Bluetooth, input devices, unused filesystems
  - Place at `kernel/arm64/bentos_defconfig`

- [x] **M0.3** Cross-compile the kernel
  - On macOS: use a Docker/OrbStack container with `aarch64-linux-gnu-gcc` cross-compiler
  - Or: build natively on the ARM64 Mac inside an Alpine container
  - ```bash
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bentos_defconfig
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
    ```
  - Output: `arch/arm64/boot/Image` (~5-10 MB)
- [x] **M0.4** Validate the kernel
  - `file arch/arm64/boot/Image` -> shows ARM64 executable
  - Check built-in options: `scripts/config --file .config --state CONFIG_FUSE_FS` -> `y`
  - Check module options: `scripts/config --file .config --state CONFIG_CUSE` -> `m`
  - Save built `.config` as `kernel/arm64/bentos_defconfig_full` for reference

**Validation**: Kernel binary exists, is ARM64, has correct config options. Does not boot yet — needs rootfs.

### M1: Minimal Rootfs — Boot to Login Prompt

Build a rootfs that boots to a login prompt inside VZ.fw. No BentOS binaries yet — just Alpine base + essential services.

- [x] **M1.1** Set up rootfs build environment
  - Docker/OrbStack container with Alpine (ARM64) or `qemu-aarch64-static` for cross-arch `apk`
  - Script: `scripts/build-rootfs.sh --arch arm64 --output output/arm64/bentos-rootfs-arm64.img`
- [x] **M1.2** Create sparse ext4 image
  - ```bash
    truncate -s 512M rootfs.img
    mkfs.ext4 -L bentos-root rootfs.img
    ```
- [x] **M1.3** Install Alpine base packages
  - Mount the image, bootstrap apk:
  - ```bash
    mount -o loop rootfs.img /tmp/rootfs
    apk --root /tmp/rootfs --initdb --arch aarch64 \
        --repository https://dl-cdn.alpinelinux.org/alpine/v3.21/main \
        --repository https://dl-cdn.alpinelinux.org/alpine/v3.21/community \
        add alpine-base bash openssh-server shadow sudo \
            networking ifupdown musl-utils busybox-initscripts openrc
    ```
- [x] **M1.4** Configure essential system files
  - `/etc/hostname` -> `bentos`
  - `/etc/hosts` -> `127.0.0.1 localhost bentos`
  - `/etc/resolv.conf` -> `nameserver 8.8.8.8` (overridden by DHCP)
  - `/etc/network/interfaces`:
    ```
    auto lo
    iface lo inet loopback

    auto eth0
    iface eth0 inet dhcp
    ```
  - `/etc/modules` -> `cuse` (loaded at boot by modules service)
  - `/etc/inittab` -> ensure `ttyS0`/`hvc0` console getty if needed
  - `/etc/securetty` -> add `hvc0` (allow root login on virtio-console)
  - Set root password (or enable autologin on console for dev)
- [x] **M1.5** Enable services in default runlevel
  - ```bash
    chroot /tmp/rootfs rc-update add networking default
    chroot /tmp/rootfs rc-update add sshd default
    chroot /tmp/rootfs rc-update add modules boot
    ```
- [x] **M1.6** Unmount, finalize image
  - ```bash
    umount /tmp/rootfs
    e2fsck -f rootfs.img
    resize2fs -M rootfs.img  # Shrink to minimum (golden image)
    ```

**Validation**: Boot with bentos-vmm-macos (or manual VZ.fw test tool). Kernel boots, OpenRC runs, login prompt appears on console. Network comes up via DHCP.

### M2: Kernel Modules on Rootfs

The kernel modules built in M0 need to be on the rootfs so `modprobe` can load them.

- [x] **M2.1** Extract modules from kernel build
  - ```bash
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install \
        INSTALL_MOD_PATH=/tmp/rootfs
    ```
  - This installs `cuse.ko`, `virtiofs.ko`, and `modules.dep` into `/lib/modules/<version>/`
- [x] **M2.2** Rebuild rootfs image with modules included
  - Mount, copy modules, rebuild depmod, unmount
- [ ] **M2.3** Verify module loading (requires VM boot)
  - Boot the VM
  - `lsmod` shows `cuse` loaded (from `/etc/modules`)
  - `modprobe virtiofs` loads successfully

**Validation**: `lsmod | grep cuse` shows the module. `/dev/cuse` device node exists.

### M3: BentOS Rootfs — Full Bill of Materials

Add BentOS-specific binaries, user model, and service configuration. This is the real distro image.

- [ ] **M3.1** Compile BentOS Dart binaries for ARM64
  - bentosd: `dart compile exe` targeting ARM64 (Dart AOT)
  - bentos-agent: `dart compile exe` targeting ARM64
  - bentos CLI: `dart compile exe` targeting ARM64
  - If cross-compiling is hard: compile natively inside an ARM64 Alpine container
  - Place at `/usr/bin/bentosd`, `/usr/bin/bentos-agent`, `/usr/bin/bentos`
- [ ] **M3.2** Install additional Alpine packages
  - ```bash
    apk --root /tmp/rootfs add fuse3 containerd runc bsd-finger
    ```
- [ ] **M3.3** Create bentosd OpenRC service
  - `/etc/init.d/bentosd`:
    ```sh
    #!/sbin/openrc-run
    name="bentosd"
    description="BentOS device and driver daemon"
    command="/usr/bin/bentosd"
    command_user="bentosd:bentos"
    supervisor="supervise-daemon"
    depend() {
        need net
        after modules
    }
    ```
  - Enable: `rc-update add bentosd default`
- [ ] **M3.4** Create agent OpenRC service template
  - `/etc/init.d/bentos-agent.alfred`:
    ```sh
    #!/sbin/openrc-run
    name="bentos-agent-alfred"
    description="BentOS agent: alfred"
    command="/usr/bin/bentos-agent"
    command_user="alfred:alfred"
    supervisor="supervise-daemon"
    depend() {
        need bentosd
    }
    ```
  - Enable: `rc-update add bentos-agent.alfred default`
- [ ] **M3.5** Set up user model
  - System users:
    ```bash
    chroot /tmp/rootfs addgroup -S bentos
    chroot /tmp/rootfs addgroup -S agents
    chroot /tmp/rootfs addgroup -S fuse
    chroot /tmp/rootfs adduser -S -G bentos -h /var/lib/bentosd -s /sbin/nologin bentosd
    chroot /tmp/rootfs addgroup bentosd fuse
    ```
  - Skel template:
    ```bash
    mkdir -p /tmp/rootfs/etc/skel/{.mem,office}
    # .bashrc, .profile, .plan, .project -> from configs/
    ```
  - Pre-configured agent (alfred):
    ```bash
    chroot /tmp/rootfs adduser -D -G agents -s /bin/bash -g "Alfred,CPO+COO,BentOS,," alfred
    chroot /tmp/rootfs addgroup alfred fuse
    # Copy skel contents to /home/alfred/
    ```
  - Sudoers: agents can run `bentos` CLI commands
- [ ] **M3.6** Create bentosd configuration
  - `/etc/bentos/config.yaml` with sensible defaults
- [ ] **M3.7** Add containerd service
  - Enable: `rc-update add containerd default` (before bentosd)
- [ ] **M3.8** Write `/etc/bentos-release`
  - ```
    BENTOS_VERSION=0.1.0
    BENTOS_BUILD_DATE=<build date>
    ALPINE_VERSION=3.21
    KERNEL_VERSION=<kernel version>
    IMAGE_HASH=sha256:<computed after build>
    ```
- [ ] **M3.9** Finalize and hash the image
  - Unmount, e2fsck, resize2fs -M
  - Compute SHA-256 of rootfs image -> update `/etc/bentos-release` IMAGE_HASH
  - (Chicken-and-egg: either embed hash post-build or accept it as external metadata)

**Validation**: Boot the full image with bentos-vmm-macos. OpenRC starts all services in order: networking -> modules (cuse) -> containerd -> bentosd -> sshd -> bentos-agent.alfred. `finger alfred` shows agent info. `ls /dev/cuse` exists. bentosd opens vsock. Machine is running and inhabited.

### M4: Build Script Automation

Wrap everything into a reproducible build script.

- [ ] **M4.1** `scripts/build-kernel.sh`
  - Inputs: arch (arm64 | x86_64), defconfig path
  - Outputs: kernel image + modules tarball
  - Runs inside a Docker container for reproducibility
  - Pins Alpine repo version (date-based snapshot)
- [ ] **M4.2** `scripts/build-rootfs.sh`
  - Inputs: arch, kernel modules tarball, BentOS binaries directory
  - Outputs: ext4 rootfs image
  - Pins Alpine repo version (same as kernel)
  - Runs inside a Docker container
  - Stages: base packages -> system config -> kernel modules -> BentOS binaries -> user model -> services -> finalize
- [ ] **M4.3** `scripts/build-image.sh` (orchestrator)
  - Calls build-kernel.sh then build-rootfs.sh
  - Produces `output/arm64/` with both files
  - Prints image hash
- [ ] **M4.4** `Makefile` or top-level build command
  - `make arm64` -> full build
  - `make kernel-arm64` -> kernel only
  - `make rootfs-arm64` -> rootfs only (assumes kernel modules exist)

**Validation**: `make arm64` from clean state produces `output/arm64/bentos-kernel-arm64.gz` + `output/arm64/bentos-rootfs-arm64.img`. Run twice -> same package versions installed (pinned repos).

---

## Project Structure

```
lib/bentos_distro/
+-- README.md
+-- TACTICAL_PLAN.md
+-- Makefile
+-- kernel/
|   +-- arm64/
|   |   +-- bentos_defconfig          BentOS kernel config (ARM64)
|   +-- x86_64/
|       +-- bentos_defconfig          BentOS kernel config (x86-64, future)
+-- configs/
|   +-- etc/
|   |   +-- init.d/
|   |   |   +-- bentosd              OpenRC service definition
|   |   |   +-- bentos-agent.alfred  Agent service definition
|   |   +-- bentos/
|   |   |   +-- config.yaml          bentosd defaults
|   |   +-- skel/
|   |   |   +-- .bashrc
|   |   |   +-- .profile
|   |   |   +-- .plan
|   |   |   +-- .project
|   |   +-- modules                  "cuse"
|   |   +-- network/
|   |   |   +-- interfaces           eth0 DHCP
|   |   +-- hostname                 "bentos"
|   |   +-- hosts
|   |   +-- securetty                hvc0 added
|   +-- home/
|       +-- alfred/                  Pre-forged agent home (overlay on skel)
+-- scripts/
|   +-- build-kernel.sh
|   +-- build-rootfs.sh
|   +-- build-image.sh
+-- output/                          (gitignored)
    +-- arm64/
    |   +-- bentos-kernel-arm64.gz
    |   +-- bentos-rootfs-arm64.img
    +-- x86_64/
        +-- ...
```

Configs are shared across architectures. Per-arch: only kernel defconfig and output binaries.

---

## Build Environment

All builds run inside Docker containers for reproducibility. The host (macOS) never runs `apk` or `make` directly.

**Kernel build container:**
```dockerfile
FROM alpine:3.21
RUN apk add build-base bc bison flex elfutils-dev linux-headers \
    perl python3 openssl-dev
# For cross-compile: add cross-compiler toolchain
```

**Rootfs build container:**
```dockerfile
FROM alpine:3.21
RUN apk add e2fsprogs apk-tools alpine-keys
# Runs as root to mount loopback devices
# Requires --privileged or specific device access
```

**Dart AOT compilation container (ARM64 native):**
```dockerfile
FROM dart:3.5 AS builder
# Copy Dart packages, compile AOT
# Output: bentosd, bentos-agent, bentos binaries
```

Note: `dart compile exe` produces a self-contained binary that statically links the Dart runtime. musl compatibility is not an issue — the Dart binary brings its own runtime.

---

## Implementation Order

```
M0 (kernel)          ~1 day     defconfig + cross-compile
    |
M1 (minimal rootfs)  ~1 day    Alpine base + login prompt
    |
M2 (modules)         ~0.5 day  Install kernel modules on rootfs
    |
M3 (full rootfs)     ~1-2 days BentOS binaries + users + services
    |
M4 (build scripts)   ~1 day    Automation + reproducibility
```

**Dependency on bentos-vmm-macos:** M1 validation requires a working VZ.fw daemon (bentos-vmm-macos M3). If the daemon isn't ready, validate with Apple's sample VZ.fw code or a minimal Swift test harness that just boots a VM.

**Dependency on Dart packages:** M3 requires compiled bentosd + bentos-agent. If these aren't ready for ARM64 AOT, build the rootfs without them and add later. The machine will still boot — just without BentOS services.

**Parallelization with bentos-vmm-macos:** M0 + M1 + M2 can be done in parallel with bentos-vmm-macos M0-M2. Both converge at the integration point: "boot a VM with this kernel and rootfs."

---

## Gotchas

1. **Loop device mounting requires privileges.** `mount -o loop` needs root or `CAP_SYS_ADMIN`. The build container needs `--privileged` or `--device /dev/loop-control`. On macOS Docker, this usually works. On CI, may need special config.

2. **Cross-architecture apk.** Installing aarch64 Alpine packages from an x86-64 host requires either `qemu-aarch64-static` (binfmt_misc) or building inside a native ARM64 container. On Apple Silicon Macs, Docker runs ARM64 natively — no cross-compilation needed for rootfs packages.

3. **Kernel cross-compilation.** Building an ARM64 kernel on an ARM64 Mac inside Docker is native compilation, not cross-compilation. Simplest path: `docker run --platform linux/arm64 alpine:3.21` and build directly.

4. **Dart AOT cross-compilation.** `dart compile exe` targets the host architecture. For ARM64 binaries, compile inside an ARM64 container. On Apple Silicon, this is native.

5. **Console device name.** VZ.fw uses `hvc0` (Hypervisor Virtual Console), not `ttyS0`. The kernel command line must say `console=hvc0`. Getty/login must be configured on `hvc0`. Add `hvc0` to `/etc/securetty`.

6. **DHCP in VZ.fw NAT.** VZ.fw's NAT networking provides a DHCP server to the guest. The guest interface (`eth0`, virtio-net) should be configured for DHCP. Static IP also works if the VMM assigns a known address.

7. **Sparse files + ext4.** `truncate -s 512M` creates a sparse file that uses near-zero disk space. ext4 on APFS (via Docker's virtiofs) may not preserve sparseness. Build inside the container's own filesystem, then copy out.

8. **resize2fs needs e2fsck first.** Always `e2fsck -f` before `resize2fs`. The tool refuses to resize a filesystem that hasn't been checked.

---

## What's Explicitly Deferred

- x86-64 kernel + rootfs (until bentos-vmm-linux exists)
- Level 3 packaging (APKBUILDs for bentosd, own Alpine repo)
- Immutable rootfs / A-B partitioning
- Verified boot / encrypted rootfs / initramfs
- Image update mechanism (for running machines)
- CI/CD pipeline for automated image builds
- Multiple image variants (minimal, full, dev)
