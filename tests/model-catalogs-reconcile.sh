#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/model-catalogs-reconcile.sh <model-catalogs-workflow>
#
# Runs the snapshot refresh job of .github/workflows/model-catalogs.yml the
# way Actions does, against a sandboxed git remote: every `run:` step in
# order, under `bash --noprofile --norc -eo pipefail` (what `shell: bash`
# runs), with the job's and the step's own `env:`, secrets resolved from a
# fake set (an absent secret resolves to the empty string, as in Actions),
# `$GITHUB_OUTPUT` read back into `steps.<id>.outputs`, and each `if:`
# evaluated with the implicit `success()`. A `uses:` step is skipped. An
# expression the runner does not know fails the check rather than guessing.
#
# A stub `nix` stands in for the snapshot fetches and the verification build
# and logs each call to an event log that origin's post-receive hook also
# writes, so the log orders verification against the pushes origin accepted.

set -euo pipefail

workflow=${1:-}
if [[ $# -ne 1 || -z $workflow || ! -f $workflow ]]; then
  printf 'usage: %s WORKFLOW_FILE\n' "${0##*/}" >&2
  exit 2
fi

fail() { printf 'model-catalogs-reconcile: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'model-catalogs-reconcile: ok - %s\n' "$*"; }

for tool in git jq yq; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done

synthetic=home/h82/agents/synthetic-catalog.json
openrouter=home/h82/agents/openrouter-catalog.json
token=fake-gh-token-0123456789
verify_args='build --no-link --print-build-logs .#checks.x86_64-linux.omp-settings .#checks.x86_64-linux.omp-models-load .#checks.x86_64-linux.synthetic-models'

scratch=$(mktemp -d "${TMPDIR:-/tmp}/model-catalogs-reconcile.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

wf_json=$(yq -o=json '.' "$workflow")
[[ $(jq '.jobs | length' <<<"$wf_json") == 1 ]] || fail "expected one job in $workflow"
job=$(jq '.jobs | to_entries[0].value' <<<"$wf_json")
step_count=$(jq '.steps | length' <<<"$job")

step_by_name() {
  jq --arg n "$1" '.steps[] | select(.name == $n)' <<<"$job"
}

for pair in 'SYNTHETIC_API_KEY|Refresh the Synthetic catalog snapshot' \
  'OPENROUTER_API_KEY|Refresh the OpenRouter catalog snapshot' \
  'GH_TOKEN_FOR_UPDATES|Push the refreshed snapshots to main'; do
  key=${pair%%|*} step=${pair#*|}
  [[ $(grep -c "secrets\.$key\b" "$workflow") == 1 ]] ||
    fail "secrets.$key should appear exactly once in $workflow"
  value=$(step_by_name "$step" | jq -r --arg k "$key" '.env[$k] // empty')
  [[ $value == "\${{ secrets.$key }}" ]] ||
    fail "the step '$step' does not hold secrets.$key in its own env"
done
[[ $(jq '.env // {} | keys | length' <<<"$wf_json") == 0 ]] || fail 'the workflow sets a workflow-level env'
pass 'each catalog key is held only by its fetch step, and GH_TOKEN_FOR_UPDATES only by the push step'

checkout=$(jq '[.steps[] | select((.uses // "") | startswith("actions/checkout@"))]' <<<"$job")
[[ $(jq 'length' <<<"$checkout") == 1 && $(jq '.[0].with["persist-credentials"]' <<<"$checkout") == false ]] ||
  fail 'the checkout step does not set persist-credentials: false'
[[ $(jq -r '.[0].with.ref // empty' <<<"$checkout") == main ]] ||
  fail 'the checkout step does not set ref: main'
pass 'checkout sets ref: main and persist-credentials: false'

for ((i = 0; i < step_count; i++)); do
  step=$(jq ".steps[$i]" <<<"$job")
  [[ $(jq 'has("run")' <<<"$step") == true ]] || continue
  name=$(jq -r '.name // "(unnamed)"' <<<"$step")
  [[ $(jq -r '.shell // empty' <<<"$step") == bash ]] || fail "the step '$name' does not set shell: bash"
  first=$(awk '!/^[[:space:]]*(#|$)/ { print; exit }' <<<"$(jq -r '.run' <<<"$step")")
  [[ $first == 'set -euo pipefail' ]] || fail "the step '$name' does not start with set -euo pipefail"
done
pass 'every run step uses shell: bash and starts with set -euo pipefail'

declare -A secrets outputs

resolve() {
  local re='^\$\{\{ secrets\.([A-Za-z0-9_]+) \}\}$'
  if [[ $1 =~ $re ]]; then
    printf '%s' "${secrets[${BASH_REMATCH[1]}]-}"
  elif [[ $1 == *'${{'* ]]; then
    fail "the runner does not know the expression in env value: $1"
  else
    printf '%s' "$1"
  fi
}

should_run() {
  local cond=$1 ok=$2 re="^steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+) == '([^']*)'$"
  [[ -z $cond ]] && { ((ok)); return; }
  [[ $cond =~ $re ]] || fail "the runner does not know the if: expression: $cond"
  ((ok)) && [[ ${outputs[${BASH_REMATCH[1]}.${BASH_REMATCH[2]}]-} == "${BASH_REMATCH[3]}" ]]
}

# setup <name>: a bare origin whose main holds both snapshots, a clone of it
# with the stub `nix` first on PATH, and an event log. Sets origin, clone,
# other, ctl, events, and bin.
setup() {
  local name=$1
  origin=$scratch/$name-origin.git clone=$scratch/$name-clone other=$scratch/$name-other
  ctl=$scratch/$name-ctl events=$scratch/$name-events.log bin=$scratch/$name-bin
  mkdir -p "$ctl" "$bin"
  : >"$events"
  git init -q --bare "$origin"
  # A sandboxed HOME has no init.defaultBranch; pin HEAD to main.
  git --git-dir "$origin" symbolic-ref HEAD refs/heads/main
  cat >"$origin/hooks/post-receive" <<EOF
#!$BASH
while read -r old new ref; do
  printf 'push %s\n' "\$(git log -1 --format=%s "\$new")" >>"$events"
done
EOF
  chmod +x "$origin/hooks/post-receive"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" config user.email t@example.invalid
  git -C "$clone" config user.name Test
  git -C "$clone" checkout -qb main
  mkdir -p "$clone/home/h82/agents"
  printf '{"data": [{"id": "hf:old/Model"}]}\n' >"$clone/$synthetic"
  printf '{"data": [{"id": "old/model"}]}\n' >"$clone/$openrouter"
  git -C "$clone" add "$synthetic" "$openrouter"
  git -C "$clone" commit -qm init
  git -C "$clone" push -q origin main 2>/dev/null
  : >"$events"
  git clone -q "$origin" "$other" 2>/dev/null
  git -C "$other" config user.email o@example.invalid
  git -C "$other" config user.name Other
  # The push step's authenticated URL reaches the sandbox origin.
  git -C "$clone" config "url.$origin.insteadOf" "https://x-access-token:$token@github.com/owner/repo.git"

  # The stub: `run .#<tool> -- --snapshot FILE` acts as ctl/<tool> says
  # (change, fail, or same); `build` fails when ctl/verify-fail lists its call
  # number, and first pushes a concurrent commit to main when ctl/race lists it.
  cat >"$bin/nix" <<EOF
#!$BASH
seen="syn=\${SYNTHETIC_API_KEY:+set} or=\${OPENROUTER_API_KEY:+set} gh=\${GH_TOKEN_FOR_UPDATES:+set}"
case \$1 in
  run)
    tool=\${2#.#} file=\${5:-}
    printf 'fetch %s %s\n' "\$tool" "\$seen" >>"$events"
    case \$(cat "$ctl/\$tool" 2>/dev/null || echo same) in
      change) printf '{"data": [{"id": "%s-new"}]}\n' "\$tool" >"\$file" ;;
      fail) printf '{"data": [' >"\$file"; echo "\$tool: HTTP 502" >&2; exit 1 ;;
    esac
    ;;
  build)
    n=\$(( \$(grep -c '^verify' "$events" || true) + 1 ))
    printf 'verify %s %s\n' "\$*" "\$seen" >>"$events"
    if grep -qx "\$n" "$ctl/race" 2>/dev/null; then
      git -C "$other" pull -q --rebase origin main 2>/dev/null
      printf 'race %s\n' "\$n" >>"$other/race.txt"
      git -C "$other" add race.txt
      git -C "$other" commit -qm "concurrent commit \$n"
      git -C "$other" push -q origin main 2>/dev/null
    fi
    if grep -qx "\$n" "$ctl/verify-fail" 2>/dev/null; then echo 'check failed' >&2; exit 1; fi
    ;;
  *) echo "unexpected nix call: \$*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$bin/nix"
}

move_main() {
  git -C "$other" pull -q --rebase origin main 2>/dev/null
  printf 'moved\n' >>"$other/moved.txt"
  git -C "$other" add moved.txt
  git -C "$other" commit -qm 'unrelated commit on main'
  git -C "$other" push -q origin main 2>/dev/null
  : >"$events"
}

# Sets job_ok and writes the whole run's output to $scratch/<name>.log.
run_job() {
  local name=$1 log=$scratch/$1.log i step cond script out ok=1 status checkout_ref
  local -a env_args
  outputs=()
  : >"$log"
  checkout_ref=$(jq -r '[.steps[] | select((.uses // "") | startswith("actions/checkout@"))][0].with.ref // empty' <<<"$job")
  [[ -n $checkout_ref ]] && git -C "$clone" checkout -q "$checkout_ref"
  for ((i = 0; i < step_count; i++)); do
    step=$(jq ".steps[$i]" <<<"$job")
    [[ $(jq 'has("run")' <<<"$step") == true ]] || continue
    cond=$(jq -r '.if // empty' <<<"$step")
    should_run "$cond" "$ok" || continue
    env_args=()
    while IFS=$'\t' read -r k v; do
      [[ -n $k ]] && env_args+=("$k=$(resolve "$v")")
    done < <(jq -nr 'input as $job | input as $step
      | ($job.env // {} | to_entries[]), ($step.env // {} | to_entries[]) | "\(.key)\t\(.value)"' \
      <<<"$job"$'\n'"$step")
    script=$scratch/$name-step-$i.sh out=$scratch/$name-output-$i
    jq -r '.run' <<<"$step" >"$script"
    : >"$out"
    printf '### %s\n' "$(jq -r '.name // "(unnamed)"' <<<"$step")" >>"$log"
    status=0
    (
      cd "$clone"
      exec env -u SYNTHETIC_API_KEY -u OPENROUTER_API_KEY -u GH_TOKEN_FOR_UPDATES \
        PATH="$bin:$PATH" GITHUB_OUTPUT="$out" GITHUB_SERVER_URL=https://github.com \
        GITHUB_REPOSITORY=owner/repo "${env_args[@]}" \
        bash --noprofile --norc -eo pipefail "$script"
    ) >>"$log" 2>&1 || status=$?
    if ((status != 0)); then ok=0; continue; fi
    local id
    id=$(jq -r '.id // empty' <<<"$step")
    while IFS= read -r line; do
      [[ $line == *'<<'* ]] && fail "the runner does not read multiline outputs: $line"
      [[ -n $id && $line == *=* ]] && outputs[$id.${line%%=*}]=${line#*=}
    done <"$out"
  done
  job_ok=$ok
  if grep -q "$token" "$log"; then fail "($name) the run printed GH_TOKEN_FOR_UPDATES"; fi
}

pushed_subjects() {
  git --git-dir "$origin" log --reverse --format=%s main | tail -n +2 | paste -sd '|'
}

commit_files() {
  git --git-dir "$origin" show --format= --name-only \
    "$(git --git-dir "$origin" log --format=%H --fixed-strings --grep="$1" main | head -n 1)"
}

events_of() { grep "^$1" "$events" | paste -sd '|' || true; }

all_secrets() {
  secrets=([SYNTHETIC_API_KEY]=fake-syn [OPENROUTER_API_KEY]=fake-or [GH_TOKEN_FOR_UPDATES]=$token)
}

syn_subject='chore(agents): refresh the synthetic catalog snapshot'
or_subject='chore(agents): refresh the openrouter catalog snapshot'
push_seen='syn= or= gh=set'

setup ae2
all_secrets
echo change >"$ctl/synthetic-models-watch"
echo fail >"$ctl/openrouter-catalog-snapshot"
run_job ae2
((job_ok)) || fail "(ae2) the run failed: $(tail -n 20 "$scratch/ae2.log")"
[[ $(pushed_subjects) == "$syn_subject" ]] || fail "(ae2) origin got: $(pushed_subjects)"
[[ $(commit_files "$syn_subject") == "$synthetic" ]] || fail '(ae2) the synthetic commit holds other files'
or_blob=$(git --git-dir "$origin" show "main:$openrouter")
grep -q '"old/model"' <<<"$or_blob" ||
  fail '(ae2) the OpenRouter snapshot changed on origin'
grep -q '^::warning.*OpenRouter' "$scratch/ae2.log" || fail '(ae2) no warning names OpenRouter'
if grep -q '^::warning.*Synthetic' "$scratch/ae2.log"; then fail '(ae2) a warning names Synthetic'; fi
[[ $(events_of fetch) == "fetch synthetic-models-watch syn=set or= gh=|fetch openrouter-catalog-snapshot syn= or=set gh=" ]] ||
  fail "(ae2) each fetch should see only its own key: $(events_of fetch)"
[[ $(events_of 'verify\|push') == "verify $verify_args syn= or= gh=|push $syn_subject" ]] ||
  fail "(ae2) expected one verification, then the push: $(events_of 'verify\|push')"
pass 'a failing OpenRouter fetch warns naming OpenRouter and the Synthetic refresh alone lands'

setup syn-fails
all_secrets
echo fail >"$ctl/synthetic-models-watch"
echo change >"$ctl/openrouter-catalog-snapshot"
run_job syn-fails
((job_ok)) || fail "(syn-fails) the run failed: $(tail -n 20 "$scratch/syn-fails.log")"
[[ $(pushed_subjects) == "$or_subject" ]] || fail "(syn-fails) origin got: $(pushed_subjects)"
[[ $(commit_files "$or_subject") == "$openrouter" ]] || fail '(syn-fails) the openrouter commit holds other files'
syn_blob=$(git --git-dir "$origin" show "main:$synthetic")
grep -q '"hf:old/Model"' <<<"$syn_blob" ||
  fail '(syn-fails) the Synthetic snapshot changed on origin'
grep -q '^::warning.*Synthetic' "$scratch/syn-fails.log" || fail '(syn-fails) no warning names Synthetic'
if grep -q '^::warning.*OpenRouter' "$scratch/syn-fails.log"; then fail '(syn-fails) a warning names OpenRouter'; fi
pass 'a failing Synthetic fetch warns naming Synthetic and the OpenRouter refresh alone lands'

setup both-fail
all_secrets
echo fail >"$ctl/synthetic-models-watch"
echo fail >"$ctl/openrouter-catalog-snapshot"
run_job both-fail
((job_ok)) || fail "(both-fail) the run failed: $(tail -n 20 "$scratch/both-fail.log")"
[[ -z $(pushed_subjects) && -z $(events_of 'verify\|push') ]] ||
  fail "(both-fail) failed fetches verified or pushed: $(events_of 'verify\|push')"
grep -q '^::warning.*Synthetic' "$scratch/both-fail.log" || fail '(both-fail) no warning names Synthetic'
grep -q '^::warning.*OpenRouter' "$scratch/both-fail.log" || fail '(both-fail) no warning names OpenRouter'
pass 'when both fetches fail, both warn, no verification runs, and nothing is pushed'

setup nokey
all_secrets
unset 'secrets[SYNTHETIC_API_KEY]'
echo change >"$ctl/synthetic-models-watch"
echo change >"$ctl/openrouter-catalog-snapshot"
run_job nokey
((job_ok)) || fail "(nokey) the run failed: $(tail -n 20 "$scratch/nokey.log")"
[[ $(pushed_subjects) == "$or_subject" ]] || fail "(nokey) origin got: $(pushed_subjects)"
grep -q '^::warning.*Synthetic' "$scratch/nokey.log" || fail '(nokey) no warning names Synthetic'
pass 'a missing Synthetic key keeps its snapshot, warns naming Synthetic, and the OpenRouter refresh lands'

setup no-or-key
all_secrets
unset 'secrets[OPENROUTER_API_KEY]'
echo change >"$ctl/synthetic-models-watch"
echo change >"$ctl/openrouter-catalog-snapshot"
run_job no-or-key
((job_ok)) || fail "(no-or-key) the run failed: $(tail -n 20 "$scratch/no-or-key.log")"
[[ $(pushed_subjects) == "$syn_subject" ]] || fail "(no-or-key) origin got: $(pushed_subjects)"
grep -q '^::warning.*OpenRouter' "$scratch/no-or-key.log" || fail '(no-or-key) no warning names OpenRouter'
pass 'a missing OpenRouter key keeps its snapshot, warns naming OpenRouter, and the Synthetic refresh lands'

setup same
all_secrets
run_job same
((job_ok)) || fail "(same) the run failed: $(tail -n 20 "$scratch/same.log")"
[[ -z $(pushed_subjects) && -z $(events_of 'verify\|push') ]] ||
  fail "(same) unchanged snapshots verified or pushed: $(events_of 'verify\|push')"
pass 'unchanged snapshots run no verification and push nothing'

setup verify-fails
all_secrets
echo change >"$ctl/synthetic-models-watch"
echo 1 >"$ctl/verify-fail"
run_job verify-fails
((!job_ok)) || fail '(verify-fails) the run succeeded with a failing verification'
[[ -z $(pushed_subjects) ]] || fail "(verify-fails) origin got: $(pushed_subjects)"
pass 'a failing verification fails the run and pushes nothing'

setup isolate-verify
all_secrets
echo change >"$ctl/synthetic-models-watch"
echo change >"$ctl/openrouter-catalog-snapshot"
printf '1\n3\n' >"$ctl/verify-fail"
run_job isolate-verify
((job_ok)) || fail "(isolate-verify) the run failed: $(tail -n 20 "$scratch/isolate-verify.log")"
[[ $(pushed_subjects) == "$syn_subject" ]] || fail "(isolate-verify) origin got: $(pushed_subjects)"
[[ $(commit_files "$syn_subject") == "$synthetic" ]] || fail '(isolate-verify) the synthetic commit holds other files'
or_blob=$(git --git-dir "$origin" show "main:$openrouter")
grep -q '"old/model"' <<<"$or_blob" ||
  fail '(isolate-verify) the OpenRouter snapshot changed on origin'
grep -q '^::warning.*OpenRouter' "$scratch/isolate-verify.log" || fail '(isolate-verify) no warning names OpenRouter'
if grep -q '^::warning.*Synthetic' "$scratch/isolate-verify.log"; then fail '(isolate-verify) a warning names Synthetic'; fi
pass 'when one changed snapshot fails verification, it is reverted with a warning and the valid snapshot lands'

setup dispatch-branch
all_secrets
git -C "$clone" checkout -qb feature
git -C "$clone" commit --allow-empty -qm 'feature work'
echo change >"$ctl/synthetic-models-watch"
run_job dispatch-branch
((job_ok)) || fail "(dispatch-branch) the run failed: $(tail -n 20 "$scratch/dispatch-branch.log")"
[[ $(pushed_subjects) == "$syn_subject" ]] || fail "(dispatch-branch) origin got: $(pushed_subjects)"
pass 'a run dispatched from another branch checks out main and does not push feature commits'

setup moved
all_secrets
echo change >"$ctl/synthetic-models-watch"
echo change >"$ctl/openrouter-catalog-snapshot"
move_main
run_job moved
((job_ok)) || fail "(moved) the run failed: $(tail -n 20 "$scratch/moved.log")"
[[ $(pushed_subjects) == "unrelated commit on main|$syn_subject|$or_subject" ]] ||
  fail "(moved) origin got: $(pushed_subjects)"
[[ $(commit_files "$or_subject") == "$openrouter" ]] || fail '(moved) the openrouter commit holds other files'
[[ $(events_of 'verify\|push') == "verify $verify_args syn= or= gh=|verify $verify_args $push_seen|push $or_subject" ]] ||
  fail "(moved) expected verification again before the push: $(events_of 'verify\|push')"
pass 'when main moved, the push step rebases and verifies again before pushing'

setup moved-fails
all_secrets
echo change >"$ctl/synthetic-models-watch"
move_main
echo 2 >"$ctl/verify-fail"
run_job moved-fails
((!job_ok)) || fail '(moved-fails) the run succeeded with a failing re-verification'
[[ $(pushed_subjects) == 'unrelated commit on main' ]] || fail "(moved-fails) origin got: $(pushed_subjects)"
pass 'a failing re-verification after main moved pushes nothing'

setup rejected
all_secrets
echo change >"$ctl/synthetic-models-watch"
move_main
echo 2 >"$ctl/race"
run_job rejected
((job_ok)) || fail "(rejected) the run failed: $(tail -n 20 "$scratch/rejected.log")"
[[ $(pushed_subjects) == "unrelated commit on main|concurrent commit 2|$syn_subject" ]] ||
  fail "(rejected) origin got: $(pushed_subjects)"
[[ $(events_of 'verify\|push') == "verify $verify_args syn= or= gh=|verify $verify_args $push_seen|push concurrent commit 2|verify $verify_args $push_seen|push $syn_subject" ]] ||
  fail "(rejected) expected a rejected push to rebase, verify, and push once more: $(events_of 'verify\|push')"
pass 'a rejected push rebases, verifies again without a catalog key, and pushes once more'

setup rejected-twice
all_secrets
echo change >"$ctl/synthetic-models-watch"
move_main
printf '2\n3\n' >"$ctl/race"
run_job rejected-twice
((!job_ok)) || fail '(rejected-twice) the run succeeded after two rejected pushes'
[[ $(pushed_subjects) == 'unrelated commit on main|concurrent commit 2|concurrent commit 3' ]] ||
  fail "(rejected-twice) origin got: $(pushed_subjects)"
[[ $(grep -c '^verify' "$events") == 3 ]] || fail '(rejected-twice) the push step retried more than once'
pass 'a second rejected push fails the run and pushes nothing'

setup notoken
all_secrets
unset 'secrets[GH_TOKEN_FOR_UPDATES]'
echo change >"$ctl/synthetic-models-watch"
run_job notoken
((!job_ok)) || fail '(notoken) the run succeeded without GH_TOKEN_FOR_UPDATES'
[[ -z $(pushed_subjects) ]] || fail "(notoken) origin got: $(pushed_subjects)"
grep -q 'GH_TOKEN_FOR_UPDATES' "$scratch/notoken.log" || fail '(notoken) the failure does not name GH_TOKEN_FOR_UPDATES'
pass 'without GH_TOKEN_FOR_UPDATES the run fails naming it and pushes nothing'
