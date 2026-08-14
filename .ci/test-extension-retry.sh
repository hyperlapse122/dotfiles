#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

new_templates=(
  ".chezmoiscripts/30-linux/run_after_install-vscodium-extensions.sh.tmpl"
  ".chezmoiscripts/50-linux-gnome/run_after_install-gnome-solaar-extension.sh.tmpl"
  ".chezmoiscripts/50-linux-gnome/run_after_install-gnome-kimpanel-extension.sh.tmpl"
)
old_templates=(
  ".chezmoiscripts/30-linux/run_onchange_after_install-vscodium-extensions.sh.tmpl"
  ".chezmoiscripts/50-linux-gnome/run_onchange_after_install-gnome-solaar-extension.sh.tmpl"
  ".chezmoiscripts/50-linux-gnome/run_onchange_after_install-gnome-kimpanel-extension.sh.tmpl"
)

fail() {
  printf 'test-extension-retry: %s\n' "$*" >&2
  exit 1
}

for template in "${old_templates[@]}"; do
  [[ ! -e "$repo_root/$template" ]] || fail "old extension lifecycle source remains: $template"
done
for template in "${new_templates[@]}"; do
  [[ -f "$repo_root/$template" ]] || fail "missing run_after extension source: $template"
  if grep -q 'run_onchange_after_install-' "$repo_root/$template"; then
    fail "stale onchange lifecycle wording remains: $template"
  fi
done

scratch_parent=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/extension-retry.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

source_dir="$scratch/source"
destination="$scratch/destination"
fixture_home="$scratch/home"
state_db="$scratch/state/chezmoi.boltdb"
cache_dir="$scratch/cache"
stub_bin="$scratch/bin"
stub_state="$scratch/stub-state"
runtime_dir="$scratch/runtime"
log="$scratch/transactions.log"

mkdir -p -- \
  "$source_dir/.chezmoiscripts/30-linux" \
  "$source_dir/.chezmoiscripts/50-linux-gnome" \
  "$source_dir/.chezmoiscripts/70-later" \
  "$source_dir/.chezmoitemplates" \
  "$source_dir/.chezmoidata" \
  "$stub_bin"

for template in "${new_templates[@]}"; do
  mkdir -p -- "$source_dir/$(dirname -- "$template")"
  cp -- "$repo_root/$template" "$source_dir/$template"
done

# Copied real, unlike the stubbed guard below: this partial's atomic write and
# symlink refusal are what the signature cases exercise.
cp -- "$repo_root/.chezmoitemplates/extension-signature-stamp.sh.tmpl" \
  "$source_dir/.chezmoitemplates/extension-signature-stamp.sh.tmpl"

cat >"$source_dir/.chezmoitemplates/gnome-guard.sh.tmpl" <<'TEMPLATE'
FACT_DESKTOP=gnome
TEMPLATE

cat >"$source_dir/.chezmoidata/vscodium.yaml" <<'YAML'
vscodium:
  extensions:
    - fixture.vscode
YAML

cat >"$source_dir/.chezmoidata/gnome.yaml" <<'YAML'
gnome:
  shellExtensions:
    solaar:
      uuid: solaar@test
      egoId: 101
    kimpanel:
      uuid: kimpanel@test
      egoId: 102
YAML

cat >"$source_dir/.chezmoiscripts/70-later/run_after_later-phase.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'later-phase\n' >>"$FIXTURE_LOG"
SCRIPT

chmod +x \
  "$source_dir/.chezmoiscripts/30-linux/run_after_install-vscodium-extensions.sh.tmpl" \
  "$source_dir/.chezmoiscripts/50-linux-gnome/run_after_install-gnome-solaar-extension.sh.tmpl" \
  "$source_dir/.chezmoiscripts/50-linux-gnome/run_after_install-gnome-kimpanel-extension.sh.tmpl" \
  "$source_dir/.chezmoiscripts/70-later/run_after_later-phase.sh"

cat >"$stub_bin/codium" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode=${EXTENSION_RETRY_MODE:-success}
case "${1:-}" in
  --list-extensions)
    exit 0
    ;;
  --install-extension)
    extension=${2:?extension id is required}
    printf 'codium-install %s\n' "$extension" >>"$FIXTURE_LOG"
    [[ "$mode" != vscodium-failure ]] || exit 1
    ;;
  *)
    printf 'unexpected codium arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
