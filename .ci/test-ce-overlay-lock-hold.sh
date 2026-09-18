#!/usr/bin/env bash
set -euo pipefail

# Offline verification of the lock job's compound-engineering hold-back:
# .ci/ce-overlay-lock-hold.sh, the commit and push steps of
# .github/workflows/refresh-release-lock.yml, and the static wiring check
# .ci/check-ce-overlay-wiring.sh.
#
# HOLD SCRIPT, against the real gate, driver, and release-lock CLI with fixture
# upstream trees (--pristine-dir) and a seeded fixture overlay: a valid candidate
# keeps the new entry, stamps base.json, and passes the pinned-mode gate; an
# invalid candidate (a changed pre-image, a collision, a removed file) restores
# only the CE entry, reports a rebase candidate, and leaves the overlay untouched;
# an unreachable upstream (a stub curl) restores without a candidate and writes a
# notice; the committed lock comes from `git show HEAD:` when no file is given; a
# held-back real lock still passes .ci/check-release-lock-digests.sh.
# HOLD SCRIPT, against a stub gate and driver: an unchanged, older, or malformed
# version never calls the gate; the gate and stamp receive the right arguments in
# the right order; a failed pinned-mode run rolls the stamp back; each gate status
# maps to the right result; a gate crash fails the script.
# WORKFLOW STEPS: the commit and push steps run from the workflow file against a
# scratch repository and a local bare remote. Nothing to commit, an allowlisted
# change, and a change outside the allowlist (refused at commit and at push);
# a rejected push fails with the message that names the App bypass.
# WIRING CHECK: it passes on the repository's workflows and rejects each mutation
# of the lock workflow that it exists to catch.

root=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlay-lock-hold.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# shellcheck source=.ci/lib/ce-overlay.sh
source "$root/.ci/lib/ce-overlay.sh"
CEO_SCRATCH=$scratch
CEO_REPORT="$scratch/report"
: >"$CEO_REPORT"
ceo_git_prepare "$scratch/git-home"

hold="$root/.ci/ce-overlay-lock-hold.sh"
gate="$root/.ci/check-ce-overlay-patches.sh"
driver="$root/.ci/ce-overlay-rebase.sh"
wiring="$root/.ci/check-ce-overlay-wiring.sh"
digests="$root/.ci/check-release-lock-digests.sh"
workflow="$root/.github/workflows/refresh-release-lock.yml"
fx="$root/.ci/fixtures/ce-overlays"

fail() {
  printf 'test-ce-overlay-lock-hold: %s\n' "$*" >&2
  exit 1
}

pass() { printf 'test-ce-overlay-lock-hold: ok - %s\n' "$*"; }

for tool in chezmoi bun jq git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
yaml_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    yaml_python=$candidate
    break
  fi
done
[[ -n $yaml_python ]] || fail 'no python3 with PyYAML found'

tag_old=compound-engineering-v3.26.3
tag_new=compound-engineering-v3.26.4
source_allowed=everyinc/compound-engineering-plugin
k_int=skills/ce-sweep/references/interview.md
k_persona=skills/ce-sweep/references/sources/gitlab-issues.md
k_plan=skills/ce-plan/scripts/elevation-dispatch.sh
k_brain=skills/ce-brainstorm/scripts/elevation-dispatch.sh
keys=("$k_int" "$k_persona" "$k_plan" "$k_brain")

rc=0
out=''
err=''
run() {
  rc=0
  out=$("$@" 2>"$scratch/stderr") || rc=$?
  err=$(<"$scratch/stderr")
}

# --- fixtures ----------------------------------------------------------------

effort=$(ceo_authoring_effort "$root") || fail 'could not render the roster authoring effort'

materialize() { # <fixture subdirectory> <dest>
  local src=$fx/$1 dest=$2 file rel content
  while IFS= read -r -d '' file; do
    rel=${file#"$src"/}
    mkdir -p -- "$dest/$(dirname -- "$rel")"
    content=$(
      cat -- "$file"
      printf x
    )
    content=${content%x}
    printf '%s' "${content//@AUTHORING_EFFORT@/$effort}" >"$dest/$rel"
    case $rel in
      */elevation-dispatch.sh) chmod 0755 "$dest/$rel" ;;
      *) chmod 0644 "$dest/$rel" ;;
    esac
  done < <(find "$src" -type f -print0 | sort -z)
}

old="$scratch/upstream-old"
post="$scratch/postimage"
materialize upstream-old "$old"
materialize postimage "$post"

changed="$scratch/up-changed"
cp -Rp -- "$old" "$changed"
{
  head -n 1 "$old/$k_int"
  printf 'An upstream edit that moves the recorded pre-image.\n'
  tail -n +2 "$old/$k_int"
} >"$changed/$k_int"

