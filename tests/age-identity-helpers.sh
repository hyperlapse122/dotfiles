#!/usr/bin/env bash
set -euo pipefail

recover=${1:-}
prepare=${2:-}
if [[ $# -ne 2 || ! -f $recover || ! -f $prepare ]]; then
  printf 'usage: %s RECOVER_SCRIPT PREPARE_SCRIPT\n' "${0##*/}" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/age-helpers.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'age-identity-helpers: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'age-identity-helpers: ok - %s\n' "$*"; }

expect_failure() {
  local status=0
  err=$("$@" 2>&1 >/dev/null) || status=$?
  [[ $status -ne 0 ]] || fail "expected non-zero status: $*"
}

# The helpers resolve their repository root from their own location, so give
# each a fake checkout rather than pointing them at the real secrets tree. No
# real key, card, sudo, or /var/lib is touched anywhere below.
fake_repo=$scratch/repo
mkdir -p "$fake_repo/scripts" "$fake_repo/secrets/bootstrap"
cp "$recover" "$fake_repo/scripts/recover-age-identity"
cp "$prepare" "$fake_repo/scripts/prepare-age-identity"
chmod +x "$fake_repo/scripts/"*
recover_bin=$fake_repo/scripts/recover-age-identity
prepare_bin=$fake_repo/scripts/prepare-age-identity

fake_recipient=age1faketestrecipientvaluenotarealkey000000000000000000000
host_dir=$fake_repo/secrets/bootstrap/testhost
mkdir -p "$host_dir"
printf 'not a real ciphertext\n' >"$host_dir/age-key.asc"
printf '%s\n' "$fake_recipient" >"$host_dir/recipient.txt"

# ---------------------------------------------------------------------------
# recover-age-identity
# ---------------------------------------------------------------------------

pipe_stubs=$scratch/pipe-stubs
mkdir -p "$pipe_stubs"
bash_bin_pipe=$(command -v bash) || fail 'bash is required'

expect_failure "$recover_bin" --host nosuchhost
[[ $err == *testhost* ]] || fail "the failure does not list available hosts: $err"
[[ $err == *--host* ]] || fail "the failure does not name --host: $err"
pass 'an unknown host exits non-zero, lists the available hosts and names --host'

# In the rescue path the hostname is the installer image's, not a configuration
# name, so detection finds nothing and --host becomes mandatory.
printf '#!%s\nprintf "nixos-installer\\n"\n' "$bash_bin_pipe" >"$pipe_stubs/uname"
chmod +x "$pipe_stubs/uname"
expect_failure env PATH=$pipe_stubs:$PATH "$recover_bin"
[[ $err == *"no bootstrap material"* ]] || fail "the rescue-path failure did not report missing material: $err"
[[ $err == *--host* ]] || fail "the rescue-path failure does not name --host: $err"
pass 'an undetectable hostname fails and names --host'

# --- the real pipeline -----------------------------------------------------
cat >"$pipe_stubs/sudo" <<STUB
#!$bash_bin_pipe
[[ \${1:-} == -v ]] && exit 0
printf '%s\n' "\$*" >>"$scratch/sudo.log"
[[ \${1:-} == -- ]] && shift
exec "\$@"
STUB
chmod +x "$pipe_stubs/sudo"

# An installer stub that records what reached it, the way the real root-side
# installer reads the identity from stdin and the recipient from argv.
cat >"$pipe_stubs/installer" <<STUB
#!$bash_bin_pipe
printf 'recipient=%s\n' "\$2" >"$scratch/installed.log"
cat >>"$scratch/installed.log"
STUB
chmod +x "$pipe_stubs/installer"
ln -sf "$pipe_stubs/installer" "$pipe_stubs/install-user-age-identity"

cat >"$pipe_stubs/gpg-ok" <<STUB
#!$bash_bin_pipe
printf 'gpg_args=%s\n' "\$*" >"$scratch/gpg.log"
printf "DECRYPTED-IDENTITY\n"
STUB
chmod +x "$pipe_stubs/gpg-ok"
printf '#!%s\nexit 2\n' "$bash_bin_pipe" >"$pipe_stubs/gpg-fail"
chmod +x "$pipe_stubs/gpg-fail"

export RECOVER_AGE_INSTALLER=$pipe_stubs/installer

rm -f "$scratch/installed.log" "$scratch/sudo.log" "$scratch/gpg.log"
ln -sf "$pipe_stubs/gpg-ok" "$pipe_stubs/gpg"
PATH=$pipe_stubs:$PATH "$recover_bin" --host testhost >/dev/null 2>&1 ||
  fail 'the happy-path pipeline did not succeed'
[[ -f $scratch/gpg.log ]] || fail 'gpg was not invoked'
grep -qF -- "--decrypt -- $host_dir/age-key.asc" "$scratch/gpg.log" ||
  fail "the resolved ciphertext path is wrong: $(cat "$scratch/gpg.log")"
[[ -f $scratch/sudo.log ]] || fail 'sudo was not invoked on the right-hand side'
[[ $(wc -l <"$scratch/sudo.log") -eq 1 ]] ||
  fail "sudo was invoked more than once for the pipeline: $(cat "$scratch/sudo.log")"
[[ $(<"$scratch/sudo.log") == "-- $pipe_stubs/installer --recipient $fake_recipient" ]] ||
  fail "sudo argv did not match expected right-hand installer call: $(cat "$scratch/sudo.log")"
[[ -f $scratch/installed.log ]] || fail 'the installer never received the decrypted identity'
grep -q "recipient=$fake_recipient" "$scratch/installed.log" ||
  fail "the installer did not receive the recorded recipient: $(cat "$scratch/installed.log")"
grep -q 'DECRYPTED-IDENTITY' "$scratch/installed.log" ||
  fail 'the identity did not reach the installer on stdin'
pass 'the executed pipeline runs gpg as the user, crosses sudo once on the right, and sends the identity on stdin and the recipient in argv'

# pipefail is the reason a GPG failure is not masked by the installer's status.
rm -f "$scratch/installed.log"
ln -sf "$pipe_stubs/gpg-fail" "$pipe_stubs/gpg"
if PATH=$pipe_stubs:$PATH "$recover_bin" --host testhost >/dev/null 2>&1; then
  fail 'a GPG failure was masked by the installer exiting zero'
fi
pass 'a GPG failure on the left of the pipe fails the whole run'

# A missing installer must be named rather than producing a broken pipe.
ln -sf "$pipe_stubs/gpg-ok" "$pipe_stubs/gpg"
expect_failure env RECOVER_AGE_INSTALLER=$scratch/absent-installer \
  PATH=$pipe_stubs:$PATH "$recover_bin" --host testhost
[[ $err == *absent-installer* ]] || fail "a missing installer was not named: $err"
pass 'a missing installer exits non-zero naming the path'

# --- user mode, for a non-NixOS host ---------------------------------------
# The identity goes to the invoking user's installer with no sudo anywhere, and
# the host must be named because the distribution owns the running hostname.

expect_failure "$recover_bin" --user
[[ $err == *--host* ]] || fail "--user without --host does not name --host: $err"
pass '--user without --host exits non-zero and names --host'

rm -f "$scratch/installed.log" "$scratch/sudo.log"
ln -sf "$pipe_stubs/gpg-ok" "$pipe_stubs/gpg"
PATH=$pipe_stubs:$PATH "$recover_bin" --user --host testhost >/dev/null 2>&1 ||
  fail 'the user-mode pipeline did not succeed'
[[ ! -e $scratch/sudo.log ]] || fail "user mode invoked sudo: $(cat "$scratch/sudo.log")"
grep -q "recipient=$fake_recipient" "$scratch/installed.log" ||
  fail "the user installer did not receive the recorded recipient: $(cat "$scratch/installed.log")"
grep -q 'DECRYPTED-IDENTITY' "$scratch/installed.log" ||
  fail 'the identity did not reach the user installer on stdin'
pass 'the executed user-mode pipeline sends the identity to the user installer and never crosses sudo'

# ---------------------------------------------------------------------------
# prepare-age-identity
# ---------------------------------------------------------------------------

unset RECOVER_AGE_INSTALLER

runtime=$scratch/runtime
mkdir -p "$runtime"
export PREPARE_AGE_RUNTIME_DIR=$runtime

stub_dir=$scratch/stubs
mkdir -p "$stub_dir"

# The Nix sandbox has no /usr/bin/env, so stubs get a resolved interpreter.
bash_bin=$(command -v bash) || fail 'bash is required'
stub() { printf '#!%s\n' "$bash_bin" >"$stub_dir/$1"; }

# A fake age-keygen: writes a deterministic "identity" and derives a recipient
# from it, so the round-trip comparison is meaningful without real crypto.
stub age-keygen
cat >>"$stub_dir/age-keygen" <<'STUB'
set -euo pipefail
if [[ ${1:-} == -o ]]; then
  printf 'FAKE-IDENTITY-%s\n' "${FAKE_IDENTITY_TAG:-default}" >"$2"
  exit 0
fi
if [[ ${1:-} == -y ]]; then
  printf 'age1fake%s\n' "$(tr -dc 'a-z0-9' <"$2" | tail -c 20)"
  exit 0
fi
exit 2
STUB
chmod +x "$stub_dir/age-keygen"

# A fake gpg. Encrypt base64-encodes and decrypt decodes, so the "ciphertext"
# is reversible without containing the plaintext -- a plain copy would make the
# no-plaintext-in-the-repository assertion below vacuous.
stub gpg-good
cat >>"$stub_dir/gpg-good" <<'STUB'
set -euo pipefail
out=; src=; mode=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --armor|--batch|--no-tty) shift ;;
    --recipient) shift 2 ;;
    *) src=$1; shift ;;
  esac
