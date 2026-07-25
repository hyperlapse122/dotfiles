#!/usr/bin/env bash
# Isolated verification for the Open Design hibernate stop hook
# (system/linux/etc/systemd/system-sleep/open-design.sh).
#
# Exercises the hook's branch logic and best-effort guarantees with stubbed
# loginctl/getent/systemctl binaries. Never starts the real user service, never
# runs chezmoi apply, and never clones or builds Open Design — per the repo's
# non-deployment verification policy.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook_src="$repo_root/system/linux/etc/systemd/system-sleep/open-design.sh"
manifest="$repo_root/.chezmoidata/system.yaml"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/open-design-sleep-hook.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

stub_bin="$scratch/bin"
systemctl_log="$scratch/systemctl.log"
mkdir -p -- "$stub_bin"
: >"$systemctl_log"

# --- Static checks -----------------------------------------------------------
[[ -f "$hook_src" && ! -L "$hook_src" ]] || {
  printf 'open-design sleep hook: source is missing or unsafe: %s\n' "$hook_src" >&2
  exit 1
}
[[ -s "$hook_src" ]] || {
  printf 'open-design sleep hook: source is empty: %s\n' "$hook_src" >&2
  exit 1
}

# The manifest must install the hook mode 0755 so systemd can execute it
# (the default 0644 would make systemd silently skip it). Assert within the
# path's own list-item record so a future manifest edit cannot couple the
# assertion to line adjacency or a unique substring.
grep -qE '^[[:space:]]*- path:[[:space:]]+etc/systemd/system-sleep/open-design\.sh$' "$manifest" || {
  printf 'open-design sleep hook: manifest override for the hook path is missing\n' >&2
  exit 1
}
record_mode=$(awk '
  /^[[:space:]]+- path:/ {
    if (found) exit
    if ($0 ~ /system-sleep\/open-design\.sh/) found = 1
    next
  }
  found && /^[[:space:]]*mode:/ { gsub(/[^0-9]/, "", $2); print $2; exit }
' "$manifest")
[[ "$record_mode" == "755" ]] || {
  printf 'open-design sleep hook: manifest mode for the hook is "%s", expected 755\n' \
    "${record_mode:-<missing>}" >&2
  exit 1
}

# --- Stub binaries -----------------------------------------------------------
cat >"$stub_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
# Emulates `loginctl list-users --no-legend`. LOGINCTL_USERS overrides the
# emitted rows (UID USER ...), newline-separated for multiple users. Quoted so
# a row like "1000 alice" stays one line instead of word-splitting.
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
# Records every invocation to SYSTEMCTL_LOG for assertion.
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
EOF
chmod 700 "$stub_bin/systemctl"

export SYSTEMCTL_LOG="$systemctl_log"

# Run the hook with a controlled PATH containing only the stubs and /bin:/usr/bin
# (for sh, cut, awk, command). Resets the systemctl log before each run.
run_hook() {
  : >"$systemctl_log"
  LOGINCTL_USERS="${LOGINCTL_USERS:-}" \
    env PATH="$stub_bin:/usr/bin:/bin" \
    sh "$hook_src" "$1" "${2:-}" || true
}

assert_stop_calls() {
  local expected=$1 label=$2
  local got
  got=$(grep -c -- '--user -M .* stop open-design.service' "$systemctl_log" 2>/dev/null || true)
  got=${got:-0}
  if [[ "$got" -ne "$expected" ]]; then
    printf 'open-design sleep hook: %s: expected %s stop call(s), got %s\n' \
      "$label" "$expected" "$got" >&2
    printf 'systemctl log:\n' >&2
    cat "$systemctl_log" >&2 || true
    exit 1
  fi
}

# --- Behavioral scenarios ----------------------------------------------------

# Happy path: pre hibernate stops open-design once for the single human user.
LOGINCTL_USERS="1000 alice" run_hook pre hibernate
assert_stop_calls 1 "pre hibernate"

# Hybrid-sleep is also a disk-persisting state -> stop fires.
LOGINCTL_USERS="1000 alice" run_hook pre hybrid-sleep
assert_stop_calls 1 "pre hybrid-sleep"

# Multiple human users -> one stop per user.
LOGINCTL_USERS=$'1000 alice\n1001 bob' run_hook pre hibernate
assert_stop_calls 2 "pre hibernate (two users)"

# Plain suspend is intentionally excluded.
LOGINCTL_USERS="1000 alice" run_hook pre suspend
assert_stop_calls 0 "pre suspend"

# suspend-then-hibernate is not matched at pre time.
LOGINCTL_USERS="1000 alice" run_hook pre suspend-then-hibernate
assert_stop_calls 0 "pre suspend-then-hibernate"

# post phases never stop.
LOGINCTL_USERS="1000 alice" run_hook post hibernate
assert_stop_calls 0 "post hibernate"
LOGINCTL_USERS="1000 alice" run_hook post suspend
assert_stop_calls 0 "post suspend"

# System-only UIDs (< 1000) -> no human user -> no stop.
LOGINCTL_USERS="999 systemd-network" run_hook pre hibernate
assert_stop_calls 0 "pre hibernate (system uid only)"

# Missing loginctl -> hook exits 0 and stops nothing (best-effort, R5).
: >"$systemctl_log"
env PATH="/usr/bin:/bin" sh "$hook_src" pre hibernate
if [[ -s "$systemctl_log" ]]; then
  printf 'open-design sleep hook: missing loginctl should stop nothing\n' >&2
  cat "$systemctl_log" >&2 || true
  exit 1
fi

printf 'open-design sleep hook: OK\n'
