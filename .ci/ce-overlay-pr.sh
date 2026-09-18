#!/usr/bin/env bash
# .ci/ce-overlay-pr.sh -- the GitHub side of the compound-engineering overlay
# rebase: preflight, open, await, decide, marker, issue.
#
# Usage: .ci/ce-overlay-pr.sh <subcommand> [--option value ...]
#
# OUTPUT CONTRACT. stdout carries exactly one line per run:
#   result=<value> class=<failure class or none> [key=value ...]
# Values hold no whitespace. Everything else goes to stderr. Exit status: 0 for
# a normal outcome, 1 for a failed one, 2 for a usage error.
#
# EVERY gh CALL GOES THROUGH gh_call, so .ci/test-ce-overlay-pr.sh can put a stub
# first on PATH. preflight, open and await run as the CE_REBASE_TOKEN identity
# and never fall back to GITHUB_TOKEN: a pull request created with GITHUB_TOKEN
# starts no checks, and a merge by a bypass identity would skip "Final delivery".
# decide, issue and marker use whatever GH_TOKEN the caller exports.
#
# The pure decision logic lives in packages/ce-overlay-rebase (KTD10); this
# script only collects state, calls that CLI and performs git and gh work.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"

BRANCH_PREFIX='chore/rebase-ce-overlays-'
ISSUE_TITLE='Compound Engineering overlay rebase needs attention'
WORKFLOW_FILE='rebase-ce-overlays.yml'
FINAL_CHECK='Final delivery'
ACTIONS_APP_ID=15368
CONFLICT_MAX=4000
TAG_PATTERN='^compound-engineering-v[0-9]+\.[0-9]+\.[0-9]+$'
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

tmp_dir=''
err_file=''
ceo_bun=''
MARKER_REL=''
LOCK_REL=''
BASE_REL=''
PATCHES_REL=''

say() { printf 'ce-overlay-pr: %s\n' "$*" >&2; }

warn() {
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    printf '::warning::ce-overlay-pr: %s\n' "$*" >&2
  else
    printf 'ce-overlay-pr: warning: %s\n' "$*" >&2
  fi
}

err() { printf 'ce-overlay-pr: error: %s\n' "$*" >&2; }

usage() {
  err "$*"
  printf 'usage: ce-overlay-pr.sh <preflight|open|await|decide|marker|issue> [--option value ...]\n' >&2
  exit 2
}

# emit <result=..> <class=..> [key=value ...]: the one machine-readable line.
emit() {
  local field out=''
  for field in "$@"; do
    out+="${out:+ }${field//[[:space:]]/_}"
  done
  printf '%s\n' "$out"
}

