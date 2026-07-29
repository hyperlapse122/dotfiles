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
# (expect) covers hosts that ship it instead.
pty_provider=''
if command -v script >/dev/null 2>&1; then
  pty_provider=script
elif command -v unbuffer >/dev/null 2>&1; then
  pty_provider=unbuffer
fi

# With neither provider the transport half cannot run. That is a legitimate
# local skip, but in CI it would green the job while proving nothing about the
# behavior this gate exists to protect, so fail there instead of skipping.
if [ -z "$pty_provider" ]; then
  if [ -n "${CI:-}" ]; then
    fail 'no pty provider in CI (need script(1) or unbuffer); the transport cases cannot run and must not be skipped'
  fi
  printf 'tmux-kitty-passthrough: options and pane environment OK (tmux %s)\n' "$tmux_version"
  printf 'tmux-kitty-passthrough: SKIP transport cases locally — no pty provider (need script(1) or unbuffer)\n'
  exit 0
fi

wrapped="CEWRAPPED$$"
bare="CEBARE$$"
fidelity="CEFIDELITY$$"
# The literal bytes the emitter writes for the fidelity probe: ESC [ 1 m <text>.
# Matched with grep -F so the bracket stays a bracket.
sgr_marker=$(printf '\033[1m%s' "$fidelity")

emit="$scratch/emit.sh"
cat >"$emit" <<EOF
#!/usr/bin/env bash
# \$1 = the socket of the server running this pane.
#
# allow-passthrough=on forwards ONLY from a visible pane, so emitting before the
# client has attached would lose the payload for a reason unrelated to the
# setting. Wait for a client, then let it paint.
for _ in \$(seq 1 100); do
  case "\$(tmux -S "\$1" list-clients -F x 2>/dev/null)" in
    x*) break ;;
  esac
  sleep 0.1
done
sleep 0.5

# Three probes, each isolating one layer:
#
# 1. A bold-SGR marker: proves the capture path preserves raw control bytes.
printf '\033[1m%s\033[0m' '$fidelity'
# 2. A BARE Kitty APC: tmux forwards this whatever allow-passthrough says, so it
#    proves the client can receive APC bytes at all. Without it, a missing
#    wrapped payload is ambiguous between "tmux refused" and "this environment
#    never delivers APCs".
printf '\033_G%s\033\\\\' '$bare'
# 3. The DCS-WRAPPED Kitty APC, escapes doubled — the shape omp emits, and the
#    only one allow-passthrough gates.
printf '\033Ptmux;\033\033_G%s\033\033\\\\\033\\\\' '$wrapped'
sleep 1
EOF
chmod 700 "$emit"

# A config that loads the managed file and then closes the passthrough gate.
# Sourcing the real file keeps the negative case honest: the ONLY difference
# between the two runs is the one setting under test.
printf 'source-file %s\nset -g allow-passthrough off\n' "$config" >"$scratch/off.conf"

pty_run() { # $1 = socket, $2 = config, $3 = capture path
  local run_sock=$1 run_conf=$2 cap=$3 pane_cmd
  # tmux takes the pane program as ONE shell command string, so quote the words
  # here or a scratch path containing a space would split into bogus arguments.
  pane_cmd=$(printf '%q %q' "$emit" "$run_sock")
  case "$pty_provider" in
    script)
      # script(1) also takes a single command string.
      local cmd
      cmd=$(printf 'tmux -S %q -f %q new-session %q' "$run_sock" "$run_conf" "$pane_cmd")
      TERM=xterm-256color script -q -e -c "$cmd" "$cap" >/dev/null 2>&1 || true
      ;;
    unbuffer)
      TERM=xterm-256color unbuffer \
        tmux -S "$run_sock" -f "$run_conf" new-session "$pane_cmd" >"$cap" 2>&1 || true
      ;;
  esac
  tmux -S "$run_sock" kill-server 2>/dev/null || true
}

