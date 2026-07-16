#!/bin/sh
# Launcher invariants plus rendered reconciler state-transition tests.
set -eu

root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
scratch=${XDG_RUNTIME_DIR:-${HOME}/.cache}/cli-proxy-api-service-test-$$
dummy_pid=
cleanup() {
  if [ -n "$dummy_pid" ]; then
    kill "$dummy_pid" >/dev/null 2>&1 || true
    wait "$dummy_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM
mkdir -p "$scratch"

# ---------------------------------------------------------------------------
# The private launcher must strip ambient credentials and reject unsafe state.
# ---------------------------------------------------------------------------
launcher_home=$scratch/launcher-home
launcher_auth=$launcher_home/.local/share/cli-proxy-api/auth
launcher_work=$launcher_home/.local/share/cli-proxy-api/work
launcher_current=$launcher_home/.local/share/cli-proxy-api/current
launcher_source=$launcher_home/.config/cli-proxy-api/config.yaml
launcher_config=$launcher_home/.local/share/cli-proxy-api/runtime/config.yaml
launcher_binary=$launcher_current/cli-proxy-api
mkdir -p "$launcher_auth" "$launcher_work" "$launcher_current" "$(dirname "$launcher_config")" "$(dirname "$launcher_source")"
chmod 700 "$launcher_auth" "$launcher_work" "$launcher_current"
printf 'host: "127.0.0.1"\nport: 8317\ncommercial-mode: true\n' > "$launcher_source"
chmod 444 "$launcher_source"
cp "$launcher_source" "$launcher_config"
chmod 400 "$launcher_config"
cp "$root/dot_local/libexec/private_executable_cli-proxy-api-launch" "$scratch/launcher"
chmod 700 "$scratch/launcher"
cat > "$launcher_binary" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" > "$HOME/args"
env | sort > "$HOME/environment"
EOF
chmod 700 "$launcher_binary"

CPA_HOME="$launcher_home" \
CPA_ACTIVE_BINARY="$launcher_binary" \
CPA_SOURCE_CONFIG="$launcher_source" \
CPA_CONFIG="$launcher_config" \
CPA_AUTH_DIR="$launcher_auth" \
CPA_WORK_DIR="$launcher_work" \
HOME="$scratch/ambient-home-canary" \
MANAGEMENT_PASSWORD=canary HOME_JWT=canary GITSTORE_GIT_TOKEN=canary \
OBJECTSTORE_SECRET_KEY=canary HTTPS_PROXY=canary OP_SERVICE_ACCOUNT_TOKEN=canary \
ANTHROPIC_API_KEY=canary \
PATH=${PATH:-/usr/bin:/bin} "$scratch/launcher" --

grep -qx -- '-local-model' "$launcher_home/args"
for forbidden in MANAGEMENT_PASSWORD HOME_JWT GITSTORE_GIT_TOKEN OBJECTSTORE_SECRET_KEY HTTPS_PROXY OP_SERVICE_ACCOUNT_TOKEN ANTHROPIC_API_KEY CPA_HOME CPA_ACTIVE_BINARY CPA_CONFIG CPA_AUTH_DIR CPA_WORK_DIR; do
  if grep -q "^${forbidden}=" "$launcher_home/environment"; then
    printf 'launcher leaked %s\n' "$forbidden" >&2
    exit 1
  fi
done
grep -qx 'HOME='"$launcher_home" "$launcher_home/environment"
grep -qx 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$launcher_home/environment"

assert_launcher_rejects() {
  expected=$1
  shift
  if "$@" 2> "$scratch/launcher-error"; then
    printf 'launcher accepted unsafe state: %s\n' "$expected" >&2
    exit 1
  fi
  grep -F "$expected" "$scratch/launcher-error" >/dev/null
}

mkdir -p "$scratch/poison-bin"
printf '%s\n' '#!/bin/sh' 'exit 99' > "$scratch/poison-bin/id"
chmod 700 "$scratch/poison-bin/id"
run_launcher() {
  env \
    "PATH=$scratch/poison-bin" "HOME=$scratch/ambient-home-canary" \
    "CPA_HOME=$launcher_home" "CPA_ACTIVE_BINARY=$launcher_binary" \
    "CPA_SOURCE_CONFIG=$launcher_source" "CPA_CONFIG=$launcher_config" "CPA_AUTH_DIR=$launcher_auth" \
    "CPA_WORK_DIR=$launcher_work" "$scratch/launcher" --
}

printf 'forbidden\n' > "$launcher_work/.env"
assert_launcher_rejects 'forbidden .env' run_launcher
rm -f "$launcher_work/.env"

printf 'credential\n' > "$launcher_auth/residue"
assert_launcher_rejects 'auth directory is not empty' run_launcher
rm -f "$launcher_auth/residue"

printf 'credential\n' > "$launcher_auth/.hidden-residue"
assert_launcher_rejects 'auth directory is not empty' run_launcher
rm -f "$launcher_auth/.hidden-residue"

chmod 755 "$launcher_auth"
assert_launcher_rejects 'auth directory mode must be 0700' run_launcher
chmod 700 "$launcher_auth"

chmod 755 "$launcher_work"
assert_launcher_rejects 'working directory mode must be 0700' run_launcher
chmod 700 "$launcher_work"

mv "$launcher_auth" "$launcher_auth.real"
ln -s "$launcher_auth.real" "$launcher_auth"
assert_launcher_rejects 'auth directory must not be a symlink' run_launcher
rm "$launcher_auth"
mv "$launcher_auth.real" "$launcher_auth"

mv "$launcher_binary" "$launcher_binary.real"
ln -s "$launcher_binary.real" "$launcher_binary"
assert_launcher_rejects 'active binary must not be a symlink' run_launcher
rm "$launcher_binary"
mv "$launcher_binary.real" "$launcher_binary"

chmod 644 "$launcher_config"
assert_launcher_rejects 'runtime config mode must be 0400' run_launcher
chmod 600 "$launcher_config"
assert_launcher_rejects 'runtime config mode must be 0400' run_launcher
if ! env \
  "PATH=$scratch/poison-bin" "HOME=$scratch/ambient-home-canary" \
  "CPA_HOME=$launcher_home" "CPA_ACTIVE_BINARY=$launcher_binary" \
  "CPA_SOURCE_CONFIG=$launcher_source" "CPA_CONFIG=$launcher_config" \
  "CPA_BOOTSTRAP=1" "CPA_AUTH_DIR=$launcher_auth" "CPA_WORK_DIR=$launcher_work" \
  "$scratch/launcher" --; then
  printf 'launcher rejected an explicitly bootstrapped runtime config\n' >&2
  exit 1
fi
chmod 400 "$launcher_config"
mv "$launcher_config" "$launcher_config.real"
ln -s "$launcher_config.real" "$launcher_config"
assert_launcher_rejects 'config is not a regular file' run_launcher
rm "$launcher_config"
mv "$launcher_config.real" "$launcher_config"
chmod 400 "$launcher_config"

mv "$launcher_work" "$launcher_work.real"
ln -s "$launcher_work.real" "$launcher_work"
assert_launcher_rejects 'working directory must not be a symlink' run_launcher
rm "$launcher_work"
mv "$launcher_work.real" "$launcher_work"

if [ "${CPA_TEST_OWNER_TEST:-0}" = 1 ]; then
  launcher_uid=$(id -u)
  foreign_uid=0
  [ "$launcher_uid" -ne 0 ] || foreign_uid=1
  /usr/bin/sudo chown "$foreign_uid" "$launcher_auth"
  assert_launcher_rejects 'auth directory owner mismatch' run_launcher
  /usr/bin/sudo chown "$launcher_uid" "$launcher_auth"
fi

rmdir "$launcher_work/tmp"
mkdir -m 700 "$scratch/real-tmp"
ln -s "$scratch/real-tmp" "$launcher_work/tmp"
assert_launcher_rejects 'temporary directory must not be a symlink' run_launcher

# A rendered reconciler path + platform activates deterministic manager tests.
rendered_reconciler=${1:-}
platform=${2:-}
if [ -z "$rendered_reconciler" ]; then
  printf 'cli-proxy-api launcher tests passed\n'
  exit 0
fi
[ -f "$rendered_reconciler" ]
case $platform in linux|darwin) ;; *) printf 'platform must be linux or darwin\n' >&2; exit 1 ;; esac

