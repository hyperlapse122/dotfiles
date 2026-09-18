#!/usr/bin/env bash
# test-ce-overlay-pr.sh -- proves .ci/ce-overlay-pr.sh, the GitHub side of the
# compound-engineering overlay rebase, without a network, a token, or a real gh.
#
# Every gh call the script makes lands on a stub first on PATH. The stub records
# its arguments and the GH_TOKEN it saw, then replays canned JSON from a rules
# file: `<glob on the joined argv>\t<exit code>\t<response files, comma separated>`.
# A rule with several response files answers its Nth match with the Nth file and
# repeats the last one, which is how a pull request "falls behind main" or a
# check "appears later" here. A call matching GH_STUB_HANG never answers, which
# is how a stalled connection is simulated. A local bare repository is the push remote for
# `marker` and `open`. Deadlines run in seconds.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/.ci/ce-overlay-pr.sh"
# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"

[ -x "$script" ] || {
  printf 'test-ce-overlay-pr: missing or non-executable %s\n' "$script" >&2
  exit 1
}
command -v jq >/dev/null || {
  printf 'test-ce-overlay-pr: jq is required\n' >&2
  exit 1
}
resolve_bun
[ -n "$BUN_BIN" ] || {
  printf 'test-ce-overlay-pr: bun is required to run the packages/ce-overlay-rebase CLI\n' >&2
  exit 1
}

real_git=$(command -v git)
scratch_root=${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlay-pr.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

stub="$scratch/stub"
remote="$scratch/remote.git"
work="$scratch/work"
mkdir -p -- "$scratch/bin"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GITHUB_REPOSITORY=hyperlapse122/dotfiles GH_STUB_DIR="$stub"
export PATH="$scratch/bin:$BUN_DIR:/usr/bin:/bin"

repo=hyperlapse122/dotfiles
target=compound-engineering-v3.27.0
branch=chore/rebase-ce-overlays-v3.27.0
prefix=home
marker_path="$prefix/.chezmoidata/ce-overlay-rebase.json"
lock_path="$prefix/.chezmoidata/releases.json"
base_path="$prefix/dot_local/share/compound-engineering-overlays/base.json"
patch_dir="$prefix/dot_local/share/compound-engineering-overlays/patches"
patch_path="$patch_dir/skills/ce-plan/scripts/elevation-dispatch.sh.patch"

case_name=''
out=''
err=''
rc=0
resp_n=0
run_cwd=$scratch
run_env=()

cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
dir=${GH_STUB_DIR:?}
n=0
[ -f "$dir/count" ] && n=$(<"$dir/count")
n=$((n + 1))
printf '%s' "$n" >"$dir/count"
mkdir -p "$dir/calls"
printf '%s\0' "$@" >"$dir/calls/$n.argv"
key="$*"
printf '%s\t%s\t%s\n' "$n" "${GH_TOKEN-}" "${key//$'\n'/ }" >>"$dir/log"
if [ -n "${GH_STUB_HANG-}" ]; then
  case $key in
  $GH_STUB_HANG) exec sleep 30 ;;
  esac
