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
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

mkdir -p "$scratch/home" "$scratch/bin" "$scratch/target"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 0700 "$scratch/bin/op"

wrapper="$scratch/roster-wrapper.tmpl"
printf '%s\n' '{{- includeTemplate "agent-roster-validate.tmpl" (dict "roster" .agents.roster) -}}' >"$wrapper"

# --- positive: the committed roster renders and prints five ids ----------- #

positive_out="$scratch/positive.out"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$wrapper" "$positive_out" ||
  fail 'the committed roster failed to render'
model_count=$(grep -c . "$positive_out")
[[ $model_count -eq 5 ]] || fail "the committed roster printed $model_count model id(s), want 5"
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

# A null brief fails too. The learning at
# docs/solutions/integration-issues/chezmoi-template-required-field-guard-accepts-null.md
# proved that hasKey plus an empty-string test passes a key declared null, so the
# guard carries a kindIs arm and this fixture is what holds it there.
assert_render_fails null-brief \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":null}]' \
  'has an empty brief'

# A worker declaring the retired fallback shape fails with unknown-shape.
assert_render_fails worker-declaring-fallback \
  '[{"id":"codex-luna","agent":"codex","model":"gpt-5.6-luna","effort":"max","shapes":["fallback"],"brief":"x"}]' \
  'declares unknown shape "fallback"'

# A roster missing a mechanical shape for omp fails.
assert_render_fails omp-missing-mechanical \
  '[{"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"rung":"judgment-escalation","brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["implementation","judgment"],"brief":"x"}]' \
  'no omp entry declares the mechanical shape'

# A roster missing an implementation shape for omp fails.
assert_render_fails omp-missing-implementation \
  '[{"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"rung":"judgment-escalation","brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","judgment"],"brief":"x"}]' \
  'no omp entry declares the implementation shape'

# A roster missing a judgment shape for omp fails.
assert_render_fails omp-missing-judgment \
  '[{"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"rung":"judgment-escalation","brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation"],"brief":"x"}]' \
  'no omp entry declares the judgment shape'

# An edge case: a fixture with two omp rows still renders, so the guard
# enforces presence and not a count.
assert_render_ok omp-two-rows \
  '[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"medium","shapes":["authoring"],"brief":"x"},
    {"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"rung":"judgment-escalation","brief":"x"},
    {"id":"claude-opus-judgment","agent":"claude","model":"opus","effort":"xhigh","shapes":["judgment"],"rung":"judgment-deep","brief":"x"},
    {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"omp-flash-mech","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"low","shapes":["mechanical"],"brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["implementation","judgment"],"brief":"x"}]'

# Two claude implementation entries distinguished by rung (sonnet, a fake
# second rung) pass. The second rung is a visibly fake id rather than `opus`,
# which the roster no longer declares. An omp entry carrying all three shapes
# is present so this positive fixture covers the omp presence guards.
assert_render_ok claude-two-rungs \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-stub-rung","agent":"claude","model":"claude-9.9-stub","effort":"medium","shapes":["implementation"],"rung":"stub-rung","brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation","judgment"],"brief":"x"}]'

# Two claude implementation entries sharing a rung fail the render naming it.
assert_render_fails claude-missing-rung \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation","judgment"],"brief":"x"}]' \
  'is a claude implementation entry without rung'

assert_render_fails claude-duplicate-rung \
  '[{"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"claude-stub-rung","agent":"claude","model":"claude-9.9-stub","effort":"medium","shapes":["implementation"],"rung":"sonnet","brief":"x"},
    {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation","judgment"],"brief":"x"}]' \
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

# R4: `fable` is the judgment-escalation rung, reachable only outside the
# primary routing table, and is never a sizing rung; the author of a
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
  local agent=$1 shape=$2 override=$3 rung=${4:-} out
  out="$scratch/$agent-seat-pair-$shape${rung:+-$rung}.out"
  printf '%s\n' "{{- \$w := includeTemplate \"agent-roster-lookup.tmpl\" (dict \"roster\" .agents.roster \"agent\" \"$agent\" \"shape\" \"$shape\" \"rung\" \"$rung\" \"name\" \"a $agent $shape entry\") | fromJson -}}{{ \$w.model }} {{ \$w.effort }}" >"$agent_seat_pair_wrapper"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$agent_seat_pair_wrapper" "$out" "$override" ||
    fail "seat pair render failed for agent $agent shape $shape"
  cat "$out"
}