# ---------------------------------------------------------------------------
# Reconciler: success, extracted-binary integrity, binary-only rollback,
# fail-stop, and failed rollback. Official archive provenance is covered by the
# deterministic resolver; these fake binaries exercise local manifest pinning.
# ---------------------------------------------------------------------------
old_binary_fixture=$scratch/old-binary
printf '%s\n' '#!/bin/sh' '# deterministic verified fixture' 'exit 0' > "$old_binary_fixture"
chmod 500 "$old_binary_fixture"

service_home=$scratch/service-home
stub_bin=$scratch/stub-bin
mkdir -p "$service_home/.config/cli-proxy-api" "$service_home/.local/libexec" \
  "$service_home/.local/share/cli-proxy-api/versions" "$service_home/.local/bin" "$stub_bin"
chmod 700 "$service_home/.local/share/cli-proxy-api" "$service_home/.local/share/cli-proxy-api/versions"
cp "$root/dot_config/cli-proxy-api/readonly_config.yaml" "$service_home/.config/cli-proxy-api/config.yaml"
chmod 444 "$service_home/.config/cli-proxy-api/config.yaml"
management_secret=synthetic-management-key-0123456789abcdef
management_source=$scratch/management-config.yaml
sed 's/secret-key: ""/secret-key: "$2b$12$fixture-management-hash"/' \
  "$service_home/.config/cli-proxy-api/config.yaml" > "$management_source"
chmod 444 "$management_source"
mkdir -p "$service_home/.local/share/cli-proxy-api/runtime"
cp "$service_home/.config/cli-proxy-api/config.yaml" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
cp "$root/dot_local/libexec/private_executable_cli-proxy-api-launch" "$service_home/.local/libexec/cli-proxy-api-launch"
chmod 700 "$service_home/.local/libexec/cli-proxy-api-launch"
if [ "$platform" = linux ]; then
  mkdir -p "$service_home/.config/systemd/user"
  cp "$root/dot_config/systemd/user/readonly_cli-proxy-api.service" "$service_home/.config/systemd/user/cli-proxy-api.service"
  chmod 444 "$service_home/.config/systemd/user/cli-proxy-api.service"
else
  mkdir -p "$service_home/Library/LaunchAgents"
  cp "$root/Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl" "$service_home/Library/LaunchAgents/dev.h82.cli-proxy-api.plist"
  chmod 444 "$service_home/Library/LaunchAgents/dev.h82.cli-proxy-api.plist"
fi

real_jq=$(command -v jq)
sed \
  -e "s|^PATH=.*|PATH=$stub_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin|" \
  -e "s|^CPA_HOME=.*|CPA_HOME=\"$service_home\"|" \
  -e "s|^CPA_JQ=.*|CPA_JQ=\"$real_jq\"|" \
  -e 's|^CPA_TEST_ADAPTER=.*|CPA_TEST_ADAPTER=1|' \
  "$rendered_reconciler" > "$scratch/reconciler-fixture"
chmod 700 "$scratch/reconciler-fixture"
rendered_reconciler=$scratch/reconciler-fixture

release_id=$(awk -F= '$1 == "CPA_RELEASE_ID" { gsub(/^"|"$/, "", $2); print $2; exit }' "$rendered_reconciler")
[ -n "$release_id" ]
old_dir=$service_home/.local/share/cli-proxy-api/versions/$release_id
mkdir -p "$old_dir"
cp "$old_binary_fixture" "$old_dir/cli-proxy-api"
chmod 500 "$old_dir/cli-proxy-api"

