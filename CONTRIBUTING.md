# Contributing to bentos-distro

Build system internals, local CI setup, and hard-won lessons.

## Local CI with act

The full GitHub Actions workflow can be run locally using [act](https://github.com/nektos/act).

### Setup

```bash
# Install act
brew install act

# Create .secrets (gitignored) — both tokens needed for checkout steps
cat > lib/bentos_distro/.secrets <<EOF
REPO_TOKEN=$(gh auth token)
GITHUB_TOKEN=$(gh auth token)
EOF
```

### Running

```bash
cd lib/bentos_distro
./scripts/run-ci-local.sh
```

Log is written to stdout. For long runs (kernel compile takes ~2hrs), use nohup:

```bash
nohup ./scripts/run-ci-local.sh > /tmp/bentos-ci-local.log 2>&1 &
echo "PID: $!"
tail -f /tmp/bentos-ci-local.log
```

**Never use background execution wrappers** that die when the shell goes idle. Use `nohup` + `&` directly and record the PID.

### Cleanup between runs

Docker containers must be fully removed between runs or act will find stale state:

```bash
docker stop -t 0 $(docker ps -q) 2>/dev/null
docker container prune -f
```

### Dry run

```bash
./scripts/run-ci-local.sh --dryrun   # parse workflow only, no execution
```

---

## How --bind Works (Critical)

act is invoked with `--bind`, which mounts the repo root directly as `github.workspace` instead of copying it into a container. This has two consequences:

**1. The distro checkout is a no-op.**

The workflow checks out `cafe01/bentos-distro` into `monorepo/lib/bentos_distro`. With `--bind`, act detects this is the local repo and skips copying — leaving `monorepo/lib/bentos_distro` missing. `run-ci-local.sh` pre-creates it as a symlink:

```
monorepo/lib/bentos_distro -> $REPO_ROOT
```

This makes `cd "$GITHUB_WORKSPACE/monorepo/lib/bentos_distro"` resolve correctly. Sibling repos (`bentos_execd`, `bentosd`, `bentos_fuse`) are real git clones done by the checkout steps.

**2. REPO_ROOT resolves to monorepo/, not the workspace root.**

`build-rootfs.sh` sets `REPO_ROOT="$(cd "${DISTRO_ROOT}/../.." && pwd)"` — two levels above `lib/bentos_distro`. Under `--bind` this is `monorepo/`. The workspace root (which contains the root `pubspec.yaml`) is one level higher. Build scripts that reference `$REPO_ROOT/pubspec.yaml` will fail locally but pass on GitHub (where the workspace IS the monorepo root populated by checkouts).

---

## Docker-in-Docker (DinD)

The build scripts run Docker containers from inside the act container. This works because OrbStack's `/var/run/docker.sock` symlink is automatically bind-mounted into act containers.

The act container needs `--privileged` for DinD (mount operations in kernel build):

```yaml
# In ci.yml — do not change this
- uses: docker/setup-buildx-action@v3
```

```bash
# In run-ci-local.sh — the flag form matters (act 0.2.86+)
--container-options "--privileged"   # correct
--privileged                          # deprecated, ignored
```

---

## Squid Proxy (Optional, for caching)

A Squid proxy on localhost:3128 with SSL bump caches large downloads (kernel source ~140MB, Alpine packages, Docker images). Useful when iterating on CI — saves significant time and bandwidth.

**Config location:** `/opt/homebrew/etc/squid.conf`

**Known issues with Squid 7 on macOS:**
- `sslproxy_session_cache_size` must be set to `0 MB` — macOS `PSHMNAMLEN=31` limit causes `shm_open` failures with any non-zero value
- Remove `workers` directive — same SHM issue
- CA cert must be trusted: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /opt/homebrew/etc/squid/ssl_cert/squid-ca.crt`
- OrbStack must be restarted after adding `~/.orbstack/config/docker.json` with `{ "proxies": { "default": { "httpProxy": "http://host.internal:3128", "httpsProxy": "http://host.internal:3128" } } }`

---

## Build Script Details

### build-kernel.sh

Compiles the ARM64 kernel inside a Docker container from Alpine's `linux-virt` source. The kernel compile is the long pole — expect ~2hrs on Apple Silicon M4, longer under QEMU emulation.

`cdn.kernel.org` occasionally returns 503. The download has retry logic but may need a manual re-run on transient failures.

### build-rootfs.sh

Two-stage build:

**Stage 1 (Rust):** Cross-compiles `bentos-execd` for `aarch64-unknown-linux-musl`. Requires on the host:
- `aarch64-unknown-linux-musl` Rust target
- `aarch64-linux-musl-gcc` linker (symlink to `aarch64-linux-gnu-gcc` works)
- `protoc` (protobuf compiler) — required by `bentos-execd`'s `build.rs` to compile `exec_wire.proto`

**Stage 2 (Dart):** Compiles `bentosd` and `bentos` Dart AOT binaries inside a `dart:stable` container on `linux/arm64`. The build synthesizes a minimal workspace pubspec internally — it does not use the root workspace pubspec.

**Stage 3 (rootfs assembly):** Runs Alpine inside Docker, installs packages, copies in kernel modules and BentOS binaries, configures OpenRC services, shrinks the ext4 image.

### Skipping binary compilation

```bash
bash scripts/build-rootfs.sh --no-bentos   # skip Rust + Dart stages, fast iteration
```

---

## CI Workflow Notes

### Upload and Release steps

`actions/upload-artifact@v4` and the release step require `ACTIONS_RUNTIME_TOKEN` which is only available on real GitHub-hosted runners. These steps are skipped in local act runs via `if: ${{ !env.ACT }}` — act sets `ACT=true` automatically.

Local runs produce artifacts on disk at `output/arm64/` and package them at the repo root. The upload/publish steps only run on GitHub.

### Adding new dependencies

If a new build dependency needs to be installed in CI (e.g., a compiler, a tool required by a build script), add it to the `apt-get install` line in `.github/workflows/ci.yml` under "Install musl cross-compiler". Current list: `gcc-aarch64-linux-gnu musl-tools protobuf-compiler`.

---

## Files to Keep Out of Git

`.gitignore` covers `output/` and `.secrets`. Also gitignore:

```
monorepo/          # created by run-ci-local.sh, contains clones + distro symlink
*.tar.gz           # packaged artifacts
```

These are generated at build time. Committing them wastes space and creates merge conflicts.
