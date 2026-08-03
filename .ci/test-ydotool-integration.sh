#!/usr/bin/env bash
# .ci/test-ydotool-integration.sh
#
# Isolated integration coverage for the ydotool Linux provisioning plan (U4):
# desktop-gated package membership + distro service cutover (U1), active-seat
# udev least privilege (U2), and the managed graphical-session runtime — unit,
# active-seat wrapper, and reconciler (U3). Everything renders through
# `chezmoi execute-template` against an empty config and a scratch
# destination, or executes an EXTRACTED/SUBSTITUTED copy of a production
# script against scratch stubs. Never runs a live `chezmoi apply`, starts the
# real ydotool.service, calls a real systemctl/ydotoold, touches live /etc,
# mutates a real group, or injects synthetic input.
#
# Desktop and distro facts are forced two different ways, matching how
# .chezmoitemplates/facts.tmpl actually resolves them:
#   desktop   — no `.chezmoi.*` builtin reaches it; it comes from
#               `lookPath "plasmashell"|"gnome-shell"`, so this harness scopes
#               PATH to a scratch bin dir holding only a stub for the desired
#               shell (or neither, for "none"). lookPath is chezmoi's own
#               native PATH scan — it needs no other binary on that PATH.
#   distro    — `--override-data '{"chezmoi":{"osRelease":{"id":...}}}'`.
#   headless  — a `probe: hook` fact read from a REAL file at
#               ${XDG_CACHE_HOME:-~/.cache}/chezmoi/facts.yaml (the
#               read-source-state.pre hook's cache), never reachable through
#               override-data. This harness points XDG_CACHE_HOME at a
#               scratch cache holding a fabricated `headless: false` line for
#               the eligible branch, or an empty scratch dir (no file — the
#               documented fail-safe default, headless=true) otherwise.
#   container — only a real /run/.containerenv or /.dockerenv marker (minus
#               /run/.toolboxenv) can flip it; see the YDOTOOL_TEST_EXPECT
#               dispatch at the bottom, driven by the CI job that briefly
#               creates the real marker with a cleanup trap.
#
# Run modes (the <TOOL>_TEST_EXPECT convention shared by the CI
# container-fact render jobs):
#   YDOTOOL_TEST_EXPECT unset or "host" — full battery, including the
#     eligible-render assertions, which assume this host is not itself a
#     container (true for a dev workstation or a GH Actions VM runner).
#   YDOTOOL_TEST_EXPECT=container — skips the eligible-render assertions
#     (invalid once a real container marker exists) and instead proves the
#     REAL container fact gates out an otherwise-eligible combination. The
#     caller owns creating/removing the real marker file.

set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "test-ydotool-integration: must not run as root (the wrapper scenarios simulate device access with real permission bits, which root bypasses)" >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ydotool-integration.XXXXXX")