# Fixed-string match, and always a number. `grep -c` prints 0 and exits 1 on no
# match, but prints NOTHING when the file is unreadable — an empty result would
# then satisfy a "!= 0" assertion and pass without proving anything. -F also
# keeps the ESC-bearing patterns literal instead of letting `[1m` be read as a
# bracket expression.
count() {
  local n
  n=$(LC_ALL=C grep -acF -- "$1" "$2" 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$n" ;;
  esac
}

# Run one transport case and establish both preconditions before its verdict is
# read: the capture must be byte-faithful, and the client must be able to receive
# APC bytes at all. Either precondition failing makes the wrapped-payload verdict
# meaningless, so each fails loudly with its own cause instead of skewing it.
capture_case() { # $1 = label, $2 = socket, $3 = config, $4 = capture path
  pty_run "$2" "$3" "$4"
  [ -s "$4" ] || fail "the $pty_provider capture for the $1 case is empty; the pty run produced nothing"
  [ "$(count "$sgr_marker" "$4")" != '0' ] \
    || fail "the $pty_provider capture for the $1 case dropped the raw SGR marker; the capture path is not byte-faithful"
  [ "$(count "$bare" "$4")" != '0' ] \
    || fail "the $1 case never delivered a BARE Kitty APC to the client, which tmux forwards regardless of allow-passthrough; this environment cannot carry APC bytes to a tmux client, so the wrapped-payload verdict would be meaningless"
}

diagnose() { # $1 = capture path
  printf 'tmux-kitty-passthrough: capture diagnostics\n' >&2
  printf '  tmux version    : %s\n' "$tmux_version" >&2
  printf '  pty provider    : %s\n' "$pty_provider" >&2
  printf '  capture bytes   : %s\n' "$(wc -c <"$1" 2>/dev/null || echo 0)" >&2
  printf '  raw SGR marker  : %s (nonzero = capture path is byte-faithful)\n' "$(count "$sgr_marker" "$1")" >&2
  printf '  bare APC        : %s (nonzero = client receives APC bytes)\n' "$(count "$bare" "$1")" >&2
  printf '  wrapped APC     : %s (nonzero = tmux forwarded the gated form)\n' "$(count "$wrapped" "$1")" >&2
  printf '  verbatim DCS    : %s (nonzero = tmux passed the wrapper through unparsed)\n' "$(count 'Ptmux;' "$1")" >&2
}

# --- 3. the transport pair ----------------------------------------------------

capture_case 'passthrough-on' "$sock" "$config" "$scratch/cap-on"
if [ "$(count "$wrapped" "$scratch/cap-on")" = '0' ]; then
  diagnose "$scratch/cap-on"
  fail 'passthrough is on but the wrapped Kitty graphics payload never reached the client'
fi

# The negative case is what proves the setting is the cause rather than something
# incidental: the bare probe still arrives, and only the gated form disappears.
capture_case 'passthrough-off' "${sock}-off" "$scratch/off.conf" "$scratch/cap-off"
if [ "$(count "$wrapped" "$scratch/cap-off")" != '0' ]; then
  diagnose "$scratch/cap-off"
  fail 'passthrough is off but the wrapped Kitty graphics payload still reached the client'
fi

# --- 3b. drift guard on the substitution -------------------------------------

# The transport cases assert on a hand-built payload, not on omp itself. That
# substitution is only valid while omp still wraps its graphics emissions in the
# tmux passthrough DCS. When omp is installed, prove that; when it is not (CI),
# say so rather than implying the check ran.
if command -v omp >/dev/null 2>&1; then
  omp_bin=$(command -v omp)
  if LC_ALL=C grep -qaF -- 'Ptmux;' "$omp_bin" 2>/dev/null \
    && LC_ALL=C grep -qaF -- 'packages/tui/src/tmux.ts' "$omp_bin" 2>/dev/null; then
    printf 'tmux-kitty-passthrough: drift guard OK — omp still carries its tmux passthrough wrapper\n'
  else
    fail 'omp no longer shows a tmux passthrough wrapper; the hand-built payload may no longer match what omp emits, so re-derive the transport assertion against omp'
  fi
else
  printf 'tmux-kitty-passthrough: drift guard not applicable — omp is not installed here\n'
fi

# --- 4. isolation -------------------------------------------------------------

default_after=$(tmux show -gv allow-passthrough 2>/dev/null || echo '<no-default-server>')
[ "$default_before" = "$default_after" ] \
  || fail "this run changed the default socket's allow-passthrough ($default_before -> $default_after)"

printf 'tmux-kitty-passthrough (tmux %s, pty via %s): OK\n' "$tmux_version" "$pty_provider"
