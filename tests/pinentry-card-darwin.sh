#!/usr/bin/env bash
# Tests the darwin pinentry-card: the front-stage filter in
# scripts/pinentry-card-darwin and the darwin render of scripts/pinentry-card
# it runs as its child.  The argument is the rendered package, built on any
# platform with a stand-in pinentry_mac path.
set -euo pipefail

package=${1:-}
if [[ $# -ne 1 || -z $package || ! -d $package ]]; then
  printf 'usage: %s PINENTRY-CARD-DARWIN-PACKAGE\n' "${0##*/}" >&2
  exit 2
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pinentry-card-darwin.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
fail() { printf 'pinentry-card-darwin: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'pinentry-card-darwin: ok - %s\n' "$*"; }
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
python3_bin=$(command -v python3)
bash_bin=$(command -v bash)
env_bin=$(command -v env)
timeout_bin=$(command -v timeout)
sleep_bin=$(command -v sleep)

# ---------------------------------------------------------------------------
# RENDER half: the installed files and their platform constants
# ---------------------------------------------------------------------------

filter="$package/bin/pinentry-card"
[[ -f $filter ]] || fail "the package installs no bin/pinentry-card"
[[ -L $package/bin/pinentry && $(readlink "$package/bin/pinentry") == pinentry-card ]] ||
  fail 'bin/pinentry is not a link to pinentry-card'
proxy=$(sed -n 's/^PROXY_PATH = "\(.*\)"$/\1/p' "$filter")
[[ -n $proxy && -f $proxy ]] || fail "the filter's PROXY_PATH names no installed file: '$proxy'"
for rendered in "$filter" "$proxy"; do
  "$python3_bin" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$rendered" "$scratch/compiled.pyc" || fail "$rendered does not compile"
  if grep -qE '@[A-Z_]+@' "$rendered"; then
    fail "$rendered still carries a placeholder: $(grep -oE '@[A-Z_]+@' "$rendered" | head -1)"
  fi
done
grep -qFx 'IS_LINUX = False' "$proxy" || fail 'the darwin proxy is not rendered with IS_LINUX = False'
grep -qFx 'KEYRING_BACKEND = "security"' "$proxy" || fail 'the darwin proxy does not use the security backend'
grep -qFx 'SECRET_TOOL_PATH = "/usr/bin/security"' "$proxy" || fail 'the darwin proxy does not run /usr/bin/security'
grep -qFx 'KEYRING_LOOKUP_TIMEOUT = 5' "$proxy" || fail 'the darwin proxy keyring timeout is not 5 seconds'
grep -qE '^DELEGATE_PATH = "/[^"]*/bin/pinentry-mac"$' "$proxy" || fail 'the darwin proxy does not delegate to pinentry-mac'
delegate_line=$(grep '^DELEGATE_PATH = ' "$proxy")
grep -qFx "LINUX_FALLBACK_PATH = ${delegate_line#DELEGATE_PATH = }" "$proxy" ||
  fail 'the darwin proxy can fall back to a pinentry other than pinentry-mac'
grep -qFx 'SECURITY_PATH = "/usr/bin/security"' "$filter" || fail 'the filter does not run /usr/bin/security'
pass 'the render installs the filter and a darwin proxy with IS_LINUX False, the security backend, and pinentry-mac'

# ---------------------------------------------------------------------------
# BEHAVIOR half: fake pinentry_mac, stub security
# ---------------------------------------------------------------------------

stored_serial='14963605'
stored_pin='te%st pin'
stored_pin_encoded='te%25st pin'
derived="SETKEYINFO n/gnupg-card-pin-$stored_serial"

cat >"$scratch/fake-delegate.py" <<'PYEOF'
"""Stands in for pinentry_mac: logs every Assuan line it receives and answers
OK, or D <tag>/OK on GETPIN, or a late ERR to SETKEYINFO when told to."""
import os
import sys
import time

log_path = os.environ["FAKE_DELEGATE_LOG"]
tag = os.environ.get("FAKE_DELEGATE_TAG", "delegate")
# Seconds to wait before refusing SETKEYINFO, when set.
keyinfo_err_delay = os.environ.get("FAKE_DELEGATE_KEYINFO_ERR_DELAY")
keyinfo_err_delay = float(keyinfo_err_delay) if keyinfo_err_delay is not None else None
out = sys.stdout.buffer
out.write(b"OK Pleased to meet you\n")
out.flush()
while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    with open(log_path, "ab") as fh:
        fh.write(line)
    if line.startswith(b"SETKEYINFO") and keyinfo_err_delay is not None:
        time.sleep(keyinfo_err_delay)
        out.write(b"ERR 83886254 Unknown command <Pinentry>\n")
        out.flush()
        continue
    if line.startswith(b"GETPIN"):
        out.write(("D DELEGATE-PIN-%s\n" % tag).encode())
    out.write(b"OK\n")
    out.flush()
    if line.startswith(b"BYE"):
        break
sys.exit(int(os.environ.get("FAKE_DELEGATE_EXIT", "0")))
PYEOF

make_delegate_shim() {
  local name=$1 tag=$2 log=$3
  cat >"$scratch/bin/$name" <<SHIM
#!$bash_bin
export FAKE_DELEGATE_TAG="$tag"
export FAKE_DELEGATE_LOG="$log"
exec "$python3_bin" "$scratch/fake-delegate.py" "\$@"
SHIM
  chmod +x "$scratch/bin/$name"
}
delegate_log="$scratch/darwin-delegate.log"
fallback_log="$scratch/fallback-delegate.log"
make_delegate_shim fake-pinentry-mac darwin "$delegate_log"
make_delegate_shim fake-fallback-delegate fallback "$fallback_log"

# The stub logs every call, one line of arguments each.  Lookups of the
# shared proxy's gnupg-card-pin item answer per SECURITY_FIND_MODE; deletes
# fail when SECURITY_DELETE_MODE is fail.
security_log="$scratch/security.log"
stored_pin_b64=$(printf '%s' "$stored_pin" | base64 | tr -d '\n')
stored_pin_hex=$("$python3_bin" -c 'import sys; sys.stdout.write(sys.argv[1].encode().hex())' "$stored_pin")
cat >"$scratch/bin/security" <<STUB
#!$bash_bin
printf '%s\n' "\$*" >>"$security_log"
case "\$1" in
  delete-generic-password)
    [[ \${SECURITY_DELETE_MODE:-ok} == fail ]] && exit 44
    exit 0 ;;
  find-generic-password)
    [[ "\$3" == gnupg-card-pin && "\$5" == "$stored_serial" ]] || exit 44
    case "\${SECURITY_FIND_MODE:-missing}" in
      base64) printf 'go-keyring-base64:%s' "$stored_pin_b64"; exit 0 ;;
      hex) printf 'go-keyring-encoded:%s' "$stored_pin_hex"; exit 0 ;;
    esac
    exit 44 ;;
