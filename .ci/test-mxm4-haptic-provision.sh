#!/usr/bin/env bash
set -euo pipefail

rendered=${1:?usage: test-mxm4-haptic-provision.sh RENDERED_PROVISIONER}
scratch_parent=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
mkdir -p -- "$scratch_parent"
chmod 0700 "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/mxm4-haptic-provision.XXXXXX")
chmod 0700 "$scratch"
trap 'rm -rf -- "$scratch"' EXIT

make_stub() {
  local path=$1
  shift
  cat >"$path"
  chmod 0755 "$path"
}

make_stubs() {
  local bin=$1
  mkdir -p -- "$bin"

  make_stub "$bin/vp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'vp %s\n' "$*" >>"$TEST_LOG"
case "$*" in
  'install --frozen-lockfile')
    # The workspace install must run from the workspace root, never the member.
    [[ ${PWD##*/} == packages ]] || exit 30
    [[ ${FAIL_STAGE:-} != plugin-deps ]] || exit 31
    ;;
  'run build:omp-plugin')
    [[ ${FAIL_STAGE:-} != plugin-build ]] || exit 31
    mkdir -p dist/omp-plugin
    printf '%s\n' "${PLUGIN_BYTES:-export default function plugin() { return {}; }}" >dist/omp-plugin/index.js
    ;;
  *) exit 32 ;;
esac
EOF

  make_stub "$bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'node %s\n' "$*" >>"$TEST_LOG"
case ${3-} in
  manifest) [[ ${FAIL_STAGE:-} != manifest ]] ;;
  artifact) [[ ${FAIL_STAGE:-} != plugin-artifact ]] ;;
  *) exit 33 ;;
esac
EOF

  make_stub "$bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_STAGE:-} != rust-build ]] || exit 41
