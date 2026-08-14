#!/usr/bin/env bash
# Isolated verification for omp's zsh completion install
# (U2/U3 of docs/plans/2026-08-05-004-feat-omp-mnemopi-memory-zsh-completion-plan.md).
#
# Three isolated contracts:
#
#   1. the rendered generator script, driven against a stub `omp` in a scratch
#      HOME — happy path, idempotence, and every fail-closed case (malformed,
#      empty, and failing generator output), plus the prezto zcompdump
#      invalidation and its gating on install success;
#   2. the $fpath wiring in dot_config/zsh/dot_zshrc — a static ordering check
#      that the fpath line precedes the prezto init source, and a real `zsh -f`
#      proving compinit resolves _omp WITH the prepend and does NOT resolve it
#      without. The negative case is what makes the positive one load-bearing;
#   3. external completion generators are skipped when compdef is unavailable
#      (Prezto's TERM=dumb path), but execute normally after compinit.
#
# Never runs chezmoi apply, never writes outside its scratch tree, and never
# invokes the real omp binary — a stub stands in so failure modes are drivable.
set -euo pipefail

usage='usage: test-omp-zsh-completion.sh RENDERED_GENERATOR'
generator=${1:?$usage}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
zshrc="$repo_root/dot_config/zsh/dot_zshrc"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/omp-zsh-completion.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'omp-zsh-completion: FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$generator" ] || fail "rendered generator not found at $generator"
[ -f "$zshrc" ] || fail 'dot_config/zsh/dot_zshrc not found'

bash -n "$generator" || fail 'rendered generator is not valid bash'

# The rendered script must carry the locked omp version, because that comment IS
# the onchange trigger — without it a lock bump would never re-run the install.
grep -Eq '^# omp version: v[0-9]' "$generator" \
  || fail 'rendered generator carries no "# omp version: vN" fingerprint line'

# --- generator harness --------------------------------------------------------

stub_dir="$scratch/bin"
mkdir -p -- "$stub_dir"

# $1 = stub body for `omp completions zsh`. Writes an `omp` stub that logs its
# argv, so a case can also assert the generator called the expected subcommand.
write_omp_stub() {
  cat >"$stub_dir/omp" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$scratch/omp.calls"
$1
STUB
  chmod 0755 "$stub_dir/omp"
}

# Runs the generator in a fresh scratch HOME and EXITS with the generator's own
# status, so callers use the ordinary `rc=0; run_case x || rc=$?` idiom rather
# than reading a status back out of stdout. The generator's stdout and stderr
# land in <case>.out / <case>.err. $2 pre-seeds the target _omp when set.
run_case() {
  local name=$1 preseed=${2-}
  local home="$scratch/home-$name"
  local cache="$scratch/cache-$name"
  mkdir -p -- "$home/.local/share/zsh/site-functions" "$cache/prezto"
  if [ -n "$preseed" ]; then
    printf '%s\n' "$preseed" >"$home/.local/share/zsh/site-functions/_omp"
  fi
  # Pre-seed the dump and its compiled sibling so invalidation is observable.
  printf 'stale dump\n' >"$cache/prezto/zcompdump"
  printf 'stale zwc\n' >"$cache/prezto/zcompdump.zwc"
  : >"$scratch/omp.calls"
  env -i \
    PATH="$stub_dir:/usr/bin:/bin" \
    HOME="$home" \
    XDG_CACHE_HOME="$cache" \
    bash "$generator" >"$scratch/$name.out" 2>"$scratch/$name.err"
}

target_of() { printf '%s' "$scratch/home-$1/.local/share/zsh/site-functions/_omp"; }
dump_of() { printf '%s' "$scratch/cache-$1/prezto/zcompdump"; }

# No leftover mktemp staging file may survive, on success or failure — a stray
# dotfile in an $fpath directory is litter compinit would scan every rebuild.
assert_no_residue() {
  local name=$1 dir="$scratch/home-$1/.local/share/zsh/site-functions"
  local residue
  residue=$(find "$dir" -maxdepth 1 -name '.omp-completion.*' -print -quit)
  [ -z "$residue" ] || fail "$name: staging file survived at $residue"
}

readonly VALID_COMPLETION='#compdef omp
_omp() { _describe omp "" }
_omp "$@"'

