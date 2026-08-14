#!/usr/bin/env bash
set -euo pipefail

# Proves the R6 post-merge merge-method guard on disposable fixtures, never on a
# live merge:
#
#   * .ci/check-merge-commit-only.sh accepts only a two-parent result object,
#     rejects squash-, rebase-, and root-shaped results, keeps checking the
#     REST-resolved original result after a later base commit lands, resolves a
#     literal object id that a shallow checkout does not have yet, and rejects
#     every malformed value BEFORE any git process runs.
#   * .github/workflows/merge-commit-only.yml stays a read-only post-merge
#     surface: a merged `pull_request_target` close event only, exactly
#     contents/pull-requests read permission, no PR-code checkout, no push
#     trigger, no write-shaped call, and a REST lookup keyed by the event's
#     pull-request NUMBER whose returned SHA reaches the checker as a quoted
#     environment value.
#
# The workflow's own resolver block is extracted and executed against a stubbed
# read-only pull response, so the documented-empty event `merge_commit_sha` case
# is proved here rather than after a real merge.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check="$repo_root/.ci/check-merge-commit-only.sh"
workflow="$repo_root/.github/workflows/merge-commit-only.yml"
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/merge-commit-only-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'merge-commit-only gates: %s\n' "$*" >&2; exit 1; }

[[ -x $check ]] || fail "missing executable checker .ci/check-merge-commit-only.sh"
[[ -f $workflow ]] || fail 'missing .github/workflows/merge-commit-only.yml'
for tool in bun jq; do
  command -v "$tool" >/dev/null || fail "$tool is required to audit the workflow"
done

# Disposable Git only: no user/system config, no credential prompt, and every
# repository below lives under $scratch.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true LC_ALL=C \
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

git_log="$scratch/git-invocations"
gh_log="$scratch/gh-invocations"
mkdir -p "$scratch/bin"
real_git=$(type -P git) || fail 'git is required'

# A recording pass-through: proves which git commands the checker ran, and with
# which arguments, without changing its behaviour.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf "%%s\\n" "$*" >>%q\n' "$git_log"
  printf 'exec %q "$@"\n' "$real_git"
} >"$scratch/bin/git"
chmod +x "$scratch/bin/git"

origin="$scratch/origin"
g() { git -C "$origin" "$@"; }

git init -q -b main "$origin"
g config uploadpack.allowReachableSHA1InWant true
printf 'base\n' >"$origin/base.txt"
g add base.txt
g commit -q -m 'add base'
root_sha=$(g rev-parse HEAD)

g checkout -q -b feature/topology
printf 'feature\n' >"$origin/feature.txt"
g add feature.txt
g commit -q -m 'add feature'
feature_sha=$(g rev-parse HEAD)

g checkout -q main
g merge -q --no-ff feature/topology -m 'merge feature/topology'
merge_sha=$(g rev-parse HEAD)
[[ $(g cat-file commit "$merge_sha" | grep -c '^parent ') == 2 ]] ||
  fail 'fixture merge did not produce a two-parent commit'

g checkout -q -B landing/squashed "$root_sha"
g merge -q --squash feature/topology >/dev/null
g commit -q -m 'squashed pull request'
squash_sha=$(g rev-parse HEAD)

g checkout -q -B landing/rebased "$root_sha"
g cherry-pick "$feature_sha" >/dev/null
rebase_sha=$(g rev-parse HEAD)

# The base branch keeps moving after the merge lands; the guard must still check
# the result the REST lookup named, not this tip.
g checkout -q main
printf 'later\n' >"$origin/later.txt"
g add later.txt
g commit -q -m 'add later base commit'
later_sha=$(g rev-parse HEAD)
[[ $later_sha != "$merge_sha" ]] || fail 'fixture later base commit did not advance main'
[[ $(g rev-parse main) == "$later_sha" ]] || fail 'fixture main is not at the later base commit'

