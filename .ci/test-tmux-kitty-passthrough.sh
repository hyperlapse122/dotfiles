#!/usr/bin/env bash
# Isolated verification for the managed tmux config that carries omp's inline
# image path (U1/U2 of docs/plans/2026-07-29-006-fix-tmux-kitty-image-passthrough-plan.md).
#
# Proves three things against an isolated tmux server, never the user's:
#   1. the managed config applies its four settings, including the pane-visible
#      PI_FORCE_IMAGE_PROTOCOL value (a session-environment listing does NOT
#      show a globally-set variable, so the assertion runs inside a pane);
#   2. tmux FORWARDS a Kitty graphics APC wrapped in the tmux passthrough DCS
#      when allow-passthrough is on, and DROPS it when off — the negative case
#      is what proves the setting is the cause rather than a vacuous pass;
#   3. the capture path preserves raw bytes, asserted before the transport
#      cases so a mangling pty provider fails loudly instead of silently
#      inverting them.
#
# Pixels are out of scope here: CI has no Kitty and no display, so the visual
# half stays a documented manual check (see the plan's Verification Contract).
#
# Never runs chezmoi apply and never addresses the default tmux socket. Its own
# sockets live inside the scratch directory via -S, so nothing lands in the
# shared /tmp tmux directory and cleanup removes them with the scratch tree.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/dot_config/tmux/tmux.conf"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/tmux-kitty-passthrough.XXXXXX")
sock="$scratch/sock"

cleanup() {
  tmux -S "$sock" kill-server 2>/dev/null || true
  tmux -S "${sock}-off" kill-server 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

fail() {
  printf 'tmux-kitty-passthrough: FAIL: %s\n' "$1" >&2
  exit 1
}

command -v tmux >/dev/null 2>&1 || fail 'tmux not found on PATH'
[ -f "$config" ] || fail "managed tmux config not found at dot_config/tmux/tmux.conf"

# Record the default socket's value up front so the isolation check at the end
# can prove this run never touched it. A missing default server is fine.
default_before=$(tmux show -gv allow-passthrough 2>/dev/null || echo '<no-default-server>')

# --- 1. options and pane environment -----------------------------------------

tmux -S "$sock" -f "$config" new-session -d -s opts 'sleep 120' \
  || fail 'the managed config did not load on an isolated server'

opt() { tmux -S "$sock" show -gv "$1" 2>/dev/null || true; }

[ "$(opt allow-passthrough)" = 'on' ] \
  || fail "allow-passthrough is '$(opt allow-passthrough)', expected 'on'"
[ "$(opt extended-keys)" = 'on' ] \
  || fail "extended-keys is '$(opt extended-keys)', expected 'on'"

# extended-keys-format arrived in tmux 3.5. Use tmux's own comparison so this
# assertion agrees with the %if guard inside the config rather than reimplementing
# version parsing. The comparison is lexical, which is correct for this threshold.
tmux_version=$(tmux -S "$sock" display -p '#{version}')
if [ "$(tmux -S "$sock" display -p '#{>=:#{version},3.5}')" = '1' ]; then
  [ "$(opt extended-keys-format)" = 'csi-u' ] \
    || fail "extended-keys-format is '$(opt extended-keys-format)', expected 'csi-u'"
else
  printf 'tmux-kitty-passthrough: skip extended-keys-format (tmux %s predates 3.5)\n' "$tmux_version"
fi

# The forced protocol must reach a real pane process. Assert it for a session
# created after the server was already running and for a new window inside an
# existing session — the two paths aoe actually uses.
pane_env() { # $1 = label, $2 = tmux subcommand words
  local out="$scratch/paneenv-$1"
  shift
  tmux -S "$sock" "$@" "printenv PI_FORCE_IMAGE_PROTOCOL > '$out' 2>&1 || echo UNSET > '$out'; sleep 30"
  local waited=0
  while [ ! -s "$out" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  tr -d '[:space:]' <"$out" 2>/dev/null || true
}

got=$(pane_env newsession new-session -d -s envA)
[ "$got" = 'kitty' ] || fail "a pane in a newly created session saw PI_FORCE_IMAGE_PROTOCOL='$got', expected 'kitty'"

got=$(pane_env newwindow new-window -d -t opts)
[ "$got" = 'kitty' ] || fail "a new window in an existing session saw PI_FORCE_IMAGE_PROTOCOL='$got', expected 'kitty'"

tmux -S "$sock" kill-server 2>/dev/null || true

# --- 2. pty provider ---------------------------------------------------------

# tmux only forwards a passthrough payload to an ATTACHED client, so the
# transport cases need a pty. util-linux script(1) covers CI runners; unbuffer
# (expect) covers hosts that ship it instead. With neither, skip the transport
# half rather than reporting a pass we did not earn.
pty_provider=''
if command -v script >/dev/null 2>&1; then
  pty_provider=script
elif command -v unbuffer >/dev/null 2>&1; then
  pty_provider=unbuffer
fi

if [ -z "$pty_provider" ]; then
  printf 'tmux-kitty-passthrough: options and pane environment OK (tmux %s)\n' "$tmux_version"
  printf 'tmux-kitty-passthrough: SKIP transport cases — no pty provider (need script(1) or unbuffer)\n'
  exit 0
fi

marker="CETMUXPASSTHRU$$"
fidelity="CEFIDELITY$$"

emit="$scratch/emit.sh"
cat >"$emit" <<EOF
#!/usr/bin/env bash
# A bold-SGR marker proves the capture path preserves raw control bytes.
printf '\033[1m%s\033[0m' '$fidelity'
# A Kitty graphics APC wrapped in the tmux passthrough DCS, escapes doubled —
# the same shape omp emits.
printf '\033Ptmux;\033\033_G%s\033\033\\\\\033\\\\' '$marker'
sleep 1
EOF
chmod 700 "$emit"

# A config that loads the managed file and then closes the passthrough gate.
# Sourcing the real file keeps the negative case honest: the ONLY difference
# between the two runs is the one setting under test.
printf 'source-file %s\nset -g allow-passthrough off\n' "$config" >"$scratch/off.conf"

pty_run() { # $1 = socket, $2 = config, $3 = capture path
  local run_sock=$1 run_conf=$2 cap=$3
  case "$pty_provider" in
    script)
      TERM=xterm-256color script -q -e -c \
        "tmux -S $run_sock -f $run_conf new-session $emit" "$cap" >/dev/null 2>&1 || true
      ;;
    unbuffer)
      TERM=xterm-256color unbuffer \
        tmux -S "$run_sock" -f "$run_conf" new-session "$emit" >"$cap" 2>&1 || true
      ;;
  esac
  tmux -S "$run_sock" kill-server 2>/dev/null || true
}