shipped="$scratch/up-collision"
cp -Rp -- "$old" "$shipped"
mkdir -p -- "$shipped/$(dirname -- "$k_persona")"
printf 'upstream persona\n' >"$shipped/$k_persona"

removed="$scratch/up-removed"
cp -Rp -- "$old" "$removed"
rm -- "$removed/$k_brain"

write_lock() { # <file> <compound-engineering version> <other tool version>
  jq -n --arg ce "$2" --arg other "$3" --arg source "$source_allowed" '
    {releases: {tools: {
      "compound-engineering": {kind: "githubRelease", source: $source, version: $ce},
      other: {kind: "githubRelease", source: "owner/other", version: $other}}}}' >"$1"
}

lock_seed="$scratch/lock-seed.json"
write_lock "$lock_seed" "$tag_old" 1.0.0
ov="$scratch/overlay"
posts=()
for key in "${keys[@]}"; do posts+=(--post "$key=$post/$key"); done
run "$driver" seed --overlay-dir "$ov" --lock "$lock_seed" --pristine-dir "$old" --target-tag "$tag_old" "${posts[@]}"
[[ $rc == 0 ]] || fail "could not seed the fixture overlay ($rc): $err"

snapshot() { # <dir>
  local file
  while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(ceo_sha256 "$1/$file")"
  done < <(cd -- "$1" && find . -type f | sort)
}

overlay_before=$(snapshot "$ov")

# case_dir <name> <committed ce> <committed other> <working ce> <working other>
case_dir() {
  local dir="$scratch/case-$1"
  mkdir -p -- "$dir"
  cp -Rp -- "$ov" "$dir/overlay"
  write_lock "$dir/committed.json" "$2" "$3"
  write_lock "$dir/lock.json" "$4" "$5"
  printf '%s' "$dir"
}

ce_version() { jq -r '.releases.tools["compound-engineering"].version // "absent"' "$1"; }
other_version() { jq -r '.releases.tools.other.version' "$1"; }

hold_case() { # <dir> <pristine dir> [env assignments...]
  local dir=$1 pristine=$2
  shift 2
  run env "$@" "$hold" --lock "$dir/lock.json" --committed-lock "$dir/committed.json" \
    --overlay-dir "$dir/overlay" --pristine-dir "$pristine"
}

expect_line() { # <label> <expected stdout line>
  [[ $rc == 0 ]] || fail "$1: status $rc: $err"
  [[ $out == "$2" ]] || fail "$1: stdout was '$out', want '$2' ($err)"
  pass "$1"
}

line() { # <result> <candidate> <class> <resolved> <pin>
  printf 'result=%s candidate=%s class=%s resolved=%s pin=%s' "$1" "$2" "$3" "$4" "$5"
}

# --- hold script against the real gate ---------------------------------------

# AE1
dir=$(case_dir valid "$tag_old" 1.0.0 "$tag_new" 2.0.0)
hold_case "$dir" "$old"
expect_line 'a valid candidate advances the entry' "$(line valid no valid "$tag_new" "$tag_old")"
[[ $(ce_version "$dir/lock.json") == "$tag_new" ]] || fail 'a valid candidate lost the new CE entry'
[[ $(other_version "$dir/lock.json") == 2.0.0 ]] || fail 'a valid candidate changed another tool'
[[ $(jq -r .version "$dir/overlay/base.json") == "$tag_new" ]] || fail 'base.json was not stamped to the new tag'
[[ $(jq -S 'del(.version)' "$dir/overlay/base.json") == $(jq -S 'del(.version)' "$ov/base.json") ]] ||
  fail 'the stamp changed more than the tag'
[[ $(snapshot "$dir/overlay/patches") == $(snapshot "$ov/patches") ]] || fail 'the stamp changed a patch'
run "$gate" --overlay-dir "$dir/overlay" --lock "$dir/lock.json" --pristine-dir "$old"
[[ $rc == 0 ]] || fail "the pinned-mode gate rejects the stamped result ($rc): $err"
pass 'the stamped result passes the pinned-mode gate'

# AE2: a CE-only change, so the restored lock equals the committed one byte for byte
dir=$(case_dir preimage "$tag_old" 1.0.0 "$tag_new" 1.0.0)
hold_case "$dir" "$changed"
expect_line 'a changed pre-image holds the entry back and reports a candidate' \
  "$(line held yes preimage-mismatch "$tag_new" "$tag_old")"
cmp -s "$dir/lock.json" "$dir/committed.json" || fail 'a CE-only restore differs from the committed lock'
[[ $(snapshot "$dir/overlay") == "$overlay_before" ]] || fail 'an invalid candidate changed the overlay directory'
pass 'a CE-only restore is byte-identical to the committed lock and leaves the overlay alone'

