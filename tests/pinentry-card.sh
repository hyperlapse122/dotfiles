#!/usr/bin/env bash
set -euo pipefail

wrapper=${1:-}
if [[ ( $# -ne 1 && $# -ne 5 ) || -z $wrapper || ! -f $wrapper ]]; then
  printf 'usage: %s RAW_WRAPPER [INSTALLED_WRAPPER QT CURSES SECRET_TOOL]\n' "${0##*/}" >&2
  exit 2
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pinentry-card.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
fail() { printf 'pinentry-card: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'pinentry-card: ok - %s\n' "$*"; }
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
python3_bin=$(command -v python3)
bash_bin=$(command -v bash)
env_bin=$(command -v env)
timeout_bin=$(command -v timeout)
base64_bin=$(command -v base64)
tr_bin=$(command -v tr)
sleep_bin=$(command -v sleep)
rm_bin=$(command -v rm)
"$python3_bin" -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$wrapper" "$scratch/wrapper.pyc" || fail 'production wrapper does not compile'
grep -qF 'IS_LINUX = True' "$wrapper" || fail 'production wrapper is not Linux-only'
grep -qF 'KEYRING_BACKEND = "secret-tool"' "$wrapper" || fail 'production wrapper does not use Secret Service'
pass 'production wrapper syntax and safety constants are present'
rendered_gnome="$wrapper"

# ---------------------------------------------------------------------------
# BEHAVIOR half: fake delegate, stub keyring commands
# ---------------------------------------------------------------------------

# The PIN chosen for every "answered" scenario below deliberately carries a
# '%' and a space, so every happy-path assertion also proves percent-encoding
# without a separate fixture.
stored_pin='te%st pin'
stored_pin_encoded='te%25st pin'
stored_serial='14963605'
# The two cards added in the ed25519 rotation.  A serial is laser-printed on
# the device and is not a secret, but it stays confined to these fixtures.
serial_nfc='37522734'
serial_nano='37620322'
pin_nfc='nfc%pin a'
pin_nano='nano%pin b'
pin_nfc_encoded=${pin_nfc//%/%25}
pin_nano_encoded=${pin_nano//%/%25}

cat >"$scratch/fake-delegate.py" <<'PYEOF'
#!$python3_bin
"""Test double for the real desktop pinentry: logs every Assuan command line
it receives (byte-exact) and answers OK, or D <tag>/OK on GETPIN, unless told
to hang on GETPIN to simulate a still-open dialog."""
import os
import sys
import time

log_path = os.environ["FAKE_DELEGATE_LOG"]
hang = os.environ.get("FAKE_DELEGATE_HANG_ON_GETPIN") == "1"
tag = os.environ.get("FAKE_DELEGATE_TAG", "delegate")
exit_status = int(os.environ.get("FAKE_DELEGATE_EXIT", "0"))
stream_after_eof = os.environ.get("FAKE_DELEGATE_STREAM_AFTER_EOF") == "1"
flood_on_getpin = os.environ.get("FAKE_DELEGATE_FLOOD_ON_GETPIN") == "1"
# Seconds to stall before the greeting or before exiting at EOF: a healthy
# delegate on a loaded machine, slow to start or to wind down.
start_delay = float(os.environ.get("FAKE_DELEGATE_START_DELAY", "0"))
exit_delay = float(os.environ.get("FAKE_DELEGATE_EXIT_DELAY", "0"))


def log(data):
    with open(log_path, "ab") as fh:
        fh.write(data)


def fork_flooder():
    # A grandchild that inherits the delegate's stdout keeps the wrapper's
    # relay thread writing, whatever the delegate itself does next, until the
    # wrapper is gone and the pipe breaks.  One page per write fills a pipe
    # to within one page, so a test can measure it.
    if os.fork() != 0:
        return
    filler = b"S" * 4095 + b"\n"
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            out.write(filler)
            out.flush()
    except OSError:
        pass
    os._exit(0)


out = sys.stdout.buffer
time.sleep(start_delay)
out.write(b"OK Pleased to meet you\n")
out.flush()

while True:
    line = sys.stdin.buffer.readline()
    if not line:
        break
    log(line)
    cmd = (line[:-1] if line.endswith(b"\n") else line).split(b" ", 1)[0]
    if cmd == b"GETPIN" and hang:
        time.sleep(3600)
        continue
    if cmd == b"GETPIN" and flood_on_getpin:
        # No reply: the delegate's own writes must never block on the full
        # pipe, so it can still exit with its status at EOF.
        fork_flooder()
        continue
    if cmd == b"GETPIN":
        out.write(("D DELEGATE-PIN-%s\n" % tag).encode())
        out.write(b"OK\n")
        out.flush()
        continue
    if cmd == b"BYE":
        out.write(b"OK\n")
        out.flush()
        break
    out.write(b"OK\n")
    out.flush()
if stream_after_eof:
    fork_flooder()
time.sleep(exit_delay)
sys.exit(exit_status)
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

gnome_log="$scratch/gnome-delegate.log"
fallback_log="$scratch/fallback-delegate.log"
make_delegate_shim fake-gnome-delegate gnome "$gnome_log"
make_delegate_shim fake-fallback-delegate fallback "$fallback_log"

# secret-tool lookup|clear service gnupg-card-pin username <serial>
keyring_dir="$scratch/keyring"
clear_log="$scratch/secret-tool-clear.log"
cat >"$scratch/bin/secret-tool" <<STUB
#!$bash_bin
mode=\${KEYRING_STUB_MODE:-ok}
op=\$1
serial=\$5
case "\$op:\$mode" in
  clear:clear-fail) exit 1 ;;
  clear:clear-sleep) "$sleep_bin" 9; exit 0 ;;
esac
case "\$mode" in
  fail-nonzero) printf 'PRIVATE-SUBPROCESS-OUTPUT'; printf 'PRIVATE-SUBPROCESS-ERROR' >&2; exit 1 ;;
  empty) printf ''; exit 0 ;;
  sleep) "$sleep_bin" 3; exit 0 ;;
  cold) "$sleep_bin" 6 ;;
esac
if [[ "\$op" == clear ]]; then
  printf '%s\n' "\$serial" >>"$clear_log"
  "$rm_bin" -f "$keyring_dir/\$serial"
  exit 0
fi
if [[ ( "\$op" == lookup || "\$op" == find-generic-password ) && -f "$keyring_dir/\$serial" ]]; then
  printf '%s' "\$(<"$keyring_dir/\$serial")"
  exit 0
fi
exit 1
STUB
chmod +x "$scratch/bin/secret-tool"

