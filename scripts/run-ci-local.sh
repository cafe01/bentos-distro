#!/usr/bin/env bash
# Run the CI workflow locally using act (https://github.com/nektos/act).
# Install: brew install act
#
# Create .secrets in this repo root (gitignored):
#   REPO_TOKEN=ghp_...
#   GITHUB_TOKEN=ghp_...
#
# Usage:
#   ./scripts/run-ci-local.sh              # full build
#   ./scripts/run-ci-local.sh --dryrun     # parse workflow, don't run
#   ./scripts/run-ci-local.sh -j build-arm64  # explicit job

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$REPO_ROOT/.secrets"

command -v act &>/dev/null || { echo "error: brew install act" >&2; exit 1; }

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "error: $SECRETS_FILE not found. Create it with REPO_TOKEN and GITHUB_TOKEN." >&2
  exit 1
fi

# act --bind mounts the repo root as github.workspace. The workflow checks out
# bentos_distro into path: monorepo/lib/bentos_distro, but with --bind act skips
# the local-repo copy and leaves that path missing. Pre-create the symlink so
# the build step's `cd "$GITHUB_WORKSPACE/monorepo/lib/bentos_distro"` resolves.
# Sibling repos (execd, bentosd, fuse) are real clones done by checkout steps.
SYMLINK="$REPO_ROOT/monorepo/lib/bentos_distro"
mkdir -p "$REPO_ROOT/monorepo/lib"
[[ -e "$SYMLINK" ]] || ln -s "$REPO_ROOT" "$SYMLINK"

act push \
  --secret-file "$SECRETS_FILE" \
  --platform "ubuntu-latest=catthehacker/ubuntu:act-latest" \
  --container-architecture linux/arm64 \
  --container-options "--privileged" \
  --bind \
  "$@"
