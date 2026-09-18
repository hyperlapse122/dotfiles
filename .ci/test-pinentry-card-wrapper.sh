#!/usr/bin/env bash
# Card PIN wrapper (KTD6, U5): private_dot_gnupg/executable_pinentry-card.tmpl.
#
# Two halves, the same split .ci/test-sudo-elevation-guard.sh uses:
#
# RENDER half: renders the four OS/desktop variants (gnome, kde, none,
# darwin) and checks the constants each one bakes in, plus that every variant
# compiles with `python3 -m py_compile`.
#
# BEHAVIOR half: the rendered wrapper is a real Assuan proxy, so it is run
# for real against a fake delegate (logs every command it receives, answers
# OK or D/OK on GETPIN) and stub `secret-tool`/`security` keyring commands,
# all on PATH. The delegate is spawned from an ABSOLUTE rendered path (KTD6),
# so a PATH stub cannot substitute it; the behaviour fixtures rewrite that
# literal to a scratch path instead, the same technique
# test-sudo-elevation-guard.sh uses for its askpass helper. The keyring
# lookup's 5-second bound is likewise rewritten to 1 second so the
# past-the-bound scenario does not spend 5+ real seconds in CI; the render
# half pins the production 5-second constant separately.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

setup_render_scratch pinentry-card-wrapper
mkdir -p "$scratch/home"