tree_sha=$(g rev-parse "main^{tree}")
absent_sha=0123456789abcdef0123456789abcdef01234567
refs_before=$(g for-each-ref --format='%(refname) %(objectname)')

check_output=
run_check() {
  local repo=$1 value=$2 remote=${3-} rc=0
  : >"$git_log"
  if [[ $value == '<unset>' ]]; then
    PATH="$scratch/bin:$PATH" MERGE_RESULT_REMOTE="${remote:-origin}" \
      env -u MERGE_RESULT_SHA "$check" "$repo" >"$scratch/out" 2>&1 || rc=$?
  else
    PATH="$scratch/bin:$PATH" MERGE_RESULT_REMOTE="${remote:-origin}" \
      MERGE_RESULT_SHA="$value" "$check" "$repo" >"$scratch/out" 2>&1 || rc=$?
  fi
  check_output=$(<"$scratch/out")
  return "$rc"
}

pass_case() {
  local label=$1 repo=$2 value=$3
  run_check "$repo" "$value" || fail "$label: rejected a compliant result ($check_output)"
  grep -qF 'is a two-parent merge commit' <<<"$check_output" ||
    fail "$label: pass did not report a two-parent result ($check_output)"
}

fail_case() {
  local label=$1 repo=$2 value=$3 needle=$4 remote=${5-}
  if run_check "$repo" "$value" "$remote"; then
    fail "$label: accepted a non-compliant result ($check_output)"
  fi
  grep -qF "$needle" <<<"$check_output" ||
    fail "$label: failure did not report '$needle' ($check_output)"
}

# The compliant landing, checked while main already points somewhere newer.
pass_case 'two-parent result' "$origin" "$merge_sha"
grep -qF "$merge_sha" "$git_log" || fail 'the pass path never inspected the resolved object'

fail_case 'later base tip' "$origin" "$later_sha" 'has one parent'
fail_case 'squash landing' "$origin" "$squash_sha" 'has one parent'
fail_case 'rebase landing' "$origin" "$rebase_sha" 'has one parent'
fail_case 'root commit' "$origin" "$root_sha" 'has no parent'
fail_case 'tree object' "$origin" "$tree_sha" 'is a tree, not a commit'
fail_case 'absent object' "$origin" "$absent_sha" 'is not present in this repository'

# Every malformed or missing value must fail with no git process at all: it can
# never be fetched, resolved, or parsed as a revision expression.
prevalidated_case() {
  local label=$1 value=$2 needle=$3
  fail_case "$label" "$origin" "$value" "$needle"
  if [[ -s $git_log ]]; then
    fail "$label: ran git before validating the resolved value ($(<"$git_log"))"
  fi
}

prevalidated_case 'missing value' '<unset>' 'no landed result commit was resolved'
prevalidated_case 'empty value' '' 'no landed result commit was resolved'
prevalidated_case 'uppercase hex' "${merge_sha^^}" 'is not lowercase canonical hex'
prevalidated_case 'short hex' "${merge_sha:0:39}" 'not a canonical object id'
prevalidated_case 'long hex' "${merge_sha}0" 'not a canonical object id'
prevalidated_case 'rev expression' 'HEAD^' 'is not lowercase canonical hex'
prevalidated_case 'peel expression' "${merge_sha}^{tree}" 'is not lowercase canonical hex'
prevalidated_case 'reflog expression' 'main@{1}' 'is not lowercase canonical hex'
prevalidated_case 'range expression' "..${merge_sha}" 'is not lowercase canonical hex'
prevalidated_case 'command separator' "$merge_sha; touch $scratch/pwned-separator" \
  'is not lowercase canonical hex'
prevalidated_case 'command substitution' "\$(touch $scratch/pwned-substitution)" \
  'is not lowercase canonical hex'
prevalidated_case 'option lookalike' '--upload-pack=touch' 'is not lowercase canonical hex'

if compgen -G "$scratch/pwned-*" >/dev/null; then
  fail 'a malformed resolved value executed a shell command'
