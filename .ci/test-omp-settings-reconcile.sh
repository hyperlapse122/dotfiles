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
#   - a host without omp or jq skips and still succeeds

usage='usage: test-omp-settings-reconcile.sh OMP_SETTINGS_SCRIPT'
script=${1:?$usage}

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
  'omp config set'
do
  grep -F "$needle" "$script" >/dev/null || fail "rendered script lost: $needle"
done

grep -F 'gemini-3.7-flash' "$script" >/dev/null &&
  fail 'rendered script still declares the retired 3.7 model'

# run_after_ is load-bearing: omp edits config.yml without changing any chezmoi
# source fingerprint, so an onchange script would record a clean skip and never
# re-assert an overwritten value.
case "run_after_config-omp-settings.sh.tmpl" in
  run_after_*) ;;
  *) fail 'the settings reconciler must use the run_after_ lifecycle' ;;
esac

bash -n "$script" || fail 'rendered script is not valid bash'

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

# A live config whose every reported top-level key differs from the declaration.
live_drifted="$scratch/live-drifted.json"
cat >"$live_drifted" <<'EOF'
{"startup":{"setupWizard":true},"setupVersion":0,
 "enabledModels":["something/else"],"disabledProviders":[],
 "modelRoles":{"default":"something/else"}}
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
grep -q 'declared paths asserted' "$scratch/ok.out" ||
  fail 'the run did not report how many paths it asserted'

# --- convergence: an already-equal host writes nothing --------------------- #

# Build a live config that deep-equals the declaration by replaying the very
# `config set` calls the drifted run just made.
python3 - "$script" "$live_converged" <<'PY'
import json, re, sys
script, out = sys.argv[1], sys.argv[2]
body = open(script).read()
block = re.search(r"cat >\"\$declared\" <<'JSON'\n(.*?)\nJSON\n", body, re.S)
declared = json.loads(block.group(1))
live = {}
for path, value in declared.items():
    node = live
    parts = path.split(".")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = value
json.dump(live, open(out, "w"))
PY

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

# --- a host without omp skips and succeeds --------------------------------- #

reset
no_omp="$scratch/no-omp-bin"
mkdir -p "$no_omp"
env HOME="$home" PATH="$no_omp:/usr/bin:/bin" OMP_CALLS="$calls" OMP_STATE="$state" \
  OMP_CATALOG="$full_catalog" OMP_LIVE="$live_converged" bash "$script" \
  >"$scratch/skip.out" 2>"$scratch/skip.err" ||
  fail 'a host without omp did not exit successfully'
grep -q 'omp is unavailable' "$scratch/skip.err" ||
  fail 'the omp-absent skip did not state its reason'

printf 'omp settings reconcile: ok\n'