fi
i=0
while IFS=$'\t' read -r glob code files; do
  i=$((i + 1))
  case $key in
  $glob)
    hits=0
    [ -f "$dir/hits.$i" ] && hits=$(<"$dir/hits.$i")
    printf '%s' "$((hits + 1))" >"$dir/hits.$i"
    IFS=, read -r -a list <<<"$files"
    idx=$hits
    [ "$idx" -lt "${#list[@]}" ] || idx=$((${#list[@]} - 1))
    file=${list[$idx]}
    if [ "$code" = 0 ]; then
      [ "$file" = - ] || cat "$file"
    else
      [ "$file" = - ] || cat "$file" >&2
    fi
    exit "$code"
    ;;
  esac
done <"$dir/rules"
printf 'stub gh: no rule for: %s\n' "$key" >&2
exit 99
STUB
chmod +x "$scratch/bin/gh"

# A git wrapper that loses the push race on purpose: before each of the first
# GIT_STUB_RACES pushes it advances the remote, so the real push is rejected as
# non-fast-forward. Every other invocation passes straight through.
cat >"$scratch/bin/git" <<STUB
#!/usr/bin/env bash
real='$real_git'
push=0
for a in "\$@"; do [ "\$a" = push ] && push=1; done
if [ "\$push" = 1 ] && [ -n "\${GIT_STUB_RACES-}" ]; then
  n=0
  [ -f "\$GIT_STUB_STATE/pushes" ] && n=\$(<"\$GIT_STUB_STATE/pushes")
  printf '%s' "\$((n + 1))" >"\$GIT_STUB_STATE/pushes"
  if [ "\$n" -lt "\$GIT_STUB_RACES" ]; then
    tmp=\$(mktemp -d)
    "\$real" clone -q "\$GIT_STUB_REMOTE" "\$tmp/c"
    printf 'race %s\n' "\$n" >>"\$tmp/c/README.md"
    "\$real" -C "\$tmp/c" -c user.name=race -c user.email=race@example.invalid -c commit.gpgsign=false commit -q -am "race \$n"
    "\$real" -C "\$tmp/c" push -q origin HEAD:main
    rm -rf "\$tmp"
  fi
fi
exec "\$real" "\$@"
STUB
chmod +x "$scratch/bin/git"

tgit() { "$real_git" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }

fail() {
  printf 'test-ce-overlay-pr: FAIL [%s]: %s\n' "$case_name" "$*" >&2
  [ -z "$err" ] || printf -- '--- stderr ---\n%s\n--------------\n' "$err" >&2
  exit 1
}

pass() { printf 'test-ce-overlay-pr: ok - %s\n' "$1"; }

begin() {
  case_name=$1
  out=''
  err=''
  rm -rf -- "$stub"
  mkdir -p -- "$stub/resp"
  : >"$stub/rules"
  : >"$stub/log"
  run_env=()
  run_cwd=$scratch
  unset GIT_STUB_RACES
}

# stub_rule <glob> <exit> <response body>...: the Nth match answers with the Nth body.
# A rule added later wins over an earlier one, so a case can override a shared default.
# Add every rule of a case before its first run: the hit counters are keyed by line.
stub_rule() {
  local glob=$1 code=$2 files='' body
  shift 2
  for body in "$@"; do
    resp_n=$((resp_n + 1))
    printf '%s' "$body" >"$stub/resp/$resp_n"
    files+="${files:+,}$stub/resp/$resp_n"
  done
  {
    printf '%s\t%s\t%s\n' "$glob" "$code" "${files:--}"
    cat "$stub/rules"
  } >"$stub/rules.new"
  mv "$stub/rules.new" "$stub/rules"
}

run_pr() {
  local errf="$scratch/stderr"
  out=$(cd -- "$run_cwd" && env -u CE_REBASE_TOKEN -u GITHUB_TOKEN -u GH_TOKEN -u CE_LOCK_APP_ID \
    -u CE_LOCK_APP_PRIVATE_KEY -u CE_PUSH_TOKEN -u CE_DEFAULT_BRANCH -u GITHUB_ACTIONS -u GITHUB_RUN_ID \
    "${run_env[@]}" "$script" "$@" 2>"$errf") && rc=0 || rc=$?
  err=$(<"$errf")
}

result_field() { tr ' ' '\n' <<<"$out" | sed -n "s/^$1=//p" | head -n 1; }
expect_rc() { [ "$rc" -eq "$1" ] || fail "expected exit $1, got $rc; stdout: $out"; }
expect_field() { [ "$(result_field "$1")" = "$2" ] || fail "expected $1=$2, got '$(result_field "$1")' in: $out"; }
expect_err() { grep -Fq -- "$1" <<<"$err" || fail "stderr does not contain '$1'"; }
call_count() { grep -Ec -- "$1" "$stub/log" || true; }
expect_call() { [ "$(call_count "$1")" -ge 1 ] || fail "no gh call matches $1"; }
expect_no_call() { [ "$(call_count "$1")" -eq 0 ] || fail "unexpected gh call matches $1"; }
call_num() { grep -E -m1 -- "$1" "$stub/log" | cut -f1; }

# call_arg <call number> <flag>: the value after the flag in that call's argv.
call_arg() {
  local -a argv=()
  local item i
  while IFS= read -r -d '' item; do argv+=("$item"); done <"$stub/calls/$1.argv"
  for ((i = 0; i < ${#argv[@]}; i++)); do
    if [ "${argv[i]}" = "$2" ]; then
      printf '%s' "${argv[i + 1]}"
      return 0
    fi
  done
  return 1
}

expect_only_token() {
  local bad
  bad=$(awk -F'\t' -v t="$1" '$2 != t' "$stub/log" | head -n 1)
  [ -z "$bad" ] || fail "a gh call ran with a token other than $1: $bad"
}

# --- canned API responses ---------------------------------------------------

repo_json() { jq -n -c --argjson a "$1" '{default_branch: "main", allow_auto_merge: $a}'; }

rules_json() { # <context> <integration id or null> <strict> <ruleset id>
  jq -n -c --arg c "$1" --argjson app "$2" --argjson strict "$3" --argjson id "$4" '
    [{type: "required_status_checks", ruleset_id: $id, ruleset_source_type: "Repository",
      parameters: {strict_required_status_checks_policy: $strict, required_status_checks: [{context: $c, integration_id: $app}]}},
     {type: "deletion", ruleset_id: $id}]'
}

app_bypass='[{"actor_id":123,"actor_type":"Integration","bypass_mode":"always"}]'

ruleset_json() { # <current_user_can_bypass> [bypass_actors JSON, or null to omit the field]
  jq -n -c --arg b "$1" --argjson actors "${2-$app_bypass}" \
    '{id: 42, current_user_can_bypass: $b} + (if $actors == null then {} else {bypass_actors: $actors} end)'
}

env_name=ce-overlay-rebase
env_ok='{"name":"ce-overlay-rebase","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
policies_ok='{"total_count":1,"branch_policies":[{"id":1,"name":"main","type":"branch"}]}'

pr_json() { # <state> <merged> <mergeable> <mergeable_state> <head sha>
  jq -n -c --arg s "$1" --argjson m "$2" --argjson mg "$3" --arg ms "$4" --arg sha "$5" --arg ref "$branch" \
    '{state: $s, merged: $m, mergeable: $mg, mergeable_state: $ms, head: {sha: $sha, ref: $ref}, merge_commit_sha: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}'
}

runs_json() { # <status> <conclusion or null> [app id]
  jq -n -c --arg s "$1" --argjson c "$2" --argjson app "${3:-15368}" \
    '{check_runs: [{name: "Final delivery", status: $s, conclusion: $c, app: {id: $app, slug: "github-actions"}}]}'
}

no_runs='{"check_runs":[]}'

sha_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
sha_m=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# --- git fixtures ------------------------------------------------------------

seed_remote() {
  rm -rf -- "$remote" "$scratch/seed" "$work" "$scratch/gitstate"
  mkdir -p -- "$scratch/gitstate"
  "$real_git" init -q --bare -b main "$remote"
  "$real_git" init -q -b main "$scratch/seed"
  mkdir -p -- "$scratch/seed/$patch_dir/skills/ce-plan/scripts" "$scratch/seed/$prefix/.chezmoidata" \
    "$scratch/seed/$prefix/dot_local/share/compound-engineering-overlays"
  printf 'home\n' >"$scratch/seed/.chezmoiroot"
  printf 'readme\n' >"$scratch/seed/README.md"
  cp "$repo_root/home/.chezmoidata/ce-overlay-rebase.json" "$scratch/seed/$marker_path"
  printf '{"tools":{"compound-engineering":"old","other":"old"}}\n' >"$scratch/seed/$lock_path"
  printf '{"version":"compound-engineering-v3.26.3"}\n' >"$scratch/seed/$base_path"
  printf 'old patch\n' >"$scratch/seed/$patch_path"
  tgit -C "$scratch/seed" add -A
  tgit -C "$scratch/seed" commit -q -m seed
  "$real_git" -C "$scratch/seed" remote add origin "$remote"
  "$real_git" -C "$scratch/seed" push -q origin main
  "$real_git" clone -q "$remote" "$work"
}

edit_work_tree() {
  printf '{"tools":{"compound-engineering":"new","other":"old"}}\n' >"$work/$lock_path"
  printf '{"version":"%s"}\n' "$target" >"$work/$base_path"
  printf 'new patch\n' >"$work/$patch_path"
}

remote_main_paths() { "$real_git" -C "$remote" diff --name-only "$1" "$2"; }

remote_marker() { "$real_git" -C "$remote" show "$1:$marker_path" | jq -c .ceOverlayRebase; }

# --- preflight ----------------------------------------------------------------

preflight_env() {
  run_env=(CE_REBASE_TOKEN=tok-rebase GITHUB_TOKEN=tok-github CE_LOCK_APP_ID=123 CE_LOCK_APP_PRIVATE_KEY=key)
}

preflight_rules() { # <auto-merge> <context> <integration id> <strict> <bypass> [bypass_actors JSON]
  stub_rule "api repos/$repo" 0 "$(repo_json "$1")"
  stub_rule "api repos/$repo/rules/branches/main" 0 "$(rules_json "$2" "$3" "$4" 42)"
  stub_rule "api repos/$repo/rulesets/42" 0 "$(ruleset_json "$5" "${6-$app_bypass}")"
  stub_rule "api repos/$repo/environments/$env_name" 0 "$env_ok"
  stub_rule "api repos/$repo/environments/$env_name/deployment-branch-policies" 0 "$policies_ok"
}

begin 'preflight-p1'
preflight_env
run_env=(CE_REBASE_TOKEN= GITHUB_TOKEN=tok-github CE_LOCK_APP_ID=123 CE_LOCK_APP_PRIVATE_KEY=key)
preflight_rules true 'Final delivery' 15368 true never
run_pr preflight
expect_rc 1
expect_err 'CE_REBASE_TOKEN'
expect_field missing P1
expect_field class configuration
expect_no_call 'pr create'
[ "$(call_count '.')" -eq 0 ] || fail 'a populated GITHUB_TOKEN made preflight call gh with an empty CE_REBASE_TOKEN'
run_env=(CE_REBASE_TOKEN='   ' GITHUB_TOKEN=tok-github)
run_pr preflight
expect_rc 1
expect_field missing P1
run_env=(GITHUB_TOKEN=tok-github)
run_pr preflight
expect_rc 1
expect_field missing P1
[ "$(call_count '.')" -eq 0 ] || fail 'preflight called gh with CE_REBASE_TOKEN unset'
pass 'an empty CE_REBASE_TOKEN fails preflight naming P1 and no GITHUB_TOKEN substitutes'

begin 'preflight-p2'
preflight_env
preflight_rules false 'Final delivery' 15368 true never
run_pr preflight
expect_rc 1
expect_field missing P2
expect_err 'Allow auto-merge'
pass 'auto-merge off fails preflight naming P2'

begin 'preflight-first-missing'
preflight_env
preflight_rules false 'Other check' 15368 false always
run_env+=(CE_LOCK_APP_ID=)
run_pr preflight
expect_rc 1
expect_field missing P2
pass 'preflight names only the first missing prerequisite'

begin 'preflight-p3-check-missing'
preflight_env
preflight_rules true 'Other check' 15368 true never
run_pr preflight
expect_rc 1
expect_field missing P3
expect_field detail check-missing
expect_err 'Final delivery'
pass 'no required Final delivery check fails preflight naming P3'

begin 'preflight-p3-no-rules'
preflight_env
stub_rule "api repos/$repo" 0 "$(repo_json true)"
stub_rule "api repos/$repo/rules/branches/main" 0 '[]'
run_pr preflight
expect_rc 1
expect_field missing P3
pass 'a default branch with no rules fails preflight naming P3'

begin 'preflight-p3-unbound'
preflight_env
preflight_rules true 'Final delivery' null true never
run_pr preflight
expect_rc 1
expect_field missing P3
expect_field detail check-unbound
expect_err 'GitHub Actions'
begin 'preflight-p3-wrong-source'
preflight_env
preflight_rules true 'Final delivery' 999 true never
run_pr preflight
expect_rc 1
expect_field detail check-unbound
pass 'a required check not bound to the GitHub Actions source fails preflight naming P3'

begin 'preflight-p3-strict-off'
preflight_env
preflight_rules true 'Final delivery' 15368 false never
run_pr preflight
expect_rc 1
expect_field missing P3
expect_field detail up-to-date-off
expect_err 'up to date'
pass 'the up-to-date rule off fails preflight naming that rule'

begin 'preflight-p3-bypass'
for mode in always pull_requests_only exempt unknown; do
  begin "preflight-p3-bypass-$mode"
  preflight_env
  preflight_rules true 'Final delivery' 15368 true "$mode"
  run_pr preflight
  expect_rc 1
  expect_field missing P3
  expect_field detail bypass
  expect_err 'can bypass'
done
pass 'a ruleset the CE_REBASE_TOKEN identity can bypass fails preflight naming the bypass'

begin 'preflight-p4'
preflight_env
run_env=(CE_REBASE_TOKEN=tok-rebase GITHUB_TOKEN=tok-github)
preflight_rules true 'Final delivery' 15368 true never
run_pr preflight
expect_rc 1
expect_field missing P4
expect_err 'CE_LOCK_APP_PRIVATE_KEY'
pass 'missing App credentials with a ruleset present fail preflight naming P4'

begin 'preflight-p4-bypass-actors'
for variant in missing-app other-app extra-actor not-always wrong-type hidden; do
  begin "preflight-p4-bypass-actors-$variant"
  preflight_env
  case $variant in
  missing-app) actors='[]' ;;
  other-app) actors='[{"actor_id":999,"actor_type":"Integration","bypass_mode":"always"}]' ;;
  extra-actor) actors='[{"actor_id":123,"actor_type":"Integration","bypass_mode":"always"},{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]' ;;
  not-always) actors='[{"actor_id":123,"actor_type":"Integration","bypass_mode":"pull_request"}]' ;;
  wrong-type) actors='[{"actor_id":123,"actor_type":"User","bypass_mode":"always"}]' ;;
  hidden) actors=null ;;
  esac
  preflight_rules true 'Final delivery' 15368 true never "$actors"
  run_pr preflight
  expect_rc 1
  expect_field class configuration
  expect_field missing P3
  expect_field detail bypass-unauthorized
  expect_err 'CE_LOCK_APP_ID'