reset_keyring() {
  rm -rf -- "$keyring_dir"
  mkdir -p "$keyring_dir"
  printf '%s' "$stored_pin" >"$keyring_dir/$stored_serial"
  printf '%s' "$pin_nfc" >"$keyring_dir/$serial_nfc"
  printf '%s' "$pin_nano" >"$keyring_dir/$serial_nano"
  : >"$clear_log"
}
reset_keyring

assert_entry_present() {
  [[ -f "$keyring_dir/$1" ]] || fail "$2: keychain entry for serial $1 is gone"
}
assert_entry_absent() {
  if [[ -e "$keyring_dir/$1" ]]; then
    fail "$2: keychain entry for serial $1 survived"
  fi
}
assert_cleared_exactly() {
  # <serial> <label>: the clear log holds that serial and nothing else.
  local want=$1 label=$2 lines
  lines=$(wc -l <"$clear_log")
  [[ $lines -eq 1 ]] || fail "$label: expected exactly one clear, saw $lines: $(tr '\n' ' ' <"$clear_log")"
  grep -qFx -- "$want" "$clear_log" || fail "$label: the clear did not target serial $want"
}
assert_no_clear() {
  if [[ -s "$clear_log" ]]; then
    fail "$1: nothing should have been cleared, but saw $(tr '\n' ' ' <"$clear_log")"
  fi
}

card_desc() {
  # <serial> [extra-line]
  if [[ $# -eq 2 ]]; then
    printf 'Please unlock the card%%0A%%0ANumber: %s%%0A%s' "$1" "$2"
  else
    printf 'Please unlock the card%%0A%%0ANumber: %s' "$1"
  fi
}

# Behaviour fixtures: retarget the absolute delegate path(s) to the scratch
# shims above, and shrink the lookup and removal bounds to one second.
# The cold-lookup scenario below keeps the production deadline.
sed \
  -e "s#^DELEGATE_PATH = .*#DELEGATE_PATH = \"$scratch/bin/fake-gnome-delegate\"#" \
  -e "s#^LINUX_FALLBACK_PATH = .*#LINUX_FALLBACK_PATH = \"$scratch/bin/fake-fallback-delegate\"#" \
  -e "s#^SECRET_TOOL_PATH = .*#SECRET_TOOL_PATH = \"$scratch/bin/secret-tool\"#" \
  -e 's/KEYRING_LOOKUP_TIMEOUT = 30/KEYRING_LOOKUP_TIMEOUT = 1/' \
  -e 's/KEYRING_CLEAR_TIMEOUT = 5/KEYRING_CLEAR_TIMEOUT = 1/' \
  "$rendered_gnome" >"$scratch/functional-gnome.py"
sed \
  -e "s#^DELEGATE_PATH = .*#DELEGATE_PATH = \"$scratch/bin/fake-gnome-delegate\"#" \
  -e "s#^LINUX_FALLBACK_PATH = .*#LINUX_FALLBACK_PATH = \"$scratch/bin/fake-fallback-delegate\"#" \
  -e "s#^SECRET_TOOL_PATH = .*#SECRET_TOOL_PATH = \"$scratch/bin/secret-tool\"#" \
  -e 's/KEYRING_LOOKUP_TIMEOUT = 30/KEYRING_LOOKUP_TIMEOUT = 1/' \
  -e 's/KEYRING_CLEAR_TIMEOUT = 5/KEYRING_CLEAR_TIMEOUT = 1/' \
  "$rendered_gnome" >"$scratch/functional-fallback.py"

pipe_into() { cat >"$1"; }

# Redirect only the OS logging boundary, leaving real socket operations and
# the wrapper's Assuan consumer intact. No diagnostic switch enters production.
cat >"$scratch/log-consumer.py" <<'PYLOG'
import os
import pathlib
import socket
import subprocess
import sys

wrapper, log_path, mode, address = sys.argv[1:]
endpoint = str(pathlib.Path(log_path).with_suffix(".sock"))
receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
receiver.setblocking(False)
if mode != "missing":
    receiver.bind(endpoint)
if mode == "full":
    filler = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    filler.setblocking(False)
    filler.connect(endpoint)
    while True:
        try:
            filler.send(b"filler")
        except BlockingIOError:
            break

bootstrap = r'''
import runpy, socket, sys, time
endpoint, mode, wrapper, address = sys.argv[1:]
original = socket.socket
class LocalLogSocket(original):
    def __init__(self, *args, **kwargs):
        assert mode != "forbidden", "Darwin must not open a diagnostic socket"
        if mode == "socket-error":
            raise OSError("PRIVATE-EXCEPTION-TEXT")
        super().__init__(*args, **kwargs)
    def connect(self, address):
        assert address == expected_address
        return super().connect(endpoint)
expected_address = address
socket.socket = LocalLogSocket
def forbidden_wall_clock():
    raise AssertionError("lookup diagnostics must use monotonic time")
time.time = forbidden_wall_clock
sys.argv = [wrapper]
runpy.run_path(wrapper, run_name="__main__")
'''
status = subprocess.call([sys.executable, "-c", bootstrap, endpoint, mode, wrapper, address])
packets = []
while mode != "missing":
    try:
        packet = receiver.recv(4096)
    except BlockingIOError:
        break
    if packet != b"filler":
        packets.append(packet)
pathlib.Path(log_path).write_bytes(b"\n".join(packets))
receiver.close()
if mode != "missing":
    os.unlink(endpoint)
sys.exit(status)
PYLOG
diagnostic_sink=healthy
diagnostic_address=/dev/log

run_wrapper() {
  # run_wrapper <functional.py> <stdin-text> <out-file> <err-file> [env NAME=value ...]
  # <stdin-text> is command-substitution output, which already lost its
  # trailing newline; restore exactly one so the final Assuan line is
  # terminated like every other, instead of looking like a dangling partial
  # line the wrapper must treat as EOF.
  # A non-zero exit prints the wrapper's stderr, so a failure that only shows
  # up on a loaded builder still names its cause; cases that expect a
  # non-zero exit print it too.
  local functional=$1 input=$2 out=$3 err=$4 rc=0
  shift 4
  if [[ -p $out ]]; then
    printf '%s\n' "$input" | "$timeout_bin" 10 "$env_bin" "$@" PATH="$scratch/bin:/usr/bin:/bin" \
      "$python3_bin" "$scratch/log-consumer.py" "$functional" "$err.log" "$diagnostic_sink" "$diagnostic_address" >"$out" 2>"$err" || rc=$?
  else
    printf '%s\n' "$input" | "$timeout_bin" 10 "$env_bin" "$@" PATH="$scratch/bin:/usr/bin:/bin" \
      "$python3_bin" "$scratch/log-consumer.py" "$functional" "$err.log" "$diagnostic_sink" "$diagnostic_address" 2>"$err" | pipe_into "$out" || rc=$?
  fi
  if (( rc != 0 )); then
    printf 'pinentry-card: wrapper exited %d; its stderr follows:\n%s\n' "$rc" "$(<"$err")" >&2
  fi
  if [[ -f $out ]]; then
    for raw_pin in "$stored_pin" "$pin_nfc" "$pin_nano"; do
      if grep -qF -- "$raw_pin" "$out"; then
        fail 'raw PIN appeared in the Assuan response'
      fi
    done
  fi
  return "$rc"
}

assert_contains() {
  local file=$1 needle=$2 label=$3
  grep -qF -- "$needle" "$file" || fail "$label: expected to find $(printf '%q' "$needle") in $file"
}

assert_not_contains() {
  local file=$1 needle=$2 label=$3
  if grep -qF -- "$needle" "$file"; then
    fail "$label: unexpectedly found $(printf '%q' "$needle") in $file"
  fi
}

assert_lookup_diagnostic() {
  "$python3_bin" - "$err.log" "$1" "$out" "$err" <<'PYASSERT'
import pathlib, re, sys
log, category, protocol, stderr = sys.argv[1:]
data = pathlib.Path(log).read_bytes()
match = re.fullmatch(rb"<14>pinentry-card: lookup outcome=" + category.encode() + rb" elapsed_ms=([0-9]{1,6})", data)
assert match, "missing or unsafe lookup diagnostic for " + category
elapsed = int(match[1])
if category == "timeout":
    assert 900 <= elapsed < 3000, "timeout duration did not measure the lookup"
assert b"pinentry-card:" not in pathlib.Path(protocol).read_bytes(), "diagnostic contaminated Assuan"
assert not pathlib.Path(stderr).read_bytes(), "lookup leaked stderr"
PYASSERT
}

yubikey5_desc() {
  # "Number:" surrounded by \x1e/\x1f alignment bytes, the literal YubiKey 5
  # card-prompt shape (KTD3).
  printf 'Please unlock the card%%0A%%0A\x1eNumber:\x1f 14 963 605%%0AHolder: Jo Doe'
}

# Keep the production timeout for a cold Secret Service lookup. A valid PIN
# arriving after the old five-second deadline must not open a dialog.
sed \
  -e "s#^DELEGATE_PATH = .*#DELEGATE_PATH = \"$scratch/bin/fake-gnome-delegate\"#" \
  -e "s#^LINUX_FALLBACK_PATH = .*#LINUX_FALLBACK_PATH = \"$scratch/bin/fake-fallback-delegate\"#" \
  -e "s#^SECRET_TOOL_PATH = .*#SECRET_TOOL_PATH = \"$scratch/bin/secret-tool\"#" \
  -e 's/KEYRING_CLEAR_TIMEOUT = 5/KEYRING_CLEAR_TIMEOUT = 1/' \
  "$rendered_gnome" >"$scratch/functional-cold.py"
out="$scratch/out-cold" err="$scratch/err-cold"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$stored_serial")")
run_wrapper "$scratch/functional-cold.py" "$input" "$out" "$err" DISPLAY=:0 KEYRING_STUB_MODE=cold
assert_contains "$out" "D $stored_pin_encoded" 'cold keyring lookup'
assert_not_contains "$gnome_log" 'GETPIN' 'cold keyring lookup'
assert_lookup_diagnostic success
pass 'a cold keyring lookup supplies the stored PIN without opening a dialog'

answered_labels=(yubikey5 older-firmware non-yubikey invalid-utf8-holder no-holder alignment)
answered_descs=(
  "$(yubikey5_desc)"
  'Please unlock the card%0A%0ANumber: 14963605%0AHolder: Jo Doe'
  'Please unlock the card%0A%0ANumber: 0006 14963605%0AHolder: Jo Doe'
  'Please unlock the card%0A%0ANumber: 14 963 605%0AHolder: Jo%FFhn'
  'Please unlock the card%0A%0ANumber: 14 963 605'
  "$(printf 'Please unlock the card%%0A%%0A\x1e\x1fNumber:\x1e 14 963 605\x1f')"
)
for index in "${!answered_labels[@]}"; do
  label=${answered_labels[$index]}
  out="$scratch/out-answered-$label" err="$scratch/err-answered-$label"
  rm -f "$gnome_log"
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "${answered_descs[$index]}")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$out" "D $stored_pin_encoded" "$label"
  assert_contains "$out" $'\nOK\n' "$label"
  assert_not_contains "$out" "$stored_pin" "$label raw PIN"
  assert_contains "$gnome_log" 'SETPROMPT PIN' "$label"
  assert_contains "$gnome_log" 'SETDESC' "$label"
  assert_not_contains "$gnome_log" 'GETPIN' "$label"
  assert_lookup_diagnostic success
  pass "answered grammar: $label"
