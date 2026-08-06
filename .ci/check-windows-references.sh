#!/usr/bin/env bash
set -uo pipefail

# Fails if Windows support regresses back into any surface the 2026-08-05 and
# 2026-08-06 Windows-purge plans removed it from: a `.chezmoi.os "windows"`
# conditional -- direct field access or via a local $variable, either eq/ne
# token order -- in a chezmoi template; `windows` as an os:/validOS list value
# in the omp plugin/MCP catalog's OS-eligibility validation; or a
# windows-amd64/windows-arm64 PlatformKey literal in release-lock production
# code or the committed lock.
#
# Extracted from render-dotfiles.yml's shellcheck job so
# test-windows-references-gates.sh can exercise it against synthetic
# fixtures -- a regression here must fail loudly, not silently no-op.

# root defaults to the current directory; test-windows-references-gates.sh
# passes a scratch fixture tree.
root=${1:-.}
cd -- "$root" || { printf 'check-windows-references: cannot cd to %s\n' "$root" >&2; exit 1; }

failed=0

# A grep exit status of 1 (no match) is success; any OTHER nonzero status
# (2+: bad path, glob matched nothing, permission error, ...) must fail
# loudly rather than being silently treated the same as "no match found" --
# a missing scanned path must not make this check quietly stop enforcing.
scan() {
  local message=$1 rc=0
  shift
  grep "$@" || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '::error::%s\n' "$message" >&2
    failed=1
  elif [[ $rc -ne 1 ]]; then
    printf '::error::check-windows-references: grep failed (exit %d) while checking: %s\n' "$rc" "$message" >&2
    failed=1
  fi
}

# R14: a .chezmoi.os "windows" conditional -- direct field access
# (.chezmoi.os) or a local $variable it was assigned to -- reappearing in a
# template that gated Windows before the 2026-08-05 drop and this pass's
# leftover-gate cleanup. Scans every .chezmoitemplates/*.tmpl partial too,
# including release-lock-ref.tmpl, the sole shared lock-lookup entry point.
scan 'a .chezmoi.os "windows" conditional has reappeared' -rEn \
  '(eq|ne)[[:space:]]+\.chezmoi\.os[[:space:]]+"windows"|(eq|ne)[[:space:]]+"windows"[[:space:]]+\.chezmoi\.os|(eq|ne)[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]+"windows"|(eq|ne)[[:space:]]+"windows"[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*' \
  .chezmoiexternals/*.toml .chezmoiscripts .chezmoitemplates/*.tmpl .chezmoi.toml.tmpl

# R14: windows reappearing as an os:/validOS list value in the omp plugin /
# MCP-server catalog's OS-eligibility validation.
scan 'windows has reappeared in the omp plugin/MCP os validation' -qi windows \
  .chezmoidata/agents.yaml .chezmoitemplates/agent-mcp-servers-json.tmpl \
  .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl

# R16: a windows-amd64/windows-arm64 PlatformKey literal reappearing in
# release-lock production code or the committed lock. github-skill-collection.ts's
# WINDOWS_RESERVED/WINDOWS_INVALID are unrelated filename-portability guards, and
# packages/release-lock/test/ legitimately fixtures retired windows-* keys to
# prove the pruning behavior removes them.
scan 'a windows PlatformKey literal has reappeared in release-lock src' -rEn \
  'windows-(amd64|arm64)' packages/release-lock/src --exclude=github-skill-collection.ts

scan 'a windows PlatformKey literal has reappeared in the committed lock' -Eq \
  'windows-(amd64|arm64)' .chezmoidata/releases.json

exit "$failed"