done
if [[ $mode == decrypt ]]; then
  base64 -d <"$src" >"$out"
else
  base64 <"$src" >"$out"
fi
STUB
chmod +x "$stub_dir/gpg-good"

# A fake gpg that encrypts to something that decrypts back to a different key.
stub gpg-corrupt
cat >>"$stub_dir/gpg-corrupt" <<'STUB'
set -euo pipefail
out=; src=; mode=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --armor|--batch|--no-tty) shift ;;
    --recipient) shift 2 ;;
    *) src=$1; shift ;;
  esac
done
if [[ $mode == decrypt ]]; then
  printf 'FAKE-IDENTITY-tampered\n' >"$out"
else
  base64 <"$src" >"$out"
fi
STUB
chmod +x "$stub_dir/gpg-corrupt"

# Happy path
ln -sf "$stub_dir/gpg-good" "$stub_dir/gpg"
PATH=$stub_dir:$PATH "$prepare_bin" --host newhost --recipient DEADBEEF >/dev/null
new_dir=$fake_repo/secrets/bootstrap/newhost
[[ -f $new_dir/age-key.asc ]] || fail 'the ciphertext was not written'
[[ -f $new_dir/recipient.txt ]] || fail 'the recipient was not recorded'
[[ -s $new_dir/recipient.txt ]] || fail 'the recorded recipient is empty'
pass 'a successful run writes both files under the per-host directory'

