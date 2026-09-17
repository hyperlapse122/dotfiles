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
# The sibling agents.roster.lead map SURVIVES a workers-only override
# (confirmed empirically: the duplicate-id fixture below, which overrides
# only .agents.roster.workers, still fails with "duplicate worker id
# \"claude-fable\"" rather than a lead diagnostic — chezmoi's override merge
# is recursive on the map, replacing only the workers leaf it names and
# leaving the committed lead map in place). Lead fixtures therefore cannot
# use --override-data anyway (see lead_wrapper below), but if they could,
# this is why a workers-only override would not need to also restate lead.
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

# --- positive: the committed roster renders and prints six ids ------------ #

positive_out="$scratch/positive.out"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$wrapper" "$positive_out" ||
  fail 'the committed roster failed to render'
model_count=$(grep -c . "$positive_out")
[[ $model_count -eq 6 ]] || fail "the committed roster printed $model_count model id(s), want 6"

# --- negative and alternate-valid cases ------------------------------------ #

# Shared render-and-expect-failure tail for assert_render_fails and
# lead_wrapper below. `override` is optional: when a caller omits it, render
# is called with the same argument count it gets without one, not with an
# empty string appended (the trailing-arg form still ends up equivalent inside
# render() itself, but the call-site shape stays exactly as before).
expect_render_failure() {
  local label=$1 template=$2 want=$3
  local override=${4:-}
  local out err
  out="$scratch/$label.out"
  err="$scratch/$label.err"
  if [[ -n "$override" ]]; then
    if render "$repo_root" "$scratch" "$chezmoi_bin" linux "$template" "$out" "$override" 2>"$err"; then
      fail "$label: expected a failed render, got exit 0"
    fi
  else
    if render "$repo_root" "$scratch" "$chezmoi_bin" linux "$template" "$out" 2>"$err"; then
      fail "$label: expected a failed render, got exit 0"
    fi
  fi
  grep -qF -- "$want" "$err" ||
    fail "$label: render failed without the expected diagnostic ($want): $(cat "$err")"
}

assert_render_fails() {
  local label=$1 workers_json=$2 want=$3
  local override
  override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$workers_json")
  expect_render_failure "$label" "$wrapper" "$want" "$override"
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

# Two claude implementation entries distinguished by rung (sonnet, a fake
# second rung) pass. The second rung is a visibly fake id rather than `opus`,
# which the roster no longer declares.
assert_render_ok claude-two-rungs \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-stub-rung","agent":"claude","model":"claude-9.9-stub","effort":"medium","shapes":["implementation"],"rung":"stub-rung","brief":"x"},
    {"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["judgment","fallback"],"brief":"x"}]'

# Two claude implementation entries sharing a rung fail the render naming it.
assert_render_fails claude-missing-rung \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"brief":"x"},
    {"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["judgment","fallback"],"brief":"x"}]' \
  'is a claude implementation entry without rung'

assert_render_fails claude-duplicate-rung \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-stub-rung","agent":"claude","model":"claude-9.9-stub","effort":"medium","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["judgment","fallback"],"brief":"x"}]' \
  'duplicate rung "sonnet" for agent claude'

# --- lead map validation ---------------------------------------------------- #
#
# A recursive map merge cannot delete a key, so --override-data on
# agents.roster.lead can never produce an entry that OMITS a field (only add
# or replace one). Each fixture instead composes a wrapper template that
# builds the roster from a literal Go-template lead map and the committed
# .agents.roster.workers, with no override at all.

lead_wrapper() {
  local label=$1 lead_expr=$2 want=$3
  local wrapper
  wrapper="$scratch/$label-wrapper.tmpl"
  printf '%s\n' "{{- includeTemplate \"agent-roster-validate.tmpl\" (dict \"roster\" (dict \"lead\" $lead_expr \"workers\" .agents.roster.workers)) -}}" >"$wrapper"
  expect_render_failure "$label" "$wrapper" "$want"
}

# A codex lead entry without effort fails.
lead_wrapper lead-codex-missing-effort \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "model" "gpt-6-astra"))' \
  'lead.codex is missing effort'

# A codex lead entry without model fails.
lead_wrapper lead-codex-missing-model \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "effort" "medium"))' \
  'lead.codex is missing model'

