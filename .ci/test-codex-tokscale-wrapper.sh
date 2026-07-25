#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper_source="$repo_root/dot_local/bin/executable_codex"
installer_source="$repo_root/.chezmoiscripts/00-tools/run_onchange_after_codex.sh.tmpl"
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/codex-tokscale-wrapper.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

test_home="$scratch/home"
public_bin="$test_home/.local/bin"
real_bin="$test_home/.codex/packages/standalone/releases/current/bin"
log_dir="$scratch/log"
mkdir -p "$public_bin" "$real_bin" "$log_dir"

if grep -Eq 'BIN_DIR|ln .*\.local/bin/codex' "$installer_source"; then
  printf 'codex installer must not own the public wrapper path\n' >&2
  exit 1
fi

cp "$wrapper_source" "$public_bin/codex"
chmod 700 "$public_bin/codex"

cat >"$real_bin/codex" <<'EOF'
#!/usr/bin/env bash
: >"$CODEX_TEST_LOG/real.args"
if (( $# > 0 )); then
  printf '%s\0' "$@" >"$CODEX_TEST_LOG/real.args"
fi
exit "${CODEX_TEST_REAL_STATUS:-0}"
EOF
chmod 700 "$real_bin/codex"

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
  mapfile -d '' -t actual <"$file"
  if (( ${#actual[@]} != $# )); then
    printf 'expected %d arguments, got %d in %s\n' "$#" "${#actual[@]}" "$file" >&2
    exit 1
  fi
  local index=0
  for expected in "$@"; do
    if [[ ${actual[$index]} != "$expected" ]]; then
      printf 'argument %d: expected %q, got %q\n' "$index" "$expected" "${actual[$index]}" >&2
      exit 1
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

rm -f "$log_dir"/*
run_codex exec --json "two words"
assert_args "$log_dir/tokscale.args" headless codex exec --json "two words"
assert_args "$log_dir/real.args" exec --json "two words"
[[ $(<"$log_dir/resolved-codex") == "$real_bin/codex" ]]

for args in "" "--help" "resume session-123" "execx"; do
  rm -f "$log_dir"/*
  argv=()
  if [[ -n $args ]]; then
    read -r -a argv <<<"$args"
  fi
  run_codex "${argv[@]}"
  [[ ! -e "$log_dir/tokscale.args" ]]
  assert_args "$log_dir/real.args" "${argv[@]}"
done

set +e
CODEX_TEST_TOKSCALE_STATUS=23 run_codex exec prompt
status=$?
set -e
[[ $status -eq 23 ]]

set +e
CODEX_TEST_REAL_STATUS=17 run_codex resume session-123
status=$?
set -e
[[ $status -eq 17 ]]

printf 'codex tokscale wrapper: ok\n'
