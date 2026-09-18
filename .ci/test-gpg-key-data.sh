#!/usr/bin/env bash
set -euo pipefail

# Validates GPG public key and card data consistency across the repository:
#   1. The recipient literal and yubikeySerials literal list in .chezmoi.toml.tmpl
#      match gpgPubKey and yubikeySerials in .chezmoidata/user.yaml in value,
#      order, and count.
#   2. The yubikeySerials list is non-empty, and every serial is a decimal integer
#      with no leading zeros (per KTD3 normalization).
#   3. The committed public key in .keys/gpg-<FPR>.asc has public key armor headers,
#      contains only public key packets (no secret key packets), and imports into
#      a scratch keyring as exactly one primary key matching gpgPubKey.
#   4. If both private_dot_gnupg/scdaemon.conf and the hook seed text exist,
#      their directives match.
#   5. Fixture mutants verify that:
#      - a template with a changed serial fails naming both values;
#      - a data file with yubikeySerials: [] fails;
#      - a data file with a leading-zero serial fails;
#      - an armored file holding a secret key is rejected naming the secret packet.
#   6. Render cases for .chezmoi.toml.tmpl under the scratch contract (U4):
#      - a non-TTY execute-template --init render emits an empty yubikeyPinPrompted list and runs no snippet;
#      - the same render with existing yubikeyPinPrompted carries the list forward unchanged and runs no snippet;
#      - an interactive render with fixture serials targets only unprompted serials;
#      - the snippet in isolation handles failing chezmoi, blank answer, and delivering PIN on stdin without --value.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo_root"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/gpg-key-data-test
mkdir -p "$scratch_root"
chmod 0700 "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-gpg-key-data: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'test-gpg-key-data: ok - %s\n' "$*"
}

# --- Extraction helpers (fixed-shape scans) -----------------------------------

extract_template_recipient() {
  local tmpl="$1"
  sed -nE 's/^[[:space:]]*recipient[[:space:]]*=[[:space:]]*"([A-Fa-f0-9]+)".*/\1/p' "$tmpl"
}

extract_template_serials() {
  local tmpl="$1"
  sed -nE 's/.*\$yubikeySerials[[:space:]]*:=[[:space:]]*list[[:space:]]+([0-9 ]+)[[:space:]]*-}}/\1/p' "$tmpl" | xargs
}

extract_user_gpg_pubkey() {
  local data="$1"
  sed -nE 's/^[[:space:]]*gpgPubKey:[[:space:]]*"?([A-Fa-f0-9]+)"?.*/\1/p' "$data"
}

extract_user_serials() {
  local data="$1"
  sed -nE 's/^[[:space:]]*yubikeySerials:[[:space:]]*\[([0-9, ]*)\].*/\1/p' "$data" | tr ',' ' ' | xargs
}

# --- Validation functions -----------------------------------------------------

check_parity() {
  local tmpl_file="$1"
  local data_file="$2"

  local recipient serials gpg_pubkey user_serials
  recipient=$(extract_template_recipient "$tmpl_file")
  serials=$(extract_template_serials "$tmpl_file")
  gpg_pubkey=$(extract_user_gpg_pubkey "$data_file")
  user_serials=$(extract_user_serials "$data_file")

  [[ -n "$recipient" ]] || fail "could not extract recipient from $tmpl_file"
  [[ -n "$gpg_pubkey" ]] || fail "could not extract gpgPubKey from $data_file"

  if [[ "$recipient" != "$gpg_pubkey" ]]; then
    fail "recipient mismatch: template has '$recipient', user.yaml has '$gpg_pubkey'"
  fi

  local raw_serials_line
  raw_serials_line=$(grep -E '^[[:space:]]*yubikeySerials:' "$data_file" || true)
  [[ -n "$raw_serials_line" ]] || fail "yubikeySerials missing from $data_file"

  if [[ -z "$user_serials" ]]; then
    fail "yubikeySerials in $data_file must not be empty"
  fi

  local s
  for s in $user_serials; do
    if [[ ! "$s" =~ ^[1-9][0-9]*$ ]]; then
      fail "invalid serial '$s' in $data_file: leading zeros or non-digits are forbidden"
    fi
  done

  if [[ -z "$serials" ]]; then
    fail "could not extract yubikeySerials literal from $tmpl_file"
  fi

  for s in $serials; do
    if [[ ! "$s" =~ ^[1-9][0-9]*$ ]]; then
      fail "invalid serial '$s' in $tmpl_file: leading zeros or non-digits are forbidden"
    fi
  done

  if [[ "$serials" != "$user_serials" ]]; then
    fail "serials mismatch: template has '$serials', user.yaml has '$user_serials'"
  fi
}