dir=$(case_dir preimage-other "$tag_old" 1.0.0 "$tag_new" 2.0.0)
hold_case "$dir" "$changed"
expect_line 'a held-back release still commits the other tools' \
  "$(line held yes preimage-mismatch "$tag_new" "$tag_old")"
[[ $(ce_version "$dir/lock.json") == "$tag_old" && $(other_version "$dir/lock.json") == 2.0.0 ]] ||
  fail 'the restore dropped the other tool update'

# AE6
dir=$(case_dir collision "$tag_old" 1.0.0 "$tag_new" 1.0.0)
hold_case "$dir" "$shipped"
expect_line 'upstream shipping an added path is a collision candidate' \
  "$(line held yes collision "$tag_new" "$tag_old")"
[[ $(snapshot "$dir/overlay") == "$overlay_before" ]] || fail 'a collision changed the overlay directory'

dir=$(case_dir removed "$tag_old" 1.0.0 "$tag_new" 1.0.0)
hold_case "$dir" "$removed"
expect_line 'a removed patched file is a candidate' \
  "$(line held yes removed-upstream "$tag_new" "$tag_old")"

# an unreachable upstream
stub_bin="$scratch/stub-bin"
mkdir -p -- "$stub_bin"
cat >"$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CURL_LOG"
exit 7
STUB
chmod 0755 "$stub_bin/curl"
dir=$(case_dir unavailable "$tag_old" 1.0.0 "$tag_new" 2.0.0)
run env PATH="$stub_bin:$PATH" STUB_CURL_LOG="$scratch/curl.log" CE_OVERLAY_FETCH_RETRY_DELAY=0 \
  GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$dir/summary.md" \
  "$hold" --lock "$dir/lock.json" --committed-lock "$dir/committed.json" --overlay-dir "$dir/overlay"
expect_line 'an unreachable upstream restores without a candidate' \
  "$(line held no unavailable "$tag_new" "$tag_old")"
grep -qF "/archive/refs/tags/$tag_new.tar.gz" "$scratch/curl.log" || fail 'the gate did not request the candidate tag'
[[ $(ce_version "$dir/lock.json") == "$tag_old" && $(other_version "$dir/lock.json") == 2.0.0 ]] ||
  fail 'an unavailable upstream did not restore only the CE entry'
[[ $(snapshot "$dir/overlay") == "$overlay_before" ]] || fail 'an unavailable upstream changed the overlay directory'
grep -qF '::notice' <<<"$err" || fail 'a hold-back wrote no workflow notice'
grep -qF "$tag_new" "$dir/summary.md" || fail 'a hold-back wrote no job-summary notice'
pass 'a hold-back writes a notice and a job-summary entry'

# the committed lock defaults to `git show HEAD:`
repo="$scratch/gitrepo"
mkdir -p -- "$repo"
git_env=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)
env "${git_env[@]}" git -C "$repo" init -q -b main
write_lock "$repo/releases.json" "$tag_old" 1.0.0
env "${git_env[@]}" git -C "$repo" add releases.json
env "${git_env[@]}" git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -q -m init
write_lock "$repo/releases.json" "$tag_new" 1.0.0
mkdir -p -- "$scratch/case-git"
cp -Rp -- "$ov" "$scratch/case-git/overlay"
run env "${git_env[@]}" "$hold" --lock "$repo/releases.json" --overlay-dir "$scratch/case-git/overlay" --pristine-dir "$changed"
expect_line 'the committed lock comes from git HEAD' "$(line held yes preimage-mismatch "$tag_new" "$tag_old")"
[[ -z $(env "${git_env[@]}" git -C "$repo" status --porcelain) ]] || fail 'a CE-only hold-back left a change to commit'
pass 'a CE-only hold-back leaves nothing to commit'

# the held-back real lock passes the digest check
real_lock=$(join_source_state "$root" .chezmoidata/releases.json)
dir="$scratch/case-real"
mkdir -p -- "$dir"
cp -Rp -- "$ov" "$dir/overlay"
other_tool=$(jq -r '.releases.tools | keys[] | select(. != "compound-engineering")' "$real_lock" | head -n 1)
cp -- "$real_lock" "$dir/committed.json"
jq --arg other "$other_tool" '
  .releases.tools["compound-engineering"].version = "compound-engineering-v99.0.0"
  | .releases.tools[$other].version = "changed-by-test"' "$real_lock" >"$dir/lock.json"
hold_case "$dir" "$changed"
expect_line 'the real lock is held back' \
  "$(line held yes preimage-mismatch compound-engineering-v99.0.0 "$(ce_version "$real_lock")")"
[[ $(jq -r --arg other "$other_tool" '.releases.tools[$other].version' "$dir/lock.json") == changed-by-test ]] ||
  fail 'the held-back real lock lost the other tool update'
