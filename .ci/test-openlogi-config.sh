#!/usr/bin/env bash
# Fixture test for OpenLogi configuration assertion (plan U3 / KTD3).
# Covers:
#   1. Fresh create: config.toml created with declared keys; agent enabled and started.
#   2. Drift re-assert (AE2): declared keys updated; undeclared GUI keys/tables preserved byte-identical.
#   3. Agent-active ordering: active agent is stopped before reconcile and restarted after.
#   4. Failure trap: reconciler failure with active agent triggers EXIT trap restart.
#   5. Container gate: skips execution cleanly without touching services.
#   6. Darwin (macOS): clean config assertion without systemd dependencies.
#   7. Reconciler validation: incompatible contracts or missing binary fail with diagnostic.
#   8. Render verification: renders correctly on Linux/macOS, empty on Windows/containers.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
script_tmpl=".chezmoiscripts/70-agents/run_after_config-openlogi.sh.tmpl"

fail() {
  printf '::error::test-openlogi-config: %s\n' "$*" >&2
  exit 1
}

[[ -f "$repo_root/$script_tmpl" ]] || fail "missing template: $script_tmpl"
[[ -f "$repo_root/.chezmoidata/openlogi.yaml" ]] || fail "missing data: .chezmoidata/openlogi.yaml"

scratch_parent=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
mkdir -p -- "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/openlogi-test.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

destination="$scratch/destination"
home_dir="$scratch/home"
stub_bin="$scratch/bin"
stub_log="$scratch/systemctl.log"
render_toml="$scratch/render.toml"
: > "$render_toml"

mkdir -p "$destination" "$home_dir" "$stub_bin"

bun_bin=$(command -v bun || true)
[[ -n "$bun_bin" ]] || fail "bun is required for settings-reconcile CLI fixture execution"
ln -sf "$bun_bin" "$stub_bin/bun"

cat >"$stub_bin/op" <<'STUB'
#!/usr/bin/env bash
case "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac
STUB
chmod 0700 "$stub_bin/op"

cat >"$stub_bin/settings-reconcile" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "settings" && "\${RECONCILER_FAIL:-0}" == "1" ]]; then
  printf 'settings-reconcile: simulated failure\n' >&2
  exit 1
fi
if [[ "\${RECONCILER_BAD_CONTRACT:-0}" == "1" ]]; then
  printf '{"settings":"settings-reconcile/v999"}\n'
  exit 0
fi
exec "$stub_bin/bun" run "$repo_root/packages/settings-reconcile/src/cli.ts" "\$@"
EOF
chmod 0755 "$stub_bin/settings-reconcile"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
log="${SYSTEMCTL_LOG:-}"
if [[ -n "$log" ]]; then
  printf '%s\n' "$*" >> "$log"
fi
case "${1:-}" in
  --user)
    shift
    cmd="${1:-}"
    shift
    case "$cmd" in
      is-active)
        if [[ "${SYSTEMCTL_ACTIVE:-0}" == "1" ]]; then
          exit 0
        else
          exit 1
        fi
        ;;
      is-enabled)
        if [[ "${SYSTEMCTL_ENABLED:-0}" == "1" ]]; then
          exit 0
        else
          exit 1
        fi
        ;;
      enable|stop|start|restart)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod 0755 "$stub_bin/systemctl"

chezmoi_bin=$(command -v chezmoi)

# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

render_script() {
  local os="${1:-linux}"
  local out="$scratch/rendered-$os.sh"
  
  local -a data_args=()
  if [[ "$os" == "linux" ]]; then
    data_args=(--override-data "{\"chezmoi\":{\"os\":\"linux\",\"homeDir\":\"$home_dir\",\"osRelease\":{\"id\":\"fedora\"}}}")
  elif [[ "$os" == "darwin" ]]; then
    data_args=(--override-data "{\"chezmoi\":{\"os\":\"darwin\",\"homeDir\":\"$home_dir\",\"osRelease\":{\"id\":\"macos\"}}}")
  elif [[ "$os" == "windows" ]]; then
    data_args=(--override-data '{"chezmoi":{"os":"windows","homeDir":"C:\\Users\\h82"}}')
  fi
  
  env HOME="$home_dir" PATH="$stub_bin:/usr/bin:/bin" "$chezmoi_bin" \
    --config "$render_toml" --source "$repo_root" --destination "$destination" \
    "${data_args[@]}" execute-template < "$repo_root/$script_tmpl" > "$out"
  
  printf '%s' "$out"
}