# parse_opts "<value options>" "<flag options>" args...: sets opt_<name>.
parse_opts() {
  local values=" $1 " flags=" $2 " name
  shift 2
  while [[ $# -gt 0 ]]; do
    case $1 in
    --*)
      name=${1#--}
      if [[ $values == *" $name "* ]]; then
        [[ $# -ge 2 ]] || usage "--$name needs a value"
        printf -v "opt_${name//-/_}" '%s' "$2"
        shift 2
      elif [[ $flags == *" $name "* ]]; then
        printf -v "opt_${name//-/_}" '%s' 1
        shift
      else
        usage "unknown option --$name"
      fi
      ;;
    *) usage "unexpected argument $1" ;;
    esac
  done
}

setup_scratch() {
  tmp_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ce-overlay-pr.XXXXXX")
  # shellcheck disable=SC2064  # expand now: the trap must name this run's directory
  trap "rm -rf -- '$tmp_dir'" EXIT
  err_file="$tmp_dir/gh.err"
  : >"$err_file"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
}

require_repo() {
  [[ ${GITHUB_REPOSITORY-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    usage 'GITHUB_REPOSITORY must be set to <owner>/<repo>'
  REPO=$GITHUB_REPOSITORY
}

gh_call() { command gh "$@" 2>"$err_file"; }

gh_status() { sed -n 's/.*HTTP \([0-9][0-9][0-9]\).*/\1/p' "$err_file" | head -n 1; }

gh_error_text() { sed 's/^/  gh: /' "$err_file" >&2; }

ensure_bun() {
  [[ -z $ceo_bun ]] || return 0
  # shellcheck source=.ci/lib/bun.sh
  source "$repo_root/.ci/lib/bun.sh"
  resolve_bun
  [[ -n $BUN_BIN ]] || {
    err 'bun is required to run the packages/ce-overlay-rebase CLI'
    exit 1
  }
  ceo_bun=$BUN_BIN
}

ce_cli() { "$ceo_bun" "$repo_root/packages/ce-overlay-rebase/src/cli.ts" "$@"; }

tag_valid() { [[ ${1-} =~ $TAG_PATTERN ]]; }

segment_of() { printf 'v%s' "${1#compound-engineering-v}"; }

# set_paths <root>: repository-relative source-state paths, through the resolver.
set_paths() {
  local root=$1 source_root prefix=''
  source_root=$(resolve_source_root "$root") || return 1
  [[ $source_root == "$root" ]] || prefix="${source_root#"$root"/}/"
  MARKER_REL="${prefix}.chezmoidata/ce-overlay-rebase.json"
  LOCK_REL="${prefix}.chezmoidata/releases.json"
  BASE_REL="${prefix}dot_local/share/compound-engineering-overlays/base.json"
  PATCHES_REL="${prefix}dot_local/share/compound-engineering-overlays/patches"
}

allow_marker_only() { [[ $1 == "$MARKER_REL" ]]; }

allow_pr_paths() {
  [[ $1 == "$MARKER_REL" || $1 == "$LOCK_REL" || $1 == "$BASE_REL" || $1 == "$PATCHES_REL"/*.patch ]]
}

# assert_commit_paths <repo> <base> <commit> <predicate>: the commit changes at
# least one path, and every changed path satisfies the predicate.
assert_commit_paths() {
  local repo=$1 base=$2 commit=$3 allowed=$4 path found=0
  while IFS= read -r -d '' path; do
    found=1
    if ! "$allowed" "$path"; then
      err "commit ${commit:0:12} changes $path, which is outside the allowed paths"
      return 1
    fi
  done < <(git -C "$repo" diff --name-only --no-renames -z "$base" "$commit")
  [[ $found -eq 1 ]] || {
    err "commit ${commit:0:12} changes nothing"
    return 1
  }
}

# git_authed <token variable name> <git args...>: the token reaches git through a
# credential helper that reads the environment, never through argv or a URL.
git_authed() {
  local var=$1 token
  shift
  token=${!var-}
  if [[ -z $token ]]; then
    git "$@"
    return
  fi
  # shellcheck disable=SC2016  # the helper body expands inside git's shell, not here
  CEO_PUSH_TOKEN=$token git -c credential.helper= \
    -c 'credential.helper=!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$CEO_PUSH_TOKEN"; }; f' \
    "$@"
}

remote_url() { printf '%s' "${opt_remote:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY-}.git}"; }

default_branch() {
  local db=${opt_default_branch:-${CE_DEFAULT_BRANCH-}} repo_json
  if [[ -z $db ]]; then
    repo_json=$(gh_call api "repos/$REPO") || {
      gh_error_text
      return 1
    }
    db=$(jq -r '.default_branch // empty' <<<"$repo_json")
  fi
  [[ $db =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  printf '%s' "$db"
}

# Neutralizes what must not reach a public artifact or wake another workflow:
# token-shaped strings, and the @claude mention that starts claude.yml.
sanitize_text() {
  sed -E \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/[redacted]/g' \
    -e 's/@([Cc][Ll][Aa][Uu][Dd][Ee])/[at]\1/g'
}

run_url() {
  if [[ -n ${opt_run_url-} ]]; then
    printf '%s' "$opt_run_url"
  elif [[ -n ${GITHUB_RUN_ID-} && -n ${GITHUB_REPOSITORY-} ]]; then
    printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  else
    printf 'unavailable'
  fi
}

# require_rebase_token: P1. Reads only CE_REBASE_TOKEN and hides GITHUB_TOKEN so
# gh cannot substitute it.
require_rebase_token() {
  local token=${CE_REBASE_TOKEN-}
  if [[ -z ${token//[[:space:]]/} ]]; then
    err 'P1: the secret CE_REBASE_TOKEN is empty or not set; a rebase pull request is never created with GITHUB_TOKEN'
    emit result=failed class=configuration missing=P1 detail=token-missing
    exit 1
  fi
  export GH_TOKEN=$CE_REBASE_TOKEN
  unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN
}

fail_prereq() {
  err "$2"
  emit result=failed class=configuration "missing=$1" "detail=$3"
  exit 1
}

# api_failure <prerequisite for a 403 or 404> <what failed>
api_failure() {
  local status
  status=$(gh_status)
  gh_error_text
  case $status in
  401) fail_prereq P1 "P1: the API rejected CE_REBASE_TOKEN with HTTP 401 while reading $2; the token is invalid or expired" unauthorized ;;
  403 | 404) fail_prereq "$1" "$1: CE_REBASE_TOKEN cannot read $2 (HTTP $status)" forbidden ;;
  esac
  err "the API call for $2 failed${status:+ with HTTP $status}"
  emit result=failed class=unknown detail=api-error
  exit 1
}

cmd_preflight() {
  parse_opts 'default-branch' '' "$@"
  setup_scratch
  require_repo
  require_rebase_token

  local repo_json db rules ids id ruleset bypass count bound strict
  repo_json=$(gh_call api "repos/$REPO") || api_failure P2 'the repository settings'
  if [[ $(jq -r '.allow_auto_merge // false' <<<"$repo_json") != true ]]; then
    fail_prereq P2 'P2: the repository setting "Allow auto-merge" is off; gh pr merge --auto cannot work' auto-merge-off
  fi

  db=${opt_default_branch:-$(jq -r '.default_branch // empty' <<<"$repo_json")}
  [[ $db =~ ^[A-Za-z0-9._/-]+$ ]] || fail_prereq P3 'P3: the default branch is unknown' no-default-branch
  rules=$(gh_call api "repos/$REPO/rules/branches/$db") || api_failure P3 "the active rules for $db"

  count=$(jq --arg c "$FINAL_CHECK" \
    '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == $c)] | length' <<<"$rules")
  if [[ $count -eq 0 ]]; then
    fail_prereq P3 "P3: no active ruleset on $db requires the status check \"$FINAL_CHECK\"; auto-merge would merge without waiting for CI" check-missing
  fi
  bound=$(jq --arg c "$FINAL_CHECK" --argjson app "$ACTIONS_APP_ID" \
    '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == $c and .integration_id == $app)] | length' <<<"$rules")
  if [[ $bound -eq 0 ]]; then
    fail_prereq P3 "P3: the required check \"$FINAL_CHECK\" is not bound to the GitHub Actions source (integration $ACTIONS_APP_ID)" check-unbound
  fi
  strict=$(jq '[.[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy] | any' <<<"$rules")
  if [[ $strict != true ]]; then
    fail_prereq P3 "P3: the ruleset does not require branches to be up to date before merging (the up-to-date rule is off)" up-to-date-off
  fi

  ids=$(jq -r '[.[] | select(.type == "required_status_checks") | .ruleset_id] | unique | .[]' <<<"$rules")
  for id in $ids; do
    ruleset=$(gh_call api "repos/$REPO/rulesets/$id") || api_failure P3 "ruleset $id"
    bypass=$(jq -r '.current_user_can_bypass // "unknown"' <<<"$ruleset")
    if [[ $bypass != never ]]; then
      fail_prereq P3 "P3: the CE_REBASE_TOKEN identity can bypass ruleset $id (current_user_can_bypass=$bypass); a bypassing merge would skip \"$FINAL_CHECK\"" bypass
    fi
  done

  if [[ -z ${CE_LOCK_APP_ID-} || -z ${CE_LOCK_APP_PRIVATE_KEY-} ]]; then
    fail_prereq P4 'P4: the GitHub App credentials CE_LOCK_APP_ID and CE_LOCK_APP_PRIVATE_KEY are missing, and a ruleset exists that rejects direct pushes without the App bypass' app-missing
  fi

  say "preflight: P1-P4 hold for $REPO on $db"
  emit result=ok class=none "default_branch=$db"
}

# close_and_delete <pr> <branch> <reason>: best effort, never deletes a branch
# outside the rebase prefix.
close_and_delete() {
  local pr=$1 branch=$2 reason=$3
  gh_call pr close "$pr" --repo "$REPO" --comment "Closed automatically: $reason." >/dev/null ||
    { gh_error_text; warn "could not close pull request #$pr"; }
  if [[ $branch == "$BRANCH_PREFIX"* ]]; then
    gh_call api -X DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null ||
      { gh_error_text; warn "could not delete branch $branch"; }
  else
    warn "branch $branch is outside $BRANCH_PREFIX and was not deleted"
  fi
}

pr_body() {
  local target=$1 lines=$2
  {
    printf 'Rebases the compound-engineering overlay patches onto `%s`.\n\n' "$target"
    printf 'The change carries the CE lock entry, the regenerated patches, `base.json`, and the rebase marker reset to `idle`.\n\n'
    if [[ $lines == unchanged ]]; then
      printf 'Only context lines moved in the patches, so auto-merge is enabled. It waits for `%s`.\n' "$FINAL_CHECK"
    else
      printf 'A customization line changed, so this pull request waits for the owner'"'"'s review and has no auto-merge.\n'
    fi
    printf '\nRun: %s\n' "$(run_url)"
  } | sanitize_text
}

cmd_open() {
  parse_opts 'target work-tree customization-lines base default-branch remote' '' "$@"
  setup_scratch
  require_repo
  ensure_bun
  local target=${opt_target-} lines=${opt_customization_lines-}
  tag_valid "$target" || usage '--target must be a compound-engineering-v<semver> tag'
  [[ $lines == unchanged || $lines == changed ]] || usage '--customization-lines must be unchanged or changed'
  require_rebase_token

  local work top db remote head_sha base_sha branch idx work_tree_obj final_tree merged c p
  local -a add_paths=()
  work=$(cd -- "${opt_work_tree:-.}" && pwd)
  top=$(git -C "$work" rev-parse --show-toplevel)
  [[ $top == "$work" ]] || usage '--work-tree must be the top of a git work tree'
  set_paths "$work"
  db=$(default_branch) || {
    err 'cannot determine the default branch'
    emit result=failed class=unknown detail=no-default-branch
    exit 1
  }
  remote=$(remote_url)
  branch="$BRANCH_PREFIX$(segment_of "$target")"

  head_sha=$(git -C "$work" rev-parse --verify 'HEAD^{commit}')
  if [[ -n ${opt_base-} ]]; then
    git -C "$work" cat-file -e "${opt_base}^{commit}" 2>/dev/null ||
      git_authed CE_REBASE_TOKEN -C "$work" fetch -q --no-tags "$remote" "refs/heads/$db" >&2
    base_sha=$(git -C "$work" rev-parse --verify "${opt_base}^{commit}")
  else
    base_sha=$head_sha
  fi

  while IFS= read -r -d '' p; do
    allow_pr_paths "$p" || {
      err "the work tree changes $p, which is outside the pull request allowlist"
      emit result=failed class=genuine detail=path-outside-allowlist
      exit 1
    }
  done < <(git -C "$work" diff --name-only -z HEAD)
  while IFS= read -r -d '' p; do
    allow_pr_paths "$p" || {
      err "the work tree holds the untracked file $p inside the patches directory"
      emit result=failed class=genuine detail=path-outside-allowlist
      exit 1
    }
  done < <(git -C "$work" ls-files --others --exclude-standard -z -- "$PATCHES_REL")

  idx="$tmp_dir/open.index"
  gitx() { GIT_INDEX_FILE=$idx git -C "$work" "$@"; }
  gitx read-tree "$head_sha"
  for p in "$LOCK_REL" "$BASE_REL" "$PATCHES_REL"; do
    [[ -e $work/$p ]] && add_paths+=("$p")
  done
  gitx add -A -- "${add_paths[@]}"
  work_tree_obj=$(gitx write-tree)

  final_tree=$work_tree_obj
  if [[ $base_sha != "$head_sha" ]]; then
    c=$(git -C "$work" -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" -c commit.gpgsign=false \
      commit-tree "$work_tree_obj" -p "$head_sha" -m 'ce-overlay rebase work')
    if ! merged=$(git -C "$work" merge-tree --write-tree "$base_sha" "$c" 2>"$tmp_dir/merge.err"); then
      sed 's/^/  git: /' "$tmp_dir/merge.err" >&2
      err "the rebase changes do not merge onto ${base_sha:0:12}"
      emit result=failed class=unknown detail=merge-conflict
      exit 1
    fi
    final_tree=${merged%%$'\n'*}
  fi

  local marker_file="$tmp_dir/marker.json" current blob
  current=$(git -C "$work" show "$base_sha:$MARKER_REL") || {
    err "cannot read $MARKER_REL at ${base_sha:0:12}"
    emit result=failed class=unknown detail=marker-unreadable
    exit 1
  }
  jq -c --arg target "$target" '{currentMarker: .ceOverlayRebase, event: {type: "reset", target: $target}}' <<<"$current" |
    ce_cli transition | ce_cli write-marker --out "$marker_file" >&2
  "$repo_root/.ci/check-ce-overlay-rebase-marker.sh" "$marker_file" >&2
  blob=$(git -C "$work" hash-object -w "$marker_file")
  gitx read-tree "$final_tree"
  gitx update-index --add --cacheinfo "100644,$blob,$MARKER_REL"
  final_tree=$(gitx write-tree)

  local subject="chore(ce-overlay): rebase patches onto $target" commit
  commit=$(git -C "$work" -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" -c commit.gpgsign=false \
    commit-tree "$final_tree" -p "$base_sha" -m "$subject")
  if ! assert_commit_paths "$work" "$base_sha" "$commit" allow_pr_paths; then
    emit result=failed class=genuine detail=path-outside-allowlist
    exit 1
  fi

  if ! git_authed CE_REBASE_TOKEN -C "$work" push -q "$remote" "$commit:refs/heads/$branch" >&2; then
    err "cannot push $branch"
    emit result=failed class=unknown detail=push-failed
    exit 1
  fi

  local title=$subject body url pr
  body=$(pr_body "$target" "$lines")
  if [[ $title == *@claude* || $body == *@claude* ]]; then
    err 'a generated title or body contains @claude'
    exit 1
  fi
  if ! url=$(gh_call pr create --repo "$REPO" --base "$db" --head "$branch" --title "$title" --body "$body"); then
    local create_status
    create_status=$(gh_status)
    gh_error_text
    gh_call api -X DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null || true
    if [[ $create_status == 401 ]]; then
      fail_prereq P1 'P1: the API rejected CE_REBASE_TOKEN with HTTP 401 while creating the pull request' unauthorized
    fi
    emit result=failed class=unknown detail=pr-create-failed
    exit 1
  fi
  pr=$(printf '%s\n' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\)[[:space:]]*$#\1#p' | tail -n 1)
  [[ -n $pr ]] || {
    err "cannot read the pull request number from: $url"
    emit result=failed class=unknown detail=pr-number-unreadable
    exit 1
  }

  if [[ $lines == changed ]]; then
    say "opened #$pr without auto-merge: a customization line changed"
    emit result=awaiting-review class=none "pr=$pr" "branch=$branch" "sha=$commit"
    return 0
  fi
  if ! gh_call pr merge "$pr" --repo "$REPO" --merge --auto >/dev/null; then
    gh_error_text
    close_and_delete "$pr" "$branch" 'auto-merge could not be enabled'
    emit result=failed class=configuration missing=P2 detail=auto-merge-failed
    exit 1
  fi
  say "opened #$pr with auto-merge enabled"
  emit result=auto-merge class=none "pr=$pr" "branch=$branch" "sha=$commit"
}

# check_state <sha>: success, pending, missing, or failed:<conclusion> for the
# required check, run by the GitHub Actions app, on that exact commit.
check_state() {
  local checks
  checks=$(gh_call api --paginate "repos/$REPO/commits/$1/check-runs?per_page=100") || return 1
  jq -s -r --arg n "$FINAL_CHECK" --argjson app "$ACTIONS_APP_ID" '
    [.[].check_runs[]? | select(.name == $n and .app.id == $app)] as $runs
    | if ($runs | length) == 0 then "missing"
      elif any($runs[]; .status != "completed") then "pending"
      elif all($runs[]; .conclusion == "success") then "success"
      else "failed:" + ([$runs[] | select(.conclusion != "success") | .conclusion][0] // "unknown") end
  ' <<<"$checks"
}

cmd_await() {
  parse_opts 'pr customization-lines deadline-seconds interval-seconds default-branch' '' "$@"
  local lines=${opt_customization_lines-} pr=${opt_pr-}
  [[ $lines == unchanged || $lines == changed ]] || usage '--customization-lines must be unchanged or changed'
  if [[ $lines == changed ]]; then
    emit result=awaiting-review class=none
    return 0
  fi
  [[ $pr =~ ^[0-9]+$ ]] || usage '--pr must be a pull request number'
  local deadline=${opt_deadline_seconds:-3300} interval=${opt_interval_seconds:-30}
  [[ $deadline =~ ^[0-9]+$ ]] || usage '--deadline-seconds must be a whole number'
  [[ $interval =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage '--interval-seconds must be a number'
  setup_scratch
  require_repo
  require_rebase_token

  local db pr_json state merged mergeable mstate sha branch behind checks last_update=''
  local deadline_at=$((SECONDS + deadline))
  db=$(default_branch) || {
    err 'cannot determine the default branch'
    emit result=failed class=unknown detail=no-default-branch
    exit 1
  }

  while :; do
    if pr_json=$(gh_call api "repos/$REPO/pulls/$pr"); then
      state=$(jq -r '.state' <<<"$pr_json")
      merged=$(jq -r '.merged // false' <<<"$pr_json")
      mergeable=$(jq -r '.mergeable | tostring' <<<"$pr_json")
      mstate=$(jq -r '.mergeable_state // "unknown"' <<<"$pr_json")
      sha=$(jq -r '.head.sha' <<<"$pr_json")
      branch=$(jq -r '.head.ref' <<<"$pr_json")

      if [[ $merged == true ]]; then
        checks=$(check_state "$sha") || checks=unreadable
        if [[ $checks == success ]]; then
          say "#$pr merged, and \"$FINAL_CHECK\" succeeded on its final head ${sha:0:12}"
          emit result=merged class=none "pr=$pr" "sha=$sha"
          return 0
        fi
        err "#$pr merged unchecked: \"$FINAL_CHECK\" is $checks on its final head ${sha:0:12}"
        emit result=failed class=unknown detail=merged-unchecked "pr=$pr"
        exit 1
      elif [[ $state == closed ]]; then
        err "#$pr was closed without merging"
        emit result=failed class=unknown detail=closed "pr=$pr"
        exit 1
      elif [[ $mergeable == false || $mstate == dirty ]]; then
        say "#$pr conflicts with $db; closing it so the next hourly tick dispatches again"
        close_and_delete "$pr" "$branch" "it conflicts with $db"
        emit result=conflict class=none "pr=$pr"
        return 0
      fi

      behind=$(gh_call api "repos/$REPO/compare/$db...$sha" | jq -r '.behind_by // 0') || behind=0
      if [[ $behind =~ ^[0-9]+$ && $behind -gt 0 && $sha != "$last_update" ]]; then
        if gh_call api -X PUT "repos/$REPO/pulls/$pr/update-branch" -f "expected_head_sha=$sha" >/dev/null; then
          last_update=$sha
          say "#$pr is $behind commit(s) behind $db; updated its branch with a merge"
        elif grep -qi 'conflict' "$err_file"; then
          gh_error_text
          close_and_delete "$pr" "$branch" "it conflicts with $db"
          emit result=conflict class=none "pr=$pr"
          return 0
        else
          gh_error_text
          warn "could not update the branch of #$pr; retrying"
        fi
      else
        checks=$(check_state "$sha") || checks=unreadable
        case $checks in
        failed:*)
          err "\"$FINAL_CHECK\" ended ${checks#failed:} on ${sha:0:12}"
          close_and_delete "$pr" "$branch" "the required check \"$FINAL_CHECK\" failed"
          emit result=failed class=unknown detail=check-failed "pr=$pr"
          exit 1
          ;;
        *) say "#$pr waiting: \"$FINAL_CHECK\" is $checks on ${sha:0:12}" ;;
        esac
      fi
    else
      if [[ $(gh_status) == 401 ]]; then
        gh_error_text
        fail_prereq P1 'P1: the API rejected CE_REBASE_TOKEN with HTTP 401 while waiting for the merge' unauthorized
      fi
      gh_error_text
      warn "could not read #$pr; retrying"
    fi

    if ((SECONDS >= deadline_at)); then
      err "the deadline of ${deadline}s passed before #$pr merged"
      close_and_delete "$pr" "${branch:-}" 'the merge deadline passed'
      emit result=failed class=unknown detail=deadline "pr=$pr"
      exit 1
    fi
    sleep "$interval"
  done
}

cmd_decide() {
  parse_opts 'resolved-tag pin gate-class default-branch marker-file exclude-run now workflow' 'no-act' "$@"
  setup_scratch
  require_repo
  ensure_bun
  local resolved=${opt_resolved_tag-} pin=${opt_pin-} gate=${opt_gate_class:-invalid} workflow=${opt_workflow:-$WORKFLOW_FILE}
  [[ -n $resolved && -n $pin ]] || usage '--resolved-tag and --pin are required'
  local db failed=0 marker_file=${opt_marker_file-} marker runs='[]' prs='[]' issue='null' raw n title_hit

  db=$(default_branch) || {
    warn 'cannot determine the default branch; no dispatch'
    emit result=skip class=none reason=state-query-failed
    return 0
  }
  if [[ -z $marker_file ]]; then
    set_paths "$repo_root"
    marker_file="$repo_root/$MARKER_REL"
  fi
  marker=$(jq -c '.ceOverlayRebase' "$marker_file" 2>/dev/null) || marker=''
  if [[ -z $marker || $marker == null ]]; then
    failed=1
    marker='{"target":"compound-engineering-v0.0.0","status":"idle","attempts":0,"firstAttempt":null,"lastAttempt":null,"notBefore":null,"failureClass":null,"missing":[],"issue":null}'
    warn "cannot read the marker at $marker_file"
  fi

  if ((!failed)); then
    if raw=$(gh_call run list --repo "$REPO" --workflow "$workflow" --limit 50 --json databaseId,status,conclusion); then
      runs=$(jq -c --arg x "${opt_exclude_run-}" '
        [.[] | select(.status != "completed") | select(($x == "") or ((.databaseId | tostring) != $x))
         | {status: (if .status == "in_progress" then "in_progress" else "queued" end), conclusion: null}]' <<<"$raw")
    else
      gh_error_text
      failed=1
    fi
  fi
  if ((!failed)); then
    if raw=$(gh_call pr list --repo "$REPO" --state open --limit 100 --json number,headRefName,createdAt,autoMergeRequest,isCrossRepository); then
      prs=$(jq -c --arg p "$BRANCH_PREFIX" '
        [.[] | select(.headRefName | startswith($p)) | select(.isCrossRepository == false)
         | {number, headRefName, createdAt, autoMergeEnabled: (.autoMergeRequest != null),
            targetTag: ("compound-engineering-" + (.headRefName | ltrimstr($p)))}]' <<<"$raw")
    else
      gh_error_text
      failed=1
    fi
  fi
  if ((!failed)); then
    n=$(jq -r '.issue // empty' <<<"$marker")
    if [[ -n $n ]]; then
      if raw=$(gh_call issue view "$n" --repo "$REPO" --json number,state,title); then
        issue=$(jq -c '{number, state: (.state | ascii_downcase), title}' <<<"$raw")
      elif [[ $(gh_status) != 404 ]]; then
        gh_error_text
        failed=1
      fi
    fi
  fi
  if ((!failed)) && [[ $(jq -r '.state // "none"' <<<"$issue") != open ]]; then
    if raw=$(gh_call issue list --repo "$REPO" --state open --limit 100 --json number,state,title); then
      title_hit=$(jq -c --arg t "$ISSUE_TITLE" '[.[] | select(.title == $t)] | sort_by(.number) | .[0] // null
        | if . == null then null else {number, state: (.state | ascii_downcase), title} end' <<<"$raw")
      [[ $title_hit == null ]] || issue=$title_hit
    else
      gh_error_text
      failed=1
    fi
  fi

  local input decision action reason
  input=$(jq -n -c --arg resolvedTag "$resolved" --arg pin "$pin" --arg gateClass "$gate" --arg now "${opt_now-}" \
    --argjson marker "$marker" --argjson runs "$runs" --argjson prs "$prs" --argjson issue "$issue" --argjson failed "$failed" '
    {resolvedTag: $resolvedTag, pin: $pin, gateClass: $gateClass, marker: $marker, rebaseRuns: $runs,
     openPullRequests: $prs, trackingIssue: $issue, stateQueryFailed: ($failed == 1)}
    + (if $now == "" then {} else {now: $now} end)')
  if ! decision=$(ce_cli decide <<<"$input" 2>"$tmp_dir/decide.err"); then
    sed 's/^/  cli: /' "$tmp_dir/decide.err" >&2
    warn 'the dispatch decision failed; no dispatch'
    emit result=skip class=none reason=decision-failed
    return 0
  fi
  action=$(jq -r '.action' <<<"$decision")
  reason=$(jq -r '.reason' <<<"$decision")
  say "decision: $action: $reason"
  if ((failed)); then
    warn 'a state query failed; no dispatch'
    emit result=skip class=none reason=state-query-failed
    return 0
  fi
  local slug
  slug=$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')

  if [[ $action == skip ]]; then
    emit result=skip class=none "reason=$slug"
    return 0
  fi
  if [[ -n ${opt_no_act-} ]]; then
    emit "result=$action" class=none "reason=$slug"
    return 0
  fi

  local closed='' number branch
  if [[ $action == close-then-dispatch ]]; then
    for number in $(jq -r '.closePrNumbers[]?' <<<"$decision"); do
      branch=$(jq -r --argjson n "$number" '.[] | select(.number == $n) | .headRefName' <<<"$prs")
      if ! gh_call pr close "$number" --repo "$REPO" --comment 'Closed automatically: superseded or orphaned rebase pull request.' >/dev/null; then
        gh_error_text
        warn "cannot close #$number; no dispatch"
        emit result=skip class=none reason=close-failed
        return 0
      fi
      gh_call api -X DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null ||
        { gh_error_text; warn "cannot delete branch $branch"; }
      closed+="${closed:+,}$number"
    done
  fi
  if gh_call workflow run "$workflow" --repo "$REPO" --ref "$db" >/dev/null; then
    say "dispatched $workflow on $db"
    emit "result=$action" class=none "reason=$slug" "closed=${closed:-none}"
  else
    gh_error_text
    warn "cannot dispatch $workflow on $db; the next hourly tick retries"
    emit result=dispatch-failed class=none "reason=$slug" "closed=${closed:-none}"
  fi
}

# fresh_checkout <dir> <remote> <branch> <token variable name>
fresh_checkout() {
  git init -q "$1"
  git -C "$1" remote add origin "$2"
  git_authed "$4" -C "$1" fetch -q --no-tags --depth=1 origin "refs/heads/$3" >&2
  git -C "$1" checkout -q --detach FETCH_HEAD
}

cmd_marker() {
  parse_opts 'event target failure-class reached-claude missing issue now push-token-env default-branch remote' 'manual-trigger' "$@"
  setup_scratch
  ensure_bun
  local event=${opt_event-} target=${opt_target-} token_var=${opt_push_token_env:-CE_PUSH_TOKEN}
  case $event in failure | awaiting-review | reset) ;; *) usage '--event must be failure, awaiting-review or reset' ;; esac
  tag_valid "$target" || usage '--target must be a compound-engineering-v<semver> tag'
  [[ $token_var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage '--push-token-env must name an environment variable'
  if [[ $event == failure ]]; then
    [[ -n ${opt_failure_class-} ]] || usage '--failure-class is required for a failure event'
  fi

  local db=${opt_default_branch:-${CE_DEFAULT_BRANCH:-main}} remote attempt=0 co current new_marker file push_out subject sha
  remote=$(remote_url)
  local event_json
  event_json=$(jq -n -c --arg type "$event" --arg target "$target" --arg fc "${opt_failure_class-}" \
    --arg reached "${opt_reached_claude-}" --arg missing "${opt_missing-}" --arg issue "${opt_issue-}" \
    --arg now "${opt_now-}" --arg manual "${opt_manual_trigger-}" '
    {type: $type, target: $target}
    + (if $type == "failure" then {failureClass: $fc} else {} end)
    + (if $reached == "" then {} else {reachedClaude: ($reached == "true")} end)
    + (if $missing == "" then {} else {missing: ($missing | split(","))} end)
    + (if $issue == "" then {} else {issue: ($issue | tonumber)} end)
    + (if $now == "" then {} else {now: $now} end)
    + (if $manual == "" then {} else {manualTrigger: true} end)')

  while :; do
    co="$tmp_dir/marker-checkout.$attempt"
    fresh_checkout "$co" "$remote" "$db" "$token_var"
    set_paths "$co"
    file="$co/$MARKER_REL"
    current=$(jq -c '.ceOverlayRebase' "$file") || {
      err "cannot read the marker at $MARKER_REL on $db"
      emit result=failed class=unknown detail=marker-unreadable
      exit 1
    }
    if ! new_marker=$(jq -n -c --argjson current "$current" --argjson event "$event_json" '{currentMarker: $current, event: $event}' |
      ce_cli transition); then
      err 'the marker transition failed'
      emit result=failed class=unknown detail=transition-failed
      exit 1
    fi
    if ! ce_cli write-marker --out "$file" <<<"$new_marker" >&2; then
      err 'the marker CLI refused the new marker; nothing was written'
      emit result=failed class=unknown detail=marker-refused
      exit 1
    fi
    "$repo_root/.ci/check-ce-overlay-rebase-marker.sh" "$file" >&2 || {
      emit result=failed class=unknown detail=marker-check-failed
      exit 1
    }

    if git -C "$co" diff --quiet -- "$MARKER_REL"; then
      sha=$(git -C "$co" rev-parse HEAD)
      say 'the marker already holds this state; nothing to commit'
      emit result=unchanged class=none "sha=$sha"
      return 0
    fi
    subject="chore(ce-overlay): record rebase marker $(jq -r '.status' <<<"$new_marker")"
    git -C "$co" add -- "$MARKER_REL"
    git -C "$co" -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
      commit -q -m "$subject"
    if ! assert_commit_paths "$co" HEAD~1 HEAD allow_marker_only; then
      emit result=failed class=genuine detail=path-outside-allowlist
      exit 1
    fi
    sha=$(git -C "$co" rev-parse HEAD)

    if push_out=$(git_authed "$token_var" -C "$co" push -q origin "HEAD:refs/heads/$db" 2>&1); then
      say "pushed the marker commit ${sha:0:12} to $db"
      emit result=pushed class=none "sha=$sha"
      return 0
    fi
    printf '%s\n' "$push_out" | sed 's/^/  git: /' >&2
    if [[ $push_out == *'non-fast-forward'* || $push_out == *'fetch first'* ]]; then
      if ((attempt >= 3)); then
        err "the push lost the race on $db after 3 re-creations"
        emit result=failed class=unknown detail=push-race
        exit 1
      fi
      attempt=$((attempt + 1))
      say "the push lost a race; re-creating the marker commit on the new tip ($attempt/3)"
      continue
    fi
    err "the push to $db was rejected. If a ruleset protects $db, the P3 bypass entry for the P4 GitHub App is missing; the hourly refresh of every tool stops until it exists"
    emit result=push-rejected class=configuration missing=P3
    exit 1
  done
}

cmd_issue() {
  parse_opts 'target failure-class missing conflict-file path-results run-url issue' '' "$@"
  setup_scratch
  require_repo
  local target=${opt_target-}
  tag_valid "$target" || usage '--target must be a compound-engineering-v<semver> tag'
  local class=${opt_failure_class:-unknown} conflict='' body found='' number raw
  case $class in outage | quota | genuine | unknown | configuration) ;; *) usage '--failure-class must be a known failure class' ;; esac
  if [[ -n ${opt_conflict_file-} ]]; then
    [[ -f $opt_conflict_file ]] || usage "--conflict-file $opt_conflict_file does not exist"
    conflict=$(head -c "$CONFLICT_MAX" "$opt_conflict_file" | tr -d '\000')
    [[ $(wc -c <"$opt_conflict_file") -le $CONFLICT_MAX ]] || conflict+=$'\n[truncated]'
    conflict=${conflict//'~~~'/'~ ~ ~'}
  fi

  body=$(
    printf '## Target\n\n`%s`\n\n## Failure class\n\n`%s`\n\n' "$target" "$class"
    if [[ -n ${opt_missing-} ]]; then
      printf '## Missing owner prerequisites\n\n%s\n\n' "${opt_missing//,/, }"
    fi
    printf '## Per-path result\n\n'
    if [[ -n ${opt_path_results-} ]]; then
      local pair
      for pair in ${opt_path_results//,/ }; do
        printf -- '- `%s`: %s\n' "${pair%%=*}" "${pair#*=}"
      done
    else
      printf 'No per-path result was recorded.\n'
    fi
    printf '\n'
    if [[ -n $conflict ]]; then
      printf '## Conflict output\n\n~~~text\n%s\n~~~\n\n' "$conflict"
    fi
    printf '## Run\n\n%s\n\n' "$(run_url)"
    printf '## Recovery\n\n'
    printf '1. Read the run log and follow the conflict procedure in AGENTS.md.\n'
    printf '2. For a missing prerequisite, complete P1-P4 as listed in AGENTS.md.\n'
    printf '3. Close this issue to resume automatic dispatch, or run the `%s` workflow manually.\n' "$WORKFLOW_FILE"
  )
  body=$(sanitize_text <<<"$body")

  number=${opt_issue-}
  if [[ -n $number ]]; then
    if raw=$(gh_call issue view "$number" --repo "$REPO" --json number,state,title); then
      [[ $(jq -r '.state' <<<"$raw") == OPEN ]] && found=$number
    elif [[ $(gh_status) != 404 ]]; then
      gh_error_text
      emit result=failed class=unknown detail=issue-query-failed
      exit 1
    fi
  fi
  if [[ -z $found ]]; then
    if raw=$(gh_call issue list --repo "$REPO" --state open --limit 100 --json number,title); then
      found=$(jq -r --arg t "$ISSUE_TITLE" '[.[] | select(.title == $t)] | sort_by(.number) | .[0].number // empty' <<<"$raw")
    else
      gh_error_text
      emit result=failed class=unknown detail=issue-query-failed
      exit 1
    fi
  fi

  if [[ -n $found ]]; then
    gh_call issue comment "$found" --repo "$REPO" --body "$body" >/dev/null || {
      gh_error_text
      emit result=failed class=unknown detail=issue-comment-failed
      exit 1
    }
    say "commented on tracking issue #$found"
    emit result=commented class=none "issue=$found"
    return 0
  fi
  raw=$(gh_call issue create --repo "$REPO" --title "$ISSUE_TITLE" --body "$body") || {
    gh_error_text
    emit result=failed class=unknown detail=issue-create-failed
    exit 1
  }
  found=$(printf '%s\n' "$raw" | sed -n 's#.*/issues/\([0-9][0-9]*\)[[:space:]]*$#\1#p' | tail -n 1)
  say "opened tracking issue #${found:-unknown}"
  emit result=created class=none "issue=${found:-unknown}"
}

main() {
  local sub=${1-}
  [[ -n $sub ]] || usage 'a subcommand is required'
  shift
  case $sub in
  preflight) cmd_preflight "$@" ;;
  open) cmd_open "$@" ;;
  await) cmd_await "$@" ;;
  decide) cmd_decide "$@" ;;
  marker) cmd_marker "$@" ;;
  issue) cmd_issue "$@" ;;
  *) usage "unknown subcommand $sub" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
