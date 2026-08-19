#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/vllm-provision.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'test-vllm-provision: FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'test-vllm-provision: ok - %s\n' "$*"
}

source_root="$scratch/source"
mkdir -p -- "$source_root" "$scratch/bin" "$scratch/target"
: >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 -- "$scratch/bin/op"

cp -a -- "$repo_root/.chezmoidata" "$repo_root/.chezmoitemplates" "$repo_root/.chezmoiscripts" \
  "$repo_root/system" "$repo_root/dot_config" "$source_root/"

write_facts() {
  local jetson=$1 shared_host=$2
  cat >"$source_root/.chezmoitemplates/facts.tmpl" <<FACTS
os: linux
distro: ubuntu
desktop: gnome
nvidia: false
thinkpad: false
jetson: ${jetson}
vm: false
virt: false
sddmBreeze: false
gdm: false
fprintdPam: false
headless: false
container: false
sharedHost: ${shared_host}
FACTS
}

render_provisioner() {
  local jetson=$1 out=$2
  write_facts "$jetson" false
  env PATH="$scratch/bin:$PATH" chezmoi \
    --config "$scratch/empty.toml" \
    --source "$source_root" \
    --destination "$scratch/target" \
    --override-data '{"chezmoi":{"osRelease":{"id":"ubuntu"},"arch":"arm64","sourceDir":"'"$source_root"'"}}' \
    execute-template <"$source_root/.chezmoiscripts/60-build/run_after_provision-vllm.sh.tmpl" >"$out"
}

rendered_true="$scratch/provision-jetson-true.sh"
rendered_false="$scratch/provision-jetson-false.sh"
render_provisioner true "$rendered_true"
render_provisioner false "$rendered_false"

make_stub() {
  local path=$1
  shift
  cat >"$path"
  chmod 0755 "$path"
}

make_stubs() {
  local bin=$1
  mkdir -p -- "$bin"

  make_stub "$bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ss %s\n' "$*" >>"$TEST_LOG"
if [[ -n "${STUB_SS_LISTENER_PORT:-}" ]]; then
  printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$STUB_SS_LISTENER_PORT"
fi
EOF

  make_stub "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  '--user daemon-reload') exit 0 ;;
  '--user is-active --quiet '*)
    unit=${*##* }
    [[ -f "$TEST_STATE/systemd-active-$unit" ]]
    ;;
  '--user enable '*)
    for u in "${@:3}"; do
      : >"$TEST_STATE/systemd-enabled-$u"
    done
    exit 0
    ;;
  '--user restart '*)
    unit=${*##* }
    : >"$TEST_STATE/systemd-active-$unit"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF

  make_stub "$bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemd-analyze %s\n' "$*" >>"$TEST_LOG"
exit 0
EOF

  make_stub "$bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'op %s\n' "$*" >>"$TEST_LOG"
if [[ "${STUB_OP_ABSENT:-0}" == 1 ]]; then
  exit 127
fi
if [[ "${STUB_OP_FAIL:-0}" == 1 ]]; then
  exit 1
fi
case "$*" in
  'read '*) printf 'resolved-op-secret-key-12345' ;;
  *) exit 1 ;;
esac
EOF

  make_stub "$bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'openssl %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  'rand -hex 32') printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' ;;
  *) /usr/bin/openssl "$@" ;;
esac
EOF

  make_stub "$bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/root 100000000 10000000 90000000 10%% /\n'
EOF

  make_stub "$bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
  -nG|-Gn)
    if [[ "${STUB_ID_MISSING_GROUPS:-0}" == 1 ]]; then
      printf 'users adm\n'
    else
      printf 'users adm video render\n'
    fi
    ;;
  -u) printf '%s\n' "${EUID:-1000}" ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

  make_stub "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$TEST_LOG"
if [[ "${STUB_SUDO_FAIL:-0}" == 1 ]]; then
  exit 1
fi
exit 0
EOF

  make_stub "$bin/loginctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'loginctl %s\n' "$*" >>"$TEST_LOG"
case "${1-}" in
  show-user)
    if [[ "${STUB_LOGINCTL_NOLINGER:-0}" == 1 ]]; then
      printf 'Linger=no\n'
    else
      printf 'Linger=yes\n'
    fi
    ;;
  enable-linger) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  make_stub "$bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'group video')
    if [[ "${STUB_MANAGER_LACKS_GROUPS:-0}" == 1 ]]; then
      printf 'video:x:99991:\n'
    else
      printf 'video:x:4:\n'
    fi
    ;;
  'group render')
    if [[ "${STUB_MANAGER_LACKS_GROUPS:-0}" == 1 ]]; then
      printf 'render:x:99992:\n'
    else
      printf 'render:x:27:\n'
    fi
    ;;
  *) /usr/bin/getent "$@" || true ;;