# Keep one orphaned real PID alive; manager/lsof adapters report it
# deterministically, and the OS can reap it during forced-stop tests.
dummy_pid=$(/bin/sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
export CPA_TEST_PID="$dummy_pid" CPA_TEST_HOME="$service_home" \
  CPA_TEST_LOG="$scratch/manager.log" CPA_TEST_STATE="$scratch/manager.state" \
  CPA_TEST_EXECUTABLE_DIR="$old_dir"
printf '0\n' > "$CPA_TEST_STATE"

cat > "$stub_bin/op" <<'EOF'
#!/bin/sh
set -eu
[ "${1-}" = read ] || exit 1
case ${CPA_TEST_OP_MODE:-valid} in
  missing|unreadable) exit 1 ;;
  malformed) printf short ;;
  *) printf '%s' "$CPA_TEST_MANAGEMENT_SECRET" ;;
esac
EOF
chmod 700 "$stub_bin/op"

cat > "$stub_bin/lsof" <<'EOF'
#!/bin/sh
set -eu
current=$(readlink "$CPA_TEST_HOME/.local/share/cli-proxy-api/current" 2>/dev/null || printf '%s' "$CPA_TEST_EXECUTABLE_DIR")
active=$(cat "$CPA_TEST_STATE")
[ "${CPA_TEST_LOADED_NO_PID:-0}" != 1 ] || active=0
case " $* " in
  *' -Fn '*)
    [ "$active" = 1 ] || exit 0
    executable=$current/cli-proxy-api
    [ "${CPA_TEST_LISTENER_SCENARIO:-}" != wrong-executable ] || executable=$current/not-the-candidate
    printf 'p%s\nftxt\nn%s\n' "$CPA_TEST_PID" "$executable"
    ;;
  *)
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    [ "$active" = 1 ] || exit 0
    [ "${CPA_TEST_LISTENER_SCENARIO:-}" != missing ] || exit 0
    endpoint=127.0.0.1:8317
    listener_pid=$CPA_TEST_PID
    [ "${CPA_TEST_LISTENER_SCENARIO:-}" != wrong-pid ] || listener_pid=999999
    [ "${CPA_TEST_LISTENER_SCENARIO:-}" != non-loopback ] || endpoint='*:8317'
    printf 'cpa %s user 3u IPv4 0x1 0t0 TCP %s\n' "$listener_pid" "$endpoint"
    if [ "${CPA_TEST_LISTENER_SCENARIO:-}" = multiple ]; then
      printf 'cpa %s user 4u IPv6 0x2 0t0 TCP [::1]:8317\n' "$listener_pid"
    fi
    ;;
esac
EOF
chmod 700 "$stub_bin/lsof"

cat > "$stub_bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=
url=
request_data=
config_file=
authenticated=0
while [ "$#" -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -K|--config) config_file=$2; shift 2 ;;
    --data) request_data=$2; shift 2 ;;
    -w|-H|--max-time|--noproxy) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ]
if [ -n "$config_file" ] && grep -q '^header = "Authorization: Bearer ' "$config_file"; then
  authenticated=1
  management_header_value=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "$config_file")
  if [ -n "${CPA_TEST_EXPECTED_MANAGEMENT_SECRET:-}" ] &&
     [ "$management_header_value" != "$CPA_TEST_EXPECTED_MANAGEMENT_SECRET" ]; then
    authenticated=2
  fi
fi
[ "${CPA_TEST_CURL_SCENARIO:-}" != transport-failure ] || exit 7
current=$(readlink "$CPA_TEST_HOME/.local/share/cli-proxy-api/current")
if [ "${CPA_TEST_SIGNAL_STAGE:-}" = foreground ]; then
  case $url in */healthz) kill -TERM "$PPID"; exit 7 ;; esac
fi
if [ "${CPA_TEST_SIGNAL_STAGE:-}" = smoke-header ] && [ "$authenticated" = 1 ]; then
  kill -TERM "$PPID"
  exit 7
fi
if [ "${CPA_TEST_CURL_SCENARIO:-}" = listener-handoff ]; then
  case $url in */healthz) printf '0\n' > "$CPA_TEST_STATE" ;; esac
fi
if [ "${CPA_TEST_MUTATE_CONFIG:-0}" = 1 ] && [ ! -e "$CPA_TEST_STATE.config-mutated" ]; then
  chmod 644 "$CPA_TEST_HOME/.local/share/cli-proxy-api/runtime/config.yaml"
  printf '# startup mutation\n' >> "$CPA_TEST_HOME/.local/share/cli-proxy-api/runtime/config.yaml"
  chmod 444 "$CPA_TEST_HOME/.local/share/cli-proxy-api/runtime/config.yaml"
  : > "$CPA_TEST_STATE.config-mutated"
fi
if [ -n "${CPA_TEST_MUTATE_PRIOR:-}" ] && [ ! -e "$CPA_TEST_STATE.prior-mutated" ]; then
  chmod 700 "$CPA_TEST_MUTATE_PRIOR"
  printf '# rollback mutation\n' >> "$CPA_TEST_MUTATE_PRIOR"
  chmod 500 "$CPA_TEST_MUTATE_PRIOR"
  : > "$CPA_TEST_STATE.prior-mutated"
fi
if [ "${CPA_TEST_MUTATE_BINARY:-0}" = 1 ] && [ ! -e "$CPA_TEST_STATE.binary-mutated" ]; then
  chmod 700 "$current/cli-proxy-api"
  printf '# startup mutation\n' >> "$current/cli-proxy-api"
  chmod 500 "$current/cli-proxy-api"
  : > "$CPA_TEST_STATE.binary-mutated"
fi
if [ "${CPA_TEST_LOG_REQUEST:-0}" = 1 ] && [ -n "$request_data" ]; then
  printf '%s\n' "$request_data" >> "$CPA_TEST_HOME/.local/share/cli-proxy-api/work/supervisor.log"