wrapper_pid=""
cleanup() {
  if [[ -n "$wrapper_pid" ]]; then
    kill -TERM "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

command -v chezmoi >/dev/null 2>&1 || {
  echo "test-ydotool-integration: chezmoi is required" >&2
  exit 1
}
chezmoi_bin=$(command -v chezmoi)

fail()     { echo "FAIL: $*" >&2; exit 1; }
has()      { grep -qE -- "$1" "$2" || fail "$3"; }
lacks()    { if grep -qE -- "$1" "$2"; then fail "$3"; fi; }
has_line() { grep -qFx -- "$1" "$2" || fail "$3"; }

: >"$scratch/empty.toml"
mkdir -p "$scratch/target"
render() {
  "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
    --destination "$scratch/target" "$@" execute-template
}

# Deterministic bounded wait: polls a test command every 0.1s, up to 5s.
wait_until() {
  local desc=$1; shift
  local _i
  for _i in $(seq 1 50); do
    "$@" && return 0
    sleep 0.1
  done
  fail "timed out (5s) waiting for: $desc"
}

# --- desktop PATH stubs: lookPath sees ONLY what is on this scoped PATH ----
mkdir -p "$scratch/path-kde" "$scratch/path-gnome" "$scratch/path-none"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/path-kde/plasmashell"
chmod +x "$scratch/path-kde/plasmashell"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/path-gnome/gnome-shell"
chmod +x "$scratch/path-gnome/gnome-shell"

# --- headless hook-fact cache: fabricate the read-source-state.pre hook's
# cache file directly, matching write_facts_cache's shape (comment lines then
# `<name>: true|false`) so facts.tmpl's regex-guarded parse accepts it. ------
mkdir -p "$scratch/cache-desktop/chezmoi" "$scratch/cache-headless/chezmoi"
cat >"$scratch/cache-desktop/chezmoi/facts.yaml" <<'EOF'
# fabricated hook cache: a non-headless desktop host
nvidia: false
intelGpu: false
vm: false
virt: false
headless: false
EOF
# cache-headless/chezmoi/ deliberately holds no facts.yaml: headless falls
# back to its registry absentDefault (true), the documented fail-safe.

fedora_ov='{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}'
ubuntu_ov='{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu"}}}'

fedora_installer="$repo_root/.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl"
ubuntu_installer="$repo_root/.chezmoiscripts/40-linux-ubuntu/run_onchange_before_ubuntu.sh.tmpl"
reconciler_tmpl="$repo_root/.chezmoiscripts/30-linux/run_after_config-ydotool.sh.tmpl"
unit_file="$repo_root/dot_config/systemd/user/ydotool.service"
wrapper_src="$repo_root/dot_local/libexec/executable_ydotoold-active-seat"
ignore_file="$repo_root/.chezmoiignore"
rules_70="$repo_root/system/linux/etc/udev/rules.d/70-uinput-solaar.rules"
rules_80="$repo_root/system/linux/etc/udev/rules.d/80-uinput.rules"
packages_yaml="$repo_root/.chezmoidata/packages.yaml"

for f in "$fedora_installer" "$ubuntu_installer" "$reconciler_tmpl" "$unit_file" \
  "$wrapper_src" "$ignore_file" "$rules_70" "$rules_80" "$packages_yaml"; do
  [[ -f "$f" ]] || fail "expected managed source file is missing: $f"
done
ignore_hit_count() {
  grep -cE 'ydotoold-active-seat|systemd/user/ydotool\.service|config-ydotool\.sh' "$1" || true
}

eligibility_positive() {  # $1=override json $2=path dir $3=label
  local ov=$1 pathdir=$2 label=$3
  local ignore_out="$scratch/ignore-$label.txt"
  local reconciler_out="$scratch/reconciler-$label.sh"
  PATH="$pathdir" XDG_CACHE_HOME="$scratch/cache-desktop" render --override-data "$ov" <"$ignore_file" >"$ignore_out"
  [[ "$(ignore_hit_count "$ignore_out")" -eq 0 ]] \
    || fail "$label: an eligible host must NOT ignore any of the three runtime target files"
  PATH="$pathdir" XDG_CACHE_HOME="$scratch/cache-desktop" render --override-data "$ov" <"$reconciler_tmpl" >"$reconciler_out"
  [[ -s "$reconciler_out" ]] || fail "$label: an eligible host must render a non-empty reconciler"
  bash -n "$reconciler_out"
}

eligibility_negative() {  # $1=override json $2=path dir $3=cache dir $4=label
  local ov=$1 pathdir=$2 cachedir=$3 label=$4
  local ignore_out="$scratch/ignore-$label.txt"
  local reconciler_out="$scratch/reconciler-$label.sh"
  PATH="$pathdir" XDG_CACHE_HOME="$cachedir" render --override-data "$ov" <"$ignore_file" >"$ignore_out"
  [[ "$(ignore_hit_count "$ignore_out")" -eq 3 ]] \
    || fail "$label: an ineligible host must ignore all three runtime target files"
  PATH="$pathdir" XDG_CACHE_HOME="$cachedir" render --override-data "$ov" <"$reconciler_tmpl" >"$reconciler_out"
  [[ ! -s "$reconciler_out" ]] || fail "$label: an ineligible host must render an empty reconciler"
}

expect=${YDOTOOL_TEST_EXPECT:-host}
case "$expect" in
  host) ;;
  container)
    echo "=== U3: eligibility render matrix (real container fact) ==="
    [[ -e /run/.containerenv || -e /.dockerenv ]] \
      || fail "YDOTOOL_TEST_EXPECT=container requires a real container marker; the caller must create one"
    eligibility_negative "$fedora_ov" "$scratch/path-kde" "$scratch/cache-desktop" real-container
    echo "container gate: OK"
    printf 'ydotool-integration: all checks passed (mode=%s)\n' "$expect"
    exit 0
    ;;
  *)
    fail "unknown YDOTOOL_TEST_EXPECT: $expect"
    ;;
esac

# =============================================================================
# U1 — desktop-gated package delivery and distro service cutover
# =============================================================================
echo "=== U1: package delivery + service cutover ==="

# packages.yaml is plain data (no .tmpl suffix) — assert its static shape
# directly, no chezmoi render involved.
group_block() {  # stdin = one distro's section text, $1 = list key
  awk -v key="$1" '
    $0 ~ ("^      " key ":$") { grab=1; next }
    grab && $0 ~ /^      [A-Za-z]/ { exit }
    grab { print }
  '
}
for group in fedora:kdePackages fedora:gnomePackages ubuntu:kdePackages ubuntu:gnomePackages; do
  distro=${group%%:*}; key=${group#*:}
  case "$distro" in
    fedora) section=$(sed -n '/^    fedora:$/,/^    ubuntu:$/p' "$packages_yaml") ;;
    ubuntu) section=$(sed -n '/^    ubuntu:$/,$p' "$packages_yaml") ;;
  esac
  n=$(printf '%s\n' "$section" | group_block "$key" | grep -cE '^\s+- ydotool(\s|#|$)' || true)
  [[ "$n" -eq 1 ]] || fail "expected exactly 1 ydotool entry in $distro.$key, found $n"
