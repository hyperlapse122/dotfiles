#!/usr/bin/env bash
# scripts/linux/install-linux-system-config.sh
#
# Installs root-owned config from system/linux/etc/**/* into /etc/* using
# `sudo install -D -m <mode>`, then enables firewalld masquerading on the
# default zone. Called from a `shell:` step in ../../install.linux.yaml
# (dotbot has no sudo / root mode, see AGENTS.md).
#
# Single-platform (Linux only) by design — no .ps1 counterpart per the
# script-parity exception in AGENTS.md.
#
# Re-runnable: `install -D` is idempotent, and the firewalld step queries
# `--permanent --query-masquerade` before mutating.
#
# Skip behaviour: when not running as root, stdin is not a TTY, and sudo
# has no cached credentials, the script exits 0 immediately. Dotbot
# invokes this from a non-interactive shell step during bootstrap; in
# that context an uncached sudo would hang or fail. Skipping cleanly
# keeps the rest of the dotbot run going. Re-run the script manually
# (`bash scripts/linux/install-linux-system-config.sh`) afterwards.
#
# Most files install at mode 0644. The one exception is etc/sudoers.d/*,
# which installs at 0440 (sudo refuses group/world-readable drop-ins) and
# only on virtual machines, gated on `systemd-detect-virt --vm`. Sudoers
# drop-ins are also syntax-checked with `visudo -c -f` before install — a
# broken drop-in can break sudo globally on the host.
#
# firewalld masquerade is required for the Tailscale exit-node and VMware
# NAT egress paths to source-NAT traffic out the host's primary interface
# (which lives in the default zone on Fedora Workstation). It rides on top
# of the IPv4/IPv6 forwarding enabled by etc/sysctl.d/99-tailscale.conf,
# which this script installs in the same run. The firewalld step is a
# no-op on hosts where firewalld is not the active backend.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_ROOT="$REPO_ROOT/system/linux"

# Use sudo only when not already root (e.g. when invoked inside chroot/container).
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)

  # Skip cleanly when we'd need to prompt for a password but can't.
  # `[[ -t 0 ]]` is true only when stdin is a TTY; dotbot's `shell:`
  # steps connect stdin so this is true under `./install.sh` but false
  # under agent/CI runs. `sudo -n true` succeeds when sudo has cached
  # credentials (recent `sudo` invocation) or when the user has
  # password-less sudo configured — in either case we can proceed
  # without prompting. Only when both fail do we give up.
  if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
    printf 'install-linux-system-config.sh: skipped (non-interactive shell, no cached sudo credentials).\n'
    printf '  Re-run manually:\n'
    printf '    bash %s/scripts/linux/install-linux-system-config.sh\n' "$REPO_ROOT"
    exit 0
  fi
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

# Reload systemd and enable timers when system/linux/etc/systemd/system/
# ships any unit files. `daemon-reload` is required so systemd notices the
# newly-installed units; `enable --now` is idempotent for timers (enables
# the symlink + starts the timer; no-op if already in that state).
#
# docker-prune.timer is gated on `command -v docker` so we don't enable a
# timer that has no chance of doing useful work on a host that never ran
# scripts/linux/install-packages.sh. The service unit itself also carries
# `ConditionPathExists=/usr/bin/docker` as a runtime safety net.
if [[ -d "$SRC_ROOT/etc/systemd/system" ]]; then
  "${SUDO[@]}" systemctl daemon-reload

  if command -v docker >/dev/null 2>&1; then
    printf '  -> systemctl enable --now docker-prune.timer\n'
    "${SUDO[@]}" systemctl enable --now docker-prune.timer
  else
    printf '  -- docker-prune.timer: skipped (docker not installed)\n'
  fi
fi

# Enable firewalld masquerade on the default zone — required for the
# Tailscale exit-node and VMware NAT egress paths (see header comment).
# Scope is the default zone (`FedoraWorkstation` on Fedora Workstation),
# which by default binds the host's primary network interfaces and is
# therefore the egress path for both use cases.
#
# Gate: `firewall-cmd --state` is firewalld's own liveness probe
# (https://firewalld.org/documentation/howto/get-firewalld-state.html).
# It returns 0 when the daemon is running and non-zero when firewalld is
# masked, missing, or replaced by a different backend (raw nftables,
# iptables-services). In every non-running case the masquerade step is
# skipped — we don't program a backend that isn't there.
#
# Idempotency: `--permanent --query-masquerade` returns 0 when masquerade
# is already enabled in the permanent config, so we only mutate when
# something would change. `--reload` after `--permanent` is what makes
# the change take effect in the runtime without restarting firewalld
# (https://firewalld.org/documentation/configuration/runtime-versus-permanent.html).
if "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
  if "${SUDO[@]}" firewall-cmd --permanent --query-masquerade >/dev/null 2>&1; then
    printf '  -- firewalld masquerade: already enabled (default zone)\n'
  else
    printf '  -> firewalld masquerade: enabling on default zone\n'
    "${SUDO[@]}" firewall-cmd --permanent --add-masquerade >/dev/null
    "${SUDO[@]}" firewall-cmd --reload >/dev/null
  fi
else
  printf '  -- firewalld masquerade: skipped (firewalld not running)\n'
fi