#!/bin/sh
# systemd system-sleep hook: stop the per-user CLIProxyAPI quadlet services
# (the proxy and the CPA-Manager-Plus panel) before disk-persisting sleep so a
# hibernating laptop does not carry the containers' state across the power
# cycle, and restart exactly the units that were stopped on resume. Plain
# suspend is intentionally left alone — a suspend user keeps their running
# session. See docs/plans/2026-07-28-004-feat-cli-proxy-api-quadlet-plan.md.
#
# Installed to /etc/systemd/system-sleep/cli-proxy-api.sh (mode 0755) by
# install-system-10-files from the system.yaml manifest. systemd invokes every
# system-sleep hook as:  $0 <pre|post> <suspend|hibernate|hybrid-sleep|suspend-then-hibernate>
# with SYSTEMD_SLEEP_ACTION set. suspend-then-hibernate invokes the hooks
# twice (suspend leg, then hibernate leg); only the hibernate leg acts, so a
# plain suspend resume never bounces the services. Stop/start are idempotent:
# only units that were active are recorded at pre, and post starts exactly the
# recorded units.
#
# Best-effort by design: a missing tool, an absent unit, or an unreachable
# user manager must never abort the sleep transition (exit 0 regardless).

set -u

UNITS="cli-proxy-api.service cpa-manager-plus.service"
# /run is tmpfs: the record survives hibernation (RAM-resident) and is cleared
# on boot, so a stale record can never restart units after a real reboot.
# CLI_PROXY_API_SLEEP_STATE_DIR exists only so the .ci stub test can run
# unprivileged; production never sets it.
STATE_DIR="${CLI_PROXY_API_SLEEP_STATE_DIR:-/run/cli-proxy-api-sleep}"

# Only disk-persisting transitions act.
case "${2:-}" in
  hibernate|hybrid-sleep) ;;
  suspend-then-hibernate)
    [ "${SYSTEMD_SLEEP_ACTION:-}" = "hibernate" ] || exit 0
    ;;
  *) exit 0 ;;
esac

case "${1:-}" in
  pre|post) ;;
  *) exit 0 ;;
esac

# If any tool we need is absent, do nothing rather than break hibernation.
command -v loginctl >/dev/null 2>&1 || exit 0
command -v getent    >/dev/null 2>&1 || exit 0
command -v systemctl >/dev/null 2>&1 || exit 0

# Stop every active unit for one user and record what was actually stopped.
# `systemctl --user -M "<user>@.host" is the only way a root-run system hook
# can act on a user unit. Append-safe and deduplicated, so a repeated pre
# without an intervening post never loses an already-recorded unit.
stop_for_user() {
  mach=$1 record=$2
  for unit in $UNITS; do
    if systemctl --user -M "$mach" is-active --quiet "$unit" 2>/dev/null; then
      systemctl --user -M "$mach" stop "$unit" 2>/dev/null || continue
      grep -qx "$unit" "$record" 2>/dev/null ||
        printf '%s\n' "$unit" >>"$record" 2>/dev/null || true
    fi
  done
}

# Restart exactly the units recorded at pre, then drop the record.
start_for_user() {
  mach=$1 record=$2
  [ -f "$record" ] || return 0
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    systemctl --user -M "$mach" start "$unit" 2>/dev/null || true
  done <"$record"
  rm -f "$record" 2>/dev/null || true
}

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
chmod 700 "$STATE_DIR" 2>/dev/null || true

loginctl list-users --no-legend 2>/dev/null |
  awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1000 { print $1 }' |
  while IFS= read -r uid; do
    [ -n "${uid:-}" ] || continue
    user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || continue
    [ -n "${user:-}" ] || continue
    record="$STATE_DIR/stopped-$uid"
    case $1 in
      pre)  stop_for_user "${user}@.host" "$record" ;;
      post) start_for_user "${user}@.host" "$record" ;;
    esac
  done

exit 0