[[ -z $(ls -A "$runtime") ]] || fail "plaintext survived in $runtime: $(ls -A "$runtime")"
pass 'the runtime directory is left empty, so no plaintext survives'

if grep -rqF 'FAKE-IDENTITY' "$fake_repo/secrets"; then
  fail 'plaintext identity material was written into the repository'
fi
pass 'no plaintext identity material reaches the repository'

# Refuses to overwrite
if PATH=$stub_dir:$PATH "$prepare_bin" --host newhost --recipient DEADBEEF >/dev/null 2>&1; then
  fail 'an existing host directory should not be overwritten'
fi
pass 'an existing host directory is refused rather than overwritten'

# Round-trip verification
ln -sf "$stub_dir/gpg-corrupt" "$stub_dir/gpg"
if PATH=$stub_dir:$PATH "$prepare_bin" --host badhost --recipient DEADBEEF >/dev/null 2>&1; then
  fail 'a ciphertext that decrypts to a different identity should fail'
fi
bad_dir=$fake_repo/secrets/bootstrap/badhost
[[ ! -f $bad_dir/age-key.asc ]] || fail 'a failed round trip left the ciphertext behind'
[[ ! -f $bad_dir/recipient.txt ]] || fail 'a failed round trip left the recipient behind'
pass 'a ciphertext that does not decrypt back fails and leaves no files behind'