target=
while (($#)); do
  if [[ $1 == --target-dir ]]; then target=$2; shift 2; else shift; fi
done
[[ -n $target ]] || exit 42
mkdir -p "$target/release"
for name in mxm4-hapticd mxm4-haptic; do
  printf '#!/bin/sh\nexit 0\n' >"$target/release/$name"
  chmod 0755 "$target/release/$name"
done
if [[ ${MXM4_HAPTIC_PLATFORM:-} == linux ]]; then
  printf '#!/bin/sh\nexit 0\n' >"$target/release/mxm4-haptic-notify"
  chmod 0755 "$target/release/mxm4-haptic-notify"
fi
[[ ${FAIL_STAGE:-} != rust-artifact ]] || rm -f "$target/release/mxm4-hapticd"
EOF

  make_stub "$bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install %s\n' "$*" >>"$TEST_LOG"
destination=${!#}
if [[ ${FAIL_STAGE:-} == atomic-install && $destination == "$HOME"/* ]]; then exit 51; fi
/usr/bin/install "$@"
EOF

  make_stub "$bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'readiness %s\n' "$2" >>"$TEST_LOG"
[[ ${FAIL_STAGE:-} != readiness ]]
EOF

  make_stub "$bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  make_stub "$bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemd-analyze %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_STAGE:-} != unit-validation ]] || exit 1
# Real `systemd-analyze verify` resolves ExecStart against the filesystem and
# rejects the unit when the program is absent, so a fresh host can only pass
# this check after the daemon binary has been installed.
unit=${!#}
while IFS= read -r line; do
  [[ $line == ExecStart=* ]] || continue
  program=${line#ExecStart=}
  program=${program//%h/$HOME}
  [[ -x $program ]] || {
    printf 'Command %s is not executable: No such file or directory\n' "$program" >&2
    exit 1
  }
done <"$unit"
EOF

  make_stub "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
active="$TEST_STATE/systemd-active"
enabled="$TEST_STATE/systemd-enabled"
count_file="$TEST_STATE/systemd-active-count"
case "$*" in
  '--user show-environment') [[ ${FAIL_STAGE:-} != manager-domain ]] ;;
  '--user daemon-reload') [[ ${FAIL_STAGE:-} != daemon-reload ]] ;;
  '--user enable mxm4-hapticd.service')
    [[ ${FAIL_STAGE:-} != enable ]] || exit 60
    : >"$enabled"
    ;;
  '--user start mxm4-hapticd.service')
    [[ ${FAIL_STAGE:-} != start ]] || exit 61
    : >"$active"
    ;;
  '--user restart mxm4-hapticd.service')
    [[ ${FAIL_STAGE:-} != restart ]] || exit 62
    : >"$active"
    ;;
  '--user is-enabled --quiet mxm4-hapticd.service')
    [[ ${FAIL_STAGE:-} != enabled-state ]] && [[ -f $enabled ]]
    ;;
  '--user is-active --quiet mxm4-hapticd.service')
    count=0; [[ ! -f $count_file ]] || count=$(<"$count_file"); count=$((count + 1)); printf '%s\n' "$count" >"$count_file"
    if [[ $count -eq 2 && ${FAIL_STAGE:-} == first-state ]]; then exit 63; fi
    if [[ $count -eq 3 && ${FAIL_STAGE:-} == second-state ]]; then exit 64; fi
    [[ -f $active ]]
    ;;
  '--user enable mxm4-haptic-notify.service') exit 0 ;;
  '--user is-active --quiet mxm4-haptic-notify.service') exit 1 ;;
  *) exit 65 ;;
esac
EOF

  # Stands in for an unactivated shell's mise: the build toolchain lives only
  # under `mise exec`, which also changes into the requested directory.
  make_stub "$bin/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == -C ]] || exit 90
directory=$2
shift 2
[[ ${1-} == exec && ${2-} == -- ]] || exit 91
shift 2
printf 'mise %s %s\n' "$directory" "$1" >>"$TEST_LOG"
cd "$directory"
exec "${MISE_TOOL_DIR:?mise tool directory is required}/$1" "${@:2}"
EOF

  make_stub "$bin/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'plutil %s\n' "$*" >>"$TEST_LOG"
[[ ${FAIL_STAGE:-} != plist-validation ]]
EOF

  make_stub "$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'launchctl %s\n' "$*" >>"$TEST_LOG"
loaded="$TEST_STATE/launch-loaded"
running="$TEST_STATE/launch-running"
disabled="$TEST_STATE/launch-disabled"
count_file="$TEST_STATE/launch-print-count"
case ${1-} in
  print)
    if [[ $2 == gui/* && $2 != */dev.h82.mxm4-hapticd ]]; then
      [[ ${FAIL_STAGE:-} != gui-domain ]]
      exit
    fi
    if [[ ! -f $loaded ]]; then exit 113; fi
    if [[ -f $running ]]; then
      count=0; [[ ! -f $count_file ]] || count=$(<"$count_file"); count=$((count + 1)); printf '%s\n' "$count" >"$count_file"
      if [[ $count -eq 1 && ${FAIL_STAGE:-} == first-state ]]; then printf 'state = waiting\n'; exit 0; fi
      if [[ $count -eq 2 && ${FAIL_STAGE:-} == second-state ]]; then printf 'state = waiting\n'; exit 0; fi
      printf 'state = running\n'
    else
      printf 'state = waiting\n'
    fi
    ;;
  print-disabled)
    printf 'disabled services = {\n'
    [[ ! -f $disabled ]] || printf '  "dev.h82.mxm4-hapticd" => true\n'
    printf '}\n'
    ;;
  bootout)
    [[ ${FAIL_STAGE:-} != bootout ]] || exit 71
    rm -f "$loaded" "$running"
    ;;
  enable)
    [[ ${FAIL_STAGE:-} != launch-enable ]] || exit 70
    rm -f "$disabled"
    ;;
  bootstrap)
    [[ ${FAIL_STAGE:-} != bootstrap ]] || exit 72
    [[ $2 == gui/* && $3 == "$HOME/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist" ]] || exit 73
    : >"$loaded"
    ;;
  kickstart)
    [[ ${FAIL_STAGE:-} != kickstart ]] || exit 74
    [[ $2 == -k && $3 == gui/*/dev.h82.mxm4-hapticd ]] || exit 75
    : >"$running"
    ;;
  *) exit 76 ;;
esac
EOF
}