STUB

cat >"$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode=${EXTENSION_RETRY_MODE:-success}
output=
url=
while (($#)); do
  case "$1" in
    -o|--output)
      output=${2:?curl output is required}
      shift 2
      ;;
    http://*|https://*|/*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$url" ]] || { printf 'curl stub did not receive a URL\n' >&2; exit 2; }

if [[ "$url" == *'extension-info/'* ]]; then
  case "$url" in
    *'pk=101'*) name=solaar; uuid=solaar@test ;;
    *'pk=102'*) name=kimpanel; uuid=kimpanel@test ;;
    *) printf 'unexpected extension-info URL: %s\n' "$url" >&2; exit 2 ;;
  esac
  printf 'gnome-query %s\n' "$name" >>"$FIXTURE_LOG"
  [[ "$mode" != "$name-query-failure" ]] || exit 22
  if [[ "$mode" == "$name-unexpected-response" ]]; then
    printf 'not-json\n'
  elif [[ "$mode" == "$name-no-compatible" ]]; then
    printf '{"uuid":"%s","shell_version_map":{}}\n' "$uuid"
  else
    printf '{"uuid":"%s","shell_version_map":{"46":{}},"download_url":"/%s.zip"}\n' "$uuid" "$name"
  fi
else
  case "$url" in
    */solaar.zip) name=solaar; uuid=solaar@test ;;
    */kimpanel.zip) name=kimpanel; uuid=kimpanel@test ;;
    *) printf 'unexpected download URL: %s\n' "$url" >&2; exit 2 ;;
  esac
  printf 'gnome-download %s\n' "$name" >>"$FIXTURE_LOG"
  [[ "$mode" != "$name-download-failure" ]] || exit 23
  [[ -n "$output" ]] || { printf 'download missing output path\n' >&2; exit 2; }
  printf '%s\n' "$uuid" >"$output"
fi
STUB

cat >"$stub_bin/gnome-extensions" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode=${EXTENSION_RETRY_MODE:-success}
case "${1:-}" in
  info)
    uuid=${2:?uuid is required}
    [[ -f "$FIXTURE_STUB_STATE/installed-$uuid" ]]
    ;;
  install)
    [[ "${2:-}" == --force ]] || { printf 'install did not receive --force\n' >&2; exit 2; }
    zip=${3:?zip is required}
    uuid=$(<"$zip")
    case "$uuid" in
      solaar@test) name=solaar ;;
      kimpanel@test) name=kimpanel ;;
      *) printf 'unexpected extension archive identity: %s\n' "$uuid" >&2; exit 2 ;;
    esac
    printf 'gnome-install %s\n' "$name" >>"$FIXTURE_LOG"
    [[ "$mode" != "$name-install-failure" ]] || exit 24
    : >"$FIXTURE_STUB_STATE/installed-$uuid"
    ;;
  *)
    printf 'unexpected gnome-extensions arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
STUB

cat >"$stub_bin/gnome-shell" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --version ]] || exit 2
printf 'GNOME Shell 46.2\n'
STUB

cat >"$stub_bin/gsettings" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode=${EXTENSION_RETRY_MODE:-success}
case "${1:-}" in
  get)
    printf 'gsettings-get\n' >>"$FIXTURE_LOG"
    [[ "$mode" != gsettings-read-warning ]] || exit 1
    if [[ "$mode" == gsettings-parse-warning ]]; then
      printf 'not-a-gvariant\n'
    elif [[ -f "$FIXTURE_STUB_STATE/enabled-extensions" ]]; then
      cat "$FIXTURE_STUB_STATE/enabled-extensions"
    else
      printf '[]\n'
    fi
    ;;
  set)
    printf 'gsettings-set\n' >>"$FIXTURE_LOG"
    [[ "$mode" != gsettings-write-warning ]] || exit 1
    printf '%s\n' "${4:?gsettings value is required}" >"$FIXTURE_STUB_STATE/enabled-extensions"
    ;;
  *)
    printf 'unexpected gsettings arguments: %s\n' "$*" >&2
    exit 2
    ;;
