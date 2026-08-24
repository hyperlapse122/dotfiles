#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_parent="${XDG_RUNTIME_DIR:-"$HOME/.cache"}"
mkdir -p -- "$scratch_parent"
chmod 0700 "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/cloud-provision-test.XXXXXX")
chmod 0700 "$scratch"
trap 'rm -rf -- "$scratch"' EXIT

rendered_input="${1:-}"
if [[ -n "$rendered_input" && -f "$rendered_input" ]]; then
  rendered_script="$scratch/provisioner.sh"
  cp "$rendered_input" "$rendered_script"
  chmod 0755 "$rendered_script"
else
  op_stub="$scratch/op-stub"
  mkdir -p "$op_stub"
  cat <<'EOF' > "$op_stub/op"
#!/usr/bin/env bash
case "$*" in
  *"op://Private/JPI Microsoft 365/Entra Client ID"*) printf 'mock-corporate-client-id' ;;
  *"op://Private/JPI Microsoft 365/Tenant ID"*) printf 'mock-corporate-tenant-id' ;;
  *"op://Private/JPI Microsoft 365/ICS URL"*) printf 'mock-corporate-ics-url' ;;
  *"op://Private/Microsoft Personal/ICS URL"*) printf 'mock-personal-ics-url' ;;
  *) printf 'mock-dummy-secret' ;;
esac
EOF
  chmod 0755 "$op_stub/op"
  empty_config="$scratch/empty.toml"
  : > "$empty_config"
  rendered_script="$scratch/provisioner.sh"
  PATH="$op_stub:$PATH" chezmoi \
    --config "$empty_config" \
    --source "$REPO_ROOT" \
    execute-template < "$REPO_ROOT/.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-cloud.sh.tmpl" > "$rendered_script"
  chmod 0755 "$rendered_script"
fi

sed -i 's/^[[:space:]]*FACT_DESKTOP=.*/  FACT_DESKTOP=kde/' "$rendered_script"

for forbidden in "mock-google-client-secret" "mock-personal-client-secret" "mock-corporate-client-secret" "mock-personal-ics-url" "mock-corporate-ics-url"; do
  if grep -qF "$forbidden" "$rendered_script"; then
    printf 'FAIL: rendered script contains secret or ICS URL: %s\n' "$forbidden" >&2
    exit 1
  fi
done

stubs_dir="$scratch/stubs"
mkdir -p "$stubs_dir"

cat <<'EOF' > "$stubs_dir/systemctl"
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${SYSTEMCTL_CALLS:-}" ]]; then
  printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
fi

state_dir="${SYSTEMCTL_STATE_DIR:-/tmp/systemctl-state}"
mkdir -p "$state_dir"

quiet=0
cmd=""
unit=""

for arg in "$@"; do
  case "$arg" in
    --user)
      ;;
    --quiet|-q)
      quiet=1
      ;;
    *)
      if [[ -z "$cmd" ]]; then
        cmd="$arg"
      elif [[ -z "$unit" ]]; then
        unit="$arg"
      fi
      ;;
  esac
done

normalize_unit() {
  local u="$1"
  if [[ "$u" != *.* ]]; then
    u="${u}.service"
  fi
  printf '%s' "$u"
}

