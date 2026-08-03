#!/usr/bin/env bash
# test-wifi-import-macos.sh — hermetic runtime fixture for
# import-wifi-1password-macos: renders the tool with fixture 1Password values,
# then drives it against a FAKE profiles(1) (.ci/fixtures/wifi-secret-handoff/profiles)
# proving deployed-mode behavior, transient-profile cleanup on every exit path
# (success / command failure / interruption), and zero secret leakage into
# argv, logs, or residue. Never touches live Wi-Fi: the real profiles(1) is
# never executed (the fixture shadows it on PATH).
#
# Requires macOS: the tool parses its manifest with the real plutil +
# /usr/libexec/PlistBuddy (its production parser — not stubbed). chezmoi must
# be on PATH.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$repo_root/.ci/fixtures/wifi-secret-handoff"

fail() { printf 'wifi-import macos fixture: %s\n' "$*" >&2; exit 1; }

if [[ $(uname -s) != Darwin ]]; then
  printf '%s\n' 'wifi-import macos fixture: skipped on non-macOS host'
  exit 0
fi
command -v chezmoi >/dev/null 2>&1 || fail "chezmoi not found on PATH"
command -v plutil >/dev/null 2>&1 || fail "plutil not found"
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy not found"

scratch_parent=${TMPDIR:-/tmp}
scratch=$(mktemp -d "$scratch_parent/wifi-import-macos-test.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/bin"
printf '[data]\n' >"$scratch/empty.toml"

# op stub: deterministic per-item fixture values (see test-wifi-import-gates.sh).
cat >"$scratch/bin/op" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"KT HomeHub 5G/name"*)     printf 'fixture-ssid-home' ;;
  *"KT HomeHub 5G/password"*) printf 'fixture-psk-home' ;;
  *"CPS-01/name"*)            printf 'fixture-ssid-cps' ;;
  *"CPS-01/password"*)        printf 'fixture-psk-cps' ;;
  *)                          printf 'fixture-dummy' ;;
esac
EOF
chmod 0755 "$scratch/bin/op"

# Fake `id` reporting root, for the scenarios that exercise a REAL run
# (profiles(1) requires root on macOS 11+; the tool checks `id -u`).
cat >"$scratch/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then printf '0\n'; else printf 'uid=0(fixture) gid=0(fixture)\n'; fi
EOF
chmod 0755 "$scratch/bin/id"

# Render the deployed-mode tool (os=darwin) with fixture secrets resolved.
tool="$scratch/import-wifi-1password-macos"
env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
  chezmoi --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" --override-data '{"chezmoi":{"os":"darwin"}}' \
    execute-template \
  <"$repo_root/dot_local/bin/private_executable_import-wifi-1password-macos.sh.tmpl" \
  >"$tool"
chmod 0700 "$tool"

# Resolution proof: the rendered owner-only artifact embeds the fixture values
# (this is the render-time resolution design; the artifact itself is private_).
grep -q 'fixture-psk-home' "$tool" || fail "render did not resolve op:// password refs"
grep -q 'fixture-ssid-home' "$tool" || fail "render did not resolve op:// ssid refs"

# run_tool <label> <tool-args...> : run the tool against the fake profiles(1)
# with an isolated TMPDIR (residue scan target) and state dir. Captures rc,
# argv log, and combined output per label. Real `id` is shadowed by the root
# fixture unless WIFI_FIXTURE_REAL_ID=1 is set by the scenario.
run_tool() {
  local label=$1; shift
  mkdir -p "$scratch/tmp-$label" "$scratch/state-$label"
  : >"$scratch/log-$label"
  local path="$fixtures:$scratch/bin:/usr/bin:/bin:/usr/sbin"
  [[ ${WIFI_FIXTURE_REAL_ID:-} == 1 ]] && path="$fixtures:/usr/bin:/bin:/usr/sbin"
  set +e
  env -i HOME="$scratch/home" TMPDIR="$scratch/tmp-$label" \
    TEST_LOG="$scratch/log-$label" TEST_STATE_DIR="$scratch/state-$label" \
    PATH="$path" ${WIFI_FAKE_BLOCK:+WIFI_FAKE_BLOCK="$WIFI_FAKE_BLOCK"} \
    ${WIFI_FAKE_FAIL_STAGE:+WIFI_FAKE_FAIL_STAGE="$WIFI_FAKE_FAIL_STAGE"} \
    ${WIFI_FAKE_INSTALL_CONFLICT_ONCE:+WIFI_FAKE_INSTALL_CONFLICT_ONCE="$WIFI_FAKE_INSTALL_CONFLICT_ONCE"} \
    "$tool" "$@" >"$scratch/out-$label" 2>&1
  TOOL_RC=$?
  set -e
}

count_calls() { # count_calls <label> <verb>
  grep -c "^profiles $verb " "$scratch/log-$1" 2>/dev/null || true
}

assert_no_leak() { # assert_no_leak <label> : no fixture PSK in argv log/output,
  # and no transient residue under the scenario TMPDIR.
  local label=$1
  ! grep -q 'fixture-psk' "$scratch/log-$label" \
    || fail "$label: fixture PSK appeared on a profiles(1) command line"
  ! grep -q 'fixture-psk' "$scratch/out-$label" \
    || fail "$label: fixture PSK appeared in tool output"
  [[ -z $(find "$scratch/tmp-$label" -mindepth 1 -print -quit) ]] \
    || fail "$label: transient residue left under scenario TMPDIR"
}