prepare_case() {
  local name=$1 platform=$2
  case_dir="$scratch/$name"
  test_home="$case_dir/home"
  fake_bin="$case_dir/bin"
  test_source="$case_dir/source"
  runtime="$case_dir/runtime"
  TEST_LOG="$case_dir/commands.log"
  TEST_STATE="$case_dir/state"
  export TEST_LOG TEST_STATE
  clean_bin="$case_dir/clean_bin"
  mkdir -p "$test_home/.local/bin" \
    "$test_home/.local/share/omp-plugins/plugins/mxm4-haptic" \
    "$test_home/.config/systemd/user" "$test_home/Library/LaunchAgents" \
    "$test_source/packages/mxm4-haptic/src" "$test_source/crates/mxm4-haptic/src" \
    "$runtime" "$TEST_STATE" "$clean_bin"
  for p in /usr/bin/* /bin/*; do
    tool_name=${p##*/}
    if [[ $tool_name != mise && $tool_name != vp && $tool_name != cargo && $tool_name != node && ! -e "$clean_bin/$tool_name" ]]; then
      ln -s "$p" "$clean_bin/$tool_name" 2>/dev/null || true
    fi
  done
  printf '%s\n' '{"name":"@h82/omp-mxm4-haptic","type":"module","omp":{"extensions":["./dist/index.js"]}}' \
    >"$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/package.json"
  # Managed unit shape, including the %h-relative ExecStart that only resolves
  # once the provisioner has installed the binary.
  printf '%s\n' '[Service]' 'Type=exec' 'ExecStart=%h/.local/bin/mxm4-hapticd' \
    >"$test_home/.config/systemd/user/mxm4-hapticd.service"
  printf '%s\n' '[Service]' 'Type=simple' 'ExecStart=%h/.local/bin/mxm4-haptic-notify' \
    >"$test_home/.config/systemd/user/mxm4-haptic-notify.service"
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
    >"$test_home/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist"
  printf '%s\n' '[package]' 'name="mxm4-haptic"' 'version="0.0.0"' \
    >"$test_source/crates/mxm4-haptic/Cargo.toml"
  cp "$rendered" "$case_dir/provision.sh"
  chmod 0755 "$case_dir/provision.sh"
  : >"$TEST_LOG"
  make_stubs "$fake_bin"
  if [[ $platform == darwin ]]; then : >"$TEST_STATE/launch-loaded"; fi
}

assert_stage_clean() {
  local root path
  for root in "$runtime" "$test_home/.cache"; do
    for path in "$root"/mxm4-haptic.*; do
      [[ ! -d "$path" ]] || {
        printf 'staging directory leaked: %s\n' "$path" >&2
        return 1
      }
    done
  done
}

run_case() {
  local platform=$1 status
  if env HOME="$test_home" PATH="$fake_bin:$case_dir/clean_bin" \
    TEST_LOG="$TEST_LOG" TEST_STATE="$TEST_STATE" \
    MXM4_HAPTIC_SOURCE_ROOT="$test_source" MXM4_HAPTIC_PLATFORM="$platform" \
    MXM4_HAPTIC_READINESS_ATTEMPTS=1 XDG_RUNTIME_DIR="$runtime" TMPDIR="$runtime" \
    FAIL_STAGE="${FAIL_STAGE:-}" PLUGIN_BYTES="${PLUGIN_BYTES:-}" \
    MISE_TOOL_DIR="${MISE_TOOL_DIR:-}" \
    bash "$case_dir/provision.sh"; then
    status=0
  else
    status=$?
  fi
  assert_stage_clean || return
  return "$status"
}

assert_failed() {
  local platform=$1 stage=$2
  if [[ "$platform" == darwin && "$stage" == launch-enable ]]; then
    : >"$TEST_STATE/launch-disabled"
  fi
  set +e
  FAIL_STAGE=$stage run_case "$platform" >"$case_dir/$stage.out" 2>"$case_dir/$stage.err"
  status=$?
  set -e
  [[ $status -ne 0 ]] || { printf 'stage unexpectedly succeeded: %s/%s\n' "$platform" "$stage" >&2; exit 1; }
  assert_stage_clean
}

assert_no_manager_mutation() {
  if grep -E 'systemctl --user (daemon-reload|enable|start|restart)|launchctl (bootout|enable|bootstrap|kickstart)' "$TEST_LOG"; then
    printf 'manager mutated before the failure boundary\n' >&2
    exit 1
  fi
}

