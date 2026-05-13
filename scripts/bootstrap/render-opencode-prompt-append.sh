#!/usr/bin/env bash
# scripts/bootstrap/render-opencode-prompt-append.sh
#
# POSIX wrapper for render-opencode-prompt-append.mjs. Keeps script parity with
# render-opencode-prompt-append.ps1 while the rendering logic runs through
# mise-managed Node.js.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MISE_BIN="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
if command -v mise >/dev/null 2>&1; then
  MISE_BIN="mise"
elif [[ -x "$MISE_BIN" ]]; then
  :
else
  printf 'render-opencode-prompt-append.sh: mise not found. Install mise yourself and re-run.\n' >&2
  printf 'render-opencode-prompt-append.sh: expected mise on PATH or at %s.\n' "$MISE_BIN" >&2
  exit 1
fi

exec "$MISE_BIN" exec node@latest -- node "$SCRIPT_DIR/render-opencode-prompt-append.mjs" "$@"
