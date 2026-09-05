#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper_source="$repo_root/dot_local/share/chezmoi-command-sources/executable_codex"
manifest_source="$repo_root/.chezmoidata/commands.yaml"
scratch_root="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/codex-tokscale-wrapper.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'codex tokscale wrapper: %s\n' "$*" >&2; exit 1; }

test_home="$scratch/home"
public_bin="$test_home/.local/bin"
real_dir="$test_home/.local/lib/commands/current/codex"
log_dir="$scratch/log"
mkdir -p "$public_bin" "$real_dir" "$log_dir"

[[ -f "$wrapper_source" ]] || fail "missing wrapper source $wrapper_source"

if grep -Eq 'CODEX_(REAL|BIN)|\$\{[A-Z_]*CODEX[A-Z_]*[:-]' "$wrapper_source"; then
  fail "wrapper must resolve the real binary through codex-bin only, not an environment override"
fi
grep -Fq '.local/bin/codex-bin' "$wrapper_source" || fail "wrapper must resolve \$HOME/.local/bin/codex-bin"

# Public command `codex` must be published by exactly one unit, and that unit must be codex-wrapper.
codex_publishers=$(awk '
  /^    [A-Za-z0-9][A-Za-z0-9._-]*:[[:space:]]*$/ { unit = $1; sub(":$", "", unit) }
  /^        - name: codex[[:space:]]*$/ { print unit }
' "$manifest_source")
[[ "$codex_publishers" == "codex-wrapper" ]] || fail "expected only codex-wrapper to publish codex, got: ${codex_publishers:-<none>}"

cp "$wrapper_source" "$public_bin/codex"
chmod 700 "$public_bin/codex"

cat >"$real_dir/codex" <<'EOF'
#!/usr/bin/env bash
: >"$CODEX_TEST_LOG/real.args"
if (( $# > 0 )); then
  printf '%s\0' "$@" >"$CODEX_TEST_LOG/real.args"
fi
exit "${CODEX_TEST_REAL_STATUS:-0}"
EOF
chmod 700 "$real_dir/codex"
ln -s "../lib/commands/current/codex/codex" "$public_bin/codex-bin"

cat >"$public_bin/tokscale-capture" <<'EOF'
#!/usr/bin/env bash
: >"$CODEX_TEST_LOG/tokscale.args"
if (( $# > 0 )); then
  printf '%s\0' "$@" >"$CODEX_TEST_LOG/tokscale.args"
fi
command -v codex >"$CODEX_TEST_LOG/resolved-codex"
codex "${@:3}"
exit "${CODEX_TEST_TOKSCALE_STATUS:-0}"
EOF
chmod 700 "$public_bin/tokscale-capture"

if [[ -n ${TOKSCALE_WRAPPER_UNDER_TEST-} ]]; then
  cp "$TOKSCALE_WRAPPER_UNDER_TEST" "$public_bin/tokscale"
  cat >"$public_bin/mise" <<'EOF'
#!/usr/bin/env bash
while [[ $1 != -- ]]; do shift; done
shift
exec "$@"
EOF
  cat >"$public_bin/npx" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -y && $2 == tokscale ]]
shift 2
exec tokscale-capture "$@"
EOF
  chmod 700 "$public_bin/tokscale" "$public_bin/mise" "$public_bin/npx"
else
  ln -s tokscale-capture "$public_bin/tokscale"
fi

assert_args() {
  local file=$1
  shift
  local actual=()
  [[ -e "$file" ]] || fail "expected argv log $file"
  if [[ -s "$file" ]]; then
    mapfile -d '' -t actual <"$file"
  fi
  if (( ${#actual[@]} != $# )); then
    fail "expected $# arguments, got ${#actual[@]} in $file"
  fi
  local index=0
  for expected in "$@"; do
    if [[ ${actual[$index]} != "$expected" ]]; then
      fail "argument $index: expected $(printf %q "$expected"), got $(printf %q "${actual[$index]}")"
    fi
    index=$((index + 1))
  done
}

run_codex() {
  env HOME="$test_home" \
    PATH="$public_bin:/usr/bin:/bin" \
    CODEX_TEST_LOG="$log_dir" \
    "$public_bin/codex" "$@"
}

assert_status() {
  local expected=$1
  shift
  local status=0
  "$@" || status=$?
  [[ $status -eq $expected ]] || fail "expected exit status $expected, got $status for: $*"
}

# exec path: tokscale wraps the real binary, and its own `codex` lookup hits the real binary.
rm -f "$log_dir"/*
run_codex exec task
assert_args "$log_dir/tokscale.args" headless codex exec task
assert_args "$log_dir/real.args" exec task
[[ $(<"$log_dir/resolved-codex") == "$real_dir/codex" ]] || fail "tokscale resolved codex to $(<"$log_dir/resolved-codex")"

rm -f "$log_dir"/*
run_codex exec --json "two words" -- "-leading dash"
assert_args "$log_dir/tokscale.args" headless codex exec --json "two words" -- "-leading dash"
assert_args "$log_dir/real.args" exec --json "two words" -- "-leading dash"

# passthrough path: every other invocation reaches the real binary with argv unchanged.
passthrough_cases=(
  ""
  "--version"
  "login --help"
  "resume session-123"
  "execx"
)
for args in "${passthrough_cases[@]}"; do
  rm -f "$log_dir"/*
  argv=()
  if [[ -n $args ]]; then
    read -r -a argv <<<"$args"
  fi
  run_codex "${argv[@]}"
  [[ ! -e "$log_dir/tokscale.args" ]] || fail "tokscale must not run for: $args"
  assert_args "$log_dir/real.args" "${argv[@]}"
done

rm -f "$log_dir"/*
run_codex login "--flag=with space" -x "two words" "-leading dash"
[[ ! -e "$log_dir/tokscale.args" ]] || fail "tokscale must not run for passthrough args"
assert_args "$log_dir/real.args" login "--flag=with space" -x "two words" "-leading dash"

# exit status propagates on both paths, including non-zero.
CODEX_TEST_TOKSCALE_STATUS=23 assert_status 23 run_codex exec prompt
CODEX_TEST_REAL_STATUS=17 assert_status 17 run_codex --version
CODEX_TEST_REAL_STATUS=17 assert_status 17 run_codex login --help
assert_status 0 run_codex --version

# missing codex-bin link: clear message, exit 127, nothing executed.
rm -f "$log_dir"/* "$public_bin/codex-bin"
missing_status=0
missing_output=$(run_codex --version 2>&1) || missing_status=$?
[[ $missing_status -eq 127 ]] || fail "expected exit 127 without codex-bin, got $missing_status"
[[ "$missing_output" == *codex-bin* ]] || fail "expected a message naming codex-bin, got: $missing_output"
[[ ! -e "$log_dir/real.args" && ! -e "$log_dir/tokscale.args" ]] || fail "nothing may run without codex-bin"

# dangling codex-bin link is the same failure.
ln -s "../lib/commands/current/codex/does-not-exist" "$public_bin/codex-bin"
dangling_status=0
run_codex --version >/dev/null 2>&1 || dangling_status=$?
[[ $dangling_status -eq 127 ]] || fail "expected exit 127 with a dangling codex-bin, got $dangling_status"

printf 'codex tokscale wrapper: ok\n'
