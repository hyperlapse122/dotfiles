#!/usr/bin/env bash
set -euo pipefail

# The disposable bare origin is configured as a GitHub-shaped URL through a
# local `url.*.insteadOf` mapping, while a fake native `gh` records prompt
# settings and emits controlled GraphQL pages. No case uses a real remote or
# credential.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo_root/dot_local/share/chezmoi/command-sources/executable_git-prune-local-branches"
[ -f "$tool" ] || {
  printf 'git-prune-local-branches gates: missing %s\n' "$tool" >&2
  exit 1
}

real_git=$(command -v git)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/git-prune-local-branches.XXXXXX")
# Linked worktrees keep an admin dir inside the repo, so plain rm -rf of the
# scratch tree is enough: nothing is registered outside it.
trap 'rm -rf -- "$scratch"' EXIT

# Hermetic Git: no user/system config, no credential prompts, stable messages.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=prune-fixture GIT_AUTHOR_EMAIL=prune@example.invalid
export GIT_COMMITTER_NAME=prune-fixture GIT_COMMITTER_EMAIL=prune@example.invalid
export GIT_TERMINAL_PROMPT=0
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

case_name=
out=
rc=0
wrap=
tool_tmpdir=

fail() {
  printf 'git-prune-local-branches gates [%s]: %s\n' "$case_name" "$*" >&2
  [ -z "$out" ] || printf -- '--- helper output ---\n%s\n---------------------\n' "$out" >&2
  exit 1
}

wcommit() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$4"
}

seed() {
  local d=$1 w base
  w="$d/w"
  mkdir -p -- "$d"
  git init -q --bare -b main "$d/origin.git"
  git init -q -b main "$w"
  git -C "$w" remote add origin "$d/origin.git"

  wcommit "$w" base.txt base 'base'
  base=$(git -C "$w" rev-parse HEAD)

  git -C "$w" checkout -q -b merged-1 "$base"
  wcommit "$w" merged.txt merged 'merged-1 work'
  git -C "$w" checkout -q main
  git -C "$w" merge -q --no-ff -m 'merge merged-1' merged-1

  git -C "$w" checkout -q -b wt-1 "$base"
  wcommit "$w" wt.txt wt 'wt-1 work'
  git -C "$w" checkout -q main
  git -C "$w" merge -q --no-ff -m 'merge wt-1' wt-1

  # Squash-shaped: identical content on main, unrelated commit on the branch.
  git -C "$w" checkout -q -b squashed-1 "$base"
  wcommit "$w" squash.txt squashed 'squashed-1 work'
  git -C "$w" checkout -q main
  wcommit "$w" squash.txt squashed 'squash-merge squashed-1'

  git -C "$w" checkout -q -b wip-1 "$base"
  wcommit "$w" wip.txt wip 'wip-1 work'

  git -C "$w" checkout -q -b work "$base"
  wcommit "$w" work.txt work 'work in progress'

  git -C "$w" push -q origin main
  git -C "$w" push -q origin "$base:refs/heads/trunk"
  git -C "$w" fetch -q origin
  git -C "$w" remote set-head origin main
  git -C "$w" remote set-url origin https://github.com/acme/fixture.git
  git -C "$w" config url."$d/origin.git".insteadOf https://github.com/acme/fixture.git

  git -C "$w" worktree add -q "$d/wt" wt-1

  printf 'stashed\n' >>"$w/base.txt"
  git -C "$w" stash push -q -m 'fixture stash'

  git -C "$w" config branch.merged-1.remote .
  git -C "$w" config branch.merged-1.merge refs/heads/wip-1
}

snapshot() {
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" stash list --pretty=tformat:'%gd %H %gs'
  git -C "$1" worktree list --porcelain
}