run "$digests" "$dir/lock.json"
[[ $rc == 0 ]] || fail "the held-back lock fails the digest check: $out $err"
pass 'a held-back lock passes the digest check'

# --- hold script against a stub gate and driver ------------------------------

stub_tree="$scratch/stub-tree"
mkdir -p -- "$stub_tree/.ci"
cp -Rp -- "$root/.ci/lib" "$stub_tree/.ci/lib"
cp -p -- "$hold" "$stub_tree/.ci/ce-overlay-lock-hold.sh"
ln -s -- "$root/packages" "$stub_tree/packages"
cat >"$stub_tree/.ci/check-ce-overlay-patches.sh" <<'STUB'
#!/usr/bin/env bash
printf 'gate %s\n' "$*" >>"$STUB_LOG"
mode=$STUB_GATE_PINNED
for arg in "$@"; do
  if [ "$arg" = --candidate-tag ]; then mode=$STUB_GATE_CANDIDATE; fi
done
case $mode in
  valid) echo class=valid; exit 0 ;;
  invalid) echo class=patch-conflict; exit 1 ;;
  unavailable) echo class=unavailable; exit 2 ;;
  *) exit 64 ;;
esac
STUB
cat >"$stub_tree/.ci/ce-overlay-rebase.sh" <<'STUB'
#!/usr/bin/env bash
printf 'driver %s\n' "$*" >>"$STUB_LOG"
shift
target=''
overlay=''
while [ $# -gt 0 ]; do
  case $1 in
    --target-tag) target=$2; shift 2 ;;
    --overlay-dir) overlay=$2; shift 2 ;;
    *) shift ;;
  esac
done
case ${STUB_STAMP:-ok} in
  ok)
    jq --arg v "$target" '.version = $v' "$overlay/base.json" >"$overlay/base.json.new"
    mv -f "$overlay/base.json.new" "$overlay/base.json"
    echo "stamped=$target"
    ;;
  refuse) exit 1 ;;
  unavailable) exit 2 ;;
esac
STUB
chmod 0755 "$stub_tree/.ci/check-ce-overlay-patches.sh" "$stub_tree/.ci/ce-overlay-rebase.sh"
stub_hold="$stub_tree/.ci/ce-overlay-lock-hold.sh"
stub_log="$scratch/stub.log"

# stub_case <name> <committed ce> <working ce> [env assignments...]: sets $dir and
# the run results in this shell, so it must not run in a command substitution.
stub_case() {
  local name=$1 committed_ce=$2 working_ce=$3
  shift 3
  dir="$scratch/stub-$name"
  mkdir -p -- "$dir/overlay"
  jq -n --arg v "$tag_old" '{version: $v, paths: {}}' >"$dir/overlay/base.json"
  write_lock "$dir/committed.json" "$committed_ce" 1.0.0
  write_lock "$dir/lock.json" "$working_ce" 2.0.0
  : >"$stub_log"
  run env STUB_LOG="$stub_log" STUB_GATE_CANDIDATE=valid STUB_GATE_PINNED=valid "$@" \
    "$stub_hold" --lock "$dir/lock.json" --committed-lock "$dir/committed.json" \
    --overlay-dir "$dir/overlay" --pristine-dir "$scratch/pristine-passthrough"
}

# the gate is never called
stub_case unchanged "$tag_old" "$tag_old"
expect_line 'an unchanged version reports unchanged' "$(line unchanged no none "$tag_old" "$tag_old")"
[[ ! -s $stub_log ]] || fail "an unchanged version called the gate: $(<"$stub_log")"
[[ $(other_version "$dir/lock.json") == 2.0.0 ]] || fail 'an unchanged version touched the lock'

while IFS='|' read -r label committed_ce working_ce class; do
  stub_case "never-$label" "$committed_ce" "$working_ce"
  slug=$(printf '%s' "${working_ce:-none}" | tr -c 'A-Za-z0-9._+-' '_')
  expect_line "$label is restored without a candidate" "$(line held no "$class" "${slug:-none}" "$committed_ce")"
  [[ ! -s $stub_log ]] || fail "$label called the gate: $(<"$stub_log")"
  [[ $(ce_version "$dir/lock.json") == "$committed_ce" && $(other_version "$dir/lock.json") == 2.0.0 ]] ||
    fail "$label did not restore only the CE entry"
done <<EOF
a downgrade|compound-engineering-v3.26.3|compound-engineering-v3.26.2|not-newer
a lower major|compound-engineering-v3.0.0|compound-engineering-v2.99.99|not-newer
a numeric compare of a shorter number|compound-engineering-v3.26.10|compound-engineering-v3.26.9|not-newer
a version without a patch part|compound-engineering-v3.26.3|compound-engineering-v3.27|malformed-tag
a prerelease suffix|compound-engineering-v3.26.3|compound-engineering-v3.27.0-rc.1|malformed-tag
a tag without the prefix|compound-engineering-v3.26.3|v3.27.0|malformed-tag
a moving name|compound-engineering-v3.26.3|latest|malformed-tag
EOF