fi

# A sha256-width value in a sha1 repository must be rejected by the advertised
# object format, and must not reach a git command line on the way there.
wide_sha=${merge_sha}${merge_sha:0:24}
fail_case 'wrong object-format width' "$origin" "$wide_sha" 'this sha1 repository advertises 40'
grep -qF 'rev-parse --show-object-format' "$git_log" ||
  fail 'the width check did not read the repository object format'
if grep -qF "$wide_sha" "$git_log"; then
  fail 'a wrong-width value reached a git command line'
fi

# A shallow base checkout does not have the result object: the checker must
# fetch that literal id and read its raw parent headers.
shallow="$scratch/shallow"
git clone -q --depth=1 "file://$origin" "$shallow"
if git -C "$shallow" cat-file -e "$merge_sha" 2>/dev/null; then
  fail 'fixture shallow clone already contains the merge result'
fi
pass_case 'shallow fetch of the literal result object' "$shallow" "$merge_sha"
grep -qE "fetch .*--depth=1 origin $merge_sha" "$git_log" ||
  fail 'the shallow path did not fetch the literal result object'
[[ -z $(git -C "$shallow" log -1 --format=%P "$merge_sha") ]] ||
  fail 'fixture no longer proves the shallow graft hides parents from traversal'

broken="$scratch/broken-remote"
git clone -q --depth=1 "file://$origin" "$broken"
git -C "$broken" remote set-url origin "$scratch/no-such-repository"
fail_case 'unfetchable result' "$broken" "$absent_sha" 'cannot fetch the resolved result object'

detached="$scratch/no-remote"
git init -q -b main "$detached"
fail_case 'no remote and no object' "$detached" "$absent_sha" 'is not present in this repository'

[[ $(g for-each-ref --format='%(refname) %(objectname)') == "$refs_before" ]] ||
  fail 'the checker changed a ref in the fixture repository'
[[ -z $(g status --porcelain) ]] || fail 'the checker wrote into the fixture worktree'
[[ $(g rev-parse main) == "$later_sha" ]] || fail 'the checker moved the fixture base branch'

# Workflow shape: parsed, not grepped, so a restructured trigger, an added
# permission, or a PR-code checkout cannot slip through as matching text.
audit="$scratch/workflow-audit.js"
cat >"$audit" <<'JS'
const fs = require("node:fs");
const [path] = process.argv.slice(2);
const text = fs.readFileSync(path, "utf8");
const workflow = Bun.YAML.parse(text);
const problems = [];
const want = (ok, message) => { if (!ok) problems.push(message); };
const shape = (value) => JSON.stringify(value);

want(shape(workflow.on) === shape({ pull_request_target: { types: ["closed"] } }),
  `trigger set is ${shape(workflow.on)}, not a pull_request_target closed-only trigger`);
want(shape(workflow.permissions) === shape({ contents: "read", "pull-requests": "read" }),
  `permissions are ${shape(workflow.permissions)}, not exactly contents/pull-requests read`);

