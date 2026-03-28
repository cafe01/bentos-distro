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

exec act push \
  --secret-file "$SECRETS_FILE" \
  --platform "ubuntu-latest=catthehacker/ubuntu:act-latest" \
  "$@"