assert_no_live_install() {
  local line destination
  while IFS= read -r line; do
    destination=${line##* }
    if [[ $destination == "$test_home"/* ]]; then
      printf 'live files mutated before the failure boundary\n' >&2
      return 1
    fi
  done < <(grep '^install ' "$TEST_LOG" || true)
}

# Linux first convergence starts from a bare host, so the managed unit's
# ExecStart cannot resolve until the daemon binary exists. The provisioner must
# still validate both staged artifacts before installing anything, then verify
# the startup definition between the install and the first manager mutation —
# verifying it in preflight deadlocked a fresh host permanently (issue #158).
# It must also use the exact managed endpoint and perform only read-only manager
# checks plus readiness on a converged repeat.
prepare_case linux-success linux
run_case linux
artifact_line=$(grep -n 'node .* artifact$' "$TEST_LOG" | head -1 | cut -d: -f1)
rust_line=$(grep -n '^cargo ' "$TEST_LOG" | head -1 | cut -d: -f1)
daemon_install_line=$(grep -n "^install .*$test_home/.local/bin/mxm4-hapticd.new." "$TEST_LOG" | head -1 | cut -d: -f1)
verify_line=$(grep -n '^systemd-analyze .*mxm4-hapticd.service$' "$TEST_LOG" | head -1 | cut -d: -f1)
reload_line=$(grep -n 'systemctl --user daemon-reload' "$TEST_LOG" | head -1 | cut -d: -f1)
(( artifact_line < daemon_install_line && rust_line < daemon_install_line ))
(( daemon_install_line < verify_line && verify_line < reload_line ))
grep -F "readiness $runtime/mxm4-haptic.sock" "$TEST_LOG"
manager_count=$(grep -Ec 'systemctl --user (daemon-reload|enable mxm4-hapticd|start mxm4-hapticd|restart mxm4-hapticd)' "$TEST_LOG")
vp_count=$(grep -c '^vp ' "$TEST_LOG")
run_case linux
[[ $(grep -Ec 'systemctl --user (daemon-reload|enable mxm4-hapticd|start mxm4-hapticd|restart mxm4-hapticd)' "$TEST_LOG") -eq $manager_count ]]
[[ $(grep -c '^vp ' "$TEST_LOG") -eq $vp_count ]]
[[ -s "$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" ]]
[[ -x "$test_home/.local/bin/mxm4-hapticd" ]]

# Unchanged Linux artifacts repair stopped, disabled, and deleted manager state
# without rebuilding or reloading the manager.
: >"$TEST_LOG"
rm -f "$TEST_STATE/systemd-active" "$TEST_STATE/systemd-active-count"
run_case linux
grep -F 'systemctl --user start mxm4-hapticd.service' "$TEST_LOG"
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi
if grep -F 'systemctl --user daemon-reload' "$TEST_LOG"; then exit 1; fi
if grep -F 'systemctl --user enable mxm4-hapticd.service' "$TEST_LOG"; then exit 1; fi

: >"$TEST_LOG"
rm -f "$TEST_STATE/systemd-enabled" "$TEST_STATE/systemd-active-count"
run_case linux
grep -F 'systemctl --user enable mxm4-hapticd.service' "$TEST_LOG"
if grep -Eq 'systemctl --user (start|restart|daemon-reload) mxm4-hapticd.service' "$TEST_LOG"; then exit 1; fi
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi

: >"$TEST_LOG"
rm -f "$TEST_STATE/systemd-enabled" "$TEST_STATE/systemd-active" \
  "$TEST_STATE/systemd-active-count"
run_case linux
grep -F 'systemctl --user enable mxm4-hapticd.service' "$TEST_LOG"
grep -F 'systemctl --user start mxm4-hapticd.service' "$TEST_LOG"
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi
if grep -F 'systemctl --user daemon-reload' "$TEST_LOG"; then exit 1; fi

# Plugin-only drift updates bundle bytes without rebuilding or restarting the daemon.
plugin_stamp="$test_home/.local/share/omp-plugins/.mxm4-haptic-state/plugin"
daemon_stamp="$test_home/.local/share/omp-plugins/.mxm4-haptic-state/daemon-linux"
printf 'stale\n' >"$plugin_stamp"
: >"$TEST_LOG"
PLUGIN_BYTES='export default function changed() { return { changed: true }; }' run_case linux
[[ $(<"$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js") == *changed* ]]
if grep -q '^cargo ' "$TEST_LOG"; then exit 1; fi
if grep -Eq 'systemctl --user (daemon-reload|start mxm4-hapticd|restart mxm4-hapticd)' "$TEST_LOG"; then exit 1; fi

# Daemon/startup-only drift leaves plugin bytes untouched and reconciles the daemon.
plugin_digest=$(sha256sum "$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" | cut -d' ' -f1)
printf 'stale\n' >"$daemon_stamp"
: >"$TEST_LOG"
: >"$TEST_STATE/systemd-active"
rm -f "$TEST_STATE/systemd-active-count"
run_case linux
[[ $(sha256sum "$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" | cut -d' ' -f1) == "$plugin_digest" ]]
if grep -q '^vp ' "$TEST_LOG"; then exit 1; fi
grep -F 'systemctl --user restart mxm4-hapticd.service' "$TEST_LOG"
grep -F -- '--bin mxm4-hapticd --bin mxm4-haptic' "$TEST_LOG"
if grep -F -- '--bin mxm4-haptic-notify' "$TEST_LOG"; then exit 1; fi

# Notification-only drift rebuilds and reconciles only the optional bridge.
notify_stamp="$test_home/.local/share/omp-plugins/.mxm4-haptic-state/notify-linux"
printf 'stale\n' >"$notify_stamp"
: >"$TEST_LOG"
run_case linux
grep -q '^cargo ' "$TEST_LOG"
if grep -q '^vp ' "$TEST_LOG"; then exit 1; fi
if grep -Eq 'systemctl --user (start|restart) mxm4-hapticd.service' "$TEST_LOG"; then exit 1; fi
grep -F 'systemctl --user enable mxm4-haptic-notify.service' "$TEST_LOG"
grep -F -- '--bin mxm4-haptic-notify' "$TEST_LOG"
if grep -F -- '--bin mxm4-hapticd' "$TEST_LOG"; then exit 1; fi

# Every preflight/build/validation failure is fatal. Preflight and staged
# failures cannot touch live bytes or mutate either native manager.
for stage in manifest plugin-deps plugin-build plugin-artifact rust-build rust-artifact manager-domain; do
  prepare_case "linux-$stage" linux
  assert_failed linux "$stage"
  assert_no_manager_mutation
  assert_no_live_install
done

# An unactivated shell exposes the build toolchain only through mise. The
# provisioner must fall back to it and converge; without it and without mise the
# failure is fatal and touches nothing.
prepare_case linux-mise linux
mkdir -p "$case_dir/mise-tools"
for tool in vp cargo node; do mv "$fake_bin/$tool" "$case_dir/mise-tools/$tool"; done
MISE_TOOL_DIR="$case_dir/mise-tools"
run_case linux
MISE_TOOL_DIR=
grep -F "mise $test_source/packages vp" "$TEST_LOG"
grep -F "mise $test_source/packages/mxm4-haptic vp" "$TEST_LOG"
grep -F "mise $test_source/crates/mxm4-haptic cargo" "$TEST_LOG"
grep -F "mise $test_source node" "$TEST_LOG"
[[ -s "$test_home/.local/share/omp-plugins/plugins/mxm4-haptic/dist/index.js" ]]
[[ -x "$test_home/.local/bin/mxm4-hapticd" ]]

prepare_case linux-missing-vp linux
rm -f "$fake_bin/vp" "$fake_bin/mise"
set +e
run_case linux >"$case_dir/missing-vp.out" 2>"$case_dir/missing-vp.err"
status=$?
set -e
[[ $status -ne 0 ]]
grep -F 'preflight: vp is required' "$case_dir/missing-vp.err"
assert_no_manager_mutation
assert_no_live_install

# Post-validation failures remain fatal at their exact commit boundary. Unit
# validation now sits after the install, so it may replace inert binaries, but
# it must still precede every manager mutation.
for stage in atomic-install unit-validation daemon-reload enable start enabled-state first-state readiness second-state; do
  prepare_case "linux-$stage" linux
  assert_failed linux "$stage"
  if [[ $stage == atomic-install || $stage == unit-validation ]]; then assert_no_manager_mutation; fi
done

# macOS validates the plist and staged daemon before bootout, uses gui/$UID
# throughout, proves running/readiness/running, and performs no manager mutation
# on a converged repeat.
prepare_case mac-success darwin
run_case darwin
plutil_line=$(grep -n '^plutil ' "$TEST_LOG" | cut -d: -f1)
cargo_line=$(grep -n '^cargo ' "$TEST_LOG" | cut -d: -f1)
bootout_line=$(grep -n '^launchctl bootout ' "$TEST_LOG" | cut -d: -f1)
(( plutil_line < bootout_line && cargo_line < bootout_line ))
grep -F "launchctl bootstrap gui/$UID $test_home/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist" "$TEST_LOG"
grep -F "launchctl kickstart -k gui/$UID/dev.h82.mxm4-hapticd" "$TEST_LOG"
grep -F "readiness $runtime/mxm4-haptic.sock" "$TEST_LOG"
launch_mutations=$(grep -Ec '^launchctl (bootout|enable|bootstrap|kickstart)' "$TEST_LOG")
run_case darwin
[[ $(grep -Ec '^launchctl (bootout|enable|bootstrap|kickstart)' "$TEST_LOG") -eq $launch_mutations ]]

# Unchanged macOS artifacts repair stopped, disabled, and deleted LaunchAgent
# state without rebuilding.
: >"$TEST_LOG"
rm -f "$TEST_STATE/launch-running" "$TEST_STATE/launch-print-count"
run_case darwin
grep -F "launchctl kickstart -k gui/$UID/dev.h82.mxm4-hapticd" "$TEST_LOG"
if grep -Eq '^launchctl (enable|bootstrap|bootout) ' "$TEST_LOG"; then exit 1; fi
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi

: >"$TEST_LOG"
: >"$TEST_STATE/launch-disabled"
rm -f "$TEST_STATE/launch-print-count"
run_case darwin
grep -F "launchctl enable gui/$UID/dev.h82.mxm4-hapticd" "$TEST_LOG"
if grep -Eq '^launchctl (bootstrap|bootout|kickstart) ' "$TEST_LOG"; then exit 1; fi
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi

: >"$TEST_LOG"
rm -f "$TEST_STATE/launch-loaded" "$TEST_STATE/launch-running" \
  "$TEST_STATE/launch-print-count"
run_case darwin
grep -F "launchctl bootstrap gui/$UID $test_home/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist" "$TEST_LOG"
grep -F "launchctl kickstart -k gui/$UID/dev.h82.mxm4-hapticd" "$TEST_LOG"
if grep -Eq '^launchctl (enable|bootout) ' "$TEST_LOG"; then exit 1; fi
if grep -Eq '^(vp|cargo) ' "$TEST_LOG"; then exit 1; fi

for stage in plist-validation gui-domain plugin-deps plugin-build plugin-artifact rust-build rust-artifact; do
  prepare_case "mac-$stage" darwin
  assert_failed darwin "$stage"
  assert_no_manager_mutation
  assert_no_live_install
done
for stage in atomic-install bootout launch-enable bootstrap kickstart first-state readiness second-state; do
  prepare_case "mac-$stage" darwin
  assert_failed darwin "$stage"
  if [[ $stage == atomic-install ]]; then assert_no_manager_mutation; fi
done

# Managed endpoint fallback is forbidden: a literal /tmp TMPDIR fails before launchd mutation.
prepare_case mac-unmanaged-tmp darwin
set +e
env HOME="$test_home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$TEST_LOG" TEST_STATE="$TEST_STATE" \
  MXM4_HAPTIC_SOURCE_ROOT="$test_source" MXM4_HAPTIC_PLATFORM=darwin \
  MXM4_HAPTIC_READINESS_ATTEMPTS=1 TMPDIR=/tmp XDG_RUNTIME_DIR= \
  bash "$case_dir/provision.sh" >"$case_dir/tmp.out" 2>"$case_dir/tmp.err"
status=$?
set -e
[[ $status -ne 0 ]]
assert_stage_clean
assert_no_manager_mutation

printf '%s\n' 'mxm4-haptic provision fixture passed'