esac
EOF

  make_stub "$bin/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${STUB_PGREP_PID:-$$}"
EOF

  make_stub "$bin/uvx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'uvx %s\n' "$*" >>"$TEST_LOG"
dir=""
while (($#)); do
  if [[ "$1" == "--local-dir" ]]; then
    dir="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$dir" ]]; then
  mkdir -p "$dir"
  touch "$dir/config.json"
fi
exit 0
EOF

  make_stub "$bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'uv %s\n' "$*" >>"$TEST_LOG"
case "${1-}" in
  venv)
    venv_path="${!#}"
    mkdir -p "$venv_path/bin"
    cat >"$venv_path/bin/vllm" <<'BIN'
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "vllm 0.27.1"
fi
exit 0
BIN
    chmod 0755 "$venv_path/bin/vllm"
    ;;
  pip) exit 0 ;;
  *) exit 0 ;;
esac
EOF

  make_stub "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$TEST_LOG"
if [[ "$*" == *"-f"* ]]; then
  exit 0
fi
if [[ "$*" == *"-w %{http_code}"* ]] && [[ "$*" != *"-K"* ]]; then
  printf '401'
  exit 0
fi
if [[ "$*" == *"-w %{http_code}"* ]] && [[ "$*" == *"-K"* ]]; then
  printf '200'
  exit 0
fi
exit 0
EOF

  make_stub "$bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
}

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  test_home="$case_dir/home"
  fake_bin="$case_dir/bin"
  TEST_LOG="$case_dir/commands.log"
  TEST_STATE="$case_dir/state"
  export TEST_LOG TEST_STATE

  mkdir -p "$test_home/.config/systemd/user" \
    "$test_home/.local/share/vllm/models" \
    "$test_home/.local/share/vllm/venv" \
    "$test_home/.config/vllm" \
    "$TEST_STATE" "$fake_bin"

  for unit in vllm-chat.service vllm-embed.service vllm-chat-mdns.service vllm-embed-mdns.service; do
    printf '[Unit]\nDescription=%s\n[Service]\nExecStart=/bin/true\n' "$unit" \
      >"$test_home/.config/systemd/user/$unit"
  done

  cp "$rendered_true" "$case_dir/provision.sh"
  chmod 0755 "$case_dir/provision.sh"
  : >"$TEST_LOG"
  make_stubs "$fake_bin"
}

run_case() {
  local script_path=${1:-"$case_dir/provision.sh"}
  env HOME="$test_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    TEST_LOG="$TEST_LOG" \
    TEST_STATE="$TEST_STATE" \
    STUB_SS_LISTENER_PORT="${STUB_SS_LISTENER_PORT:-}" \
    STUB_OP_ABSENT="${STUB_OP_ABSENT:-0}" \
    STUB_OP_FAIL="${STUB_OP_FAIL:-0}" \
    STUB_ID_MISSING_GROUPS="${STUB_ID_MISSING_GROUPS:-0}" \
    STUB_SUDO_FAIL="${STUB_SUDO_FAIL:-0}" \
    STUB_LOGINCTL_NOLINGER="${STUB_LOGINCTL_NOLINGER:-0}" \
    STUB_MANAGER_LACKS_GROUPS="${STUB_MANAGER_LACKS_GROUPS:-0}" \
    STUB_PGREP_PID="$$" \
    VLLM_SOURCE_ROOT="$source_root" \
    USER="testuser" \
    bash "$script_path"
}

prepare_case convergence
run_case >"$case_dir/run1.out" 2>"$case_dir/run1.err"
[[ -f "$test_home/.local/share/vllm/.vllm-state/provision-stamp" ]] || fail 'stamp not written after first convergence'
[[ -f "$test_home/.config/vllm/auth.env" ]] || fail 'auth.env missing after convergence'
[[ $(stat -c '%a' "$test_home/.config/vllm/auth.env") == "600" ]] || fail 'auth.env does not have 0600 permissions'
grep -qF 'VLLM_API_KEY=resolved-op-secret-key-12345' "$test_home/.config/vllm/auth.env" || fail 'auth.env missing resolved secret'
grep -qF 'systemctl --user restart vllm-embed.service' "$TEST_LOG" || fail 'vllm-embed.service not restarted'
grep -qF 'systemctl --user restart vllm-chat.service' "$TEST_LOG" || fail 'vllm-chat.service not restarted'
grep -qF 'systemctl --user restart vllm-embed-mdns.service' "$TEST_LOG" || fail 'vllm-embed-mdns.service not restarted'
grep -qF 'systemctl --user restart vllm-chat-mdns.service' "$TEST_LOG" || fail 'vllm-chat-mdns.service not restarted'

