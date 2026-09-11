#!/usr/bin/env bash
set -euo pipefail

# Proves the omp model-policy reconciler rendered from
# .chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl.
#
# The behaviours under test are the ones the deleted reconciler had to learn
# the hard way, and which KTD3 named as the porting set:
#   - the catalog probe FAILS OPEN, because an unauthenticated provider returns
#     a partial catalog with exit 0; only a provider the catalog speaks for can
#     prove a selector absent
#   - a selector the catalog covers but does not serve fails the apply loudly
#   - convergence is read-then-compare, so a converged host writes nothing
#   - a declared path omp does not report is a typo, not a silent skip
#   - a wedged omp read is bounded without GNU timeout
#   - a host without omp or jq fails the apply

usage='usage: test-omp-settings-reconcile.sh OMP_SETTINGS_SCRIPT'
script=${1:?$usage}
source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-settings-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-omp-settings-reconcile: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq is required to run this test'

# --- rendered surface ------------------------------------------------------ #

for needle in \
  'google-antigravity/gemini-3.8-flash:high' \
  'google-antigravity/gemini-3.1-flash-lite:minimal' \
  '"startup.setupWizard"' \
  '"enabledModels"' \
  '"disabledProviders"' \
  '"symbolPreset": "nerd"' \
  '"tui.resizeScrollback": "rebuild"' \
  '"display.showTokenUsage": true' \
  '"completion.notify": "off"' \
  '"error.notify": "off"' \
  '"ask.notify": "off"' \
  '"memory.backend": "off"' \
  '"memories.enabled": false' \
  '"autolearn.enabled": false' \
  '"autolearn.autoContinue": false' \
  '"astGrep.enabled": true' \
  '"skills.enableAgentsProject": false' \
  '"skills.enableClaudeProject": false' \
  '"skills.enablePiProject": false' \
  '"commands.enableClaudeProject": false' \
  '"commands.enableOpencodeProject": false' \
  '"skills.enableClaudeUser": false' \
  '"skills.enableCodexUser": false' \
  '"commands.enableClaudeUser": false' \
  '"commands.enableOpencodeUser": false' \
  '"skills.enabled": true' \
  '"skills.enableAgentsUser": true' \
  '"skills.enablePiUser": true' \
  'omp config set'
do
  grep -F "$needle" "$script" >/dev/null || fail "rendered script lost: $needle"
done

grep -F 'gemini-3.7-flash' "$script" >/dev/null &&
  fail 'rendered script still declares the retired 3.7 model'

# run_after_ is load-bearing: omp edits config.yml without changing any chezmoi
# source fingerprint, so an onchange script would record a clean skip and never
# re-assert an overwritten value. The lifecycle lives in the SOURCE filename, not
# in the rendered output this test is handed, so it is asserted against the
# source tree — and the onchange spelling must not exist alongside it.
phase_dir="$source_root/.chezmoiscripts/70-agents"
[ -f "$phase_dir/run_after_config-omp-settings.sh.tmpl" ] ||
  fail 'the settings reconciler must use the run_after_ lifecycle'
for stray in "$phase_dir"/run_onchange_*config-omp-settings.sh.tmpl; do
  [ -e "$stray" ] && fail "an onchange settings reconciler would never re-assert live drift: $stray"
done

bash -n "$script" || fail 'rendered script is not valid bash'

# --- the notification leaves are enum tokens, not booleans ----------------- #

# The needles above prove the three paths survived the render. They cannot prove
# the VALUES stayed strings: `off` is a YAML 1.1 boolean spelling, so a parser
# change or a hand edit could turn them into `false`, which omp's enum would
# reject. Quoting alone is not the guard either -- go-yaml already reads
# unquoted `off` as the string "off", so removing the quotes changes nothing and
# is not a failure case worth a fixture. The type and the value are.
declared_of() {
  python3 - "$1" <<'PY'
import json, re, sys
body = open(sys.argv[1]).read()
block = re.search(r"cat >\"\$declared\" <<'JSON'\n(.*?)\nJSON\n", body, re.S)
if block is None:
    raise SystemExit('no declaration heredoc in the rendered script')
print(json.dumps(json.loads(block.group(1))))
PY
}

notify_offenders() {
  jq -r --argjson want '["completion.notify","error.notify","ask.notify"]' '
    . as $d
    | $want[]
    | select((($d[.] | type) != "string") or ($d[.] != "off"))
    | "\(.) is \($d[.] | tojson), want the string \"off\""' "$1"
}

declared_json="$scratch/declared.json"
declared_of "$script" > "$declared_json"