# A claude lead entry without model fails.
lead_wrapper lead-claude-missing-model \
  '(dict "claude" (dict) "codex" (dict "model" "gpt-6-astra" "effort" "medium"))' \
  'lead.claude is missing model'

# A null codex model has the key but no usable value, and must fail the same
# way an absent key does (a YAML `effort: null` has the key, so a bare
# hasKey/eq-empty check lets it through).
lead_wrapper lead-codex-null-model \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "model" (fromJson "null") "effort" "medium"))' \
  'lead.codex is missing model'

# A null codex effort must fail the same way.
lead_wrapper lead-codex-null-effort \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "model" "gpt-6-astra" "effort" (fromJson "null")))' \
  'lead.codex is missing effort'

# A null claude model must fail the same way.
lead_wrapper lead-claude-null-model \
  '(dict "claude" (dict "model" (fromJson "null")) "codex" (dict "model" "gpt-6-astra" "effort" "medium"))' \
  'lead.claude is missing model'

# A wrong-typed field (a number where a string is required) must fail too.
lead_wrapper lead-codex-model-wrong-type \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "model" 42 "effort" "medium"))' \
  'lead.codex is missing model'

# A lead map with no codex key fails.
lead_wrapper lead-no-codex-entry \
  '(dict "claude" (dict "model" "opus[1m]"))' \
  'agents.roster.lead declares no codex entry'

# A lead map carrying an unknown agent fails.
lead_wrapper lead-unknown-agent \
  '(dict "claude" (dict "model" "opus[1m]") "codex" (dict "model" "gpt-6-astra" "effort" "medium") "gemini" (dict "model" "x"))' \
  'agents.roster.lead declares unknown agent "gemini"'

# --- payload/roster parity (KTD6) ------------------------------------------ #
#
# Parity is asserted by RENDERING, never by grepping a literal: the payload
# bodies are templates over the roster, so the only honest question is whether
# the id set they render equals the id set the roster declares.

everyone_wrapper="$scratch/everyone-wrapper.tmpl"
coordinator_wrapper="$scratch/coordinator-wrapper.tmpl"
printf '%s\n' '{{- includeTemplate "orchestration-everyone.tmpl" (dict "ctx" . "harness" "claude") -}}' >"$everyone_wrapper"
printf '%s\n' '{{- includeTemplate "orchestration-coordinator.tmpl" (dict "ctx" . "harness" "claude") -}}' >"$coordinator_wrapper"

everyone_body="$scratch/everyone.md"
coordinator_body="$scratch/coordinator.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$everyone_wrapper" "$everyone_body" ||
  fail 'the everyone payload body failed to render against the committed roster'
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$coordinator_body" ||
  fail 'the coordinator payload body failed to render against the committed roster'

for body in "$everyone_body" "$coordinator_body"; do
  grep -F '{{' "$body" >/dev/null && fail "$(basename "$body") still carries a template action"
done

# A vendor model id is `<provider>/`-prefixed gemini/gpt token or one of the
# three Claude rung names in backticks; nothing else in this prose looks like
# one. Reading them out of the text is what makes the reverse direction real:
# a hand-written id that is not in the roster has nowhere to hide.
extract_model_ids() {
  cat -- "$@" | {
    grep -oE '(google-antigravity/)?(gemini|gpt)-[0-9][0-9a-zA-Z.-]*' || true
  } | sed 's/[.,]*$//' | sort -u
  cat -- "$@" | {
    grep -oE '`(fable|opus|sonnet)`' || true
  } | tr -d '`' | sort -u
}

roster_models="$scratch/roster-models.txt"
sort -u "$positive_out" >"$roster_models"

# Prose and payload prose both name an Antigravity model by its bare id as
# often as by its provider-qualified one, and they are the same seat. Membership
# is therefore tested against both spellings; the forward direction below still
# demands the roster's own exact id somewhere in the rendered payloads.
roster_aliases="$scratch/roster-aliases.txt"
sed 's|^google-antigravity/||' "$roster_models" | cat - "$roster_models" | sort -u >"$roster_aliases"

rendered_models="$scratch/rendered-models.txt"
extract_model_ids "$everyone_body" "$coordinator_body" | sort -u >"$rendered_models"

while IFS= read -r model; do
  [[ -z $model ]] && continue
  grep -Fxq -- "$model" "$rendered_models" ||
    fail "roster model $model is named by no rendered payload body"