case "$cmd" in
  show-environment)
    if [[ "${SYSTEMCTL_FAIL_BUS:-0}" == "1" ]]; then
      exit 1
    fi
    exit 0
    ;;
  daemon-reload)
    exit 0
    ;;
  is-enabled)
    u=$(normalize_unit "$unit")
    if [[ -f "$state_dir/$u.enabled" ]]; then
      [[ $quiet -eq 1 ]] || printf 'enabled\n'
      exit 0
    else
      [[ $quiet -eq 1 ]] || printf 'disabled\n'
      exit 1
    fi
    ;;
  is-active)
    u=$(normalize_unit "$unit")
    if [[ -f "$state_dir/$u.active" ]]; then
      [[ $quiet -eq 1 ]] || printf 'active\n'
      exit 0
    else
      [[ $quiet -eq 1 ]] || printf 'inactive\n'
      exit 3
    fi
    ;;
  enable)
    u=$(normalize_unit "$unit")
    touch "$state_dir/$u.enabled"
    exit 0
    ;;
  disable)
    u=$(normalize_unit "$unit")
    rm -f "$state_dir/$u.enabled"
    exit 0
    ;;
  start)
    u=$(normalize_unit "$unit")
    touch "$state_dir/$u.active"
    exit 0
    ;;
  stop)
    u=$(normalize_unit "$unit")
    rm -f "$state_dir/$u.active"
    exit 0
    ;;
  restart)
    u=$(normalize_unit "$unit")
    touch "$state_dir/$u.active"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "$stubs_dir/systemctl"

cat <<'EOF' > "$stubs_dir/kwriteconfig6"
#!/usr/bin/env python3
import configparser
import os
import sys

def main():
    args = sys.argv[1:]
    file = None
    group = None
    key = None
    delete = False
    value = None
    
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '--file' and i + 1 < len(args):
            file = args[i+1]
            i += 2
        elif arg == '--group' and i + 1 < len(args):
            group = args[i+1]
            i += 2
        elif arg == '--key' and i + 1 < len(args):
            key = args[i+1]
            i += 2
        elif arg == '--delete':
            delete = True
            i += 1
        else:
            if value is None:
                value = arg
            else:
                value += " " + arg
            i += 1

    if not file or not group:
        sys.exit(1)

    config_home = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
    if os.path.isabs(file) or file.startswith('./') or file.startswith('../'):
        filepath = os.path.abspath(file)
    else:
        filepath = os.path.join(config_home, file)

    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    
    cp = configparser.RawConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    if os.path.exists(filepath):
        cp.read(filepath, encoding='utf-8')

    if delete:
        if key:
            if cp.has_section(group):
                cp.remove_option(group, key)
                if not cp.options(group):
                    cp.remove_section(group)
        else:
            cp.remove_section(group)
    else:
        if not cp.has_section(group):
            cp.add_section(group)
        if key is not None and value is not None:
            cp.set(group, key, value)

    with open(filepath, 'w', encoding='utf-8') as f:
        cp.write(f, space_around_delimiters=False)
    sys.exit(0)

if __name__ == '__main__':
    main()
EOF
chmod 0755 "$stubs_dir/kwriteconfig6"

cat <<'EOF' > "$stubs_dir/kreadconfig6"
#!/usr/bin/env python3
import configparser
import os
import sys

def main():
    args = sys.argv[1:]
    file = None
    group = None
    key = None
    default = ""
    
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '--file' and i + 1 < len(args):
            file = args[i+1]
            i += 2
        elif arg == '--group' and i + 1 < len(args):
            group = args[i+1]
            i += 2
        elif arg == '--key' and i + 1 < len(args):
            key = args[i+1]
            i += 2
        elif arg == '--default' and i + 1 < len(args):
            default = args[i+1]
            i += 2
        else:
            i += 1

    if not file or not group or not key:
        sys.exit(1)

    config_home = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
    if os.path.isabs(file) or file.startswith('./') or file.startswith('../'):
        filepath = os.path.abspath(file)
    else:
        filepath = os.path.join(config_home, file)

    if not os.path.exists(filepath):
        print(default)
        sys.exit(0)

    cp = configparser.RawConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    cp.read(filepath, encoding='utf-8')

    if cp.has_section(group) and cp.has_option(group, key):
        print(cp.get(group, key))
    else:
        print(default)
    sys.exit(0)

if __name__ == '__main__':
    main()
EOF
chmod 0755 "$stubs_dir/kreadconfig6"

run_in_sandbox() {
  local home="$1" bin="$2" runtime="$3" calls="$4" state="$5" script="$6"
  shift 6
  env -i \
    HOME="$home" \
    PATH="$bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$runtime" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    SYSTEMCTL_CALLS="$calls" \
    SYSTEMCTL_STATE_DIR="$state" \
    USER="$(whoami)" \
    "$@" \
    bash "$script"
}