done
pass 'a ruleset whose bypass list is not exactly the P4 App in Always mode fails preflight naming P3'

begin 'preflight-p5'
for variant in missing no-policy protected-only two-policies other-branch tag-policy; do
  begin "preflight-p5-$variant"
  preflight_env
  preflight_rules true 'Final delivery' 15368 true never
  case $variant in
  missing) stub_rule "api repos/$repo/environments/$env_name" 1 'gh: Not Found (HTTP 404)' ;;
  no-policy) stub_rule "api repos/$repo/environments/$env_name" 0 '{"name":"ce-overlay-rebase","deployment_branch_policy":null}' ;;
  protected-only) stub_rule "api repos/$repo/environments/$env_name" 0 '{"name":"ce-overlay-rebase","deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}' ;;
  two-policies) stub_rule "api repos/$repo/environments/$env_name/deployment-branch-policies" 0 '{"total_count":2,"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":2,"name":"feature/*","type":"branch"}]}' ;;
  other-branch) stub_rule "api repos/$repo/environments/$env_name/deployment-branch-policies" 0 '{"total_count":1,"branch_policies":[{"id":1,"name":"release","type":"branch"}]}' ;;
  tag-policy) stub_rule "api repos/$repo/environments/$env_name/deployment-branch-policies" 0 '{"total_count":1,"branch_policies":[{"id":1,"name":"main","type":"tag"}]}' ;;
  esac
  run_pr preflight
  expect_rc 1
  expect_field class configuration
  expect_field missing P5
  expect_err 'ce-overlay-rebase'