rendered_linux=$(render_script linux)
[[ -s "$rendered_linux" ]] || fail "linux render is empty"
bash -n "$rendered_linux" || fail "linux render syntax error"

rendered_darwin=$(render_script darwin)
[[ -s "$rendered_darwin" ]] || fail "darwin render is empty"
bash -n "$rendered_darwin" || fail "darwin render syntax error"

# Scenario 8: Render verification (Windows & container must be empty)
rendered_windows=$(render_script windows)
[[ ! -s "$rendered_windows" ]] || fail "windows render must be empty"

rendered_container="$scratch/rendered-container.sh"
render_reconciler "$repo_root" "$scratch" "$chezmoi_bin" linux true "$script_tmpl" "$rendered_container"
[[ ! -s "$rendered_container" ]] || fail "container render must be empty"

run_rendered() {
  local script_path="$1"
  local stdout="$scratch/test.stdout"
  local stderr="$scratch/test.stderr"
  env -i \
    HOME="$home_dir" \
    PATH="$stub_bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$scratch/runtime" \
    SYSTEMCTL_LOG="$stub_log" \
    SYSTEMCTL_ACTIVE="${SYSTEMCTL_ACTIVE:-0}" \
    SYSTEMCTL_ENABLED="${SYSTEMCTL_ENABLED:-0}" \
    RECONCILER_FAIL="${RECONCILER_FAIL:-0}" \
    RECONCILER_BAD_CONTRACT="${RECONCILER_BAD_CONTRACT:-0}" \
    OPENLOGI_TEST_CONTAINER="${OPENLOGI_TEST_CONTAINER:-0}" \
    bash "$script_path" >"$stdout" 2>"$stderr"
}

reset_fixture() {
  rm -rf -- "$home_dir" "$scratch/runtime"
  mkdir -p "$home_dir/.config" "$scratch/runtime"
  : > "$stub_log"
}

# --- Scenario 1: Fresh create ---
reset_fixture
SYSTEMCTL_ACTIVE=0 SYSTEMCTL_ENABLED=0 run_rendered "$rendered_linux"
target_toml="$home_dir/.config/openlogi/config.toml"
[[ -f "$target_toml" ]] || fail "scenario 1: config.toml was not created"
grep -qF 'launch_at_login = true' "$target_toml" || fail "scenario 1: missing launch_at_login"
grep -qF 'check_for_updates = true' "$target_toml" || fail "scenario 1: missing check_for_updates"
grep -qF -- '--user enable openlogi-agent.service' "$stub_log" || fail "scenario 1: service was not enabled"
grep -qF -- '--user start openlogi-agent.service' "$stub_log" || fail "scenario 1: service was not started"

# --- Scenario 2: Drift re-assert (AE2) ---
reset_fixture
mkdir -p "$home_dir/.config/openlogi"
cat >"$target_toml" <<'TOML'
[app_settings]
check_for_updates = false
launch_at_login = false
show_in_menu_bar = false

[receiver.123456789abc.slot.1]
model_id = "B023"
name = "MX Master 3S"
TOML
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_ENABLED=1 run_rendered "$rendered_linux"
grep -qF 'launch_at_login = true' "$target_toml" || fail "scenario 2: launch_at_login not re-asserted"
grep -qF 'check_for_updates = true' "$target_toml" || fail "scenario 2: check_for_updates not re-asserted"
grep -qF 'show_in_menu_bar = false' "$target_toml" || fail "scenario 2: undeclared show_in_menu_bar lost"
grep -qF '[receiver.123456789abc.slot.1]' "$target_toml" || fail "scenario 2: undeclared receiver table lost"
grep -qF 'name = "MX Master 3S"' "$target_toml" || fail "scenario 2: undeclared device name lost"
grep -qF 'model_id = "B023"' "$target_toml" || fail "scenario 2: undeclared device model_id lost"