done
total=$(grep -cE '^\s+- ydotool(\s|#|$)' "$packages_yaml" || true)
# The 4 per-group checks above already prove each of the 4 gated groups
# carries exactly one; a 5th anywhere would mean an unconditional list (e.g.
# packages/corePackages/bareMetalPackages/nvidiaPackages) also carries it.
[[ "$total" -eq 4 ]] || fail "expected exactly 4 total ydotool package entries, found $total"

# The desktop fact correctly seeds HAS_KDE/HAS_GNOME at execution time:
# fact_gate() reads FACT_DESKTOP, baked by facts-sh.tmpl from the `lookPath`
# probe honoring the scoped PATH below. Truncate the rendered script right
# after the HAS_GNOME line (a side-effect-free prefix) and execute JUST that
# prefix — this exercises the real fact_gate() dispatch, not a copy of it.
desktop_flags() {  # $1 = rendered installer path
  local line
  line=$(grep -n '^HAS_GNOME=0; fact_gate' "$1" | head -1 | cut -d: -f1)
  [[ -n "$line" ]] || fail "no HAS_GNOME seeding line found in $1"
  head -n "$line" "$1" >"$scratch/probe.sh"
  printf 'echo "HAS_KDE=$HAS_KDE HAS_GNOME=$HAS_GNOME"\n' >>"$scratch/probe.sh"
  bash "$scratch/probe.sh"
}

fedora_kde="$scratch/fedora-kde.sh"
PATH="$scratch/path-kde" XDG_CACHE_HOME="$scratch/cache-headless" \
  render --override-data "$fedora_ov" <"$fedora_installer" >"$fedora_kde"
[[ -s "$fedora_kde" ]] || fail "fedora installer rendered empty"
bash -n "$fedora_kde"
[[ "$(desktop_flags "$fedora_kde")" == 'HAS_KDE=1 HAS_GNOME=0' ]] \
  || fail "desktop=kde did not seed HAS_KDE=1/HAS_GNOME=0"

fedora_gnome="$scratch/fedora-gnome.sh"
PATH="$scratch/path-gnome" XDG_CACHE_HOME="$scratch/cache-headless" \
  render --override-data "$fedora_ov" <"$fedora_installer" >"$fedora_gnome"
bash -n "$fedora_gnome"
[[ "$(desktop_flags "$fedora_gnome")" == 'HAS_KDE=0 HAS_GNOME=1' ]] \
  || fail "desktop=gnome did not seed HAS_KDE=0/HAS_GNOME=1"

fedora_none="$scratch/fedora-none.sh"
PATH="$scratch/path-none" XDG_CACHE_HOME="$scratch/cache-headless" \
  render --override-data "$fedora_ov" <"$fedora_installer" >"$fedora_none"
bash -n "$fedora_none"
[[ "$(desktop_flags "$fedora_none")" == 'HAS_KDE=0 HAS_GNOME=0' ]] \
  || fail "desktop=none unexpectedly seeded HAS_KDE or HAS_GNOME"
# desktop=none selects none of the four ydotool package entries: the block
# check above already proved ydotool is embedded ONLY inside the
# HAS_KDE/HAS_GNOME-guarded packages+=() blocks, and this run proves those
# guards both evaluate false when desktop=none.

ubuntu_kde="$scratch/ubuntu-kde.sh"
PATH="$scratch/path-kde" XDG_CACHE_HOME="$scratch/cache-headless" \
  render --override-data "$ubuntu_ov" <"$ubuntu_installer" >"$ubuntu_kde"
[[ -s "$ubuntu_kde" ]] || fail "ubuntu installer rendered empty"
bash -n "$ubuntu_kde"

ubuntu_gnome="$scratch/ubuntu-gnome.sh"
PATH="$scratch/path-gnome" XDG_CACHE_HOME="$scratch/cache-headless" \
  render --override-data "$ubuntu_ov" <"$ubuntu_installer" >"$ubuntu_gnome"
bash -n "$ubuntu_gnome"

# unsupported target gate: neither installer renders on a non-Linux host.
darwin_fedora=$(render --override-data '{"chezmoi":{"os":"darwin"}}' <"$fedora_installer")
[[ -z "${darwin_fedora//[$' \t\n']/}" ]] || fail "fedora installer must render empty on darwin"
darwin_ubuntu=$(render --override-data '{"chezmoi":{"os":"darwin"}}' <"$ubuntu_installer")
[[ -z "${darwin_ubuntu//[$' \t\n']/}" ]] || fail "ubuntu installer must render empty on darwin"

