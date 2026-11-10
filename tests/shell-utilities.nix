/*
  Check interface:

    import ./tests/shell-utilities.nix { inherit pkgs self; }

  Asserts that the shell-scripting utilities reach user `h82` on every
  configuration `tests/lib/configurations.nix` yields, bootstrap outputs
  included, so a change that gates the profile on `my.bootstrap` fails here.

  The expected executables are listed here rather than read from
  home/h82/shell/utilities.nix, so removing a package from the module fails
  the check. Each one runs from home.path against a fixed input and its
  output is compared, because an existence test alone passes for a binary
  that exists but does not work.

  Every lookup carries an `or` fallback so a mutation that removes a declaration
  reaches the builder as a failing assertion rather than an evaluation error.
  See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  Each configuration runs in a subshell and records failures in a file, so one
  red build names every broken assertion across every configuration. The
  helper's guard runs first, so an empty configuration list fails the build
  instead of passing it.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  assertEntry =
    entry:
    let
      homePath = entry.user.home.path or "";
    in
    ''
      checkHost ${esc entry.name} ${esc homePath}
    '';
in
pkgs.runCommand "shell-utilities-tests" { } ''
  ${configurations.guard}
  failures=$PWD/failures
  : > "$failures"

  checkHost() (
    host=$1 homePath=$2
    fail() { echo "$host: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -d "$homePath/bin" ]; then
      fail "home-manager renders no home.path"
      exit
    fi
    bin=$homePath/bin

    # expect <tool> <expected> <command...>: runs the command and compares its
    # stdout; a missing executable is reported once instead of as a mismatch.
    expect() {
      tool=$1 expected=$2
      shift 2
      if [ ! -x "$bin/$tool" ]; then
        fail "$tool is not in home.path"
        return
      fi
      actual=$("$@" 2>&1) || { fail "$tool exited non-zero: $actual"; return; }
      [ "$actual" = "$expected" ] || fail "$tool printed '$actual', expected '$expected'"
    }

    work=$(mktemp -d)
    cd "$work"
    export HOME=$work/home
    mkdir -p "$HOME" tree
    printf 'alpha\nneedle\n' > haystack
    touch tree/needle.txt
    printf '#!/bin/sh\necho "$1"\n' > clean.sh

    expect jq 1 sh -c 'printf "{\"a\":1}" | "$0" .a' "$bin/jq"
    # yq-go edits YAML in place; the Python yq wrapper would print JSON.
    expect yq "$(printf 'a: 1\nb: 2')" sh -c 'printf "a: 1\n" | "$0" ".b = 2"' "$bin/yq"
    expect rg needle "$bin/rg" --no-filename --no-line-number needle haystack
    expect fd needle.txt "$bin/fd" --base-directory tree needle
    expect fzf banana sh -c 'printf "apple\nbanana\n" | "$0" --filter ban' "$bin/fzf"
    expect bat hello sh -c 'printf "hello\n" | "$0" --plain --paging=never --color=never' "$bin/bat"
    expect tree needle.txt sh -c '"$0" --noreport -i tree | tail -n 1' "$bin/tree"
    expect file text/plain "$bin/file" --brief --mime-type haystack
    expect zip "" "$bin/zip" -q archive.zip haystack
    expect unzip "$(cat haystack)" "$bin/unzip" -p archive.zip haystack
    expect shellcheck "" "$bin/shellcheck" clean.sh
    expect shfmt "if true; then echo hi; fi" sh -c 'printf "if true;then echo hi;fi\n" | "$0"' "$bin/shfmt"
    expect sponge "" sh -c 'printf "soaked\n" | "$0" sponged' "$bin/sponge"
    [ "$(cat sponged 2>/dev/null)" = soaked ] || fail "sponge did not write its input to the file"
    expect wget "GNU Wget" sh -c '"$0" --version | head -n 1 | cut -d " " -f 1-2' "$bin/wget"
    # The build sandbox has no Wayland compositor, so run --version, which
    # exits before connecting to a display.
    expect wl-copy wl-clipboard sh -c '"$0" --version | head -n 1 | cut -d " " -f 1' "$bin/wl-copy"
    expect wl-paste wl-clipboard sh -c '"$0" --version | head -n 1 | cut -d " " -f 1' "$bin/wl-paste"

    # pgrep and pkill target a sleep this subshell owns, matched by parent and
    # name. The unreaped child stays visible as a zombie, so wait on it rather
    # than probing: 143 means SIGTERM from pkill ended it. The sleep is short
    # so a pkill that exits 0 without signalling fails instead of hanging.
    # The background child is a bash fork until it execs sleep, so wait for
    # its name to change before matching it by name.
    sleep 5 &
    sleeper=$!
    for _ in $(seq 50); do
      [ "$(cat "/proc/$sleeper/comm" 2>/dev/null)" = sleep ] && break
      sleep 0.1
    done
    expect pgrep "$sleeper" "$bin/pgrep" -P "$BASHPID" -x sleep
    expect pkill "" "$bin/pkill" -P "$BASHPID" -x sleep
    [ -x "$bin/pkill" ] || kill "$sleeper"
    wait "$sleeper" && status=0 || status=$?
    [ "$status" = 143 ] || fail "pkill did not stop its target: wait returned $status"

    # lsof reports the file behind a descriptor this subshell holds open.
    exec 3< haystack
    expect lsof "$PWD/haystack" sh -c '"$0" -a -p "$1" -d 3 -Fn 2>/dev/null | sed -n "s/^n//p"' "$bin/lsof" "$BASHPID"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