done

# 3. A second "Number:" line (injected, after the holder) disables the match.
out="$scratch/out3" err="$scratch/err3"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 14 963 605%0AHolder: X%0ANumber: 20 000 001'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '3 second-number-line'
assert_not_contains "$out" "D $stored_pin_encoded" '3 second-number-line'
pass '3: a second Number line (holder data) is passed through, never answered'

# 5. An encoded newline, a raw carriage return, a malformed % escape, and an
#    overlong SETDESC: each forwarded raw and never answered.
overlong=$("$python3_bin" -c "print('A' * 5000, end='')")
run_case5() {
  local tag=$1 desc=$2
  local out="$scratch/out5-$tag" err="$scratch/err5-$tag"
  rm -f "$gnome_log"
  local input
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$gnome_log" 'GETPIN' "5 $tag"
  assert_not_contains "$out" "D $stored_pin_encoded" "5 $tag"
}
run_case5 malformed-escape 'Please unlock the card%0A%0ANumber: 14 963 605%GZ'
run_case5 overlong "Please unlock the card${overlong}"
raw_cr_desc=$(printf 'Please unlock the card\rmore')
run_case5 raw-cr "$raw_cr_desc"
pass '5a-c: malformed %-escape, overlong SETDESC, and an embedded raw CR each pass through'
# The encoded-newline case needs no special decode failure: SETPROMPT PIN%0A
# decodes to "PIN\n", which fails the exact "PIN" match through ordinary
# classification.
out="$scratch/out5-encoded-newline" err="$scratch/err5-encoded-newline"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN%%0A\nSETDESC %s\nGETPIN\n' 'Please unlock the card%0A%0ANumber: 14 963 605')
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '5d encoded-newline-in-prompt'
assert_not_contains "$out" "D $stored_pin_encoded" '5d encoded-newline-in-prompt'
pass '5d: an encoded newline in SETPROMPT fails the exact PIN match and passes through'

