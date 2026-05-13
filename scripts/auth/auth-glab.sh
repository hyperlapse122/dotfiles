#!/usr/bin/env bash

set -euo pipefail

# Prefer system `glab`; fall back to ephemeral `mise exec glab@latest`. Error
# if neither is available.
if command -v glab >/dev/null 2>&1; then
  GLAB=(glab)
elif command -v mise >/dev/null 2>&1; then
  GLAB=(mise exec glab@latest -- glab)
else
  printf 'auth-glab.sh: glab not found and mise unavailable as fallback.\n' >&2
  exit 1
fi

"${GLAB[@]}" auth login --hostname git.jpi.app --web --container-registry-domains registry.jpi.app -a git.jpi.app -g https -p https
"${GLAB[@]}" auth login --hostname gitlab.com --web --container-registry-domains registry.gitlab.com -a gitlab.com -g https -p https