# a resolved version with a missing entry restores it
dir="$scratch/stub-missing"
mkdir -p -- "$dir/overlay"
jq -n --arg v "$tag_old" '{version: $v, paths: {}}' >"$dir/overlay/base.json"
write_lock "$dir/committed.json" "$tag_old" 1.0.0
jq 'del(.releases.tools["compound-engineering"])' "$dir/committed.json" >"$dir/lock.json"
: >"$stub_log"
run env STUB_LOG="$stub_log" "$stub_hold" --lock "$dir/lock.json" --committed-lock "$dir/committed.json" --overlay-dir "$dir/overlay"
expect_line 'a lock with no CE entry is restored' "$(line held no malformed-tag none "$tag_old")"
[[ ! -s $stub_log && $(ce_version "$dir/lock.json") == "$tag_old" ]] || fail 'a missing entry was not restored without the gate'

# a numeric semver compare, not a text compare
stub_case numeric "compound-engineering-v3.9.0" "compound-engineering-v3.10.0"
expect_line 'v3.10.0 is newer than v3.9.0' \
  "$(line valid no valid compound-engineering-v3.10.0 compound-engineering-v3.9.0)"

# the gate and the stamp get the right arguments in the right order
stub_case order "$tag_old" "$tag_new"
expect_line 'a valid candidate through the stub gate' "$(line valid no valid "$tag_new" "$tag_old")"
[[ $(wc -l <"$stub_log" | tr -d ' ') == 3 ]] || fail "expected gate, stamp, gate; got: $(<"$stub_log")"
sed -n 1p "$stub_log" | grep -q -- "^gate .*--candidate-tag $tag_new" || fail 'the first gate call is not in candidate mode'
sed -n 2p "$stub_log" | grep -q -- "^driver stamp .*--target-tag $tag_new" || fail 'the second call is not the stamp'
sed -n 3p "$stub_log" | grep -q -- '^gate ' || fail 'the third call is not the gate'
if sed -n 3p "$stub_log" | grep -q -- '--candidate-tag'; then fail 'the re-run is not in pinned mode'; fi
while IFS= read -r call; do
  grep -qF -- "--pristine-dir $scratch/pristine-passthrough" <<<"$call" || fail "a call lacks the pristine-dir passthrough: $call"
  grep -qF -- "--overlay-dir $dir/overlay" <<<"$call" || fail "a call lacks the overlay dir: $call"
  grep -qF -- "--lock $dir/lock.json" <<<"$call" || fail "a call lacks the working lock: $call"
done <"$stub_log"
[[ $(jq -r .version "$dir/overlay/base.json") == "$tag_new" ]] || fail 'the stamp did not reach base.json'
pass 'the gate and the stamp receive the right arguments in the right order'

# a failed pinned-mode run rolls the stamp back
stub_case pinned-invalid "$tag_old" "$tag_new" STUB_GATE_PINNED=invalid
expect_line 'a pinned-mode failure holds the release back as a candidate' \
  "$(line held yes patch-conflict "$tag_new" "$tag_old")"
[[ $(jq -r .version "$dir/overlay/base.json") == "$tag_old" ]] || fail 'the stamp was not rolled back'
[[ $(ce_version "$dir/lock.json") == "$tag_old" && $(other_version "$dir/lock.json") == 2.0.0 ]] ||
  fail 'a pinned-mode failure did not restore only the CE entry'
[[ ! -e $dir/overlay/base.json.rollback ]] || fail 'the rollback left a temporary file'

stub_case pinned-unavailable "$tag_old" "$tag_new" STUB_GATE_PINNED=unavailable
expect_line 'a pinned-mode outage holds the release back without a candidate' \
  "$(line held no unavailable "$tag_new" "$tag_old")"
[[ $(jq -r .version "$dir/overlay/base.json") == "$tag_old" ]] || fail 'the stamp was not rolled back after an outage'

stub_case stamp-refused "$tag_old" "$tag_new" STUB_STAMP=refuse
expect_line 'a refused stamp is a candidate' "$(line held yes stamp-refused "$tag_new" "$tag_old")"
[[ $(jq -r .version "$dir/overlay/base.json") == "$tag_old" ]] || fail 'a refused stamp changed base.json'

stub_case stamp-unavailable "$tag_old" "$tag_new" STUB_STAMP=unavailable
expect_line 'an unavailable stamp is not a candidate' "$(line held no unavailable "$tag_new" "$tag_old")"