done
pass 'a missing environment, or one not limited to the default branch alone, fails preflight naming P5'

begin 'preflight-401'
preflight_env
stub_rule "api repos/$repo" 1 'gh: Bad credentials (HTTP 401)'
run_pr preflight
expect_rc 1
expect_field class configuration
expect_field detail unauthorized
pass 'a 401 from the API makes preflight report configuration'

begin 'preflight-ok'
preflight_env
preflight_rules true 'Final delivery' 15368 true never
run_pr preflight
expect_rc 0
expect_field result ok
expect_field class none
expect_only_token tok-rebase
expect_no_call 'pr create'
expect_call "environments/$env_name/deployment-branch-policies"
pass 'preflight passes when P1-P5 hold, and every call used CE_REBASE_TOKEN'

# --- marker -------------------------------------------------------------------

marker_args=(--remote "$remote" --default-branch main)

begin 'marker-awaiting-review'
seed_remote
edit_work_tree
printf 'dirty\n' >>"$work/README.md"
printf 'staged\n' >"$work/staged.txt"
tgit -C "$work" add staged.txt
before_status=$("$real_git" -C "$work" status --porcelain)
before_head=$("$real_git" -C "$work" rev-parse HEAD)
before_main=$("$real_git" -C "$remote" rev-parse main)
run_cwd=$work
run_pr marker "${marker_args[@]}" --event awaiting-review --target "$target"
expect_rc 0
expect_field result pushed
stop_sha=$(result_field sha)
[ "$stop_sha" = "$("$real_git" -C "$remote" rev-parse main)" ] || fail 'the printed sha is not the main tip'
[ "$(remote_main_paths "$before_main" "$stop_sha")" = "$marker_path" ] || fail 'the marker commit changes more than the marker path'
[ "$(remote_marker "$stop_sha" | jq -r '.status + " " + .target')" = "awaiting-review $target" ] || fail 'the marker on main is not awaiting-review for the target'
[ "$("$real_git" -C "$work" status --porcelain)" = "$before_status" ] || fail 'the caller work tree changed'
[ "$("$real_git" -C "$work" rev-parse HEAD)" = "$before_head" ] || fail 'the caller HEAD moved'
pass 'marker builds a marker-only commit from a fresh checkout, leaving a dirty work tree alone, and prints its sha'

begin 'open-after-stop-commit'
# main holds the awaiting-review stop commit; the branch must start there and reset the marker to idle
work_head=$("$real_git" -C "$work" rev-parse HEAD)
edit_work_tree
git -C "$work" checkout -q -- README.md
git -C "$work" reset -q
rm -f "$work/staged.txt"
stub_rule "pr create*" 0 "https://github.com/$repo/pull/7"
run_env=(CE_REBASE_TOKEN=tok-rebase GITHUB_TOKEN=tok-github)
run_cwd=$work
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines changed --base "$stop_sha"
expect_rc 0
expect_field result awaiting-review
expect_field pr 7
branch_sha=$("$real_git" -C "$remote" rev-parse "refs/heads/$branch")
[ "$("$real_git" -C "$remote" rev-parse "$branch^")" = "$stop_sha" ] || fail 'the branch does not start at the stop commit'
[ "$(remote_marker "$branch" | jq -r '.status + " " + .target')" = "idle $target" ] || fail 'the branch commit does not reset the marker to idle'
[ "$(remote_main_paths "$stop_sha" "$branch_sha" | sort | tr '\n' ' ')" = "$(printf '%s\n' "$base_path" "$lock_path" "$marker_path" "$patch_path" | sort | tr '\n' ' ')" ] ||
  fail 'the branch commit changes paths outside the lock, base.json, the patches, and the marker'
[ "$("$real_git" -C "$remote" rev-parse main)" = "$stop_sha" ] || fail 'open moved main'
expect_no_call 'pr merge'
work_head_after=$("$real_git" -C "$work" rev-parse HEAD)
[ "$work_head" = "$work_head_after" ] || fail 'open moved the caller HEAD'
pass 'awaiting-review: the stop commit reaches main first, then the branch starts there and resets the marker to idle'

begin 'marker-race'
seed_remote
export GIT_STUB_RACES=1 GIT_STUB_REMOTE="$remote" GIT_STUB_STATE="$scratch/gitstate"
before_main=$("$real_git" -C "$remote" rev-parse main)
run_env=(GIT_STUB_RACES=1 GIT_STUB_REMOTE="$remote" GIT_STUB_STATE="$scratch/gitstate")
run_pr marker "${marker_args[@]}" --event awaiting-review --target "$target"
expect_rc 0
expect_field result pushed
new_tip=$("$real_git" -C "$remote" rev-parse main)
race_commit=$("$real_git" -C "$remote" rev-parse "$new_tip^")
[ "$("$real_git" -C "$remote" log -1 --format=%s "$race_commit")" = 'race 0' ] || fail 'the marker commit was not re-created on the raced tip'
[ "$(remote_main_paths "$race_commit" "$new_tip")" = "$marker_path" ] || fail 'the re-created commit changes more than the marker path'
[ "$(cat "$scratch/gitstate/pushes")" = 2 ] || fail "expected 2 push attempts, got $(cat "$scratch/gitstate/pushes")"
pass 'marker re-creates its commit on the new tip after a lost push race'

begin 'marker-race-limit'
seed_remote
rm -f "$scratch/gitstate/pushes"
before_main=$("$real_git" -C "$remote" rev-parse main)
run_env=(GIT_STUB_RACES=99 GIT_STUB_REMOTE="$remote" GIT_STUB_STATE="$scratch/gitstate")
run_pr marker "${marker_args[@]}" --event awaiting-review --target "$target"
expect_rc 1
expect_field detail push-race
[ "$(cat "$scratch/gitstate/pushes")" = 4 ] || fail "expected 4 push attempts (1 + 3 re-creations), got $(cat "$scratch/gitstate/pushes")"
[ "$("$real_git" -C "$remote" log --format=%s main | grep -c 'record rebase marker' || true)" -eq 0 ] || fail 'a marker commit reached main despite every push losing'
pass 'marker re-creates at most three times, then fails'

begin 'marker-protected'
seed_remote
before_main=$("$real_git" -C "$remote" rev-parse main)
printf '#!/bin/sh\necho "remote: error: GH013: Repository rule violations found for refs/heads/main." >&2\nexit 1\n' >"$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
run_pr marker "${marker_args[@]}" --event awaiting-review --target "$target"
expect_rc 1
expect_field result push-rejected
expect_field missing P3
expect_err 'bypass entry'
expect_err 'every tool'
[ "$("$real_git" -C "$remote" rev-parse main)" = "$before_main" ] || fail 'a rejected push moved main'
rm -f "$remote/hooks/pre-receive"
pass 'a ruleset rejection names the P3 bypass entry'