# KTD6/KTD9: the terminal is launched per dispatch with that entry's model;
# render the mechanical seat through agent-roster-lookup.tmpl instead of
# grepping a hand-written id, so a roster edit to the mechanical entry reaches
# this assertion with no edit here.
grep -F 'worker-start --task <task_id> --terminal <handle>' "$coordinator_body" >/dev/null ||
  fail 'the rendered coordinator does not carry the omp seat-selection line'
read -r mechanical_model mechanical_effort <<<"$(agent_seat_pair omp mechanical '')"
grep -F -- "$mechanical_model" "$coordinator_body" >/dev/null ||
  fail 'the omp seat-selection line does not name the mechanical entry model'

# The committed roster's mechanical and implementation entries resolve to the
# single omp-flash seat (high), so it renders the one-seat branch.
read -r omp_impl_model omp_impl_effort <<<"$(agent_seat_pair omp implementation '')"
grep -F "one seat (\`$omp_impl_model\` at \`$omp_impl_effort\`) for mechanical and implementation work alike" "$coordinator_body" >/dev/null ||
  fail 'the committed roster does not render the one-seat branch'
grep -F 'for mechanical work, ' "$coordinator_body" >/dev/null &&
  fail 'the committed roster rendered the two-seat branch'
# A single omp entry carrying both shapes, at one pair, proves the one-seat
# branch still renders when a future roster collapses back to it.
one_seat_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"max","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"medium","shapes":["judgment"],"rung":"judgment-deep","brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["mechanical","implementation","judgment"],"rung":"judgment-standard","brief":"x"},
  {"id":"omp-judgment-cheap-stub","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"low","shapes":["judgment"],"rung":"judgment-cheap","brief":"x"}]'
one_seat_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$one_seat_workers")
one_seat_body="$scratch/coordinator-one-seat.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$one_seat_body" "$one_seat_override" ||
  fail 'the coordinator body failed to render against a single-omp-entry stub'
grep -F 'one seat (`google-antigravity/gemini-3.8-flash` at `high`) for mechanical and implementation work alike' "$one_seat_body" >/dev/null ||
  fail 'the single-omp-entry stub does not render the one-seat branch'
grep -F 'for mechanical work, ' "$one_seat_body" >/dev/null &&
  fail 'the single-omp-entry stub rendered the two-seat branch'

# R13: the routing table has six rows (mechanical, two implementation rows,
# and three judgment rungs); the brief-guidance table has seven, one per
# committed roster worker including the new claude-opus-judgment row.
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
[[ $routing_rows -eq 5 ]] || fail "the routing table rendered $routing_rows row(s), want 5"
brief_rows=$(count_table_rows "$coordinator_body" '| Model |')
[[ $brief_rows -eq 5 ]] || fail "the brief-guidance table rendered $brief_rows row(s), want 5"

# R30/KTD13: the real-`op` prohibition is brief guidance that exists because a
# Gemini seat ignored the rule in AGENTS.md. Counting rows does not prove the
# text reached the payload, so assert it on the merged omp row by name.
op_rows=$(grep -c 'the real `op`: never invoke it' "$coordinator_body")
[[ $op_rows -eq 1 ]] \
  || fail "the rendered brief table carries the real-op prohibition on $op_rows row(s), want 1"

# U1: The rendered Everyone body contains no Codex launch rule.
grep -F 'When another agent launches Codex' "$everyone_body" >/dev/null &&
  fail 'the everyone body still carries the Codex launch rule'

# U1: The rendered coordinator body routing table names no codex recipient.
grep -F '|' "$coordinator_body" | grep -F '`codex`' >/dev/null &&
  fail 'the coordinator routing table still names codex'

# U1 AE3: The implementation row failure column names sonnet after omp.
grep -F 're-size on the four signals; at the same size, `omp`' "$coordinator_body" | grep -F 'then `claude` `sonnet`' >/dev/null ||
  fail 'AE3: implementation row failure column does not name sonnet after omp'

# U1 AE1: The judgment-deep row names claude opus and omp over the same brief,
# and a degraded reviewer leaves claude at xhigh.
grep -F 'Judgment work at the `judgment-deep` rung' "$coordinator_body" | grep -F '`claude` `opus` xhigh and `omp`' | grep -F 'over the same brief' >/dev/null ||
  fail 'AE1: judgment-deep row does not name claude opus and omp over the same brief'
grep -F 'the review proceeds on the other, recorded as degraded, and the `claude` reviewer keeps its `judgment-deep` effort' "$coordinator_body" >/dev/null ||
  fail 'AE1: coordinator body does not carry the rule that claude keeps judgment-deep effort when degraded'

# U1: The rendered coordinator says a Compound Engineering cross-model peer,
# codex included, resolves to the routing table's recipients.
grep -F 'A Compound Engineering cross-model peer or work-engine preference, its default `codex` peer included, resolves to the routing table'"'"'s recipients and never to a Codex worker.' "$coordinator_body" >/dev/null ||
  fail 'coordinator does not carry the CE peer routing rule naming codex'
# KTD4: the Claude judgment-deep pair is asserted the same way, from its own
# rendered seat rather than a literal, and pinned to the judgment-deep rung
# explicitly rather than whichever claude judgment row happens to sort last.
read -r claude_judge_model claude_judge_effort <<<"$(agent_seat_pair claude judgment '' judgment-deep)"
claude_launch_anchor="--model $claude_judge_model --effort $claude_judge_effort"
grep -F -- "$claude_launch_anchor" "$coordinator_body" >/dev/null ||
  fail 'the coordinator body does not carry the claude judgment-deep launch anchor'
grep -F 'launch.requested' "$coordinator_body" >/dev/null ||
  fail 'the coordinator body lost the claude launch-receipt comparison rule'
grep -F 'records the pass as degraded' "$coordinator_body" >/dev/null ||
  fail 'the coordinator body lost the degraded-pass recording rule'

# The opus row is unprobed by apply (it never checks claude/omp roster
# entries), so this is the one guard that catches a model-id or effort typo
# on claude-opus-judgment. Asserted through the same rung-pinned lookup, not
# a literal, so a future model or effort change reaches this check unedited.
[[ $claude_judge_model == opus && $claude_judge_effort == xhigh ]] ||
  fail "the committed claude judgment-deep entry is $claude_judge_model/$claude_judge_effort, want opus/xhigh"

# U2 AE2: The standard-and-cheap judgment row names omp alone, and its failure
# and unavailable cells name sonnet, recorded as degraded.
read -r judgment_omp_model judgment_omp_effort <<<"$(agent_seat_pair omp judgment '')"
grep -F "Judgment work at the \`judgment-standard\` or \`judgment-cheap\` rung" "$coordinator_body" | grep -F "\`omp\` \`$judgment_omp_model\` $judgment_omp_effort" | grep -F "\`claude\` \`sonnet\` replaces it, recorded as degraded" >/dev/null ||
  fail 'AE2: the coordinator body does not carry the standard-and-cheap judgment row naming omp alone with sonnet fallback'
# --- AE9: a roster edit re-renders the payload, with no hand edit ----------- #

# The stub moves three entries, not one: the single omp seat's model exercises
# the coordinator body (AE9), and the authoring and judgment efforts are set
# to distinct, non-`max` values so the elevation line and the launch line are
# each proven to read their own roster entry rather than a stale literal.
stub_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"low","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"rung":"judgment-deep","brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"omp-flash-mechanical","agent":"omp","model":"google-antigravity/gemini-9.9-stub","effort":"low","shapes":["mechanical","judgment"],"rung":"judgment-cheap","brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-9.9-stub","effort":"high","shapes":["implementation","judgment"],"rung":"judgment-standard","brief":"x"}]'
stub_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$stub_workers")
stub_body="$scratch/coordinator-stub.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$stub_body" "$stub_override" ||
  fail 'AE9: the coordinator body failed to render against a changed roster'
