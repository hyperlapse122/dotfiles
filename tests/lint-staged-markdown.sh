#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/lint-staged-markdown.sh <script> <hook> <config> <toml_version> <lock_version> <nixpkgs_version> <task_run>
#
# Verifies scripts/lint-staged-markdown, .githooks/pre-commit, the run command
# of the mise task lint-staged-markdown (<task_run>, relative to the directory
# holding scripts/), and that the mise.toml and mise.lock markdownlint-cli2 pins
# equal the nixpkgs version.
set -euo pipefail

if [[ $# -ne 7 ]]; then
  printf "usage: %s SCRIPT HOOK CONFIG TOML_VER LOCK_VER NIXPKGS_VER TASK_RUN\n" "${0##*/}" >&2
  exit 2
fi
abspath() { printf "%s/%s\n" "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
script=$(abspath "$1")
hook=$(abspath "$2")
config=$(abspath "$3")
toml_version=$4
lock_version=$5
nixpkgs_version=$6
task_run=$7

fail() { printf "lint-staged-markdown: FAIL: %s\n" "$*" >&2; exit 1; }
pass() { printf "lint-staged-markdown: ok - %s\n" "$*"; }

assert_version_parity() {
  local toml_ver=$1
  local lock_ver=$2
  local nixpkgs_ver=$3

  if [[ -z "$toml_ver" || -z "$lock_ver" || -z "$nixpkgs_ver" ]]; then
    fail "version parity: missing version input (toml='$toml_ver', lock='$lock_ver', nixpkgs='$nixpkgs_ver')"
  fi

  if [[ "$toml_ver" != "$nixpkgs_ver" ]]; then
    fail "version parity mismatch: mise.toml pins npm:markdownlint-cli2 at '$toml_ver', but nixpkgs markdownlint-cli2 is '$nixpkgs_ver'"
  fi

  if [[ "$lock_ver" != "$nixpkgs_ver" ]]; then
    fail "version parity mismatch: mise.lock pins npm:markdownlint-cli2 at '$lock_ver', but nixpkgs markdownlint-cli2 is '$nixpkgs_ver'"
  fi
}

assert_version_parity "$toml_version" "$lock_version" "$nixpkgs_version"
pass "version parity holds (mise.toml=$toml_version, mise.lock=$lock_version, nixpkgs=$nixpkgs_version)"

# Setup isolated test environment
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export HOME="$TEST_TMPDIR/home"
mkdir -p "$HOME"

export GIT_AUTHOR_NAME="Test Author"
export GIT_AUTHOR_EMAIL="author@example.com"
export GIT_COMMITTER_NAME="Test Committer"
export GIT_COMMITTER_EMAIL="committer@example.com"

export GIT_CONFIG_GLOBAL="$TEST_TMPDIR/gitconfig"
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[init]
    defaultBranch = main
[user]
    name = Test Author
    email = author@example.com
EOF

make_test_repo() {
  local repo_dir=$1
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  cp "$config" "$repo_dir/.markdownlint-cli2.jsonc"
  git -C "$repo_dir" add .markdownlint-cli2.jsonc
  git -C "$repo_dir" commit -q -m "initial commit"
}

bad_md_content=$'# Title\n\nSome text\n- item 1\n- item 2\n'
clean_md_content=$'# Title\n\nSome text.\n\n- item 1\n- item 2\n'

# Scenario: Staged docs/bad.md with MD032 exits non-zero and outputs docs/bad.md, line number, MD032
repo1="$TEST_TMPDIR/repo1"
make_test_repo "$repo1"
mkdir -p "$repo1/docs"
printf "%s" "$bad_md_content" > "$repo1/docs/bad.md"
git -C "$repo1" add docs/bad.md
status=0
out=$( (cd "$repo1" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "staged bad markdown exited 0"
[[ $out == *"docs/bad.md"* ]] || fail "staged bad markdown output missing filename"
[[ $out =~ docs/bad\.md:[0-9]+ ]] || fail "staged bad markdown output missing line number"
[[ $out == *"MD032"* ]] || fail "staged bad markdown output missing MD032"
[[ $out == *"mise exec -- markdownlint-cli2 --no-globs --fix <file>"* ]] || fail "staged bad markdown missing fix instructions"
[[ $out == *"git commit --no-verify"* ]] || fail "staged bad markdown missing no-verify instructions"
pass "staged docs/bad.md exits non-zero and reports file, line number, and MD032"

# Scenario: Staged clean docs/ok.md exits 0
repo2="$TEST_TMPDIR/repo2"
make_test_repo "$repo2"
mkdir -p "$repo2/docs"
printf "%s" "$clean_md_content" > "$repo2/docs/ok.md"
git -C "$repo2" add docs/ok.md
(cd "$repo2" && bash "$script") || fail "staged clean docs/ok.md failed"
pass "staged clean docs/ok.md exits 0"

# Scenario: Commit staging only flake.nix exits 0 without running markdownlint-cli2 (proven by stub)
repo3="$TEST_TMPDIR/repo3"
make_test_repo "$repo3"
touch "$repo3/flake.nix"
git -C "$repo3" add flake.nix
stub_dir="$TEST_TMPDIR/failing_lint_bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/markdownlint-cli2" <<'STUB_EOF'
#!/bin/sh
echo "FAIL_STUB_CALLED" >&2
exit 99
STUB_EOF
chmod +x "$stub_dir/markdownlint-cli2"
(cd "$repo3" && PATH="$stub_dir:$PATH" bash "$script") || fail "staging non-markdown called markdownlint-cli2"
pass "staging only flake.nix exits 0 without running markdownlint-cli2"

# Scenario: the lint runs with the scratch copy trusted by its resolved path.
# The stub stands in for a mise shim: it refuses, as mise does, unless
# MISE_TRUSTED_CONFIG_PATHS names the resolved directory it runs in.
trust_stub_dir="$TEST_TMPDIR/trust_lint_bin"
mkdir -p "$trust_stub_dir"
cat > "$trust_stub_dir/markdownlint-cli2" <<'STUB_EOF'
#!/bin/sh
printf '%s\n' "${MISE_TRUSTED_CONFIG_PATHS-<unset>}" > "$TRUST_RECORD"
printf '%s\n' "${MISE_SAFE-<unset>}" > "$TRUST_RECORD.safe"
if [ "${MISE_TRUSTED_CONFIG_PATHS-}" != "$(pwd -P)" ]; then
  echo "mise ERROR Config files in $(pwd -P)/mise.toml are not trusted." >&2
  exit 1
fi
STUB_EOF
chmod +x "$trust_stub_dir/markdownlint-cli2"
repo15="$TEST_TMPDIR/repo15"
make_test_repo "$repo15"
mkdir -p "$repo15/docs"
printf "%s" "$clean_md_content" > "$repo15/docs/ok.md"
git -C "$repo15" add docs/ok.md
export TRUST_RECORD="$TEST_TMPDIR/trust_record"
(cd "$repo15" && PATH="$trust_stub_dir:$PATH" bash "$script") >/dev/null 2>&1 \
  || fail "lint ran without MISE_TRUSTED_CONFIG_PATHS naming the scratch copy (recorded: $(cat "$TRUST_RECORD" 2>/dev/null))"
pass "lint runs with MISE_TRUSTED_CONFIG_PATHS naming the scratch copy"

# Scenario: the trusted copy runs in mise safe mode, so a staged mise.toml
# cannot run environment code such as an [env] _.source script.
[[ $(cat "$TRUST_RECORD.safe") == 1 ]] \
  || fail "lint ran without MISE_SAFE=1 (recorded: $(cat "$TRUST_RECORD.safe"))"
pass "lint runs the trusted copy in mise safe mode"

# Scenario: under a symlinked TMPDIR the trusted path is the resolved one, as
# on macOS, where $TMPDIR sits under /var, a link to /private/var.
real_tmp="$TEST_TMPDIR/real_tmp"
mkdir -p "$real_tmp"
ln -s "$real_tmp" "$TEST_TMPDIR/linked_tmp"
(cd "$repo15" && TMPDIR="$TEST_TMPDIR/linked_tmp" PATH="$trust_stub_dir:$PATH" bash "$script") >/dev/null 2>&1 \
  || fail "lint under a symlinked TMPDIR was not trusted by its resolved path (recorded: $(cat "$TRUST_RECORD" 2>/dev/null))"
real_tmp_resolved=$(cd "$real_tmp" && pwd -P)
[[ $(cat "$TRUST_RECORD") == "$real_tmp_resolved"/* ]] \
  || fail "trusted path $(cat "$TRUST_RECORD") is not under the resolved $real_tmp_resolved"
pass "lint under a symlinked TMPDIR trusts the resolved scratch path"

# Scenario: no trust entry is written.
mise_record="$TEST_TMPDIR/mise_record"
cat > "$trust_stub_dir/mise" <<STUB_EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$mise_record"
exit 1
STUB_EOF
chmod +x "$trust_stub_dir/mise"
(cd "$repo15" && PATH="$trust_stub_dir:$PATH" bash "$script") >/dev/null 2>&1 \
  || fail "lint-staged-markdown failed while verifying it never calls mise"
[[ ! -e "$mise_record" ]] || fail "lint-staged-markdown called mise: $(cat "$mise_record")"
rm "$trust_stub_dir/mise"
unset TRUST_RECORD
pass "lint-staged-markdown never calls mise"

# Scenario: Staged secrets/bad.md with error exits 0 because outside globs
repo4="$TEST_TMPDIR/repo4"
make_test_repo "$repo4"
mkdir -p "$repo4/secrets"
printf "%s" "$bad_md_content" > "$repo4/secrets/bad.md"
git -C "$repo4" add secrets/bad.md
(cd "$repo4" && bash "$script") || fail "secrets/bad.md outside globs failed"
pass "staged secrets/bad.md exits 0 (outside config globs)"

# Scenario: Staged root README.md with error and .compound-engineering/artifacts/plans/bad.md with error each exit non-zero
repo5="$TEST_TMPDIR/repo5"
make_test_repo "$repo5"
printf "%s" "$bad_md_content" > "$repo5/README.md"
git -C "$repo5" add README.md
status=0
out=$( (cd "$repo5" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "root README.md with error exited 0"
[[ $out == *"README.md"* && $out == *"MD032"* ]] || fail "root README.md error output incorrect"

mkdir -p "$repo5/.compound-engineering/artifacts/plans"
git -C "$repo5" rm -q -f README.md
printf "%s" "$bad_md_content" > "$repo5/.compound-engineering/artifacts/plans/bad.md"
git -C "$repo5" add .compound-engineering/artifacts/plans/bad.md
status=0
out=$( (cd "$repo5" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "artifacts plan bad.md exited 0"
[[ $out == *".compound-engineering/artifacts/plans/bad.md"* && $out == *"MD032"* ]] || fail "artifacts plan bad.md error output incorrect"
pass "staged root README.md and .compound-engineering/artifacts/plans/*.md each exit non-zero on error"

# Scenario: The index holds a bad docs/x.md and the working tree a fixed copy: exits non-zero
repo6="$TEST_TMPDIR/repo6"
make_test_repo "$repo6"
mkdir -p "$repo6/docs"
printf "%s" "$bad_md_content" > "$repo6/docs/x.md"
git -C "$repo6" add docs/x.md
printf "%s" "$clean_md_content" > "$repo6/docs/x.md"
status=0
(cd "$repo6" && bash "$script") >/dev/null 2>&1 || status=$?
[[ $status -ne 0 ]] || fail "bad index with clean working tree exited 0"
pass "index holding bad docs/x.md with fixed working tree exits non-zero"

# Scenario: The index holds a clean docs/x.md and the working tree a broken copy: exits 0
repo7="$TEST_TMPDIR/repo7"
make_test_repo "$repo7"
mkdir -p "$repo7/docs"
printf "%s" "$clean_md_content" > "$repo7/docs/x.md"
git -C "$repo7" add docs/x.md
printf "%s" "$bad_md_content" > "$repo7/docs/x.md"
(cd "$repo7" && bash "$script") >/dev/null 2>&1 || fail "clean index with broken working tree exited non-zero"
pass "index holding clean docs/x.md with broken working tree exits 0"

# Scenario: A staged deletion of a Markdown file exits 0
repo8="$TEST_TMPDIR/repo8"
make_test_repo "$repo8"
mkdir -p "$repo8/docs"
printf "%s" "$clean_md_content" > "$repo8/docs/del.md"
git -C "$repo8" add docs/del.md
git -C "$repo8" commit -q -m "add del.md"
git -C "$repo8" rm -q docs/del.md
(cd "$repo8" && bash "$script") || fail "staged deletion of markdown file exited non-zero"
pass "staged deletion of a Markdown file exits 0"

# Scenario: A staged Markdown path containing a space is linted
repo9="$TEST_TMPDIR/repo9"
make_test_repo "$repo9"
mkdir -p "$repo9/docs"
printf "%s" "$bad_md_content" > "$repo9/docs/with space.md"
git -C "$repo9" add "docs/with space.md"
status=0
out=$( (cd "$repo9" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "path with space and error exited 0"
[[ $out == *"with space.md"* && $out == *"MD032"* ]] || fail "path with space output incorrect: $out"

printf "%s" "$clean_md_content" > "$repo9/docs/with space.md"
git -C "$repo9" add "docs/with space.md"
(cd "$repo9" && bash "$script") || fail "clean path with space failed"
pass "staged Markdown path containing a space is linted correctly"

# Scenario: In a repository with no commits yet, a staged bad docs/bad.md still fails
repo10="$TEST_TMPDIR/repo10"
mkdir -p "$repo10/docs"
git -C "$repo10" init -q
cp "$config" "$repo10/.markdownlint-cli2.jsonc"
git -C "$repo10" add .markdownlint-cli2.jsonc
printf "%s" "$bad_md_content" > "$repo10/docs/bad.md"
git -C "$repo10" add docs/bad.md
status=0
out=$( (cd "$repo10" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "unborn branch bad markdown exited 0"
[[ $out == *"docs/bad.md"* && $out == *"MD032"* ]] || fail "unborn branch output incorrect: $out"
pass "unborn repository with staged bad docs/bad.md fails"

# Scenario: a failing run leaves the index blob and the working-tree file unchanged
repo11="$TEST_TMPDIR/repo11"
make_test_repo "$repo11"
mkdir -p "$repo11/docs"
printf "%s" "$bad_md_content" > "$repo11/docs/bad.md"
git -C "$repo11" add docs/bad.md
wt_sha_before=$(git -C "$repo11" hash-object docs/bad.md)
idx_sha_before=$(git -C "$repo11" ls-files -s docs/bad.md | awk '{print $2}')
(cd "$repo11" && bash "$script") >/dev/null 2>&1 || true
wt_sha_after=$(git -C "$repo11" hash-object docs/bad.md)
idx_sha_after=$(git -C "$repo11" ls-files -s docs/bad.md | awk '{print $2}')
[[ "$wt_sha_before" == "$wt_sha_after" ]] || fail "working tree file modified by lint run"
[[ "$idx_sha_before" == "$idx_sha_after" ]] || fail "index blob modified by lint run"
pass "working-tree and index blobs byte-identical after failing run"

# Scenario: a staged Markdown symlink is linted through its target, as CI does
repo13="$TEST_TMPDIR/repo13"
make_test_repo "$repo13"
mkdir -p "$repo13/docs"
printf "%s" "$bad_md_content" > "$repo13/payload.txt"
ln -s ../payload.txt "$repo13/docs/linked.md"
git -C "$repo13" add payload.txt docs/linked.md
status=0
out=$( (cd "$repo13" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "staged Markdown symlink to a bad target exited 0"
[[ $out == *"docs/linked.md"* && $out == *"MD032"* ]] || fail "symlink output incorrect: $out"
pass "staged Markdown symlink is linted through its target"

# Scenario: a nested markdownlint config applies to the staged file beneath it
repo14="$TEST_TMPDIR/repo14"
make_test_repo "$repo14"
mkdir -p "$repo14/docs"
printf '{ "MD013": true }\n' > "$repo14/docs/.markdownlint.json"
git -C "$repo14" add docs/.markdownlint.json
git -C "$repo14" commit -q -m "nested config"
long_line=$(printf 'word %.0s' {1..30})
long_line=${long_line% }
printf "# Title\n\n%s\n" "$long_line" > "$repo14/docs/x.md"
git -C "$repo14" add docs/x.md
status=0
out=$( (cd "$repo14" && bash "$script") 2>&1 ) || status=$?
[[ $status -ne 0 ]] || fail "nested config enabling MD013 was ignored"
[[ $out == *"docs/x.md"* && $out == *"MD013"* ]] || fail "nested config output incorrect: $out"
pass "nested markdownlint config applies to staged files beneath it"

# The hook runs the mise task, so the task must run the script under test.
task_script=$(abspath "$(dirname "$script")/../$task_run")
[[ $task_script == "$script" ]] || fail "mise task lint-staged-markdown runs '$task_run', not $script"
pass "mise task lint-staged-markdown runs the script under test"

# Hook wiring and linked worktrees
repo12="$TEST_TMPDIR/repo12"
make_test_repo "$repo12"
mkdir -p "$repo12/.githooks"
cp "$hook" "$repo12/.githooks/pre-commit"
chmod +x "$repo12/.githooks/pre-commit"
git -C "$repo12" add .githooks/pre-commit
git -C "$repo12" commit -q -m "add hook"
git -C "$repo12" config core.hooksPath .githooks

# Setup stub mise that delegates lint-staged-markdown to $script
stub_mise_dir="$TEST_TMPDIR/stub_mise_bin"
mkdir -p "$stub_mise_dir"
cat > "$stub_mise_dir/mise" <<STUB_MISE_EOF
#!/bin/sh
if [ "\$1" = "run" ] && [ "\$2" = "lint-staged-markdown" ]; then
  exec bash "$task_script"
fi
echo "Unexpected mise arguments: \$*" >&2
exit 1
STUB_MISE_EOF
chmod +x "$stub_mise_dir/mise"

# Create linked worktree
wt1="$TEST_TMPDIR/wt1"
git -C "$repo12" worktree add -q -b wt1-branch "$wt1"

# Bad commit in linked worktree fails and prints rule
mkdir -p "$wt1/docs"
printf "%s" "$bad_md_content" > "$wt1/docs/bad.md"
git -C "$wt1" add docs/bad.md
commit_status=0
commit_out=$( PATH="$stub_mise_dir:$PATH" git -C "$wt1" commit -m "commit bad" 2>&1 ) || commit_status=$?
[[ $commit_status -ne 0 ]] || fail "git commit with bad markdown succeeded"
[[ $commit_out == *"MD032"* ]] || fail "git commit failure output missing MD032"
pass "git commit in linked worktree with staged bad markdown fails and prints rule"

# Clean commit in linked worktree succeeds
printf "%s" "$clean_md_content" > "$wt1/docs/bad.md"
git -C "$wt1" add docs/bad.md
PATH="$stub_mise_dir:$PATH" git -C "$wt1" commit -q -m "commit clean" || fail "git commit with clean markdown failed"
pass "git commit in linked worktree with clean markdown succeeds"

pass "all lint-staged-markdown scenarios passed"