begin 'marker-failure-event'
seed_remote
run_pr marker "${marker_args[@]}" --event failure --target "$target" --failure-class outage --reached-claude true \
  --now 2026-09-19T10:00:00Z --issue 12
expect_rc 0
[ "$(remote_marker main | jq -r '[.status, (.attempts | tostring), .failureClass, .notBefore, (.issue | tostring)] | join(" ")')" = \
  'deferred 1 outage 2026-09-19T12:00:00.000Z 12' ] || fail "unexpected marker: $(remote_marker main)"
pass 'a failure event writes the deferred marker with attempts, the two-hour floor, and the issue number'

begin 'marker-unchanged'
seed_remote
run_pr marker "${marker_args[@]}" --event reset --target "$target"
expect_rc 0
expect_field result pushed
run_pr marker "${marker_args[@]}" --event reset --target "$target"
expect_rc 0
expect_field result unchanged
pass 'a marker event that changes nothing pushes nothing'

begin 'marker-refused'
seed_remote
before_main=$("$real_git" -C "$remote" rev-parse main)
run_pr marker "${marker_args[@]}" --event failure --target "$target" --failure-class bogus
expect_rc 1
expect_field detail marker-refused
[ "$("$real_git" -C "$remote" rev-parse main)" = "$before_main" ] || fail 'a refused marker still reached main'
run_pr marker "${marker_args[@]}" --event failure --target v3.27 --failure-class outage
expect_rc 2
pass 'an invalid marker or target is refused and nothing is pushed'

begin 'guard-paths'
seed_remote
# shellcheck source=.ci/ce-overlay-pr.sh
source "$script"
declare -F ceo_tag_valid >/dev/null || fail 'the shared ceo_tag_valid is not available to the script'
if declare -F tag_valid >/dev/null; then fail 'the script still carries its own tag_valid copy'; fi
set_paths "$work"
base_commit=$("$real_git" -C "$work" rev-parse HEAD)
printf '{}\n' >"$work/$marker_path"
tgit -C "$work" commit -q -am 'marker only'
marker_commit=$("$real_git" -C "$work" rev-parse HEAD)
printf 'x\n' >>"$work/README.md"
printf '{}\n' >>"$work/$marker_path"
tgit -C "$work" commit -q -am 'marker and readme'
both_commit=$("$real_git" -C "$work" rev-parse HEAD)
assert_commit_paths "$work" "$base_commit" "$marker_commit" allow_marker_only 2>/dev/null || fail 'a marker-only commit was refused'
if assert_commit_paths "$work" "$base_commit" "$both_commit" allow_marker_only 2>/dev/null; then fail 'a commit with another path passed the marker guard'; fi
if assert_commit_paths "$work" "$marker_commit" "$marker_commit" allow_marker_only 2>/dev/null; then fail 'an empty commit passed the guard'; fi
if assert_commit_paths "$work" "$base_commit" "$both_commit" allow_pr_paths 2>/dev/null; then fail 'a commit touching README.md passed the pull request guard'; fi
pass 'the push guard refuses any changed path outside its allowlist'

# --- open ---------------------------------------------------------------------

open_env() { run_env=(CE_REBASE_TOKEN=tok-rebase GITHUB_TOKEN=tok-github); }

begin 'open-unchanged'
seed_remote
edit_work_tree
printf 'dirty\n' >>"$work/README.md"
git -C "$work" checkout -q -- README.md
open_env
stub_rule "pr create*" 0 "https://github.com/$repo/pull/7"
stub_rule "pr merge*" 0 '-'
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 0
expect_field result auto-merge
expect_field pr 7
expect_field class none
expect_call "pr create .*--head $branch"
expect_call "pr merge 7 --repo $repo --merge --auto\$"
expect_no_call '--admin|--squash|--rebase'
expect_only_token tok-rebase
create_no=$(call_num 'pr create')
[ "$(call_arg "$create_no" --base)" = main ] || fail 'the pull request base is not main'
[ "$(call_arg "$create_no" --head)" = "$branch" ] || fail 'the pull request head is not the rebase branch'
title=$(call_arg "$create_no" --title)
body=$(call_arg "$create_no" --body)
if grep -Eiq '@claude' <<<"$title
$body"; then fail 'the generated title or body contains @claude'; fi
main_tip=$("$real_git" -C "$remote" rev-parse main)
[ "$("$real_git" -C "$remote" rev-parse "$branch^")" = "$main_tip" ] || fail 'the branch does not start at the work tree HEAD'
[ "$(remote_main_paths main "$branch" | sort | tr '\n' ' ')" = "$(printf '%s\n' "$base_path" "$lock_path" "$marker_path" "$patch_path" | sort | tr '\n' ' ')" ] ||
  fail 'the branch commit changes paths outside the allowlist'
[ "$(remote_marker "$branch" | jq -r '.status + " " + .target')" = "idle $target" ] || fail 'the branch marker is not idle at the target'
pass 'open pushes the rebase branch, creates the pull request as CE_REBASE_TOKEN, and enables auto-merge with --merge --auto only'

begin 'open-changed'
seed_remote
edit_work_tree
open_env
stub_rule "pr create*" 0 "https://github.com/$repo/pull/8"
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines changed
expect_rc 0
expect_field result awaiting-review
expect_field pr 8
expect_call 'pr create'
expect_no_call 'pr merge'
pass 'open with a changed customization line makes no merge call and reports awaiting-review'

begin 'open-auto-merge-refused'
seed_remote
edit_work_tree
open_env
stub_rule 'pr create*' 0 "https://github.com/$repo/pull/10"
stub_rule 'pr merge*' 1 'gh: Auto merge is not allowed (HTTP 422)'
stub_rule 'pr close 10*' 0 '-'
stub_rule 'api -X DELETE*' 0 '-'
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field class configuration
expect_field missing P2
expect_field detail auto-merge-failed
expect_call 'pr close 10'
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
pass 'a refused auto-merge closes the pull request, deletes the branch, and reports configuration P2'

begin 'open-pr-number-unreadable'
seed_remote
edit_work_tree
open_env
stub_rule 'pr create*' 0 'created something, but no pull request link'
stub_rule 'api -X DELETE*' 0 '-'
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field class unknown
expect_field detail pr-number-unreadable
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
expect_no_call 'pr merge'
pass 'a pull request URL that carries no number deletes the pushed branch'

