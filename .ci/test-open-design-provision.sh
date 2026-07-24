#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-open-design-provision.sh RENDERED_PROVISIONER}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/open-design-provision.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

make_stubs() {
  local bin=$1
  mkdir -p -- "$bin"
  cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$TEST_LOG"
if [[ ${1-} == clone ]]; then
  tag=
  for ((i=1; i<=$#; i++)); do
    if [[ ${!i} == --branch ]]; then
      j=$((i + 1))
      tag=${!j}
    fi
  done
  dest=${!#}
  mkdir -p "$dest/.git" "$dest/apps/daemon/bin" "$dest/tools/pack/resources/linux"
  printf '%s\n' 'https://github.com/nexu-io/open-design.git' >"$dest/.fake-origin"
  printf '%s\n' "$tag" >"$dest/.fake-head"
  printf '{"packageManager":"%s","engines":{"node":"%s","pnpm":"%s"}}\n' \
    "${PACKAGE_MANAGER:-pnpm@10.33.2}" "${NODE_ENGINE:-~24}" \
    "${PNPM_ENGINE:->=10.33.2 <11}" >"$dest/package.json"
  printf '%s\n' '#!/usr/bin/env node' >"$dest/apps/daemon/bin/od.mjs"
  chmod 0755 "$dest/apps/daemon/bin/od.mjs"
  printf 'png' >"$dest/tools/pack/resources/linux/icon.png"
  exit 0
fi
if [[ ${1-} == -C ]]; then
  dir=$2
  shift 2
  case ${1-} in
    config)
      cat "$dir/.fake-origin"
      ;;
    fetch)
      [[ ${FAIL_STAGE:-} != fetch ]] || exit 41
      ;;
    reset)
      [[ ${FAIL_STAGE:-} != reset ]] || exit 42
      printf '%s\n' "${3-}" >"$dir/.fake-head"
      ;;
    rev-parse)
      value=${2-}
      if [[ $value == HEAD ]]; then
        cat "$dir/.fake-head"
      else
        printf '%s\n' "${value%\^\{commit\}}"
      fi
      ;;
    *)
      exit 90
      ;;
  esac
  exit 0
fi
exit 91
EOF
  cat >"$bin/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mise %s\n' "$*" >>"$TEST_LOG"
if [[ " $* " == *" node --version "* ]]; then
  [[ ${FAIL_STAGE:-} != metadata ]] || exit 51
  printf '%s\n' "${NODE_VERSION:-v24.12.0}"
  exit 0
fi
if [[ " $* " == *" corepack enable "* ]]; then
  [[ ${COREPACK_ENABLE_DOWNLOAD_PROMPT:-} == 0 ]] || exit 52
  [[ ${FAIL_STAGE:-} != corepack ]] || exit 53
elif [[ " $* " == *" pnpm install "* ]]; then
  [[ ${FAIL_STAGE:-} != install ]] || exit 54
elif [[ " $* " == *" pnpm bootstrap "* ]]; then
  [[ ${FAIL_STAGE:-} != bootstrap ]] || exit 55
elif [[ " $* " == *" @open-design/web build "* ]]; then
  [[ ${FAIL_STAGE:-} != build ]] || exit 56
fi
EOF
  cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  "--user show-environment")
    [[ ${NO_USER_BUS:-0} != 1 ]]
    ;;
  "--user is-active --quiet open-design.service")
    [[ ${SERVICE_ACTIVE:-0} == 1 ]]
    ;;
  "--user restart open-design.service")
    [[ ${FAIL_STAGE:-} != restart ]]
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod 0755 "$bin/git" "$bin/mise" "$bin/systemctl"
}

prepare_case() {
  local name=$1
  case_dir="$scratch/$name"
  test_home="$case_dir/home"
  fake_bin="$case_dir/bin"
  TEST_LOG="$case_dir/commands.log"
  export TEST_LOG
  mkdir -p "$test_home" "$fake_bin"
  : >"$TEST_LOG"
  cp "$rendered" "$case_dir/provision.sh"
  chmod 0755 "$case_dir/provision.sh"
  make_stubs "$fake_bin"
}

run_case() {
  env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" \
    SERVICE_ACTIVE="${SERVICE_ACTIVE:-0}" NO_USER_BUS="${NO_USER_BUS:-0}" \
    FAIL_STAGE="${FAIL_STAGE:-}" TEST_LOG="$TEST_LOG" \
    PACKAGE_MANAGER="${PACKAGE_MANAGER:-}" NODE_ENGINE="${NODE_ENGINE:-}" \
    PNPM_ENGINE="${PNPM_ENGINE:-}" NODE_VERSION="${NODE_VERSION:-}" \
    OPEN_DESIGN_LOCK_TIMEOUT="${OPEN_DESIGN_LOCK_TIMEOUT:-}" \
    bash "$case_dir/provision.sh"
}