validate_key_file() {
  local file="$1"
  local expected_fpr="${2:-}"

  [[ -f "$file" ]] || fail "key file does not exist: $file"

  # Packet inspection: reject any secret key packet
  local packets secret_packet
  packets=$(gpg --list-packets "$file" 2>/dev/null || true)
  secret_packet=$(grep -oE ':(secret[a-z ]*packet):' <<<"$packets" | head -n 1 | tr -d ':' || true)
  if [[ -n "$secret_packet" ]]; then
    fail "rejected key file $file: contains $secret_packet"
  fi

  # Armor header inspection
  local first_line last_line
  first_line=$(grep -m 1 '^-----' "$file" || true)
  last_line=$(grep '^-----END' "$file" | tail -n 1 || true)

  if [[ "$first_line" != "-----BEGIN PGP PUBLIC KEY BLOCK-----" ]]; then
    fail "key file $file does not begin with PUBLIC KEY BLOCK armor header (got: $first_line)"
  fi
  if [[ "$last_line" != "-----END PGP PUBLIC KEY BLOCK-----" ]]; then
    fail "key file $file does not end with PUBLIC KEY BLOCK armor header (got: $last_line)"
  fi

  if grep -qE 'PRIVATE KEY BLOCK|SECRET KEY BLOCK' "$file"; then
    fail "key file $file contains private/secret key block header"
  fi

  # Keyring import into scratch GNUPGHOME
  if [[ -n "$expected_fpr" ]]; then
    local check_home="$scratch/key-check-gnupg"
    rm -rf "$check_home"
    mkdir -p "$check_home"
    chmod 0700 "$check_home"
    GNUPGHOME="$check_home" gpg --batch --no-tty --import "$file" 2>/dev/null || fail "failed to import $file into scratch keyring"

    local listing pub_count imported_fpr
    listing=$(GNUPGHOME="$check_home" gpg --batch --no-tty --with-colons --fingerprint)
    pub_count=$(grep -c '^pub:' <<<"$listing" || true)
    if (( pub_count != 1 )); then
      fail "expected exactly 1 primary public key in $file, found $pub_count"
    fi

    imported_fpr=$(awk -F: '/^pub:/{getline; if ($1=="fpr") print $10}' <<<"$listing")
    if [[ "$imported_fpr" != "$expected_fpr" ]]; then
      fail "fingerprint mismatch: imported key has '$imported_fpr', expected '$expected_fpr'"
    fi
  fi
}

check_scdaemon_conf_parity() {
  local managed="$source_root/private_dot_gnupg/scdaemon.conf"
  local hook="$repo_root/.install-prerequisites.sh"

  if [[ -f "$managed" ]] && grep -q 'scdaemon\.conf' "$hook"; then
    local managed_directives hook_directives
    managed_directives=$(grep -E '^[[:space:]]*(disable-ccid|pcsc-shared)' "$managed" | sort | xargs)
    hook_directives=$(grep -E '(disable-ccid|pcsc-shared)' "$hook" | grep -oE '(disable-ccid|pcsc-shared)' | sort -u | xargs)
    if [[ "$managed_directives" != "$hook_directives" ]]; then
      fail "scdaemon.conf content mismatch: managed has '$managed_directives', hook seed has '$hook_directives'"
    fi
  fi
}

# --- Production checks --------------------------------------------------------

