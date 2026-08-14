#!/usr/bin/env bash
set -euo pipefail

# Proves dot_local/bin/executable_git-prune-local-branches against disposable
# Git fixtures only: a bare `origin`, a clone with merged / unmerged /
# squash-shaped / worktree-attached / oddly-named branches, a stale
# remote-tracking state, a secondary worktree, an in-progress operation and a
# stash. Every case builds its own throwaway repository under a scratch dir; the
# helper is never pointed at this checkout or any real repository, and no case
# touches a real remote.
#
# The cases cover: report mode changing nothing and querying no remote, --apply
# deleting only what the freshly fetched default tip proves merged (including
# against a mismatched configured upstream), protection of unmerged,
# squash-merged, current, default and worktree-attached branches, stash
# preservation, unusual-but-valid branch names, refusal on detached / ambiguous
# / in-progress / no-live-default / unreachable-origin repositories, override
# acceptance and rejection, stale origin/HEAD versus a moved, rewritten or
# repointed live default, a candidate that changes before the final recheck, and
# Git's own deletion-time worktree protection when an unrelated client attaches
# the candidate in the last instant.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo_root/dot_local/bin/executable_git-prune-local-branches"
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

fail() {
  printf 'git-prune-local-branches gates [%s]: %s\n' "$case_name" "$*" >&2
  [ -z "$out" ] || printf -- '--- helper output ---\n%s\n---------------------\n' "$out" >&2
  exit 1
}

wcommit() { # wcommit <repo> <file> <content> <message>
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$4"
}

# A repository shaped like a real working clone:
#   origin.git   bare remote, HEAD -> main, plus a `trunk` branch at the base
#   w            clone: current branch `work`, a real merged branch, a squash-
#                shaped branch, an unmerged branch, a worktree-attached branch,
#                a stash, a mismatched upstream on the candidate, and a cached
#                origin/HEAD that later cases deliberately make stale
#   wt           secondary worktree holding `wt-1`
seed() { # seed <dir>
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

  # `work` is the current branch and does NOT contain merged-1, so an ordinary
  # `git branch -d` would judge the candidate against the wrong tip.
  git -C "$w" checkout -q -b work "$base"
  wcommit "$w" work.txt work 'work in progress'

  git -C "$w" push -q origin main
  git -C "$w" push -q origin "$base:refs/heads/trunk"
  git -C "$w" fetch -q origin
  git -C "$w" remote set-head origin main

  git -C "$w" worktree add -q "$d/wt" wt-1

  printf 'stashed\n' >>"$w/base.txt"
  git -C "$w" stash push -q -m 'fixture stash'

  # A configured upstream that disagrees with the default branch: wip-1 does not
  # contain merged-1, so only the helper's own upstream override can make Git
  # judge the candidate against the freshly fetched default tip.
  git -C "$w" config branch.merged-1.remote .
  git -C "$w" config branch.merged-1.merge refs/heads/wip-1
}

# A second clone used to move origin's default branch behind the fixture's back.
pusher() { # pusher <dir>
  [ -d "$1/pusher" ] || git clone -q "$1/origin.git" "$1/pusher"
  printf '%s' "$1/pusher"
}

snapshot() { # snapshot <repo> -- every ref, stash entry and worktree binding
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" stash list --pretty=tformat:'%gd %H %gs'
  git -C "$1" worktree list --porcelain
}

# Transparent PATH `git` that records every invocation the helper makes.
log_wrapper() { # log_wrapper <dir>
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1/argv.log"
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
  : >"$1/argv.log"
}

# PATH `git` that attaches the candidate to a brand-new worktree in the instant
# before the helper's final `git branch -d` reaches real Git.
attach_wrapper() { # attach_wrapper <dir> <repo> <branch> <worktree-path>
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

# PATH `git` that moves the candidate onto an unmerged tip during the helper's
# SECOND ls-remote, i.e. the pre-deletion recheck.
move_candidate_wrapper() { # move_candidate_wrapper <dir> <repo> <branch> <new-start>
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" ls-remote "*)
    n=\$(cat "$1/calls" 2>/dev/null || printf 0)
    n=\$((n + 1))
    printf '%s' "\$n" >"$1/calls"
    if [ "\$n" -eq 2 ]; then
      "$real_git" -C "$2" branch -f -- "$3" "$4" >"$1/move.log" 2>&1 || true
    fi
    ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}

