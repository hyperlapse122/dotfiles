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

fail() { printf '%s\n' "$*" >&2; exit 1; }
ok() { printf '  ok: %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to run this guard"

# The scratch root, the stub `op` and the empty chezmoi config are the same three
# things every render gate needs, and the repo already factored them out after
# each gate had drifted its own copy. Use that helper rather than adding a fourth.
# shellcheck source=.ci/lib/render-scratch.sh
. "$repo_root/.ci/lib/render-scratch.sh"
setup_render_scratch orca-settings-reconcile
# AGENTS.md requires every render gate to use this helper rather than hand-roll
# the invocation: it pins PATH to the stub and system directories only -- never
# the inherited PATH, so no code path can fall through to the real `op` -- and
# writes through a throwaway --destination.
# shellcheck source=.ci/lib/render-gate-helpers.sh
. "$repo_root/.ci/lib/render-gate-helpers.sh"
chezmoi_bin=$(command -v chezmoi) || fail 'chezmoi is required to run this guard'
mkdir -p -- "$scratch/home"

# The helper renders file-to-file; these checks are easier to read as a here-doc
# pipeline, so wrap it rather than reimplement it. The template's own render
# failure is the assertion in half of them, so the exit status must survive.
render_stdin() {
  local in="$scratch/render.in" out="$scratch/render.out" rc=0
  cat >"$in"
  render "$repo_root" "$scratch" "$chezmoi_bin" linux "$in" "$out" || rc=$?
  if [[ -s $out ]]; then cat -- "$out"; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Render-time guard: every rejection the validator owns must actually fire.
# Without these the guard could go quiet and nothing would say so.
# ---------------------------------------------------------------------------
printf 'render-time declaration guard\n'

validate_call='{{ includeTemplate "orca-settings-validate.tmpl" (dict "ctx" . "settings" SETTINGS) }}accepted'

expect_reject() {
  local what=$1 settings_expr=$2 want=$3 out
  if out=$(render_stdin <<<"${validate_call/SETTINGS/$settings_expr}" 2>&1); then
    fail "declaration guard accepted $what; it must fail the render"
  fi
  grep -q -- "$want" <<<"$out" \
    || fail "declaration guard rejected $what but not for the stated reason; wanted $want, got: $out"
  ok "rejects $what"
}

expect_accept() {
  local what=$1 settings_expr=$2 out
  out=$(render_stdin <<<"${validate_call/SETTINGS/$settings_expr}" 2>&1) \
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
expect_reject 'an unsubstituted placeholder inside an array element' \
  '(dict "settings.a" (list "@nope@"))' 'does not substitute'
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

declared_source=$(render_stdin <<<'{{ .orca.settings | toJson }}')
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
before_mode=$(stat -c %a -- "$data")
run --mode assert >/dev/null 2>&1
[[ $(cat "$data") == "$before" ]] || fail 'assert rewrote an already-converged document; a second apply must change zero bytes'
[[ $(stat -c %a -- "$data") == "$before_mode" ]] || fail 'assert changed the mode of an already-converged document'
ok 'a converged document is left byte-identical and mode-identical'

reset_fixture
drift_one
chmod 0600 "$data"
run --mode assert >/dev/null 2>&1
assert_json 'assert did not converge the 0600 drifted document' \
  '.settings.appFontFamily == "Pretendard"'
[[ $(stat -c %a -- "$data") == 600 ]] || fail 'assert widened a 0600 document'
ok 'a drifted 0600 document preserves its mode'

reset_fixture
drift_one
chmod 0644 "$data"
run --mode assert >/dev/null 2>&1
assert_json 'assert did not converge the 0644 drifted document' \
  '.settings.appFontFamily == "Pretendard"'
[[ $(stat -c %a -- "$data") == 644 ]] || fail 'assert narrowed a 0644 document'
ok 'a drifted 0644 document preserves its mode'

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
# Drift the typed leaves to the WRONG type first -- a fixture built from the
# declaration already holds the right ones, so without this the check would pass
# on values assert never wrote.
reset_fixture
tmp="$scratch/types.json"
jq --argjson declared "$declared" '
  reduce ($declared | to_entries[] | select(.value | type == "boolean" or type == "number")) as $e
    (.; setpath($e.key | split("."); "wrong-type"))
' "$data" >"$tmp" && mv -- "$tmp" "$data"
run --mode assert >/dev/null 2>&1
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

# A real orca-data.json is a quarter of a megabyte, and Linux caps a single argv
# entry at MAX_ARG_STRLEN (128 KiB). Passing the document as a jq argument fails
# with E2BIG against every real profile while passing against every small
# fixture, so the fixture must be grown past that limit or this guard is blind to
# the whole class.
reset_fixture
tmp="$scratch/big.json"
jq '.worktreeMeta.bulk = ([range(6000)] | map({key: "w\(.)", value: {branch: "feature/padding-\(.)", note: "padding to exceed the single-argument limit"}}) | from_entries)' \
  "$data" >"$tmp" && mv -- "$tmp" "$data"
data_bytes=$(wc -c <"$data")
[[ $data_bytes -gt 131072 ]] \
  || fail "the oversized fixture is only $data_bytes bytes; it must exceed 131072 to exercise the argv limit"
drift_one
run --mode assert >/dev/null 2>&1 || fail 'assert failed on a realistically sized document'
assert_json 'assert did not converge against an oversized document' \
  '.settings.appFontFamily == "Pretendard"'
assert_json 'assert lost the bulk metadata of an oversized document' \
  '(.worktreeMeta.bulk | length) == 6000'
report_out=$(run --mode report 2>&1) || fail 'report failed on a realistically sized document'
ok "assert and report handle a ${data_bytes}-byte document (past the 131072-byte argv limit)"

# Report never writes and never fails, whatever it finds.
reset_fixture
drift_one
before=$(cat "$data")
report_out=$(run --mode report 2>&1) || fail 'report exited non-zero; drift must never fail an apply'
[[ $(cat "$data") == "$before" ]] || fail 'report wrote to the live document'
# Match the whole line, not a substring: a raw-output flag lost from the jq call
# wraps every line in JSON quotes and escapes, which a substring grep still finds.
grep -qx '  settings\.appFontFamily: declared "Pretendard", live "DriftedFont"' <<<"$report_out" \
  || fail "report did not print the drift line in raw form; got: $report_out"
ok 'report names the drift, changes nothing, and exits zero'

# ---------------------------------------------------------------------------
# The running check. Existence alone is not enough: a crash leaves the lock
# behind, and skipping forever on it is the silent failure this guard exists for.
# ---------------------------------------------------------------------------
printf 'running-application detection\n'

# Read once: the reconciler compares the lock's hostname against this value, so
# recomputing it per case would suggest it can change mid-run, which is exactly
# the semantics these cases are pinning down.
this_host=$(uname -n)

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

expect_lock 'a lock naming this host and a live pid' "$this_host-$$" skipped
expect_lock 'a lock naming this host and a dead pid' "$this_host-999999" written
expect_lock 'a lock naming another host' "someotherhost-$$" written
expect_lock 'a lock whose target does not parse' 'garbage' written

# Report is not gated on the lock: an operator running apply from inside Orca is
# the common case, and it is exactly when they need to see drift.
reset_fixture
drift_one
ln -sfn "$this_host-$$" "$lock"
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

# Without jq there is no classifier at all. The reconciler must say so rather than
# exit quietly, because silence reads as "the declared values are pinned".
nojq_bin=$scratch/nojq
mkdir -p -- "$nojq_bin"
for cmd in bash uname readlink mktemp mv rm chmod dirname printf base64 kill; do
  target=$(command -v "$cmd" 2>/dev/null) && ln -sf "$target" "$nojq_bin/$cmd"
done
reset_fixture
drift_one
before=$(cat "$data")
nojq_err=$(env -i HOME="$scratch/home" PATH="$nojq_bin" ORCA_SETTINGS_CONFIG_DIR="$fixtures" \
  bash "$reconcile_script" --mode assert 2>&1 >/dev/null) \
  || fail 'a missing jq should not fail the run'
grep -qF 'jq is unavailable' <<<"$nojq_err" || fail "a missing jq was not reported; stderr was: $nojq_err"
[[ $(cat "$data") == "$before" ]] || fail 'the reconciler wrote without jq'
ok 'a missing jq is reported and nothing is written'

# ---------------------------------------------------------------------------
# The concurrent-write guard. No fixture can reach this by content alone -- the
# competing write must land BETWEEN the reconciler's read and its rename. Shadow
# jq so the classification pass, identifiable by its -rn flags, rewrites the
# document on its way out, exactly as a co-writer using open(O_TRUNC) would.
# Deleting the guard from the reconciler must fail here.
# ---------------------------------------------------------------------------
printf 'concurrent writer\n'

race_bin=$scratch/race
mkdir -p -- "$race_bin"
# Call the real jq through the ORIGINAL PATH, not an absolute path. `command -v
# jq` can resolve to a version-manager shim that re-resolves `jq` through PATH
# itself, and with the shadow directory prepended that shim would find this file
# again and recurse until the run is killed.
orig_path=$PATH
cat >"$race_bin/jq" <<RACE
#!/usr/bin/env bash
PATH="$orig_path" jq "\$@"; rc=\$?
if [[ ! -e "\$RACE_MARK" ]]; then
  for a in "\$@"; do
    if [[ \$a == -rn ]]; then
      : >"\$RACE_MARK"
      printf '%s' "\$RACE_CONTENT" >"\$RACE_TARGET"
      break
    fi
  done
fi
exit \$rc
RACE
chmod 0700 "$race_bin/jq"

reset_fixture
drift_one
race_content=$(jq -c '.settings.injectedByOtherWriter = true' "$data")
race_err=$(RACE_MARK="$scratch/race.mark" RACE_CONTENT="$race_content" RACE_TARGET="$data" \
  PATH="$race_bin:$PATH" ORCA_SETTINGS_CONFIG_DIR="$fixtures" \
  bash "$reconcile_script" --mode assert 2>&1 >/dev/null) \
  || fail 'a concurrent write should not fail the run'
grep -qF 'changed while this run staged its replacement' <<<"$race_err" \
  || fail "the concurrent write was not reported; stderr was: $race_err"
[[ $(cat "$data") == "$race_content" ]] \
  || fail "the staged file overwrote the concurrent writer's content"
[[ -z $(find "$(dirname "$data")" -maxdepth 1 -name '.orca-data.*' -print -quit) ]] \
  || fail 'the discarded staged file was left behind'
ok 'a concurrent write is detected, reported, and never overwritten'

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

reset_fixture
drift_one
run --mode=assert >/dev/null 2>&1 || fail 'the --mode=assert form exited non-zero'
assert_json '--mode=assert did not converge the drifted leaf' \
  '.settings.appFontFamily == "Pretendard"'
ok 'the --mode=assert form converges the drifted leaf'

for help_arg in -h --help; do
  reset_fixture
  before=$(cat "$data")
  help_out=$(run "$help_arg") || fail "$help_arg exited non-zero"
  [[ $help_out == 'usage: orca-settings-reconcile [--mode assert|report]' ]] \
    || fail "$help_arg did not print the usage line: $help_out"
  [[ $(cat "$data") == "$before" ]] || fail "$help_arg changed the live document"
  ok "$help_arg prints usage and leaves the live document untouched"
done

reset_fixture
missing_mode_err="$scratch/missing-mode.err"
if run --mode >/dev/null 2>"$missing_mode_err"; then
  fail 'a --mode with no value was accepted'
else
  missing_mode_rc=$?
fi
[[ $missing_mode_rc -eq 2 ]] || fail "a --mode with no value exited $missing_mode_rc instead of 2"
grep -qxF 'orca-settings-reconcile: --mode needs a value (assert or report)' "$missing_mode_err" \
  || fail "a --mode with no value printed the wrong error: $(cat "$missing_mode_err")"
ok 'a --mode with no value reports its full error and exits 2'

printf '\nall orca settings reconciler checks passed\n'