# 1. Parity between .chezmoi.toml.tmpl and .chezmoidata/user.yaml
check_parity "$source_root/.chezmoi.toml.tmpl" "$source_root/.chezmoidata/user.yaml"
pass "recipient literal equals gpgPubKey and serial literal equals yubikeySerials"

# 2. Key file validation
pubkey=$(extract_user_gpg_pubkey "$source_root/.chezmoidata/user.yaml")
key_file="$source_root/.keys/gpg-${pubkey}.asc"
validate_key_file "$key_file" "$pubkey"
pass "committed key file is public only, matches fingerprint, and imports cleanly"

# 3. scdaemon.conf parity check
check_scdaemon_conf_parity
pass "scdaemon.conf parity verified"

# --- Mutant and fixture checks ------------------------------------------------

# Fixture 1: Template with changed serial fails naming both values
mutant_tmpl="$scratch/mutant-tmpl.toml.tmpl"
sed 's/14963605/14963606/' "$source_root/.chezmoi.toml.tmpl" > "$mutant_tmpl"
mutant_err=$(check_parity "$mutant_tmpl" "$source_root/.chezmoidata/user.yaml" 2>&1) || true
if ! grep -q "14963606" <<<"$mutant_err" || ! grep -q "14963605" <<<"$mutant_err"; then
  fail "mutant template check did not fail naming both values; output was: $mutant_err"
fi
pass "fixture template with altered serial fails naming both values"

# Fixture 2: Data file with empty yubikeySerials fails
empty_data="$scratch/empty-serials.yaml"
sed 's/yubikeySerials:.*/yubikeySerials: []/' "$source_root/.chezmoidata/user.yaml" > "$empty_data"
empty_err=$(check_parity "$source_root/.chezmoi.toml.tmpl" "$empty_data" 2>&1) || true
if ! grep -qi "empty" <<<"$empty_err"; then
  fail "mutant data file with empty serials did not fail with empty message; output was: $empty_err"
fi
pass "fixture data file with empty yubikeySerials fails"

# Fixture 3: Data file with a serial containing a leading zero fails
leading_zero_data="$scratch/leading-zero-serials.yaml"
sed 's/14963605/014963605/' "$source_root/.chezmoidata/user.yaml" > "$leading_zero_data"
zero_err=$(check_parity "$source_root/.chezmoi.toml.tmpl" "$leading_zero_data" 2>&1) || true
if ! grep -qi "leading zero" <<<"$zero_err"; then
  fail "mutant data file with leading zero did not fail with leading zero message; output was: $zero_err"
fi
pass "fixture data file with leading zero serial fails"

# Fixture 4: Armored file holding a secret key is rejected naming the secret packet
throwaway_home="$scratch/throwaway-gnupg"
mkdir -p "$throwaway_home"
chmod 0700 "$throwaway_home"
GNUPGHOME="$throwaway_home" gpg --batch --passphrase '' --quick-generate-key 'Throwaway <throwaway@example.invalid>' default default 0 2>/dev/null
secret_key_file="$scratch/throwaway-secret.asc"
GNUPGHOME="$throwaway_home" gpg --batch --armor --export-secret-keys 'Throwaway' > "$secret_key_file" 2>/dev/null
secret_err=$(validate_key_file "$secret_key_file" 2>&1) || true
if ! grep -q "secret key packet" <<<"$secret_err"; then
  fail "fixture armored secret key did not fail naming secret key packet; output was: $secret_err"
fi
pass "fixture armored file holding a secret key is rejected naming the secret packet"

# --- Render and prompt cases (U4) ---------------------------------------------

render_scratch="$scratch/render"
mkdir -p "$render_scratch/bin" "$render_scratch/target"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$render_scratch/bin/op"
chmod 700 "$render_scratch/bin/op"
printf '[data]\n' > "$render_scratch/empty.toml"
chezmoi_bin=$(command -v chezmoi)

