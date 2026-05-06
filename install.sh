#!/usr/bin/env bash
# install.sh - Bootstrap dotfiles on macOS or Linux.
#
# Detects the OS, ensures `uv` is on PATH (installing it from astral.sh if
# missing), then runs dotbot ephemerally via `uvx`. dotbot itself is NEVER
# installed — see AGENTS.md.
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

# 2. Ensure uv on PATH. The astral installer drops uv into ~/.local/bin and
#    writes ~/.local/bin/env that prepends it to PATH for new shells.
if ! command -v uv >/dev/null 2>&1; then
  printf 'install.sh: uv not found, installing from astral.sh...\n'
  curl -LsSf https://astral.sh/uv/install.sh | sh
  if [[ -f "$HOME/.local/bin/env" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.local/bin/env"
  fi
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi

if ! command -v uv >/dev/null 2>&1; then
  printf 'install.sh: uv still not on PATH after install attempt.\n' >&2
  printf 'install.sh: add %s/.local/bin to PATH manually and re-run.\n' "$HOME" >&2
  exit 1
fi

# 3. Run dotbot ephemerally via uvx. Pass through extra args (e.g. --only).
#    NOTE: dotbot's `-c` uses argparse `nargs='+'` (NOT `append`), so multiple
#    config files MUST be passed under a SINGLE `-c` flag. `-c f1 -c f2` would
#    only use f2 (the last one wins). Don't change this back.
exec uvx dotbot \
  -d "$REPO_ROOT" \
  -c "$REPO_ROOT/install.conf.yaml" "$REPO_ROOT/$OS_YAML" \
  "$@"