# --- 1. happy path ------------------------------------------------------------

write_omp_stub "cat <<'EOF'
$VALID_COMPLETION
EOF"

status=0
run_case happy || status=$?
[ "$status" -eq 0 ] || fail "happy: expected exit 0, got $status ($(cat "$scratch/happy.err"))"
[ -f "$(target_of happy)" ] || fail 'happy: _omp was not installed'
diff -u <(printf '%s\n' "$VALID_COMPLETION") "$(target_of happy)" >/dev/null \
  || fail 'happy: installed _omp does not match the generator output'
grep -qxF 'completions zsh' "$scratch/omp.calls" \
  || fail "happy: generator did not call 'omp completions zsh' (calls: $(cat "$scratch/omp.calls"))"
mode=$(stat -c '%a' "$(target_of happy)" 2>/dev/null || stat -f '%Lp' "$(target_of happy)")
[ "$mode" = '644' ] || fail "happy: _omp mode is $mode, expected 644"
[ ! -e "$(dump_of happy)" ] || fail 'happy: zcompdump survived a successful install'
[ ! -e "$(dump_of happy).zwc" ] || fail 'happy: zcompdump.zwc survived a successful install'
assert_no_residue happy

# --- 2. a successful run REPLACES a different pre-existing file ---------------
# Pre-seeding identical content would pass whether or not an overwrite happened,
# so a generator that silently no-ops on an existing target would look correct.
# Seed something clearly different and require it to be gone.

readonly STALE='#compdef omp
# stale completion from an older omp'

status=0
run_case replace "$STALE" || status=$?
[ "$status" -eq 0 ] || fail "replace: expected exit 0, got $status ($(cat "$scratch/replace.err"))"
diff -u <(printf '%s\n' "$VALID_COMPLETION") "$(target_of replace)" >/dev/null \
  || fail 'replace: a stale pre-existing _omp was not overwritten by the fresh generator output'

# --- 3. missing dump ----------------------------------------------------------
# A successful run with no dump to remove must not trip on the absent file.

home_nodump="$scratch/home-nodump"
mkdir -p -- "$home_nodump/.local/share/zsh/site-functions" "$scratch/cache-nodump"
status=0
env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$home_nodump" \
  XDG_CACHE_HOME="$scratch/cache-nodump" \
  bash "$generator" >/dev/null 2>"$scratch/nodump.err" || status=$?
[ "$status" -eq 0 ] || fail "nodump: expected exit 0 with no pre-existing dump, got $status"
[ -f "$home_nodump/.local/share/zsh/site-functions/_omp" ] \
  || fail 'nodump: _omp was not installed'

# --- 3b. the target directory does not exist yet ------------------------------
# run_case pre-creates it, which would hide a missing mkdir -p in the generator.

home_mkdir="$scratch/home-mkdir"
mkdir -p -- "$home_mkdir"
status=0
env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$home_mkdir" \
  XDG_CACHE_HOME="$scratch/cache-mkdir" \
  bash "$generator" >/dev/null 2>"$scratch/mkdir.err" || status=$?
[ "$status" -eq 0 ] || fail "mkdir: expected exit 0 with no target directory, got $status ($(cat "$scratch/mkdir.err"))"
[ -f "$home_mkdir/.local/share/zsh/site-functions/_omp" ] \
  || fail 'mkdir: the generator did not create its target directory'

# --- 3c. omp resolvable only through the ~/.local/bin PATH prepend ------------
# Every other case puts the stub on PATH directly, which never exercises the
# prepend that exists because chezmoi's script environment omits ~/.local/bin.

home_path="$scratch/home-path"
mkdir -p -- "$home_path/.local/bin" "$home_path/.local/share/zsh/site-functions"
cp "$stub_dir/omp" "$home_path/.local/bin/omp"
status=0
env -i PATH="/usr/bin:/bin" HOME="$home_path" \
  XDG_CACHE_HOME="$scratch/cache-path" \
  bash "$generator" >/dev/null 2>"$scratch/pathprepend.err" || status=$?
[ "$status" -eq 0 ] \
  || fail "pathprepend: expected exit 0 with omp only in ~/.local/bin, got $status ($(cat "$scratch/pathprepend.err"))"
