#!/usr/bin/env bash
set -euo pipefail

launcher=${1:?usage: test-open-design-activation.sh SERVICE_LAUNCHER RENDERED_UNIT [ENSURE_SERVICE OD_WRAPPER]}
unit=${2:?usage: test-open-design-activation.sh SERVICE_LAUNCHER RENDERED_UNIT [ENSURE_SERVICE OD_WRAPPER]}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ensure_source=${3:-"$repo_root/dot_local/libexec/open-design/executable_ensure-service"}
wrapper_source=${4:-"$repo_root/dot_local/bin/executable_od"}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/open-design-activation.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

test_home="$scratch/home"
fake_bin="$scratch/bin"
root="$test_home/.local/share/open-design"
source_dir="$root/source"
log="$scratch/commands.log"
mkdir -p "$fake_bin" "$source_dir/.git" \
  "$source_dir/apps/daemon/bin" "$source_dir/tools/pack/resources/linux" \
  "$test_home/.local/libexec/open-design" "$test_home/.local/bin" "$scratch/runtime"
chmod 0700 "$scratch/runtime"
cp "$ensure_source" "$test_home/.local/libexec/open-design/ensure-service"
cp "$wrapper_source" "$test_home/.local/bin/od"
chmod 0755 "$test_home/.local/libexec/open-design/ensure-service" "$test_home/.local/bin/od"
printf '%s\n' v0.15.1 >"$root/successful-release"
printf '%s\n' v0.15.1 >"$source_dir/.fake-head"
printf '%s\n' 'https://github.com/nexu-io/open-design.git' >"$source_dir/.fake-origin"
printf '%s\n' '#!/usr/bin/env node' >"$source_dir/apps/daemon/bin/od.mjs"
chmod 0755 "$source_dir/apps/daemon/bin/od.mjs"
printf 'png' >"$source_dir/tools/pack/resources/linux/icon.png"

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$2
case ${3-} in
  config) cat "$dir/.fake-origin" ;;
  rev-parse)
    value=${4-}
    if [[ $value == HEAD ]]; then cat "$dir/.fake-head"; else printf '%s\n' "${value%\^\{commit\}}"; fi
    ;;
  *) exit 90 ;;
esac
EOF
cat >"$fake_bin/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'argv='
  printf '%q ' "$@"
  printf '\nOD_DATA_DIR=%s\nOD_DAEMON_URL=%s\nOD_SIDECAR_IPC_BASE=%s\nOD_SIDECAR_IPC_PATH=%s\n' \
    "${OD_DATA_DIR:-}" "${OD_DAEMON_URL:-}" "${OD_SIDECAR_IPC_BASE:-}" "${OD_SIDECAR_IPC_PATH:-}"
} >>"$TEST_LOG"
if [[ " $* " == *" node "*"apps/daemon/bin/od.mjs "* ]]; then
  cat
  printf 'upstream-stderr\n' >&2
  exit "${UPSTREAM_EXIT:-0}"
fi
EOF
cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
case " $* " in
  *" start open-design.service "*)
    [[ ${SYSTEMCTL_START_FAIL:-0} != 1 ]]
    ;;
  *" is-active --quiet open-design.service "*)
    [[ ${SYSTEMCTL_ACTIVE:-1} == 1 ]]
    ;;
  *) exit 91 ;;
esac
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$TEST_LOG"
case " $* " in
  *" http://127.0.0.1:43909/api/ready "*)
    printf '{"ok":%s,"ready":%s,"version":%s}\n' \
      "${DAEMON_OK:-true}" "${DAEMON_READY:-true}" "${DAEMON_VERSION:-\"0.16.1\"}"
    ;;
  *" http://127.0.0.1:36947/ "*)
    [[ ${WEB_READY:-1} == 1 ]]
    ;;
  *) exit 92 ;;
esac
EOF
cat >"$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$TEST_LOG"
EOF
chmod 0755 "$fake_bin/git" "$fake_bin/mise" "$fake_bin/systemctl" \
  "$fake_bin/curl" "$fake_bin/sleep"

