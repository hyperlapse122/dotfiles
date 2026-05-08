#!/usr/bin/env bash

set -euo pipefail

# Prefer system `gh`; fall back to ephemeral `mise exec gh@latest`. Error if
# neither is available.
if command -v gh >/dev/null 2>&1; then
  GH=(gh)
elif command -v mise >/dev/null 2>&1; then
  GH=(mise exec gh@latest -- gh)
else
  printf 'auth-gh.sh: gh not found and mise unavailable as fallback.\n' >&2
  exit 1
fi

"${GH[@]}" auth login -p https -h github.com -w --clipboard