# The macOS Keychain backend is covered by tests/pinentry-card-darwin.sh,
# which runs the darwin render behind its front-stage filter.

# 7. Stdin closes while the delegate is inside GETPIN: the delegate is
#    terminated and the wrapper exits (bounded, not left hanging).
out="$scratch/out7" err="$scratch/err7"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT Admin PIN\nSETDESC Please enter the Admin PIN\nGETPIN\n')
start=$(date +%s)
rc=0
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 FAKE_DELEGATE_HANG_ON_GETPIN=1 || rc=$?
elapsed=$(( $(date +%s) - start ))
[[ $rc -ne 124 ]] || fail '7 stdin-close-mid-getpin: the wrapper hung past the 10-second test timeout'
(( elapsed < 8 )) || fail "7 stdin-close-mid-getpin: took ${elapsed}s to exit after stdin closed"
assert_contains "$gnome_log" 'GETPIN' '7 stdin-close-mid-getpin'
pass '7: stdin closing while the delegate is inside GETPIN terminates the delegate and exits promptly'

# 8. AE6: Admin PIN is not the card PIN prompt; the delegate answers it and
#    that reply is relayed.
out="$scratch/out8" err="$scratch/err8"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT Admin PIN\nSETDESC Please enter the Admin PIN\nGETPIN\n')
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '8 admin-pin AE6'
assert_contains "$out" 'D DELEGATE-PIN-gnome' '8 admin-pin AE6'
pass '8 (AE6): Admin PIN reaches the real pinentry and its reply is relayed'

# 9. Reset Code, New PIN, Repeat this PIN, and the old-PIN check all pass
#    through.
run_case9() {
  local tag=$1 prompt=$2 desc=$3
  local out="$scratch/out9-$tag" err="$scratch/err9-$tag"
  rm -f "$gnome_log"
  local input
  input=$(printf 'SETPROMPT %s\nSETDESC %s\nGETPIN\n' "$prompt" "$desc")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$gnome_log" 'GETPIN' "9 $tag"
  assert_not_contains "$out" "D $stored_pin_encoded" "9 $tag"
}
run_case9 reset-code 'Reset Code' 'Please unlock the card%0A%0ANumber: 14 963 605'
run_case9 new-pin 'New PIN' 'Please unlock the card%0A%0ANumber: 14 963 605'
run_case9 repeat-pin 'Repeat this PIN' 'Please unlock the card%0A%0ANumber: 14 963 605'
run_case9 old-pin-no-serial 'PIN' 'Please enter the PIN'
pass '9: Reset Code, New PIN, Repeat this PIN, and the serial-less old-PIN check all pass through'

# 10. "Remaining attempts" disables the match; the stored PIN never appears.
out="$scratch/out10" err="$scratch/err10"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 14 963 605%0ARemaining attempts: 2'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '10 remaining-attempts'
assert_not_contains "$out" "D $stored_pin_encoded" '10 remaining-attempts'
assert_cleared_exactly "$stored_serial" '10 remaining-attempts'
pass '10: a Remaining attempts marker passes through, clears that serial, and never puts the stored PIN on stdout'
reset_keyring

# 11. A SETERROR before the prompt guards exactly the next GETPIN.
out="$scratch/out11" err="$scratch/err11"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 14 963 605'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nSETERROR Bad PIN\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '11 seterror-guard'
assert_not_contains "$out" "D $stored_pin_encoded" '11 seterror-guard'
assert_cleared_exactly "$stored_serial" '11 seterror-guard'
pass '11: a SETERROR before the prompt passes the next GETPIN through and clears that serial'
# Cases 10 and 11 legitimately discard the rejected serial's entry; restore it
# for the cases below, which expect that serial to still be registered.
reset_keyring

# 12. The keyring stub exits non-zero, prints nothing, or sleeps past the
#     (1-second, rewritten) bound: pass-through in each case.
desc='Please unlock the card%0A%0ANumber: 14 963 605'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
for mode in fail-nonzero empty sleep os-error; do
  out="$scratch/out12-$mode" err="$scratch/err12-$mode"
  rm -f "$gnome_log"
  if [[ $mode == os-error ]]; then
    mv "$scratch/bin/secret-tool" "$scratch/bin/secret-tool-away"
  fi
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 KEYRING_STUB_MODE="$mode"
  if [[ $mode == os-error ]]; then
    mv "$scratch/bin/secret-tool-away" "$scratch/bin/secret-tool"
  fi
  assert_contains "$gnome_log" 'GETPIN' "12 keyring-stub-$mode"
  assert_not_contains "$out" "D $stored_pin_encoded" "12 keyring-stub-$mode"
  assert_contains "$out" 'D DELEGATE-PIN-gnome' "12 keyring-stub-$mode fallback"
  case $mode in
    fail-nonzero) category=nonzero ;;
    sleep) category=timeout ;;
    *) category=$mode ;;
  esac
  assert_lookup_diagnostic "$category"
done
pass '12: timeout, OS error, nonzero, and empty lookups log only category/duration and delegate GETPIN'

# A missing, saturated, or unopenable local log sink must preserve both a
# cached answer and fallback, without blocking or adding any protocol bytes.
for diagnostic_sink in missing full socket-error; do
  for mode in ok fail-nonzero; do
    out="$scratch/out12-sink-$diagnostic_sink-$mode" err="$scratch/err12-sink-$diagnostic_sink-$mode"
    rm -f "$gnome_log"
    run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 KEYRING_STUB_MODE="$mode"
    "$python3_bin" - "$out" "$err" "$mode" <<'PYPROTOCOL'
import pathlib, sys
out, err, mode = sys.argv[1:]
pin = b"D te%25st pin" if mode == "ok" else b"D DELEGATE-PIN-gnome"
assert sorted(pathlib.Path(out).read_bytes().splitlines()) == sorted([
    b"OK Pleased to meet you", b"OK", b"OK", pin, b"OK"
]), "log sink failure changed Assuan replies"
assert not pathlib.Path(err).read_bytes(), "log sink failure escaped to stderr"
assert not pathlib.Path(err + ".log").read_bytes(), "failed sink unexpectedly accepted a diagnostic"
PYPROTOCOL
  done
