#!/usr/bin/env bash
# Isolated verification for the CLIProxyAPI system-sleep hook
# (system/linux/etc/systemd/system-sleep/cli-proxy-api.sh).
#
# Exercises the hook's branch logic, record/restart pairing, and best-effort
# guarantees with stubbed loginctl/getent/systemctl binaries. Never starts the
# real user services, never runs chezmoi apply, and never touches podman —
# per the repo's non-deployment verification policy. Mirrors
# .ci/test-open-design-sleep-hook.sh; that hook and its test are untouched.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook_src="$repo_root/system/linux/etc/systemd/system-sleep/cli-proxy-api.sh"
manifest="$repo_root/.chezmoidata/system.yaml"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/cli-proxy-api-sleep-hook.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

stub_bin="$scratch/bin"
systemctl_log="$scratch/systemctl.log"
state_dir="$scratch/state"
mkdir -p -- "$stub_bin" "$state_dir"
: >"$systemctl_log"

# --- Static checks -----------------------------------------------------------
[[ -f "$hook_src" && ! -L "$hook_src" ]] || {
  printf 'cli-proxy-api sleep hook: source is missing or unsafe: %s\n' "$hook_src" >&2
  exit 1
}
[[ -s "$hook_src" ]] || {
  printf 'cli-proxy-api sleep hook: source is empty: %s\n' "$hook_src" >&2
  exit 1
}

# The manifest must install the hook mode 0755 so systemd can execute it
# (the default 0644 would make systemd silently skip it). Assert within the
# path's own list-item record, mirroring the Open Design test.
grep -qE '^[[:space:]]*- path:[[:space:]]+etc/systemd/system-sleep/cli-proxy-api\.sh$' "$manifest" || {
  printf 'cli-proxy-api sleep hook: manifest override for the hook path is missing\n' >&2
  exit 1
}
record_mode=$(awk '
  /^[[:space:]]+- path:/ {
    if (found) exit
    if ($0 ~ /system-sleep\/cli-proxy-api\.sh/) found = 1
    next
  }
  found && /^[[:space:]]*mode:/ { gsub(/[^0-9]/, "", $2); print $2; exit }
' "$manifest")
[[ "$record_mode" == "755" ]] || {
  printf 'cli-proxy-api sleep hook: manifest mode for the hook is "%s", expected 755\n' \
    "${record_mode:-<missing>}" >&2
  exit 1
}

# --- Stub binaries -----------------------------------------------------------
cat >"$stub_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
# Emulates `loginctl list-users --no-legend`. LOGINCTL_USERS overrides the
# emitted rows (UID USER ...), newline-separated for multiple users.
printf '%s\n' "${LOGINCTL_USERS:-1000 alice}"
EOF
chmod 700 "$stub_bin/loginctl"

cat >"$stub_bin/getent" <<'EOF'
#!/usr/bin/env bash
# Emulates `getent passwd <uid>` for the stub users used below.
case "$2" in
  1000) printf 'alice:x:1000:1000:alice:/home/alice:/bin/sh\n' ;;
  1001) printf 'bob:x:1001:1001:bob:/home/bob:/bin/sh\n' ;;
  999)  printf 'systemd-network:x:999:999:systemd-network:/:/usr/sbin/nologin\n' ;;
esac
EOF
chmod 700 "$stub_bin/getent"

cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# Emulates `systemctl --user -M <user>@.host <verb> ... <unit>` with a fake
# per-user active set under ACTIVE_DIR (<user> file, one unit per line).
# Records every invocation to SYSTEMCTL_LOG for assertion.
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
active_dir=${ACTIVE_DIR:?}
verb=""
unit=""
user=""
for arg in "$@"; do
  case "$arg" in
    is-active|stop|start) verb=$arg ;;
    *.service) unit=$arg ;;
    *@.host) user=${arg%@.host} ;;
  esac
done
active_file="$active_dir/$user"
touch "$active_file"
case "$verb" in
  is-active) grep -qx "$unit" "$active_file" ;;
  stop)      grep -vx "$unit" "$active_file" >"$active_file.tmp" || true; mv "$active_file.tmp" "$active_file" ;;
  start)     grep -qx "$unit" "$active_file" || printf '%s\n' "$unit" >>"$active_file" ;;
esac
EOF
chmod 700 "$stub_bin/systemctl"

export SYSTEMCTL_LOG="$systemctl_log"
export ACTIVE_DIR="$scratch/active"
mkdir -p "$ACTIVE_DIR"

# Run the hook with a controlled PATH containing only the stubs and /bin:/usr/bin.
# Arguments: <pre|post> <state> [SYSTEMD_SLEEP_ACTION]. Resets neither the log
# nor the active set — scenarios that need a clean slate do it themselves.
run_hook() {
  LOGINCTL_USERS="${LOGINCTL_USERS:-}" \
    env PATH="$stub_bin:/usr/bin:/bin" \
    CLI_PROXY_API_SLEEP_STATE_DIR="$state_dir" \
    SYSTEMD_SLEEP_ACTION="${3-}" \
    sh "$hook_src" "$1" "${2:-}" || true
}

