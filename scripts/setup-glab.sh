#!/usr/bin/env bash

set -euo pipefail

# Prefer system `glab`; fall back to ephemeral `mise exec glab@latest`. Error
# if neither is available.
if command -v glab >/dev/null 2>&1; then
  GLAB=(glab)
elif command -v mise >/dev/null 2>&1; then
  GLAB=(mise exec glab@latest -- glab)
else
  printf 'setup-glab.sh: glab not found and mise unavailable as fallback.\n' >&2
  exit 1
fi

# Configure glab
"${GLAB[@]}" config set client_id c6c350c323dbd7dbd4091b2f3e56a1d6ef31e7104ae6deddfc5d950c7d11d69f --global --host git.jpi.app