# configure_ydotool_package_service: exact guard + body, call-site ordering,
# and no `input` group membership.
extract_function() {  # $1 = file, $2 = function name
  awk -v fn="$2" '
    $0 == fn"() {" { grab=1 }
    grab { print }
    grab && $0 == "}" { exit }
  ' "$1"
}
fedora_fn="$scratch/fedora-fn.sh"
extract_function "$fedora_kde" configure_ydotool_package_service >"$fedora_fn"
[[ -s "$fedora_fn" ]] || fail "configure_ydotool_package_service not found in the rendered Fedora installer"
has '^\s*\[\[ -x /usr/bin/ydotoold \]\] \|\| return 0$' "$fedora_fn" "Fedora helper is missing the daemon-presence guard"
has '^\s*\{ \[\[ "\$\{HAS_KDE\}" -eq 1 \]\] \|\| \[\[ "\$\{HAS_GNOME\}" -eq 1 \]\]; \} \|\| return 0$' "$fedora_fn" "Fedora helper is missing the KDE/GNOME eligibility guard"
has '^\s*"\$\{SUDO\[@\]\}" systemctl stop ydotool\.service$' "$fedora_fn" "Fedora helper does not stop the package unit"
has '^\s*"\$\{SUDO\[@\]\}" systemctl mask ydotool\.service$' "$fedora_fn" "Fedora helper does not mask the package unit"
lacks '--now|--global|--user' "$fedora_fn" "Fedora helper must only stop+mask the root system unit"

ubuntu_fn="$scratch/ubuntu-fn.sh"
extract_function "$ubuntu_kde" configure_ydotool_package_service >"$ubuntu_fn"
[[ -s "$ubuntu_fn" ]] || fail "configure_ydotool_package_service not found in the rendered Ubuntu installer"
has '^\s*\[\[ -x /usr/bin/ydotoold \]\] \|\| return 0$' "$ubuntu_fn" "Ubuntu helper is missing the daemon-presence guard"
has '^\s*\{ \[\[ "\$\{HAS_KDE\}" -eq 1 \]\] \|\| \[\[ "\$\{HAS_GNOME\}" -eq 1 \]\]; \} \|\| return 0$' "$ubuntu_fn" "Ubuntu helper is missing the KDE/GNOME eligibility guard"
has '^\s*"\$\{SUDO\[@\]\}" systemctl --global disable ydotool\.service$' "$ubuntu_fn" "Ubuntu helper does not globally disable the vendor unit"
lacks '--now|systemctl stop|systemctl mask' "$ubuntu_fn" "Ubuntu helper must only globally disable the vendor unit, never stop/mask a system unit"

call_site_line() {  # $1 = file, $2 = bare identifier
  grep -nx -- "$2" "$1" | head -1 | cut -d: -f1 || true
}
fedora_pkg_line=$(call_site_line "$fedora_kde" install_fedora_packages)
fedora_svc_line=$(call_site_line "$fedora_kde" configure_ydotool_package_service)
[[ -n "$fedora_pkg_line" && -n "$fedora_svc_line" && "$fedora_pkg_line" -lt "$fedora_svc_line" ]] \
  || fail "Fedora must call configure_ydotool_package_service AFTER install_fedora_packages ($fedora_pkg_line vs $fedora_svc_line)"

ubuntu_pkg_line=$(grep -nFx 'install_ubuntu_packages "${packages[@]}"' "$ubuntu_kde" | head -1 | cut -d: -f1 || true)
ubuntu_svc_line=$(call_site_line "$ubuntu_kde" configure_ydotool_package_service)
[[ -n "$ubuntu_pkg_line" && -n "$ubuntu_svc_line" && "$ubuntu_pkg_line" -lt "$ubuntu_svc_line" ]] \
  || fail "Ubuntu must call configure_ydotool_package_service AFTER install_ubuntu_packages ($ubuntu_pkg_line vs $ubuntu_svc_line)"

for f in "$fedora_kde" "$ubuntu_kde"; do
  has 'groups=\(keyd vboxusers\)' "$f" "expected the unchanged group membership list (in $f)"
  lacks 'groups=\([^)]*\<input\>[^)]*\)' "$f" "no installer may add the managed user to the input group (in $f)"
done

# BEHAVIORAL proof against a strict, call-logging systemctl stub. The one
# hardcoded absolute path (/usr/bin/ydotoold) is substituted to a scratch
# stub in a TEXT COPY of the extracted function only — never a real
# /usr/bin write.
mkdir -p "$scratch/bin"
pkg_call_log="$scratch/pkg-systemctl.calls"
cat >"$scratch/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$pkg_call_log"
case "\$*" in
  'stop ydotool.service'|'mask ydotool.service'|'--global disable ydotool.service') exit 0 ;;
  *) echo "unexpected systemctl call: \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$scratch/bin/systemctl"