assert_no_leak_global() {
  ! grep -q 'fixture-psk' "$scratch"/log-* "$scratch"/out-* \
    || fail "fixture PSK leaked into an argv log or tool output"
  [[ -z $(find "$scratch" -name 'wifi-import.*' -print -quit) ]] \
    || fail "transient wifi-import directory left behind"
  [[ -z $(find "$scratch" -name '*.mobileconfig' -print -quit) ]] \
    || fail "transient .mobileconfig left behind"
}

# --- scenario 1: dry run (deployed mode, no root, no changes) -------------
WIFI_FIXTURE_REAL_ID=1 run_tool dry --dry-run
[[ "$TOOL_RC" -eq 0 ]] || fail "dry-run exit $TOOL_RC, expected 0: $(cat "$scratch/out-dry")"
[[ "$(count_calls dry install)" -eq 0 ]] || fail "dry-run must not install"
[[ "$(count_calls dry remove)" -eq 0 ]] || fail "dry-run must not remove"
grep -q 'would install "fixture-ssid-home"' "$scratch/out-dry" \
  || fail "dry-run must plan the KT HomeHub network"
grep -q 'cannot carry DNS' "$scratch/out-dry" \
  || fail "dry-run must warn that manifest DNS is ignored on macOS"
assert_no_leak dry

# --- scenario 2: real run (deployed mode) ---------------------------------
run_tool real
[[ "$TOOL_RC" -eq 0 ]] || fail "real run exit $TOOL_RC, expected 0: $(cat "$scratch/out-real")"
[[ "$(count_calls real install)" -eq 2 ]] || fail "real run must install both networks"
[[ "$(count_calls real remove)" -eq 0 ]] || fail "real run must not remove when install succeeds"
grep -q 'installed "fixture-ssid-home"' "$scratch/out-real" \
  || fail "real run must report the install"
grep -q 'installed "fixture-ssid-cps"' "$scratch/out-real" \
  || fail "real run must report the second install"
assert_no_leak real

# --- scenario 3: declarative overwrite — stale profile conflict retried ---
WIFI_FAKE_INSTALL_CONFLICT_ONCE=1 run_tool conflict
[[ "$TOOL_RC" -eq 0 ]] || fail "conflict run exit $TOOL_RC, expected 0: $(cat "$scratch/out-conflict")"
[[ "$(count_calls conflict install)" -eq 3 ]] \
  || fail "conflict run must retry the rejected install (3 installs total)"
[[ "$(count_calls conflict remove)" -eq 1 ]] \
  || fail "conflict run must remove the stale profile once before retrying"
assert_no_leak conflict

# --- scenario 4: --force removes before installing -------------------------
run_tool force --force
[[ "$TOOL_RC" -eq 0 ]] || fail "force run exit $TOOL_RC, expected 0: $(cat "$scratch/out-force")"
[[ "$(count_calls force remove)" -eq 2 ]] || fail "force run must remove both profiles first"
[[ "$(count_calls force install)" -eq 2 ]] || fail "force run must install both profiles"
assert_no_leak force

# --- scenario 5: command failure — nonzero exit, cleanup still happens -----
WIFI_FAKE_FAIL_STAGE=install run_tool fail
[[ "$TOOL_RC" -eq 1 ]] || fail "failing run exit $TOOL_RC, expected 1"
[[ "$(count_calls fail install)" -eq 4 ]] \
  || fail "failing run must attempt install + one retry per network"
grep -q 'failed to install' "$scratch/out-fail" \
  || fail "failing run must report the failures"
assert_no_leak fail

# --- scenario 6: interruption — INT while profiles(1) is blocked ----------
mkdir -p "$scratch/tmp-int" "$scratch/state-int"
: >"$scratch/log-int"
env -i HOME="$scratch/home" TMPDIR="$scratch/tmp-int" \
  TEST_LOG="$scratch/log-int" TEST_STATE_DIR="$scratch/state-int" \
  PATH="$fixtures:$scratch/bin:/usr/bin:/bin:/usr/sbin" WIFI_FAKE_BLOCK=install \
  "$tool" >"$scratch/out-int" 2>&1 &
tool_pid=$!
deadline=$((SECONDS + 15))
until [[ -f "$scratch/state-int/blocked" || $SECONDS -ge $deadline ]]; do sleep 0.05; done
[[ -f "$scratch/state-int/blocked" ]] || fail "interruption fixture never reached the blocking install"
kill -INT "$tool_pid"
# The tool's bash defers the INT trap until the blocked profiles(1) returns;
# unblock it, then the single EXIT-trap path must run (exit 130).
: >"$scratch/state-int/unblock"
set +e
wait "$tool_pid"
TOOL_RC=$?
set -e
[[ "$TOOL_RC" -eq 130 ]] || fail "interrupted run exit $TOOL_RC, expected 130"
assert_no_leak int

# --- scenario 7: non-root real run is an environment bail ------------------
WIFI_FIXTURE_REAL_ID=1 run_tool noroot
[[ "$TOOL_RC" -eq 1 ]] || fail "non-root run exit $TOOL_RC, expected 1"
grep -q 'require root' "$scratch/out-noroot" \
  || fail "non-root run must explain the sudo requirement"
[[ "$(count_calls noroot install)" -eq 0 ]] || fail "non-root run must not install"

# --- global leak + residue scan across every scenario ----------------------
assert_no_leak_global

printf 'wifi-import macos fixture: ok\n'
