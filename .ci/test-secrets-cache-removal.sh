#!/usr/bin/env bash
# Regression guard for the GPG secrets cache removal
# (docs/plans/2026-08-05-002-refactor-remove-gpg-secrets-cache-plan.md, R7 and R10).
#
# The cache is gone: every op:// reference now resolves through a direct live
# onepasswordRead, and the deployed ~/.local/bin/chezmoi-secrets-sync binary is
# pruned by a .chezmoiremove entry. Two things can silently regress:
#
#   1. The prune entry. Deleting or un-gating it keeps every other check green
#      while already-provisioned non-Windows hosts keep a stale executable on
#      PATH forever. Its gate must also stay non-Windows-only: the source that
#      deployed it carried the same gate, so pruning on Windows would target a
#      path chezmoi never wrote there. (Same failure shape, and the same
#      reasoning, as Check 7 in test-garden-registry-relocation.sh.)
#   2. The scaffolding. A reintroduced template, script, or instruction that
#      names the cache would describe a mechanism that no longer exists.
#
# Both are static/render checks — no GPG key and no 1Password access needed, so
# this runs unchanged in CI.

set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo_root"

fail() {
  printf 'test-secrets-cache-removal: %s\n' "$1" >&2
  exit 1
}

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/secrets-cache-removal.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/target"
: >"$scratch/empty.toml"

render_remove() {
  chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" "$@" execute-template <"$repo_root/.chezmoiremove"
}

# --- Check 1: the prune entry renders on a host that received the binary -----
render_remove >"$scratch/linux.out" \
  || fail '.chezmoiremove failed to render with default (linux) data'
grep -qxF '.local/bin/chezmoi-secrets-sync' "$scratch/linux.out" \
  || fail '.chezmoiremove is missing its .local/bin/chezmoi-secrets-sync prune entry'

# The leading dot is load-bearing: chezmoi's dot_ source prefix maps to a
# literal "." in the target, so a dotless entry would match nothing and prune
# nothing while still looking present to a careless grep.
grep -qxF 'local/bin/chezmoi-secrets-sync' "$scratch/linux.out" \
  && fail '.chezmoiremove carries a dotless local/bin/... entry, which prunes nothing'

# --- Check 2: it does NOT render on Windows, which never received it ---------
render_remove --override-data '{"chezmoi":{"os":"windows","arch":"amd64"}}' >"$scratch/windows.out" \
  || fail '.chezmoiremove failed to render under an os=windows override'
grep -qxF '.local/bin/chezmoi-secrets-sync' "$scratch/windows.out" \
  && fail '.chezmoiremove prunes chezmoi-secrets-sync on Windows, where chezmoi never deployed it'

# A pre-existing entry must survive both renders — this test must fail if the
# new block was appended in a way that swallowed its neighbour. Deliberately
# asserted against the omp mirror entry rather than the garden one: Check 7 of
# test-garden-registry-relocation.sh sweeps the repo for that old target
# literal and allows it only in .chezmoiremove and docs/, so naming it here
# would turn this guard into a cross-test failure.
grep -qxF '.omp/agent/CLAUDE.md' "$scratch/linux.out" \
  || fail '.chezmoiremove lost a pre-existing prune entry on the linux render'

# --- Check 3: no live source still describes the removed cache ---------------
# docs/plans/ is the historical record of the decision and its reversal, so it
# legitimately names the cache. .chezmoiremove names the binary because that is
# the prune instruction. Everything else must be clean. This test is excluded
# too: its own prose necessarily names what it guards.
stale="$(grep -rIl -E 'secrets-bundle|secret-read\.tmpl|gpg-cache-ready|chezmoi-secrets-sync|encrypted secrets cache' . \
  --exclude-dir=.git \
  --exclude-dir=plans \
  --exclude='.chezmoiremove' \
  --exclude="$(basename "$0")" || true)"
if [ -n "$stale" ]; then
  printf 'test-secrets-cache-removal: these files still reference the removed GPG secrets cache:\n%s\n' "$stale" >&2
  exit 1
fi

printf 'secrets cache removal checks passed\n'
