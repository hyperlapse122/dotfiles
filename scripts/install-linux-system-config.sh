#!/usr/bin/env bash
# scripts/install-linux-system-config.sh
#
# Installs root-owned config from system/linux/etc/**/* into /etc/* using
# `sudo install -D -m <mode>`. Called from a `shell:` step in
# ../install.linux.yaml (dotbot has no sudo / root mode, see AGENTS.md).
#
# Single-platform (Linux only) by design — no .ps1 counterpart per the
# script-parity exception in AGENTS.md.
#
# Re-runnable: `install -D` is idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="$REPO_ROOT/system/linux"

# Use sudo only when not already root (e.g. when invoked inside chroot/container).
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# Discover files at runtime so adding system/linux/etc/... config does not
# require editing this script. All root-owned config files are installed 0644.
shopt -s globstar nullglob

count=0
for src in "$SRC_ROOT"/etc/**; do
  [[ -f "$src" ]] || continue

  rel="${src#"$SRC_ROOT"/}"
  dst="/$rel"

  printf '  -> %s (mode 644)\n' "$dst"
  "${SUDO[@]}" install -D -m 644 "$src" "$dst"
  count=$((count + 1))
done

printf 'install-linux-system-config.sh: %d file(s) installed\n' "$count"