# PATH `git` that makes origin unreachable in the instant before the first
# `git branch -d`, so the run loses the remote after one deletion.
break_remote_wrapper() { # break_remote_wrapper <dir> <origin path>
  mkdir -p -- "$1"
  cat >"$1/git" <<EOF
#!/usr/bin/env bash
saw_branch=0
saw_delete=0
for a in "\$@"; do
  [ "\$a" != branch ] || saw_branch=1
  [ "\$a" != -d ] || saw_delete=1
done
if [ "\$saw_branch" -eq 1 ] && [ "\$saw_delete" -eq 1 ] && [ -d "$2" ]; then
  mv -- "$2" "$2.gone"
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$1/git"
}

run_tool() { # run_tool <workdir> [args...]
  local dir=$1
  shift
  rc=0
  if [ -n "$wrap" ]; then
    out=$(cd -- "$dir" && PATH="$wrap:$PATH" bash "$tool" "$@" 2>&1) || rc=$?
  else
    out=$(cd -- "$dir" && bash "$tool" "$@" 2>&1) || rc=$?
  fi
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

heads() { git -C "$1" for-each-ref --format='%(refname:strip=2)' refs/heads/ | sort; }

case_name='report is read-only'
c=$scratch/report
seed "$c"
before=$(snapshot "$c/w")
wrap=$scratch/wrap-report
log_wrapper "$wrap"
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
expect_eq "$(snapshot "$c/w")" "$before" 'report changed repository state'

# The same report must work with origin unreachable and from another directory
# with the repository given as an argument, which only holds if it never talks
# to the remote at all.
mv -- "$c/origin.git" "$c/origin.moved"
run_tool "$scratch" "$c/w"
expect_rc 0
expect_out "mode=report repo=$c/w"
expect_out 'candidate-unverified: merged-1 '
mv -- "$c/origin.moved" "$c/origin.git"

# An override reclassifies the report too, still without contacting origin.
run_tool "$c/w" --default-branch trunk
expect_rc 0
expect_out 'default-unverified: trunk source=override'
expect_out 'protected: merged-1 reason=unmerged'
expect_eq "$(snapshot "$c/w")" "$before" 'override report changed repository state'

# The helper must never fall back to a main/master guess.
case_name='report infers no default'
c=$scratch/report-nohint
seed "$c"
git -C "$c/w" symbolic-ref --delete refs/remotes/origin/HEAD
run_tool "$c/w"
expect_rc 0
expect_out 'default-unverified: (none) source=none tip=(none)'
expect_out 'protected: merged-1 reason=no-default-ref'
expect_no_out 'candidate-unverified:'

# --apply must beat both the feature checkout and the mismatched configured
# upstream when it judges the candidate against the fetched default tip.
case_name='apply deletes merged candidate'
c=$scratch/apply
seed "$c"
stash_before=$(git -C "$c/w" stash list --pretty=tformat:'%gd %H %gs')
# Precondition: ordinary deletion refuses here, so a pass below is the helper's
# upstream override at work, not Git's default predicate.
if git -C "$c/w" branch -d -- merged-1 >/dev/null 2>&1; then
  fail 'fixture invalid: plain git branch -d already deletes the candidate'
fi
wrap=$scratch/wrap-apply
log_wrapper "$wrap"
merged_sha=$(git -C "$c/w" rev-parse merged-1)
before=$(snapshot "$c/w")
run_tool "$c/w" --apply
wrap=
expect_rc 0
expect_out 'source=live-symref'
expect_out 'deleted: merged-1 '
expect_no_branch "$c/w" merged-1
expect_branch "$c/w" wip-1
expect_branch "$c/w" squashed-1
expect_branch "$c/w" wt-1
expect_branch "$c/w" work
expect_branch "$c/w" main
expect_out 'protected: wt-1 reason=worktree'
expect_out 'protected: squashed-1 reason=unmerged'
expect_eq "$(git -C "$c/w" stash list --pretty=tformat:'%gd %H %gs')" "$stash_before" 'stash changed'
expect_out 'stash-count: 1'
[ -f "$c/wt/wt.txt" ] || fail 'secondary worktree was damaged'
expect_eq "$(git -C "$c/wt" symbolic-ref --short HEAD)" 'wt-1' 'secondary worktree head moved'

log=$scratch/wrap-apply/argv.log
grep -q 'ls-remote --symref origin HEAD' "$log" || fail 'apply never ran the live symref query'
grep -q '^fetch' "$log" || fail 'apply never fetched the default ref'
! grep -qE '(^| )branch -D( |$)' "$log" || fail 'apply used force deletion'
! grep -q 'update-ref' "$log" || fail 'apply used update-ref'
! grep -qE '(^| )push( |$)' "$log" || fail 'apply pushed to the remote'
! grep -qE '(^| )stash (drop|pop|clear|apply)' "$log" || fail 'apply touched the stash'
! grep -qE 'worktree (add|remove|prune)' "$log" || fail 'apply changed worktrees'
after=$(snapshot "$c/w")
expect_eq "$(comm -23 <(sort <<<"$before") <(sort <<<"$after"))" \
  "refs/heads/merged-1 $merged_sha" 'apply removed state beyond the candidate ref'
expect_eq "$(comm -13 <(sort <<<"$before") <(sort <<<"$after"))" '' 'apply added state'
expect_eq "$(grep -c 'ls-remote --symref origin HEAD' "$log")" 2 \
  'one live symref query per pass plus one per candidate recheck'

# A name that cannot be interpolated into a config key must be protected,
# never deleted through an unsafe key.
case_name='unusual branch names'
c=$scratch/names
seed "$c"
# Refnames cannot contain spaces, so the evaluation probes use redirection-only
# substitutions: if any of these names reached a shell or an eval, the files
# `pwned` / `pwned2` would appear.
odd=('feat/$(>pwned)' 'bt`>pwned2`' 'x|y' "q'quote" 'weird.merge' 'br#hash' 'a=b')
for n in "${odd[@]}"; do
  git -C "$c/w" branch -- "$n" main 2>/dev/null ||
    fail "fixture invalid: could not create branch $n"
done
run_tool "$c/w" --apply
expect_rc 0
expect_out 'protected: a=b reason=unsafe-name'
expect_out 'deleted: feat/$(>pwned) '
expect_out 'deleted: bt`>pwned2` '
expect_out 'deleted: weird.merge '
expect_out "deleted: q'quote "
expect_out 'deleted: x|y '
expect_out 'deleted: br#hash '
for probe in "$c/w/pwned" "$c/w/pwned2" "$scratch/pwned" "$scratch/pwned2"; do
  [ ! -e "$probe" ] || fail "branch name was evaluated by a shell: $probe"
done
expect_eq "$(heads "$c/w")" "$(printf '%s\n' 'a=b' main squashed-1 wip-1 work wt-1 | sort)" \
  'surviving branch set'

refusal_case() { # refusal_case <name> <apply fragment> <setup fn> [report fragment]
  case_name=$1
  local want=$2 setup=$3 report_want=${4:-}
  c=$scratch/refuse-$(printf '%s' "$case_name" | tr -c 'a-z0-9' '-')
  seed "$c"
  "$setup" "$c"
  run_tool "$c/w" --apply
  expect_rc 1
  expect_out "$want"
  expect_branch "$c/w" merged-1
  expect_no_out 'deleted:'
  run_tool "$c/w"
  expect_rc 0
  expect_out 'mode=report'
  [ -z "$report_want" ] || expect_out "$report_want"
  expect_branch "$c/w" merged-1
}

setup_detached() { git -C "$1/w" checkout -q --detach HEAD; }
setup_ambiguous() { git -C "$1/w" tag work "$(git -C "$1/w" rev-parse main)"; }
setup_merge_op() { git -C "$1/w" merge --no-commit --no-ff -q wip-1 >/dev/null 2>&1 || true; }
setup_bisect() { git -C "$1/w" bisect start >/dev/null 2>&1; }
setup_worktree_op() {
  git -C "$1/wt" merge --no-commit --no-ff -q wip-1 >/dev/null 2>&1 || true
}
setup_cherry_pick() {
  local w=$1/w
  git -C "$w" checkout -q -b cp-source main
  wcommit "$w" base.txt cherry-source 'cherry-pick source'
  git -C "$w" checkout -q work
  wcommit "$w" base.txt cherry-target 'conflicting local change'
  git -C "$w" cherry-pick cp-source >/dev/null 2>&1 || true
}
setup_no_default() {
  git -C "$1/origin.git" symbolic-ref HEAD refs/heads/does-not-exist
}
setup_unreachable() { git -C "$1/w" remote set-url origin "$1/gone.git"; }

refusal_case 'detached head' 'refused: HEAD is detached' setup_detached 'head: (detached)'
refusal_case 'ambiguous head' 'refused: the checked-out branch name is ambiguous' setup_ambiguous
refusal_case 'merge in progress' 'refused: merge in progress' setup_merge_op 'state: merge'
refusal_case 'bisect in progress' 'refused: bisect in progress' setup_bisect 'state: bisect'
refusal_case 'worktree operation' 'refused: merge in progress' setup_worktree_op 'state: merge'
refusal_case 'cherry-pick in progress' 'refused: cherry-pick in progress' setup_cherry_pick 'state: cherry-pick'
refusal_case 'no live default' "refused: origin's HEAD names no branch" setup_no_default
refusal_case 'unreachable origin' 'refused: origin could not be queried' setup_unreachable

# An override substitutes only for a name the remote cannot state, and is
# validated against the remote before use.
case_name='override accepted when live HEAD names nothing'
c=$scratch/override-ok
seed "$c"
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/does-not-exist
run_tool "$c/w" --apply --default-branch main
expect_rc 0
expect_out 'source=override-validated'
expect_out 'deleted: merged-1 '
expect_branch "$c/w" wip-1
expect_branch "$c/w" wt-1
expect_out 'protected: wt-1 reason=worktree'

case_name='override rejected against a healthy live HEAD'
c=$scratch/override-conflict
seed "$c"
run_tool "$c/w" --apply --default-branch trunk
expect_rc 1
expect_out 'refused: --default-branch trunk conflicts with origin'
expect_branch "$c/w" merged-1
expect_no_out 'deleted:'

case_name='override must exist on the remote'
c=$scratch/override-ghost
seed "$c"
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/does-not-exist
run_tool "$c/w" --apply --default-branch ghost
expect_rc 1
expect_out 'refused: origin does not advertise exactly one refs/heads/ghost'
expect_branch "$c/w" merged-1

# A stale cached origin/HEAD and stale tracking refs never authorize a
# deletion: the live symref repoint, a moved tip and a rewritten tip decide.
case_name='live symref repoint beats cached origin/HEAD'
c=$scratch/repoint
seed "$c"
expect_eq "$(git -C "$c/w" symbolic-ref refs/remotes/origin/HEAD)" \
  'refs/remotes/origin/main' 'cached origin/HEAD precondition'
git -C "$c/origin.git" symbolic-ref HEAD refs/heads/trunk
run_tool "$c/w" --apply
expect_rc 0
expect_out 'default: trunk sha='
expect_no_out 'default: main '
expect_out 'protected: merged-1 reason=unmerged'
expect_no_out 'deleted:'
expect_branch "$c/w" merged-1
expect_eq "$(git -C "$c/w" rev-parse refs/remotes/origin/trunk)" \
  "$(git -C "$c/origin.git" rev-parse refs/heads/trunk)" 'trunk was not fetched fresh'
expect_eq "$(git -C "$c/w" symbolic-ref refs/remotes/origin/HEAD)" \
  'refs/remotes/origin/main' 'helper rewrote the cached origin/HEAD'

case_name='rewritten remote default protects the candidate'
c=$scratch/rewrite
seed "$c"
p=$(pusher "$c")
git -C "$p" checkout -q --detach origin/trunk
wcommit "$p" rewrite.txt rewrite 'rewritten history'
git -C "$p" push -q --force origin HEAD:main
run_tool "$c/w" --apply
expect_rc 0
expect_out 'protected: merged-1 reason=unmerged'
expect_no_out 'deleted:'
expect_branch "$c/w" merged-1
expect_eq "$(git -C "$c/w" rev-parse refs/remotes/origin/main)" \
  "$(git -C "$c/origin.git" rev-parse refs/heads/main)" 'rewritten default tip was not force-fetched'

case_name='moved remote default is the authority, not the stale tracking ref'
c=$scratch/moved
seed "$c"
p=$(pusher "$c")
wcommit "$p" ahead.txt ahead 'default moved ahead'
git -C "$p" push -q origin HEAD:main
stale=$(git -C "$c/w" rev-parse refs/remotes/origin/main)
fresh=$(git -C "$c/origin.git" rev-parse refs/heads/main)
[ "$stale" != "$fresh" ] || fail 'fixture invalid: tracking ref is not stale'
run_tool "$c/w" --apply
expect_rc 0
expect_out "default: main sha=$fresh"
expect_out 'deleted: merged-1 '
expect_eq "$(git -C "$c/w" rev-parse refs/remotes/origin/main)" "$fresh" 'tracking ref was not refreshed'

# A candidate that changes between classification and the final recheck is
# reclassified, never deleted on the stale verdict.
case_name='candidate changed before the final recheck'
c=$scratch/moving-candidate
seed "$c"
wrap=$scratch/wrap-move
move_candidate_wrapper "$wrap" "$c/w" merged-1 wip-1
run_tool "$c/w" --apply
wrap=
expect_rc 0
expect_out 'reclassified: merged-1 reason=candidate-oid-changed'
expect_out 'restart: pass=1'
expect_out 'protected: merged-1 reason=unmerged'
expect_no_out 'deleted:'
expect_branch "$c/w" merged-1
expect_eq "$(git -C "$c/w" rev-parse merged-1)" "$(git -C "$c/w" rev-parse wip-1)" \
  'candidate is not at the moved tip'

# Losing the remote part-way through stops the run instead of finishing the
# remaining candidates against a verdict that can no longer be re-proven.
case_name='remote lost after the first deletion'
c=$scratch/midrun
seed "$c"
git -C "$c/w" branch --no-track merged-2 refs/remotes/origin/main
wrap=$scratch/wrap-break
break_remote_wrapper "$wrap" "$c/origin.git"
run_tool "$c/w" --apply
wrap=
expect_rc 1
expect_out 'deleted: merged-1 '
expect_out 'refused: origin could not be queried'
expect_out 'stopping; 1 branch(es) reported deleted above'
expect_no_branch "$c/w" merged-1
expect_branch "$c/w" merged-2
mv -- "$c/origin.git.gone" "$c/origin.git"

# An unrelated client attaches the candidate to a worktree in the instant
# before Git's own deletion check: Git refuses, and both the branch and the
# new worktree survive.
case_name='deletion-time worktree attach'
c=$scratch/attach
seed "$c"
wrap=$scratch/wrap-attach
attach_wrapper "$wrap" "$c/w" merged-1 "$c/wt2"
run_tool "$c/w" --apply
wrap=
expect_rc 1
expect_out 'kept: merged-1 reason=git-refused'
expect_no_out 'deleted:'
expect_branch "$c/w" merged-1
[ -f "$c/wt2/merged.txt" ] || fail 'the racing worktree was damaged'
expect_eq "$(git -C "$c/wt2" symbolic-ref --short HEAD)" 'merged-1' 'racing worktree head moved'
expect_eq "$(git -C "$c/wt" symbolic-ref --short HEAD)" 'wt-1' 'original worktree head moved'

# Concurrent helper instances are serialized by the helper's own lock.
case_name='helper lock'
c=$scratch/lock
seed "$c"
lockdir="$(git -C "$c/w" rev-parse --absolute-git-dir)/git-prune-local-branches.lock"
mkdir -p -- "$lockdir"
run_tool "$c/w" --apply
expect_rc 1
expect_out 'refused: another git-prune-local-branches instance holds'
expect_branch "$c/w" merged-1
rmdir -- "$lockdir"
run_tool "$c/w" --apply
expect_rc 0
expect_out 'deleted: merged-1 '
[ ! -e "$lockdir" ] || fail 'lock was not released'

case_name=
out=
printf '%s\n' 'git-prune-local-branches gates passed'