stub_case candidate-invalid "$tag_old" "$tag_new" STUB_GATE_CANDIDATE=invalid
expect_line 'an invalid candidate is reported with the gate class' "$(line held yes patch-conflict "$tag_new" "$tag_old")"
[[ $(wc -l <"$stub_log" | tr -d ' ') == 1 ]] || fail 'an invalid candidate went on to stamp'

stub_case candidate-unavailable "$tag_old" "$tag_new" STUB_GATE_CANDIDATE=unavailable
expect_line 'an unavailable candidate is not reported as a candidate' \
  "$(line held no unavailable "$tag_new" "$tag_old")"

stub_case gate-crash "$tag_old" "$tag_new" STUB_GATE_CANDIDATE=crash
[[ $rc != 0 && -z $out ]] || fail "a gate crash must fail the script with no result line (rc $rc, out '$out')"
[[ $(ce_version "$dir/lock.json") == "$tag_new" ]] || fail 'a gate crash restored the entry instead of failing'
pass 'a gate crash fails the script'

# --- workflow steps: commit and push -----------------------------------------

step_script() { # <step id> <output file>
  "$yaml_python" - "$workflow" "$1" >"$2" <<'PYTHON'
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in document["jobs"].values():
    for step in job["steps"]:
        if step.get("id") == sys.argv[2]:
            sys.stdout.write(step["run"])
            sys.exit(0)
sys.exit(f"no step with id {sys.argv[2]}")
PYTHON
}

step_script commit "$scratch/commit-step.sh"
step_script push "$scratch/push-step.sh"

lock_rel=home/.chezmoidata/releases.json
base_rel=home/dot_local/share/compound-engineering-overlays/base.json
git_quiet=(env "${git_env[@]}")

new_work_tree() { # <name>: a repository with a bare origin, at one commit
  local work="$scratch/$1-work" remote="$scratch/$1-remote.git"
  mkdir -p -- "$work/.ci/lib" "$work/home/.chezmoidata" "$work/home/dot_local/share/compound-engineering-overlays"
  cp -- "$root/.ci/lib/source-root.sh" "$work/.ci/lib/source-root.sh"
  printf 'home\n' >"$work/.chezmoiroot"
  printf '{"releases":{}}\n' >"$work/$lock_rel"
  printf '{"version":"x"}\n' >"$work/$base_rel"
  printf 'tracked\n' >"$work/other.txt"
  "${git_quiet[@]}" git -C "$work" init -q -b main
  "${git_quiet[@]}" git -C "$work" add -A
  "${git_quiet[@]}" git -C "$work" -c user.name=test -c user.email=test@example.invalid commit -q -m init
  "${git_quiet[@]}" git init -q --bare -b main "$remote"
  "${git_quiet[@]}" git -C "$work" remote add origin "$remote"
  "${git_quiet[@]}" git -C "$work" push -q origin main
  printf '%s' "$work"
}

run_step() { # <work tree> <script> [env assignments...]
  local work=$1 script=$2
  shift 2
  step_output="$work.github-output"
  : >"$step_output"
  rc=0
  out=$(cd -- "$work" && env "${git_env[@]}" GITHUB_OUTPUT="$step_output" GITHUB_REF_NAME=main \
    PUSH_TOKEN=unused "$@" bash -e "$script" 2>&1) || rc=$?
  err=$out
}

head_of() { "${git_quiet[@]}" git -C "$1" rev-parse HEAD; }

work=$(new_work_tree nothing)
before=$(head_of "$work")
run_step "$work" "$scratch/commit-step.sh"
[[ $rc == 0 ]] || fail "the commit step failed with nothing to commit: $err"
grep -qx 'changed=false' "$step_output" || fail 'the commit step did not report nothing to commit'
[[ $(head_of "$work") == "$before" ]] || fail 'the commit step committed with nothing to commit'
pass 'the commit step commits nothing when nothing changed'

work=$(new_work_tree lock-only)
before=$(head_of "$work")
printf '{"releases":{"tools":{}}}\n' >"$work/$lock_rel"
run_step "$work" "$scratch/commit-step.sh"
[[ $rc == 0 ]] || fail "the commit step failed on a lock change: $err"
grep -qx 'changed=true' "$step_output" || fail 'the commit step did not report a change'
[[ $("${git_quiet[@]}" git -C "$work" rev-list --count "$before..HEAD") == 1 ]] || fail 'the commit step made no single commit'
[[ $("${git_quiet[@]}" git -C "$work" diff --name-only HEAD~1 HEAD) == "$lock_rel" ]] || fail 'the commit holds more than the lock'
run_step "$work" "$scratch/push-step.sh"
[[ $rc == 0 ]] || fail "the push step failed: $err"
[[ $("${git_quiet[@]}" git --git-dir "$scratch/lock-only-remote.git" rev-parse main) == "$(head_of "$work")" ]] ||
  fail 'the push step did not update the remote'