const jobs = Object.entries(workflow.jobs ?? {});
want(jobs.length === 1, `expected one job, found ${jobs.length}`);
for (const [name, job] of jobs) {
  want(job.if === "github.event.pull_request.merged == true",
    `job ${name} predicate is ${shape(job.if)}, not the documented merged predicate`);
  want(job.permissions === undefined, `job ${name} re-declares permissions`);
  const steps = job.steps ?? [];
  for (const step of steps) {
    const label = step.name ?? step.uses ?? "an unnamed step";
    for (const input of ["ref", "repository", "token", "ssh-key"]) {
      want(!(input in (step.with ?? {})), `${label} passes \`${input}\` to its checkout`);
    }
  }
  const runs = steps.filter((step) => typeof step.run === "string");
  const body = runs.map((step) => step.run).join("\n");
  for (const write of [/git\s+push/, /git\s+commit/, /git\s+tag/, /gh\s+pr\s/, /gh\s+issue\s/,
    /--method\s/, /(^|\s)-X\s/, /gh\s+api\s+\S+\s+-f\s/]) {
    want(!write.test(body), `a step runs a write-shaped command matching ${write}`);
  }
  const checker = runs.find((step) => step.run.includes(".ci/check-merge-commit-only.sh"));
  want(checker !== undefined, "no step runs .ci/check-merge-commit-only.sh");
  if (checker) {
    want(checker.env?.MERGE_RESULT_SHA === "${{ steps.resolve.outputs.merge_result_sha }}",
      `the checker step receives ${shape(checker.env?.MERGE_RESULT_SHA)}, not the resolver output`);
    want(/MERGE_RESULT_SHA: "\$\{\{ steps\.resolve\.outputs\.merge_result_sha \}\}"/.test(text),
      "the resolved SHA is not passed as a quoted environment value");
  }
  const resolver = steps.find((step) => step.id === "resolve");
  want(resolver !== undefined, "no step resolves the landed result commit");
  if (resolver) {
    want(resolver.env?.PR_NUMBER === "${{ github.event.pull_request.number }}",
      `the resolver keys its lookup on ${shape(resolver.env?.PR_NUMBER)}, not the event number`);
    want(/gh api "repos\/\$\{GH_REPO\}\/pulls\/\$\{PR_NUMBER\}"/.test(resolver.run),
      "the resolver does not query the read-only pull endpoint by event number");
    want(/--jq\s+['"]\.merge_commit_sha\s*\/\/\s*""['"]/.test(resolver.run),
      'the resolver does not select `.merge_commit_sha // ""` from the REST response');
  }
}

for (const [pattern, message] of [
  [/pull_request\.merge_commit_sha/, "reads the event payload's merge_commit_sha"],
  [/pull_request\.head/, "references pull-request head code"],
  [/refs\/pull\//, "references a refs/pull ref"],
  [/id-token/, "requests an identity token"],
  [/\bwrite\b/, "mentions a write permission"],
]) {
  want(!pattern.test(text), `the workflow ${message}`);
}

for (const problem of problems) process.stderr.write(`workflow audit: ${problem}\n`);
process.exit(problems.length === 0 ? 0 : 1);
JS
bun "$audit" "$workflow" ||
  fail 'the post-merge workflow is not a read-only merged-close guard'

# The merged predicate decides invocation. Translate the workflow's own
# expression into jq and evaluate it against event payloads.
predicate=$(sed -n 's/^[[:space:]]*if:[[:space:]]*//p' "$workflow")
[[ -n $predicate ]] || fail 'the workflow job has no invocation predicate'
predicate_jq=${predicate//github.event./.}
evaluate_predicate() {
  local payload=$1
  printf '%s\n' "$payload" >"$scratch/event.json"
  jq -r "$predicate_jq" "$scratch/event.json"
}

merged_payload='{"action":"closed","pull_request":{"number":42,"merged":true,"merge_commit_sha":null}}'
unmerged_payload='{"action":"closed","pull_request":{"number":42,"merged":false,"merge_commit_sha":null}}'
push_payload='{"ref":"refs/heads/main","commits":[{"id":"deadbeef"}]}'

[[ $(evaluate_predicate "$merged_payload") == true ]] ||
  fail 'the predicate does not invoke the guard for a merged close event'
[[ $(evaluate_predicate "$unmerged_payload") == false ]] ||
  fail 'the predicate invokes the guard for an unmerged closed pull request'
[[ $(evaluate_predicate "$push_payload") != true ]] ||
  fail 'the predicate invokes the guard for a direct push payload'

# The resolver runs verbatim from the workflow against a stubbed pull response.
resolver="$scratch/resolver.sh"
[[ $(grep -c '# resolver:begin' "$workflow") == 1 && $(grep -c '# resolver:end' "$workflow") == 1 ]] ||
  fail 'the workflow resolver block markers changed'
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  sed -n '/# resolver:begin/,/# resolver:end/p' "$workflow" | sed 's/^ \{10\}//'
} >"$resolver"
chmod +x "$resolver"
grep -qF 'gh api' "$resolver" || fail 'the extracted resolver does not query the pull endpoint'
if grep -qE 'GITHUB_EVENT_PATH|event\.pull_request\.merge_commit_sha' "$resolver"; then
  fail 'the resolver reads the event payload merge SHA instead of the REST result'
fi

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'printf "%%s\\n" "$*" >>%q\n' "$gh_log"
  printf '%s\n' '[[ ${STUB_GH_STATUS:-0} -eq 0 ]] || exit "${STUB_GH_STATUS}"'
  printf '%s\n' 'printf "%s" "${STUB_GH_BODY-}"'
} >"$scratch/bin/gh"
chmod +x "$scratch/bin/gh"

# The event payload's own merge SHA is null here, as GitHub documents for merged
# `pull_request` payloads: resolution must come from the stubbed REST response.
printf '%s\n' "$merged_payload" >"$scratch/merged-event.json"
resolver_output="$scratch/resolver-output"
resolver_status=0
run_resolver() {
  local number=$1 body=$2 status=$3 rc=0
  : >"$gh_log"
  : >"$resolver_output"
  PATH="$scratch/bin:$PATH" \
    GH_REPO=fixture-owner/fixture-repo PR_NUMBER="$number" \
    GITHUB_EVENT_PATH="$scratch/merged-event.json" \
    GITHUB_OUTPUT="$resolver_output" \
    STUB_GH_BODY="$body" STUB_GH_STATUS="$status" \
    "$resolver" >"$scratch/resolver-log" 2>&1 || rc=$?
  resolver_status=$rc
  check_output=$(<"$scratch/resolver-log")
  return 0
}

run_resolver 42 "$merge_sha" 0
[[ $resolver_status -eq 0 ]] || fail "the resolver failed on a valid REST result ($check_output)"
[[ $(<"$resolver_output") == "merge_result_sha=$merge_sha" ]] ||
  fail "the resolver did not publish the REST merge_commit_sha ($(<"$resolver_output"))"
grep -qF 'api repos/fixture-owner/fixture-repo/pulls/42' "$gh_log" ||
  fail "the resolver did not look up the event pull-request number ($(<"$gh_log"))"
if grep -qE -- '(--method|-X )' "$gh_log"; then
  fail 'the resolver issued a non-read REST call'
fi

resolved_sha=$(sed -n 's/^merge_result_sha=//p' "$resolver_output")
pass_case 'resolver output feeds the checker' "$origin" "$resolved_sha"
fail_case 'resolver output cannot rescue a squash landing' "$origin" "$squash_sha" 'has one parent'

resolver_fails() {
  local label=$1 number=$2 body=$3 status=$4 needle=$5
  run_resolver "$number" "$body" "$status"
  [[ $resolver_status -ne 0 ]] || fail "$label: the resolver reported success"
  grep -qF "$needle" <<<"$check_output" ||
    fail "$label: failure did not report '$needle' ($check_output)"
  [[ ! -s $resolver_output ]] ||
    fail "$label: the resolver still published a step output ($(<"$resolver_output"))"
}

resolver_fails 'missing event number' '' "$merge_sha" 0 'carried no pull-request number'
[[ ! -s $gh_log ]] || fail 'the resolver queried REST without an event pull-request number'
resolver_fails 'empty REST result' 42 '' 0 'reported no usable merge_commit_sha'
resolver_fails 'multi-line REST result' 42 "$merge_sha"$'\n'"$squash_sha" 0 \
  'reported no usable merge_commit_sha'
resolver_fails 'failed REST lookup' 42 "$merge_sha" 1 'pull lookup for #42 failed'

printf '%s\n' 'merge-commit-only gates passed'
