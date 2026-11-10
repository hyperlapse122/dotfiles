#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/ci-docs-only-paths.sh <script>
#
# Verifies scripts/ci-docs-only-paths, which decides whether a list of
# changed repo-relative paths (stdin, one per line) is entirely
# documentation for the check.yml docs-only CI skip.

set -euo pipefail

script=${1:-}
if [[ $# -ne 1 || -z $script || ! -f $script ]]; then
  printf 'usage: %s SCRIPT\n' "${0##*/}" >&2
  exit 2
fi

fail() { printf 'ci-docs-only-paths: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ci-docs-only-paths: ok - %s\n' "$*"; }

run() {
  # run <label> <expected> <path>...
  local label=$1 expected=$2
  shift 2
  local got
  got=$(printf '%s\n' "$@" | bash "$script")
  [[ $got == "$expected" ]] || fail "$label: expected '$expected', got '$got'"
}

run 'all paths under docs/' true 'docs/install.md' 'docs/recovery.md'
run 'all paths under .compound-engineering/artifacts/' true \
  '.compound-engineering/artifacts/plans/foo-plan.md' \
  '.compound-engineering/artifacts/solutions/best-practices/bar.md'
run 'root *.md mixed with a docs/ path' true 'AGENTS.md' 'docs/install.md'
run 'one non-doc path among otherwise-doc paths' false 'docs/install.md' 'flake.nix'
run 'a nested README.md is not root-level' false 'secrets/README.md'
run 'a docs-prefixed but different directory' false 'docs2/foo.md'
run 'a single root *.md file alone' true 'README.md'
run 'a path under neither declared root' false 'scripts/ci-docs-only-paths'
run 'a non-artifacts path directly under .compound-engineering/' false '.compound-engineering/config.yaml'

got=$(printf '' | bash "$script")
[[ $got == false ]] || fail "empty input: expected 'false', got '$got'"
pass 'empty input defaults to false (fail-safe)'

pass 'all ci-docs-only-paths scenarios passed'