done <"$roster_models"

while IFS= read -r model; do
  [[ -z $model ]] && continue
  grep -Fxq -- "$model" "$roster_aliases" ||
    fail "the rendered payloads name $model, which the roster does not declare"
done <"$rendered_models"

# R4: `fable` is the judgment model, never a sizing rung, and the author of a
# document is no longer excluded from reviewing it.
grep -F 'rung' "$coordinator_body" | grep -F '`fable`' >/dev/null &&
  fail 'the rendered coordinator still names `fable` as a sizing rung'
grep -F 'authored the document under review MUST NOT serve as a reviewer' "$coordinator_body" >/dev/null &&
  fail 'the rendered coordinator still carries the author-exclusion rule'

# KTD4: each Codex seat is asserted by its own rendered pair, read from the
# roster through agent-roster-lookup.tmpl, so a line-level grep for a model
# near an effort cannot tell the seats apart once both resolve to the same
# model.
agent_seat_pair_wrapper="$scratch/agent-seat-pair-wrapper.tmpl"
agent_seat_pair() {
  local agent=$1 shape=$2 override=$3 out
  out="$scratch/$agent-seat-pair-$shape.out"
  printf '%s\n' "{{- \$w := includeTemplate \"agent-roster-lookup.tmpl\" (dict \"roster\" .agents.roster \"agent\" \"$agent\" \"shape\" \"$shape\" \"rung\" \"\" \"name\" \"a $agent $shape entry\") | fromJson -}}{{ \$w.model }} {{ \$w.effort }}" >"$agent_seat_pair_wrapper"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$agent_seat_pair_wrapper" "$out" "$override" ||
    fail "seat pair render failed for agent $agent shape $shape"
  cat "$out"
}

# KTD6/KTD9: the omp seat is chosen by launching the terminal with that
# entry's model; render the mechanical seat through agent-roster-lookup.tmpl
# instead of grepping a hand-written id, so a roster edit to the mechanical
# entry reaches this assertion with no edit here.
grep -F 'worker-start --terminal' "$coordinator_body" >/dev/null ||
  fail 'the rendered coordinator does not carry the omp seat-selection line'
read -r mechanical_model mechanical_effort <<<"$(agent_seat_pair omp mechanical '')"
grep -F -- "$mechanical_model" "$coordinator_body" >/dev/null ||
  fail 'the omp seat-selection line does not name the mechanical entry model'

# The one-seat branch (`{{ if and (eq $mechanical.model $ompImpl.model) (eq
# $mechanical.effort $ompImpl.effort) }}`) collapses mechanical and
# implementation into a single seat when both resolve to the same pair. The
# committed roster's mechanical and implementation entries share a model but
# not an effort (low vs high), so it takes the TWO-seat branch instead; assert
# that rendered phrase directly rather than relying on a model id that other
# rows already satisfy.
read -r omp_impl_model omp_impl_effort <<<"$(agent_seat_pair omp implementation '')"
grep -F -- "\`$mechanical_model\` at \`$mechanical_effort\` for mechanical work, \`$omp_impl_model\` at \`$omp_impl_effort\` otherwise" "$coordinator_body" >/dev/null ||
  fail 'the omp seat-selection line does not render the two-seat branch for the committed roster'
grep -F "one seat (\`$omp_impl_model\` at \`$omp_impl_effort\`) for mechanical and implementation work alike" "$coordinator_body" >/dev/null &&
  fail 'the committed two-seat roster rendered the one-seat branch'

# A single omp entry carrying both shapes, at one pair, proves the one-seat
# branch still renders when a future roster collapses back to it.
one_seat_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"max","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["judgment","fallback"],"brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation"],"brief":"x"}]'
one_seat_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$one_seat_workers")
one_seat_body="$scratch/coordinator-one-seat.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$one_seat_body" "$one_seat_override" ||
  fail 'the coordinator body failed to render against a single-omp-entry stub'
grep -F 'one seat (`google-antigravity/gemini-3.8-flash` at `high`) for mechanical and implementation work alike' "$one_seat_body" >/dev/null ||
  fail 'the single-omp-entry stub does not render the one-seat branch'
grep -F 'for mechanical work, ' "$one_seat_body" >/dev/null &&
  fail 'the single-omp-entry stub rendered the two-seat branch'