offenders=$(notify_offenders "$declared_json")
[[ -z $offenders ]] || fail "notification leaves must be the string \"off\": $offenders"

# Force the failure branch. A guard that only ever sees today's correct
# declaration never executes its own failure path, so it can rot unnoticed.
printf '{"completion.notify": false, "error.notify": "off", "ask.notify": "off"}\n' \
  > "$scratch/notify-boolean.json"
notify_offenders "$scratch/notify-boolean.json" | grep -q '^completion.notify is false' ||
  fail 'a boolean notification value was not flagged'

printf '{"completion.notify": "on", "error.notify": "off", "ask.notify": "off"}\n' \
  > "$scratch/notify-on.json"
notify_offenders "$scratch/notify-on.json" | grep -q '^completion.notify is "on"' ||
  fail 'a re-enabled notification value was not flagged'

printf '{"error.notify": "off", "ask.notify": "off"}\n' > "$scratch/notify-absent.json"
notify_offenders "$scratch/notify-absent.json" | grep -q '^completion.notify is null' ||
  fail 'a dropped notification declaration was not flagged'

# --- memory and autolearn leaves are pinned off ---------------------------- #

# memory.backend is an enum selecting the backend and must be the string "off".
# memories.enabled, autolearn.enabled, and autolearn.autoContinue are independent
# booleans and must be false.
memory_offenders() {
  jq -r '
    . as $d
    | (
        if ($d | has("memory.backend") | not) then "memory.backend is missing, want the string \"off\""
        elif (($d["memory.backend"] | type) != "string") or ($d["memory.backend"] != "off")
        then "memory.backend is \($d["memory.backend"] | tojson), want the string \"off\""
        else empty end
      ),
      (
        ["memories.enabled", "autolearn.enabled", "autolearn.autoContinue"][] as $k
        | if ($d | has($k) | not) then "\($k) is missing, want boolean false"
          elif (($d[$k] | type) != "boolean") or ($d[$k] != false)
          then "\($k) is \($d[$k] | tojson), want boolean false"
          else empty end
      )' "$1"
}

mem_offenders=$(memory_offenders "$declared_json")
[[ -z $mem_offenders ]] || fail "memory leaves must match declared types and values: $mem_offenders"

# Force the failure branch. Hand-crafted fixtures verify that mistyped or missing
# memory declarations fail loudly.
printf '{"memory.backend": "local", "memories.enabled": false, "autolearn.enabled": false, "autolearn.autoContinue": false}\n' \
  > "$scratch/memory-backend-local.json"
memory_offenders "$scratch/memory-backend-local.json" | grep -q '^memory.backend is "local"' ||
  fail 'a non-off memory.backend value was not flagged'

printf '{"memory.backend": "off", "memories.enabled": "false", "autolearn.enabled": false, "autolearn.autoContinue": false}\n' \
  > "$scratch/memory-string.json"
memory_offenders "$scratch/memory-string.json" | grep -q '^memories.enabled is "false"' ||
  fail 'a string memories.enabled value was not flagged'

printf '{"memories.enabled": false, "autolearn.enabled": false, "autolearn.autoContinue": false}\n' \
  > "$scratch/memory-absent.json"
memory_offenders "$scratch/memory-absent.json" | grep -q '^memory.backend is missing' ||
  fail 'a dropped memory.backend declaration was not flagged'

printf '{"memory.backend": "off", "autolearn.enabled": false, "autolearn.autoContinue": false}\n' \
  > "$scratch/memories-enabled-absent.json"
memory_offenders "$scratch/memories-enabled-absent.json" | grep -q '^memories.enabled is missing' ||
  fail 'a dropped memories.enabled declaration was not flagged'

printf '{"memory.backend": "off", "memories.enabled": false, "autolearn.enabled": false, "autolearn.autoContinue": false}\n' \
  > "$scratch/memory-clean.json"
[[ -z $(memory_offenders "$scratch/memory-clean.json") ]] ||
  fail 'a correct memory declaration was flagged as an offender'

# --- fixtures -------------------------------------------------------------- #

home="$scratch/home"
bin="$scratch/bin"
mkdir -p "$home" "$bin"
calls="$scratch/omp-calls"
state="$scratch/omp-state"