fi
status=200
body='{"status":"ok"}'
case $url in
  */v1beta/interactions)
    if [ "${CPA_TEST_FAIL_ALL:-0}" = 1 ] || { [ -n "${CPA_TEST_BAD_ID:-}" ] && [ "$(basename "$current")" = "$CPA_TEST_BAD_ID" ]; }; then
      status=500
      body='{"error":{"type":"server_error","code":"unexpected","message":"fixture failure"}}'
    else
      status=503
      body='{"error":{"type":"server_error","code":"internal_server_error","message":"no auth available"}}'
    fi
    ;;
  */v0/management/config)
    if [ "${CPA_TEST_MANAGEMENT_ENABLED:-0}" != 1 ]; then
      status=404
      body='not found'
    elif [ "$authenticated" = 1 ]; then
      status=200
      body='{}'
    else
      status=401
      body='{"error":"missing management key"}'
    fi
    ;;
  */management.html|*/v0/resource/plugins/example)
    status=404
    body='not found'
    ;;
esac
case ${CPA_TEST_CURL_SCENARIO:-} in
  health-redirect)
    case $url in */healthz) status=302; body='<html>redirect</html>' ;; esac
    ;;
  health-malformed)
    case $url in */healthz) status=200; body='not-json' ;; esac
    ;;
  provider-unauthorized)
    case $url in */v1beta/interactions) status=401; body='{"error":{"message":"unauthorized"}}' ;; esac
    ;;
  provider-malformed)
    case $url in */v1beta/interactions) status=503; body='not-json' ;; esac
    ;;
  optional-enabled)
    case $url in */v0/management/config|*/management.html|*/v0/resource/plugins/example) status=200; body='{}' ;; esac
    ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$status"
EOF
chmod 700 "$stub_bin/curl"

cat > "$stub_bin/systemctl" <<'EOF'
#!/bin/sh
set -eu
printf 'systemctl %s\n' "$*" >> "$CPA_TEST_LOG"
case " $* " in
  *' show '*)
    [ "$(cat "$CPA_TEST_STATE")" = 1 ] && printf '%s\n' "$CPA_TEST_PID" || printf '0\n'
    ;;
  *' disable '*|*' stop '*)
    [ "${CPA_TEST_STOP_FAIL:-0}" != 1 ] || exit 1
    printf '0\n' > "$CPA_TEST_STATE"
    ;;
  *' daemon-reload '*) [ "${CPA_TEST_FAIL_COMMAND:-}" != daemon-reload ] ;;
  *' reset-failed '*) [ "${CPA_TEST_FAIL_COMMAND:-}" != reset-failed ] ;;
  *' enable '*) [ "${CPA_TEST_FAIL_COMMAND:-}" != enable ] ;;
  *' restart '*)
    [ "${CPA_TEST_MANAGER_FAIL:-0}" != 1 ] || exit 1
    [ "${CPA_TEST_FAIL_COMMAND:-}" != restart ] || exit 1
    printf '1\n' > "$CPA_TEST_STATE"
    [ "${CPA_TEST_SIGNAL_STAGE:-}" != supervisor ] || { kill -TERM "$PPID"; exit 1; }
    ;;
  *) : ;;
esac
EOF
chmod 700 "$stub_bin/systemctl"

cat > "$stub_bin/launchctl" <<'EOF'
#!/bin/sh
set -eu
printf 'launchctl %s\n' "$*" >> "$CPA_TEST_LOG"
case " $* " in
  *' print '*)
    [ "$(cat "$CPA_TEST_STATE")" = 1 ] || exit 1
    if [ "${CPA_TEST_LOADED_NO_PID:-0}" = 1 ]; then
      printf '    state = waiting\n'
    else
      printf '    pid = %s\n' "$CPA_TEST_PID"
    fi
    ;;
  *' bootout '*|*' disable '*)
    [ "${CPA_TEST_STOP_FAIL:-0}" != 1 ] || exit 1
    [ "${CPA_TEST_LOADED_NO_PID:-0}" != 1 ] || exit 1
    printf '0\n' > "$CPA_TEST_STATE"
    ;;
  *' enable '*) [ "${CPA_TEST_FAIL_COMMAND:-}" != enable ] ;;
  *' bootstrap '*)
    [ "${CPA_TEST_MANAGER_FAIL:-0}" != 1 ] || exit 1
    [ "${CPA_TEST_FAIL_COMMAND:-}" != bootstrap ] || exit 1
    printf '1\n' > "$CPA_TEST_STATE"
    ;;
  *' kickstart '*)
    [ "${CPA_TEST_FAIL_COMMAND:-}" != kickstart ] || exit 1
    printf '1\n' > "$CPA_TEST_STATE"
    [ "${CPA_TEST_SIGNAL_STAGE:-}" != supervisor ] || { kill -TERM "$PPID"; exit 1; }
    ;;
  *) : ;;
esac
EOF
chmod 700 "$stub_bin/launchctl"

run_reconciler() {
  script=$1
  shift
  env "HOME=$service_home" "PATH=$stub_bin:$PATH" \
    "CPA_TEST_PID=$CPA_TEST_PID" "CPA_TEST_HOME=$CPA_TEST_HOME" \
    "CPA_TEST_LOG=$CPA_TEST_LOG" "CPA_TEST_STATE=$CPA_TEST_STATE" \
    "$@" /bin/sh "$script"
}

chmod 777 "$service_home/.local/bin"
if run_reconciler "$rendered_reconciler"; then
  printf 'world-writable binary directory unexpectedly passed\n' >&2
  exit 1
fi
chmod 755 "$service_home/.local/bin"
chmod 644 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
if run_reconciler "$rendered_reconciler"; then
  printf 'writable managed config unexpectedly passed\n' >&2
  exit 1
fi
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
printf 'preserve current collision\n' > "$service_home/.local/share/cli-proxy-api/current"
if run_reconciler "$rendered_reconciler"; then
  printf 'regular current collision unexpectedly passed\n' >&2
  exit 1
fi
grep -qx 'preserve current collision' "$service_home/.local/share/cli-proxy-api/current"
rm -f "$service_home/.local/share/cli-proxy-api/current"
printf 'preserve binary collision\n' > "$service_home/.local/bin/cli-proxy-api"
if run_reconciler "$rendered_reconciler"; then
  printf 'regular binary collision unexpectedly passed\n' >&2
  exit 1