done
diagnostic_sink=healthy
pass '12: unavailable or full logging sinks preserve cached answers and delegated replies'

# Linux-only diagnostics must leave Darwin decoding and fallback intact,
# without trying to open a logging socket on that platform.
sed -e 's/IS_LINUX = True/IS_LINUX = False/' \
  -e 's/KEYRING_BACKEND = "secret-tool"/KEYRING_BACKEND = "security"/' \
  "$scratch/functional-gnome.py" >"$scratch/functional-darwin-proxy.py"
diagnostic_sink=forbidden
for encoding in valid invalid; do
  if [[ $encoding == valid ]]; then
    printf 'go-keyring-base64:%s' "$(printf '%s' "$stored_pin" | "$base64_bin" | "$tr_bin" -d '\n')" >"$keyring_dir/$stored_serial"
  else
    printf 'go-keyring-base64:PRIVATE-INVALID-ENCODING' >"$keyring_dir/$stored_serial"
  fi
  out="$scratch/out12-darwin-$encoding" err="$scratch/err12-darwin-$encoding"
  run_wrapper "$scratch/functional-darwin-proxy.py" "$input" "$out" "$err" DISPLAY=:0
  if [[ $encoding == valid ]]; then
    assert_contains "$out" "D $stored_pin_encoded" '12 Darwin decoded success'
  else
    assert_contains "$out" 'D DELEGATE-PIN-gnome' '12 Darwin decode fallback'
  fi
  [[ ! -s $err && ! -s $err.log ]] || fail 'Darwin emitted diagnostics'
done
diagnostic_sink=healthy
reset_keyring
pass '12: Darwin preserves decoded answers and fallback without Linux diagnostics'

# 13. An unknown serial (no keyring record) passes through.
out="$scratch/out13" err="$scratch/err13"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 99 999 999'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '13 unknown-serial'
pass '13: a serial with no keyring record passes through'

# 14. AE4: the insert-card CONFIRM is cancelled at once; the delegate never
#     sees CONFIRM; a following BYE still reaches the delegate.
out="$scratch/out14" err="$scratch/err14"
rm -f "$gnome_log"
desc='Please insert the card with serial number:%0A%0A  14 963 605'
input=$(printf 'SETDESC %s\nCONFIRM\nBYE\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" 'ERR 83886179 Operation cancelled <Pinentry>' '14 insert-card AE4'
assert_not_contains "$gnome_log" 'CONFIRM' '14 insert-card AE4'
assert_contains "$gnome_log" 'BYE' '14 insert-card AE4'
pass '14 (AE4): the insert-card CONFIRM is cancelled with no dialog; BYE still reaches the delegate'

# 15. Everything else (OPTION, SETKEYINFO, SETTITLE, SETOK, SETCANCEL,
#     GETINFO, SETQUALITYBAR): forwarded verbatim, replies relayed verbatim.
out="$scratch/out15" err="$scratch/err15"
rm -f "$gnome_log"
input=$(printf 'OPTION ttyname=/dev/pts/1\nSETKEYINFO --clear\nSETTITLE\nSETOK\nSETCANCEL\nGETINFO pid\nSETQUALITYBAR\n')
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
for verbatim_line in 'OPTION ttyname=/dev/pts/1' 'SETKEYINFO --clear' 'SETTITLE' 'SETOK' 'SETCANCEL' 'GETINFO pid' 'SETQUALITYBAR'; do
  assert_contains "$gnome_log" "$verbatim_line" "15 forward-verbatim: $verbatim_line"
done
ok_count=$(grep -c '^OK$' "$out")
[[ $ok_count -ge 7 ]] || fail "15 forward-verbatim: expected at least 7 relayed OK replies, saw $ok_count"
pass '15: OPTION/SETKEYINFO/SETTITLE/SETOK/SETCANCEL/GETINFO/SETQUALITYBAR forward and relay verbatim'

# 18. A localized SETDESC (German) passes through.
out="$scratch/out18" err="$scratch/err18"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC Bitte die Karte entsperren%%0A%%0ANumber: 14 963 605\nGETPIN\n')
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '18 localized-setdesc'
assert_not_contains "$out" "D $stored_pin_encoded" '18 localized-setdesc'
pass '18: a localized (German) SETDESC passes through'

# 19. Linux: DISPLAY and WAYLAND_DISPLAY both unset spawns the fallback;
#     DISPLAY set spawns the desktop delegate.
rm -f "$gnome_log" "$fallback_log"
out="$scratch/out19-fallback" err="$scratch/err19-fallback"
input=$(printf 'SETPROMPT PIN\nBYE\n')
run_wrapper "$scratch/functional-fallback.py" "$input" "$out" "$err" -u DISPLAY -u WAYLAND_DISPLAY
[[ -s "$fallback_log" ]] || fail '19 display-fallback: the fallback delegate never ran with no DISPLAY/WAYLAND_DISPLAY'
[[ ! -s "$gnome_log" ]] || fail '19 display-fallback: the desktop delegate ran despite no DISPLAY/WAYLAND_DISPLAY'
rm -f "$gnome_log" "$fallback_log"
out="$scratch/out19-desktop" err="$scratch/err19-desktop"
run_wrapper "$scratch/functional-fallback.py" "$input" "$out" "$err" -u WAYLAND_DISPLAY DISPLAY=:0
[[ -s "$gnome_log" ]] || fail '19 display-fallback: the desktop delegate never ran with DISPLAY set'
[[ ! -s "$fallback_log" ]] || fail '19 display-fallback: the fallback delegate ran despite DISPLAY being set'
pass '19: the Linux DISPLAY/WAYLAND_DISPLAY fallback picks the right delegate'

if [[ $# -eq 5 ]]; then
  "$python3_bin" - "$2" "$3" "$4" "$5" "$scratch" <<'PYINSTALLED'
import os
from pathlib import Path
import py_compile
import re
import runpy
import sys
from unittest.mock import patch

installed, qt, curses, secret_tool, scratch = sys.argv[1:]
class SpawnObserved(BaseException):
    pass

for entry in (Path(installed), Path(installed).with_name("pinentry")):
    assert entry.is_file() and os.access(entry, os.X_OK), f"missing executable entry point: {entry}"
    text = entry.read_text()
    assert not re.search(r"@[A-Z_]+@", text), f"unresolved package substitution: {entry}"
    assert text.startswith("#!/nix/store/"), f"unpatched interpreter: {entry}"
    interpreter = text.splitlines()[0][2:].split()[0]
    assert os.access(interpreter, os.X_OK), f"missing packaged interpreter: {entry}"
    py_compile.compile(str(entry), cfile=str(Path(scratch) / "installed.pyc"), doraise=True)
    declaration = runpy.run_path(str(entry))
    assert declaration["SECRET_TOOL_PATH"] == secret_tool, "wrong packaged keyring delegate"
    for display, wayland, expected in (("", "", curses), (":0", "", qt), ("", "wayland-0", qt)):
        observed = []
        def spawn(argv, **kwargs):
            observed.append(argv)
            raise SpawnObserved()
        with patch.dict(os.environ, {"DISPLAY": display, "WAYLAND_DISPLAY": wayland}), \
                patch.object(sys, "argv", [str(entry)]), \
                patch("subprocess.Popen", side_effect=spawn):
            try:
                runpy.run_path(str(entry), run_name="__main__")
            except SpawnObserved:
                pass
        assert observed == [[expected]], f"{entry} selected {observed}, expected {expected}"
print("pinentry-card: installed Linux entry points compile and select packaged delegates")
PYINSTALLED
else
  pass 'installed Linux package proof not requested; raw relay proof only'
fi

# 21. A Number value the documented forms do not cover (letters, punctuation,
#     or an odd grouping) passes through; the stored PIN never appears.
for bad_number in 'abc123' '14-963-605' '14  963 605' '14 9O3 605'; do
  out="$scratch/out21" err="$scratch/err21"
  rm -f "$gnome_log"
  desc=$(printf 'Please unlock the card%%0A%%0ANumber: %s' "$bad_number")
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$gnome_log" 'GETPIN' "21 uncovered-number-form '$bad_number'"
  assert_not_contains "$out" "D $stored_pin_encoded" "21 uncovered-number-form '$bad_number'"
done
pass '21: a Number value outside the three documented forms passes through, never sending the stored PIN'

# 22. Two registered serials holding different PINs: each prompt is answered
#     with its own card's PIN, and never with the other card's.
reset_keyring
run_case22() {
  local serial=$1 want=$2 other=$3 tag=$4
  local out="$scratch/out22-$tag" err="$scratch/err22-$tag"
  rm -f "$gnome_log"
  local input
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$serial")")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$out" "D $want" "22 per-card-pin $tag"
  assert_not_contains "$out" "$other" "22 per-card-pin $tag (the other card's PIN must never appear)"
  assert_not_contains "$gnome_log" 'GETPIN' "22 per-card-pin $tag"
}
run_case22 "$serial_nfc" "$pin_nfc_encoded" "$pin_nano_encoded" nfc
run_case22 "$serial_nano" "$pin_nano_encoded" "$pin_nfc_encoded" nano
pass '22: two serials with different PINs are each answered with that card'"'"'s own PIN'

# 23. A rejected PIN ("Remaining attempts") drops that serial's entry, leaves
#     every other serial's entry intact, and delegates the prompt.
reset_keyring
out="$scratch/out23" err="$scratch/err23"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$serial_nfc" 'Remaining attempts: 2')")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '23 rejection-clears'
assert_not_contains "$out" "D $pin_nfc_encoded" '23 rejection-clears'
assert_cleared_exactly "$serial_nfc" '23 rejection-clears'
assert_entry_absent "$serial_nfc" '23 rejection-clears'
assert_entry_present "$serial_nano" '23 rejection-clears'
assert_entry_present "$stored_serial" '23 rejection-clears'
# The rejected serial is now unregistered: a later clean prompt for it is
# delegated, while the untouched card still answers from the keychain.
out="$scratch/out23b" err="$scratch/err23b"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$serial_nfc")")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '23b cleared-serial-no-longer-answers'
assert_not_contains "$out" "D $pin_nfc_encoded" '23b cleared-serial-no-longer-answers'
out="$scratch/out23c" err="$scratch/err23c"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$serial_nano")")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" "D $pin_nano_encoded" '23c other-serial-still-answers'
pass '23: a Remaining-attempts rejection clears only that serial, and the other cards keep answering'