snippet_log="$render_scratch/snippet.log"
cat << 'EOF' > "$render_scratch/bin/sh"
#!/usr/bin/env bash
if [ "${1-}" = "-c" ] && [ -n "${4-}" ]; then
  echo "$4" >> "${SNIPPET_LOG:-/dev/null}"
  echo "stored"
  exit 0
fi
exec /bin/bash "$@"
EOF
chmod 700 "$render_scratch/bin/sh"

# Render 1: non-TTY execute-template --init emits an empty yubikeyPinPrompted list and runs no snippet
rm -f "$snippet_log"
render_out1=$(env PATH="$render_scratch/bin:/usr/bin:/bin" SNIPPET_LOG="$snippet_log" "$chezmoi_bin" \
  --config "$render_scratch/empty.toml" \
  --source "$repo_root" \
  --destination "$render_scratch/target" \
  execute-template --init < "$source_root/.chezmoi.toml.tmpl")

if [[ -f "$snippet_log" ]] && [[ -s "$snippet_log" ]]; then
  fail "non-TTY init render ran snippet for serials: $(cat "$snippet_log")"
fi
prompted_line1=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' <<<"$render_out1" || true)
if [[ "$prompted_line1" != *"yubikeyPinPrompted = []"* ]]; then
  fail "non-TTY init render expected 'yubikeyPinPrompted = []', got: '$prompted_line1'"
fi
pass "non-TTY init render emits empty yubikeyPinPrompted list and runs no snippet"

# Render 2: non-TTY render with existing yubikeyPinPrompted carries it forward unchanged and runs no snippet
rm -f "$snippet_log"
render_out2=$(env PATH="$render_scratch/bin:/usr/bin:/bin" SNIPPET_LOG="$snippet_log" "$chezmoi_bin" \
  --config "$render_scratch/empty.toml" \
  --source "$repo_root" \
  --destination "$render_scratch/target" \
  --override-data '{"yubikeyPinPrompted":["14963605"]}' \
  execute-template --init < "$source_root/.chezmoi.toml.tmpl")

if [[ -f "$snippet_log" ]] && [[ -s "$snippet_log" ]]; then
  fail "non-TTY override render ran snippet for serials: $(cat "$snippet_log")"
fi
prompted_line2=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' <<<"$render_out2" || true)
if [[ "$prompted_line2" != *'yubikeyPinPrompted = ["14963605"]'* ]]; then
  fail "non-TTY override render expected 'yubikeyPinPrompted = [\"14963605\"]', got: '$prompted_line2'"
fi
pass "non-TTY init render with existing prompted list carries it forward unchanged and runs no snippet"

# Render 3: fixture render with multiple serials targets only unprompted serial
fixture_tmpl="$render_scratch/fixture-multi-serial.toml.tmpl"
sed 's/\$yubikeySerials := list [0-9 ]*-}}/$yubikeySerials := list 14963605 20000001 -}}/' \
  "$source_root/.chezmoi.toml.tmpl" > "$fixture_tmpl"

rm -f "$snippet_log"
python3 -c "
import pty, os, subprocess
master, slave = pty.openpty()
proc = subprocess.Popen(
    ['$chezmoi_bin', '--config', '$render_scratch/empty.toml',
     '--source', '$repo_root', '--destination', '$render_scratch/target',
     '--override-data', '{\"yubikeyPinPrompted\":[\"14963605\"]}',
     'execute-template', '--init', '--file', '$fixture_tmpl'],
    stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env=dict(os.environ, PATH='$render_scratch/bin:/usr/bin:/bin', SNIPPET_LOG='$snippet_log')
)
os.close(slave)
out, err = proc.communicate()
if proc.returncode != 0:
    print('ERROR:', err.decode())
    exit(proc.returncode)
with open('$render_scratch/render_out3.txt', 'wb') as f:
    f.write(out)
"

if [[ ! -f "$snippet_log" ]]; then
  fail "interactive fixture render did not invoke stub snippet"
fi
logged_serials=$(xargs < "$snippet_log")
if [[ "$logged_serials" != "20000001" ]]; then
  fail "interactive fixture render targeted '$logged_serials', expected only '20000001'"
fi

