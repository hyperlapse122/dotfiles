#!/usr/bin/env bash
set -euo pipefail

# Proves .chezmoitemplates/agent-roster-validate.tmpl accepts the committed
# agents.roster (KTD2) and fails the render on each declared defect.
#
# Positive coverage renders the real repo data with no override. Negative
# coverage overrides agents.roster.workers wholesale via --override-data,
# which chezmoi REPLACES rather than merges elementwise for a list-typed
# field (confirmed empirically: two entries in the override produce exactly
# two entries in the rendered result, not seven-plus-two). This is the same
# technique test-omp-plugin-reconcile.sh uses to exercise
# agents.omp.pluginsRemoved, so a fixture never touches the committed yaml.
#
# Payload/roster parity (KTD6) is U3's job and is not added here — the spot
# below is left for it.

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
chezmoi_bin=$(command -v "${CHEZMOI:-chezmoi}") ||
  { echo "test-agent-roster: chezmoi is not on PATH" >&2; exit 1; }

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/agent-roster-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-agent-roster: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

mkdir -p "$scratch/home" "$scratch/bin" "$scratch/target"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 0700 "$scratch/bin/op"

wrapper="$scratch/roster-wrapper.tmpl"
printf '%s\n' '{{- includeTemplate "agent-roster-validate.tmpl" (dict "roster" .agents.roster) -}}' >"$wrapper"

# --- positive: the committed roster renders and prints seven ids ----------- #

positive_out="$scratch/positive.out"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$wrapper" "$positive_out" ||
  fail 'the committed roster failed to render'
model_count=$(grep -c . "$positive_out")
[[ $model_count -eq 7 ]] || fail "the committed roster printed $model_count model id(s), want 7"

# --- negative and alternate-valid cases ------------------------------------ #

assert_render_fails() {
  local label=$1 workers_json=$2 want=$3
  local override out err
  override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$workers_json")
  out="$scratch/$label.out"
  err="$scratch/$label.err"
  if render "$repo_root" "$scratch" "$chezmoi_bin" linux "$wrapper" "$out" "$override" 2>"$err"; then
    fail "$label: expected a failed render, got exit 0"
  fi
  grep -qF -- "$want" "$err" ||
    fail "$label: render failed without the expected diagnostic ($want): $(cat "$err")"
}

assert_render_ok() {
  local label=$1 workers_json=$2
  local override out err
  override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$workers_json")
  out="$scratch/$label.out"
  err="$scratch/$label.err"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$wrapper" "$out" "$override" 2>"$err" ||
    fail "$label: expected a successful render, got a failure: $(cat "$err")"
}

# A duplicate id fails the render naming the id.
assert_render_fails duplicate-id \
  '[{"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"brief":"x"},
    {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"brief":"x"}]' \
  'duplicate worker id "claude-fable"'

# An omp model without the google-antigravity/ provider prefix fails.
assert_render_fails omp-missing-prefix \
  '[{"id":"omp-flash","agent":"omp","model":"gemini-3.8-flash","effort":"high","shapes":["implementation"],"brief":"x"}]' \
  'does not start with google-antigravity/'

# An empty brief fails.
assert_render_fails empty-brief \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":""}]' \
  'has an empty brief'

# A roster missing a judgment shape for codex fails.
assert_render_fails codex-missing-judgment \
  '[{"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["fallback"],"brief":"x"}]' \
  'no codex entry declares the judgment shape'

# Two claude implementation entries distinguished by rung (sonnet, opus) pass.
assert_render_ok claude-two-rungs \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-opus","agent":"claude","model":"opus","effort":"medium","shapes":["implementation"],"rung":"opus","brief":"x"},
    {"id":"codex-astra","agent":"codex","model":"gpt-6-astra","effort":"medium","shapes":["judgment"],"brief":"x"}]'

# Two claude implementation entries sharing a rung fail the render naming it.
assert_render_fails claude-duplicate-rung \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-opus","agent":"claude","model":"opus","effort":"medium","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"codex-astra","agent":"codex","model":"gpt-6-astra","effort":"medium","shapes":["judgment"],"brief":"x"}]' \
  'duplicate rung "sonnet" for agent claude'

# --- U3 adds payload/roster parity cases here (KTD6); none belong in U1. --- #

printf 'agent roster: ok\n'