# The stub reads its catalog and live config from files the test controls, so a
# scenario is expressed as fixture content rather than as stub edits.
cat >"$bin/omp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMP_CALLS"
case "$*" in
  "models --json")
    [[ -z ${OMP_MODELS_HANG:-} ]] || { sleep 120; exit 0; }
    cat "$OMP_CATALOG"
    ;;
  "config list --json")
    cat "$OMP_LIVE"
    ;;
  "config set "*)
    printf '%s\n' "$*" >>"$OMP_STATE"
    # With OMP_LIVE_WRITE set, the stub also APPLIES the write, so a scenario
    # can assert the resulting config and not just the call log. A reconciler
    # that emits the right calls but writes nothing looks identical in
    # $OMP_STATE alone.
    if [[ -n ${OMP_LIVE_WRITE:-} ]]; then
      jq --arg k "$3" --arg v "$4" \
        '.[$k] = {"value": (try ($v | fromjson) catch $v)}' \
        "$OMP_LIVE_WRITE" >"$OMP_LIVE_WRITE.next"
      mv "$OMP_LIVE_WRITE.next" "$OMP_LIVE_WRITE"
    fi
    ;;
  *) printf 'unexpected omp call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/omp"

reset() { : > "$calls"; : > "$state"; }

# A catalog that serves both declared selectors.
full_catalog="$scratch/catalog-full.json"
cat >"$full_catalog" <<'EOF'
{"models":[
 {"provider":"google-antigravity","selector":"google-antigravity/gemini-3.8-flash"},
 {"provider":"google-antigravity","selector":"google-antigravity/gemini-3.1-flash-lite"}
]}
EOF

# A catalog with no google-antigravity models at all: the unauthenticated case.
empty_catalog="$scratch/catalog-empty.json"
printf '{"models":[]}\n' > "$empty_catalog"

# A catalog that speaks for the provider but is missing one declared selector.
partial_catalog="$scratch/catalog-partial.json"
cat >"$partial_catalog" <<'EOF'
{"models":[
 {"provider":"google-antigravity","selector":"google-antigravity/gemini-3.1-flash-lite"}
]}
EOF

# `omp config list --json` is a FLAT map keyed by the whole dotted path, whose
# entries are objects carrying the current value under `value` — it reports
# every schema key, set or not. A nested-tree fixture would let a reconciler
# that reads paths as a tree pass here and then fail on every real host.
live_drifted="$scratch/live-drifted.json"
cat >"$live_drifted" <<'EOF'
{"startup.setupWizard": {"value": true},
 "setupVersion": {"value": 0},
 "symbolPreset": {"value": "unicode"},
 "tui.resizeScrollback": {"value": "none"},
 "display.showTokenUsage": {"value": false},
 "completion.notify": {"value": "on"},
 "error.notify": {"value": "on"},
 "ask.notify": {"value": "on"},
 "memory.backend": {"value": "local"},
 "memories.enabled": {"value": true},
 "autolearn.enabled": {"value": true},
 "autolearn.autoContinue": {"value": true},
 "theme": {"value": "dark"},
 "astGrep.enabled": {"value": false},
 "skills.enableAgentsProject": {"value": true},
 "skills.enableClaudeProject": {"value": true},
 "skills.enablePiProject": {"value": true},
 "commands.enableClaudeProject": {"value": true},
 "commands.enableOpencodeProject": {"value": true},
 "skills.enableClaudeUser": {"value": true},
 "skills.enableCodexUser": {"value": true},
 "commands.enableClaudeUser": {"value": true},
 "commands.enableOpencodeUser": {"value": true},
 "skills.enabled": {"value": false},
 "skills.enableAgentsUser": {"value": false},
 "skills.enablePiUser": {"value": false},
 "enabledModels": {"value": ["something/else"]},
 "disabledProviders": {"value": []},
 "modelRoles": {"value": {"default": "something/else"}}}
EOF
# A live config that already equals the declaration is built from it at runtime.
live_converged="$scratch/live-converged.json"

run() {
  env HOME="$home" PATH="$bin:/usr/bin:/bin" \
    OMP_CALLS="$calls" OMP_STATE="$state" \
    OMP_CATALOG="$1" OMP_LIVE="$2" ${3:+OMP_MODELS_HANG=1} \
    bash "$script"
}

# --- a covered provider missing a declared selector fails the apply -------- #

reset
if run "$partial_catalog" "$live_drifted" >"$scratch/partial.out" 2>"$scratch/partial.err"; then
  fail 'a selector the catalog does not serve was accepted'
fi
grep -q 'which provider google-antigravity does not serve' "$scratch/partial.err" ||
  fail 'the missing-selector refusal did not name the provider'
[[ ! -s $state ]] || fail 'the refused run still wrote settings'

# --- an uncovered provider skips validation and still asserts -------------- #

reset
run "$empty_catalog" "$live_drifted" >"$scratch/empty.out" 2>"$scratch/empty.err" ||
  fail 'an unauthenticated provider was treated as a failure'
