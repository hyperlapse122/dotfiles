#!/usr/bin/env bash
# Guards run_before_guard-codex-skills.sh.tmpl: an apply that would replace a real
# ~/.codex/skills directory holding files with the managed symlink must stop
# before chezmoi deletes those files; every other state must let the apply run.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
guard_tmpl='.chezmoiscripts/70-agents/run_before_guard-codex-skills.sh.tmpl'

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/codex-skills-guard
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'codex skills guard: %s\n' "$*" >&2; exit 1; }

mkdir -p "$scratch/op" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/op/op"
chmod 0700 "$scratch/op/op"
: >"$scratch/empty.toml"
guard="$scratch/guard.sh"
env PATH="$scratch/op:$PATH" chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
  --destination "$scratch/target" execute-template <"$repo_root/$guard_tmpl" >"$guard" ||
  fail 'guard failed to render'
chmod 0700 "$guard"
grep -F '.codex/skills' "$guard" >/dev/null || fail 'rendered guard does not name ~/.codex/skills'

run_guard() {
  local home=$1
  env HOME="$home" bash "$guard"
}

# No directory, an existing symlink, and an empty real directory all pass.
home="$scratch/home-none"
mkdir -p "$home/.codex"
run_guard "$home" || fail 'guard refused a HOME without ~/.codex/skills'

home="$scratch/home-symlink"
mkdir -p "$home/.codex" "$home/.agents/skills/demo"
ln -s ../.agents/skills "$home/.codex/skills"
run_guard "$home" || fail 'guard refused an existing skills symlink'

home="$scratch/home-empty"
mkdir -p "$home/.codex/skills"
run_guard "$home" || fail 'guard refused an empty real skills directory'

# A real directory with contents stops the apply and says where to move them.
home="$scratch/home-real"
mkdir -p "$home/.codex/skills/android-cli"
: >"$home/.codex/skills/android-cli/SKILL.md"
status=0
output=$(run_guard "$home" 2>&1) || status=$?
[[ $status -eq 1 ]] || fail "expected exit 1 for a populated real skills directory, got $status"
[[ $output == *"$home/.codex/skills"* ]] || fail "refusal does not name the directory: $output"
[[ $output == *"$home/.agents/skills"* ]] || fail "refusal does not name the destination: $output"
[[ -f "$home/.codex/skills/android-cli/SKILL.md" ]] || fail 'guard mutated the skills directory'

printf 'codex skills guard: ok\n'