fail() { printf 'pinentry-card-wrapper: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'pinentry-card-wrapper: ok - %s\n' "$*"; }

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'

source_template="$source_root/private_dot_gnupg/executable_pinentry-card.tmpl"
require_file "$repo_root" "$scratch" "$chezmoi_bin" private_dot_gnupg/executable_pinentry-card.tmpl

# ---------------------------------------------------------------------------
# RENDER half
# ---------------------------------------------------------------------------

render_variant() {
  local label=$1 os=$2 desktop=$3 arch=${4:-}
  local variant="$scratch/variant-$label.tmpl" out="$scratch/rendered-$label.py"
  local override_data=''
  [[ -z "$arch" ]] || override_data="{\"chezmoi\":{\"os\":\"$os\",\"arch\":\"$arch\"}}"
  write_fact_stub "$source_template" "$variant" false false "$desktop"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$variant" "$out" "$override_data"
  printf '%s\n' "$out"
}

rendered_gnome=$(render_variant gnome linux gnome)
rendered_kde=$(render_variant kde linux kde)
rendered_none=$(render_variant none linux none)
rendered_darwin=$(render_variant darwin darwin gnome arm64)
rendered_darwin_amd64=$(render_variant darwin-amd64 darwin gnome amd64)

assert_first_line() {
  local file=$1 expected=$2 label=$3
  local first_line
  first_line=$(head -n1 -- "$file")
  [[ "$first_line" == "$expected" ]] || fail "$label: shebang is $(printf '%q' "$first_line"), expected $(printf '%q' "$expected")"
}

for entry in "gnome:$rendered_gnome" "kde:$rendered_kde" "none:$rendered_none" "darwin:$rendered_darwin" "darwin-amd64:$rendered_darwin_amd64"; do
  label=${entry%%:*}
  rendered=${entry#*:}
  assert_first_line "$rendered" '#!/usr/bin/python3' "render $label"
  python3 -m py_compile "$rendered" || fail "render $label: python3 -m py_compile failed"
done
pass 'every rendered variant starts with the /usr/bin/python3 shebang and compiles'

grep -qF 'DELEGATE_PATH = "/usr/bin/pinentry-gnome3"' "$rendered_gnome" || fail 'gnome variant does not name pinentry-gnome3'
grep -qF 'IS_LINUX = True' "$rendered_gnome" || fail 'gnome variant is not IS_LINUX = True'
grep -qF 'KEYRING_BACKEND = "secret-tool"' "$rendered_gnome" || fail 'gnome variant does not use secret-tool'
pass 'gnome render names pinentry-gnome3 with the secret-tool backend'

grep -qF 'DELEGATE_PATH = "/usr/bin/pinentry-qt"' "$rendered_kde" || fail 'kde variant does not name pinentry-qt'
pass 'kde render names pinentry-qt'

grep -qF 'DELEGATE_PATH = "/usr/bin/pinentry-curses"' "$rendered_none" || fail 'none variant does not name pinentry-curses'
pass 'headless (none) render names pinentry-curses'

grep -qF 'DELEGATE_PATH = "/opt/homebrew/bin/pinentry-mac"' "$rendered_darwin" || fail 'darwin arm64 variant does not name /opt/homebrew pinentry-mac'
grep -qF 'IS_LINUX = False' "$rendered_darwin" || fail 'darwin variant is not IS_LINUX = False'
grep -qF 'KEYRING_BACKEND = "security"' "$rendered_darwin" || fail 'darwin variant does not use security'
pass 'darwin arm64 render names /opt/homebrew/bin/pinentry-mac with the security backend'

# Intel Homebrew installs to /usr/local, not /opt/homebrew (KTD6); the hook's
# own activate_homebrew() tries /opt/homebrew first and falls back to
# /usr/local, so the wrapper must select by .chezmoi.arch, not a fixed path.
grep -qF 'DELEGATE_PATH = "/usr/local/bin/pinentry-mac"' "$rendered_darwin_amd64" || \
  fail 'darwin amd64 variant does not name /usr/local pinentry-mac'
pass 'darwin amd64 render names /usr/local/bin/pinentry-mac (Intel Homebrew prefix)'

# The production 5-second keyring-lookup bound, pinned here; the behaviour
# fixtures below rewrite it down so CI does not pay the real 5 seconds.
grep -qF 'KEYRING_LOOKUP_TIMEOUT = 5' "$rendered_gnome" || fail 'the 5-second keyring lookup bound regressed'
pass 'the keyring lookup bound is 5 seconds in the rendered wrapper'

# ---------------------------------------------------------------------------
# BEHAVIOR half: fake delegate, stub keyring commands
# ---------------------------------------------------------------------------

# The PIN chosen for every "answered" scenario below deliberately carries a
# '%' and a space, so every happy-path assertion also proves percent-encoding
# without a separate fixture.
stored_pin='te%st pin'
stored_pin_encoded='te%25st pin'
stored_serial='14963605'

cat >"$scratch/fake-delegate.py" <<'PYEOF'
#!/usr/bin/env python3
"""Test double for the real desktop pinentry: logs every Assuan command line
it receives (byte-exact) and answers OK, or D <tag>/OK on GETPIN, unless told
to hang on GETPIN to simulate a still-open dialog."""
import os
import sys
import time

log_path = os.environ["FAKE_DELEGATE_LOG"]
hang = os.environ.get("FAKE_DELEGATE_HANG_ON_GETPIN") == "1"
tag = os.environ.get("FAKE_DELEGATE_TAG", "delegate")


def log(data):
    with open(log_path, "ab") as fh:
        fh.write(data)


out = sys.stdout.buffer
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
sys.exit(0)
PYEOF

make_delegate_shim() {
  local name=$1 tag=$2 log=$3
  cat >"$scratch/bin/$name" <<SHIM
#!/usr/bin/env bash
export FAKE_DELEGATE_TAG="$tag"
export FAKE_DELEGATE_LOG="$log"
exec python3 "$scratch/fake-delegate.py" "\$@"
SHIM
  chmod +x "$scratch/bin/$name"
}

gnome_log="$scratch/gnome-delegate.log"
fallback_log="$scratch/fallback-delegate.log"
darwin_log="$scratch/darwin-delegate.log"
make_delegate_shim fake-gnome-delegate gnome "$gnome_log"
make_delegate_shim fake-fallback-delegate fallback "$fallback_log"
make_delegate_shim fake-darwin-delegate darwin "$darwin_log"

# secret-tool lookup service gnupg-card-pin username <serial>
cat >"$scratch/bin/secret-tool" <<STUB
#!/usr/bin/env bash
mode=\${KEYRING_STUB_MODE:-ok}
serial=\$5
case "\$mode" in
  fail-nonzero) exit 1 ;;
  empty) printf ''; exit 0 ;;
  sleep) sleep 3; exit 0 ;;
esac
if [[ "\$serial" == "$stored_serial" ]]; then
  printf '%s' "$stored_pin"
  exit 0
fi
exit 1
STUB
chmod +x "$scratch/bin/secret-tool"

# security find-generic-password -s gnupg-card-pin -a <serial> -w
stored_pin_b64=$(printf '%s' "$stored_pin" | base64 | tr -d '\n')
stored_pin_hex=$(python3 -c "import sys; sys.stdout.write(sys.argv[1].encode().hex())" "$stored_pin")
cat >"$scratch/bin/security" <<STUB
#!/usr/bin/env bash
mode=\${KEYRING_STUB_MODE:-base64}
serial=\$5
if [[ "\$serial" != "$stored_serial" ]]; then exit 1; fi
case "\$mode" in
  base64) printf 'go-keyring-base64:%s' "$stored_pin_b64"; exit 0 ;;
  hex) printf 'go-keyring-encoded:%s' "$stored_pin_hex"; exit 0 ;;
  locked) echo 'keychain is locked' >&2; exit 44 ;;
