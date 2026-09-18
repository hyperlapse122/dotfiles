#!/usr/bin/env bash
set -euo pipefail

# Validates the committed compound-engineering overlay rebase marker file
# (home/.chezmoidata/ce-overlay-rebase.json) against its schema.
#
# Runs the package CLI through .ci/lib/bun.sh.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")
marker=${1:-$source_root/.chezmoidata/ce-overlay-rebase.json}

fail() {
  printf 'check-ce-overlay-rebase-marker: %s\n' "$*" >&2
  exit 1
}

[ -f "$marker" ] || fail "marker not found: $marker"

# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"
resolve_bun

[ -n "$BUN_BIN" ] || fail "bun is required to run the marker check"

out=$("$BUN_BIN" "$repo_root/packages/ce-overlay-rebase/src/cli.ts" validate-marker "$marker" 2>&1) || {
  fail "marker validation failed for $marker: $out"
}

printf 'check-ce-overlay-rebase-marker: ok - %s\n' "$marker"
