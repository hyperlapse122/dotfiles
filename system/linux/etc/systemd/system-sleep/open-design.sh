#!/bin/sh
# systemd system-sleep hook: stop the per-user Open Design service before the
# system hibernates (or enters hybrid-sleep) so its long-lived daemon and IPC
# sockets do not outlive the power cycle. Plain suspend is intentionally left
# alone — a suspend user keeps their running session. See
# docs/plans/2026-07-25-001-feat-open-design-hibernate-stop-plan.md.
#
# Installed to /etc/systemd/system-sleep/open-design.sh (mode 0755) by
# install-system-10-files from the system.yaml manifest. systemd invokes every
# system-sleep hook as:  $0 <pre|post> <suspend|hibernate|hybrid-sleep|suspend-then-hibernate>
#
# Best-effort by design: a missing tool, an absent service, or an unreachable
# user manager must never abort the sleep transition (exit 0 regardless).

set -u

# Only act before disk-persisting sleep states.
case "${1:-}/${2:-}" in
  pre/hibernate|pre/hybrid-sleep) ;;
  *) exit 0 ;;
esac

# If any tool we need is absent, do nothing rather than break hibernation.
command -v loginctl >/dev/null 2>&1 || exit 0
command -v getent    >/dev/null 2>&1 || exit 0
command -v systemctl >/dev/null 2>&1 || exit 0

# Stop open-design.service for every logged-in human user whose user manager is
# reachable from the system context (systemctl --user -M "<user>@.host" is the
# only way a root-run system hook can stop a user unit). Each stop is
# best-effort: an absent service or unreachable user manager is ignored.
loginctl list-users --no-legend 2>/dev/null |
  awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1000 { print $1 }' |
  while IFS= read -r uid; do
    [ -n "${uid:-}" ] || continue
    user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1) || continue
    [ -n "${user:-}" ] || continue
    systemctl --user -M "${user}@.host" stop open-design.service 2>/dev/null || true
  done

exit 0