present_daemon="$scratch/fake-ydotoold-present"
: >"$present_daemon"; chmod +x "$present_daemon"
absent_daemon="$scratch/fake-ydotoold-absent"

run_pkg_service() {  # $1=fn-file $2=has_kde $3=has_gnome $4=daemon(present|absent)
  local fn_file=$1 has_kde=$2 has_gnome=$3 daemon=$4
  local daemon_path=$present_daemon
  [[ "$daemon" == absent ]] && daemon_path=$absent_daemon
  : >"$pkg_call_log"
  ( set -euo pipefail
    PATH="$scratch/bin:/usr/bin:/bin"
    # shellcheck disable=SC2034 # consumed by the evaluated function body
    SUDO=()
    # shellcheck disable=SC2034 # consumed by the evaluated function body
    HAS_KDE=$has_kde
    # shellcheck disable=SC2034 # consumed by the evaluated function body
    HAS_GNOME=$has_gnome
    fn_text=$(sed "s#/usr/bin/ydotoold#$daemon_path#" "$fn_file")
    eval "$fn_text"
    configure_ydotool_package_service
  )
  tr '\n' '|' <"$pkg_call_log"
}

[[ "$(run_pkg_service "$fedora_fn" 1 0 absent)" == '' ]] \
  || fail "Fedora helper must call nothing when ydotoold is absent"
[[ "$(run_pkg_service "$fedora_fn" 0 0 present)" == '' ]] \
  || fail "Fedora helper must call nothing on desktop=none"
[[ "$(run_pkg_service "$fedora_fn" 1 0 present)" == 'stop ydotool.service|mask ydotool.service|' ]] \
  || fail "Fedora helper must stop then mask ydotool.service on KDE"
[[ "$(run_pkg_service "$fedora_fn" 0 1 present)" == 'stop ydotool.service|mask ydotool.service|' ]] \
  || fail "Fedora helper must stop then mask ydotool.service on GNOME"

[[ "$(run_pkg_service "$ubuntu_fn" 1 0 absent)" == '' ]] \
  || fail "Ubuntu helper must call nothing when ydotoold is absent"
[[ "$(run_pkg_service "$ubuntu_fn" 0 0 present)" == '' ]] \
  || fail "Ubuntu helper must call nothing on desktop=none"
[[ "$(run_pkg_service "$ubuntu_fn" 1 0 present)" == '--global disable ydotool.service|' ]] \
  || fail "Ubuntu helper must globally disable ydotool.service on KDE"
[[ "$(run_pkg_service "$ubuntu_fn" 0 1 present)" == '--global disable ydotool.service|' ]] \
  || fail "Ubuntu helper must globally disable ydotool.service on GNOME"

echo "U1: OK"

# =============================================================================
# U2 — active-seat uinput policy
# =============================================================================
echo "=== U2: udev least privilege ==="
has_line 'KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"' \
  "$rules_70" "70-uinput-solaar.rules lost its exact active-seat uaccess grant"
lacks 'GROUP=|OWNER=|MODE=' "$rules_70" "70-uinput-solaar.rules must not declare a persistent group/owner/mode grant"
rules_80_active=$(grep -vE '^\s*(#.*)?$' "$rules_80" || true)
[[ -z "$rules_80_active" ]] || fail "80-uinput.rules must be comment-only (found: $rules_80_active)"
[[ "$(basename -- "$rules_80")" == "80-uinput.rules" ]] || fail "the override must keep Ubuntu's exact vendor basename"

if command -v udevadm >/dev/null 2>&1; then
  udevadm verify "$rules_70" "$rules_80" || fail "udevadm verify rejected the managed udev rules"
fi
echo "U2: OK"

# =============================================================================
# U3 — managed graphical-session runtime
# =============================================================================
echo "=== U3: unit contract ==="
has_line 'ExecStart=%h/.local/libexec/ydotoold-active-seat' "$unit_file" "unit does not invoke the active-seat wrapper"
has_line 'PartOf=graphical-session.target' "$unit_file" "unit is not bound to graphical-session.target via PartOf"
has_line 'WantedBy=graphical-session.target' "$unit_file" "unit is not enabled against graphical-session.target"
has_line 'Restart=on-failure' "$unit_file" "unit does not restart on failure"
for directive in 'UMask=0077' 'NoNewPrivileges=yes' 'CapabilityBoundingSet=' \
  'RestrictSUIDSGID=yes' 'SystemCallArchitectures=native' 'RestrictAddressFamilies=AF_UNIX'; do
  has_line "$directive" "$unit_file" "unit is missing hardening directive: $directive"
