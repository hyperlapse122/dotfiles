#!/usr/bin/env bash
# Drives the tokscale wrapper against a stub `bun` that records its argv and
# the TOKSCALE_* environment it was given.
#
#   tokscale.sh SCRIPT                        the source, placeholders rendered here
#   tokscale.sh --packaged BIN HOST TOKEN     a built copy whose token file holds TOKEN
set -euo pipefail

usage() {
  printf 'usage: %s SCRIPT | --packaged BIN HOST TOKEN\n' "${0##*/}" >&2
  exit 2
}

mode=source
if [[ ${1:-} == --packaged ]]; then
  [[ $# -eq 4 ]] || usage
  mode=packaged
  target=$2
  host=$3
  file_token=$4
  [[ -n $host && -n $file_token ]] || usage
else
  [[ $# -eq 1 ]] || usage
  target=$1
fi
[[ -f $target ]] || usage
target=$(cd -- "$(dirname -- "$target")" && pwd -P)/$(basename -- "$target")

scratch=$(mktemp -d "${TMPDIR:-/tmp}/tokscale-tests.XXXXXX")
trap 'chmod -R u+rwx "$scratch" 2>/dev/null; rm -rf -- "$scratch"' EXIT

fail() { printf 'tokscale: FAIL (%s): %s\n' "$mode" "$*" >&2; exit 1; }
pass() { printf 'tokscale: ok (%s) - %s\n' "$mode" "$*"; }

bash_bin=$(command -v bash) || fail 'bash is required'
token_file=$scratch/token

if [[ $mode == source ]]; then
  host=test-host
  file_token=fake-token-123
  wrapper=$scratch/tokscale
  sed -e "s|@HOST_NAME@|$host|" -e "s|@TOKEN_FILE@|$token_file|" "$target" >"$wrapper"
  chmod +x "$wrapper"
else
  wrapper=$target
  [[ -x $wrapper ]] || fail "$wrapper is not executable"
fi

# --- the stub and the environment it runs in -------------------------------

rec=$scratch/rec
bin=$scratch/bin
nobun=$scratch/nobun
home=$scratch/home
mkdir -p "$bin" "$nobun" "$home"
# The source shebang is `/usr/bin/env bash`, so every PATH offers bash, and
# only the stub directory offers bun.
ln -s "$bash_bin" "$bin/bash"
ln -s "$bash_bin" "$nobun/bash"
cat >"$bin/bun" <<STUB
#!$bash_bin
# Builtins only: the wrapper runs with a PATH that holds nothing but bash and bun.
printf '%s\0' "\$@" >"$rec/argv"
[[ -n \${TOKSCALE_API_TOKEN+x} ]] && printf '%s' "\$TOKSCALE_API_TOKEN" >"$rec/token"
[[ -n \${TOKSCALE_EXTRA_DIRS+x} ]] && printf '%s' "\$TOKSCALE_EXTRA_DIRS" >"$rec/extra"
[[ -n \${TOKSCALE_DEVICE_NAME+x} ]] && printf '%s' "\$TOKSCALE_DEVICE_NAME" >"$rec/device"
printf 'stub-bun ran\n'
exit "\$(<"$scratch/status")"
STUB
chmod +x "$bin/bun"

# run [VAR=value ...] ARGS... -- runs the wrapper in a clean environment and
# leaves its status in $rc and its output in $scratch/stdout and stderr.
run() {
  local -a assigns=()
  while [[ $# -gt 0 && $1 == *=* && $1 != -* ]]; do
    assigns+=("$1")
    shift
  done
  rm -rf -- "$rec"
  mkdir -p "$rec"
  set +e
  env -i HOME="$home" PATH="$bin" "${assigns[@]}" "$wrapper" "$@" \
    >"$scratch/stdout" 2>"$scratch/stderr"
  rc=$?
  set -e
}

stub_ran() { [[ -f $rec/argv ]]; }
recorded() { [[ -f $rec/$1 ]] && cat -- "$rec/$1"; }

set_token_file() {
  [[ $mode == source ]] || fail 'the packaged token file is fixed at build time'
  chmod -R u+rwx "$token_file" 2>/dev/null || true
  rm -rf -- "$token_file"
  if [[ $# -gt 0 ]]; then printf '%s' "$1" >"$token_file"; fi
}

# The token must reach Tokscale only through its environment.
assert_token_hidden() {
  local token=$1 f
  for f in "$rec/argv" "$scratch/stdout" "$scratch/stderr"; do
    if [[ -f $f ]] && grep -aqF -- "$token" "$f"; then
      fail "the token appeared in ${f##*/}"
    fi
  done
  if grep -raqF -- "$token" "$home"; then
    fail "the token was written under $home"
  fi
}

echo 0 >"$scratch/status"
if [[ $mode == source ]]; then set_token_file "$file_token"; fi

# --- packaging ---------------------------------------------------------------

if [[ $mode == packaged ]]; then
  if grep -qE '@[A-Z_]+@' "$wrapper"; then
    fail "a placeholder survived in $wrapper: $(grep -oE '@[A-Z_]+@' "$wrapper" | head -n1)"
  fi
  shebang=$(head -n1 "$wrapper")
  store=${NIX_STORE:-/nix/store}
  [[ $shebang == "#!$store/"*/bin/bash ]] || fail "shebang is not a store bash: $shebang"
  pass 'no placeholder survives and the shebang is a store bash'
fi

# --- arguments and exit status ---------------------------------------------

echo 3 >"$scratch/status"
run submit --since "a b"
stub_ran || fail 'the stub bun never ran'
mapfile -d '' argv <"$rec/argv"
expected=(x tokscale@latest submit --since "a b")
[[ ${#argv[@]} -eq ${#expected[@]} ]] || fail "argv has ${#argv[@]} words: ${argv[*]}"
for i in "${!expected[@]}"; do
  [[ ${argv[i]} == "${expected[i]}" ]] || fail "argv[$i] is '${argv[i]}', want '${expected[i]}'"
done
[[ $rc -eq 3 ]] || fail "exit status $rc, want the stub's 3"
pass 'arguments reach bun x tokscale@latest unchanged and the exit status is kept'
echo 0 >"$scratch/status"

run
mapfile -d '' argv <"$rec/argv"
[[ ${#argv[@]} -eq 2 && ${argv[0]} == x && ${argv[1]} == tokscale@latest ]] ||
  fail "a bare run passed extra words: ${argv[*]}"
[[ $rc -eq 0 ]] || fail "a bare run exited $rc"
pass 'a bare run passes no extra arguments'

# --- bun missing -----------------------------------------------------------

run PATH="$nobun" report
[[ $rc -eq 127 ]] || fail "without bun the wrapper exited $rc, want 127"
if stub_ran; then fail 'the stub ran although it was not on PATH'; fi
[[ $(wc -l <"$scratch/stderr") -eq 1 ]] ||
  fail "without bun stderr is not one line: $(cat "$scratch/stderr")"
grep -qw bun "$scratch/stderr" || fail "the error does not name bun: $(cat "$scratch/stderr")"
# bash's own failed exec also exits 127 with a line naming bun, so only the
# wrapper's prefix shows the wrapper checked for bun before exec.
[[ $(<"$scratch/stderr") == 'tokscale: '* ]] ||
  fail "the error is not the wrapper's own: $(cat "$scratch/stderr")"
pass 'without bun on PATH it prints one line naming bun and exits 127'

# --- device name -----------------------------------------------------------

run
[[ $(recorded device) == "$host" ]] ||
  fail "TOKSCALE_DEVICE_NAME is '$(recorded device)', want '$host'"
run TOKSCALE_DEVICE_NAME=elsewhere
[[ $(recorded device) == "$host" ]] || fail 'a caller value replaced the host name'
pass "TOKSCALE_DEVICE_NAME is the host name $host"

# --- token ----------------------------------------------------------------

run submit
[[ -f $rec/token ]] || fail 'the token file did not reach TOKSCALE_API_TOKEN'
[[ $(recorded token) == "$file_token" ]] || fail 'TOKSCALE_API_TOKEN is not the file token'
assert_token_hidden "$file_token"
pass 'the token file reaches TOKSCALE_API_TOKEN and nowhere else'

run TOKSCALE_API_TOKEN=caller-token submit
[[ $(recorded token) == caller-token ]] || fail 'the file token replaced the caller token'
assert_token_hidden "$file_token"
pass 'a caller-exported TOKSCALE_API_TOKEN wins over the token file'

run TOKSCALE_API_TOKEN= submit
[[ $(recorded token) == "$file_token" ]] || fail 'an empty caller token blocked the file token'
pass 'an empty caller TOKSCALE_API_TOKEN falls back to the token file'

if [[ $mode == source ]]; then
  echo 4 >"$scratch/status"
  check_no_token() {
    local label=$1
    run submit
    stub_ran || fail "$label: the stub did not run"
    [[ $rc -eq 4 ]] || fail "$label: exit status $rc, want the stub's 4"
    if [[ -f $rec/token ]]; then
      fail "$label: TOKSCALE_API_TOKEN was set to '$(recorded token)'"
    fi
    if [[ -n $(<"$scratch/stderr") ]]; then
      fail "$label: the wrapper printed to stderr: $(cat "$scratch/stderr")"
    fi
    run TOKSCALE_API_TOKEN= submit
    if [[ -f $rec/token ]]; then fail "$label: an empty caller token was passed on"; fi
  }

  set_token_file
  check_no_token 'missing token file'
  pass 'a missing token file runs unauthenticated with the exit status kept'

  set_token_file ''
  check_no_token 'empty token file'
  set_token_file $'\n'
  check_no_token 'newline-only token file'
  pass 'an empty token file behaves like a missing one'

  set_token_file 'fake token'
  check_no_token 'token with a space'
  set_token_file $'fake-token\nsecond-line'
  check_no_token 'two-line token file'
  set_token_file "$(printf 'x%.0s' {1..8193})"
  check_no_token 'oversize token file'
  pass 'a whitespace-bearing or oversize token file behaves like a missing one'

  longest=$(printf 'x%.0s' {1..8192})
  set_token_file "$longest"
  run submit
  [[ $(recorded token) == "$longest" ]] || fail 'an 8192-character token was not accepted'
  pass 'a token of exactly 8192 characters is accepted'

  set_token_file $'fake-token-456\n'
  run submit
  [[ $(recorded token) == fake-token-456 ]] || fail 'a trailing newline was not stripped'
  pass 'a trailing newline after the token is stripped'

  set_token_file "$file_token"
  chmod 000 "$token_file"
  if [[ -r $token_file ]]; then
    printf 'tokscale: skip (%s) - running as a user that can read mode 000\n' "$mode"
  else
    check_no_token 'unreadable token file'
    pass 'an unreadable token file behaves like a missing one'
  fi

  set_token_file
  mkdir "$token_file"
  check_no_token 'token path is a directory'
  rmdir "$token_file"

  set_token_file "$file_token"
  echo 0 >"$scratch/status"
fi

# --- Antigravity ACP conversation directories --------------------------------

providers=$home/.t3/userdata/providers/antigravity
acp_default=$home/.gemini/antigravity-acp/conversations

run
if [[ -f $rec/extra ]]; then fail "TOKSCALE_EXTRA_DIRS was set to '$(recorded extra)'"; fi
caller=$'claude:/a b,  trailing,\ttab'
run TOKSCALE_EXTRA_DIRS="$caller"
[[ $(recorded extra) == "$caller" ]] || fail "the caller value changed: '$(recorded extra)'"
run TOKSCALE_EXTRA_DIRS=
[[ -f $rec/extra && -z $(recorded extra) ]] || fail 'an empty caller value was not kept'
[[ $rc -eq 0 ]] || fail "with no conversations directory the wrapper exited $rc"
pass 'with no conversations directory TOKSCALE_EXTRA_DIRS is untouched'

mkdir -p "$providers/empty" "$providers/filed/antigravity-acp" "$home/.gemini/antigravity-acp"
touch "$providers/filed/antigravity-acp/conversations" "$acp_default"
run
if [[ -f $rec/extra ]]; then fail "TOKSCALE_EXTRA_DIRS was set to '$(recorded extra)'"; fi
pass 'a provider without a conversations directory, or a file in its place, adds nothing'
rm -f -- "$acp_default"

mkdir -p "$providers/first/antigravity-acp/conversations" "$providers/second/antigravity-acp/conversations"
run TOKSCALE_EXTRA_DIRS=claude:/x
want="claude:/x,antigravity-cli:$providers/first/antigravity-acp/conversations,antigravity-cli:$providers/second/antigravity-acp/conversations"
[[ $(recorded extra) == "$want" ]] || fail "extra dirs '$(recorded extra)', want '$want'"
pass 'each T3 Antigravity conversations directory is appended after the caller value'

mkdir -p "$providers/a,b/antigravity-acp/conversations"
run
want="antigravity-cli:$providers/first/antigravity-acp/conversations,antigravity-cli:$providers/second/antigravity-acp/conversations"
[[ $(recorded extra) == "$want" ]] || fail "a path with a comma was not skipped: '$(recorded extra)'"
pass 'a T3 conversations path containing a comma is skipped'

run TOKSCALE_EXTRA_DIRS=
[[ $(recorded extra) == "$want" ]] || fail "an empty caller value left a leading comma: '$(recorded extra)'"
pass 'with an empty caller value only the conversations directories are listed'

mkdir -p "$acp_default"
run
want+=",antigravity-cli:$acp_default"
[[ $(recorded extra) == "$want" ]] || fail "extra dirs '$(recorded extra)', want '$want'"
pass 'the standalone ACP conversations directory follows the T3 ones'

printf 'tokscale: all checks passed (%s)\n' "$mode"