esac
STUB

chmod +x "$stub_bin/codium" "$stub_bin/curl" "$stub_bin/gnome-extensions" \
  "$stub_bin/gnome-shell" "$stub_bin/gsettings"

chezmoi_bin=$(type -P chezmoi)
source_digest_before=$(sha256sum "${new_templates[@]/#/$repo_root/}")
apply_stdout="$scratch/apply.stdout"
apply_stderr="$scratch/apply.stderr"

vscodium_signature="$fixture_home/.local/state/chezmoi/extension-retry/vscodium-extensions"
solaar_signature="$fixture_home/.local/state/chezmoi/extension-retry/gnome-solaar-extension"
kimpanel_signature="$fixture_home/.local/state/chezmoi/extension-retry/gnome-kimpanel-extension"

reset_fixture() {
  rm -rf -- "$destination" "$fixture_home" "$(dirname -- "$state_db")" "$cache_dir" "$stub_state" "$runtime_dir"
  mkdir -p -- "$destination" "$fixture_home" "$(dirname -- "$state_db")" "$cache_dir" "$stub_state" "$runtime_dir"
  : >"$log"
}

run_apply() {
  local mode=${1:?mode is required}
  env \
    HOME="$fixture_home" \
    XDG_STATE_HOME="$fixture_home/.local/state" \
    PATH="$stub_bin:/usr/bin:/bin" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    FIXTURE_LOG="$log" \
    FIXTURE_STUB_STATE="$stub_state" \
    EXTENSION_RETRY_MODE="$mode" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$source_dir" \
      --destination "$destination" --persistent-state "$state_db" --cache "$cache_dir" \
      --no-tty --force apply >"$apply_stdout" 2>"$apply_stderr"
}

assert_log() {
  grep -qxF -- "$1" "$log" || fail "missing log event: $1"
}
assert_apply_error() {
  grep -qF -- "$1" "$apply_stderr" || fail "missing apply diagnostic: $1"
}

assert_no_log_prefix() {
  local prefix=${1:?prefix is required} event
  while IFS= read -r event; do
    [[ "$event" != "$prefix"* ]] || fail "unexpected log event: $event"
  done <"$log"
}

assert_later_phase() {
  assert_log 'later-phase'
}

assert_safe_signature() {
  local path=${1:?signature path is required}
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || fail "missing safe signature: $path"
}

assert_no_signature() {
  local path=${1:?signature path is required}
  [[ ! -e "$path" ]] || fail "retry path retained signature: $path"
}

reset_fixture
run_apply vscodium-failure
assert_later_phase
assert_log 'codium-install fixture.vscode'
assert_no_signature "$vscodium_signature"
assert_apply_error '1 extension(s) failed; will retry on next apply'
run_apply success
assert_safe_signature "$vscodium_signature"
assert_log 'codium-install fixture.vscode'

for retry_case in \
  solaar-query-failure solaar-unexpected-response solaar-download-failure \
  kimpanel-query-failure kimpanel-unexpected-response kimpanel-download-failure; do
  name=${retry_case%%-*}
  case "$name" in
    solaar) signature=$solaar_signature ;;
    kimpanel) signature=$kimpanel_signature ;;
    *) fail "unknown retry case: $retry_case" ;;
  esac
  case "$retry_case" in
    *query-failure) expected_diagnostic='extensions.gnome.org query failed (' ;;
    *unexpected-response) expected_diagnostic='unexpected extension-info response' ;;
    *download-failure) expected_diagnostic='download failed' ;;
  esac
  reset_fixture
  run_apply "$retry_case"
  assert_later_phase
  assert_log "gnome-query $name"
  assert_apply_error "$expected_diagnostic"
  assert_no_signature "$signature"
  run_apply success
  assert_safe_signature "$signature"
  assert_log "gnome-install $name"
done

reset_fixture
run_apply solaar-no-compatible
assert_later_phase
assert_log 'gnome-query solaar'
assert_no_signature "$solaar_signature"
assert_apply_error 'no compatible build for GNOME Shell 46; will retry on next apply'
run_apply success
assert_safe_signature "$solaar_signature"
assert_log 'gnome-install solaar'