render_out3=$(cat "$render_scratch/render_out3.txt")
prompted_line3=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' <<<"$render_out3" || true)
if [[ "$prompted_line3" != *'["14963605","20000001"]'* ]] && [[ "$prompted_line3" != *'["14963605", "20000001"]'* ]]; then
  fail "interactive fixture render expected both serials in yubikeyPinPrompted, got: '$prompted_line3'"
fi
pass "fixture render with multiple serials targets only unprompted serial"

# ---------------------------------------------------------------------------
# Render 4-6: pty-driven cases against a fixture copy of the template with the
# REAL sh (not the Render-3 stub) and a stubbed chezmoi executable.
#
# chezmoi's `output` gives the child's stdin /dev/null regardless of the
# operator's real terminal (Go's exec.Cmd sets a nil Stdin), so a snippet
# that gated its prompt on `[ -t 0 ]` was always dead under `output`, yet
# still recorded the serial as prompted. The fix opens /dev/tty directly. A
# stub `sh` (as Render 1-3 use) can never observe this: it never execs a
# real shell against a real controlling terminal. These scenarios do, via a
# pty.fork() child that gives chezmoi (and the sh it spawns) a genuine
# controlling terminal, the same condition an interactive `chezmoi init`
# runs under.
# ---------------------------------------------------------------------------
mkdir -p "$render_scratch/bin2"
cp "$render_scratch/bin/op" "$render_scratch/bin2/op"

realsh_fixture_tmpl="$render_scratch/fixture-realsh.toml.tmpl"

make_stub_chezmoi_exec() {
  local path="$1" log="$2" exit_code="$3"
  cat << EOF > "$path"
#!/usr/bin/env bash
printf 'called: %s\n' "\$*" >> "$log"
IFS= read -r pin
printf 'pin: %s\n' "\$pin" >> "$log"
exit $exit_code
EOF
  chmod 700 "$path"
}

stub_chezmoi_ok="$render_scratch/stub-chezmoi-ok"
stub_chezmoi_ok_log="$render_scratch/stub-chezmoi-ok.log"
make_stub_chezmoi_exec "$stub_chezmoi_ok" "$stub_chezmoi_ok_log" 0

stub_chezmoi_fail="$render_scratch/stub-chezmoi-fail"
stub_chezmoi_fail_log="$render_scratch/stub-chezmoi-fail.log"
make_stub_chezmoi_exec "$stub_chezmoi_fail" "$stub_chezmoi_fail_log" 1

render_realsh_fixture() {
  local stub_path="$1" out="$2"
  python3 -c "
import json
with open('$fixture_tmpl') as f:
    text = f.read()
text = text.replace('\$.chezmoi.executable', json.dumps('$stub_path'))
with open('$out', 'w') as f:
    f.write(text)
"
}

cat << 'PYEOF' > "$render_scratch/pty_driver.py"
import os
import pty
import select
import sys
import time

env = os.environ
pid, master_fd = pty.fork()
if pid == 0:
    os.environ["PATH"] = env["CHILD_PATH"]
    args = [
        env["CHEZMOI_BIN"], "--config", env["CFG"], "--source", env["SRC"],
        "--destination", env["DEST"], "--override-data", env["OVERRIDE_DATA"],
        "execute-template", "--init", "--file", env["FIXTURE"],
    ]
    os.execvp(env["CHEZMOI_BIN"], args)
    os._exit(127)

marker = env.get("MARKER", "").encode()
reply = env.get("REPLY")
buf = b""
start = time.time()
sent = False
while time.time() - start < 15:
    r, _, _ = select.select([master_fd], [], [], 1)
    if master_fd in r:
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if not sent and marker and marker in buf:
            time.sleep(0.2)
            if reply is not None:
                os.write(master_fd, reply.encode() + b"\n")
            sent = True
    try:
        wpid, _status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if wpid == pid:
        break

try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass

with open(env["OUT_FILE"], "wb") as f:
    f.write(buf)
PYEOF