[ -f "$home_path/.local/share/zsh/site-functions/_omp" ] \
  || fail 'pathprepend: the generator did not find omp via the ~/.local/bin prepend'

# --- 4. fail-closed cases -----------------------------------------------------
# Each must exit non-zero, leave a pre-seeded _omp byte-identical, and leave the
# zcompdump in place (invalidation is gated on install success).

readonly SENTINEL='#compdef omp
# pre-existing sentinel'

# Runs a case expected to fail closed, then asserts the whole fail-closed
# contract: non-zero exit, the pre-seeded _omp untouched, the zcompdump still
# present (invalidation is gated on install success), the named stderr message,
# and no staging residue.
assert_failed_case() {
  local name=$1 needle=$2 status=0
  run_case "$name" "$SENTINEL" || status=$?
  [ "$status" -ne 0 ] || fail "$name: expected a non-zero exit, got 0"
  diff -u <(printf '%s\n' "$SENTINEL") "$(target_of "$name")" >/dev/null \
    || fail "$name: pre-existing _omp was modified"
  [ -f "$(dump_of "$name")" ] || fail "$name: zcompdump was invalidated despite failure"
  [ -f "$(dump_of "$name").zwc" ] || fail "$name: zcompdump.zwc was invalidated despite failure"
  grep -q "$needle" "$scratch/$name.err" \
    || fail "$name: stderr lacked '$needle' (got: $(cat "$scratch/$name.err"))"
  assert_no_residue "$name"
}

# 4a. malformed: non-empty output whose first line is not the compdef tag. This
# models omp's observed source-dump-on-early-stdout-close failure.
write_omp_stub "printf '%s\n' 'internal error' '732312 |   j.set(u.name, g);'"
assert_failed_case malformed '#compdef omp'

# 4b. empty output.
write_omp_stub 'exit 0'
assert_failed_case empty 'no output'

# 4c. generator itself fails.
write_omp_stub "printf '%s\n' 'boom' >&2; exit 3"
assert_failed_case generr 'failed'

# 4d. valid `#compdef omp` header but a body that is not parseable zsh. This is
# the case the first-line check CANNOT catch, and the one that would install a
# file every new interactive shell then fails to load.
write_omp_stub "printf '%s\n' '#compdef omp' '_omp() {' 'unterminated'"
assert_failed_case brokenbody 'not valid zsh'

# 4e. a directory sitting at the target path. Plain \`mv\` would move the staged
# file INTO it and still report success, leaving no loadable _omp.
write_omp_stub "cat <<'EOF'
$VALID_COMPLETION
EOF"
dir_home="$scratch/home-dirtarget"
dir_target="$dir_home/.local/share/zsh/site-functions/_omp"
mkdir -p -- "$dir_target" "$scratch/cache-dirtarget"
status=0
env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$dir_home" \
  XDG_CACHE_HOME="$scratch/cache-dirtarget" \
  bash "$generator" >/dev/null 2>"$scratch/dirtarget.err" || status=$?
[ "$status" -ne 0 ] || fail 'dirtarget: expected a non-zero exit with a directory at the target, got 0'
[ -d "$dir_target" ] || fail 'dirtarget: the directory at the target was replaced'
[ -z "$(find "$dir_target" -mindepth 1 -print -quit)" ] \
  || fail 'dirtarget: the staged file was moved INTO the target directory'
grep -q 'is a directory' "$scratch/dirtarget.err" \
  || fail "dirtarget: stderr lacked the directory notice (got: $(cat "$scratch/dirtarget.err"))"

# --- 5. soft-skip when omp is absent ------------------------------------------
# The skip runs through .chezmoitemplates/skip.sh.tmpl as a transient-blocking
# declaration, so it is emphatically NOT a bare exit 0: the derived operator
# notice goes to stdout (the partial reserves stderr for transient-tolerable,
# which exits non-zero) and names both the deferral and the capability probe that
# re-triggers the install, and the skip is recorded under $XDG_STATE_HOME so
# `dotfiles-skips` can report the outstanding work. Assert all three: a notice
# that lost its re-run promise, or a skip that recorded nothing, is exactly the
# silent no-op the declaration contract exists to prevent.

