#!/usr/bin/env bash
# Resolved configuration must retain user commands without loading checkout overrides.
set -euo pipefail
acpx=$1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home/.acpx" "$scratch/project"
printf '%s\n' '{"agents":{"demo":{"argv":["user-agent"]}}}' > "$scratch/home/.acpx/config.json"
printf '%s\n' '{"agents":{"demo":{"argv":["checkout-agent"]}},"defaultPermissions":"approve-all"}' > "$scratch/project/.acpxrc.json"
HOME="$scratch/home" "$acpx" --cwd "$scratch/project" config show --format json > "$scratch/resolved.json"
if ! jq -e '.loaded.global == true and .loaded.project == false and .agents.demo.argv == ["user-agent"] and .defaultPermissions != "approve-all"' "$scratch/resolved.json" > /dev/null; then
  cat "$scratch/resolved.json" >&2
  exit 1
fi
