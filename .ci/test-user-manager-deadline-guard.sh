#!/usr/bin/env bash
# Prove the user-manager deadline guard partial (.chezmoitemplates/user-manager-deadline-guard.sh.tmpl).
#
# Verifies:
#   1. RENDER error when called with a non-map argument or missing required `name`.
#   2. RENDER output for both includeReload=false and includeReload=true forms.
#   3. RUNTIME validation of deadline variables:
#      - accepts valid positive integers and empty defaults
#      - rejects 0, negative, and non-integer values with the per-caller prefix
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/user-manager-deadline-guard"
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/test.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'user-manager-deadline-guard: FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'user-manager-deadline-guard: ok - %s\n' "$*"
}

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'

template_file="$repo_root/.chezmoitemplates/user-manager-deadline-guard.sh.tmpl"
[[ -f "$template_file" ]] || fail "missing template $template_file"

printf '[data]\n' >"$scratch/empty.toml"

# 1. Reject non-map argument
if env HOME="$scratch" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" execute-template \
  '{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" "not-a-map" }}' >/dev/null 2>&1; then
  fail 'template accepted non-map argument'
fi
pass 'rejected non-map argument'

# 2. Reject missing name
if env HOME="$scratch" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" execute-template \
  '{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" (dict "ctx" .) }}' >/dev/null 2>&1; then
  fail 'template accepted map without name'
fi
pass 'rejected missing name parameter'

# 3. Render default form (includeReload: false)
default_render="$scratch/default.sh"
env HOME="$scratch" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" execute-template \
  '{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" (dict "ctx" . "name" "test-default") }}' \
  >"$default_render"
bash -n "$default_render" || fail 'default render is not valid shell syntax'
grep -qF 'test-default: user-manager deadlines must be positive integer seconds' "$default_render" \
  || fail 'default render does not contain error string with caller name'
if grep -qF 'USER_MANAGER_RELOAD_DEADLINE_SECS' "$default_render"; then
  fail 'default render should not contain reload deadline'
fi
pass 'default render structure valid'

# 4. Render with includeReload: true
reload_render="$scratch/reload.sh"
env HOME="$scratch" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" execute-template \
  '{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" (dict "ctx" . "name" "test-reload" "includeReload" true) }}' \
  >"$reload_render"
bash -n "$reload_render" || fail 'reload render is not valid shell syntax'
grep -qF 'test-reload: user-manager deadlines must be positive integer seconds' "$reload_render" \
  || fail 'reload render does not contain error string with caller name'
grep -qF 'user_manager_reload_deadline_secs=${USER_MANAGER_RELOAD_DEADLINE_SECS:-30}' "$reload_render" \
  || fail 'reload render does not contain reload deadline assignment'
pass 'reload render structure valid'

# 5. Runtime execution checks on default render
# Valid default execution
bash "$default_render" || fail 'default render failed with unset env'
CAPABILITY_PROBE_DEADLINE_SECS=10 CAPABILITY_PROBE_TERM_GRACE_SECS=3 bash "$default_render" \
  || fail 'default render failed with valid positive integers'
CAPABILITY_PROBE_DEADLINE_SECS='' CAPABILITY_PROBE_TERM_GRACE_SECS='' bash "$default_render" \
  || fail 'default render failed with empty variables'

# Invalid values rejected
stderr_out="$scratch/err.log"
for bad in 0 -1 abc "1.5"; do
  if CAPABILITY_PROBE_DEADLINE_SECS="$bad" bash "$default_render" 2>"$stderr_out"; then
    fail "default render accepted invalid deadline '$bad'"
  fi
  grep -qF 'test-default: user-manager deadlines must be positive integer seconds' "$stderr_out" \
    || fail "default render error message missing for invalid deadline '$bad'"
done

# 6. Runtime execution checks on reload render
# Valid execution
bash "$reload_render" || fail 'reload render failed with unset env'
USER_MANAGER_RELOAD_DEADLINE_SECS=60 bash "$reload_render" || fail 'reload render failed with valid reload deadline'
USER_MANAGER_RELOAD_DEADLINE_SECS='' bash "$reload_render" || fail 'reload render failed with empty reload deadline'

for bad in 0 -1 abc "2.0"; do
  if USER_MANAGER_RELOAD_DEADLINE_SECS="$bad" bash "$reload_render" 2>"$stderr_out"; then
    fail "reload render accepted invalid reload deadline '$bad'"
  fi
  grep -qF 'test-reload: user-manager deadlines must be positive integer seconds' "$stderr_out" \
    || fail "reload render error message missing for invalid reload deadline '$bad'"
done
pass 'runtime validation passed for all shapes'

printf 'user-manager-deadline-guard: PASS\n'