done
for forbidden in '^PrivateTmp' '^ProtectSystem' '^ProtectHome' '^PrivateDevices' '^User=' '^WantedBy=default\.target$' '^DevicePolicy'; do
  lacks "$forbidden" "$unit_file" "unit must not declare forbidden directive: $forbidden"
done

if command -v systemd-analyze >/dev/null 2>&1; then
  # %h resolves to the real $HOME, where nothing is deployed under this
  # policy — substitute only the deployed path systemd-analyze would try to
  # stat, exactly as .ci/test-open-design-integration.sh does for its unit.
  sed 's|^ExecStart=.*|ExecStart=/bin/true|' "$unit_file" >"$scratch/ydotool-verify.service"
  systemd-analyze --user verify "$scratch/ydotool-verify.service" || fail "systemd-analyze --user verify rejected the unit"
fi
echo "unit contract: OK"

echo "=== U3: active-seat wrapper lifecycle ==="
has_line 'readonly DEVICE=/dev/uinput' "$wrapper_src" "wrapper lost its DEVICE path; harness substitution would silently no-op"
has_line 'readonly DAEMON=/usr/bin/ydotoold' "$wrapper_src" "wrapper lost its DAEMON path; harness substitution would silently no-op"
bash -n "$wrapper_src"

wrapper_home="$scratch/wrapper-rt"
mkdir -p "$wrapper_home"
fake_device="$scratch/fake-uinput"
: >"$fake_device"
chmod 000 "$fake_device"
mkdir -p "$scratch/daemon-bin"
fake_daemon_bin="$scratch/daemon-bin/fake-ydotoold"
daemon_log="$scratch/daemon-calls.log"
: >"$daemon_log"
daemon_pid_file="$scratch/daemon-current-pid"
cat >"$fake_daemon_bin" <<OUTER
#!/usr/bin/env bash
sock=""
for arg in "\$@"; do
  case "\$arg" in
    --socket-path=*) sock="\${arg#--socket-path=}" ;;
  esac
done
printf '%s %s\n' "\$\$" "\$*" >>"$daemon_log"
printf '%s\n' "\$\$" >"$daemon_pid_file"
[[ -n "\$sock" ]] && : >"\$sock"
trap 'exit 0' TERM
while true; do sleep 0.05; done
OUTER
chmod +x "$fake_daemon_bin"

wrapper_test="$scratch/wrapper-test"
sed -e "s#^readonly DEVICE=/dev/uinput#readonly DEVICE=$fake_device#" \
    -e "s#^readonly DAEMON=/usr/bin/ydotoold#readonly DAEMON=$fake_daemon_bin#" \
    "$wrapper_src" >"$wrapper_test"
chmod +x "$wrapper_test"
bash -n "$wrapper_test"

socket="$wrapper_home/.ydotool_socket"
XDG_RUNTIME_DIR="$wrapper_home" "$wrapper_test" >"$scratch/wrapper.out" 2>"$scratch/wrapper.err" &
wrapper_pid=$!
# NEVER `disown` this job: bash's `wait PID` on an already-disowned job
# returns 0 unconditionally (verified), which would silently defeat the
# unexpected-child-exit assertion below. The "Killed"-style notification
# bash may print for the inner daemon job belongs to the WRAPPER's own bash
# process (captured in wrapper.err below), not this harness's stderr.

# no-access: never starts the daemon while the fake device is unwritable.
sleep 0.8
[[ ! -s "$daemon_log" ]] || fail "wrapper started the daemon before the fake device was writable"

# start: grant access, expect exactly one child with the production flag shape.
chmod 600 "$fake_device"
wait_until "daemon started" bash -c '[[ -s "$1" ]]' _ "$daemon_log"
wait_until "socket created" bash -c '[[ -e "$1" ]]' _ "$socket"
pid1=$(cat "$daemon_pid_file")
grep -qF -- "--socket-path=$socket" "$daemon_log" || fail "daemon invocation is missing --socket-path=$socket"
grep -qF -- '--socket-perm=0600' "$daemon_log" || fail "daemon invocation is missing --socket-perm=0600"

# steady state: no duplicate start while access and the child both persist.
sleep 0.8
[[ $(wc -l <"$daemon_log") -eq 1 ]] || fail "wrapper double-started the daemon while access and the child both remained live"

# stop: revoke access, expect the socket removed and the child terminated
# within one bounded reconciliation window.
chmod 000 "$fake_device"
wait_until "socket removed on access loss" bash -c '[[ ! -e "$1" ]]' _ "$socket"
sleep 0.3
if kill -0 "$pid1" 2>/dev/null; then fail "the revoked daemon child is still running"; fi

