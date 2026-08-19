#!/usr/bin/env bash
# setup-podman-cluster runs on every apply by contract, so a converged host must
# re-run neither `systemctl --user enable` nor `minikube config set`. Fixture 1 is
# a regression assertion: it must fail against the pre-convergence script.
set -euo pipefail

usage='usage: test-podman-cluster-convergence.sh PODMAN_SCRIPT'
podman_script=${1:?$usage}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/podman-cluster-convergence.XXXXXX")
chmod 0700 -- "$scratch"
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

bin="$scratch/bin"
mkdir -p -- "$bin"

make_stub() {
  local path=$1
  shift
  cat >"$path"
  chmod 0755 "$path"
}

make_stub "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$SYSTEMCTL_CALLS"
case "$*" in
  '--user show-environment'|'--user daemon-reload') exit 0 ;;
  '--user cat podman.socket'|'--user cat podman-prune.timer'|'--user cat minikube-autostart.service')
    exit 0 ;;
  '--user is-enabled podman.socket') exit "${FIXTURE_PODMAN_SOCKET_ENABLED:-1}" ;;
  '--user is-active podman.socket') exit "${FIXTURE_PODMAN_SOCKET_ACTIVE:-1}" ;;
  '--user is-enabled podman-prune.timer') exit "${FIXTURE_PRUNE_TIMER_ENABLED:-1}" ;;
  '--user is-active podman-prune.timer') exit "${FIXTURE_PRUNE_TIMER_ACTIVE:-1}" ;;
  '--user is-enabled minikube-autostart.service') exit "${FIXTURE_MINIKUBE_AUTOSTART_ENABLED:-1}" ;;
  '--user enable --now podman.socket') exit 0 ;;
  '--user enable --now podman-prune.timer') exit 0 ;;
  '--user enable minikube-autostart.service') exit 0 ;;
  *) exit 1 ;;
esac
EOF

make_stub "$bin/minikube" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  config)
    case "$2 $3" in
      'get driver')
        [[ -n "${FIXTURE_MINIKUBE_DRIVER-}" ]] || exit 1
        printf '%s\n' "$FIXTURE_MINIKUBE_DRIVER"
        ;;
      'get container-runtime')
        [[ -n "${FIXTURE_MINIKUBE_CONTAINER_RUNTIME-}" ]] || exit 1
        printf '%s\n' "$FIXTURE_MINIKUBE_CONTAINER_RUNTIME"
        ;;
      'set driver'|'set container-runtime')
        printf 'minikube %s\n' "$*" >>"$MINIKUBE_CALLS"
        ;;
      *) exit 1 ;;
    esac
    ;;
  status) exit 0 ;;
  *) exit 1 ;;
esac
EOF

make_stub "$bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1-}" == info ]] || exit 1
exit 0
EOF

# `sudo -n true` must fail so the no-sudo-for-delegation skip declaration
# takes its declared branch; the fixture never needs root.
make_stub "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-n true' ]] || exit 1
exit 1
EOF

run_script() {
  local out=$1 err=$2
  : >"$SYSTEMCTL_CALLS"
  : >"$MINIKUBE_CALLS"
  # HOME and XDG_STATE_HOME are isolated because the script's declared skips
  # write a real skip-ledger entry, and stdin is closed so `[[ ! -t 0 ]]` makes
  # the no-sudo branch deterministic instead of terminal-dependent.
  env PATH="$bin:/usr/bin:/bin" \
    HOME="$fixture_home" XDG_STATE_HOME="$fixture_state" \
    SYSTEMCTL_CALLS="$SYSTEMCTL_CALLS" MINIKUBE_CALLS="$MINIKUBE_CALLS" \
    FIXTURE_PODMAN_SOCKET_ENABLED="${FIXTURE_PODMAN_SOCKET_ENABLED:-1}" \
    FIXTURE_PODMAN_SOCKET_ACTIVE="${FIXTURE_PODMAN_SOCKET_ACTIVE:-1}" \
    FIXTURE_PRUNE_TIMER_ENABLED="${FIXTURE_PRUNE_TIMER_ENABLED:-1}" \
    FIXTURE_PRUNE_TIMER_ACTIVE="${FIXTURE_PRUNE_TIMER_ACTIVE:-1}" \
    FIXTURE_MINIKUBE_AUTOSTART_ENABLED="${FIXTURE_MINIKUBE_AUTOSTART_ENABLED:-1}" \
    FIXTURE_MINIKUBE_DRIVER="${FIXTURE_MINIKUBE_DRIVER-}" \
    FIXTURE_MINIKUBE_CONTAINER_RUNTIME="${FIXTURE_MINIKUBE_CONTAINER_RUNTIME-}" \
    bash "$podman_script" >"$out" 2>"$err" </dev/null
}

fixture_home="$scratch/home"
fixture_state="$scratch/state"
mkdir -p -- "$fixture_home" "$fixture_state"

SYSTEMCTL_CALLS="$scratch/systemctl.log"
MINIKUBE_CALLS="$scratch/minikube.log"