rendered_tag=$(sed -n 's/^TAG=//p' "$rendered" | head -n1)
rendered_tag=${rendered_tag#\"}
rendered_tag=${rendered_tag%\"}
[[ -n "$rendered_tag" ]]

# First install is staged, built in the requested order, then promoted.
prepare_case first
run_case
root="$test_home/.local/share/open-design"
[[ -d "$root/source" && ! -e "$root/.source-stage" ]]
[[ $(<"$root/successful-release") == "$rendered_tag" ]]
[[ ! -e "$root/updating" ]]
clone_line=$(grep -n '^git clone ' "$TEST_LOG" | cut -d: -f1)
corepack_line=$(grep -n ' corepack enable$' "$TEST_LOG" | cut -d: -f1)
install_line=$(grep -n ' pnpm install$' "$TEST_LOG" | cut -d: -f1)
bootstrap_line=$(grep -n ' pnpm bootstrap$' "$TEST_LOG" | cut -d: -f1)
build_line=$(grep -n ' pnpm --filter @open-design/web build$' "$TEST_LOG" | cut -d: -f1)
(( clone_line < corepack_line && corepack_line < install_line &&
   install_line < bootstrap_line && bootstrap_line < build_line ))
if grep -F "$HOME/src/github.com/nexu-io/open-design" "$TEST_LOG"; then
  printf 'manual developer checkout was referenced\n' >&2
  exit 1
fi

# The real metadata checks reject an unsupported release contract rather than
# relying on a stubbed validator result.
prepare_case unsupported-metadata
set +e
PACKAGE_MANAGER=pnpm@11.0.0 run_case \
  >"$case_dir/unsupported-metadata.out" 2>"$case_dir/unsupported-metadata.err"
status=$?
set -e
unset PACKAGE_MANAGER
[[ $status -ne 0 ]]
grep -F 'upstream Node/pnpm contract is not Node 24 and pnpm 10' \
  "$case_dir/unsupported-metadata.err"

# A surviving service/shared-lock holder cannot hang apply indefinitely.
prepare_case held-lock
lock_root="$test_home/.local/share/open-design"
mkdir -p "$lock_root"
exec 8>"$lock_root/provision.lock"
flock -s 8
set +e
OPEN_DESIGN_LOCK_TIMEOUT=0 run_case \
  >"$case_dir/held-lock.out" 2>"$case_dir/held-lock.err"
status=$?
set -e
unset OPEN_DESIGN_LOCK_TIMEOUT
flock -u 8
exec 8>&-
[[ $status -ne 0 ]]
grep -F 'timed out waiting for the Open Design service to stop' \
  "$case_dir/held-lock.err"

# An active upgrade stops before mutation and restarts once after promotion.
prepare_case upgrade
run_case
root="$test_home/.local/share/open-design"
printf '%s\n' old-release >"$root/successful-release"
printf '%s\n' old-release >"$root/source/.fake-head"
: >"$TEST_LOG"
SERVICE_ACTIVE=1 run_case
stop_line=$(grep -n 'systemctl --user stop open-design.service' "$TEST_LOG" | cut -d: -f1)
reset_line=$(grep -n 'git -C .* reset --hard' "$TEST_LOG" | cut -d: -f1)
restart_count=$(grep -c 'systemctl --user restart open-design.service' "$TEST_LOG")
(( stop_line < reset_line ))
[[ $restart_count -eq 1 ]]

# If the post-build restart fails, the next apply retains and fulfills the
# original active-service intent even though the unit is now inactive.
printf '%s\n' old-release >"$root/successful-release"
printf '%s\n' old-release >"$root/source/.fake-head"
: >"$TEST_LOG"
set +e
FAIL_STAGE=restart SERVICE_ACTIVE=1 run_case \
  >"$case_dir/restart-fail.out" 2>"$case_dir/restart-fail.err"
status=$?
set -e
[[ $status -ne 0 ]]
[[ -s "$root/restart-needed" ]]
: >"$TEST_LOG"
SERVICE_ACTIVE=0 run_case
grep -F 'systemctl --user restart open-design.service' "$TEST_LOG"
[[ ! -e "$root/restart-needed" ]]

# A stopped service stays stopped.
: >"$TEST_LOG"
SERVICE_ACTIVE=0 run_case
if grep -F 'restart open-design.service' "$TEST_LOG"; then
  printf 'stopped service was unexpectedly restarted\n' >&2
  exit 1
fi

# An in-place failed upgrade retains the old marker and durable guard.
printf '%s\n' old-release >"$root/successful-release"
printf '%s\n' old-release >"$root/source/.fake-head"
: >"$TEST_LOG"
set +e
export FAIL_STAGE=install
export SERVICE_ACTIVE=1
run_case >"$case_dir/fail.out" 2>"$case_dir/fail.err"
status=$?
unset FAIL_STAGE SERVICE_ACTIVE
set -e
[[ $status -ne 0 ]]
[[ $(<"$root/successful-release") == old-release ]]
[[ -s "$root/updating" ]]
grep -F 'release '"$rendered_tag"' dependency install failed' "$case_dir/fail.err"
if grep -F 'restart open-design.service' "$TEST_LOG"; then
  printf 'failed update unexpectedly restarted the service\n' >&2
  exit 1
fi

# A no-user-bus first install still builds and records success.
prepare_case no-bus
NO_USER_BUS=1 run_case >"$case_dir/no-bus.out" 2>"$case_dir/no-bus.err"
grep -F 'runtime reconciliation skipped' "$case_dir/no-bus.err"
[[ -s "$test_home/.local/share/open-design/successful-release" ]]

# Never follow a symlink at the managed parent boundary.
prepare_case unsafe-parent
mkdir -p "$case_dir/referent" "$test_home/.local/share"
ln -s "$case_dir/referent" "$test_home/.local/share/open-design"
set +e
run_case >"$case_dir/unsafe.out" 2>"$case_dir/unsafe.err"
status=$?
set -e
[[ $status -ne 0 ]]
grep -F 'managed parent is unsafe' "$case_dir/unsafe.err"
[[ -z $(find "$case_dir/referent" -mindepth 1 -print -quit) ]]

printf 'open-design provision tests passed\n'