home_skip="$scratch/home-skip"
mkdir -p -- "$home_skip/.local/share/zsh/site-functions"
status=0
env -i PATH="/usr/bin:/bin" HOME="$home_skip" XDG_CACHE_HOME="$scratch/cache-skip" \
  bash "$generator" >"$scratch/skip.out" 2>"$scratch/skip.err" || status=$?
[ "$status" -eq 0 ] || fail "skip: expected a soft-skip exit 0, got $status"
[ ! -e "$home_skip/.local/share/zsh/site-functions/_omp" ] \
  || fail 'skip: _omp was installed even though omp is unavailable'
grep -qF 'install-omp-zsh-completion: omp is not installed; zsh completion generation is deferred' \
  "$scratch/skip.out" \
  || fail "skip: stdout lacked the deferral notice (got: $(cat "$scratch/skip.out" "$scratch/skip.err"))"
grep -qF 'it re-runs automatically once omp-present changes' "$scratch/skip.out" \
  || fail "skip: the skip notice does not promise an automatic re-run (got: $(cat "$scratch/skip.out"))"
[ -s "$home_skip/.local/state/chezmoi/skips/install-omp-zsh-completion__omp-absent" ] \
  || fail 'skip: the declared skip left no state record under XDG_STATE_HOME'

# --- 6. $fpath wiring in the managed zshrc ------------------------------------
# Static ordering first: compinit only scans $fpath as it stands when prezto's
# completion module runs, so an fpath line below the prezto init is inert.

# `|| true` on each assignment is load-bearing: under `set -e` a failed
# command-substitution assignment aborts the script outright, so a missing line
# would kill the run before its own `[ -n ... ] || fail` could name what is
# wrong. Matching on the whole `fpath=...site-functions` line takes the line
# number from `grep -n` directly, rather than from a second grep's match index.
fpath_line=$(grep -n 'fpath=.*site-functions' "$zshrc" | head -n 1 | cut -d: -f1) || true
[ -n "$fpath_line" ] \
  || fail 'dot_config/zsh/dot_zshrc has no fpath entry for ~/.local/share/zsh/site-functions'
prezto_line=$(grep -n '\.zprezto/init\.zsh' "$zshrc" | head -n 1 | cut -d: -f1) || true
[ -n "$prezto_line" ] || fail 'dot_config/zsh/dot_zshrc has no prezto init source line'
[ "$fpath_line" -lt "$prezto_line" ] \
  || fail "fpath line ($fpath_line) must precede the prezto init source ($prezto_line)"

# Behavioural proof. The probe runs the SHIPPED line, extracted verbatim from
# dot_config/zsh/dot_zshrc — not a copy retyped here. A hand-written copy would
# only prove the technique works, and would stay green after the real line
# drifted into something broken or semantically different.
shipped_fpath_line=$(sed -n "${fpath_line}p" "$zshrc") || true
[ -n "$shipped_fpath_line" ] || fail 'could not extract the shipped fpath line from dot_config/zsh/dot_zshrc'

if command -v zsh >/dev/null 2>&1; then
  zhome="$scratch/zhome"
  mkdir -p -- "$zhome/.local/share/zsh/site-functions"
  printf '%s\n' "$VALID_COMPLETION" >"$zhome/.local/share/zsh/site-functions/_omp"

  probe() {
    # $1 = 'on' to run the shipped fpath line, anything else to omit it. Prints
    # the completion function name when compinit resolved it, else nothing.
    local want=$1 line=''
    [ "$want" = on ] && line=$shipped_fpath_line
    env -i PATH="/usr/bin:/bin" HOME="$zhome" zsh -f -c "
      $line
      autoload -Uz compinit
      compinit -u -d \$HOME/.zcompdump-$want >/dev/null 2>&1
      print -r -- \${_comps[omp]:-}
    " 2>/dev/null
  }

  [ "$(probe on)" = '_omp' ] \
    || fail 'zsh did not resolve _omp with the site-functions fpath prepend'
  [ -z "$(probe off)" ] \
    || fail 'zsh resolved _omp WITHOUT the fpath prepend — the negative case is vacuous'

  # --- 7. direct generator output requires compdef ---------------------------
  # Prezto deliberately skips compinit under TERM=dumb. Source the SHIPPED
  # zshrc against a no-op Prezto init and generators that record execution
  # before emitting compdef. A missing guard would both execute every stub and
  # write a command-not-found error; a text-only guard check would miss a source
  # moved outside its conditional.
  dumb_home="$scratch/zshrc-dumb-home"
  dumb_zdotdir="$scratch/zshrc-dumb-zdotdir"
  dumb_bin="$scratch/zshrc-dumb-bin"
  dumb_calls="$scratch/zshrc-dumb.calls"
  mkdir -p -- "$dumb_home/.local/share/zsh/site-functions" \
    "$dumb_zdotdir/.zprezto" "$dumb_bin"
  cp -- "$zshrc" "$dumb_zdotdir/.zshrc"
  : >"$dumb_zdotdir/.zprezto/init.zsh"

  for tool in kubectl minikube helm; do
    cat >"$dumb_bin/$tool" <<'EOF'