grep -q 'model catalog unavailable' "$scratch/empty.err" ||
  fail 'the fail-open skip did not state its reason'
grep -Fq 'config set modelRoles' "$state" ||
  fail 'the fail-open run did not assert the declared roles'

# --- happy path: a drifted host converges --------------------------------- #

reset
run "$full_catalog" "$live_drifted" >"$scratch/ok.out" 2>"$scratch/ok.err" ||
  fail 'the happy path failed'
grep -Fq 'config set startup.setupWizard' "$state" ||
  fail 'the wizard key was not asserted'
grep -Fq 'config set enabledModels' "$state" ||
  fail 'the model allowlist was not asserted'
grep -Fq 'config set disabledProviders' "$state" ||
  fail 'the provider denylist was not asserted'
for path in completion.notify error.notify ask.notify; do
  [[ $(grep -Fxc "config set $path off" "$state") == 1 ]] ||
    fail "the drifted run did not turn $path off exactly once"
done
[[ $(grep -Fxc "config set memory.backend off" "$state") == 1 ]] ||
  fail "the drifted run did not turn memory.backend off exactly once"
for path in memories.enabled autolearn.enabled autolearn.autoContinue; do
  [[ $(grep -Fxc "config set $path false" "$state") == 1 ]] ||
    fail "the drifted run did not turn $path false exactly once"
done
[[ $(grep -Fxc "config set astGrep.enabled true" "$state") == 1 ]] ||
  fail "the drifted run did not turn astGrep.enabled true exactly once"
for path in \
  skills.enableAgentsProject \
  skills.enableClaudeProject \
  skills.enablePiProject \
  commands.enableClaudeProject \
  commands.enableOpencodeProject \
  skills.enableClaudeUser \
  skills.enableCodexUser \
  commands.enableClaudeUser \
  commands.enableOpencodeUser
do
  [[ $(grep -Fxc "config set $path false" "$state") == 1 ]] ||
    fail "the drifted run did not turn $path false exactly once"
done
# The managed skills tree is pinned ON, so a host that drifted it off is
# restored. Leaving these undeclared would let one /settings toggle blank the
# tree with no apply that puts it back.
for path in skills.enabled skills.enableAgentsUser skills.enablePiUser; do
  [[ $(grep -Fxc "config set $path true" "$state") == 1 ]] ||
    fail "the drifted run did not turn $path true exactly once"
done
grep -q 'declared paths asserted' "$scratch/ok.out" ||
  fail 'the run did not report how many paths it asserted'

# --- postcondition: the resulting config, not just the call log ------------ #

# The call log proves what the reconciler asked for. This proves what the host
# ended up with, and that the keys nobody declared came through untouched.
reset
live_applied="$scratch/live-applied.json"
cp "$live_drifted" "$live_applied"
env HOME="$home" PATH="$bin:/usr/bin:/bin" \
  OMP_CALLS="$calls" OMP_STATE="$state" \
  OMP_CATALOG="$full_catalog" OMP_LIVE="$live_applied" OMP_LIVE_WRITE="$live_applied" \
  bash "$script" >"$scratch/applied.out" 2>"$scratch/applied.err" ||
  fail 'the applying run failed'

jq -e '
  (."completion.notify".value == "off") and
  (."error.notify".value == "off") and
  (."ask.notify".value == "off")' "$live_applied" >/dev/null ||
  fail 'the notification keys were not off after the run'
jq -e '
  (."memory.backend".value == "off") and
  (."memories.enabled".value == false) and
  (."autolearn.enabled".value == false) and
  (."autolearn.autoContinue".value == false)' "$live_applied" >/dev/null ||
  fail 'the memory keys were not off/false after the run'
jq -e '.theme.value == "dark"' "$live_applied" >/dev/null ||
  fail 'an undeclared key did not survive the run'
jq -e '(."symbolPreset".value == "nerd") and (."startup.setupWizard".value == false)' \
  "$live_applied" >/dev/null ||
  fail 'the pre-existing declared keys did not converge alongside the new ones'
jq -e '
  (."astGrep.enabled".value == true) and
  (."skills.enableAgentsProject".value == false) and
  (."skills.enableClaudeProject".value == false) and
  (."skills.enablePiProject".value == false) and
  (."commands.enableClaudeProject".value == false) and
  (."commands.enableOpencodeProject".value == false) and
  (."skills.enableClaudeUser".value == false) and
  (."skills.enableCodexUser".value == false) and
  (."commands.enableClaudeUser".value == false) and
  (."commands.enableOpencodeUser".value == false)' "$live_applied" >/dev/null ||
  fail 'the new declared keys did not converge to their boolean values'