fi
grep -qx 'preserve binary collision' "$service_home/.local/bin/cli-proxy-api"
rm -f "$service_home/.local/bin/cli-proxy-api"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$stub_bin/sha256sum"
chmod 700 "$stub_bin/sha256sum"
if run_reconciler "$rendered_reconciler"; then
  printf 'failed hash utility unexpectedly passed\n' >&2
  exit 1
fi
rm -f "$stub_bin/sha256sum"
# The failed hash preflight removes the runtime copy; restore a locked fixture
# before exercising the healthy no-op path below.
mkdir -p "$service_home/.local/share/cli-proxy-api/runtime"
chmod 600 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" 2>/dev/null || true
cp "$service_home/.config/cli-proxy-api/config.yaml" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"

smoke_sentinel=$scratch/must-not-delete
mkdir -p "$smoke_sentinel"
printf 'keep\n' > "$smoke_sentinel/sentinel"
: > "$CPA_TEST_LOG"
run_reconciler "$rendered_reconciler" "CPA_SMOKE_TMP=$smoke_sentinel"
[ -f "$smoke_sentinel/sentinel" ]
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
grep -qx "release_id=$release_id" "$service_home/.local/share/cli-proxy-api/last-known-good"

# Management-enabled deterministic runs use the real reconciler secret path and
# a stub op binary while retaining the existing manager/lsof/curl adapters.
chmod 600 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
cp "$management_source" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
: > "$CPA_TEST_LOG"
run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
  CPA_TEST_OP="$stub_bin/op"
management_manifest=$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")
: > "$CPA_TEST_LOG"
run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
  CPA_TEST_OP="$stub_bin/op"
if grep -Eq ' disable | restart | bootstrap ' "$CPA_TEST_LOG"; then
  printf 'unchanged management apply restarted service\n' >&2
  exit 1
fi
[ "$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")" = "$management_manifest" ]

# A newly-created plaintext runtime config is removed when hash validation fails
# before the transaction trap is active.
rm -f "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
if run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
  CPA_TEST_OP="$stub_bin/op"; then
  printf 'plaintext bootstrap failure unexpectedly passed\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" ]

# Restore a locked bcrypt fixture for the remaining management-aware smoke test.
cp "$management_source" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
  CPA_TEST_OP="$stub_bin/op"

