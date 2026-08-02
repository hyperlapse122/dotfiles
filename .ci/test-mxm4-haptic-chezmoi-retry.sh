#!/usr/bin/env bash
set -euo pipefail

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/mxm4-haptic-chezmoi-retry.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

source_dir="$scratch/source"
destination="$scratch/destination"
fixture_home="$scratch/home"
state_db="$scratch/state/chezmoi.boltdb"
cache_dir="$scratch/cache"
stub_bin="$scratch/bin"
log="$scratch/transactions.log"
stub_state="$scratch/stub-state"
mkdir -p "$source_dir/.chezmoiscripts/60-build" "$source_dir/.chezmoiscripts/70-agents" \
  "$destination" "$fixture_home/.cache" "$(dirname "$state_db")" "$cache_dir" "$stub_bin" "$stub_state"
printf '[data]\n' >"$scratch/empty.toml"
chezmoi_bin=$(command -v chezmoi)

cat >"$stub_bin/mxm4-phase60" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'phase60-attempt\n' >>"$FIXTURE_LOG"
if [[ ! -e "$FIXTURE_STUB_STATE/failed-once" ]]; then
  : >"$FIXTURE_STUB_STATE/failed-once"
  exit 23
fi
printf 'built-from-unchanged-source\n' >"${1:?artifact path is required}"
STUB
cat >"$stub_bin/omp-phase70" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
artifact=${1:?artifact path is required}
mutation=${2:?mutation path is required}
[[ $(<"$artifact") == built-from-unchanged-source ]]
printf 'phase70-mutation\n' >>"$FIXTURE_LOG"
mkdir -p "$(dirname "$mutation")"
printf 'converged\n' >"$mutation"
STUB
chmod +x "$stub_bin/mxm4-phase60" "$stub_bin/omp-phase70"

cat >"$source_dir/.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
stage="$HOME/.cache/mxm4-haptic-stage.$$"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage" "$CHEZMOI_DEST/.local/share/omp-plugins/plugins/mxm4-haptic/dist"
mxm4-phase60 "$stage/index.js"
mv -f -- "$stage/index.js" "$CHEZMOI_DEST/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js"
SCRIPT
cat >"$source_dir/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
omp-phase70 \
  "$CHEZMOI_DEST/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" \
  "$CHEZMOI_DEST/.local/state/omp-haptic-reconciled"
SCRIPT
chmod +x "$source_dir/.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh" \
  "$source_dir/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh"

source_digest_before=$(sha256sum \
  "$source_dir/.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh" \
  "$source_dir/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh")

run_apply() {
  env HOME="$fixture_home" PATH="$stub_bin:/usr/bin:/bin" \
    FIXTURE_LOG="$log" FIXTURE_STUB_STATE="$stub_state" CHEZMOI_DEST="$destination" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$source_dir" \
      --destination "$destination" --persistent-state "$state_db" --cache "$cache_dir" \
      --no-tty --force apply
}

# The first phase-60 transaction fails. Chezmoi must stop before phase 70, and
# the provisioner must not publish its staged artifact.
if run_apply >"$scratch/first.stdout" 2>"$scratch/first.stderr"; then
  printf 'expected the first apply to fail in phase 60\n' >&2
  exit 1
fi
[[ $(grep -c '^phase60-attempt$' "$log") -eq 1 ]]
if grep -q '^phase70-mutation$' "$log"; then exit 1; fi
[[ ! -e "$destination/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" ]]
[[ ! -e "$destination/.local/state/omp-haptic-reconciled" ]]

# Nothing in source state changes. Because phase 60 is run_after rather than
# run_onchange_after, the next apply retries it; phase 70 then observes the
# committed artifact and performs its one mutation.
run_apply >"$scratch/second.stdout" 2>"$scratch/second.stderr"
source_digest_after=$(sha256sum \
  "$source_dir/.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh" \
  "$source_dir/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh")
[[ "$source_digest_after" == "$source_digest_before" ]]
[[ $(grep -c '^phase60-attempt$' "$log") -eq 2 ]]
[[ $(grep -c '^phase70-mutation$' "$log") -eq 1 ]]
[[ $(<"$destination/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js") == built-from-unchanged-source ]]
[[ $(<"$destination/.local/state/omp-haptic-reconciled") == converged ]]
[[ -s "$state_db" ]]

printf '%s\n' 'mxm4-haptic chezmoi retry fixture passed'
