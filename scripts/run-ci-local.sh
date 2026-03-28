#!/usr/bin/env bash
# Run the bentos-distro CI workflow locally using `act`.
#
# act (https://github.com/nektos/act) runs GitHub Actions workflows inside
# Docker using the same runner images as GitHub. Install: brew install act
#
# SECRETS
# Create lib/bentos_distro/.secrets (gitignored) with:
#   REPO_TOKEN=ghp_...       # PAT with repo read access to sibling repos
#   GITHUB_TOKEN=ghp_...     # same PAT (or a separate one)
#
# USAGE
#   ./scripts/run-ci-local.sh            # full build (slow — QEMU ARM64)
#   ./scripts/run-ci-local.sh --dryrun   # validate workflow syntax only
#   ./scripts/run-ci-local.sh --job build-arm64   # explicit job

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$REPO_ROOT/.secrets"

if ! command -v act &>/dev/null; then
  echo "error: act is not installed. Run: brew install act" >&2
  exit 1
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  cat >&2 <<EOF
error: $SECRETS_FILE not found.

Create it with:
  REPO_TOKEN=ghp_...
  GITHUB_TOKEN=ghp_...

This file is gitignored — never commit it.
EOF
  exit 1
fi

# ubuntu-latest maps to a large runner image (~18 GB). Use the medium image
# for faster first-run downloads; swap to 'full' if apt packages go missing.
# Images: micro | medium (default) | full | catthehacker/ubuntu:full-latest
ACT_IMAGE="${ACT_IMAGE:-catthehacker/ubuntu:act-latest}"

echo "==> Running CI locally with act"
echo "    secrets: $SECRETS_FILE"
echo "    image:   $ACT_IMAGE"
echo ""

exec act push \
  --secret-file "$SECRETS_FILE" \
  --platform "ubuntu-latest=$ACT_IMAGE" \
  "$@"
