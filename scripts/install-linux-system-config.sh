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
#
# Most files install at mode 0644. The one exception is etc/sudoers.d/*,
# which installs at 0440 (sudo refuses group/world-readable drop-ins) and
# only on virtual machines, gated on `systemd-detect-virt --vm`. Sudoers
# drop-ins are also syntax-checked with `visudo -c -f` before install — a
# broken drop-in can break sudo globally on the host.

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
# require editing this script (unless it needs a non-default mode or a
# platform/host gate — currently only sudoers.d/* qualifies).
shopt -s globstar nullglob

count=0
skipped=0
for src in "$SRC_ROOT"/etc/**; do
  [[ -f "$src" ]] || continue

  rel="${src#"$SRC_ROOT"/}"
  dst="/$rel"

  # Per-path overrides. Defaults: mode 0644, install unconditionally.
  mode=644
  install_this=true

  case "$rel" in
    etc/sudoers.d/*)
      # sudoers(5): drop-ins must be mode 0440 (sudo ignores
      # group/world-writable files) and the filename must not contain '.'
      # or end in '~'. We also gate these on `systemd-detect-virt --vm`
      # so the rule only lands on virtual machines, never on bare metal.
      mode=440
      if ! systemd-detect-virt --vm --quiet 2>/dev/null; then
        install_this=false
      fi
      # Validate syntax unconditionally (even when we won't install on
      # this host) so contributors catch broken drop-ins on bare-metal
      # dev machines before they hit a VM.
      if ! visudo -c -f "$src" >/dev/null; then
        printf '  !! %s: visudo syntax check failed; aborting\n' "$dst" >&2
        exit 1
      fi
      ;;
  esac

  if [[ "$install_this" != true ]]; then
    printf '  -- %s (skipped: not a VM)\n' "$dst"
    skipped=$((skipped + 1))
    continue
  fi

  printf '  -> %s (mode %s)\n' "$dst" "$mode"
  "${SUDO[@]}" install -D -m "$mode" "$src" "$dst"
  count=$((count + 1))
done

printf 'install-linux-system-config.sh: %d installed, %d skipped\n' "$count" "$skipped"