pass 'a lock change is committed and pushed'

work=$(new_work_tree lock-and-base)
printf '{"releases":{"tools":{}}}\n' >"$work/$lock_rel"
printf '{"version":"y"}\n' >"$work/$base_rel"
run_step "$work" "$scratch/commit-step.sh"
[[ $rc == 0 ]] || fail "the commit step failed on a lock and base.json change: $err"
[[ $("${git_quiet[@]}" git -C "$work" diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ') == "$lock_rel $base_rel " ]] ||
  fail 'the commit does not hold the lock and base.json'
pass 'the lock and base.json are committed together'

for stray in modified untracked; do
  work=$(new_work_tree "stray-$stray")
  before=$(head_of "$work")
  printf '{"releases":{"tools":{}}}\n' >"$work/$lock_rel"
  if [[ $stray == modified ]]; then
    printf 'changed\n' >"$work/other.txt"
  else
    printf 'new\n' >"$work/stray.txt"
  fi
  run_step "$work" "$scratch/commit-step.sh"
  [[ $rc != 0 ]] || fail "the commit step accepted a $stray path outside the allowlist"
  grep -qF 'Refusing to commit' <<<"$err" || fail "the refusal for a $stray path did not say so: $err"
  [[ $(head_of "$work") == "$before" ]] || fail "the commit step committed despite a $stray path"
done
pass 'the commit step refuses a change outside the allowlist'

work=$(new_work_tree stray-push)
remote_before=$("${git_quiet[@]}" git --git-dir "$scratch/stray-push-remote.git" rev-parse main)
printf 'sneaky\n' >"$work/other.txt"
printf '{"releases":{"tools":{}}}\n' >"$work/$lock_rel"
"${git_quiet[@]}" git -C "$work" add -A
"${git_quiet[@]}" git -C "$work" -c user.name=test -c user.email=test@example.invalid commit -q -m 'sneaky commit'
run_step "$work" "$scratch/push-step.sh"
[[ $rc != 0 ]] || fail 'the push step accepted a commit that changes a path outside the allowlist'
grep -qF 'Refusing to push' <<<"$err" || fail "the push refusal did not say so: $err"
[[ $("${git_quiet[@]}" git --git-dir "$scratch/stray-push-remote.git" rev-parse main) == "$remote_before" ]] ||
  fail 'the push step pushed a commit outside the allowlist'
pass 'the push step refuses a commit outside the allowlist'

work=$(new_work_tree rejected)
printf '{"releases":{"tools":{}}}\n' >"$work/$lock_rel"
run_step "$work" "$scratch/commit-step.sh"
other_clone="$scratch/rejected-other"
"${git_quiet[@]}" git clone -q "$scratch/rejected-remote.git" "$other_clone"
printf 'race\n' >"$other_clone/race.txt"
"${git_quiet[@]}" git -C "$other_clone" add race.txt
"${git_quiet[@]}" git -C "$other_clone" -c user.name=test -c user.email=test@example.invalid commit -q -m race
"${git_quiet[@]}" git -C "$other_clone" push -q origin main
run_step "$work" "$scratch/push-step.sh"
[[ $rc != 0 ]] || fail 'the push step succeeded against a moved remote'
grep -qF 'P3' <<<"$err" || fail "a rejected push does not name the ruleset bypass entry: $err"
grep -qF 'every tool' <<<"$err" || fail "a rejected push does not say the refresh of every tool stopped: $err"
pass 'a rejected push fails with the message that names the App bypass'

# --- wiring check ------------------------------------------------------------

wf_tree="$scratch/wiring-tree"
mkdir -p -- "$wf_tree/.github"
cp -Rp -- "$root/.github/workflows" "$wf_tree/.github/workflows"
lock_wf="$wf_tree/.github/workflows/refresh-release-lock.yml"
lock_wf_original=$(<"$lock_wf")

run "$wiring"
[[ $rc == 0 ]] || fail "the wiring check rejects the repository's workflows: $err"
run "$wiring" "$wf_tree"
[[ $rc == 0 ]] || fail "the wiring check rejects a copy of the repository's workflows: $err"
pass 'the wiring check accepts the repository workflows'

cat >"$scratch/mutate.py" <<'PYTHON'
import sys
import yaml

source, target, operation, *names = sys.argv[1:]
document = yaml.safe_load(open(source, encoding="utf-8"))
(job,) = document["jobs"].values()
steps = job["steps"]


def find(fragment):
    hits = [i for i, step in enumerate(steps) if fragment in str(step.get("name", ""))]
    if len(hits) != 1:
        sys.exit(f"{fragment!r} matches {len(hits)} steps")
    return hits[0]


if operation == "drop":
    del steps[find(names[0])]
elif operation == "swap":
    a, b = find(names[0]), find(names[1])
    steps[a], steps[b] = steps[b], steps[a]
elif operation == "append":
    steps.append({"name": names[0], "run": names[1]})
else:
    sys.exit(f"unknown operation {operation}")
with open(target, "w", encoding="utf-8") as handle:
    yaml.safe_dump(document, handle, sort_keys=False, width=10**6)
PYTHON

expect_rejected() { # <label> <expected failure text>
  run "$wiring" "$wf_tree"
  [[ $rc != 0 ]] || fail "wiring: $1 was accepted"
  grep -qF -- "$2" <<<"$err" || fail "wiring: $1 was rejected for the wrong reason: $err"
  printf '%s\n' "$lock_wf_original" >"$lock_wf"
  pass "wiring rejects $1"
}

mutate_text() { # <from> <to>
  [[ $lock_wf_original == *"$1"* ]] || fail "the workflow no longer contains the text this mutation needs: $1"
  printf '%s\n' "${lock_wf_original//"$1"/"$2"}" >"$lock_wf"
}

mutate_steps() { # <operation> <names...>
  "$yaml_python" "$scratch/mutate.py" "$lock_wf" "$lock_wf" "$@" || fail "mutation $* failed"
}

mutate_text $'    timeout-minutes: 15\n' ''
expect_rejected 'a job without a timeout' 'has no timeout-minutes'
mutate_text $'  actions: write\n' ''
expect_rejected 'a missing actions permission' 'holds permissions'
mutate_text 'persist-credentials: false' 'persist-credentials: true'
expect_rejected 'a checkout that persists credentials' 'without persist-credentials: false'
mutate_text $'          GATE_CLASS: ${{ steps.hold.outputs.class }}' $'          GATE_CLASS: ${{ steps.hold.outputs.class }}\n          LEAK: ${{ steps.app-token.outputs.token }}'
expect_rejected 'an App token read outside the push step' 'only the push step may use'
mutate_text $'          GATE_CLASS: ${{ steps.hold.outputs.class }}' $'          GATE_CLASS: ${{ steps.hold.outputs.class }}\n          LEAK: ${{ secrets.CE_LOCK_APP_PRIVATE_KEY }}'
expect_rejected 'an App private key read outside the mint step' 'only the mint step may use'
mutate_text "(steps.push.outcome == 'success' || steps.commit.outputs.changed == 'false')" 'always()'
expect_rejected 'a dispatch that runs after a failed push' 'status function'
mutate_text $'\n          && github.ref_name == github.event.repository.default_branch' ''
expect_rejected 'a dispatch on any branch' 'the default branch'
mutate_text 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' 'DEFAULT_BRANCH: main'
expect_rejected 'a dispatch ref that is not the default branch' "default branch does not come from"
mutate_text '${{ steps.app-token.outputs.token || secrets.GITHUB_TOKEN }}' '${{ steps.app-token.outputs.token }}'
expect_rejected 'a push with no GITHUB_TOKEN fallback' 'no GITHUB_TOKEN fallback'
mutate_text '@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0' '@v3'
expect_rejected 'an action pinned to a tag' 'is not pinned to a full commit SHA'
mutate_text ' # v3.2.0' ''
expect_rejected 'a SHA pin with no release tag' 'no release tag in a trailing comment'
mutate_steps swap 'Hold back compound-engineering' 'Validate lock architecture'
expect_rejected 'a digest check that runs before the hold step' 'steps must run in the order'
mutate_steps drop 'Install locked chezmoi'
expect_rejected 'a lock job that never installs chezmoi' 'chezmoi install step'
mutate_steps swap 'Mint the direct-push App token' 'Commit the lock and base.json'
expect_rejected 'an App token minted before the commit' 'minted after the commit'
mutate_steps append 'Open a pull request' 'gh pr create --title x --body y'
expect_rejected 'a lock job that opens a pull request' 'creates or merges a pull request'

printf '%s\n' "$lock_wf_original" >"$lock_wf"
cat >"$wf_tree/.github/workflows/gate-job.yml" <<'YAML'
name: Gate job
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run the upstream gate
        run: .ci/check-ce-overlay-patches.sh
YAML
expect_rejected 'a job that runs the gate without installing chezmoi' 'without installing chezmoi'
cat >"$wf_tree/.github/workflows/gate-job.yml" <<'YAML'
name: Gate job
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Install chezmoi
        run: echo install
      - name: Run the upstream gate
        run: .ci/check-ce-overlay-patches.sh
YAML
run "$wiring" "$wf_tree"
[[ $rc == 0 ]] || fail "a job that installs chezmoi first was rejected: $err"
pass 'wiring accepts a gate job that installs chezmoi first'

printf 'test-ce-overlay-lock-hold: all cases passed\n'