begin 'open-stale-branch'
seed_remote
edit_work_tree
open_env
"$real_git" init -q -b stale "$scratch/stale"
printf 'stale\n' >"$scratch/stale/stale.txt"
tgit -C "$scratch/stale" add -A
tgit -C "$scratch/stale" commit -q -m stale
"$real_git" -C "$scratch/stale" push -q "$remote" "stale:refs/heads/$branch"
stale_sha=$("$real_git" -C "$remote" rev-parse "refs/heads/$branch")
stub_rule 'pr create*' 0 "https://github.com/$repo/pull/11"
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines changed
expect_rc 0
expect_field result awaiting-review
expect_field pr 11
new_sha=$("$real_git" -C "$remote" rev-parse "refs/heads/$branch")
[ "$new_sha" != "$stale_sha" ] || fail 'the stale branch was not replaced'
[ "$new_sha" = "$(result_field sha)" ] || fail 'the branch does not hold the commit open reported'
[ "$("$real_git" -C "$remote" rev-parse "$branch^")" = "$("$real_git" -C "$remote" rev-parse main)" ] || fail 'the replaced branch does not start at main'
rm -rf -- "$scratch/stale"
pass 'open replaces a stale rebase branch for the same target that has unrelated history'

begin 'open-refuses-other-changes'
seed_remote
edit_work_tree
printf 'tampered\n' >>"$work/README.md"
open_env
stub_rule "pr create*" 0 "https://github.com/$repo/pull/9"
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field detail path-outside-allowlist
expect_no_call 'pr create'
"$real_git" -C "$remote" rev-parse --verify -q "refs/heads/$branch" >/dev/null && fail 'a branch was pushed despite a change outside the allowlist'
git -C "$work" checkout -q -- README.md
printf 'evil\n' >"$work/$patch_dir/evil.sh"
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field detail path-outside-allowlist
expect_no_call 'pr create'
pass 'open refuses a tracked change outside the allowlist and a stray file in the patches directory'

begin 'open-no-token'
seed_remote
edit_work_tree
run_env=(GITHUB_TOKEN=tok-github)
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field missing P1
expect_no_call 'pr create'
pass 'open without CE_REBASE_TOKEN never creates a pull request'

begin 'open-401'
seed_remote
edit_work_tree
open_env
stub_rule "pr create*" 1 'gh: Bad credentials (HTTP 401)'
stub_rule "api -X DELETE*" 0 '-'
run_pr open "${marker_args[@]}" --target "$target" --work-tree "$work" --customization-lines unchanged
expect_rc 1
expect_field class configuration
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
pass 'a 401 while creating the pull request reports configuration and deletes the pushed branch'

begin 'tag-refused'
seed_remote
open_env
for bad in compound-engineering-v3.27.0-rc.1 compound-engineering-v3.27.0+build.5 compound-engineering-v3.27; do
  run_pr open "${marker_args[@]}" --target "$bad" --work-tree "$work" --customization-lines unchanged
  expect_rc 2
  run_pr marker "${marker_args[@]}" --event reset --target "$bad"
  expect_rc 2
  run_pr issue --target "$bad" --failure-class outage
  expect_rc 2
done
[ "$(call_count '.')" -eq 0 ] || fail 'a refused target still reached gh'
pass 'open, marker and issue refuse a target that is not a plain compound-engineering-v<major>.<minor>.<patch> tag'

# --- await --------------------------------------------------------------------

await_args=(--pr 7 --customization-lines unchanged --default-branch main --deadline-seconds 2 --interval-seconds 0.1)

close_rules() {
  stub_rule "pr close 7*" 0 '-'
  stub_rule "api -X DELETE repos/$repo/git/refs/heads/$branch" 0 '-'
}

begin 'await-behind'
open_env
# poll 1: head A, two commits behind main -> update; poll 2: new head B, check not there yet;
# poll 3: check green; poll 4: merged
stub_rule "api repos/$repo/pulls/7" 0 \
  "$(pr_json open false true behind $sha_a)" "$(pr_json open false true clean $sha_b)" "$(pr_json open false true clean $sha_b)" "$(pr_json closed true true clean $sha_b)"
stub_rule "api repos/$repo/compare/main...$sha_a" 0 '{"behind_by":2}'
stub_rule "api repos/$repo/compare/main...$sha_b" 0 '{"behind_by":0}'
stub_rule "api -X PUT repos/$repo/pulls/7/update-branch*" 0 '{"message":"Updating pull request branch."}'
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json in_progress null)"
stub_rule "api --paginate repos/$repo/commits/$sha_b/check-runs*" 0 "$no_runs" "$(runs_json completed '"success"')"
run_pr await "${await_args[@]}"
expect_rc 0
expect_field result merged
expect_field sha "$sha_b"
update_no=$(call_num 'update-branch')
[ "$(call_arg "$update_no" -f)" = "expected_head_sha=$sha_a" ] || fail 'the branch update did not name the behind head as expected_head_sha'
[ "$(call_count 'update-branch')" -eq 1 ] || fail 'the branch was updated more than once'
first_new_check=$(call_num "commits/$sha_b/check-runs")
[ "$first_new_check" -gt "$update_no" ] || fail 'the new check run was not awaited after the update'
expect_no_call 'pr close'
pass 'a pull request that falls behind main is updated with a merge, then the new check run is awaited until it merges'

begin 'await-deadline'
open_env
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json open false true blocked $sha_a)"
stub_rule "api repos/$repo/compare/main...$sha_a" 0 '{"behind_by":0}'
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json in_progress null)"
start=$SECONDS
run_pr await "${await_args[@]}"
expect_rc 1
expect_field class unknown
expect_field detail deadline
[ $((SECONDS - start)) -le 6 ] || fail 'the deadline took far longer than requested'
expect_call 'pr close 7'
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
pass 'a pending check ends at the deadline: the pull request is closed, the branch deleted, and the class is unknown'

begin 'await-hanging-gh'
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json open false true blocked $sha_a)"
run_env=(CE_REBASE_TOKEN=tok-rebase GITHUB_TOKEN=tok-github GH_STUB_HANG="api repos/*/pulls/7" CE_GH_TIMEOUT_SECONDS=1)
start=$SECONDS
run_pr await "${await_args[@]}"
expect_rc 1
expect_field class unknown
expect_field detail deadline
[ $((SECONDS - start)) -le 8 ] || fail "a stalled gh call held await for $((SECONDS - start))s past its 2s deadline"
expect_err 'timed out'
expect_call 'pr close 7'
pass 'a gh call that never answers is cut off, so await still reaches its deadline'

begin 'await-red-check'
open_env
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json open false true unstable $sha_a)"
stub_rule "api repos/$repo/compare/main...$sha_a" 0 '{"behind_by":0}'
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json completed '"failure"')"
run_pr await "${await_args[@]}"
expect_rc 1
expect_field class unknown
expect_field detail check-failed
expect_call 'pr close 7'
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
pass 'a failed required check closes the pull request, deletes the branch, and reports unknown'

