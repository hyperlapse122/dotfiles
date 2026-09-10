#!/usr/bin/env bash
set -euo pipefail

# Files, or updates, the tracker issue for a failed gem80 firmware watch run.
#
# WHY MORE THAN A RED WORKFLOW. A scheduled run that nobody opens is a report
# nobody reads, and this watch exists precisely for the stretch when nobody is
# thinking about the firmware. An issue puts the break where the operator
# already looks and keeps it visible until it is closed.
#
# WHY IT REUSES AN OPEN ISSUE. A daily gate against a break that lasts a week
# would file seven issues for one incident. The first failure opens one; later
# failures comment on it, so the incident stays one thread with its own history.
#
# The issue body carries the run URL and nothing from the failing log — log text
# is untrusted input and does not belong in a body that renders markdown.

usage() {
  printf 'usage: report-gem80-firmware-break.sh <cadence> <run-url>\n' >&2
  exit 2
}

cadence="${1:-}"
run_url="${2:-}"
[ -n "$cadence" ] && [ -n "$run_url" ] || usage

command -v gh >/dev/null 2>&1 || {
  printf 'report-gem80-firmware-break: gh is required on PATH\n' >&2
  exit 1
}

# Stable across incidents so the search below can find the open one.
title="gem80 firmware watch: the pinned build path is broken"

existing=$(gh issue list --state open --search "$title in:title" \
  --json number,title --jq "map(select(.title == \"$title\")) | .[0].number // empty")

if [ -n "$existing" ]; then
  gh issue comment "$existing" --body \
    "The ${cadence} gem80 firmware check failed again: ${run_url}"
  printf 'report-gem80-firmware-break: commented on #%s\n' "$existing"
  exit 0
fi

body=$(
  cat <<EOF
The ${cadence} gem80 firmware check failed: ${run_url}

The pinned build path for \`firmware/nuphy-gem80-hostrgb\` no longer resolves, or
no longer rebuilds. Until it is fixed, the firmware cannot be rebuilt — flashing
the committed binary still works.

See \`firmware/nuphy-gem80-hostrgb/README.md\` for what each check covers. The run
log names which dependency broke.

This issue is reused by later failures rather than duplicated, so close it once
the pin is repaired.
EOF
)

url=$(gh issue create --title "$title" --body "$body")
printf 'report-gem80-firmware-break: opened %s\n' "$url"
