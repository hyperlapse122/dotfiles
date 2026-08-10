#!/usr/bin/env bash
set -euo pipefail

# Proves check-windows-references.sh actually fails on every regression shape
# it claims to catch, passes clean against the real tree, and does not
# false-positive against the two documented exemptions (github-skill-collection.ts's
# WINDOWS_RESERVED/WINDOWS_INVALID, and packages/release-lock/test/'s retired-key
# fixtures). Also proves a missing scanned path fails loudly rather than being
# silently treated as "no match".

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check="$repo_root/.ci/check-windows-references.sh"
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/windows-references-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'windows-references gates: %s\n' "$*" >&2; exit 1; }

# A minimal mirror of the check's scanned surface, seeded from the real
# (already-clean) repo tree so fixtures exercise realistic content.
seed() {
  local dest=$1
  mkdir -p "$dest/.chezmoiexternals" "$dest/.chezmoiscripts/70-agents" \
    "$dest/.chezmoitemplates" "$dest/.chezmoidata" \
    "$dest/packages/release-lock/src" "$dest/packages/release-lock/test"
  cp "$repo_root"/.chezmoiexternals/*.toml "$dest/.chezmoiexternals/"
  cp "$repo_root/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl" \
    "$dest/.chezmoiscripts/70-agents/"
  cp "$repo_root"/.chezmoitemplates/*.tmpl "$dest/.chezmoitemplates/"
  cp "$repo_root/.chezmoi.toml.tmpl" "$dest/"
  cp "$repo_root/.chezmoidata/agents.yaml" "$dest/.chezmoidata/"
  cp "$repo_root/.chezmoidata/releases.json" "$dest/.chezmoidata/"
  cp "$repo_root"/packages/release-lock/src/*.ts "$dest/packages/release-lock/src/"
  cp "$repo_root"/packages/release-lock/test/*.ts "$dest/packages/release-lock/test/"
}

baseline="$scratch/baseline"
seed "$baseline"

# Clean tree: the check must pass.
"$check" "$baseline" || fail 'rejected a clean tree'

# Case 1: forward-order eq conditional reintroduced into a .chezmoiexternals file.
c1="$scratch/case1"; seed "$c1"
printf '\n{{- if eq .chezmoi.os "windows" -}}\nfoo\n{{- end -}}\n' >>"$c1/.chezmoiexternals/ai-agents.toml"
out1=$("$check" "$c1" 2>&1) && fail 'did not reject eq .chezmoi.os "windows" (forward order)'
grep -qF '.chezmoi.os "windows" conditional has reappeared' <<<"$out1" ||
  fail 'forward-order rejection did not name the conditional'

# Case 2: reversed-order ne conditional (the ai-agents.toml aoe-gate style).
c2="$scratch/case2"; seed "$c2"
printf '\n{{- if ne "windows" .chezmoi.os }}\nfoo\n{{- end }}\n' >>"$c2/.chezmoiexternals/ai-agents.toml"
"$check" "$c2" >/dev/null 2>&1 && fail 'did not reject ne "windows" .chezmoi.os (reversed order)'

# Case 3: a local $variable assigned from .chezmoi.os, not the literal path.
c3="$scratch/case3"; seed "$c3"
printf '\n{{- $os := .chezmoi.os -}}\n{{- if eq $os "windows" -}}\nfoo\n{{- end -}}\n' >>"$c3/.chezmoitemplates/release-lock-ref.tmpl"
"$check" "$c3" >/dev/null 2>&1 && fail 'did not reject eq $os "windows" ($variable form)'

# Case 4: regression in a .chezmoitemplates/*.tmpl file OTHER than
# agent-mcp-servers-json.tmpl -- proves the guard scans the whole directory,
# not just the one file the os:/validOS check names.
c4="$scratch/case4"; seed "$c4"
printf '\n{{- if eq .chezmoi.os "windows" -}}\nfoo\n{{- end -}}\n' >>"$c4/.chezmoitemplates/compound-engineering-ref.tmpl"
"$check" "$c4" >/dev/null 2>&1 && fail 'did not reject a regression in a non-agent-mcp .chezmoitemplates file'

# Case 5: windows reappears in the omp plugin/MCP os validation.
c5="$scratch/case5"; seed "$c5"
printf '\nmarketplaces:\n  x:\n    os: [linux, darwin, windows]\n' >>"$c5/.chezmoidata/agents.yaml"
out5=$("$check" "$c5" 2>&1) && fail 'did not reject windows in the omp plugin/MCP os validation'
grep -qF 'omp plugin/MCP os validation' <<<"$out5" ||
  fail 'os-validation rejection did not name the omp plugin/MCP surface'

# Case 6: a windows-amd64 literal reappears in release-lock src.
c6="$scratch/case6"; seed "$c6"
printf '\nconst x = "windows-amd64";\n' >>"$c6/packages/release-lock/src/registry.ts"
out6=$("$check" "$c6" 2>&1) && fail 'did not reject a windows-amd64 literal in release-lock src'
grep -qF 'release-lock src' <<<"$out6" || fail 'src-literal rejection did not name release-lock src'

# Case 7: a windows-amd64 literal reappears in the committed lock.
c7="$scratch/case7"; seed "$c7"
printf '\n// "windows-amd64"\n' >>"$c7/.chezmoidata/releases.json"
out7=$("$check" "$c7" 2>&1) && fail 'did not reject a windows-amd64 literal in the committed lock'
grep -qF 'committed lock' <<<"$out7" || fail 'lock-literal rejection did not name the committed lock'


# Negative control: packages/release-lock/test/ legitimately fixtures retired
# windows-amd64 keys to prove pruning removes them (KTD4) -- must never trigger
# the src-literal check, which scans src/ only.
c8="$scratch/case8"; seed "$c8"
printf '\nconst w = "windows-amd64"; // KTD4 legitimate retirement fixture\n' >>"$c8/packages/release-lock/test/lock.test.ts"
"$check" "$c8" || fail 'false-positived on a KTD4-exempt test/ fixture'

# Case 9: a scanned path going missing must fail LOUDLY, not silently pass --
# proves grep's exit status is checked, not just "if grep; then".
c9="$scratch/case9"; seed "$c9"
rm -rf "$c9/packages/release-lock/src"
out9=$("$check" "$c9" 2>&1) && fail 'silently passed with packages/release-lock/src missing entirely'
grep -qF 'grep failed' <<<"$out9" || fail 'missing-path failure did not report a grep error, not just a clean pass'

printf '%s\n' 'windows-references gates passed'