esac
exit 1
STUB
chmod +x "$scratch/bin/security"

sed \
  -e "s#^DELEGATE_PATH = .*#DELEGATE_PATH = \"$scratch/bin/fake-pinentry-mac\"#" \
  -e "s#^LINUX_FALLBACK_PATH = .*#LINUX_FALLBACK_PATH = \"$scratch/bin/fake-fallback-delegate\"#" \
  -e "s#^SECRET_TOOL_PATH = .*#SECRET_TOOL_PATH = \"$scratch/bin/security\"#" \
  -e 's/^KEYRING_LOOKUP_TIMEOUT = 5$/KEYRING_LOOKUP_TIMEOUT = 1/' \
  "$proxy" >"$scratch/proxy"
sed \
  -e "s#^PROXY_PATH = .*#PROXY_PATH = \"$scratch/proxy\"#" \
  -e "s#^SECURITY_PATH = .*#SECURITY_PATH = \"$scratch/bin/security\"#" \
  "$filter" >"$scratch/filter"
grep -qF "$scratch/proxy" "$scratch/filter" || fail 'the test could not retarget PROXY_PATH'
grep -qF "$scratch/bin/security" "$scratch/filter" || fail 'the test could not retarget SECURITY_PATH'

pipe_into() { cat >"$1"; }