log_wrapper() {
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1/argv.log"
printf 'terminal=%s\n' "\${GIT_TERMINAL_PROMPT:-}" >>"$1/env.log"
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
  : >"$1/argv.log"
  : >"$1/env.log"
}
interrupt_wrapper() {
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
saw_branch=0
saw_delete=0
for arg in "\$@"; do
  [ "\$arg" != branch ] || saw_branch=1
  [ "\$arg" != -d ] || saw_delete=1
done
if [ "\$saw_branch" -eq 1 ] && [ "\$saw_delete" -eq 1 ]; then
  : >"$1/ready"
  while [ ! -e "$1/release" ]; do sleep 0.05; done
  exit 99
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}


# PATH `git` that attaches the candidate to a brand-new worktree in the instant
# before the helper's final `git branch -d` reaches real Git.
attach_wrapper() {
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
saw_branch=0
saw_delete=0
for a in "\$@"; do
  [ "\$a" != branch ] || saw_branch=1
  [ "\$a" != -d ] || saw_delete=1
done
if [ "\$saw_branch" -eq 1 ] && [ "\$saw_delete" -eq 1 ] && [ ! -e "$1/fired" ]; then
  : >"$1/fired"
  "$real_git" -C "$2" worktree add -q "$4" "$3" >"$1/attach.log" 2>&1 || true
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}

make_gh_stub() {
  mkdir -p -- "$1"
  cat >"$1/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${GH_STUB_LOG:?}"
printf 'prompt=%s terminal=%s token=%s\n' "\${GH_PROMPT_DISABLED:-}" "\${GIT_TERMINAL_PROMPT:-}" "\${GH_TOKEN:+set}" >>"\${GH_STUB_ENV_LOG:?}"
request=\$*
for required in \
  'defaultBranchRef' 'target { oid }' 'states: MERGED' 'after: \$endCursor' \
  'pageInfo { hasNextPage endCursor }' 'id' 'number' 'state' 'mergedAt' \
  'baseRefName' 'baseRepository { nameWithOwner }' 'headRefName' \
  'headRefOid' 'headRepository { nameWithOwner }'; do
  case "\$request" in
    *"\$required"*) ;;
    *) printf 'gh fixture: query missing %s\n' "\$required" >&2; exit 1 ;;
  esac
done
case "\${GH_STUB_MODE:-ok}" in
  error) printf '%s\n' 'gh authentication failed' >&2; exit 1 ;;
  timeout)
    trap '' TERM
    while :; do sleep 1; done
    ;;
  missing) exit 127 ;;
esac
response=\$(cat -- "\${GH_STUB_RESPONSE:?}")
if [[ "\$response" == *DEFAULT_OID* ]]; then
  default_oid=\${GH_STUB_DEFAULT_OID:-}
  if [[ -z "\$default_oid" ]]; then
    default_oid=\$("$real_git" -C "\${GH_STUB_DEFAULT_REPO:?}" \
      rev-parse "refs/remotes/origin/\${GH_STUB_DEFAULT_BRANCH:-main}")
  fi
  response=\${response//DEFAULT_OID/\$default_oid}
fi
printf '%s\n' "\$response"
if [ -n "\${GH_STUB_MOVE_BRANCH:-}" ]; then
  "$real_git" -C "\${GH_STUB_REPO:?}" branch -f -- "\$GH_STUB_MOVE_BRANCH" "\$GH_STUB_MOVE_START"
fi
EOF
  chmod +x "$1/gh"
}

proof_default_branch=main
proof_default_json() {
  printf '"defaultBranchRef":{"name":"%s","target":{"oid":"DEFAULT_OID"}}' \
    "$proof_default_branch"
}

proof_page() {
  local file=$1 branch=$2 oid=$3 head_repo=${4:-acme/fixture}
  local base_repo=${5:-acme/fixture} base_ref=${6:-main}
  local default_ref
  default_ref=$(proof_default_json)
  cat >"$file" <<EOF
[{"data":{"repository":{${default_ref},"pullRequests":{"nodes":[{"id":"PR_$branch","number":1,"state":"MERGED","mergedAt":"2026-08-14T12:00:00Z","baseRefName":"$base_ref","baseRepository":{"nameWithOwner":"$base_repo"},"headRefName":"$branch","headRefOid":"$oid","headRepository":{"nameWithOwner":"$head_repo"}}],"pageInfo":{"hasNextPage":false,"endCursor":"cursor-1"}}}}}]
EOF
}