grep -F 'google-antigravity/gemini-9.9-stub' "$stub_body" >/dev/null ||
  fail 'AE9: a changed mechanical model did not reach the rendered coordinator'
grep -F 'google-antigravity/gemini-3.8-flash' "$stub_body" >/dev/null &&
  fail 'AE9: the superseded mechanical model survived the roster change'
# Anchored on the surrounding sentence, not on the bare token: searching the
# whole body for each effort separately passes even when the two template
# references are swapped, because both tokens are still present somewhere.
grep -F -- 'launched with `--model fable --effort low`' "$stub_body" >/dev/null ||
  fail 'AE9: the elevation line does not carry the authoring pair'
grep -F -- 'selects `--model fable --effort high`' "$stub_body" >/dev/null ||
  fail 'AE9: the judgment launch line does not carry the judgment pair'
grep -F -- '--effort max' "$stub_body" >/dev/null &&
  fail 'AE9: the coordinator body still names an effort the stub roster does not declare'

# A two-entry omp roster proves a future distinct mechanical entry still
# drives its consumers with no template change: the mechanical row's first
# recipient and the two-seat branch of the seat-selection line both name it.
two_entry_omp_workers='[{"id":"claude-fable-authoring","agent":"claude","model":"fable","effort":"max","shapes":["authoring"],"brief":"x"},
  {"id":"claude-fable","agent":"claude","model":"fable","effort":"high","shapes":["judgment"],"rung":"judgment-deep","brief":"x"},
  {"id":"claude-sonnet","agent":"claude","model":"sonnet","effort":"high","shapes":["implementation"],"rung":"sonnet","brief":"x"},
  {"id":"omp-lite-stub","agent":"omp","model":"google-antigravity/gemini-9.8-lite-stub","effort":"high","shapes":["mechanical"],"brief":"x"},
  {"id":"omp-flash","agent":"omp","model":"google-antigravity/gemini-3.8-flash","effort":"high","shapes":["implementation","judgment"],"brief":"x"}]'