# --- Scenario 3: Agent-active ordering ---
reset_fixture
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_ENABLED=1 run_rendered "$rendered_linux"
grep -qF -- '--user is-active --quiet openlogi-agent.service' "$stub_log" || fail "scenario 3: active probe missing"
grep -qF -- '--user stop openlogi-agent.service' "$stub_log" || fail "scenario 3: stop missing"
grep -qF -- '--user start openlogi-agent.service' "$stub_log" || fail "scenario 3: start missing"
stop_line=$(grep -nF -- '--user stop openlogi-agent.service' "$stub_log" | head -n1 | cut -d: -f1)
start_line=$(grep -nF -- '--user start openlogi-agent.service' "$stub_log" | tail -n1 | cut -d: -f1)
[[ $stop_line -lt $start_line ]] || fail "scenario 3: stop did not precede start"

# --- Scenario 4: Failure trap ---
reset_fixture
set +e
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_ENABLED=1 RECONCILER_FAIL=1 run_rendered "$rendered_linux"
exit_status=$?
set -e
[[ $exit_status -ne 0 ]] || fail "scenario 4: script unexpectedly succeeded on reconciler failure"
grep -qF -- '--user stop openlogi-agent.service' "$stub_log" || fail "scenario 4: stop missing"
grep -qF -- '--user start openlogi-agent.service' "$stub_log" || fail "scenario 4: trap restart missing"
stop_line=$(grep -nF -- '--user stop openlogi-agent.service' "$stub_log" | head -n1 | cut -d: -f1)
restart_line=$(grep -nF -- '--user start openlogi-agent.service' "$stub_log" | tail -n1 | cut -d: -f1)
[[ $stop_line -lt $restart_line ]] || fail "scenario 4: trap restart did not follow stop"

# --- Scenario 5: Container gate ---
reset_fixture
OPENLOGI_TEST_CONTAINER=1 run_rendered "$rendered_linux"
[[ ! -s "$stub_log" ]] || fail "scenario 5: container run must not touch systemctl"
[[ ! -f "$target_toml" ]] || fail "scenario 5: container run must not write config.toml"

# --- Scenario 6: Darwin (macOS) ---
reset_fixture
# On darwin, systemctl is absent; script asserts config into config.toml
env -i \
  HOME="$home_dir" \
  PATH="/usr/bin:/bin" \
  SETTINGS_RECONCILER_BIN="$stub_bin/settings-reconcile" \
  XDG_RUNTIME_DIR="$scratch/runtime" \
  bash "$rendered_darwin"
[[ -f "$target_toml" ]] || fail "scenario 6: darwin failed to create config.toml"
grep -qF 'launch_at_login = true' "$target_toml" || fail "scenario 6: darwin missing launch_at_login"

# --- Scenario 7: Reconciler contract validation & missing binary ---
reset_fixture
set +e
RECONCILER_BAD_CONTRACT=1 run_rendered "$rendered_linux"
contract_status=$?
set -e
[[ $contract_status -ne 0 ]] || fail "scenario 7: bad contract unexpectedly succeeded"
grep -qF 'incompatible settings contract' "$scratch/test.stderr" || fail "scenario 7: missing bad contract diagnostic"

reset_fixture
set +e
env -i \
  HOME="$home_dir" \
  PATH="/usr/bin:/bin" \
  XDG_RUNTIME_DIR="$scratch/runtime" \
  bash "$rendered_linux" >"$scratch/test.stdout" 2>"$scratch/test.stderr"
missing_status=$?
set -e
[[ $missing_status -ne 0 ]] || fail "scenario 7: missing reconciler unexpectedly succeeded"
grep -qF 'settings-reconcile is unavailable' "$scratch/test.stderr" || fail "scenario 7: missing reconciler diagnostic"

printf '%s\n' 'openlogi config assertion fixture tests passed'
