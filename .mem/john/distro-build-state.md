# Distro Build State (S309)

## Completed — M0+M1+M2
- **M0**: Kernel — Linux 6.12.77 LTS ARM64, from Alpine linux-virt config
  - FUSE_FS=y, CUSE=m, VIRTIO_FS=m, VSOCKETS/VIRTIO_VSOCKETS=m
  - GCC plugins disabled, module signing disabled
  - USB/sound/DRM/wireless stripped
  - Output: `lib/bentos_distro/output/arm64/bentos-kernel-arm64` (20MB, valid ARM64 Image)
- **M1**: Rootfs — Alpine 3.21, ext4, 38MB shrunk
  - alpine-base, bash, openssh-server, shadow, sudo, kmod
  - Console on hvc0, DHCP on eth0, root password: bentos
  - OpenRC services: sysinit/boot/default/shutdown all configured
- **M2**: Kernel modules selectively installed on rootfs (7 modules)
  - cuse, virtiofs, vsock, vmw_vsock_virtio_transport{,_common}, vsock_{diag,loopback}
  - /etc/modules loads vsock + vmw_vsock_virtio_transport + cuse at boot

## Artifact Locations
- Kernel: `lib/bentos_distro/output/arm64/bentos-kernel-arm64`
- Rootfs: `lib/bentos_distro/output/arm64/bentos-rootfs-arm64.img`
- Full config: `lib/bentos_distro/output/arm64/bentos_defconfig_full`

## For VMM Integration (successor handoff)
- Kernel loaded via VZLinuxBootLoader(kernelURL:)
- Rootfs presented as virtio-blk disk
- Kernel cmdline: `console=hvc0 root=/dev/vda rw`
- Root login: root / bentos
- Successor spawns as john-vmm-swift-05 at lib/bentos_vmm_macos/ for e2e validation
- Copy artifacts to .build/debug/, build+codesign Swift daemon, POST create+start VM