assert_calls() {
  local verb=$1 expected=$2 label=$3
  local got
  got=$(grep -c -- "--user -M .* $verb .*\.service" "$systemctl_log" 2>/dev/null || true)
  got=${got:-0}
  if [[ "$got" -ne "$expected" ]]; then
    printf 'cli-proxy-api sleep hook: %s: expected %s %s call(s), got %s\n' \
      "$label" "$expected" "$verb" "$got" >&2
    printf 'systemctl log:\n' >&2
    cat "$systemctl_log" >&2 || true
    exit 1
  fi
}

reset_scenario() {
  : >"$systemctl_log"
  rm -f "$state_dir"/stopped-* "$ACTIVE_DIR"/* 2>/dev/null || true
  printf '%s\n' cli-proxy-api.service cpa-manager-plus.service >"$ACTIVE_DIR/alice"
  cp "$ACTIVE_DIR/alice" "$ACTIVE_DIR/bob"
}

# --- Behavioral scenarios ----------------------------------------------------

# Happy path: pre hibernate stops both units for the single human user...
reset_scenario
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
assert_calls stop 2 "pre hibernate"
# ...and post hibernate starts exactly those two units again.
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook post hibernate
assert_calls start 2 "post hibernate"

# Hybrid-sleep is also a disk-persisting state -> stop fires.
reset_scenario
LOGINCTL_USERS="1000 alice" run_hook pre hybrid-sleep
assert_calls stop 2 "pre hybrid-sleep"

# Only active units are recorded: with the panel inactive, pre stops one unit
# and post restarts exactly that one.
reset_scenario
printf '%s\n' cli-proxy-api.service >"$ACTIVE_DIR/alice"
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
assert_calls stop 1 "pre hibernate (panel inactive)"
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook post hibernate
assert_calls start 1 "post hibernate (only recorded unit)"

# Plain suspend is intentionally excluded, at both phases.
reset_scenario
LOGINCTL_USERS="1000 alice" run_hook pre suspend
assert_calls stop 0 "pre suspend"
LOGINCTL_USERS="1000 alice" run_hook post suspend
assert_calls start 0 "post suspend"

# suspend-then-hibernate double leg: the suspend leg is a no-op on both
# phases; only the hibernate leg stops, and its post restarts.
reset_scenario
LOGINCTL_USERS="1000 alice" run_hook pre suspend-then-hibernate suspend
assert_calls stop 0 "pre suspend-then-hibernate (suspend leg)"
LOGINCTL_USERS="1000 alice" run_hook post suspend-then-hibernate suspend
assert_calls start 0 "post suspend-then-hibernate (suspend leg)"
LOGINCTL_USERS="1000 alice" run_hook pre suspend-then-hibernate hibernate
assert_calls stop 2 "pre suspend-then-hibernate (hibernate leg)"
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook post suspend-then-hibernate hibernate
assert_calls start 2 "post suspend-then-hibernate (hibernate leg)"

# A repeated pre without an intervening post loses nothing (idempotency).
reset_scenario
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
assert_calls stop 0 "repeated pre (already stopped)"
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook post hibernate
assert_calls start 2 "post after repeated pre"

# Multiple human users -> per-user stop and per-user restart.
reset_scenario
LOGINCTL_USERS=$'1000 alice\n1001 bob' run_hook pre hibernate
assert_calls stop 4 "pre hibernate (two users)"
: >"$systemctl_log"
LOGINCTL_USERS=$'1000 alice\n1001 bob' run_hook post hibernate
assert_calls start 4 "post hibernate (two users)"

# System-only UIDs (< 1000) -> no human user -> no stop.
reset_scenario
LOGINCTL_USERS="999 systemd-network" run_hook pre hibernate
assert_calls stop 0 "pre hibernate (system uid only)"

# No units active -> post of a previous cycle must not start anything.
reset_scenario
: >"$ACTIVE_DIR/alice"
: >"$ACTIVE_DIR/bob"
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
assert_calls stop 0 "pre hibernate (nothing active)"
: >"$systemctl_log"
LOGINCTL_USERS="1000 alice" run_hook post hibernate
assert_calls start 0 "post hibernate (no record)"

# Missing loginctl -> hook exits 0 and stops nothing (best-effort).
reset_scenario
env PATH="/usr/bin:/bin" CLI_PROXY_API_SLEEP_STATE_DIR="$state_dir" \
  sh "$hook_src" pre hibernate
if [[ -s "$systemctl_log" ]]; then
  printf 'cli-proxy-api sleep hook: missing loginctl should stop nothing\n' >&2
  cat "$systemctl_log" >&2 || true
  exit 1
fi

printf 'cli-proxy-api sleep hook: OK\n'