# 24. The same, signalled by SETERROR instead of the description.
reset_keyring
out="$scratch/out24" err="$scratch/err24"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nSETERROR Bad PIN\nGETPIN\n' "$(card_desc "$serial_nano")")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '24 seterror-clears'
assert_not_contains "$out" "D $pin_nano_encoded" '24 seterror-clears'
assert_cleared_exactly "$serial_nano" '24 seterror-clears'
assert_entry_absent "$serial_nano" '24 seterror-clears'
assert_entry_present "$serial_nfc" '24 seterror-clears'
pass '24: a SETERROR rejection clears only that serial'

# 25. Two GETPINs under one rejected prompt: cleared once, auto-submitted
#     never, both delegated.
reset_keyring
out="$scratch/out25" err="$scratch/err25"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\nGETPIN\n' "$(card_desc "$serial_nfc" 'Remaining attempts: 1')")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_cleared_exactly "$serial_nfc" '25 clear-once-per-rejection'
assert_not_contains "$out" "D $pin_nfc_encoded" '25 clear-once-per-rejection'
getpin_count=$(grep -c '^GETPIN' "$gnome_log")
[[ $getpin_count -eq 2 ]] || fail "25 clear-once-per-rejection: expected both GETPINs delegated, saw $getpin_count"
pass '25: a repeated GETPIN under one rejection clears once and auto-submits nothing'

# 26. A clear that fails or outruns the (1-second, rewritten) bound never
#     blocks the delegated prompt. Keep lookup at 30 seconds so accidentally
#     using its deadline for removal fails this case.
for mode in clear-fail clear-sleep; do
  reset_keyring
  out="$scratch/out26-$mode" err="$scratch/err26-$mode"
  rm -f "$gnome_log"
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(card_desc "$serial_nfc" 'Remaining attempts: 2')")
  start=$(date +%s)
  rc=0
  run_wrapper "$scratch/functional-cold.py" "$input" "$out" "$err" DISPLAY=:0 KEYRING_STUB_MODE="$mode" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  [[ $rc -ne 124 ]] || fail "26 $mode: the wrapper hung past the 10-second test timeout"
  (( elapsed < 5 )) || fail "26 $mode: took ${elapsed}s, so the clear was not bounded"
  assert_contains "$gnome_log" 'GETPIN' "26 $mode"
  assert_not_contains "$out" "D $pin_nfc_encoded" "26 $mode"
done
pass '26: a failing or hanging clear stays bounded and still delegates the prompt'