for op_mode in missing malformed unreadable; do
  : > "$CPA_TEST_LOG"
  if run_reconciler "$rendered_reconciler" \
    CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
    CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
    CPA_TEST_OP_MODE="$op_mode" CPA_TEST_OP="$stub_bin/op"; then
    printf 'invalid credential mode unexpectedly passed: %s\n' "$op_mode" >&2
    exit 1
  fi
  [ "$(cat "$CPA_TEST_STATE")" = 0 ]
  [ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
  [ ! -e "$service_home/.local/bin/cli-proxy-api" ]
  rm -f "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
  cp "$management_source" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
  chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
  run_reconciler "$rendered_reconciler" \
    CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
    CPA_TEST_MANAGEMENT_SECRET="$management_secret" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret" \
    CPA_TEST_OP="$stub_bin/op"
done

# Rotation changes both the runtime hash and the manifest credential digest.
management_secret_rotated=synthetic-management-key-rotated-0123456789abcdef
management_source_rotated=$scratch/management-config-rotated.yaml
sed 's/fixture-management-hash/rotated-management-hash/' "$management_source" > "$management_source_rotated"
chmod 444 "$management_source_rotated"
old_management_manifest=$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")
chmod 600 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
cp "$management_source_rotated" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret_rotated" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret_rotated" \
  CPA_TEST_OP="$stub_bin/op"
[ "$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")" != "$old_management_manifest" ]

# A failed candidate may roll back with an unchanged credential, but not after
# the credential rotates.
management_bad_id=v7.2.82-cccccccccccc
management_bad_dir=$service_home/.local/share/cli-proxy-api/versions/$management_bad_id
mkdir -p "$management_bad_dir"
printf '%s\n' '#!/bin/sh' '# management rollback fixture' 'exit 0' > "$management_bad_dir/cli-proxy-api"
chmod 500 "$management_bad_dir/cli-proxy-api"
sed \
  -e 's/^CPA_RELEASE_TAG=.*/CPA_RELEASE_TAG="v7.2.82"/' \
  -e 's/^CPA_RELEASE_ASSET=.*/CPA_RELEASE_ASSET="CLIProxyAPI_7.2.82_linux_amd64.tar.gz"/' \
  -e 's/^CPA_RELEASE_SHA256=.*/CPA_RELEASE_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"/' \
  -e "s/^CPA_RELEASE_ID=.*/CPA_RELEASE_ID=\"$management_bad_id\"/" \
  "$rendered_reconciler" > "$scratch/management-bad-reconciler"
chmod 700 "$scratch/management-bad-reconciler"
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/management-bad-reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 CPA_TEST_BAD_ID="$management_bad_id" \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret_rotated" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret_rotated" \
  CPA_TEST_OP="$stub_bin/op"; then
  printf 'management binary-only rollback fixture unexpectedly passed\n' >&2
  exit 1
fi
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
[ "$(cat "$CPA_TEST_STATE")" = 1 ]
[ "$(grep -Ec 'restart|bootstrap' "$CPA_TEST_LOG")" -eq 1 ]

# New credential + failed candidate must not restart the old credentialed service.
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/management-bad-reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 CPA_TEST_BAD_ID="$management_bad_id" \
  CPA_TEST_MANAGEMENT_SECRET=synthetic-management-key-new-0123456789abcdef \
  CPA_TEST_EXPECTED_MANAGEMENT_SECRET=synthetic-management-key-new-0123456789abcdef \
  CPA_TEST_OP="$stub_bin/op"; then
  printf 'credential-changed rollback fixture unexpectedly passed\n' >&2
  exit 1
fi
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
[ "$(cat "$CPA_TEST_STATE")" = 0 ]
[ "$(grep -Ec 'restart|bootstrap' "$CPA_TEST_LOG")" -eq 0 ]

# Restore the rotated locked runtime and prove the healthy path remains usable.
cp "$management_source_rotated" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
run_reconciler "$rendered_reconciler" \
  CPA_TEST_MANAGEMENT=1 CPA_TEST_MANAGEMENT_ENABLED=1 \
  CPA_TEST_MANAGEMENT_SECRET="$management_secret_rotated" CPA_TEST_EXPECTED_MANAGEMENT_SECRET="$management_secret_rotated" \
  CPA_TEST_OP="$stub_bin/op"

if command -v sha256sum >/dev/null 2>&1; then
  smoke_config_sha=$(sha256sum "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" | awk '{print $1}')
  smoke_source_sha=$(sha256sum "$service_home/.config/cli-proxy-api/config.yaml" | awk '{print $1}')
else
  smoke_config_sha=$(shasum -a 256 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" | awk '{print $1}')
  smoke_source_sha=$(shasum -a 256 "$service_home/.config/cli-proxy-api/config.yaml" | awk '{print $1}')
fi
env \
  PATH="$stub_bin:$PATH" \
  CPA_MANAGEMENT_ENABLED=1 CPA_TEST_MANAGEMENT_ENABLED=1 CPA_MANAGEMENT_SECRET=synthetic-management-key-0123456789abcdef \
  CPA_SOURCE_CONFIG="$service_home/.config/cli-proxy-api/config.yaml" \
  CPA_CONFIG="$service_home/.local/share/cli-proxy-api/runtime/config.yaml" \
  CPA_AUTH_DIR="$service_home/.local/share/cli-proxy-api/auth" \
  CPA_WORK_DIR="$service_home/.local/share/cli-proxy-api/work" \
  CPA_ACTIVE_BINARY="$old_dir/cli-proxy-api" CPA_JQ="$real_jq" \
  CPA_EXPECTED_CONFIG_SHA256="$smoke_config_sha" CPA_EXPECTED_SOURCE_CONFIG_SHA256="$smoke_source_sha" \
  CPA_LOG_FILE="$service_home/.local/share/cli-proxy-api/work/supervisor.log" \
  CPA_TEST_PID="$CPA_TEST_PID" CPA_TEST_HOME="$CPA_TEST_HOME" CPA_TEST_STATE="$CPA_TEST_STATE" \
  CPA_SMOKE_MAX_ATTEMPTS=1 /bin/sh -c 'export CPA_MANAGEMENT_ENABLED=1; . "$1"; cpa_smoke "$2"' sh "$root/.ci/smoke-cli-proxy-api.sh" "$CPA_TEST_PID"
assert_smoke_rejects() {
  scenario_type=$1
  scenario=$2
  printf '1\n' > "$CPA_TEST_STATE"
  if env \
    "PATH=$stub_bin:$PATH" "CPA_TEST_PID=$CPA_TEST_PID" \
    "CPA_TEST_HOME=$CPA_TEST_HOME" "CPA_TEST_STATE=$CPA_TEST_STATE" \
    "CPA_ACTIVE_BINARY=$old_dir/cli-proxy-api" \
    "CPA_SOURCE_CONFIG=$service_home/.config/cli-proxy-api/config.yaml" \
    "CPA_CONFIG=$service_home/.local/share/cli-proxy-api/runtime/config.yaml" \
    "CPA_AUTH_DIR=$service_home/.local/share/cli-proxy-api/auth" \
    "CPA_WORK_DIR=$service_home/.local/share/cli-proxy-api/work" \
    "CPA_JQ=$real_jq" "CPA_EXPECTED_CONFIG_SHA256=$smoke_config_sha" \
    "CPA_LOG_FILE=$service_home/.local/share/cli-proxy-api/work/supervisor.log" \
    "CPA_SMOKE_MAX_ATTEMPTS=1" "$scenario_type=$scenario" \
    /bin/sh -c '. "$1"; cpa_smoke "$2"' sh "$root/.ci/smoke-cli-proxy-api.sh" "$CPA_TEST_PID"; then
    printf 'unsafe smoke scenario unexpectedly passed: %s=%s\n' "$scenario_type" "$scenario" >&2
    exit 1
  fi
  printf '0\n' > "$CPA_TEST_STATE"
}
for scenario in missing wrong-pid non-loopback multiple wrong-executable; do
  assert_smoke_rejects CPA_TEST_LISTENER_SCENARIO "$scenario"
done
for scenario in transport-failure health-redirect health-malformed provider-unauthorized provider-malformed optional-enabled listener-handoff; do
  assert_smoke_rejects CPA_TEST_CURL_SCENARIO "$scenario"
done

# An interruption after the authenticated header is created must remove that
# file before the smoke verifier exits.
if env \
  PATH="$stub_bin:$PATH" CPA_TEST_PID="$CPA_TEST_PID" CPA_TEST_HOME="$CPA_TEST_HOME" \
  CPA_TEST_STATE="$CPA_TEST_STATE" CPA_TEST_SIGNAL_STAGE=smoke-header \
  CPA_TEST_MANAGEMENT_ENABLED=1 CPA_MANAGEMENT_ENABLED=1 \
  CPA_MANAGEMENT_SECRET="$management_secret" CPA_ACTIVE_BINARY="$old_dir/cli-proxy-api" \
  CPA_SOURCE_CONFIG="$service_home/.config/cli-proxy-api/config.yaml" \
  CPA_CONFIG="$service_home/.local/share/cli-proxy-api/runtime/config.yaml" \
  CPA_AUTH_DIR="$service_home/.local/share/cli-proxy-api/auth" \
  CPA_WORK_DIR="$service_home/.local/share/cli-proxy-api/work" CPA_JQ="$real_jq" \
  CPA_EXPECTED_CONFIG_SHA256="$smoke_config_sha" CPA_LOG_FILE="$service_home/.local/share/cli-proxy-api/work/supervisor.log" \
  CPA_SMOKE_MAX_ATTEMPTS=1 /bin/sh -c '. "$1"; cpa_smoke "$2"' sh "$root/.ci/smoke-cli-proxy-api.sh" "$CPA_TEST_PID"; then
  printf 'interrupted authenticated smoke unexpectedly passed\n' >&2
  exit 1
fi
if find "$service_home/.local/share/cli-proxy-api/work" -name management-header.conf -print -quit | grep -q .; then
  printf 'management header survived interrupted smoke\n' >&2
  exit 1
fi
printf 'credential residue\n' > "$service_home/.local/share/cli-proxy-api/auth/residue"
assert_smoke_rejects CPA_TEST_STATE_SCENARIO auth-residue
rm -f "$service_home/.local/share/cli-proxy-api/auth/residue"
mkdir -p "$service_home/.config/cli-proxy-api/static"
printf 'panel\n' > "$service_home/.config/cli-proxy-api/static/management.html"
assert_smoke_rejects CPA_TEST_STATE_SCENARIO panel-artifact
rm -rf "$service_home/.config/cli-proxy-api/static"
mkdir -p "$service_home/.local/share/cli-proxy-api/work/plugins"
assert_smoke_rejects CPA_TEST_STATE_SCENARIO plugin-artifact
rm -rf "$service_home/.local/share/cli-proxy-api/work/plugins"

: > "$CPA_TEST_LOG"
if run_reconciler "$rendered_reconciler" CPA_TEST_MUTATE_CONFIG=1; then
  printf 'startup config mutation unexpectedly passed\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" ]
grep -qx 'commercial-mode: true' "$service_home/.config/cli-proxy-api/config.yaml"
mkdir -p "$service_home/.local/share/cli-proxy-api/runtime"
cp "$service_home/.config/cli-proxy-api/config.yaml" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 644 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
rm -f "$CPA_TEST_STATE.config-mutated"

: > "$CPA_TEST_LOG"
if run_reconciler "$rendered_reconciler" CPA_TEST_MUTATE_BINARY=1; then
  printf 'readiness-time binary mutation unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'startup mutation' "$old_dir/cli-proxy-api"
chmod 700 "$old_dir/cli-proxy-api"
cp "$old_binary_fixture" "$old_dir/cli-proxy-api"
chmod 500 "$old_dir/cli-proxy-api"
rm -f "$CPA_TEST_STATE.binary-mutated"

: > "$CPA_TEST_LOG"
if run_reconciler "$rendered_reconciler" CPA_TEST_LOG_REQUEST=1; then
  printf 'request-body supervisor logging unexpectedly passed\n' >&2
  exit 1
fi

for signal_stage in foreground supervisor; do
  : > "$CPA_TEST_LOG"
  if run_reconciler "$rendered_reconciler" "CPA_TEST_SIGNAL_STAGE=$signal_stage" CPA_TEST_FORCE_RECONCILE=1; then
    printf 'interrupted %s transaction unexpectedly passed\n' "$signal_stage" >&2
    exit 1
  fi
  [ "$(cat "$CPA_TEST_STATE")" = 0 ]
  [ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
  [ ! -e "$service_home/.local/bin/cli-proxy-api" ]
  run_reconciler "$rendered_reconciler"
done

# A post-fetch candidate mutation is rejected before the service manager runs.
chmod 700 "$old_dir/cli-proxy-api"
printf '# tampered\n' >> "$old_dir/cli-proxy-api"
chmod 500 "$old_dir/cli-proxy-api"
: > "$CPA_TEST_LOG"
if run_reconciler "$rendered_reconciler"; then
  printf 'tampered candidate unexpectedly passed\n' >&2
  exit 1
fi
if grep -Eq 'restart|bootstrap' "$CPA_TEST_LOG"; then
  printf 'tampered candidate reached a start operation\n' >&2
  exit 1
fi
grep -q 'disable' "$CPA_TEST_LOG"
[ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]
chmod 700 "$old_dir/cli-proxy-api"
cp "$old_binary_fixture" "$old_dir/cli-proxy-api"
chmod 500 "$old_dir/cli-proxy-api"
run_reconciler "$rendered_reconciler"

# Every required supervisor operation must propagate failure even though the
# operation lives inside a function used by an `if` condition.
if [ "$platform" = linux ]; then
  required_commands='daemon-reload reset-failed enable restart'
else
  required_commands='enable bootstrap kickstart'
fi
for failed_command in $required_commands; do
  : > "$CPA_TEST_LOG"
  if run_reconciler "$rendered_reconciler" "CPA_TEST_FAIL_COMMAND=$failed_command" CPA_TEST_FORCE_RECONCILE=1; then
    printf 'supervisor command failure was ignored: %s\n' "$failed_command" >&2
    exit 1
  fi
  grep -q "$failed_command" "$CPA_TEST_LOG"
  [ "$(cat "$CPA_TEST_STATE")" = 0 ]
  [ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
done

cat > "$stub_bin/mv" <<'EOF'
#!/bin/sh
case " $* " in *last-known-good*) exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod 700 "$stub_bin/mv"
manifest_before=$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")
: > "$CPA_TEST_LOG"
if run_reconciler "$rendered_reconciler"; then
  printf 'failed manifest commit unexpectedly passed\n' >&2
  exit 1
fi
[ "$(cat "$CPA_TEST_STATE")" = 0 ]
[ "$(cat "$service_home/.local/share/cli-proxy-api/last-known-good")" = "$manifest_before" ]
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
rm -f "$stub_bin/mv"

# Change the complete resolver tuple. Candidate fails; verified prior restarts
# and passes, while the apply still returns nonzero.
bad_id=v7.2.81-bbbbbbbbbbbb
bad_dir=$service_home/.local/share/cli-proxy-api/versions/$bad_id
mkdir -p "$bad_dir"
printf '%s\n' '#!/bin/sh' '# deterministic bad-semantics fixture' 'exit 0' > "$bad_dir/cli-proxy-api"
chmod 500 "$bad_dir/cli-proxy-api"
sed \
  -e 's/^CPA_RELEASE_TAG=.*/CPA_RELEASE_TAG="v7.2.81"/' \
  -e 's/^CPA_RELEASE_ASSET=.*/CPA_RELEASE_ASSET="CLIProxyAPI_7.2.81_linux_amd64.tar.gz"/' \
  -e 's/^CPA_RELEASE_SHA256=.*/CPA_RELEASE_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"/' \
  -e "s/^CPA_RELEASE_ID=.*/CPA_RELEASE_ID=\"$bad_id\"/" \
  "$rendered_reconciler" > "$scratch/bad-reconciler"
chmod 700 "$scratch/bad-reconciler"
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/bad-reconciler" CPA_TEST_BAD_ID=$bad_id; then
  printf 'bad candidate unexpectedly passed\n' >&2
  exit 1
fi
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
[ "$(grep -Ec 'restart|bootstrap' "$CPA_TEST_LOG")" -eq 1 ]
grep -qx "release_id=$release_id" "$service_home/.local/share/cli-proxy-api/last-known-good"

: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/bad-reconciler" \
  CPA_TEST_BAD_ID=$bad_id "CPA_TEST_MUTATE_PRIOR=$old_dir/cli-proxy-api"; then
  printf 'rollback-time prior mutation unexpectedly passed\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]
[ "$(grep -Ec 'restart|bootstrap' "$CPA_TEST_LOG")" -eq 0 ]
chmod 700 "$old_dir/cli-proxy-api"
cp "$old_binary_fixture" "$old_dir/cli-proxy-api"
chmod 500 "$old_dir/cli-proxy-api"
rm -f "$CPA_TEST_STATE.prior-mutated"
run_reconciler "$rendered_reconciler"

# A changed non-binary input forbids automatic prior restart and leaves stopped.
mkdir -p "$service_home/.local/share/cli-proxy-api/runtime"
chmod 644 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml" 2>/dev/null || true
cp "$service_home/.config/cli-proxy-api/config.yaml" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 644 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
printf '# changed policy fixture\n' >> "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/bad-reconciler" CPA_TEST_BAD_ID=$bad_id; then
  printf 'changed-config candidate unexpectedly passed\n' >&2
  exit 1
fi
[ "$(readlink "$service_home/.local/share/cli-proxy-api/current")" = "$old_dir" ]
[ "$(grep -Ec 'restart|bootstrap' "$CPA_TEST_LOG")" -eq 0 ]
grep -q ' disable ' "$CPA_TEST_LOG"
[ "$(cat "$CPA_TEST_STATE")" = 0 ]

# Restore the managed config and last-known-good state for failed-rollback proof.
mkdir -p "$service_home/.local/share/cli-proxy-api/runtime"
cp "$service_home/.config/cli-proxy-api/config.yaml" "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 644 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
chmod 400 "$service_home/.local/share/cli-proxy-api/runtime/config.yaml"
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/bad-reconciler" CPA_TEST_FAIL_ALL=1; then
  printf 'failed rollback unexpectedly passed\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]
grep -q ' disable ' "$CPA_TEST_LOG"
[ "$(cat "$CPA_TEST_STATE")" = 0 ]

# No prior manifest means a failed first install removes both active links.
rm -f "$service_home/.local/share/cli-proxy-api/current" \
  "$service_home/.local/share/cli-proxy-api/last-known-good" \
  "$service_home/.local/bin/cli-proxy-api"
: > "$CPA_TEST_LOG"
if run_reconciler "$scratch/bad-reconciler" CPA_TEST_BAD_ID=$bad_id; then
  printf 'failed first install unexpectedly passed\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]
grep -q ' disable ' "$CPA_TEST_LOG"
[ "$(cat "$CPA_TEST_STATE")" = 0 ]

# If the manager refuses disable/stop, reconciliation terminates only the PID
# whose executable is proven to be the active candidate, removes launchable
# links, and still returns nonzero.
: > "$CPA_TEST_LOG"
run_reconciler "$rendered_reconciler"
if [ "$platform" = darwin ]; then
  if run_reconciler "$rendered_reconciler" CPA_TEST_LOADED_NO_PID=1 CPA_TEST_FORCE_RECONCILE=1; then
    printf 'loaded launchd job without a PID was mistaken for stopped\n' >&2
    exit 1
  fi
  [ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
  [ ! -e "$service_home/.local/bin/cli-proxy-api" ]
  [ "$(cat "$CPA_TEST_STATE")" = 1 ]
  # Model an explicit operator repair before exercising the separate PID-backed
  # stop-failure path below.
  printf '0\n' > "$CPA_TEST_STATE"
  run_reconciler "$rendered_reconciler"
fi
if run_reconciler "$rendered_reconciler" CPA_TEST_STOP_FAIL=1 CPA_TEST_FORCE_RECONCILE=1; then
  printf 'failed stop/disable unexpectedly passed\n' >&2
  exit 1
fi
if kill -0 "$dummy_pid" 2>/dev/null; then
  printf 'verified candidate PID survived failed stop/disable\n' >&2
  exit 1
fi
[ ! -e "$service_home/.local/share/cli-proxy-api/current" ]
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]

dummy_pid=$(/bin/sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
export CPA_TEST_PID="$dummy_pid"
printf '0\n' > "$CPA_TEST_STATE"
run_reconciler "$rendered_reconciler"
rm -f "$service_home/.local/share/cli-proxy-api/current"
printf 'preserve unsafe current collision\n' > "$service_home/.local/share/cli-proxy-api/current"
if run_reconciler "$rendered_reconciler" CPA_TEST_STOP_FAIL=1 CPA_TEST_FORCE_RECONCILE=1; then
  printf 'unsafe current plus failed stop unexpectedly passed\n' >&2
  exit 1
fi
if kill -0 "$dummy_pid" 2>/dev/null; then
  printf 'manifest-attested PID survived unsafe-link stop failure\n' >&2
  exit 1
fi
grep -qx 'preserve unsafe current collision' "$service_home/.local/share/cli-proxy-api/current"
[ ! -e "$service_home/.local/bin/cli-proxy-api" ]

printf 'cli-proxy-api launcher and %s reconciler tests passed\n' "$platform"