count() { LC_ALL=C grep -ac -- "$1" "$2" 2>/dev/null || true; }

# Run one transport case and assert the capture is usable before its verdict is
# read. Fidelity comes first: if the capture mangled control bytes, the marker
# verdict below is meaningless, so it must fail loudly rather than skew it.
capture_case() { # $1 = label, $2 = socket, $3 = config, $4 = capture path
  pty_run "$2" "$3" "$4"
  [ -s "$4" ] || fail "the $pty_provider capture for the $1 case is empty; the pty run produced nothing"
  [ "$(count "$(printf '\033')[1m$fidelity" "$4")" != '0' ] \
    || fail "the $pty_provider capture for the $1 case dropped the raw SGR marker; the capture path is not byte-faithful"
}

# --- 3. the transport pair ----------------------------------------------------

capture_case 'passthrough-on' "$sock" "$config" "$scratch/cap-on"
[ "$(count "$marker" "$scratch/cap-on")" != '0' ] \
  || fail 'passthrough is on but the Kitty graphics payload never reached the client'

# The negative case is what proves the setting is the cause. tmux forwards a
# BARE Kitty APC whatever this option says and gates only the DCS-wrapped form
# the emitter above uses, which is the form omp emits.
capture_case 'passthrough-off' "${sock}-off" "$scratch/off.conf" "$scratch/cap-off"
[ "$(count "$marker" "$scratch/cap-off")" = '0' ] \
  || fail 'passthrough is off but the Kitty graphics payload still reached the client'

# --- 4. isolation -------------------------------------------------------------

default_after=$(tmux show -gv allow-passthrough 2>/dev/null || echo '<no-default-server>')
[ "$default_before" = "$default_after" ] \
  || fail "this run changed the default socket's allow-passthrough ($default_before -> $default_after)"

printf 'tmux-kitty-passthrough (tmux %s, pty via %s): OK\n' "$tmux_version" "$pty_provider"
