# Build Lessons (bentos_distro)

## Alpine linux-virt kernel build in Docker
- Alpine config is at `/boot/config-{version}` after `apk add linux-virt`
- Kernel version extracted from `/lib/modules/` dir name (e.g., `6.12.77-0-virt`)
- Config option is `VIRTIO_VSOCKETS` (with S), not `VIRTIO_VSOCK`
- `scripts/config` requires bash — Alpine containers need explicit `apk add bash`
- GCC plugins need gmp-dev + mpc1-dev — easier to just `--disable GCC_PLUGINS`
- Alpine's config references `/home/buildozer/.abuild/kernel_signing_key.pem` — disable MODULE_SIG
- Must `mkdir -p /build` before `cd /build` in container

## Rootfs build
- `busybox-initscripts` doesn't exist in Alpine 3.21 — use `busybox-openrc` + `busybox-mdev-openrc`
- Full module tree from linux-virt is ~350MB (862 .ko files) — selective copy essential
- `resize2fs` is in `e2fsprogs-extra`, not base `e2fsprogs`
- Build container needs `--privileged` for loop mount
- Modules are gzipped (.ko.gz) — kmod handles this natively
- Dangling `build -> /build` symlink in modules dir — skip it, don't cp -a blindly

## Apple Silicon
- Docker runs ARM64 natively — no cross-compilation needed
- `--platform linux/arm64` is explicit but default on Apple Silicon