esac
STUB
chmod +x "$scratch/bin/security"

# Behaviour fixtures: retarget the absolute delegate path(s) to the scratch
# shims above, and shrink the 5-second keyring bound to 1 second (pinned at
# its real value by the render half above).
sed -e "s#/usr/bin/pinentry-gnome3#$scratch/bin/fake-gnome-delegate#" \
    -e 's/KEYRING_LOOKUP_TIMEOUT = 5/KEYRING_LOOKUP_TIMEOUT = 1/' \
    "$rendered_gnome" >"$scratch/functional-gnome.py"
sed -e "s#/usr/bin/pinentry-gnome3#$scratch/bin/fake-gnome-delegate#" \
    -e "s#/usr/bin/pinentry-curses#$scratch/bin/fake-fallback-delegate#" \
    -e 's/KEYRING_LOOKUP_TIMEOUT = 5/KEYRING_LOOKUP_TIMEOUT = 1/' \
    "$rendered_gnome" >"$scratch/functional-fallback.py"
sed -e "s#/opt/homebrew/bin/pinentry-mac#$scratch/bin/fake-darwin-delegate#" \
    -e 's/KEYRING_LOOKUP_TIMEOUT = 5/KEYRING_LOOKUP_TIMEOUT = 1/' \
    "$rendered_darwin" >"$scratch/functional-darwin.py"