begin 'await-merged-unchecked'
open_env
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json closed true true clean $sha_a)"
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$no_runs"
run_pr await "${await_args[@]}"
expect_rc 1
expect_field class unknown
expect_field detail merged-unchecked
expect_err 'merged unchecked'
begin 'await-merged-red-head'
open_env
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json closed true true clean $sha_a)"
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json completed '"failure"')"
run_pr await "${await_args[@]}"
expect_rc 1
expect_field detail merged-unchecked
begin 'await-merged-wrong-source'
open_env
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json closed true true clean $sha_a)"
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json completed '"success"' 4242)"
run_pr await "${await_args[@]}"
expect_rc 1
expect_field detail merged-unchecked
pass 'a merge whose final head has no green Final delivery from GitHub Actions reports unknown, merged unchecked'

begin 'await-merged-checked'
open_env
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json closed true true clean $sha_a)"
stub_rule "api --paginate repos/$repo/commits/$sha_a/check-runs*" 0 "$(runs_json completed '"success"')"
stub_rule "api --paginate repos/$repo/commits/$sha_m/check-runs*" 0 "$(runs_json completed '"cancelled"')"
run_pr await "${await_args[@]}"
expect_rc 0
expect_field result merged
expect_field class none
expect_no_call "commits/$sha_m/check-runs"
pass 'a merged and checked pull request reports success and never reads the push run on main'

begin 'await-conflict'
open_env
close_rules
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json open false false dirty $sha_a)"
run_pr await "${await_args[@]}"
expect_rc 0
expect_field result conflict
expect_field class none
expect_call 'pr close 7'
expect_call "api -X DELETE repos/$repo/git/refs/heads/$branch"
pass 'a pull request that conflicts with main is closed, its branch deleted, and no failure class is reported'

begin 'await-awaiting-review'
open_env
run_pr await --pr 7 --customization-lines changed --default-branch main
expect_rc 0
expect_field result awaiting-review
[ "$(call_count '.')" -eq 0 ] || fail 'await made a gh call for an awaiting-review pull request'
pass 'an awaiting-review pull request returns at once with no wait'

begin 'await-never-deletes-foreign-branch'
open_env
stub_rule "pr close 7*" 0 '-'
stub_rule "api repos/$repo/pulls/7" 0 "$(pr_json open false false dirty $sha_a | jq -c '.head.ref = "main"')"
run_pr await "${await_args[@]}"
expect_rc 0
expect_no_call 'api -X DELETE'
pass 'await never deletes a branch outside the rebase prefix'

# --- decide -------------------------------------------------------------------

idle_marker="$scratch/marker-idle.json"
escalated_marker="$scratch/marker-escalated.json"
escalated_null_marker="$scratch/marker-escalated-null.json"
jq '.ceOverlayRebase.target = "compound-engineering-v3.26.3"' "$repo_root/home/.chezmoidata/ce-overlay-rebase.json" >"$idle_marker"
jq '.ceOverlayRebase |= (.status = "escalated" | .failureClass = "genuine" | .attempts = 1 | .issue = 12)' "$idle_marker" >"$escalated_marker"
jq '.ceOverlayRebase.issue = null' "$escalated_marker" >"$escalated_null_marker"

decide_args=(--resolved-tag "$target" --pin compound-engineering-v3.26.3 --gate-class invalid --default-branch main
  --now 2026-09-19T12:00:00Z --marker-file "$idle_marker")

decide_clear() {
  stub_rule 'run list*' 0 '[]'
  stub_rule 'pr list*' 0 '[]'
  stub_rule 'issue view*' 0 "$(jq -n -c '{number: 12, state: "CLOSED", title: "x"}')"
  stub_rule 'issue list*' 0 '[]'
  stub_rule 'workflow run*' 0 '-'
}

begin 'decide-dispatch'
decide_clear
run_env=(GH_TOKEN=tok-lock)
run_pr decide "${decide_args[@]}"
expect_rc 0
expect_field result dispatch
expect_call "workflow run rebase-ce-overlays.yml --repo $repo --ref main"
pass 'decide dispatches on the default branch when nothing blocks it'

begin 'decide-state-query-failure'
decide_clear
stub_rule 'run list*' 1 'gh: Bad Gateway (HTTP 502)'
run_pr decide "${decide_args[@]}"
expect_rc 0
expect_field result skip
expect_field reason state-query-failed
expect_err 'no dispatch'
expect_no_call 'workflow run'
begin 'decide-state-query-failure-pr'
decide_clear
stub_rule 'pr list*' 1 'gh: Bad Gateway (HTTP 502)'
run_pr decide "${decide_args[@]}"
expect_field result skip
expect_no_call 'workflow run'
begin 'decide-unreadable-marker'
decide_clear
run_pr decide "${decide_args[@]}" --marker-file "$scratch/missing.json"
expect_field reason state-query-failed
expect_no_call 'workflow run'
pass 'a failed state query, or an unreadable marker, makes no dispatch and warns'

begin 'decide-orphaned-pr'
decide_clear
stub_rule 'pr list*' 0 "$(jq -n -c '[{number: 42, headRefName: "chore/rebase-ce-overlays-v3.26.9", createdAt: "2026-09-19T11:30:00Z", autoMergeRequest: {enabledBy: {login: "x"}}, isCrossRepository: false}]')"
stub_rule 'pr close 42*' 0 '-'
stub_rule 'api -X DELETE*' 0 '-'
run_pr decide "${decide_args[@]}"
expect_rc 0
expect_field result close-then-dispatch
expect_field closed 42
close_no=$(call_num 'pr close 42')
delete_no=$(call_num 'api -X DELETE repos/.*/heads/chore/rebase-ce-overlays-v3.26.9')
dispatch_no=$(call_num 'workflow run')
if ! { [ "$close_no" -lt "$delete_no" ] && [ "$delete_no" -lt "$dispatch_no" ]; }; then fail 'the order was not close, delete the branch, dispatch'; fi
pass 'decide closes an orphaned pull request, deletes its branch, then dispatches'

begin 'decide-fork-pr-ignored'
decide_clear
stub_rule 'pr list*' 0 "$(jq -n -c '[{number: 43, headRefName: "chore/rebase-ce-overlays-v3.26.9", createdAt: "2026-09-19T11:30:00Z", autoMergeRequest: null, isCrossRepository: true},
  {number: 44, headRefName: "feature/other", createdAt: "2026-09-19T11:30:00Z", autoMergeRequest: null, isCrossRepository: false}]')"