#!/bin/sh
printf '%s\n' "${0##*/}" >>"$DUMB_CALLS"
printf '%s\n' '_completion_stub() { :; }' 'compdef _completion_stub completion-stub'
EOF
    chmod 700 "$dumb_bin/$tool"
  done

  status=0
  env -i HOME="$dumb_home" ZDOTDIR="$dumb_zdotdir" TERM=dumb \
    PATH="$dumb_bin:/usr/bin:/bin" DUMB_CALLS="$dumb_calls" \
    zsh -dfc 'source "$ZDOTDIR/.zshrc"' \
    >"$scratch/zshrc-dumb.out" 2>"$scratch/zshrc-dumb.err" || status=$?
  [ "$status" -eq 0 ] \
    || fail "dumb zshrc source failed: $(cat "$scratch/zshrc-dumb.err")"
  [ ! -s "$dumb_calls" ] \
    || fail "dumb zshrc executed compdef generators: $(cat "$dumb_calls")"
  [ ! -s "$scratch/zshrc-dumb.err" ] \
    || fail "dumb zshrc wrote stderr: $(cat "$scratch/zshrc-dumb.err")"

  # A false-only guard would pass the dumb-shell case while disabling useful
  # terminal completions. Initialize compinit in the fake Prezto init, then
  # require all three shipped generator calls to execute without stderr.
  terminal_home="$scratch/zshrc-terminal-home"
  terminal_zdotdir="$scratch/zshrc-terminal-zdotdir"
  terminal_bin="$scratch/zshrc-terminal-bin"
  terminal_calls="$scratch/zshrc-terminal.calls"
  mkdir -p -- "$terminal_home/.local/share/zsh/site-functions" \
    "$terminal_zdotdir/.zprezto" "$terminal_bin"
  cp -- "$zshrc" "$terminal_zdotdir/.zshrc"
  cat >"$terminal_zdotdir/.zprezto/init.zsh" <<'EOF'
autoload -Uz compinit
compinit -i -d "$HOME/.zcompdump"
EOF
  for tool in kubectl minikube helm; do
    cp -- "$dumb_bin/$tool" "$terminal_bin/$tool"
  done

  status=0
  env -i HOME="$terminal_home" ZDOTDIR="$terminal_zdotdir" TERM=xterm-256color \
    PATH="$terminal_bin:/usr/bin:/bin" DUMB_CALLS="$terminal_calls" \
    zsh -dfc 'source "$ZDOTDIR/.zshrc"; (( $+functions[_completion_stub] ))' \
    >"$scratch/zshrc-terminal.out" 2>"$scratch/zshrc-terminal.err" || status=$?
  [ "$status" -eq 0 ] \
    || fail "terminal zshrc source failed: $(cat "$scratch/zshrc-terminal.err")"
  [ "$(wc -l <"$terminal_calls")" -eq 3 ] \
    || fail "terminal zshrc ran the wrong generator count: $(cat "$terminal_calls")"
  [ ! -s "$scratch/zshrc-terminal.err" ] \
    || fail "terminal zshrc wrote stderr: $(cat "$scratch/zshrc-terminal.err")"
else
  printf 'omp-zsh-completion: zsh not on PATH; ran the static ordering check only\n' >&2
  fail 'zsh is required for the behavioural fpath proof'
fi

printf 'omp zsh completion install and fpath wiring tests passed\n'