run_wrapper() {
  # run_wrapper <functional.py> <stdin-text> <out-file> <err-file> [env NAME=value ...]
  # <stdin-text> is command-substitution output, which already lost its
  # trailing newline; restore exactly one so the final Assuan line is
  # terminated like every other, instead of looking like a dangling partial
  # line the wrapper must treat as EOF.
  local functional=$1 input=$2 out=$3 err=$4
  shift 4
  printf '%s\n' "$input" | timeout 10 env "$@" PATH="$scratch/bin:/usr/bin:/bin" \
    python3 "$functional" >"$out" 2>"$err"
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

yubikey5_desc() {
  # "Number:" surrounded by \x1e/\x1f alignment bytes, the literal YubiKey 5
  # card-prompt shape (KTD3).
  printf 'Please unlock the card%%0A%%0A\x1eNumber:\x1f 14 963 605%%0AHolder: Jo Doe'
}

# 1. YubiKey 5 form (alignment bytes included): answered directly, delegate
#    never sees GETPIN.
out="$scratch/out1" err="$scratch/err1"
rm -f "$gnome_log"
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$(yubikey5_desc)")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" "D $stored_pin_encoded" '1 yubikey5-form'
assert_contains "$out" $'\nOK\n' '1 yubikey5-form'
assert_contains "$gnome_log" 'SETPROMPT PIN' '1 yubikey5-form'
assert_contains "$gnome_log" 'SETDESC' '1 yubikey5-form'
assert_not_contains "$gnome_log" 'GETPIN' '1 yubikey5-form'
pass '1: YubiKey 5 SETDESC form (alignment bytes) is answered from the keyring, delegate never sees GETPIN'

# 2. Older firmware ("14963605") and non-YubiKey ("0006 14963605") forms
#    normalize to the same serial and are answered the same way.
for number_value in '14963605' '0006 14963605'; do
  out="$scratch/out2" err="$scratch/err2"
  rm -f "$gnome_log"
  desc=$(printf 'Please unlock the card%%0A%%0ANumber: %s%%0AHolder: Jo Doe' "$number_value")
  input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
  assert_contains "$out" "D $stored_pin_encoded" "2 number-form '$number_value'"
  assert_not_contains "$gnome_log" 'GETPIN' "2 number-form '$number_value'"
done
pass '2: older-firmware and non-YubiKey Number forms normalize to the same serial'

# 3. A second "Number:" line (injected, after the holder) disables the match.
out="$scratch/out3" err="$scratch/err3"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 14 963 605%0AHolder: X%0ANumber: 20 000 001'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '3 second-number-line'
assert_not_contains "$out" "D $stored_pin_encoded" '3 second-number-line'
pass '3: a second Number line (holder data) is passed through, never answered'

# 4. A holder name with an invalid UTF-8 byte does not stop classification.
out="$scratch/out4" err="$scratch/err4"
rm -f "$gnome_log"
desc=$(printf 'Please unlock the card%%0A%%0ANumber: 14 963 605%%0AHolder: Jo%%FFhn')
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" "D $stored_pin_encoded" '4 invalid-utf8-holder'
assert_not_contains "$gnome_log" 'GETPIN' '4 invalid-utf8-holder'
pass '4: an invalid UTF-8 byte in the holder name still classifies the prompt'

# 5. An encoded newline, a raw carriage return, a malformed % escape, and an
#    overlong SETDESC: each forwarded raw and never answered.
overlong=$(python3 -c "print('A' * 5000, end='')")
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

# 6. macOS: go-keyring-base64 and go-keyring-encoded (hex) decode to the
#    stored PIN; a locked-keychain error passes through.
desc='Please unlock the card%0A%0ANumber: 14 963 605%0AHolder: Jo Doe'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
out="$scratch/out6-base64" err="$scratch/err6-base64"
run_wrapper "$scratch/functional-darwin.py" "$input" "$out" "$err" KEYRING_STUB_MODE=base64
assert_contains "$out" "D $stored_pin_encoded" '6 go-keyring-base64'
out="$scratch/out6-hex" err="$scratch/err6-hex"
run_wrapper "$scratch/functional-darwin.py" "$input" "$out" "$err" KEYRING_STUB_MODE=hex
assert_contains "$out" "D $stored_pin_encoded" '6 go-keyring-encoded-hex'
out="$scratch/out6-locked" err="$scratch/err6-locked"
rm -f "$darwin_log"
run_wrapper "$scratch/functional-darwin.py" "$input" "$out" "$err" KEYRING_STUB_MODE=locked
assert_contains "$darwin_log" 'GETPIN' '6 locked-keychain'
assert_not_contains "$out" "D $stored_pin_encoded" '6 locked-keychain'
pass '6: macOS go-keyring-base64/-encoded prefixes decode to the stored PIN; a locked keychain passes through'

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
pass '10: a Remaining attempts marker passes through; the stored PIN never appears on stdout'

# 11. A SETERROR before the prompt guards exactly the next GETPIN.
out="$scratch/out11" err="$scratch/err11"
rm -f "$gnome_log"
desc='Please unlock the card%0A%0ANumber: 14 963 605'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nSETERROR Bad PIN\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$gnome_log" 'GETPIN' '11 seterror-guard'
assert_not_contains "$out" "D $stored_pin_encoded" '11 seterror-guard'
pass '11: a SETERROR before the prompt passes the next GETPIN through'

# 12. The keyring stub exits non-zero, prints nothing, or sleeps past the
#     (1-second, rewritten) bound: pass-through in each case.
desc='Please unlock the card%0A%0ANumber: 14 963 605'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
for mode in fail-nonzero empty sleep; do
  out="$scratch/out12-$mode" err="$scratch/err12-$mode"
  rm -f "$gnome_log"
  run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0 KEYRING_STUB_MODE="$mode"
  assert_contains "$gnome_log" 'GETPIN' "12 keyring-stub-$mode"
  assert_not_contains "$out" "D $stored_pin_encoded" "12 keyring-stub-$mode"
done
pass '12: a keyring stub that fails, prints nothing, or times out passes GETPIN through in every case'

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

# 16. A stored PIN containing '%' and a space is emitted percent-encoded
#     (exercised by every "answered" scenario above via $stored_pin).
out="$scratch/out16" err="$scratch/err16"
desc='Please unlock the card%0A%0ANumber: 14 963 605'
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" "D $stored_pin_encoded" '16 percent-encoded-pin'
assert_not_contains "$out" "D $stored_pin" '16 percent-encoded-pin (raw PIN must never appear unescaped)'
pass '16: a stored PIN containing % and a space is emitted percent-encoded'

# 17. Alignment control bytes around "Number:" still match (a distinct byte
#     layout from case 1: bytes on both sides of the label AND the value).
out="$scratch/out17" err="$scratch/err17"
rm -f "$gnome_log"
desc=$(printf 'Please unlock the card%%0A%%0A\x1e\x1fNumber:\x1e 14 963 605\x1f')
input=$(printf 'SETPROMPT PIN\nSETDESC %s\nGETPIN\n' "$desc")
run_wrapper "$scratch/functional-gnome.py" "$input" "$out" "$err" DISPLAY=:0
assert_contains "$out" "D $stored_pin_encoded" '17 alignment-bytes'
assert_not_contains "$gnome_log" 'GETPIN' '17 alignment-bytes'
pass '17: alignment control bytes around the Number label still match'

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

# 20. Render variants naming the right binaries, each compiling, is the
#     RENDER half above (variant checks + py_compile loop).
pass '20: gnome/kde/none/darwin renders name the matching delegate and each compiles (render half)'

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

pass 'all U5 test scenarios passed'
