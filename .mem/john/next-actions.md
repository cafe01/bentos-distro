# Next Actions (S317 final)

## Nothing unfinished from S317
All three commits pushed and merged. CI green. Docs updated.

## Next priorities (distro)

### repository_dispatch wiring
bentos-execd and bentosd CIs should trigger distro rebuild when their binaries change.
Wire `repository_dispatch` events from those repos into distro CI workflow.

### amd64 architecture
x86-64 kernel + rootfs for bentos-vmm-linux. Second architecture target.
CI workflow will need matrix strategy (arm64 + amd64).

### Squid cache tuning (low priority)
Docker blob caching not working — R2 CDN signed URLs are unique per request.
Options: `store_id_program` to normalize URLs. Not blocking anything.

### OrbStack CA cert persistence (low priority)
nsenter injection won't survive OrbStack updates. Needs automation.

### Initramfs (low priority)
Replace `/etc/modules` workaround. Carried from S315.

## Cleanup notes
- `bentos-alpine-*.tar.gz` in distro root — gitignored, safe to delete
- `monorepo/` dir from act --bind — gitignored, safe to delete
