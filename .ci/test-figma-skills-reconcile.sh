#!/usr/bin/env bash
# Isolated, network-free transaction proof for the official Figma skill reconciler.
set -euo pipefail

root=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/figma-skills-reconcile.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'figma reconcile fixture: %s\n' "$*" >&2; exit 1; }
for command in chezmoi jq; do command -v "$command" >/dev/null || fail "$command is required"; done

config="$scratch/empty.toml"; : >"$config"
script="$scratch/reconcile.sh"
chezmoi --config "$config" --source "$root" execute-template --file \
  "$root/.chezmoiscripts/70-agents/run_after_install-figma-skills.sh.tmpl" >"$script"
[[ -s $script ]] || fail 'POSIX reconciler did not render'
chmod 0700 "$script"
skills=()
while IFS= read -r skill; do skills[${#skills[@]}]=$skill; done < <(jq -er '.releases.tools["figma/mcp-server-guide"].skills[]' "$root/.chezmoidata/releases.json")
((${#skills[@]} >= 2)) || fail 'fixture requires at least two locked skills'
expected_json=$(printf '%s\n' "${skills[@]}" | jq -Rsc 'split("\n")[:-1]')
grep -F "readonly DESIRED_SKILLS_JSON='$expected_json'" "$script" >/dev/null || fail 'rendered inventory differs from lock'

case_root="$scratch/case"
home="$case_root/home"
stage="$case_root/stage"
state="$case_root/state/ownership.json"
live="$home/.agents/skills"
mkdir -p "$stage" "$live/personal-skill" "$live/figma-personal"
printf 'personal\n' >"$live/personal-skill/keep.txt"
printf 'unowned\n' >"$live/figma-personal/keep.txt"
make_stage() {
  rm -rf -- "$stage"; mkdir -p "$stage"
  local skill
  for skill in "${skills[@]}"; do
    mkdir -p "$stage/$skill/references" "$stage/$skill/assets"
    printf '# %s\n' "$skill" >"$stage/$skill/SKILL.md"
    printf 'sibling: ../%s/assets/icon.txt\n' "$skill" >"$stage/$skill/references/guide.md"
    printf 'asset %s\n' "$skill" >"$stage/$skill/assets/icon.txt"
  done
}
run_reconcile() {
  env HOME="$home" FIGMA_SKILLS_ROOT="$live" FIGMA_SKILLS_STAGE="$stage" \
    FIGMA_SKILLS_OWNERSHIP="$state" "$@" "$script"
}
manifest_skills() { jq -c '.skills' "$state"; }
snapshot() {
  (cd "$case_root" && find home state -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum) 2>/dev/null || true
}
make_stage

# First install, complete subtree preservation, and deterministic ownership.
run_reconcile
[[ $(manifest_skills) == "$expected_json" ]] || fail 'first install ownership differs from lock'
for skill in "${skills[@]}"; do
  [[ -f $live/$skill/SKILL.md && -f $live/$skill/references/guide.md && -f $live/$skill/assets/icon.txt ]] || fail "incomplete subtree for $skill"
done
[[ -f $live/personal-skill/keep.txt && -f $live/figma-personal/keep.txt ]] || fail 'unrelated sibling was removed'

# True no-op preserves representative mtimes and manifest bytes.
manifest_before=$(sha256sum "$state")
mtime_before=$(stat -c '%Y:%n' "$state" "$live/${skills[0]}/SKILL.md")
run_reconcile
[[ $(sha256sum "$state") == "$manifest_before" ]] || fail 'no-op rewrote ownership'
[[ $(stat -c '%Y:%n' "$state" "$live/${skills[0]}/SKILL.md") == "$mtime_before" ]] || fail 'no-op changed mtimes'

# Drift is repaired. A newly desired collision is adopted, and prior-manifest-only retirement removes no unrelated figma-* sibling.
printf 'tampered\n' >"$live/${skills[0]}/SKILL.md"
new_skill=${skills[$((${#skills[@]} - 1))]}
old_skills=$(printf '%s\n' "${skills[@]:0:${#skills[@]}-1}" | jq -Rsc 'split("\n")[:-1]')
printf '{"schema":"figma-skills-ownership/v1","transactionId":"prior-fixture","skills":%s}\n' "$old_skills" >"$state"
rm -rf -- "$live/$new_skill"; mkdir -p "$live/$new_skill"; printf 'collision\n' >"$live/$new_skill/user.txt"
mkdir -p "$live/figma-retired-unowned"; printf 'keep\n' >"$live/figma-retired-unowned/file"
run_reconcile
 grep -q '^# ' "$live/${skills[0]}/SKILL.md" || fail 'drift was not repaired'
[[ ! -e $live/$new_skill/user.txt && -f $live/$new_skill/SKILL.md ]] || fail 'desired collision was not adopted'
[[ -f $live/figma-retired-unowned/file ]] || fail 'prefix-wide deletion occurred'

# Prior-owned retirement is the sole removal authority.
retired=figma-fixture-retired
mkdir -p "$live/$retired"; printf 'retired\n' >"$live/$retired/SKILL.md"
jq --arg retired "$retired" '.skills += [$retired] | .skills |= sort' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
run_reconcile
[[ ! -e $live/$retired ]] || fail 'prior-owned retired skill was preserved'

# Invalid staging, ownership, destination type, links, and case ambiguity fail before managed mutation.
expect_preflight_failure() {
  local label=$1; shift
  local before after
  before=$(snapshot)
  if run_reconcile "$@" >"$scratch/$label.out" 2>"$scratch/$label.err"; then fail "$label unexpectedly succeeded"; fi
  after=$(snapshot)
  [[ $before == "$after" ]] || fail "$label mutated managed state"
}
rm -f "$stage/${skills[0]}/SKILL.md"; expect_preflight_failure missing-stage; make_stage
rm -rf -- "$stage"; mkdir -p "$stage"; expect_preflight_failure empty-stage; make_stage
mkdir -p "$stage/extra"; printf x >"$stage/extra/SKILL.md"; expect_preflight_failure extra-stage; make_stage
ln -s SKILL.md "$stage/${skills[0]}/linked"; expect_preflight_failure linked-stage; make_stage
cp -p "$state" "$scratch/ownership.saved"; rm "$state"; expect_preflight_failure missing-ownership; mv "$scratch/ownership.saved" "$state"
printf '{bad\n' >"$state"; expect_preflight_failure corrupt-ownership
printf '{"schema":"figma-skills-ownership/v0","transactionId":"x","skills":[]}\n' >"$state"; expect_preflight_failure schema-ownership
printf '{"schema":"figma-skills-ownership/v1","transactionId":"reset","skills":%s}\n' "$expected_json" >"$state"
rm -rf "$live/${skills[0]}"; printf 'file\n' >"$live/${skills[0]}"; expect_preflight_failure destination-file
rm -f "$live/${skills[0]}"; cp -R "$stage/${skills[0]}" "$live/${skills[0]}"
upper_name=$(printf '%s' "${skills[0]}" | tr '[:lower:]' '[:upper:]')
mkdir -p "$live/$upper_name"; expect_preflight_failure case-ambiguity; rm -rf "$live/$upper_name"
referent="$scratch/referent"; mkdir -p "$referent"; rm -rf "$live/${skills[0]}"; ln -s "$referent" "$live/${skills[0]}"; expect_preflight_failure destination-link
rm "$live/${skills[0]}"; cp -R "$stage/${skills[0]}" "$live/${skills[0]}"

# Exclusive lock rejects a second entrant.
run_reconcile FIGMA_SKILLS_HOLD_LOCK_SECONDS=2 >"$scratch/holder.out" 2>"$scratch/holder.err" & holder=$!
for _ in {1..50}; do [[ -e $state.lock ]] && break; sleep .05; done
if run_reconcile >"$scratch/contender.out" 2>"$scratch/contender.err"; then fail 'exclusive lock admitted a contender'; fi
wait "$holder"

# Handled replacement failure rolls back content and ownership bytes.
printf 'old-live\n' >"$live/${skills[0]}/SKILL.md"
rollback_before=$(snapshot)
if run_reconcile FIGMA_SKILLS_INJECT_FAILURE=after-first-replacement >"$scratch/rollback.out" 2>"$scratch/rollback.err"; then fail 'rollback injection succeeded'; fi
[[ $(snapshot) == "$rollback_before" ]] || fail 'handled failure did not restore prior state'

# A hard-killed writer leaves a reclaimable lock and recoverable journal. A
# second hard kill during rollback must leave every original backup reusable.
printf 'rollback-original-one\n' >"$live/${skills[0]}/SKILL.md"
printf 'rollback-original-two\n' >"$live/${skills[1]}/SKILL.md"
if run_reconcile FIGMA_SKILLS_INJECT_FAILURE=hard-crash-after-first-replacement >"$scratch/hard-crash.out" 2>"$scratch/hard-crash.err"; then
  fail 'hard-crash injection succeeded'
fi
[[ -d $state.lock && -f $state.journal ]] || fail 'hard crash did not preserve lock and journal'
crash_txn=$(jq -er '.transactionDir' "$state.journal")
[[ -f $crash_txn/backups/${skills[0]}/SKILL.md && -f $crash_txn/backups/${skills[1]}/SKILL.md ]] || fail 'hard crash did not preserve rollback backups'
if run_reconcile FIGMA_SKILLS_INJECT_FAILURE=rollback-hard-crash >"$scratch/rollback-crash.out" 2>"$scratch/rollback-crash.err"; then
  fail 'rollback hard-crash injection succeeded'
fi
[[ -d $state.lock && -f $state.journal ]] || fail 'interrupted rollback did not preserve lock and journal'
[[ -f $crash_txn/backups/${skills[0]}/SKILL.md && -f $crash_txn/backups/${skills[1]}/SKILL.md ]] || fail 'interrupted rollback consumed a backup'
[[ $(<"$live/${skills[0]}/SKILL.md") == rollback-original-one ]] || fail 'interrupted rollback did not restore its first destination'
run_reconcile
[[ ! -e $state.lock && ! -e $state.journal && ! -e $crash_txn ]] || fail 'restartable rollback recovery left transaction metadata'
grep -q '^# ' "$live/${skills[0]}/SKILL.md" || fail 'post-rollback reconciliation did not converge'

# Pre-commit interruption is rolled back by the next run; post-commit interruption completes cleanup forward.
printf 'pre-commit drift\n' >"$live/${skills[0]}/SKILL.md"
if run_reconcile FIGMA_SKILLS_INJECT_FAILURE=pre-commit-crash >"$scratch/pre-crash.out" 2>"$scratch/pre-crash.err"; then fail 'pre-commit crash injection succeeded'; fi
[[ -f $state.journal ]] || fail 'pre-commit crash left no journal'
run_reconcile
[[ ! -e $state.journal ]] || fail 'pre-commit recovery left a journal'
printf 'post-commit drift\n' >"$live/${skills[0]}/SKILL.md"
if run_reconcile FIGMA_SKILLS_INJECT_FAILURE=post-commit-crash >"$scratch/post-crash.out" 2>"$scratch/post-crash.err"; then fail 'post-commit crash injection succeeded'; fi
[[ -f $state.journal ]] || fail 'post-commit crash left no journal'
committed_id=$(jq -er '.transactionId' "$state")
[[ $(jq -er '.transactionId' "$state.journal") == "$committed_id" ]] || fail 'post-commit transaction IDs differ'
run_reconcile
[[ ! -e $state.journal ]] || fail 'forward recovery left a journal'
[[ $(manifest_skills) == "$expected_json" ]] || fail 'final ownership inventory differs from lock'
[[ -f $live/personal-skill/keep.txt && -f $live/figma-personal/keep.txt && -f $live/figma-retired-unowned/file ]] || fail 'final preservation failed'

printf 'figma skills POSIX transaction, recovery, lock, idempotence, drift, adoption, removal-authority, and subtree fixture passed (%s skills)\n' "${#skills[@]}"