empty_proof_page() {
  local default_ref
  default_ref=$(proof_default_json)
  cat >"$1" <<EOF
[{"data":{"repository":{${default_ref},"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}]
EOF
}

partial_proof_page() {
  local default_ref
  default_ref=$(proof_default_json)
  cat >"$1" <<EOF
[{"data":{"repository":{${default_ref},"pullRequests":{"nodes":[{"id":"PR_partial","number":1,"state":"MERGED","mergedAt":"2026-08-14T12:00:00Z","baseRefName":"main","baseRepository":{"nameWithOwner":"acme/fixture"},"headRefName":"squashed-1","headRefOid":"0000000000000000000000000000000000000000","headRepository":{"nameWithOwner":"acme/fixture"}}],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}]
EOF
}

duplicate_proof_page() {
  local default_ref
  default_ref=$(proof_default_json)
  cat >"$1" <<EOF
[{"data":{"repository":{${default_ref},"pullRequests":{"nodes":[{"id":"PR_one","number":1,"state":"MERGED","mergedAt":"2026-08-14T12:00:00Z","baseRefName":"main","baseRepository":{"nameWithOwner":"acme/fixture"},"headRefName":"$2","headRefOid":"$3","headRepository":{"nameWithOwner":"acme/fixture"}},{"id":"PR_two","number":2,"state":"MERGED","mergedAt":"2026-08-14T12:00:01Z","baseRefName":"main","baseRepository":{"nameWithOwner":"acme/fixture"},"headRefName":"$2","headRefOid":"$3","headRepository":{"nameWithOwner":"acme/fixture"}}],"pageInfo":{"hasNextPage":false,"endCursor":"cursor-1"}}}}}]
EOF
}
paginated_proof() {
  local file=$1 branch=$2 oid=$3 default_ref
  default_ref=$(proof_default_json)
  cat >"$file" <<EOF
[
  {"data":{"repository":{${default_ref},"pullRequests":{"nodes":[{"id":"PR_remote","number":99,"state":"MERGED","mergedAt":"2026-08-14T12:00:00Z","baseRefName":"main","baseRepository":{"nameWithOwner":"acme/fixture"},"headRefName":"remote-only","headRefOid":"1111111111111111111111111111111111111111","headRepository":{"nameWithOwner":"acme/fixture"}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-2"}}}}},
  {"data":{"repository":{${default_ref},"pullRequests":{"nodes":[{"id":"PR_$branch","number":1,"state":"MERGED","mergedAt":"2026-08-14T12:00:01Z","baseRefName":"main","baseRepository":{"nameWithOwner":"acme/fixture"},"headRefName":"$branch","headRefOid":"$oid","headRepository":{"nameWithOwner":"acme/fixture"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
]
EOF
}

git_timeout_wrapper() {
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" $2 "*)
    trap '' TERM
    while :; do sleep 1; done
    ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}

run_tool() {
  local dir=$1 path=$gh_stub
  shift
  [ -z "$wrap" ] || path="$wrap:$path"
  rc=0
  out=$(cd -- "$dir" &&
    PATH="$path:$PATH" \
    GH_STUB_RESPONSE="$gh_response" GH_STUB_MODE="$gh_mode" \
    GH_STUB_LOG="$gh_stub/argv.log" GH_STUB_ENV_LOG="$gh_stub/env.log" \
    GH_STUB_DEFAULT_REPO="$dir" GH_STUB_DEFAULT_BRANCH="$proof_default_branch" \
    GH_STUB_REPO="$gh_move_repo" GH_STUB_MOVE_BRANCH="$gh_move_branch" \
    GH_STUB_MOVE_START="$gh_move_start" \
    TMPDIR="${tool_tmpdir:-${TMPDIR:-/tmp}}" \
    GIT_TERMINAL_PROMPT='' \
    GIT_PRUNE_LOCAL_BRANCHES_TIMEOUT_SECONDS="$tool_timeout" \
    GH_TOKEN=fixture-token \
    bash "$tool" "$@" 2>&1) || rc=$?
}

expect_rc() { [ "$rc" -eq "$1" ] || fail "exit $rc, expected $1"; }
expect_out() { grep -qF -- "$1" <<<"$out" || fail "output missing: $1"; }
expect_no_out() { ! grep -qF -- "$1" <<<"$out" || fail "output must not contain: $1"; }
expect_branch() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" || fail "branch gone: $2"
}
expect_no_branch() {
  ! git -C "$1" show-ref --verify --quiet "refs/heads/$2" || fail "branch survived: $2"
}
expect_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }

gh_stub=$scratch/gh-stub
gh_response=$scratch/github-proof.json
make_gh_stub "$gh_stub"
reset_gh() {
  gh_mode=ok
  tool_timeout=15
  tool_tmpdir=
  gh_move_repo=
  gh_move_branch=
  gh_move_start=
  proof_default_branch=main
  empty_proof_page "$gh_response"
  : >"$gh_stub/argv.log"
  : >"$gh_stub/env.log"
}
reset_gh

case_name='report is read-only'
c=$scratch/report
seed "$c"
before=$(snapshot "$c/w")
wrap=$scratch/wrap-report
log_wrapper "$wrap"
reset_gh
run_tool "$c/w"
wrap=
expect_rc 0
expect_out 'mode=report'
expect_out 'candidate-unverified: merged-1 '
expect_out 'protected: wip-1 reason=unmerged'
expect_out 'protected: squashed-1 reason=unmerged'
expect_out 'protected: wt-1 reason=worktree'
expect_out 'protected: work reason=current'
expect_out 'protected: main reason=default'
expect_out 'stash-count: 1'
expect_out 'note: report mode queried no remote and changed no ref, worktree, or stash'
! grep -q 'ls-remote' "$scratch/wrap-report/argv.log" || fail 'report queried the remote'
! grep -q '^fetch' "$scratch/wrap-report/argv.log" || fail 'report fetched'
[ ! -s "$gh_stub/argv.log" ] || fail 'report invoked gh'
expect_eq "$(snapshot "$c/w")" "$before" 'report changed repository state'

mv -- "$c/origin.git" "$c/origin.moved"
run_tool "$scratch" "$c/w"
expect_rc 0
expect_out "mode=report repo=$c/w"
expect_out 'candidate-unverified: merged-1 '
mv -- "$c/origin.moved" "$c/origin.git"

run_tool "$c/w" --default-branch trunk
expect_rc 0
expect_out 'default-unverified: trunk source=override'
expect_out 'protected: merged-1 reason=unmerged'
expect_eq "$(snapshot "$c/w")" "$before" 'override report changed repository state'

case_name='report infers no default'
c=$scratch/report-nohint
seed "$c"
git -C "$c/w" symbolic-ref --delete refs/remotes/origin/HEAD
run_tool "$c/w"
expect_rc 0
expect_out 'default-unverified: (none) source=none tip=(none)'
expect_out 'protected: merged-1 reason=no-default-ref'
expect_no_out 'candidate-unverified:'

case_name='apply deletes exact-tip squash proof only'
c=$scratch/exact-squash
seed "$c"
git -C "$c/w" config branch.squashed-1.remote .
git -C "$c/w" config branch.squashed-1.merge refs/heads/wip-1
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
stash_before=$(git -C "$c/w" stash list --pretty=tformat:'%gd %H %gs')
before=$(snapshot "$c/w")
wrap=$scratch/wrap-exact
log_wrapper "$wrap"
run_tool "$c/w" --apply
wrap=
expect_rc 0
expect_out 'candidate-github-confirmed: squashed-1 '
expect_out 'deleted: squashed-1 '
expect_out 'kept: merged-1 reason=github-unproven'
expect_out 'kept: wip-1 reason=github-unproven'
expect_out 'protected: wt-1 reason=worktree'
expect_out 'protected: work reason=current'
expect_out 'protected: main reason=default'
expect_no_branch "$c/w" squashed-1
expect_branch "$c/w" merged-1
expect_branch "$c/w" wip-1
expect_branch "$c/w" wt-1
expect_eq "$(git -C "$c/w" stash list --pretty=tformat:'%gd %H %gs')" "$stash_before" 'stash changed'
expect_eq "$(comm -23 <(sort <<<"$before") <(sort <<<"$(snapshot "$c/w")"))" \
  "refs/heads/squashed-1 $squash_sha" 'apply removed state beyond exact proof'
log=$scratch/wrap-exact/argv.log
grep -q 'ls-remote --symref origin HEAD' "$log" || fail 'apply never queried the live default'
grep -q '^fetch' "$log" || fail 'apply never refreshed the default'
expect_eq "$(grep -c 'ls-remote --symref origin HEAD' "$log")" 1 \
  'remote proof was not completed before deletion'
grep -q 'api --hostname github.com graphql --paginate --slurp' "$gh_stub/argv.log" ||
  fail 'apply did not request paginated native gh proof'
grep -q 'prompt=1 terminal=0 token=' "$gh_stub/env.log" ||
  fail 'apply allowed a native gh prompt'
grep -q '^terminal=0$' "$scratch/wrap-exact/env.log" ||
  fail 'apply allowed Git credential prompting'
! grep -qE '(^| )branch -D( |$)' "$log" || fail 'apply used force deletion'
! grep -q 'update-ref' "$log" || fail 'apply used update-ref'
! grep -qE '(^| )push( |$)' "$log" || fail 'apply pushed to the remote'
! grep -qE 'stash (drop|pop|clear|apply)' "$log" || fail 'apply touched the stash'
! grep -qE 'worktree (add|remove|prune)' "$log" || fail 'apply changed worktrees'
case_name='paginated GitHub inventory proves an exact tip'
c=$scratch/paginated
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
paginated_proof "$gh_response" squashed-1 "$squash_sha"
run_tool "$c/w" --apply
expect_rc 0
expect_out 'candidate-github-confirmed: squashed-1 '
expect_out 'deleted: squashed-1 '
expect_no_branch "$c/w" squashed-1
case_name='interrupt during deletion refuses safely'
c=$scratch/signal
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
signal_wrap=$scratch/wrap-signal
interrupt_wrapper "$signal_wrap"
signal_out=$scratch/signal.out
PATH="$signal_wrap:$gh_stub:$PATH" \
GH_STUB_RESPONSE="$gh_response" GH_STUB_MODE="$gh_mode" \
GH_STUB_LOG="$gh_stub/argv.log" GH_STUB_ENV_LOG="$gh_stub/env.log" \
GH_STUB_DEFAULT_REPO="$c/w" GH_STUB_DEFAULT_BRANCH="$proof_default_branch" \
GH_STUB_REPO="$gh_move_repo" GH_STUB_MOVE_BRANCH="$gh_move_branch" \
GH_STUB_MOVE_START="$gh_move_start" \
GIT_TERMINAL_PROMPT='' \
GIT_PRUNE_LOCAL_BRANCHES_TIMEOUT_SECONDS="$tool_timeout" \
GH_TOKEN=fixture-token \
bash "$tool" "$c/w" --apply >"$signal_out" 2>&1 &
signal_pid=$!
for _ in $(seq 1 100); do
  [ -e "$signal_wrap/ready" ] && break
  sleep 0.05
done
if [ ! -e "$signal_wrap/ready" ]; then
  kill -TERM "$signal_pid" 2>/dev/null || true
  : >"$signal_wrap/release"
  wait "$signal_pid" 2>/dev/null || true
  fail 'signal fixture did not reach deletion'
fi
kill -TERM "$signal_pid"
: >"$signal_wrap/release"
signal_rc=0
wait "$signal_pid" || signal_rc=$?
out=$(<"$signal_out")
expect_eq "$signal_rc" 143 'termination exit status'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1


case_name='advanced and reused heads are unproven'
c=$scratch/advanced
seed "$c"
git -C "$c/w" branch advanced-1 main
advanced_sha=$(git -C "$c/w" rev-parse advanced-1)
git -C "$c/w" branch -f advanced-1 wip-1
reset_gh
proof_page "$gh_response" advanced-1 "$advanced_sha"
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: advanced-1 reason=github-head-oid-mismatch'
expect_no_out 'deleted:'
expect_branch "$c/w" advanced-1
c=$scratch/fork
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha" fork/fixture
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: squashed-1 reason=github-head-repository-mismatch'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='wrong base cannot prove a local branch'
c=$scratch/base-mismatch
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha" acme/fixture acme/other main
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: squashed-1 reason=github-unproven'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='wrong default base ref cannot prove a local branch'
c=$scratch/base-ref-mismatch
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha" acme/fixture acme/fixture trunk
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: squashed-1 reason=github-unproven'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='missing pull request retains every branch'
c=$scratch/no-pr
seed "$c"
reset_gh
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: squashed-1 reason=github-unproven'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

proof_refusal() {
  case_name=$1
  c=$scratch/$case_name
  seed "$c"
  reset_gh
  squash_sha=$(git -C "$c/w" rev-parse squashed-1)
  proof_page "$gh_response" squashed-1 "$squash_sha"
  gh_mode=$3
  run_tool "$c/w" --apply
  expect_rc 1
  expect_out "$2"
  expect_no_out 'deleted:'
  expect_branch "$c/w" squashed-1
}

case_name='malformed GitHub inventory refuses before deletion'
c=$scratch/malformed
seed "$c"
reset_gh
printf '%s\n' '{}' >"$gh_response"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: GitHub merged-PR proof is malformed, partial, or duplicated'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='partial GitHub inventory refuses before deletion'
c=$scratch/partial
seed "$c"
reset_gh
partial_proof_page "$gh_response"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: GitHub merged-PR proof is malformed, partial, or duplicated'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='ambiguous GitHub proof refuses before deletion'
c=$scratch/ambiguous-proof
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
duplicate_proof_page "$gh_response" squashed-1 "$squash_sha"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'kept: squashed-1 reason=github-ambiguous'
expect_out 'refused: GitHub merged-PR proof is ambiguous'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

proof_refusal 'gh-auth' 'refused: GitHub merged-PR proof is unavailable' error
proof_refusal 'gh-missing' 'refused: GitHub merged-PR proof is unavailable' missing

case_name='GitHub proof timeout refuses before deletion'
c=$scratch/gh-timeout
seed "$c"
reset_gh
gh_mode=timeout
tool_timeout=1
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: timed out acquiring the complete GitHub merged-PR proof'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='live default query timeout refuses before deletion'
c=$scratch/ls-remote-timeout
seed "$c"
reset_gh
wrap=$scratch/wrap-ls-remote-timeout
git_timeout_wrapper "$wrap" ls-remote
tool_timeout=0
run_tool "$c/w" --apply
wrap=
expect_rc 1
expect_out "refused: timed out querying origin's live HEAD"
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='default fetch timeout refuses before deletion'
c=$scratch/fetch-timeout
seed "$c"
reset_gh
wrap=$scratch/wrap-fetch-timeout
git_timeout_wrapper "$wrap" fetch
tool_timeout=1
run_tool "$c/w" --apply
wrap=
expect_rc 1
expect_out 'refused: timed out fetching refs/heads/main from origin'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='candidate changes after complete proof'
c=$scratch/candidate-race
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
gh_move_repo=$c/w
gh_move_branch=squashed-1
gh_move_start=wip-1
run_tool "$c/w" --apply
expect_rc 0
expect_out 'kept: squashed-1 reason=candidate-oid-changed'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1
expect_eq "$(git -C "$c/w" rev-parse squashed-1)" "$(git -C "$c/w" rev-parse wip-1)" \
  'candidate did not move to the raced tip'

case_name='deletion-time worktree attach remains a Git backstop'
c=$scratch/attach
seed "$c"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
wrap=$scratch/wrap-attach
attach_wrapper "$wrap" "$c/w" squashed-1 "$c/wt2"
run_tool "$c/w" --apply
wrap=
expect_rc 1
expect_out 'kept: squashed-1 reason=git-refused'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1
[ -f "$c/wt2/squash.txt" ] || fail 'the racing worktree was damaged'

case_name='unsafe branch name is protected'
c=$scratch/unsafe-name
seed "$c"
git -C "$c/w" branch -- a=b squashed-1
reset_gh
unsafe_sha=$(git -C "$c/w" rev-parse a=b)
proof_page "$gh_response" a=b "$unsafe_sha"
run_tool "$c/w" --apply
expect_rc 0
expect_out 'protected: a=b reason=unsafe-name'
expect_no_out 'deleted:'
expect_branch "$c/w" a=b

case_name='ambiguous local branch is protected'
c=$scratch/ambiguous-local
seed "$c"
git -C "$c/w" tag squashed-1 "$(git -C "$c/w" rev-parse main)"
reset_gh
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
run_tool "$c/w" --apply
expect_rc 0
expect_out 'protected: squashed-1 reason=ambiguous'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

preflight_refusal() {
  case_name=$1
  c=$scratch/$case_name
  seed "$c"
  reset_gh
  "$3" "$c"
  run_tool "$c/w" --apply
  expect_rc 1
  expect_out "$2"
  expect_no_out 'deleted:'
  [ ! -s "$gh_stub/argv.log" ] || fail 'preflight failure invoked gh'
  expect_branch "$c/w" squashed-1
}

setup_detached() { git -C "$1/w" checkout -q --detach HEAD; }
setup_merge_op() { git -C "$1/w" merge --no-commit --no-ff -q wip-1 >/dev/null 2>&1 || true; }
setup_worktree_op() {
  git -C "$1/wt" merge --no-commit --no-ff -q wip-1 >/dev/null 2>&1 || true
}
preflight_refusal detached 'refused: HEAD is detached' setup_detached
preflight_refusal active-merge 'refused: merge in progress' setup_merge_op
preflight_refusal active-worktree-merge 'refused: merge in progress' setup_worktree_op

case_name='non-GitHub origin refuses without gh'
c=$scratch/non-github-origin
seed "$c"
reset_gh
git -C "$c/w" remote set-url origin "$c/origin.git"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: origin is not a supported GitHub.com repository URL'
expect_no_out 'deleted:'
[ ! -s "$gh_stub/argv.log" ] || fail 'invalid origin invoked gh'
expect_branch "$c/w" squashed-1
for scheme in http git; do
  case_name="$scheme GitHub origin refuses plaintext transport"
  c=$scratch/$scheme-github-origin
  seed "$c"
  reset_gh
  git -C "$c/w" remote set-url origin "$scheme://github.com/acme/fixture.git"
  run_tool "$c/w" --apply
  expect_rc 1
  expect_out 'refused: origin is not a supported GitHub.com repository URL'
  expect_no_out 'deleted:'
  [ ! -s "$gh_stub/argv.log" ] || fail 'plaintext origin invoked gh'
  expect_branch "$c/w" squashed-1
done
case_name='unreachable GitHub origin refuses without gh'
c=$scratch/unreachable-github-origin
seed "$c"
reset_gh
git -C "$c/w" config --unset-all url."$c/origin.git".insteadOf
git -C "$c/w" config url."$c/gone.git".insteadOf https://github.com/acme/fixture.git
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: origin could not be queried'
expect_no_out 'deleted:'
[ ! -s "$gh_stub/argv.log" ] || fail 'unreachable origin invoked gh'
expect_branch "$c/w" squashed-1


case_name='live default overrides stale cached origin HEAD'
c=$scratch/repoint
seed "$c"
reset_gh
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/trunk
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_default_branch=trunk
proof_page "$gh_response" squashed-1 "$squash_sha" acme/fixture acme/fixture trunk
run_tool "$c/w" --apply
expect_rc 0
expect_out 'default: trunk sha='
expect_no_out 'default: main '
expect_no_branch "$c/w" squashed-1
expect_eq "$(git -C "$c/w" rev-parse refs/remotes/origin/trunk)" \
  "$(git -C "$c/origin.git" rev-parse refs/heads/trunk)" 'trunk was not fetched fresh'

case_name='GitHub default mismatch refuses before deletion'
c=$scratch/github-default-mismatch
seed "$c"
reset_gh
proof_default_branch=trunk
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: GitHub proof default trunk'
expect_no_out 'deleted:'
expect_branch "$c/w" squashed-1

case_name='default override remains live-validated'
c=$scratch/override
seed "$c"
reset_gh
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/does-not-exist
squash_sha=$(git -C "$c/w" rev-parse squashed-1)
proof_page "$gh_response" squashed-1 "$squash_sha"
run_tool "$c/w" --apply --default-branch main
expect_rc 0
expect_out 'source=override-validated'
expect_no_branch "$c/w" squashed-1
case_name='missing live default refuses before GitHub proof'
c=$scratch/no-default
seed "$c"
reset_gh
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/does-not-exist
run_tool "$c/w" --apply
expect_rc 1
expect_out "refused: origin's HEAD names no branch"
expect_no_out 'deleted:'
[ ! -s "$gh_stub/argv.log" ] || fail 'missing default invoked gh'
expect_branch "$c/w" squashed-1

case_name='healthy live default rejects an override conflict'
c=$scratch/override-conflict
seed "$c"
reset_gh
run_tool "$c/w" --apply --default-branch trunk
expect_rc 1
expect_out 'refused: --default-branch trunk conflicts with origin'
expect_no_out 'deleted:'
[ ! -s "$gh_stub/argv.log" ] || fail 'override conflict invoked gh'
expect_branch "$c/w" squashed-1


case_name='proof workspace failure releases the helper lock'
c=$scratch/mktemp-failure
seed "$c"
reset_gh
lockdir="$(git -C "$c/w" rev-parse --absolute-git-dir)/git-prune-local-branches.lock"
tool_tmpdir="$c/missing-tmp"
run_tool "$c/w" --apply
tool_tmpdir=
expect_rc 1
expect_out 'refused: could not create a private proof workspace'
expect_no_out 'deleted:'
[ ! -e "$lockdir" ] || fail 'mktemp failure left the helper lock behind'
run_tool "$c/w" --apply
expect_rc 0
expect_out 'mode=apply'
expect_no_out 'another git-prune-local-branches instance holds'
expect_branch "$c/w" squashed-1

case_name='helper lock prevents proof and deletion'
c=$scratch/lock
seed "$c"
reset_gh
lockdir="$(git -C "$c/w" rev-parse --absolute-git-dir)/git-prune-local-branches.lock"
mkdir -p -- "$lockdir"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: another git-prune-local-branches instance holds'
expect_no_out 'deleted:'
[ ! -s "$gh_stub/argv.log" ] || fail 'lock failure invoked gh'
expect_branch "$c/w" squashed-1
rmdir -- "$lockdir"

case_name=
out=
printf '%s\n' 'git-prune-local-branches gates passed'