# restart: regrant access, expect a fresh child (new pid) and a new socket.
chmod 600 "$fake_device"
wait_until "a fresh daemon child started" bash -c '[[ $(wc -l <"$1") -eq 2 ]]' _ "$daemon_log"
pid2=$(cat "$daemon_pid_file")
[[ "$pid2" != "$pid1" ]] || fail "the restarted daemon reused the old child's pid"
wait_until "socket recreated on regrant" bash -c '[[ -e "$1" ]]' _ "$socket"

# graceful service stop: SIGTERM to the wrapper must remove its socket, stop
# the owned child, and preserve a successful service-exit status.
kill -TERM "$wrapper_pid"
wait_until "the gracefully stopped wrapper exits" bash -c '! kill -0 "$1" 2>/dev/null' _ "$wrapper_pid"
set +e
wait "$wrapper_pid"
graceful_status=$?
set -e
wrapper_pid=""
[[ "$graceful_status" -eq 0 ]] || fail "the wrapper must exit zero after SIGTERM"
[[ ! -e "$socket" ]] || fail "the socket must be removed after wrapper SIGTERM"
if kill -0 "$pid2" 2>/dev/null; then fail "the daemon child survived wrapper SIGTERM"; fi

# Start another wrapper/child pair for the independent unexpected-death path.
XDG_RUNTIME_DIR="$wrapper_home" "$wrapper_test" >"$scratch/wrapper.out" 2>"$scratch/wrapper.err" &
wrapper_pid=$!
wait_until "a third daemon child started" bash -c '[[ $(wc -l <"$1") -eq 3 ]]' _ "$daemon_log"
pid3=$(cat "$daemon_pid_file")
wait_until "socket recreated for child-death scenario" bash -c '[[ -e "$1" ]]' _ "$socket"

# unrequested child death while access remains present must propagate as a
# wrapper failure (systemd's Restart=on-failure owns recovery), never a
# silent in-process respawn.
kill -KILL "$pid3" 2>/dev/null || true
wait_until "the wrapper process exits" bash -c '! kill -0 "$1" 2>/dev/null' _ "$wrapper_pid"
set +e
wait "$wrapper_pid"
wrapper_status=$?
set -e
wrapper_pid=""
[[ "$wrapper_status" -ne 0 ]] || fail "the wrapper must exit nonzero when its child dies unexpectedly"
[[ $(wc -l <"$daemon_log") -eq 3 ]] || fail "the wrapper must not silently respawn after an unexpected child exit"
[[ ! -e "$socket" ]] || fail "the socket must be removed after an unexpected child exit"
echo "wrapper lifecycle: OK"

echo "=== U3: reconciler ==="
recon_bin="$scratch/recon-bin"
mkdir -p "$recon_bin"
recon_call_log="$scratch/recon-systemctl.calls"
cat >"$recon_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RECON_CALL_LOG"
case " $* " in
  *' --now '*) echo "unexpected --now" >&2; exit 9 ;;
esac
if [[ "${1-}" != "--user" ]]; then
  echo "unexpected non-user-scope call: $*" >&2
  exit 9
fi
shift
case "${1-}" in
  enable) exit "${STUB_ENABLE_EXIT:-0}" ;;
  daemon-reload) [[ "${STUB_BUS:-1}" == 1 ]] && exit 0 || exit 1 ;;
  is-active) [[ "${STUB_ACTIVE:-0}" == 1 ]] && exit 0 || exit 1 ;;
  restart) exit 0 ;;
  *) echo "unexpected systemctl subcommand: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$recon_bin/systemctl"

# Direct stub self-test: the strict stub itself rejects --now and a
# non---user scope call, independent of whether the reconciler ever emits one.
: >"$recon_call_log"
if env RECON_CALL_LOG="$recon_call_log" "$recon_bin/systemctl" --user enable --now ydotool.service 2>/dev/null; then
  fail "the systemctl stub accepted a --now call"
fi
: >"$recon_call_log"
if env RECON_CALL_LOG="$recon_call_log" "$recon_bin/systemctl" enable ydotool.service 2>/dev/null; then
  fail "the systemctl stub accepted a non---user-scope call"
fi

reconciler_eligible="$scratch/reconciler-fedora-kde.sh"
PATH="$scratch/path-kde" XDG_CACHE_HOME="$scratch/cache-desktop" render --override-data "$fedora_ov" \
  <"$reconciler_tmpl" >"$reconciler_eligible"
[[ -s "$reconciler_eligible" ]] || fail "eligible reconciler render is empty"
bash -n "$reconciler_eligible"

# Missing daemon: substitute the already-absent scratch path and keep the
# strict systemctl stub first on PATH. This proves the no-call branch without
# assuming anything about host package state or risking a real user-manager
# call when a provisioned desktop runs the harness.
has_line 'readonly DAEMON=/usr/bin/ydotoold' "$reconciler_eligible" \
  "reconciler lost its DAEMON path; harness substitution would silently no-op"