# --- convergence: an already-equal host writes nothing --------------------- #

# Build a live config that deep-equals the declaration, in the flat,
# dotted-key, entry-object shape omp actually emits.
jq 'with_entries(.value = {"value": .value})' "$declared_json" > "$live_converged"

reset
run "$full_catalog" "$live_converged" >"$scratch/conv.out" 2>"$scratch/conv.err" ||
  fail 'the converged run failed'
[[ ! -s $state ]] || fail 'the converged run rewrote settings that were already equal'
grep -q '^config-omp-settings: 0 of ' "$scratch/conv.out" ||
  fail 'the converged run did not report zero assertions'

# --- a declared path omp never reports is a typo --------------------------- #

reset
live_missing="$scratch/live-missing.json"
jq 'del(.setupVersion)' "$live_converged" > "$live_missing"
if run "$full_catalog" "$live_missing" >"$scratch/typo.out" 2>"$scratch/typo.err"; then
  fail 'a declared path omp does not report was accepted'
fi
grep -q 'is not a key omp reports' "$scratch/typo.err" ||
  fail 'the unknown-path refusal did not name its reason'

# --- a wedged catalog read is bounded -------------------------------------- #

reset
start=$(date +%s)
run "$full_catalog" "$live_converged" hang >"$scratch/hang.out" 2>"$scratch/hang.err" ||
  fail 'a wedged catalog read did not fail open'
elapsed=$(( $(date +%s) - start ))
[[ $elapsed -lt 60 ]] || fail "a wedged catalog read was not bounded (took ${elapsed}s)"
grep -q 'model catalog unavailable' "$scratch/hang.err" ||
  fail 'the wedged read did not fall through to the fail-open branch'

# --- an unreadable live config falls open and still asserts ---------------- #

reset
live_bad="$scratch/live-bad.json"
printf 'not json at all\n' > "$live_bad"
run "$full_catalog" "$live_bad" >"$scratch/badlive.out" 2>"$scratch/badlive.err" ||
  fail 'an unreadable live config was treated as a failure'
grep -q 'could not read the live config' "$scratch/badlive.err" ||
  fail 'the unreadable-live-config skip did not state its reason'
grep -Fq 'config set modelRoles' "$state" ||
  fail 'the fail-open run did not fall through to asserting every declared path'

# --- a host without jq fails the apply ------------------------------------- #

# A PATH holding omp and nothing else: the jq check is a shell builtin lookup
# that runs before the script's first external command, so it is reached even
# without coreutils on PATH.
reset
no_jq="$scratch/no-jq-bin"
mkdir -p "$no_jq"
cp "$bin/omp" "$no_jq/omp"
bash_bin=$(command -v bash) || fail 'bash is not on PATH'
env HOME="$home" PATH="$no_jq" \
  OMP_CALLS="$calls" OMP_STATE="$state" \
  OMP_CATALOG="$full_catalog" OMP_LIVE="$live_converged" "$bash_bin" "$script" \
  >"$scratch/nojq.out" 2>"$scratch/nojq.err" ||
  fail 'a host without jq aborted the apply instead of reporting a skip'
grep -q 'declared settings were NOT asserted' "$scratch/nojq.err" ||
  fail 'the jq-absent skip did not say the settings were not asserted'
[[ ! -s $state ]] || fail 'the jq-absent run still wrote settings'

# --- a host without omp skips loudly and lets the apply continue ----------- #

# 65-commands fails open by design, so omp can be legitimately absent here, and
# this run_after_ script runs on every apply. Aborting would permanently strand
# 80-keys and 90-src, which have nothing to do with omp. What the skip must not
# do is read as a converged host, so the message has to disclaim the assertion.

reset
no_omp="$scratch/no-omp-bin"
mkdir -p "$no_omp"
env HOME="$home" PATH="$no_omp:/usr/bin:/bin" OMP_CALLS="$calls" OMP_STATE="$state" \
  OMP_CATALOG="$full_catalog" OMP_LIVE="$live_converged" bash "$script" \
  >"$scratch/skip.out" 2>"$scratch/skip.err" ||
  fail 'a host without omp aborted the apply instead of reporting a skip'
grep -q 'declared settings were NOT asserted' "$scratch/skip.err" ||
  fail 'the omp-absent skip did not say the settings were not asserted'
[[ ! -s $state ]] || fail 'the omp-absent run still wrote settings'

printf 'omp settings reconcile: ok\n'