# 27. Rejections the wrapper cannot attribute to one card clear nothing: a
#     non-card prompt, and a card prompt whose serial is ambiguous.
reset_keyring
out="$scratch/out27-admin" err="$scratch/err27-admin"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT Admin PIN\nSETDESC Please enter the Admin PIN\nSETERROR Bad PIN\nGETPIN\n')
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_no_clear '27 admin-pin-rejection'
out="$scratch/out27-ambiguous" err="$scratch/err27-ambiguous"
rm -f "$gnome_log"
desc="Please unlock the card%0A%0ANumber: $serial_nfc%0ANumber: $serial_nano%0ARemaining attempts: 2"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_no_clear '27 ambiguous-serial-rejection'
assert_entry_present "$serial_nfc" '27 ambiguous-serial-rejection'
assert_entry_present "$serial_nano" '27 ambiguous-serial-rejection'
pass '27: a rejection with no unambiguous serial clears nothing'

# 28. Stdin closes while the relay thread is still writing the delegate's
#     output: the wrapper exits with the delegate's status, not an interpreter
#     abort at shutdown (exit 134).  A slow reader on stdout keeps the relay
#     thread inside its write for most of the time the wrapper exits in.
slow_fifo="$scratch/slow-reader"
mkfifo "$slow_fifo"
"$python3_bin" -c '
import os, time
while os.read(0, 4096):
    time.sleep(0.005)
' <"$slow_fifo" &
reader_pid=$!
rc=0
run_wrapper "$scratch/functional-gnome.py" 'GETINFO pid' "$slow_fifo" "$scratch/err28" \
  DISPLAY=:0 FAKE_DELEGATE_EXIT=7 FAKE_DELEGATE_STREAM_AFTER_EOF=1 || rc=$?
wait "$reader_pid" || true
[[ $rc -eq 7 ]] || fail "28 eof-during-relay-write: expected the delegate's status 7, got $rc"
pass '28: stdin closing while the relay thread writes exits with the delegate'"'"'s status'

# start_wrapper <out-target> <err-file> [NAME=value ...]: run the gnome
# wrapper in the background with stdin on a FIFO this shell holds open (fd
# $wrapper_in), a delegate that exits 7 at EOF, and any extra environment,
# and wait until that delegate has read a line. Sets wrapper_pid.
wrapper_fifo="$scratch/wrapper-in"
mkfifo "$wrapper_fifo"
start_wrapper() {
  local out=$1 err=$2 i
  shift 2
  rm -f "$gnome_log"
  "$env_bin" DISPLAY=:0 FAKE_DELEGATE_EXIT=7 "$@" PATH="$scratch/bin:/usr/bin:/bin" \
    "$python3_bin" "$scratch/functional-gnome.py" <"$wrapper_fifo" >"$out" 2>"$err" &
  wrapper_pid=$!
  exec {wrapper_in}>"$wrapper_fifo"
  printf 'GETINFO pid\n' >&"$wrapper_in"
  for (( i = 0; i < 100; i++ )); do
    grep -qF 'GETINFO pid' "$gnome_log" 2>/dev/null && return 0
    "$sleep_bin" 0.1
  done
  fail "start_wrapper: the delegate never received a line; wrapper stderr: $(<"$err")"
}

# await_wrapper_exit <label> <event> <err-file>: require the background
# wrapper to exit within 8 seconds of <event> with the delegate's status 7.
await_wrapper_exit() {
  local label=$1 event=$2 err=$3 i rc=0
  for (( i = 0; i < 80; i++ )); do
    kill -0 "$wrapper_pid" 2>/dev/null || break
    "$sleep_bin" 0.1
  done
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    kill -KILL "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" || true
    fail "$label: the wrapper was still running 8s after $event; its stderr: $(<"$err")"
  fi
  wait "$wrapper_pid" || rc=$?
  [[ $rc -eq 7 ]] || fail "$label: expected the delegate's status 7 after $event, got $rc; stderr: $(<"$err")"
}

# term_wrapper <label> <err-file>: SIGTERM the background wrapper and require
# it to exit within 8 seconds with the delegate's status 7.
term_wrapper() {
  kill -TERM "$wrapper_pid"
  await_wrapper_exit "$1" SIGTERM "$2"
  exec {wrapper_in}>&-
}

# await_pipe_full <fd>: wait until the unread pipe on <fd> is full (within one
# page: a write that does not fit the last page opens a new one) and has
# stopped growing; returns non-zero after 8s.
await_pipe_full() {
  "$python3_bin" -c '
import fcntl, struct, sys, termios, time
size = fcntl.fcntl(0, fcntl.F_GETPIPE_SZ)
previous = -1
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    queued = struct.unpack("i", fcntl.ioctl(0, termios.FIONREAD, b"\0\0\0\0"))[0]
    if queued >= size - 4096 and queued == previous:
        sys.exit(0)
    previous = queued
    time.sleep(0.1)
sys.exit(1)
' <&"$1"
}

# 29. SIGTERM while the wrapper waits for its next command.
start_wrapper "$scratch/out29" "$scratch/err29"
term_wrapper '29 sigterm-idle' "$scratch/err29"
pass '29: SIGTERM while idle reaps the delegate and exits promptly with its status'

# 30. SIGTERM while the main thread is blocked in its own write: stdout is a
#     FIFO nobody reads, and each insert-card CONFIRM makes the main thread
#     write a 45-byte cancel reply, so 3000 of them overflow the pipe and leave
#     it blocked with the output lock held.
wrapper_out_fifo="$scratch/wrapper-out"
mkfifo "$wrapper_out_fifo"
exec {wrapper_out}<>"$wrapper_out_fifo"
start_wrapper "$wrapper_out_fifo" "$scratch/err30"
{
  printf 'SETDESC Please insert the card with serial number:%%0A%%0A  14 963 605\n'
  for (( i = 0; i < 3000; i++ )); do printf 'CONFIRM\n'; done
} >&"$wrapper_in"
# The signal must land during the blocked write.
await_pipe_full "$wrapper_out" || fail "30 sigterm-during-write: the wrapper's stdout pipe never filled; stderr: $(<"$scratch/err30")"
term_wrapper '30 sigterm-during-write' "$scratch/err30"
exec {wrapper_out}<&-
pass '30: SIGTERM during a blocked main-thread write exits promptly with the delegate'"'"'s status'

