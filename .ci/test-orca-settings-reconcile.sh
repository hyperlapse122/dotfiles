#!/usr/bin/env bash
# Guards the Orca settings reconciler: the render-time declaration guard
# (.chezmoitemplates/orca-settings-validate.tmpl) and the runtime leaf assertion
# (dot_local/share/chezmoi-command-sources/executable_orca-settings-reconcile.tmpl).
#
# Two failure modes drive what this asserts.
#
# SILENT NON-CONVERGENCE. The reconciler refuses to write while Orca runs, and it
# detects that from a lock the application leaves behind on a crash. Testing only
# the running case would let a stale-lock regression through, and the symptom --
# settings that never converge while apply keeps promising they will -- is
# invisible until someone compares the two by hand. Every lock shape is exercised.
#
# SILENT CLOBBERING. The live document holds worktree metadata, workspace session
# state and telemetry beside the declared settings, and the reconciler shares the
# file with the application. Every assertion below checks what SURVIVED, not only
# what was written.
set -euo pipefail

usage='usage: test-orca-settings-reconcile.sh RECONCILE_SCRIPT'
reconcile_script=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/orca-settings-reconcile-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }
ok() { printf '  ok: %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to run this guard"

# Renders resolve secrets live, so isolate them from host state: a scratch HOME
# plus a stub op answering newline-free.
render_config="$scratch/render.toml"
printf '[data]\n' >"$render_config"
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"

render() {
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" execute-template
}

# ---------------------------------------------------------------------------
# Render-time guard: every rejection the validator owns must actually fire.
# Without these the guard could go quiet and nothing would say so.
# ---------------------------------------------------------------------------
printf 'render-time declaration guard\n'

validate_call='{{ includeTemplate "orca-settings-validate.tmpl" (dict "ctx" . "settings" SETTINGS) }}accepted'

expect_reject() {
  local what=$1 settings_expr=$2 want=$3 out
  if out=$(render <<<"${validate_call/SETTINGS/$settings_expr}" 2>&1); then
    fail "declaration guard accepted $what; it must fail the render"
  fi
  grep -q -- "$want" <<<"$out" \
    || fail "declaration guard rejected $what but not for the stated reason; wanted $want, got: $out"
  ok "rejects $what"
}

expect_accept() {
  local what=$1 settings_expr=$2 out
  out=$(render <<<"${validate_call/SETTINGS/$settings_expr}" 2>&1) \
    || fail "declaration guard rejected $what, which is legal: $out"
  [[ $out == *accepted* ]] || fail "declaration guard produced no output for $what: $out"
  ok "accepts $what"
}

expect_reject 'a path outside the settings namespace' \
  '(dict "worktreeMeta.x" "y")' 'outside the settings namespace'
expect_reject 'a map value' \
  '(dict "settings.voice" (dict "enabled" true))' 'must name a leaf'
expect_reject 'an array holding a container' \
  '(dict "settings.a" (list (dict "k" "v")))' 'must hold scalars only'
expect_reject 'an unsubstituted placeholder' \
  '(dict "settings.a" "@homeDir@/x/@nope@")' 'does not substitute'
expect_reject 'a path that is an ancestor of another' \
  '(dict "settings.voice" "x" "settings.voice.enabled" true)' 'is an ancestor of'
expect_reject 'an empty path segment' \
  '(dict "settings..x" "y")' 'not a valid settings path'
expect_accept 'an array leaf' '(dict "settings.disabledTuiAgents" (list "antigravity"))'
expect_accept 'an empty declaration' '(dict)'

# ---------------------------------------------------------------------------
# Two views of the declaration, and the difference between them is the point.
# The SOURCE view is what orca.yaml says, placeholders and all. The RESOLVED
# view is the payload the rendered script actually carries, which is what the
# fixtures below must be built from -- building them from the source view would
# leave every placeholder-bearing path permanently "drifted" and the assertions
# would be measuring the test's own mistake.
# ---------------------------------------------------------------------------
printf 'declaration content\n'

declared_source=$(render <<<'{{ .orca.settings | toJson }}')
declared=$(sed -n "s/^DECLARED=\"\$(decode_b64 '\([A-Za-z0-9+/=]*\)')\"$/\1/p" "$reconcile_script" | base64 --decode)
[[ -n $declared ]] || fail 'could not read the declaration payload out of the rendered reconciler'

declared_count=$(jq -r 'length' <<<"$declared")
[[ $declared_count -gt 0 ]] || fail 'orca.yaml declares no settings paths'
[[ $(jq -r 'length' <<<"$declared_source") -eq $declared_count ]] \
  || fail 'the rendered reconciler carries a different number of paths than orca.yaml declares'
ok "$declared_count paths declared"

# Every declared path is rooted at the document, not at its settings object.
offenders=$(jq -r 'keys[] | select(startswith("settings.") | not)' <<<"$declared")
[[ -z $offenders ]] || fail "orca.yaml declares paths outside the settings namespace: $offenders"
ok 'every declared path is under settings.'

# The workspace path must not be pinned to one operator's home directory in the
# source, and must be fully resolved by the time the script carries it.
workspace_source=$(jq -r '.["settings.workspaceDir"] // empty' <<<"$declared_source")
if [[ -n $workspace_source ]]; then
  [[ $workspace_source == '@homeDir@'* ]] \
    || fail "settings.workspaceDir is declared as $workspace_source; it must start with the @homeDir@ placeholder so it renders per host"
  [[ $(jq -r '.["settings.workspaceDir"]' <<<"$declared") == /* ]] \
    || fail 'the rendered reconciler carries a settings.workspaceDir that is not an absolute path'
  ok 'settings.workspaceDir is declared through @homeDir@ and rendered absolute'
fi

# No placeholder of any kind may survive into the rendered script.
if grep -q '@[A-Za-z0-9_-]\+@' "$reconcile_script"; then
  fail 'the rendered reconciler still carries an unresolved @…@ placeholder'
fi
ok 'the rendered reconciler carries no unresolved placeholder'

# ---------------------------------------------------------------------------
# Runtime: the rendered reconciler against fixtures.
# ---------------------------------------------------------------------------
printf 'runtime reconciliation\n'

fixtures="$scratch/fx"
data="$fixtures/profiles/p1/orca-data.json"
lock="$fixtures/SingletonLock"

reset_fixture() {
  rm -rf -- "$fixtures"
  mkdir -p -- "$fixtures/profiles/p1"
  printf '{"schemaVersion":1,"activeProfileId":"p1"}' >"$fixtures/orca-profile-index.json"
  # A live document built FROM the declaration, then deliberately drifted, so the
  # fixture cannot fall out of date when orca.yaml grows a path.
  jq -n --argjson declared "$declared" '
    reduce ($declared | to_entries[]) as $e ({}; setpath($e.key | split("."); $e.value))
    | .schemaVersion = 9
    | .worktreeMeta = {"w1": {"keep": true}}
    | .settings.voice.language = "en"
    | .settings.agentDefaultArgs.claude = "--keep-me"
    | .settings.sourceControlAi.actions.commitMessage.commandInputTemplate = "{basePrompt}"
  ' >"$data"
}

run() { ORCA_SETTINGS_CONFIG_DIR="$fixtures" bash "$reconcile_script" "$@"; }

drift_one() {
  local tmp="$scratch/drift.json"
  jq '.settings.appFontFamily = "DriftedFont"' "$data" >"$tmp" && mv -- "$tmp" "$data"
}

assert_json() {
  local what=$1 filter=$2
  [[ $(jq -r "$filter" "$data") == true ]] || fail "$what"
}

# Converged input writes nothing at all.
reset_fixture
before=$(cat "$data")
run --mode assert >/dev/null 2>&1
[[ $(cat "$data") == "$before" ]] || fail 'assert rewrote an already-converged document; a second apply must change zero bytes'
ok 'a converged document is left byte-identical'

# Drift converges, and everything the declaration does not name survives.
reset_fixture
drift_one
run --mode assert >/dev/null 2>&1
assert_json 'assert did not converge the drifted leaf' \
  '.settings.appFontFamily == "Pretendard"'
assert_json 'assert destroyed a non-declared top-level key' \
  '.worktreeMeta.w1.keep == true and .schemaVersion == 9'
assert_json 'assert destroyed a non-declared sibling inside a touched record' \
  '.settings.voice.language == "en" and .settings.agentDefaultArgs.claude == "--keep-me" and .settings.sourceControlAi.actions.commitMessage.commandInputTemplate == "{basePrompt}"'
ok 'assert converges the declared leaf and preserves every sibling'

# Declared JSON types survive the round trip. A boolean written as a string is
# the failure this catches: Orca rejects the value and falls back to its default.
type_offenders=$(jq -r --argjson declared "$declared" '
  . as $live
  | $declared
  | to_entries[]
  | . as $e
  | ($e.key | split(".")) as $p
  | ($live | getpath($p)) as $actual
  | select(($actual | type) != ($e.value | type))
  | "\($e.key) is \($actual | type), declared \($e.value | type)"
' "$data")
[[ -z $type_offenders ]] || fail "assert wrote the wrong JSON type: $type_offenders"
ok 'every asserted leaf keeps its declared JSON type'

# An array leaf is replaced whole; this grammar has no list-membership syntax.
reset_fixture
tmp="$scratch/arr.json"
jq '.settings.disabledTuiAgents = ["antigravity", "addedByHand"]' "$data" >"$tmp" && mv -- "$tmp" "$data"
run --mode assert >/dev/null 2>&1
assert_json 'an array leaf was merged instead of replaced whole' \
  '.settings.disabledTuiAgents == ["antigravity"]'
ok 'an array leaf is replaced whole'

# Report never writes and never fails, whatever it finds.
reset_fixture
drift_one
before=$(cat "$data")
report_out=$(run --mode report 2>&1) || fail 'report exited non-zero; drift must never fail an apply'
[[ $(cat "$data") == "$before" ]] || fail 'report wrote to the live document'
grep -q 'settings.appFontFamily' <<<"$report_out" || fail "report did not name the drifted path: $report_out"
grep -q 'DriftedFont' <<<"$report_out" || fail "report did not show the live value: $report_out"
ok 'report names the drift, changes nothing, and exits zero'

# ---------------------------------------------------------------------------
# The running check. Existence alone is not enough: a crash leaves the lock
# behind, and skipping forever on it is the silent failure this guard exists for.
# ---------------------------------------------------------------------------
printf 'running-application detection\n'

expect_lock() {
  local what=$1 target=$2 want=$3
  reset_fixture
  drift_one
  ln -sfn "$target" "$lock"
  run --mode assert >/dev/null 2>&1
  local live
  live=$(jq -r '.settings.appFontFamily' "$data")
  case "$want" in
    skipped)
      [[ $live == DriftedFont ]] || fail "assert wrote while Orca was running ($what)"
      ;;
    written)
      [[ $live == Pretendard ]] || fail "assert skipped on a lock that does not mean running ($what)"
      ;;
  esac
  rm -f -- "$lock"
  ok "$what -> $want"
}

expect_lock 'a lock naming this host and a live pid' "$(uname -n)-$$" skipped
expect_lock 'a lock naming this host and a dead pid' "$(uname -n)-999999" written
expect_lock 'a lock naming another host' "someotherhost-$$" written
expect_lock 'a lock whose target does not parse' 'garbage' written

# Report is not gated on the lock: an operator running apply from inside Orca is
# the common case, and it is exactly when they need to see drift.
reset_fixture
drift_one
ln -sfn "$(uname -n)-$$" "$lock"
report_out=$(run --mode report 2>&1) || fail 'report exited non-zero while Orca was running'
grep -q 'settings.appFontFamily' <<<"$report_out" \
  || fail 'report stayed silent while Orca was running; drift must still be visible'
rm -f -- "$lock"
ok 'report still names drift while Orca is running'

# ---------------------------------------------------------------------------
# States that are not drift: a key Orca no longer carries, an unwritable
# ancestor, and a host with no Orca profile.
# ---------------------------------------------------------------------------
printf 'non-drift states\n'

# A renamed or removed key must be named and left alone. Writing it would add a
# key Orca silently ignores, which is a convergence that never happens.
reset_fixture
tmp="$scratch/unknown.json"
jq 'del(.settings.appFontFamily) | .settings.editorFontFamily = "DriftedFont"' "$data" >"$tmp" && mv -- "$tmp" "$data"
out=$(run --mode assert 2>&1) || fail "assert failed on an unknown declared path: $out"
grep -q 'settings.appFontFamily' <<<"$out" || fail "assert did not name the unknown path: $out"
assert_json 'assert created a key Orca does not carry' \
  '.settings | has("appFontFamily") | not'
assert_json 'an unknown path stopped the other declared paths from converging' \
  '.settings.editorFontFamily == "JetBrainsMono NF"'
ok 'an unknown path is named, not written, and does not block its siblings'

# An ancestor holding a scalar cannot be written through. Reporting it by name
# and continuing is what keeps one damaged key from stranding the whole
# declaration.
reset_fixture
tmp="$scratch/blocked.json"
jq '.settings.voice = "not-an-object" | .settings.editorFontFamily = "DriftedFont"' "$data" >"$tmp" && mv -- "$tmp" "$data"
out=$(run --mode assert 2>&1) || fail "assert failed on a blocked ancestor: $out"
grep -q 'settings.voice.enabled' <<<"$out" || fail "assert did not name the blocked path: $out"
assert_json 'assert overwrote the blocking ancestor' \
  '.settings.voice == "not-an-object"'
assert_json 'a blocked path stopped the other declared paths from converging' \
  '.settings.editorFontFamily == "JetBrainsMono NF"'
ok 'a blocked ancestor is named, left alone, and does not block its siblings'

# A host that has never opened Orca has nothing to converge.
reset_fixture
rm -f -- "$fixtures/orca-profile-index.json"
run --mode assert >/dev/null 2>&1 || fail 'assert failed on a host with no Orca profile index'
ok 'a host with no Orca profile exits clean'

reset_fixture
printf 'not json' >"$data"
run --mode assert >/dev/null 2>&1 || fail 'assert failed on an unreadable document'
[[ $(cat "$data") == 'not json' ]] || fail 'assert rebuilt an unreadable document instead of leaving it alone'
ok 'an unreadable document is left alone'

# ---------------------------------------------------------------------------
# Argument handling.
# ---------------------------------------------------------------------------
printf 'arguments\n'

reset_fixture
drift_one
before=$(cat "$data")
run >/dev/null 2>&1 || fail 'the bare command exited non-zero'
[[ $(cat "$data") == "$before" ]] || fail 'the bare command wrote to the live document; report must be the default'
ok 'the bare command reports and writes nothing'

if run --mode wat >/dev/null 2>&1; then
  fail 'an unknown --mode was accepted'
fi
ok 'an unknown --mode is rejected'

printf '\nall orca settings reconciler checks passed\n'