fail() {
  local fixture=$1 msg=$2
  echo "test-podman-cluster-convergence: [$fixture] $msg" >&2
  echo "--- stdout ---" >&2
  cat "$scratch/out" >&2 || true
  echo "--- stderr ---" >&2
  cat "$scratch/err" >&2 || true
  echo "--- systemctl calls ---" >&2
  cat "$SYSTEMCTL_CALLS" >&2 || true
  echo "--- minikube calls ---" >&2
  cat "$MINIKUBE_CALLS" >&2 || true
  exit 1
}

# --- fixture 1: converged host -- every unit already enabled and active, ---
# --- minikube already podman/containerd. THE REGRESSION ASSERTION: must  ---
# --- fail against the unmodified script.                                 ---
FIXTURE_PODMAN_SOCKET_ENABLED=0 FIXTURE_PODMAN_SOCKET_ACTIVE=0 \
  FIXTURE_PRUNE_TIMER_ENABLED=0 FIXTURE_PRUNE_TIMER_ACTIVE=0 \
  FIXTURE_MINIKUBE_AUTOSTART_ENABLED=0 \
  FIXTURE_MINIKUBE_DRIVER=podman FIXTURE_MINIKUBE_CONTAINER_RUNTIME=containerd \
  run_script "$scratch/out" "$scratch/err" \
  || fail converged "script exited non-zero on a fully converged host"

if grep -qE '^systemctl --user enable ' "$SYSTEMCTL_CALLS"; then
  fail converged "recorded an 'enable' call on a fully converged host: $(cat "$SYSTEMCTL_CALLS")"
fi
if [[ -s "$MINIKUBE_CALLS" ]]; then
  fail converged "recorded a 'minikube config set' call on a fully converged host: $(cat "$MINIKUBE_CALLS")"
fi
for msg in \
  'setup-podman-cluster: --user podman.socket already enabled and active' \
  'setup-podman-cluster: --user podman-prune.timer already enabled and active' \
  'setup-podman-cluster: minikube-autostart.service already enabled' \
  'setup-podman-cluster: minikube already set to driver=podman, container-runtime=containerd (rootless)'; do
  grep -qF "$msg" "$scratch/out" \
    || fail converged "missing converged-state message: $msg"
done

# --- fixture 2: drifted host -- nothing enabled/active, minikube on the ---
# --- wrong driver. The fix must not break first-run provisioning.       ---
FIXTURE_PODMAN_SOCKET_ENABLED=1 FIXTURE_PODMAN_SOCKET_ACTIVE=1 \
  FIXTURE_PRUNE_TIMER_ENABLED=1 FIXTURE_PRUNE_TIMER_ACTIVE=1 \
  FIXTURE_MINIKUBE_AUTOSTART_ENABLED=1 \
  FIXTURE_MINIKUBE_DRIVER=docker FIXTURE_MINIKUBE_CONTAINER_RUNTIME=docker \
  run_script "$scratch/out" "$scratch/err" \
  || fail drifted "script exited non-zero on a fully drifted host"

grep -qF 'systemctl --user enable --now podman.socket' "$SYSTEMCTL_CALLS" \
  || fail drifted "did not enable --now podman.socket"
grep -qF 'systemctl --user enable --now podman-prune.timer' "$SYSTEMCTL_CALLS" \
  || fail drifted "did not enable --now podman-prune.timer"
grep -qF 'systemctl --user enable minikube-autostart.service' "$SYSTEMCTL_CALLS" \
  || fail drifted "did not enable minikube-autostart.service"
grep -qF 'minikube config set driver podman' "$MINIKUBE_CALLS" \
  || fail drifted "did not set minikube driver=podman"
grep -qF 'minikube config set container-runtime containerd' "$MINIKUBE_CALLS" \
  || fail drifted "did not set minikube container-runtime=containerd"

# --- fixture 3: partial minikube drift -- driver already podman, only the ---
# --- container-runtime differs. Exactly one config-set call, and it must ---
# --- name container-runtime, not driver.                                 ---
FIXTURE_PODMAN_SOCKET_ENABLED=0 FIXTURE_PODMAN_SOCKET_ACTIVE=0 \
  FIXTURE_PRUNE_TIMER_ENABLED=0 FIXTURE_PRUNE_TIMER_ACTIVE=0 \
  FIXTURE_MINIKUBE_AUTOSTART_ENABLED=0 \
  FIXTURE_MINIKUBE_DRIVER=podman FIXTURE_MINIKUBE_CONTAINER_RUNTIME=docker \
  run_script "$scratch/out" "$scratch/err" \
  || fail partial-drift "script exited non-zero on a partially drifted host"

minikube_set_count=$(grep -c '^minikube config set ' "$MINIKUBE_CALLS" || true)
[[ "$minikube_set_count" -eq 1 ]] \
  || fail partial-drift "expected exactly 1 'minikube config set' call, got $minikube_set_count: $(cat "$MINIKUBE_CALLS")"
grep -qF 'minikube config set container-runtime containerd' "$MINIKUBE_CALLS" \
  || fail partial-drift "did not set container-runtime"
if grep -qF 'minikube config set driver podman' "$MINIKUBE_CALLS"; then
  fail partial-drift "re-set an already-correct driver"
fi

echo "podman cluster convergence tests passed"