reconciler_missing="$scratch/reconciler-missing.sh"
sed "s#^readonly DAEMON=/usr/bin/ydotoold#readonly DAEMON=$absent_daemon#" \
  "$reconciler_eligible" >"$reconciler_missing"
bash -n "$reconciler_missing"
: >"$recon_call_log"
env PATH="$recon_bin:/usr/bin:/bin" RECON_CALL_LOG="$recon_call_log" bash "$reconciler_missing" \
  >"$scratch/recon-missing.out" 2>"$scratch/recon-missing.err"
[[ ! -s "$recon_call_log" ]] || fail "missing-daemon path must call systemctl zero times"

# Present-daemon scenarios: substitute the hardcoded absolute path in another
# test copy, same technique as the wrapper — never touches real /usr/bin.
recon_fake_daemon="$scratch/recon-fake-ydotoold"
: >"$recon_fake_daemon"; chmod +x "$recon_fake_daemon"
reconciler_test="$scratch/reconciler-test.sh"
sed "s#^readonly DAEMON=/usr/bin/ydotoold#readonly DAEMON=$recon_fake_daemon#" \
  "$reconciler_eligible" >"$reconciler_test"
bash -n "$reconciler_test"

run_reconciler() {  # $1..=env assignments
  : >"$recon_call_log"
  env PATH="$recon_bin:/usr/bin:/bin" RECON_CALL_LOG="$recon_call_log" "$@" bash "$reconciler_test" \
    >"$scratch/recon-run.out" 2>"$scratch/recon-run.err"
  tr '\n' '|' <"$recon_call_log"
}

[[ "$(run_reconciler STUB_BUS=0)" == '--user enable --no-reload ydotool.service|--user daemon-reload|' ]] \
  || fail "no-bus scenario: expected enable + a failing daemon-reload only, no is-active/restart"

[[ "$(run_reconciler STUB_ENABLE_EXIT=1 STUB_BUS=1 STUB_ACTIVE=1)" == '--user enable --no-reload ydotool.service|--user daemon-reload|--user is-active --quiet ydotool.service|--user restart ydotool.service|' ]] \
  || fail "enable-failure scenario: expected reconciliation to continue through daemon-reload/is-active/restart"
grep -qF 'could not enable ydotool.service' "$scratch/recon-run.err" \
  || fail "enable-failure scenario: expected an actionable warning"

[[ "$(run_reconciler STUB_BUS=1 STUB_ACTIVE=0)" == '--user enable --no-reload ydotool.service|--user daemon-reload|--user is-active --quiet ydotool.service|' ]] \
  || fail "inactive scenario: expected enable + daemon-reload + is-active, no restart"

[[ "$(run_reconciler STUB_BUS=1 STUB_ACTIVE=1)" == '--user enable --no-reload ydotool.service|--user daemon-reload|--user is-active --quiet ydotool.service|--user restart ydotool.service|' ]] \
  || fail "active scenario: expected the full enable/reload/is-active/restart sequence"

# repeated reconciliation: the same active-instance scenario run again must
# reproduce the identical, deterministic call sequence (idempotent).
[[ "$(run_reconciler STUB_BUS=1 STUB_ACTIVE=1)" == '--user enable --no-reload ydotool.service|--user daemon-reload|--user is-active --quiet ydotool.service|--user restart ydotool.service|' ]] \
  || fail "repeated reconciliation must reproduce the identical call sequence"

echo "reconciler: OK"

# =============================================================================
# U3 — eligibility render matrix (.chezmoiignore + the reconciler's own gate)
# =============================================================================

echo "=== U3: eligibility render matrix (host mode) ==="
eligibility_positive "$fedora_ov" "$scratch/path-kde" fedora-kde
eligibility_positive "$fedora_ov" "$scratch/path-gnome" fedora-gnome
eligibility_positive "$ubuntu_ov" "$scratch/path-kde" ubuntu-kde
eligibility_positive "$ubuntu_ov" "$scratch/path-gnome" ubuntu-gnome
eligibility_negative "$fedora_ov" "$scratch/path-kde" "$scratch/cache-headless" headless
eligibility_negative '{"chezmoi":{"os":"darwin"}}' "$scratch/path-kde" "$scratch/cache-desktop" nonlinux
eligibility_negative '{"chezmoi":{"os":"linux","osRelease":{"id":"debian"}}}' \
  "$scratch/path-kde" "$scratch/cache-desktop" unsupported-distro
eligibility_negative "$fedora_ov" "$scratch/path-none" "$scratch/cache-desktop" no-desktop
echo "eligibility render matrix: OK"

printf 'ydotool-integration: all checks passed (mode=%s)\n' "$expect"