run_init_pty() {
  local fixture="$1" out_file="$2" marker="$3" reply="$4"
  CHEZMOI_BIN="$chezmoi_bin" CFG="$render_scratch/empty.toml" SRC="$repo_root" \
    DEST="$render_scratch/target" OVERRIDE_DATA='{"yubikeyPinPrompted":["14963605"]}' \
    FIXTURE="$fixture" OUT_FILE="$out_file" MARKER="$marker" REPLY="$reply" \
    CHILD_PATH="$render_scratch/bin2:/usr/bin:/bin" \
    python3 "$render_scratch/pty_driver.py"
}

prompt_marker='PIN for serial 20000001'

# Render 4: real terminal, valid PIN -- the golden path the [ -t 0 ] bug broke
render_realsh_fixture "$stub_chezmoi_ok" "$realsh_fixture_tmpl"
rm -f "$stub_chezmoi_ok_log"
out4="$render_scratch/render_out4.txt"
run_init_pty "$realsh_fixture_tmpl" "$out4" "$prompt_marker" 'mySuperSecretPIN'

grep -qF "$prompt_marker" "$out4" || fail "real-tty render with a valid PIN never showed the prompt on the pty"
[[ -f "$stub_chezmoi_ok_log" ]] || fail "real-tty render with a valid PIN never invoked the stub chezmoi executable"
grep -qF -- '--value' "$stub_chezmoi_ok_log" && fail "real-tty render passed the PIN as a --value argument: $(cat "$stub_chezmoi_ok_log")"
grep -qF 'pin: mySuperSecretPIN' "$stub_chezmoi_ok_log" || \
  fail "real-tty render did not deliver the PIN on the stub's stdin: $(cat "$stub_chezmoi_ok_log")"
prompted_line4=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' "$out4" || true)
if [[ "$prompted_line4" != *'"20000001"'* ]]; then
  fail "real-tty render with a stored PIN did not record the serial: '$prompted_line4'"
fi
pass "real-terminal render with a valid PIN shows the prompt on the pty and delivers the PIN on stdin without --value"

# Render 5: real terminal, blank answer -- chezmoi is never called, the serial is still recorded
rm -f "$stub_chezmoi_ok_log"
out5="$render_scratch/render_out5.txt"
run_init_pty "$realsh_fixture_tmpl" "$out5" "$prompt_marker" ''

grep -qF "$prompt_marker" "$out5" || fail "real-tty render with a blank answer never showed the prompt on the pty"
[[ -f "$stub_chezmoi_ok_log" ]] && fail "real-tty render with a blank answer called the stub chezmoi executable"
prompted_line5=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' "$out5" || true)
if [[ "$prompted_line5" != *'"20000001"'* ]]; then
  fail "real-tty render with a blank answer did not record the serial: '$prompted_line5'"
fi
pass "real-terminal render with a blank answer prompts but never calls chezmoi, and still records the serial"

# Render 6: real terminal, chezmoi keyring-set fails -- 'failed' is reported and the serial is NOT recorded
render_realsh_fixture "$stub_chezmoi_fail" "$render_scratch/fixture-realsh-fail.toml.tmpl"
out6="$render_scratch/render_out6.txt"
run_init_pty "$render_scratch/fixture-realsh-fail.toml.tmpl" "$out6" "$prompt_marker" 'anotherPIN'

grep -qF "$prompt_marker" "$out6" || fail "real-tty render with a failing chezmoi never showed the prompt on the pty"
grep -qF 'failed to store PIN in keyring for serial 20000001' "$out6" || \
  fail "real-tty render with a failing chezmoi did not report the failure on the pty: $(cat "$out6")"
prompted_line6=$(grep -E '^[[:space:]]*yubikeyPinPrompted[[:space:]]*=' "$out6" || true)
if [[ "$prompted_line6" == *'"20000001"'* ]]; then
  fail "real-tty render with a failing chezmoi wrongly recorded the serial as prompted: '$prompted_line6'"
fi
pass "real-terminal render with a failing chezmoi reports the failure on the pty and does not record the serial"

pass "all GPG key and data tests passed"