# R13: the routing table has four rows; the brief-guidance table has five.
count_table_rows() {
  awk -v header="$2" '
    index($0, header) == 1 { inside = 1; next }
    inside && $0 !~ /^\|/ { inside = 0 }
    inside && $0 ~ /^\| *-+/ { next }
    inside { rows++ }
    END { print rows + 0 }
  ' "$1"
}
routing_rows=$(count_table_rows "$coordinator_body" '| Work shape |')
[[ $routing_rows -eq 4 ]] || fail "the routing table rendered $routing_rows row(s), want 4"
brief_rows=$(count_table_rows "$coordinator_body" '| Model |')
[[ $brief_rows -eq 6 ]] || fail "the brief-guidance table rendered $brief_rows row(s), want 6"

read -r judge_model judge_effort <<<"$(agent_seat_pair codex judgment '')"
read -r fallback_model fallback_effort <<<"$(agent_seat_pair codex fallback '')"

judgment_anchor="opinion launches \`$judge_model\` with \`$judge_effort\` reasoning effort"
fallback_anchor="after the Gemini row — launches \`$fallback_model\` with \`$fallback_effort\` reasoning effort"

grep -F -- "$judgment_anchor" "$everyone_body" >/dev/null ||
  fail 'the everyone body does not carry the judgment seat anchor with its rendered pair'
grep -F -- "$fallback_anchor" "$everyone_body" >/dev/null ||
  fail 'the everyone body does not carry the fallback seat anchor with its rendered pair'
grep -F 'launch.requested' "$everyone_body" >/dev/null ||
  fail 'the everyone body lost the launch-receipt comparison rule'

# KTD4: the Claude judgment pair is asserted the same way, from its own
# rendered seat rather than a literal.
read -r claude_judge_model claude_judge_effort <<<"$(agent_seat_pair claude judgment '')"
claude_launch_anchor="--model $claude_judge_model --effort $claude_judge_effort"
grep -F -- "$claude_launch_anchor" "$coordinator_body" >/dev/null ||
  fail 'the coordinator body does not carry the claude judgment launch anchor'
grep -F 'launch.requested' "$coordinator_body" >/dev/null ||
  fail 'the coordinator body lost the claude launch-receipt comparison rule'
grep -F 'records the pass as degraded' "$coordinator_body" >/dev/null ||
  fail 'the coordinator body lost the degraded-pass recording rule'

# R8: the fallback seat is no longer justified by a cost comparison with the
# judgment seat.
grep -F 'belongs to recovery' "$everyone_body" >/dev/null &&
  fail 'the everyone body still justifies the fallback seat by a cost comparison'

# A two-entry Codex stub with each seat on a distinct model proves the anchors
# resolve independently: one rendered match cannot satisfy both assertions.
two_seat_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"max","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"codex-judge","agent":"codex","model":"gpt-9.8-judge","effort":"medium","shapes":["judgment"],"brief":"x"},
  {"id":"codex-fallback","agent":"codex","model":"gpt-9.9-fallback","effort":"high","shapes":["fallback"],"brief":"x"},
  {"id":"omp-flash-mechanical","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"low","shapes":["mechanical"],"brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["implementation"],"brief":"x"}]'
two_seat_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$two_seat_workers")
two_seat_everyone="$scratch/everyone-two-seat.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$everyone_wrapper" "$two_seat_everyone" "$two_seat_override" ||
  fail 'the everyone body failed to render against the two-entry Codex stub'

two_seat_judge_anchor='opinion launches `gpt-9.8-judge` with `medium` reasoning effort'
two_seat_judge_leak='opinion launches `gpt-9.9-fallback` with `high` reasoning effort'
two_seat_fallback_anchor='after the Gemini row — launches `gpt-9.9-fallback` with `high` reasoning effort'
two_seat_fallback_leak='after the Gemini row — launches `gpt-9.8-judge` with `medium` reasoning effort'

grep -F -- "$two_seat_judge_anchor" "$two_seat_everyone" >/dev/null ||
  fail 'two-entry Codex stub: the judgment anchor does not carry the judgment seat model'
grep -F -- "$two_seat_judge_leak" "$two_seat_everyone" >/dev/null &&
  fail 'two-entry Codex stub: the judgment anchor leaked the fallback seat model'