env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  OD_DATA_DIR="$test_home/.od" \
  OD_DAEMON_URL=http://127.0.0.1:43909 \
  OD_SIDECAR_IPC_BASE="$scratch/runtime/open-design/ipc" \
  OD_SIDECAR_IPC_PATH="$scratch/runtime/open-design/ipc/default/daemon.sock" \
  bash "$launcher"

grep -F 'argv=--no-config --no-env --no-hooks exec node@24 -- pnpm tools-dev run web --prod --web-port 36947 --daemon-port 43909 ' "$log"
grep -F "OD_DATA_DIR=$test_home/.od" "$log"
grep -F 'OD_DAEMON_URL=http://127.0.0.1:43909' "$log"

# Durable update state is a non-restartable configuration rejection.
printf '%s\n' v0.16.0 >"$root/updating"
set +e
env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  bash "$launcher" >"$scratch/updating.out" 2>"$scratch/updating.err"
status=$?
set -e
[[ $status -eq 78 ]]
grep -F 'provisioning is incomplete' "$scratch/updating.err"
rm -f "$root/updating"

# Marker/HEAD mismatch also uses the dedicated guard status.
printf '%s\n' other >"$source_dir/.fake-head"
set +e
env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  bash "$launcher" >"$scratch/mismatch.out" 2>"$scratch/mismatch.err"
status=$?
set -e
[[ $status -eq 78 ]]
grep -F 'does not match successful release' "$scratch/mismatch.err"

grep -Fx 'RuntimeDirectory=open-design' "$unit"
grep -Fx 'RuntimeDirectoryMode=0700' "$unit"
grep -Fx 'Environment=OD_DATA_DIR=%h/.od' "$unit"
grep -Fx 'Environment=OD_DAEMON_URL=http://127.0.0.1:43909' "$unit"
grep -Fx 'Environment=OD_SIDECAR_IPC_BASE=%t/open-design/ipc' "$unit"
grep -Fx 'Environment=OD_SIDECAR_IPC_PATH=%t/open-design/ipc/default/daemon.sock' "$unit"
grep -Fx 'Restart=on-failure' "$unit"
grep -Fx 'RestartPreventExitStatus=78' "$unit"
if grep -F '[Install]' "$unit"; then
  printf 'unit unexpectedly contains an Install section\n' >&2
  exit 1
fi
if grep -F 'WantedBy=' "$unit"; then
  printf 'unit unexpectedly enables login-time activation\n' >&2
  exit 1
fi

# The shared preflight starts idempotently, confirms that systemd still regards
# the service as active, and returns only the validated runtime path on success.
: >"$log"
runtime=$(env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  "$test_home/.local/libexec/open-design/ensure-service" daemon </dev/null)
[[ "$runtime" == "$scratch/runtime" ]]
grep -F 'systemctl --user start open-design.service' "$log"
grep -F 'systemctl --user is-active --quiet open-design.service' "$log"
grep -F 'http://127.0.0.1:43909/api/ready' "$log"

: >"$log"
runtime=$(env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  "$test_home/.local/libexec/open-design/ensure-service" web </dev/null)
[[ "$runtime" == "$scratch/runtime" ]]
grep -F 'http://127.0.0.1:36947/' "$log"

# Semantic daemon readiness rejects HTTP-success JSON that is not ready. The
# fake sleep makes the exact 240 x 250ms production loop instantaneous here.
: >"$log"
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" DAEMON_READY=false \
  "$test_home/.local/libexec/open-design/ensure-service" daemon \
  </dev/null >"$scratch/not-ready.out" 2>"$scratch/not-ready.err"
status=$?
set -e
[[ $status -ne 0 ]]
[[ ! -s "$scratch/not-ready.out" ]]
grep -F 'did not become ready within 60 seconds' "$scratch/not-ready.err"
[[ $(grep -c '^sleep 0.25$' "$log") -eq 239 ]]

