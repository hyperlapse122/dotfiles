#!/usr/bin/env bash
set -euo pipefail

# Post-merge compliance check for the repository's landing method: the exact
# commit a merged pull request produced must be a real two-parent merge commit.
#
# This runs AFTER the merge has landed (from
# .github/workflows/merge-commit-only.yml), so it cannot prevent a squash or
# rebase landing -- it reports one as a FAILED compliance run.
#
# MERGE_RESULT_SHA is the `merge_commit_sha` that the read-only REST pull lookup
# returned for the event's pull request. It is never the merged `pull_request`
# payload's own (documented-empty) field and never the mutable base tip, so a
# base commit pushed after the merge cannot change what is checked here.
#
# That value is untrusted text until validated. The shape check below runs
# BEFORE any git process exists, and the object-format width check runs before
# the value reaches any git command line, so a malformed value can never be
# parsed as a revision expression (`HEAD^`, `main@{1}`, `<sha>^{tree}`,
# `a..b`) or expand inside one.
#
# Extracted from the workflow -- as .ci/check-windows-references.sh is -- so
# .ci/test-merge-commit-only-gates.sh can drive it against disposable local Git
# topologies instead of a live merge.

# repo_dir defaults to the current directory; the workflow runs this from the
# base-branch checkout, and the gate fixture passes a scratch repository.
repo_dir=${1:-.}
remote=${MERGE_RESULT_REMOTE:-origin}

fail() { printf '::error::merge-commit-only: %s\n' "$*" >&2; exit 1; }

sha=${MERGE_RESULT_SHA-}
[[ -n $sha ]] || fail 'no landed result commit was resolved (the read-only pull lookup produced no merge_commit_sha)'

# Shape first, with no git process in between.
[[ $sha =~ ^[0-9a-f]+$ ]] || fail "resolved result '$sha' is not lowercase canonical hex"
case ${#sha} in
  40 | 64) ;;
  *) fail "resolved result '$sha' is ${#sha} characters, not a canonical object id" ;;
esac

cd -- "$repo_dir" || fail "cannot enter repository $repo_dir"

# Repository metadata only: the untrusted value is not an argument here.
object_format=$(git rev-parse --show-object-format) ||
  fail "cannot read the object format of $repo_dir"
case $object_format in
  sha1) width=40 ;;
  sha256) width=64 ;;
  *) fail "unsupported repository object format $object_format" ;;
esac
[[ ${#sha} -eq $width ]] ||
  fail "resolved result is ${#sha} hex digits; this $object_format repository advertises $width"

# The result object can sit outside a shallow base checkout. Fetch that literal
# object id -- no refspec, no revision expression -- only when it is not local.
if ! git cat-file -e "$sha" 2>/dev/null; then
  if git remote get-url "$remote" >/dev/null 2>&1; then
    git fetch --no-tags --no-write-fetch-head --depth=1 "$remote" "$sha" >/dev/null 2>&1 ||
      fail "cannot fetch the resolved result object $sha from $remote"
  fi
fi

object_type=$(git cat-file -t "$sha" 2>/dev/null) ||
  fail "the resolved result object $sha is not present in this repository"
[[ $object_type == commit ]] ||
  fail "the resolved result $sha is a $object_type, not a commit"

commit_object=$(git cat-file commit "$sha") ||
  fail "cannot read the commit object $sha"

# Parents come from the RAW commit header: a shallow fetch grafts history, so
# `git rev-list --parents` / `git log --format=%P` report an empty parent list
# for a freshly fetched merge commit and would pass every landing shape.
parents=0
while IFS= read -r line; do
  [[ -z $line ]] && break
  [[ $line == 'parent '* ]] && parents=$((parents + 1))
done <<<"$commit_object"

case $parents in
  2) printf 'merge-commit-only: %s is a two-parent merge commit\n' "$sha" ;;
  1) fail "$sha has one parent: this pull request landed as a squash or rebase, not as a merge commit" ;;
  0) fail "$sha has no parent: the resolved result is a root commit, not a merge commit" ;;
  *) fail "$sha has $parents parents: the resolved result is not a two-parent merge commit" ;;
esac