two_entry_omp_override=$(printf '{"chezmoi":{"os":"linux"},"agents":{"roster":{"workers":%s}}}' "$two_entry_omp_workers")
two_entry_omp_body="$scratch/coordinator-two-entry-omp.md"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$two_entry_omp_body" "$two_entry_omp_override" ||
  fail 'the coordinator body failed to render against a two-entry omp stub'
grep -F -- '`omp` `google-antigravity/gemini-9.8-lite-stub` high' "$two_entry_omp_body" >/dev/null ||
  fail 'the two-entry omp stub: the mechanical row does not name the fake mechanical model as first recipient'
grep -F -- '`google-antigravity/gemini-9.8-lite-stub` at `high` for mechanical work, `google-antigravity/gemini-3.8-flash` at `high` otherwise' "$two_entry_omp_body" >/dev/null ||
  fail 'the two-entry omp stub: the seat-selection line does not render the two-seat branch'

two_entry_omp_judgment_row=$(grep -F 'judgment-standard` or `judgment-cheap` rung' "$two_entry_omp_body")
[[ -n $two_entry_omp_judgment_row ]] ||
  fail 'the two-entry omp stub: no standard-and-cheap judgment row rendered'
grep -qF -- 'google-antigravity/gemini-3.8-flash' <<<"$two_entry_omp_judgment_row" ||
  fail 'the two-entry omp stub: the judgment row does not name the judgment model'
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
# Until U4 updates committed prose in README.md and AGENTS.md, gpt-5.6-luna is tolerated.
printf 'gpt-5.6-luna\n' | sort -u "$roster_aliases" "$lead_models" - >"$prose_allowlist"

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

# R2: the retired worker id and the stale worker counts must not resurface.
# "seven worker" is not in this list: the roster grew back to seven workers
# with claude-opus-judgment, so that count is current prose, not a retired one.
grep -qF 'codex-astra' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still names the retired codex-astra worker id'
grep -qF 'omp-flash-lite' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still names the retired omp-flash-lite worker id'
grep -qF 'five worker' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still describes five workers'
grep -qF 'six worker' "$repo_root/README.md" "$repo_root/AGENTS.md" &&
  fail 'committed prose still describes six workers'

# --- plugin manifests track the roster (R17) ------------------------------- #

plugin_manifests=(
  dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl
)
for manifest in "${plugin_manifests[@]}"; do
  name=$(basename "$(dirname "$manifest")")
  base="$scratch/$name-base.json"
  again="$scratch/$name-again.json"
  moved="$scratch/$name-moved.json"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/$manifest" "$base" ||
    fail "$manifest failed to render"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/$manifest" "$again" ||
    fail "$manifest failed to render a second time"
  diff -q "$base" "$again" >/dev/null ||
    fail "$manifest version moved with no input change"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$source_root/$manifest" "$moved" "$stub_override" ||
    fail "$manifest failed to render against a changed roster"
  diff -q "$base" "$moved" >/dev/null &&
    fail "$manifest version did not move when a roster entry changed"
done

# --- the apply-time payload assertion -------------------------------------- #

assert_script="$scratch/assert-orchestration-hook.sh"
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$source_root/.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl" "$assert_script" ||
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