reset_fixture
run_apply success
assert_safe_signature "$vscodium_signature"
assert_safe_signature "$solaar_signature"
assert_safe_signature "$kimpanel_signature"
[[ $(<"$vscodium_signature") != $(<"$solaar_signature") ]] || fail 'VSCodium and Solaar signatures collided'
[[ $(<"$solaar_signature") != $(<"$kimpanel_signature") ]] || fail 'GNOME signatures collided'
printf '[]\n' >"$stub_state/enabled-extensions"
: >"$log"
run_apply success
assert_later_phase
assert_no_log_prefix 'codium-install '
assert_no_log_prefix 'gnome-'
[[ $(<"$stub_state/enabled-extensions") == '[]' ]] || fail 'matching signature re-enabled a user-disabled extension'

for invalid_signature in corrupt partial unsafe; do
  reset_fixture
  run_apply success
  case "$invalid_signature" in
    corrupt)
      printf 'corrupt\n' >"$vscodium_signature"
      ;;
    partial)
      printf 'vscodium-extensions-v1:' >"$vscodium_signature"
      ;;
    unsafe)
      printf 'unsafe target\n' >"$scratch/unsafe-signature-target"
      rm -f -- "$vscodium_signature"
      ln -s "$scratch/unsafe-signature-target" "$vscodium_signature"
      ;;
  esac
  : >"$log"
  run_apply success
  assert_later_phase
  assert_log 'codium-install fixture.vscode'
  assert_no_log_prefix 'gnome-'
  assert_safe_signature "$vscodium_signature"
  if [[ "$invalid_signature" == unsafe ]]; then
    [[ $(<"$scratch/unsafe-signature-target") == 'unsafe target' ]] || fail 'unsafe signature target was followed'
  fi
done

reset_fixture
run_apply success
vscodium_signature_before=$(<"$vscodium_signature")
cat >"$source_dir/.chezmoidata/vscodium.yaml" <<'YAML'
vscodium:
  extensions:
    - fixture.changed
YAML
: >"$log"
run_apply success
assert_later_phase
assert_log 'codium-install fixture.changed'
assert_no_log_prefix 'gnome-'
assert_safe_signature "$vscodium_signature"
[[ $(<"$vscodium_signature") != "$vscodium_signature_before" ]] || fail 'desired configuration did not invalidate VSCodium signature'

for warning_mode in gsettings-read-warning gsettings-parse-warning gsettings-write-warning; do
  reset_fixture
  run_apply "$warning_mode"
  assert_later_phase
  assert_log 'gnome-install solaar'
  assert_safe_signature "$solaar_signature"
  assert_safe_signature "$kimpanel_signature"
  case "$warning_mode" in
    gsettings-read-warning) expected_warning='WARNING: cannot read org.gnome.shell enabled-extensions' ;;
    gsettings-parse-warning) expected_warning='WARNING: unexpected enabled-extensions value' ;;
    gsettings-write-warning) expected_warning='WARNING: gsettings write failed' ;;
  esac
  assert_apply_error "$expected_warning"
  printf '[]\n' >"$stub_state/enabled-extensions"
  : >"$log"
  run_apply success
  assert_later_phase
  assert_no_log_prefix 'gnome-'
  [[ $(<"$stub_state/enabled-extensions") == '[]' ]] || fail "${warning_mode} convergence re-enabled a user-disabled extension"
done

reset_fixture
if run_apply solaar-install-failure; then
  fail 'gnome-extensions install failure unexpectedly succeeded'
fi
grep -qF 'HARD ERROR: gnome-extensions install --force failed for solaar@test' "$apply_stderr" \
  || fail 'gnome-extensions install failure lacked explicit hard-error diagnostic'
assert_no_signature "$solaar_signature"
assert_no_log_prefix 'later-phase'
source_digest_after=$(sha256sum "${new_templates[@]/#/$repo_root/}")
[[ "$source_digest_after" == "$source_digest_before" ]] || fail 'fixture changed repository extension sources'
printf '%s\n' 'extension retry fixture passed'
