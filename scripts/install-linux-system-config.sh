#!/usr/bin/env bash
# scripts/install-linux-system-config.sh
#
# Installs root-owned config from system/linux/etc/* into /etc/* using
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

# Use sudo only when not already root (post-install.sh in arch-chroot runs as root).
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# Each entry: <relative-path-under-system/linux>  <mode>
FILES=(
  "etc/NetworkManager/NetworkManager.conf 644"
  "etc/NetworkManager/conf.d/80-lo.conf 644"
  "etc/NetworkManager/conf.d/90-unmanaged-vmware.conf 644"
  "etc/NetworkManager/conf.d/91-tailscale.conf 644"
  "etc/NetworkManager/conf.d/92-docker.conf 644"
  "etc/NetworkManager/conf.d/93-veth.conf 644"
  "etc/locale.conf 644"
  "etc/keyd/default.conf 644"
  "etc/libinput/local-overrides.quirks 644"
  "etc/plymouth/plymouthd.conf 644"
  "etc/udev/rules.d/logitech-receiver.rules 644"
)

for entry in "${FILES[@]}"; do
  read -r rel mode <<<"$entry"
  src="$SRC_ROOT/$rel"
  dst="/$rel"
  if [[ ! -f "$src" ]]; then
    printf 'install-linux-system-config.sh: missing source %s\n' "$src" >&2
    exit 1
  fi
  printf '  -> %s (mode %s)\n' "$dst" "$mode"
  "${SUDO[@]}" install -D -m "$mode" "$src" "$dst"
done

printf 'install-linux-system-config.sh: %d file(s) installed\n' "${#FILES[@]}"
