#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-kde-calendar-hard-error.sh RENDERED_SCRIPT}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/kde-calendar-hard-error-test.XXXXXX")
socket_base=${TMPDIR:-/tmp}
(( ${#socket_base} <= 40 )) || socket_base=/tmp
socket_root=$(mktemp -d "$socket_base/kdecal.XXXXXX")
trap 'rm -rf -- "$scratch" "$socket_root"' EXIT

prepare_case() {
  local name=$1 socket_state=$2
  case_dir="$scratch/$name"
  home_dir="$case_dir/home"
  fake_bin="$case_dir/bin"
  mkdir -p "$home_dir/.config/akonadi" "$fake_bin"
  for tool in kwriteconfig6 kreadconfig6; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/$tool"
    chmod 0755 "$fake_bin/$tool"
  done
  cat >"$fake_bin/mariadb" <<'EOF'
#!/usr/bin/env bash
if [[ ${KDE_MARIADB_MODE:-empty} == query-fail ]]; then
  exit 1
fi
exit 0
EOF
  chmod 0755 "$fake_bin/mariadb"
  socket="$socket_root/$name.sock"
  (( ${#socket} < 100 )) || {
    printf 'fixture socket path %s exceeds the AF_UNIX limit\n' "$socket" >&2
    exit 1
  }
  printf 'Options=UNIX_SOCKET=%s\n' "$socket" >"$home_dir/.config/akonadi/akonadiserverrc"
  if [[ "$socket_state" == socket ]]; then
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$socket"
  fi
  sed 's/^[[:space:]]*FACT_DESKTOP=.*/  FACT_DESKTOP=kde/' "$rendered" >"$case_dir/calendar.sh"
  chmod 0755 "$case_dir/calendar.sh"
}

run_case() {
  set +e
  env HOME="$home_dir" PATH="$fake_bin:$PATH" KDE_MARIADB_MODE="$1" \
    bash "$case_dir/calendar.sh" >"$case_dir/stdout" 2>"$case_dir/stderr"
  status=$?
  set -e
}

prepare_case query-failure socket
run_case query-fail
[[ $status -ne 0 ]] || { printf 'akonadi query failure unexpectedly succeeded\n' >&2; exit 1; }
grep -F 'config-kde-calendar: failed to query the Akonadi MariaDB on' "$case_dir/stderr" >/dev/null
if grep -E 'Recorded as done|not applicable|skipping' "$case_dir/stdout" "$case_dir/stderr" >/dev/null; then
  printf 'akonadi query failure emitted a skip or completion marker\n' >&2
  exit 1
fi
if compgen -G "$home_dir/.local/state/chezmoi/skips/*" >/dev/null; then
  printf 'akonadi query failure wrote a skip declaration state marker\n' >&2
  exit 1
fi

prepare_case no-collections socket
run_case empty
[[ $status -eq 0 ]]
grep -F 'no Akonadi calendar collections are configured; not applicable on this host' \
  "$case_dir/stdout" >/dev/null

prepare_case socket-absent no-socket
run_case empty
[[ $status -eq 0 ]]
grep -F 'the Akonadi socket is unavailable; calendar collection configuration is deferred' \
  "$case_dir/stdout" >/dev/null
[[ -f "$home_dir/.local/state/chezmoi/skips/config-kde-calendar__akonadi-socket-absent" ]]

if [[ -z ${KDE_CALENDAR_NESTED_RUN:-} ]]; then
  long_root="$scratch/long-runtime-root/$(printf 'r%.0s' {1..60})/$(printf 's%.0s' {1..60})"
  mkdir -p "$long_root"
  env KDE_CALENDAR_NESTED_RUN=1 XDG_RUNTIME_DIR="$long_root" "$0" "$rendered" >/dev/null
fi

printf 'config-kde-calendar hard-error boundary tests passed\n'