grep -F -- "$two_seat_fallback_anchor" "$two_seat_everyone" >/dev/null ||
  fail 'two-entry Codex stub: the fallback anchor does not carry the fallback seat model'
grep -F -- "$two_seat_fallback_leak" "$two_seat_everyone" >/dev/null &&
  fail 'two-entry Codex stub: the fallback anchor leaked the judgment seat model'

# --- AE9: a roster edit re-renders the payload, with no hand edit ----------- #

# The stub moves three entries, not one: the single omp seat's model exercises
# the coordinator body (AE9), and the authoring and judgment efforts are set
# to distinct, non-`max` values so the elevation line and the launch line are
# each proven to read their own roster entry rather than a stale literal.
stub_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"low","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"codex-luna","agent":"codex","model":"gpt-9.9-stub","effort":"medium","shapes":["judgment","fallback"],"brief":"x"},
  {"id":"omp-flash-mechanical","agent":"omp","model":"google-antigravity/gemini-9.9-stub","effort":"low","shapes":["mechanical"],"brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-9.9-stub","effort":"high","shapes":["implementation"],"brief":"x"}]'
stub_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$stub_workers")
stub_body="$scratch/coordinator-stub.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$stub_body" "$stub_override" ||
  fail 'AE9: the coordinator body failed to render against a changed roster'
grep -F 'google-antigravity/gemini-9.9-stub' "$stub_body" >/dev/null ||
  fail 'AE9: a changed mechanical model did not reach the rendered coordinator'
grep -F 'google-antigravity/gemini-3.8-flash' "$stub_body" >/dev/null &&
  fail 'AE9: the superseded mechanical model survived the roster change'
grep -F -- '--effort low' "$stub_body" >/dev/null ||
  fail 'AE9: a changed claude authoring effort did not reach the elevation launch line'
grep -F -- '--effort high' "$stub_body" >/dev/null ||
  fail 'AE9: a changed claude judgment effort did not reach the launch anchor'
grep -F -- '--effort max' "$stub_body" >/dev/null &&
  fail 'AE9: the coordinator body still names an effort the stub roster does not declare'

