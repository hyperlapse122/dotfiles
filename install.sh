#!/usr/bin/env bash
# install.sh - Bootstrap dotfiles on macOS or Linux.
#
# Detects the OS, requires user-installed `mise`, then runs dotbot ephemerally
# via mise-managed `uvx`. dotbot itself is NEVER installed — see AGENTS.md.
#
# Idempotent: re-run after every `git pull`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Pick per-OS yaml.
case "$(uname -s)" in
  Darwin) OS_YAML="install.macos.yaml" ;;
  Linux)  OS_YAML="install.linux.yaml" ;;
  *)
    printf 'install.sh: unsupported OS: %s\n' "$(uname -s)" >&2
    printf 'install.sh: use install.ps1 on Windows.\n' >&2
    exit 1
    ;;
esac

# 2. Require mise from the user's own installation.
MISE_BIN="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
if command -v mise >/dev/null 2>&1; then
  MISE_BIN="mise"
elif [[ -x "$MISE_BIN" ]]; then
  :
else
  printf 'install.sh: mise not found. Install mise yourself and re-run.\n' >&2
  printf 'install.sh: expected mise on PATH or at %s.\n' "$MISE_BIN" >&2
  exit 1
fi

# 3. Run dotbot ephemerally via mise-managed uvx. Pass through extra args (e.g. --only).
#    NOTE: dotbot's `-c` uses argparse `nargs='+'` (NOT `append`), so multiple
#    config files MUST be passed under a SINGLE `-c` flag. `-c f1 -c f2` would
#    only use f2 (the last one wins). Don't change this back.
exec "$MISE_BIN" exec uv@latest -- uvx dotbot \
  -d "$REPO_ROOT" \
  -c "$REPO_ROOT/install.conf.yaml" "$REPO_ROOT/$OS_YAML" \
  "$@"
