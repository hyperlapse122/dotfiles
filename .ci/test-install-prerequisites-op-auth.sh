#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # sourced hook returns before this fixture body
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="${XDG_RUNTIME_DIR:-${HOME}/.cache}/dotfiles-op-auth-test.$$"
stub_dir="${scratch_root}/bin"
empty_dir="${scratch_root}/empty"
log_file="${scratch_root}/op.log"
original_path="$PATH"

cleanup() {
  PATH="$original_path"
  rm -r -- "$scratch_root" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$stub_dir" "$empty_dir"
cat > "${stub_dir}/op" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OP_STUB_LOG"
printf 'vault-metadata-sentinel\n'
printf 'approval-diagnostic-sentinel\n' >&2
if [[ "${1-}" == vault && "${2-}" == list && $# -eq 2 ]]; then
  exit "${OP_STUB_VAULT_EXIT:-0}"
fi
exit 97
STUB
chmod 0700 "${stub_dir}/op"

export _INSTALL_PREREQUISITES_TEST_SOURCE=1
# shellcheck source=.install-prerequisites.sh
source "${repo_root}/.install-prerequisites.sh"
unset _INSTALL_PREREQUISITES_TEST_SOURCE

export PATH="${stub_dir}:${original_path}"
export OP_STUB_LOG="$log_file"

assert_probe() {
  local label="$1"
  local expected_status="$2"
  local actual_output
  : > "$log_file"

  if actual_output="$(op_ready 2>&1)"; then
    actual_status=0
  else
    actual_status=$?
  fi

  if [[ "$actual_status" -ne "$expected_status" ]]; then
    printf 'FAIL: %s returned %s, expected %s\n' "$label" "$actual_status" "$expected_status" >&2
    exit 1
  fi
  if [[ -n "$actual_output" ]]; then
    printf 'FAIL: %s leaked probe output: %s\n' "$label" "$actual_output" >&2
    exit 1
  fi
  if [[ "$(cat "$log_file")" != 'vault list' ]]; then
    printf 'FAIL: %s invoked unexpected op command: %s\n' "$label" "$(cat "$log_file")" >&2
    exit 1
  fi
}

export OP_STUB_VAULT_EXIT=0
unset OP_SERVICE_ACCOUNT_TOKEN || true
assert_probe 'desktop integration' 0

export OP_SERVICE_ACCOUNT_TOKEN='fixture-token'
assert_probe 'service account' 0
unset OP_SERVICE_ACCOUNT_TOKEN

export OP_STUB_VAULT_EXIT=1
assert_probe 'unauthenticated CLI' 1

: > "$log_file"
PATH="$empty_dir"
if op_ready; then
  printf 'FAIL: missing CLI reported ready\n' >&2
  exit 1
fi
PATH="${stub_dir}:${original_path}"
if [[ -s "$log_file" ]]; then
  printf 'FAIL: missing CLI invoked an op command\n' >&2
  exit 1
fi

printf 'install-prerequisites op auth POSIX fixture: PASS\n'