[[ -z $(ls -A "$runtime") ]] || fail 'the trap did not clean the runtime directory after failure'
pass 'the trap clears the runtime directory on the failure path too'

# A gpg that writes its output file and then fails: the partial ciphertext must
# not survive, and the host directory must not be left half-populated.
stub gpg-halfwrite
cat >>"$stub_dir/gpg-halfwrite" <<'STUB'
set -uo pipefail
out=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    --recipient) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $out ]] && printf 'partial\n' >"$out"
exit 4
STUB
chmod +x "$stub_dir/gpg-halfwrite"

ln -sf "$stub_dir/gpg-halfwrite" "$stub_dir/gpg"
if PATH=$stub_dir:$PATH "$prepare_bin" --host halfhost --recipient DEADBEEF >/dev/null 2>&1; then
  fail 'an encryption failure should not succeed'
fi
[[ ! -e $fake_repo/secrets/bootstrap/halfhost ]] ||
  fail "an encryption failure left the host directory behind: $(ls -A "$fake_repo/secrets/bootstrap/halfhost")"
pass 'an encryption failure that wrote a partial ciphertext leaves nothing behind'

# An interruption between the two writes must leave nothing behind either.
# SIGTERM during the round-trip decrypt is the narrowest way to reach the gap
# the explicit failure branches do not cover.
stub gpg-hang
cat >>"$stub_dir/gpg-hang" <<'STUB'
set -uo pipefail
out=; mode=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) out=$2; shift 2 ;;
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --recipient) shift 2 ;;
    *) src=$1; shift ;;
  esac
done
if [[ $mode == decrypt ]]; then
  sleep 30
else
  base64 <"$src" >"$out"
fi
STUB
chmod +x "$stub_dir/gpg-hang"

ln -sf "$stub_dir/gpg-hang" "$stub_dir/gpg"
PATH=$stub_dir:$PATH "$prepare_bin" --host hanghost --recipient DEADBEEF >/dev/null 2>&1 &
prepare_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f $fake_repo/secrets/bootstrap/hanghost/age-key.asc ]] && break
  sleep 0.1
done
[[ -f $fake_repo/secrets/bootstrap/hanghost/age-key.asc ]] ||
  fail 'gpg-hang never wrote age-key.asc before SIGTERM'
kill -TERM "$prepare_pid" 2>/dev/null || true
wait "$prepare_pid" 2>/dev/null || true
[[ ! -e $fake_repo/secrets/bootstrap/hanghost ]] ||
  fail "an interrupted run left the host directory behind: $(ls -A "$fake_repo/secrets/bootstrap/hanghost")"
[[ -z $(ls -A "$runtime") ]] || fail 'an interrupted run left plaintext in the runtime directory'
pass 'an interrupted run leaves neither the ciphertext nor plaintext behind'

# ---------------------------------------------------------------------------
# root refusal
# ---------------------------------------------------------------------------

# Simulate an effective uid of 0 by shadowing id(1) on PATH.
real_id=$(command -v id) || fail 'id is required'
stub id
cat >>"$stub_dir/id" <<STUB
if [[ \${1:-} == -u ]]; then printf '0\n'; exit 0; fi
exec $real_id "\$@"
STUB
chmod +x "$stub_dir/id"

for bin in "$recover_bin" "$prepare_bin"; do
  name=${bin##*/}
  if PATH=$stub_dir:$PATH "$bin" --host testhost >/dev/null 2>&1; then
    fail "$name should refuse to run as root"
  fi
  expect_failure env PATH=$stub_dir:$PATH "$bin" --host testhost
  [[ $err == *root* ]] || fail "$name refusal does not mention root: $err"
done
rm -f "$stub_dir/id"
pass 'both helpers refuse to run as root, naming the boundary'

# ---------------------------------------------------------------------------
# no key material in output
# ---------------------------------------------------------------------------

ln -sf "$stub_dir/gpg-good" "$stub_dir/gpg"
combined=$(PATH=$stub_dir:$PATH "$prepare_bin" --host quiethost --recipient DEADBEEF 2>&1)
[[ $combined != *FAKE-IDENTITY* ]] || fail 'the helper printed identity material'
pass 'the helper prints the public recipient but never identity material'

printf 'age-identity-helpers: all checks passed\n'