# 31. Stdin closes while the relay thread is blocked writing to a full stdout
#     nobody reads, holding the output lock: the delegate's GETPIN starts a
#     flood of output and never replies, so the main thread stays in its read
#     and sees the EOF.  Shutdown must not wait on the lock forever.
wrapper_out_fifo="$scratch/wrapper-out31"
mkfifo "$wrapper_out_fifo"
exec {wrapper_out}<>"$wrapper_out_fifo"
start_wrapper "$wrapper_out_fifo" "$scratch/err31" FAKE_DELEGATE_FLOOD_ON_GETPIN=1
printf 'GETPIN\n' >&"$wrapper_in"
# The EOF must arrive while the relay thread is blocked in its write.
await_pipe_full "$wrapper_out" || fail "31 eof-during-blocked-relay: the wrapper's stdout pipe never filled; stderr: $(<"$scratch/err31")"
exec {wrapper_in}>&-
await_wrapper_exit '31 eof-during-blocked-relay' 'stdin closed' "$scratch/err31"
exec {wrapper_out}<&-
pass '31: stdin closing while the relay thread is blocked on an unread stdout exits promptly with the delegate'"'"'s status'

# 32. A delegate that takes 3 seconds to exit after stdin closes, with no
#     dialog pending, is a slow but healthy one on a loaded machine: the
#     wrapper waits for it and exits with its status, not a SIGTERM (241).
out="$scratch/out32" err="$scratch/err32"
rm -f "$gnome_log"
input=$(printf 'OPTION ttyname=/dev/pts/1\nSETKEYINFO --clear\nSETTITLE\nSETOK\nSETCANCEL\nGETINFO pid\nSETQUALITYBAR\n')
rc=0
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 FAKE_DELEGATE_EXIT=7 FAKE_DELEGATE_EXIT_DELAY=3 || rc=$?
[[ $rc -eq 7 ]] || fail "32 slow-exit-after-eof: expected the delegate's status 7, got $rc"
ok_count=$(grep -c '^OK$' "$out")
[[ $ok_count -eq 7 ]] || fail "32 slow-exit-after-eof: expected 7 relayed OK replies, saw $ok_count"
pass '32: a delegate slow to exit after stdin closes is waited for and its status kept'

# 33. A delegate that takes 3 seconds to start has not reached the GETPIN
#     when stdin closes, so it is not stuck in a dialog: the wrapper waits for
#     it to answer, relays the reply, and exits with its status.
out="$scratch/out33" err="$scratch/err33"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT Admin PIN\nSETDESC Please enter the Admin PIN\nGETPIN\n')
rc=0
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 FAKE_DELEGATE_EXIT=7 FAKE_DELEGATE_START_DELAY=3 || rc=$?
[[ $rc -eq 7 ]] || fail "33 slow-start-before-getpin: expected the delegate's status 7, got $rc"
assert_contains "$out" 'D DELEGATE-PIN-gnome' '33 slow-start-before-getpin'
pass '33: a delegate slow to start is not taken for a stuck dialog; its GETPIN reply is relayed'

# 34. SIGTERM while the wrapper is already waiting out a slow delegate after
#     stdin closed: the signal cuts that wait short, so the wrapper terminates
#     the delegate and exits within 8 seconds instead of the full exit grace.
start_wrapper "$scratch/out34" "$scratch/err34" FAKE_DELEGATE_EXIT_DELAY=30
exec {wrapper_in}>&-
"$sleep_bin" 0.5
kill -TERM "$wrapper_pid"
for (( i = 0; i < 80; i++ )); do
  kill -0 "$wrapper_pid" 2>/dev/null || break
  "$sleep_bin" 0.1
done
if kill -0 "$wrapper_pid" 2>/dev/null; then
  kill -KILL "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" || true
  fail "34 sigterm-during-exit-grace: the wrapper was still running 8s after SIGTERM; its stderr: $(<"$scratch/err34")"
fi
rc=0
wait "$wrapper_pid" || rc=$?
# 241 is the delegate's own -SIGTERM status, passed through by os._exit.
[[ $rc -eq 241 ]] || fail "34 sigterm-during-exit-grace: expected the terminated delegate's status 241, got $rc; stderr: $(<"$scratch/err34")"
pass '34: SIGTERM during the post-EOF wait for a slow delegate still exits promptly'

# 35. The delegate answers every command and exits, but the relay thread is
#     slow to pass the replies on: on a loaded builder it can go unscheduled
#     for seconds.  This copy of the wrapper stalls the relay 0.5 seconds per
#     line, about 4 seconds for the greeting and seven replies, and every
#     reply must still reach the client.
sed '/^        chunk = delegate_stdout.readline()$/a\        time.sleep(0.5)' \
  "$scratch/functional-gnome.py" >"$scratch/functional-slow-relay.py"
grep -qFx '        time.sleep(0.5)' "$scratch/functional-slow-relay.py" || fail '35 slow-relay: the test could not slow the relay down'
out="$scratch/out35" err="$scratch/err35"
rm -f "$gnome_log"
input=$(printf 'OPTION ttyname=/dev/pts/1\nSETKEYINFO --clear\nSETTITLE\nSETOK\nSETCANCEL\nGETINFO pid\nSETQUALITYBAR\n')
run_wrapper "$scratch/functional-slow-relay.py" "$input" "$out" "$err" DISPLAY=:0
ok_count=$(grep -c '^OK$' "$out" || true)
[[ $ok_count -eq 7 ]] || fail "35 slow-relay: expected 7 relayed OK replies, saw $ok_count"
pass '35: replies the delegate wrote before exiting are relayed even when the relay is seconds behind'

# 36. The slow relay also goes unscheduled for 2.5 seconds inside one write,
#     past DIALOG_GRACE, while the client is still reading: the wrapper must
#     keep waiting rather than take the write for a client that stopped.
sed -e '/^            client_out.flush()$/a\            pump.writes = getattr(pump, "writes", 0) + 1' \
  -e '/^            client_out.flush()$/a\            time.sleep(2.5 if pump.writes == 3 else 0)' \
  "$scratch/functional-slow-relay.py" >"$scratch/functional-stalled-write.py"
[[ $(grep -cFx '            time.sleep(2.5 if pump.writes == 3 else 0)' "$scratch/functional-stalled-write.py") -eq 1 ]] ||
  fail '36 stalled-write: the test could not stall the relay inside a write'
out="$scratch/out36" err="$scratch/err36"
rm -f "$gnome_log"
run_wrapper "$scratch/functional-stalled-write.py" "$input" "$out" "$err" DISPLAY=:0
ok_count=$(grep -c '^OK$' "$out" || true)
[[ $ok_count -eq 7 ]] || fail "36 stalled-write: expected 7 relayed OK replies, saw $ok_count"
pass '36: a write the relay is slow to finish is not taken for a client that stopped reading'

pass 'all U5 test scenarios passed'