printf '=== Running Cloud Provisioning Test Suite ===\n'

# Scenario 1: Clean fresh-host apply (no tokens configured yet)
printf 'Scenario 1: Clean fresh-host apply (no tokens configured yet)... '
case1_dir="$scratch/scenario1"
case1_home="$case1_dir/home"
case1_bin="$case1_dir/bin"
case1_runtime="$case1_dir/runtime"
case1_state="$case1_dir/systemctl-state"
case1_calls="$case1_dir/systemctl.log"
mkdir -p "$case1_home/.config" "$case1_home/.local/share" "$case1_home/.local/state" "$case1_bin" "$case1_runtime" "$case1_state"
cp "$stubs_dir"/* "$case1_bin/"

run_in_sandbox "$case1_home" "$case1_bin" "$case1_runtime" "$case1_calls" "$case1_state" "$rendered_script" >"$case1_dir/stdout.log" 2>"$case1_dir/stderr.log"

[[ -d "$case1_home/Cloud/gdrive" ]] || { printf 'FAIL: gdrive dir missing\n' >&2; exit 1; }
[[ -d "$case1_home/Cloud/onedrive" ]] || { printf 'FAIL: onedrive dir missing\n' >&2; exit 1; }
[[ -d "$case1_home/Cloud/onedrive-corp" ]] || { printf 'FAIL: onedrive-corp dir missing\n' >&2; exit 1; }
[[ -d "$case1_home/.local/state/davmail" ]] || { printf 'FAIL: davmail state dir missing\n' >&2; exit 1; }

baloo_val=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$case1_home/.config/baloofilerc'); print(cp.get('General', 'exclude folders'))")
[[ "$baloo_val" == *"$case1_home/Cloud/gdrive/"* ]] || { printf 'FAIL: gdrive missing from baloo exclusions\n' >&2; exit 1; }
[[ "$baloo_val" == *"$case1_home/Cloud/onedrive/"* ]] || { printf 'FAIL: onedrive missing from baloo exclusions\n' >&2; exit 1; }
[[ "$baloo_val" == *"$case1_home/Cloud/onedrive-corp/"* ]] || { printf 'FAIL: onedrive-corp missing from baloo exclusions\n' >&2; exit 1; }

places_file="$case1_home/.local/share/user-places.xbel"
[[ -f "$places_file" ]] || { printf 'FAIL: user-places.xbel missing\n' >&2; exit 1; }
grep -F "file://$case1_home/Cloud/gdrive" "$places_file" >/dev/null || { printf 'FAIL: gdrive missing from places\n' >&2; exit 1; }
grep -F "file://$case1_home/Cloud/onedrive" "$places_file" >/dev/null || { printf 'FAIL: onedrive missing from places\n' >&2; exit 1; }
grep -F "file://$case1_home/Cloud/onedrive-corp" "$places_file" >/dev/null || { printf 'FAIL: onedrive-corp missing from places\n' >&2; exit 1; }

thumb_val=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$case1_home/.config/kdeglobals'); print(cp.get('PreviewSettings', 'MaximumRemoteSize'))")
[[ "$thumb_val" == "0" ]] || { printf 'FAIL: MaximumRemoteSize != 0\n' >&2; exit 1; }

if grep -Eq '(enable|start) (rclone-mount|davmail)' "$case1_calls"; then
  printf 'FAIL: unauthenticated services were enabled or started\n' >&2
  exit 1
fi
printf 'PASS\n'

# Scenario 2: Active no-op / idempotency on second run
printf 'Scenario 2: Active no-op / idempotency on second run... '
calls_count_before=$(wc -l < "$case1_calls")
baloo_md5_before=$(md5sum "$case1_home/.config/baloofilerc" | cut -d' ' -f1)
places_md5_before=$(md5sum "$places_file" | cut -d' ' -f1)
kdeglobals_md5_before=$(md5sum "$case1_home/.config/kdeglobals" | cut -d' ' -f1)

run_in_sandbox "$case1_home" "$case1_bin" "$case1_runtime" "$case1_calls" "$case1_state" "$rendered_script" >"$case1_dir/stdout2.log" 2>"$case1_dir/stderr2.log"

tail -n +"$((calls_count_before + 1))" "$case1_calls" > "$case1_dir/calls_run2.log"
if grep -Eq '(enable|disable|start|stop) ' "$case1_dir/calls_run2.log"; then
  printf 'FAIL: redundant service mutations on idempotent run\n' >&2
  exit 1
fi

baloo_md5_after=$(md5sum "$case1_home/.config/baloofilerc" | cut -d' ' -f1)
places_md5_after=$(md5sum "$places_file" | cut -d' ' -f1)
kdeglobals_md5_after=$(md5sum "$case1_home/.config/kdeglobals" | cut -d' ' -f1)

[[ "$baloo_md5_before" == "$baloo_md5_after" ]] || { printf 'FAIL: baloofilerc modified on idempotent run\n' >&2; exit 1; }
[[ "$places_md5_before" == "$places_md5_after" ]] || { printf 'FAIL: user-places.xbel modified on idempotent run\n' >&2; exit 1; }
[[ "$kdeglobals_md5_before" == "$kdeglobals_md5_after" ]] || { printf 'FAIL: kdeglobals modified on idempotent run\n' >&2; exit 1; }
printf 'PASS\n'

# Scenario 3: Authenticated accounts apply
printf 'Scenario 3: Authenticated accounts apply... '
case3_dir="$scratch/scenario3"
case3_home="$case3_dir/home"
case3_bin="$case3_dir/bin"
case3_runtime="$case3_dir/runtime"
case3_state="$case3_dir/systemctl-state"
case3_calls="$case3_dir/systemctl.log"
mkdir -p "$case3_home/.config/rclone" "$case3_home/.local/share" "$case3_home/.local/state/davmail" "$case3_home/.config/akonadi" "$case3_bin" "$case3_runtime" "$case3_state"
cp "$stubs_dir"/* "$case3_bin/"

cat <<'EOF' > "$case3_home/.config/rclone/rclone.conf"
[gdrive]
type = drive
token = {"access_token":"mock-token-gdrive"}

[onedrive]
type = onedrive
token = {"access_token":"mock-token-onedrive"}

[onedrive-corp]
type = onedrive
token = {"access_token":"mock-token-onedrive-corp"}
EOF

printf 'davmail.oauth.token=mock-corp\n' > "$case3_home/.local/state/davmail/corporate-tokens.properties"
printf 'davmail.oauth.token=mock-pers\n' > "$case3_home/.local/state/davmail/personal-tokens.properties"

touch "$case3_home/.config/akonadi/agent_config_akonadi_davgroupware_resource_corporate"
touch "$case3_home/.config/akonadi/agent_config_akonadi_davgroupware_resource_personal"
chmod 0644 "$case3_home/.config/akonadi/agent_config_akonadi_davgroupware_resource_corporate"
chmod 0644 "$case3_home/.config/akonadi/agent_config_akonadi_davgroupware_resource_personal"

run_in_sandbox "$case3_home" "$case3_bin" "$case3_runtime" "$case3_calls" "$case3_state" "$rendered_script" >"$case3_dir/stdout.log" 2>"$case3_dir/stderr.log"

for unit in "rclone-mount@gdrive.service" "rclone-mount@onedrive.service" "rclone-mount@onedrive-corp.service" "davmail@corporate.service" "davmail@personal.service"; do
  [[ -f "$case3_state/$unit.enabled" ]] || { printf 'FAIL: %s not enabled\n' "$unit" >&2; exit 1; }
  [[ -f "$case3_state/$unit.active" ]] || { printf 'FAIL: %s not active\n' "$unit" >&2; exit 1; }
done

agentsrc="$case3_home/.config/akonadi/agentsrc"
[[ -f "$agentsrc" ]] || { printf 'FAIL: agentsrc missing\n' >&2; exit 1; }
corp_agent=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_davgroupware_resource_corporate', fallback=''))")
pers_agent=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_davgroupware_resource_personal', fallback=''))")
[[ "$corp_agent" == "akonadi_davgroupware_resource" ]] || { printf 'FAIL: corporate dav agent not in Instances\n' >&2; exit 1; }
[[ "$pers_agent" == "akonadi_davgroupware_resource" ]] || { printf 'FAIL: personal dav agent not in Instances\n' >&2; exit 1; }

corp_perm=$(stat -c '%a' "$case3_home/.config/akonadi/agent_config_akonadi_davgroupware_resource_corporate")
[[ "$corp_perm" == "600" ]] || { printf 'FAIL: agent config perm %s != 600\n' "$corp_perm" >&2; exit 1; }
printf 'PASS\n'

# Scenario 4: Mode switch to read-only
printf 'Scenario 4: Mode switch to read-only... '
readonly_script="$case3_dir/readonly_script.sh"
sed -e 's/"corporate:bridge"/"corporate:read-only"/' \
    -e 's/reconcile_ms_account "corporate" "bridge"/reconcile_ms_account "corporate" "read-only"/' \
    -e 's/local corp_mode="bridge"/local corp_mode="read-only"/' \
    "$rendered_script" > "$readonly_script"
chmod 0755 "$readonly_script"

run_in_sandbox "$case3_home" "$case3_bin" "$case3_runtime" "$case3_calls" "$case3_state" "$readonly_script" >"$case3_dir/stdout_ro.log" 2>"$case3_dir/stderr_ro.log"

[[ ! -f "$case3_state/davmail@corporate.service.active" ]] || { printf 'FAIL: davmail@corporate still active\n' >&2; exit 1; }
[[ ! -f "$case3_state/davmail@corporate.service.enabled" ]] || { printf 'FAIL: davmail@corporate still enabled\n' >&2; exit 1; }

[[ ! -f "$case3_home/.local/state/davmail/corporate-tokens.properties" ]] || { printf 'FAIL: corporate-tokens.properties not moved\n' >&2; exit 1; }
archive_count=$(find "$case3_home/.local/state/davmail/archive" -name "corporate-tokens-retired-*.properties" | wc -l)
[[ $archive_count -ge 1 ]] || { printf 'FAIL: retired token file missing from archive\n' >&2; exit 1; }

corp_dav_after=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_davgroupware_resource_corporate', fallback=''))")
corp_ical_after=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_ical_resource_corporate', fallback=''))")
[[ -z "$corp_dav_after" ]] || { printf 'FAIL: corporate dav agent still in Instances\n' >&2; exit 1; }
[[ "$corp_ical_after" == "akonadi_ical_resource" ]] || { printf 'FAIL: corporate ical agent not in Instances\n' >&2; exit 1; }
printf 'PASS\n'

# Scenario 5: Mode switch read-only -> bridge
printf 'Scenario 5: Mode switch read-only -> bridge... '
printf 'davmail.oauth.token=mock-corp-restored\n' > "$case3_home/.local/state/davmail/corporate-tokens.properties"

run_in_sandbox "$case3_home" "$case3_bin" "$case3_runtime" "$case3_calls" "$case3_state" "$rendered_script" >"$case3_dir/stdout_bridge.log" 2>"$case3_dir/stderr_bridge.log"

[[ -f "$case3_state/davmail@corporate.service.enabled" ]] || { printf 'FAIL: davmail@corporate not re-enabled\n' >&2; exit 1; }
[[ -f "$case3_state/davmail@corporate.service.active" ]] || { printf 'FAIL: davmail@corporate not re-activated\n' >&2; exit 1; }

corp_dav_restored=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_davgroupware_resource_corporate', fallback=''))")
corp_ical_restored=$(python3 -c "import configparser; cp = configparser.RawConfigParser(); cp.optionxform=str; cp.read('$agentsrc'); print(cp.get('Instances', 'akonadi_ical_resource_corporate', fallback=''))")
[[ "$corp_dav_restored" == "akonadi_davgroupware_resource" ]] || { printf 'FAIL: corporate dav agent not restored in Instances\n' >&2; exit 1; }
[[ -z "$corp_ical_restored" ]] || { printf 'FAIL: corporate ical agent still in Instances\n' >&2; exit 1; }
printf 'PASS\n'

# Scenario 6: Malformed user-places.xbel fail-closed
printf 'Scenario 6: Malformed user-places.xbel fail-closed... '
case6_dir="$scratch/scenario6"
case6_home="$case6_dir/home"
case6_bin="$case6_dir/bin"
case6_runtime="$case6_dir/runtime"
case6_state="$case6_dir/systemctl-state"
case6_calls="$case6_dir/systemctl.log"
mkdir -p "$case6_home/.local/share" "$case6_bin" "$case6_runtime" "$case6_state"
cp "$stubs_dir"/* "$case6_bin/"

malformed_xbel="$case6_home/.local/share/user-places.xbel"
corrupt_content="<<<CORRUPT NON-XML CONTENT>>>"
printf '%s\n' "$corrupt_content" > "$malformed_xbel"

set +e
run_in_sandbox "$case6_home" "$case6_bin" "$case6_runtime" "$case6_calls" "$case6_state" "$rendered_script" >"$case6_dir/stdout.log" 2>"$case6_dir/stderr.log"
exit_code=$?
set -e

[[ $exit_code -ne 0 ]] || { printf 'FAIL: expected non-zero exit on malformed xbel, got 0\n' >&2; exit 1; }
[[ -f "$malformed_xbel" ]] || { printf 'FAIL: malformed xbel deleted\n' >&2; exit 1; }
[[ $(cat "$malformed_xbel") == "$corrupt_content" ]] || { printf 'FAIL: malformed xbel overwritten with 0 bytes or corrupted\n' >&2; exit 1; }
printf 'PASS\n'

# Scenario 7: Non-KDE skip
printf 'Scenario 7: Non-KDE skip... '
case7_dir="$scratch/scenario7"
case7_home="$case7_dir/home"
case7_bin="$case7_dir/bin"
case7_runtime="$case7_dir/runtime"
case7_state="$case7_dir/systemctl-state"
case7_calls="$case7_dir/systemctl.log"
mkdir -p "$case7_home" "$case7_bin" "$case7_runtime" "$case7_state"
cp "$stubs_dir"/* "$case7_bin/"

nonkde_script="$case7_dir/nonkde_script.sh"
sed 's/^[[:space:]]*FACT_DESKTOP=.*/  FACT_DESKTOP=gnome/' "$rendered_script" > "$nonkde_script"
chmod 0755 "$nonkde_script"

run_in_sandbox "$case7_home" "$case7_bin" "$case7_runtime" "$case7_calls" "$case7_state" "$nonkde_script" >"$case7_dir/stdout.log" 2>"$case7_dir/stderr.log"

grep -F "plasmashell not found (non-KDE system), skipping." "$case7_dir/stdout.log" >/dev/null || {
  printf 'FAIL: skip declaration message missing from output\n' >&2
  exit 1
}

[[ ! -d "$case7_home/Cloud" ]] || { printf 'FAIL: Cloud directory created on non-KDE host\n' >&2; exit 1; }
[[ ! -f "$case7_calls" || ! -s "$case7_calls" ]] || { printf 'FAIL: systemctl called on non-KDE host\n' >&2; exit 1; }
[[ ! -d "$case7_home/.config" ]] || { printf 'FAIL: .config created on non-KDE host\n' >&2; exit 1; }
printf 'PASS\n'

printf '\nAll cloud provisioning test scenarios passed successfully.\n'
exit 0