# HTTP 200 alone is insufficient: the Open Design identity fields are part of
# readiness so an unrelated responder on the fixed port cannot pass.
: >"$log"
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" DAEMON_OK=false \
  "$test_home/.local/libexec/open-design/ensure-service" daemon \
  </dev/null >"$scratch/wrong-responder.out" 2>"$scratch/wrong-responder.err"
status=$?
set -e
[[ $status -ne 0 ]]
[[ ! -s "$scratch/wrong-responder.out" ]]
grep -F 'did not become ready within 60 seconds' "$scratch/wrong-responder.err"

# A process that dies before readiness is reported immediately, with guidance
# on stderr and no stdout/protocol contamination.
: >"$log"
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" SYSTEMCTL_ACTIVE=0 \
  "$test_home/.local/libexec/open-design/ensure-service" daemon \
  </dev/null >"$scratch/inactive.out" 2>"$scratch/inactive.err"
status=$?
set -e
[[ $status -ne 0 ]]
[[ ! -s "$scratch/inactive.out" ]]
grep -F 'stopped before readiness' "$scratch/inactive.err"
grep -F 'journalctl --user-unit open-design.service' "$scratch/inactive.err"

# Runtime roots must be absolute, non-symlink directories owned by this uid.
ln -s "$scratch/runtime" "$scratch/runtime-link"
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime-link" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
  "$test_home/.local/libexec/open-design/ensure-service" daemon \
  </dev/null >"$scratch/runtime.out" 2>"$scratch/runtime.err"
status=$?
set -e
[[ $status -ne 0 ]]
grep -F 'runtime directory is missing or unsafe' "$scratch/runtime.err"

# The od wrapper captures the preflight's sole stdout line, exports the exact
# daemon/data/IPC contract, and execs the upstream Node CLI without consuming
# stdin or adding bytes to stdout.
: >"$log"
printf 'json-rpc-input\n' |
  env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
    PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
    "$test_home/.local/bin/od" mcp --example \
    >"$scratch/od.out" 2>"$scratch/od.err"
grep -Fx 'json-rpc-input' "$scratch/od.out"
grep -Fx 'upstream-stderr' "$scratch/od.err"
grep -F 'node@24 -- node' "$log"
grep -F 'apps/daemon/bin/od.mjs mcp --example ' "$log"
grep -F "OD_DATA_DIR=$test_home/.od" "$log"
grep -F 'OD_DAEMON_URL=http://127.0.0.1:43909' "$log"
grep -F "OD_SIDECAR_IPC_BASE=$scratch/runtime/open-design/ipc" "$log"
grep -F "OD_SIDECAR_IPC_PATH=$scratch/runtime/open-design/ipc/default/daemon.sock" "$log"

# Exec transparency includes the upstream exit status.
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" UPSTREAM_EXIT=23 \
  "$test_home/.local/bin/od" --version \
  </dev/null >"$scratch/exit.out" 2>"$scratch/exit.err"
status=$?
set -e
[[ $status -eq 23 ]]

# Preflight failures never invoke upstream and never send desktop notifications.
: >"$log"
set +e
env HOME="$test_home" XDG_RUNTIME_DIR="$scratch/runtime" \
  PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" SYSTEMCTL_START_FAIL=1 \
  "$test_home/.local/bin/od" mcp \
  </dev/null >"$scratch/start-fail.out" 2>"$scratch/start-fail.err"
status=$?
set -e
[[ $status -ne 0 ]]
[[ ! -s "$scratch/start-fail.out" ]]
grep -F 'failed to start open-design.service' "$scratch/start-fail.err"
if grep -F 'apps/daemon/bin/od.mjs' "$log"; then
  printf 'upstream CLI ran after activation failure\n' >&2
  exit 1
fi
if grep -F 'notify-send' "$log"; then
  printf 'CLI activation failure sent a desktop notification\n' >&2
  exit 1
fi

printf 'open-design activation tests passed\n'
