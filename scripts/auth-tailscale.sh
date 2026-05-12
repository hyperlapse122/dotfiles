#!/usr/bin/env bash
# scripts/auth-tailscale.sh - Authenticate/configure the Linux Tailscale daemon.
#
# Single-platform (Linux only) by design. This wraps `tailscale up` for the
# system service installed/enabled by scripts/install-packages.sh on Fedora;
# macOS and Windows use their native Tailscale apps/flows. No .ps1 counterpart
# per the script-parity exception in ../AGENTS.md.

set -euo pipefail

# Use sudo only when not already root (matches install-linux-system-config.sh).
# Throw early if neither root nor sudo is available — `tailscale up` needs it.
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  printf 'auth-tailscale.sh: requires root or sudo to run tailscale up.\n' >&2
  exit 1
fi

"${SUDO[@]}" tailscale up --operator "$USER" --accept-routes