run_filter() {
  # run_filter <stdin-text> <out-file> <err-file> [env NAME=value ...]
  local input=$1 out=$2 err=$3 rc=0
  shift 3
  : >"$delegate_log"
  : >"$fallback_log"
  : >"$security_log"
  printf '%s\n' "$input" | "$timeout_bin" 20 "$env_bin" -u DISPLAY -u WAYLAND_DISPLAY "$@" \
    PATH="$scratch/bin:/usr/bin:/bin" "$python3_bin" "$scratch/filter" 2>"$err" | pipe_into "$out" || rc=$?
  if (( rc != 0 )); then
    printf 'pinentry-card-darwin: filter exited %d; its stderr follows:\n%s\n' "$rc" "$(<"$err")" >&2
  fi
  return "$rc"
}

assert_contains() {
  grep -qF -- "$2" "$1" || fail "$3: expected $(printf '%q' "$2") in ${1##*/}: $(tr '\n' '|' <"$1")"
}
assert_not_contains() {
  if grep -qF -- "$2" "$1"; then
    fail "$3: unexpected $(printf '%q' "$2") in ${1##*/}: $(tr '\n' '|' <"$1")"
  fi
}
assert_one_reply_per_command() {
  # <input> <out-file> <label>: the greeting first, then one terminal reply
  # (OK or ERR) per command.
  local commands replies
  [[ $(head -n 1 "$2") == 'OK Pleased to meet you' ]] ||
    fail "$3: the first line is not the greeting: $(tr '\n' '|' <"$2")"
  commands=$(printf '%s\n' "$1" | grep -c .)
  replies=$(grep -cE '^(OK|ERR)( |$)' "$2" || true)
  [[ $replies -eq $((commands + 1)) ]] ||
    fail "$3: $commands commands drew $replies replies (greeting included): $(tr '\n' '|' <"$2")"
}
assert_keyinfo_before_getpin() {
  # <expected-line> <label>: the delegate's line just before each GETPIN is
  # <expected-line>.
  "$python3_bin" - "$delegate_log" "$1" "$2" <<'PYEOF' || exit 1
import sys

lines = open(sys.argv[1], "rb").read().decode().splitlines()
want, label = sys.argv[2], sys.argv[3]
getpins = [i for i, line in enumerate(lines) if line == "GETPIN"]
if not getpins:
    sys.exit("pinentry-card-darwin: FAIL: %s: the delegate never saw GETPIN: %r" % (label, lines))
for i in getpins:
    if i == 0 or lines[i - 1] != want:
        sys.exit("pinentry-card-darwin: FAIL: %s: expected %r before GETPIN, saw %r" % (label, want, lines))
PYEOF
}
assert_deletes() {
  # <count> <label>: that many deletes of pinentry_mac's item for the stored
  # serial, and no other delete of a GnuPG item.
  local want=$1 label=$2 seen all
  seen=$(grep -cFx "delete-generic-password -s GnuPG -a gnupg-card-pin-$stored_serial" "$security_log" || true)
  all=$(grep -c -- '-s GnuPG' "$security_log" || true)
  [[ $seen -eq $want && $all -eq $want ]] ||
    fail "$label: expected $want delete(s) of pinentry_mac's item, saw: $(tr '\n' '|' <"$security_log")"
}
card_desc() {
  # <number> [extra-line]
  printf 'Please unlock the card%%0A%%0ANumber: %s%%0AHolder: Jo Doe' "$1"
  [[ $# -lt 2 ]] || printf '%%0A%s' "$2"
}

# D1 (AE2).  A clean card prompt: the agent's SETKEYINFO --clear is answered by
# the filter, and the delegate gets the serial-derived key id right before
# GETPIN, so pinentry_mac offers the Keychain.
input=$(printf 'OPTION ttyname=/dev/ttys001\nSETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nBYE\n' "$(card_desc '14 963 605')")
run_filter "$input" "$scratch/out1" "$scratch/err1"
assert_keyinfo_before_getpin "$derived" 'D1 clean-prompt'
assert_not_contains "$delegate_log" 'SETKEYINFO --clear' 'D1 clean-prompt'
assert_contains "$scratch/out1" 'D DELEGATE-PIN-darwin' 'D1 clean-prompt'
assert_one_reply_per_command "$input" "$scratch/out1" 'D1 clean-prompt'
assert_deletes 0 'D1 clean-prompt'
pass 'D1 (AE2): a clean card prompt gives pinentry_mac the serial-derived key id before GETPIN'

# D2.  A rejected prompt ("Remaining attempts"): the delegate gets
# SETKEYINFO --clear and never the derived id, and pinentry_mac's item is
# deleted once, whether or not that delete succeeds.
for mode in ok fail; do
  input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nBYE\n' "$(card_desc "$stored_serial" 'Remaining attempts: 2')")
  run_filter "$input" "$scratch/out2" "$scratch/err2" SECURITY_DELETE_MODE="$mode"
  assert_keyinfo_before_getpin 'SETKEYINFO --clear' "D2 remaining-attempts delete-$mode"
  assert_not_contains "$delegate_log" 'gnupg-card-pin' "D2 remaining-attempts delete-$mode"
  assert_one_reply_per_command "$input" "$scratch/out2" "D2 remaining-attempts delete-$mode"
  assert_deletes 1 "D2 remaining-attempts delete-$mode"
done
pass 'D2: a Remaining attempts prompt sends SETKEYINFO --clear and deletes the saved PIN once, even when the delete fails'

# D3.  The same rejection signalled by SETERROR.
for mode in ok fail; do
  input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nSETERROR Bad PIN\nGETPIN\nBYE\n' "$(card_desc "$stored_serial")")
  run_filter "$input" "$scratch/out3" "$scratch/err3" SECURITY_DELETE_MODE="$mode"
  assert_keyinfo_before_getpin 'SETKEYINFO --clear' "D3 seterror delete-$mode"
  assert_not_contains "$delegate_log" 'gnupg-card-pin' "D3 seterror delete-$mode"
  assert_one_reply_per_command "$input" "$scratch/out3" "D3 seterror delete-$mode"
  assert_deletes 1 "D3 seterror delete-$mode"
done
pass 'D3: a SETERROR rejection sends SETKEYINFO --clear and deletes the saved PIN once, even when the delete fails'

# D4.  Two GETPINs under one rejected prompt: one delete, and no derived id
# for either.
input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nGETPIN\nBYE\n' "$(card_desc "$stored_serial" 'Remaining attempts: 1')")
run_filter "$input" "$scratch/out4" "$scratch/err4"
assert_keyinfo_before_getpin 'SETKEYINFO --clear' 'D4 repeated-getpin'
assert_not_contains "$delegate_log" 'gnupg-card-pin' 'D4 repeated-getpin'
assert_one_reply_per_command "$input" "$scratch/out4" 'D4 repeated-getpin'
assert_deletes 1 'D4 repeated-getpin'
pass 'D4: a repeated GETPIN under one rejection deletes once and never sends the derived id'

# D5.  Prompts with no card serial get no injected id: the agent's own
# SETKEYINFO reaches the delegate unchanged, also after a card prompt in the
# same session.
input=$(printf 'SETKEYINFO --clear\nSETPROMPT Admin PIN\nSETDESC Please enter the Admin PIN\nGETPIN\nBYE\n')
run_filter "$input" "$scratch/out5a" "$scratch/err5a"
assert_keyinfo_before_getpin 'SETKEYINFO --clear' 'D5 admin-pin'
assert_not_contains "$delegate_log" 'gnupg-card-pin' 'D5 admin-pin'
assert_one_reply_per_command "$input" "$scratch/out5a" 'D5 admin-pin'
input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nSETKEYINFO n/0123456789ABCDEF\nSETPROMPT Passphrase:\nSETDESC Please enter the passphrase\nGETPIN\nBYE\n' "$(card_desc "$stored_serial")")
run_filter "$input" "$scratch/out5b" "$scratch/err5b"
mapfile -t keyinfo_lines < <(grep '^SETKEYINFO' "$delegate_log")
[[ ${#keyinfo_lines[@]} -eq 2 && ${keyinfo_lines[0]} == "$derived" && ${keyinfo_lines[1]} == 'SETKEYINFO n/0123456789ABCDEF' ]] ||
  fail "D5 passphrase-after-card: expected the derived id, then the agent's own key id; saw: ${keyinfo_lines[*]}"
assert_one_reply_per_command "$input" "$scratch/out5b" 'D5 passphrase-after-card'
assert_deletes 0 'D5 passphrase-after-card'
pass 'D5: a prompt with no card serial passes the agent'"'"'s SETKEYINFO through and injects no id'

# D6.  The darwin proxy picks pinentry_mac with no DISPLAY or WAYLAND_DISPLAY
# (run_filter unsets both), never the Linux fallback.
input=$(printf 'SETPROMPT PIN\nBYE\n')
run_filter "$input" "$scratch/out6" "$scratch/err6"
[[ -s $delegate_log ]] || fail 'D6 delegate-choice: pinentry_mac never ran with no DISPLAY/WAYLAND_DISPLAY'
[[ ! -s $fallback_log ]] || fail 'D6 delegate-choice: the Linux fallback ran on darwin'
pass 'D6: with no DISPLAY or WAYLAND_DISPLAY the darwin proxy still runs pinentry_mac'

# D7.  The shared proxy's gnupg-card-pin item still answers a clean prompt
# through the security backend, base64 or hex encoded, and the derived
# SETKEYINFO reply is consumed before the child's direct answer.
for find_mode in base64 hex; do
  input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nBYE\n' "$(card_desc "$stored_serial")")
  run_filter "$input" "$scratch/out7" "$scratch/err7" SECURITY_FIND_MODE="$find_mode"
  assert_contains "$scratch/out7" "D $stored_pin_encoded" "D7 keychain-$find_mode"
  assert_not_contains "$delegate_log" 'GETPIN' "D7 keychain-$find_mode"
  assert_contains "$delegate_log" "$derived" "D7 keychain-$find_mode"
  assert_one_reply_per_command "$input" "$scratch/out7" "D7 keychain-$find_mode"
done
pass 'D7: a gnupg-card-pin Keychain item still answers through the security backend, one reply per command'

# D8.  The child's reply to the injected SETKEYINFO is consumed before GETPIN
# goes out: a late ERR from pinentry_mac never reaches the agent as the reply
# to a GETPIN the shared proxy answered from its own Keychain item.
input=$(printf 'SETKEYINFO --clear\nSETPROMPT PIN\nSETDESC %s\nGETPIN\nBYE\n' "$(card_desc "$stored_serial")")
run_filter "$input" "$scratch/out8" "$scratch/err8" SECURITY_FIND_MODE=base64 FAKE_DELEGATE_KEYINFO_ERR_DELAY=0.5
assert_contains "$scratch/out8" "D $stored_pin_encoded" 'D8 late-keyinfo-reply'
assert_not_contains "$scratch/out8" 'ERR' 'D8 late-keyinfo-reply'
assert_one_reply_per_command "$input" "$scratch/out8" 'D8 late-keyinfo-reply'
pass 'D8: the injected SETKEYINFO reply is consumed before GETPIN, so a late ERR never reaches the agent'

# D9.  Stdin closing ends the filter with the child's exit status.
rc=0
run_filter 'GETINFO pid' "$scratch/out9" "$scratch/err9" FAKE_DELEGATE_EXIT=7 || rc=$?
[[ $rc -eq 7 ]] || fail "D9 eof: expected the delegate's status 7 through both stages, got $rc"
assert_contains "$delegate_log" 'GETINFO pid' 'D9 eof'
pass 'D9: stdin closing exits with the delegate'"'"'s status through both stages'

# D10.  SIGTERM reaches the child and the filter exits promptly.
fifo="$scratch/in10"
mkfifo "$fifo"
: >"$delegate_log"
"$env_bin" -u DISPLAY -u WAYLAND_DISPLAY PATH="$scratch/bin:/usr/bin:/bin" \
  "$python3_bin" "$scratch/filter" <"$fifo" >"$scratch/out10" 2>"$scratch/err10" &
filter_pid=$!
exec {filter_in}>"$fifo"
printf 'GETINFO pid\n' >&"$filter_in"
for (( i = 0; i < 100; i++ )); do
  grep -qF 'GETINFO pid' "$delegate_log" && break
  "$sleep_bin" 0.1
done
grep -qF 'GETINFO pid' "$delegate_log" || fail "D10 sigterm: the delegate never received a line: $(<"$scratch/err10")"
kill -TERM "$filter_pid"
for (( i = 0; i < 80; i++ )); do
  kill -0 "$filter_pid" 2>/dev/null || break
  "$sleep_bin" 0.1
done
if kill -0 "$filter_pid" 2>/dev/null; then
  kill -KILL "$filter_pid" 2>/dev/null || true
  fail "D10 sigterm: the filter was still running 8s after SIGTERM: $(<"$scratch/err10")"
fi
wait "$filter_pid" || true
exec {filter_in}>&-
pass 'D10: SIGTERM stops the filter and its child promptly'

# D11.  Both stages have answered and exited, but the filter's relay thread is
#       slow to pass the replies on, as on a loaded builder: this copy of the
#       filter stalls it 0.5 seconds per line, about 3.5 seconds in all, and
#       every reply must still reach the agent.
sed '/^            line = child_stdout.readline()$/a\            time.sleep(0.5)' \
  "$scratch/filter" >"$scratch/filter-slow-relay"
grep -qFx '            time.sleep(0.5)' "$scratch/filter-slow-relay" || fail 'D11 slow-relay: the test could not slow the relay down'
input=$(printf 'OPTION ttyname=/dev/ttys001\nSETTITLE\nSETOK\nSETCANCEL\nGETINFO pid\nSETQUALITYBAR\n')
: >"$delegate_log"
printf '%s\n' "$input" | "$timeout_bin" 20 "$env_bin" -u DISPLAY -u WAYLAND_DISPLAY \
  PATH="$scratch/bin:/usr/bin:/bin" "$python3_bin" "$scratch/filter-slow-relay" 2>"$scratch/err11" |
  pipe_into "$scratch/out11" ||
  fail "D11 slow-relay: the filter failed: $(<"$scratch/err11")"
assert_one_reply_per_command "$input" "$scratch/out11" 'D11 slow-relay'
pass 'D11: replies both stages wrote before exiting reach the agent even when the filter relay is seconds behind'

# D12.  The slow filter relay also goes unscheduled for 2.5 seconds inside one
#       write, past DIALOG_GRACE, while the agent is still reading: the filter
#       must keep waiting rather than take the write for an agent that stopped.
sed -e '/^                client_out.write(line)$/{n' \
  -e 'a\                pump.writes = getattr(pump, "writes", 0) + 1' \
  -e 'a\                time.sleep(2.5 if pump.writes == 3 else 0)' -e '}' \
  "$scratch/filter-slow-relay" >"$scratch/filter-stalled-write"
[[ $(grep -cFx '                time.sleep(2.5 if pump.writes == 3 else 0)' "$scratch/filter-stalled-write") -eq 1 ]] ||
  fail 'D12 stalled-write: the test could not stall the relay inside a write'
: >"$delegate_log"
printf '%s\n' "$input" | "$timeout_bin" 20 "$env_bin" -u DISPLAY -u WAYLAND_DISPLAY \
  PATH="$scratch/bin:/usr/bin:/bin" "$python3_bin" "$scratch/filter-stalled-write" 2>"$scratch/err12" |
  pipe_into "$scratch/out12" ||
  fail "D12 stalled-write: the filter failed: $(<"$scratch/err12")"
assert_one_reply_per_command "$input" "$scratch/out12" 'D12 stalled-write'
pass 'D12: a write the filter relay is slow to finish is not taken for an agent that stopped reading'

pass 'all darwin pinentry-card scenarios passed'
