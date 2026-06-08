#!/usr/bin/env bash
# scripts/bootstrap/configure-codex-config.sh
#
# POSIX wrapper for configure-codex-config.mjs. Keeps script parity with
# configure-codex-config.ps1 while the merge logic runs through mise-managed
# Node.js.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MISE_BIN="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
if command -v mise >/dev/null 2>&1; then
  MISE_BIN="mise"
elif [[ -x "$MISE_BIN" ]]; then
  :
else
  printf 'configure-codex-config.sh: mise not found. Install mise yourself and re-run.\n' >&2
  printf 'configure-codex-config.sh: expected mise on PATH or at %s.\n' "$MISE_BIN" >&2
  exit 1
fi

exec "$MISE_BIN" exec node@latest -- node "$SCRIPT_DIR/configure-codex-config.mjs" "$@"