log_count_before=$(wc -l <"$TEST_LOG")
run_case >"$case_dir/run2.out" 2>"$case_dir/run2.err"
grep -qF 'vLLM services already provisioned with current configuration; nothing to do' "$case_dir/run2.out" \
  || fail 'second run did not short-circuit on stamp match'
log_count_after=$(wc -l <"$TEST_LOG")
[[ "$log_count_before" -eq "$log_count_after" ]] || fail 'second run executed unexpected mutations'
pass 'unchanged convergence short-circuit'

prepare_case non-jetson
cp "$rendered_false" "$case_dir/provision-false.sh"
run_case "$case_dir/provision-false.sh" >"$case_dir/run.out" 2>"$case_dir/run.err"
grep -qF 'vLLM local inference services deploy only on Jetson AGX Thor' "$case_dir/run.out" \
  || fail 'non-jetson render did not print skip notice'
! grep -qF 'systemctl --user' "$TEST_LOG" || fail 'non-jetson render mutated systemctl'
[[ ! -f "$test_home/.local/share/vllm/.vllm-state/provision-stamp" ]] || fail 'non-jetson render wrote stamp'
pass 'non-jetson harmless skip'

prepare_case port-collision
set +e
STUB_SS_LISTENER_PORT=8000 run_case >"$case_dir/run.out" 2>"$case_dir/run.err"
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'port collision on 8000 did not exit nonzero'
grep -qF 'preflight: port 8000 is already in use by an unmanaged listener' "$case_dir/run.err" \
  || fail 'port collision did not report expected preflight error'
! grep -qF 'systemctl --user restart' "$TEST_LOG" || fail 'port collision mutated systemd services'
! grep -qF 'systemctl --user daemon-reload' "$TEST_LOG" || fail 'port collision reloaded daemon'
pass 'port-collision preflight failure'

prepare_case secret-retain
printf 'VLLM_API_KEY=existing-local-token\n' >"$test_home/.config/vllm/auth.env"
chmod 0600 "$test_home/.config/vllm/auth.env"
STUB_OP_ABSENT=1 run_case >"$case_dir/run.out" 2>"$case_dir/run.err"
grep -qF 'WARNING: op is unavailable or could not resolve' "$case_dir/run.err" \
  || fail 'secret fallback retain did not emit warning'
grep -qF 'retaining existing' "$case_dir/run.err" \
  || fail 'secret fallback retain did not emit retaining message'
grep -qF 'VLLM_API_KEY=existing-local-token' "$test_home/.config/vllm/auth.env" \
  || fail 'existing auth.env was overwritten'
[[ $(stat -c '%a' "$test_home/.config/vllm/auth.env") == "600" ]] || fail 'retained auth.env does not have 0600 permissions'
pass 'secret fallback: op absent + existing envFile retained'

prepare_case secret-generate
rm -f "$test_home/.config/vllm/auth.env"
STUB_OP_ABSENT=1 run_case >"$case_dir/run.out" 2>"$case_dir/run.err"
grep -qF 'NOTICE: Generated local API key in' "$case_dir/run.err" \
  || fail 'secret fallback generate did not emit notice'
grep -qF 'This key is not enrolled in 1Password' "$case_dir/run.err" \
  || fail 'secret fallback generate did not emit enrollment notice'
[[ -f "$test_home/.config/vllm/auth.env" ]] || fail 'generated auth.env missing'
[[ $(stat -c '%a' "$test_home/.config/vllm/auth.env") == "600" ]] || fail 'generated auth.env does not have 0600 permissions'
grep -qF 'VLLM_API_KEY=0123456789abcdef' "$test_home/.config/vllm/auth.env" \
  || fail 'generated auth.env missing generated token'
pass 'secret fallback: op absent + no envFile generates local key'

prepare_case deferred-activation
STUB_MANAGER_LACKS_GROUPS=1 run_case >"$case_dir/run.out" 2>"$case_dir/run.err"
grep -qF 'Running systemd user manager lacks video/render group credentials from session startup' "$case_dir/run.out" \
  || fail 'deferred activation missing credential notice'
grep -qF 'Units have been enabled; service activation is deferred until after reboot or user-session restart' "$case_dir/run.out" \
  || fail 'deferred activation missing deferred notice'
grep -qF 'systemctl --user enable' "$TEST_LOG" || fail 'deferred activation did not enable units'
! grep -qF 'systemctl --user restart' "$TEST_LOG" || fail 'deferred activation restarted services'
[[ ! -f "$test_home/.local/share/vllm/.vllm-state/provision-stamp" ]] || fail 'deferred activation wrote stamp'
pass 'deferred activation on manager lacking group credentials'

printf 'test-vllm-provision: all tests passed\n'