# A two-entry omp roster proves a future distinct mechanical entry still
# drives its consumers with no template change: the mechanical row's first
# recipient and the two-seat branch of the seat-selection line both name it.
two_entry_omp_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"max","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["judgment","fallback"],"brief":"x"},
  {"id":"omp-lite-stub","agent":"omp","model":"google-antigravity/gemini-9.8-lite-stub","effort":"high","shapes":["mechanical"],"brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["implementation"],"brief":"x"}]'
two_entry_omp_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$two_entry_omp_workers")
two_entry_omp_body="$scratch/coordinator-two-entry-omp.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$two_entry_omp_body" "$two_entry_omp_override" ||
  fail 'the coordinator body failed to render against a two-entry omp stub'
grep -F -- '`omp` `google-antigravity/gemini-9.8-lite-stub` high' "$two_entry_omp_body" >/dev/null ||
  fail 'the two-entry omp stub: the mechanical row does not name the fake mechanical model as first recipient'
grep -F -- '`google-antigravity/gemini-9.8-lite-stub` at `high` for mechanical work, `google-antigravity/gemini-3.8-flash` at `high` otherwise' "$two_entry_omp_body" >/dev/null ||
  fail 'the two-entry omp stub: the seat-selection line does not render the two-seat branch'

# --- committed prose (R6): README.md and AGENTS.md are never rendered ------- #
#
# KTD5: the prose allowlist is wider than the payload-parity set above. Prose
# legitimately names a lead model too -- gpt-6-astra is the Codex lead, not a
# worker -- but no rendered payload body names a lead seat, so the parity
# loops above (lines ~221-231) keep reading roster_aliases, unchanged. Lead
# ids are read through execute-template rather than hardcoded, so this scan
# follows agents.roster.lead rather than pinning today's committed values.
lead_wrapper_tmpl="$scratch/prose-lead-wrapper.tmpl"
printf '%s\n' '{{- range $agent, $entry := .agents.roster.lead -}}{{ $entry.model }}
{{ end -}}' >"$lead_wrapper_tmpl"
lead_models="$scratch/lead-models.txt"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$lead_wrapper_tmpl" "$lead_models" ||
  fail 'the committed agents.roster.lead map failed to render'

prose_allowlist="$scratch/prose-allowlist.txt"
sort -u "$roster_aliases" "$lead_models" >"$prose_allowlist"

prose_models="$scratch/prose-models.txt"
extract_model_ids "$repo_root/README.md" "$repo_root/AGENTS.md" >"$prose_models"
while IFS= read -r model; do
  [[ -z $model ]] && continue
  grep -Fxq -- "$model" "$prose_allowlist" ||
    fail "committed prose names worker model $model, which the roster does not declare"
done <"$prose_models"

# The scan has to be able to fail, or it asserts nothing about prose at all.
# The fixture id must stay outside both the worker and the lead sets, or this
# self-check stops proving anything about the wider prose allowlist above.
stub_prose="$scratch/stub-README.md"
printf 'The mechanical seat runs `google-antigravity/gemini-0.0-unknown`.\n' >"$stub_prose"
if extract_model_ids "$stub_prose" | grep -Fxq -- 'google-antigravity/gemini-0.0-unknown'; then
  grep -Fxq -- 'google-antigravity/gemini-0.0-unknown' "$prose_allowlist" &&
    fail 'the prose scan fixture id is somehow in the roster'
else
  fail 'the prose scan does not see a model id a stub README names'
fi

# R2: the retired worker id and the stale worker count must not resurface.
grep -qF 'codex-astra' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still names the retired codex-astra worker id'
grep -qF 'seven worker' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still describes seven workers'
grep -qF 'omp-flash-lite' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still names the retired omp-flash-lite worker id'
grep -qF 'six worker' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still describes six workers'

# --- plugin manifests track the roster (R17) ------------------------------- #

plugin_manifests=(
  dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl
  dot_local/share/dotfiles-codex-plugin/dot_codex-plugin/plugin.json.tmpl
)
for manifest in "${plugin_manifests[@]}"; do
  name=$(basename "$(dirname "$manifest")")
  base="$scratch/$name-base.json"
  again="$scratch/$name-again.json"
  moved="$scratch/$name-moved.json"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$manifest" "$base" ||
    fail "$manifest failed to render"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$manifest" "$again" ||
    fail "$manifest failed to render a second time"
  diff -q "$base" "$again" >/dev/null ||
    fail "$manifest version moved with no input change"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$repo_root/$manifest" "$moved" "$stub_override" ||
    fail "$manifest failed to render against a changed roster"
  diff -q "$base" "$moved" >/dev/null &&
    fail "$manifest version did not move when a roster entry changed"
done

# --- the apply-time payload assertion -------------------------------------- #

assert_script="$scratch/assert-orchestration-hook.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$repo_root/.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl" "$assert_script" ||
  fail 'the orchestration-hook assertion script failed to render'
payload_dir="$scratch/home/.local/share/orchestration-hook"
mkdir -p "$payload_dir" "$scratch/home/.local/libexec"
staged_binary="$scratch/home/.local/libexec/orchestration-hook"
printf '#!/usr/bin/env bash\nexit 0\n' >"$staged_binary"
chmod 0755 "$staged_binary"

for missing in everyone coordinator; do
  cp "$everyone_body" "$payload_dir/everyone.md"
  cp "$coordinator_body" "$payload_dir/coordinator.md"
  rm -f "$payload_dir/$missing.md"
  if bash "$assert_script" 2>"$scratch/assert-$missing.err"; then
    fail "a missing $missing.md payload must fail the apply"
  fi
  grep -qF "$payload_dir/$missing.md" "$scratch/assert-$missing.err" ||
    fail "the assertion must name the missing payload file $missing.md"
  : >"$payload_dir/$missing.md"
  if bash "$assert_script" 2>"$scratch/assert-$missing-empty.err"; then
    fail "an empty $missing.md payload must fail the apply"
  fi
  grep -qF "$payload_dir/$missing.md" "$scratch/assert-$missing-empty.err" ||
    fail "the assertion must name the empty payload file $missing.md"
done

cp "$everyone_body" "$payload_dir/everyone.md"
cp "$coordinator_body" "$payload_dir/coordinator.md"
assert_out=$(bash "$assert_script" 2>&1) ||
  fail "the assertion must pass once both payload files are staged: $assert_out"
[[ -z $assert_out ]] || fail "the assertion must stay silent on a converged host (got: $assert_out)"

printf 'agent roster: ok\n'