run_pr decide "${decide_args[@]}"
expect_field result dispatch
expect_no_call 'pr close'
pass 'decide ignores fork pull requests and branches outside the rebase prefix'

begin 'decide-skips'
decide_clear
stub_rule 'run list*' 0 "$(jq -n -c '[{databaseId: 900, status: "in_progress", conclusion: ""}]')"
run_pr decide "${decide_args[@]}"
expect_field result skip
expect_no_call 'workflow run'
begin 'decide-skip-queued'
decide_clear
stub_rule 'run list*' 0 "$(jq -n -c '[{databaseId: 901, status: "queued", conclusion: ""}, {databaseId: 899, status: "completed", conclusion: "success"}]')"
run_pr decide "${decide_args[@]}"
expect_field result skip
expect_no_call 'workflow run'
begin 'decide-exclude-run'
decide_clear
stub_rule 'run list*' 0 "$(jq -n -c '[{databaseId: 900, status: "in_progress", conclusion: ""}]')"
run_pr decide "${decide_args[@]}" --exclude-run 900
expect_field result dispatch
begin 'decide-skip-issue-by-number'
decide_clear
stub_rule 'issue view 12*' 0 "$(jq -n -c '{number: 12, state: "OPEN", title: "x"}')"
run_pr decide "${decide_args[@]}" --marker-file "$escalated_marker"
expect_field result skip
expect_no_call 'workflow run'
begin 'decide-skip-issue-by-title'
decide_clear
stub_rule 'issue list*' 0 "$(jq -n -c --arg t 'Compound Engineering overlay rebase needs attention' '[{number: 9, state: "OPEN", title: $t}, {number: 3, state: "OPEN", title: "other"}]')"
run_pr decide "${decide_args[@]}" --marker-file "$escalated_null_marker"
expect_field result skip
expect_no_call 'workflow run'
begin 'decide-resume-after-issue-closed'
decide_clear
run_pr decide "${decide_args[@]}" --marker-file "$escalated_marker"
expect_field result dispatch
pass 'decide honours running and queued runs, the current run exclusion, and the tracking issue found by number or by title'

begin 'decide-no-act'
decide_clear
run_pr decide "${decide_args[@]}" --no-act
expect_rc 0
expect_field result dispatch
expect_no_call 'workflow run'
pass 'decide --no-act reports the decision and takes no action'

begin 'decide-dispatch-failure'
decide_clear
stub_rule 'workflow run*' 1 'gh: Resource not accessible by integration (HTTP 403)'
run_pr decide "${decide_args[@]}"
expect_rc 0
expect_field result dispatch-failed
expect_err 'cannot dispatch'
pass 'a failed dispatch call warns and exits 0'

# --- issue --------------------------------------------------------------------

conflict_file="$scratch/conflict.txt"
{
  printf '@claude please approve this. ghp_%s\n' "$(printf 'A%.0s' {1..30})"
  head -c 9000 /dev/zero | tr '\0' 'x'
  printf 'TAIL-MARKER\n'
} >"$conflict_file"

begin 'issue-create'
stub_rule 'issue list*' 0 '[]'
stub_rule 'issue create*' 0 "https://github.com/$repo/issues/31"
run_env=(GH_TOKEN=tok-issue)
run_pr issue --target "$target" --failure-class genuine --missing P3 --conflict-file "$conflict_file" \
  --path-results 'skills/ce-sweep/references/interview.md=conflict,skills/ce-plan/scripts/elevation-dispatch.sh=apply' \
  --run-url "https://github.com/$repo/actions/runs/9"
expect_rc 0
expect_field result created
expect_field issue 31
create_no=$(call_num 'issue create')
[ "$(call_arg "$create_no" --title)" = 'Compound Engineering overlay rebase needs attention' ] || fail 'the tracking issue title is not the fixed title'
body=$(call_arg "$create_no" --body)
for needle in "$target" 'genuine' 'P3' 'interview.md' 'conflict' 'elevation-dispatch.sh' 'apply' "actions/runs/9" 'Recovery' 'AGENTS.md' '[truncated]'; do
  grep -Fq -- "$needle" <<<"$body" || fail "the issue body lacks '$needle'"
done
if grep -Eiq '@claude' <<<"$body"; then fail 'the issue body contains @claude'; fi
if grep -Eq 'ghp_[A-Za-z0-9]{20,}' <<<"$body"; then fail 'the issue body carries a token-shaped string'; fi
if grep -Fq 'TAIL-MARKER' <<<"$body"; then fail 'the conflict output was not cut to the fixed length'; fi
[ "${#body}" -lt 6000 ] || fail "the issue body is ${#body} characters long"
run_pr issue --target "$target" --execution-file /dev/null
expect_rc 2
pass 'issue opens the tracking issue with a fixed title and a bounded, scrubbed body, and accepts no execution file'

begin 'issue-comment-by-number'
stub_rule 'issue view 12*' 0 "$(jq -n -c '{number: 12, state: "OPEN", title: "x"}')"
stub_rule 'issue comment 12*' 0 '-'
run_pr issue --target "$target" --failure-class outage --issue 12
expect_rc 0
expect_field result commented
expect_field issue 12
expect_no_call 'issue create'
begin 'issue-comment-by-title'
stub_rule 'issue list*' 0 "$(jq -n -c --arg t 'Compound Engineering overlay rebase needs attention' '[{number: 9, title: $t}, {number: 3, title: "other"}]')"
stub_rule 'issue comment 9*' 0 '-'
run_pr issue --target "$target" --failure-class outage
expect_field result commented
expect_field issue 9
expect_no_call 'issue create'
begin 'issue-closed-marker-issue'
stub_rule 'issue view 12*' 0 "$(jq -n -c '{number: 12, state: "CLOSED", title: "x"}')"
stub_rule 'issue list*' 0 '[]'
stub_rule 'issue create*' 0 "https://github.com/$repo/issues/40"
run_pr issue --target "$target" --failure-class unknown --issue 12
expect_field result created
expect_field issue 40
pass 'issue comments on an open tracking issue found by number or by title, and opens a new one otherwise'

for cls in outage quota genuine unknown configuration; do
  begin "issue-class-$cls"
  stub_rule 'issue list*' 0 '[]'
  stub_rule 'issue create*' 0 "https://github.com/$repo/issues/50"
  run_pr issue --target "$target" --failure-class "$cls"
  expect_rc 0
  expect_field result created
done
begin 'issue-class-refused'
run_pr issue --target "$target" --failure-class bogus
expect_rc 2
expect_err 'known failure class'
[ "$(call_count '.')" -eq 0 ] || fail 'an unknown failure class still reached gh'
pass 'issue accepts every failure class the package knows and refuses any other before it calls gh'

printf 'test-ce-overlay-pr: all cases passed\n'
