#!/usr/bin/env bash
# test-package-installer-verdict.sh — drive the rendered devtools, apps and .NET
# installers with stub package managers and prove their failure verdict.
#
# WHAT IT GUARDS. These installers used to discard an install failure with
# `|| true` or `2>/dev/null` and let chezmoi record the host as converged while a
# declared package was missing. The verdict is now a re-inspection of the
# declared set after the attempt: a set that is still incomplete is reported on
# stderr and declared through skip.sh.tmpl, whose record survives until the
# passing path clears it. Every scenario asserts the function's exit status, the
# record and its direction column, the stderr text and the logged install calls,
# so a verdict that only returns 0 without declaring anything fails here.
#
# The installers are rendered through the scratch contract of
# .ci/lib/render-gate-helpers.sh and their install regions are extracted and
# run under a scratch HOME and XDG_STATE_HOME. PATH holds only the stubs and
# links to a fixed set of harmless tools, so no scenario can reach a real
# package manager, `sudo`, `op` or `/etc`.
#
# Package sets travel as space-separated words and are split on purpose.
# shellcheck disable=SC2086
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
prog=test-package-installer-verdict
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

fail() { printf '%s: FAIL: %s\n' "$prog" "$*" >&2; exit 1; }
pass() { printf '%s: ok - %s\n' "$prog" "$*"; scenarios=$((scenarios + 1)); }
scenarios=0

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}}
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/$prog.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'
devtools_src=.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl
apps_src=.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl
dotnet_src=.chezmoiscripts/30-components/run_onchange_before_50-dotnet.sh.tmpl
for src in "$devtools_src" "$apps_src" "$dotnet_src"; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$src"
done

# --- Render ------------------------------------------------------------------
#
# The render gets its own scratch tree: its PATH must not see the package
# manager stubs, and its `op` is a stub that always fails.
rscratch=$scratch/render
mkdir -p "$rscratch/bin" "$rscratch/home" "$rscratch/target" "$scratch/rendered"
printf '[data]\n' >"$rscratch/empty.toml"
printf '#!/bin/sh\nexit 1\n' >"$rscratch/bin/op"
chmod 0755 "$rscratch/bin/op"

fedora_data='{"chezmoi":{"os":"linux","osRelease":{"id":"fedora"}}}'
ubuntu_data='{"chezmoi":{"os":"linux","arch":"arm64","osRelease":{"id":"ubuntu"}}}'
darwin_data='{"chezmoi":{"os":"darwin","osRelease":{"id":"macos"}}}'

render_variant() {
  local src=$1 os=$2 data=$3 out=$scratch/rendered/$4
  render "$repo_root" "$rscratch" "$chezmoi_bin" "$os" "$repo_root/$src" "$out" "$data" ||
    fail "$src does not render for $4"
  bash -n "$out" || fail "$4 is not valid shell"
}
render_variant "$devtools_src" linux "$fedora_data" devtools-fedora.sh
render_variant "$devtools_src" linux "$ubuntu_data" devtools-ubuntu.sh
render_variant "$apps_src" linux "$fedora_data" apps-fedora.sh
render_variant "$dotnet_src" linux "$fedora_data" dotnet-fedora.sh
render_variant "$dotnet_src" linux "$ubuntu_data" dotnet-ubuntu.sh
render_variant "$dotnet_src" darwin "$darwin_data" dotnet-darwin.sh
pass 'the three installers render for Fedora, Ubuntu arm64 and darwin'

# --- Structural gates ----------------------------------------------------------

rendered=("$scratch"/rendered/*.sh)

# Only the tolerant Terra bootstrap (repository setup, KTD4) may keep `|| true`
# on an install call; every declared-set install is judged by the re-inspection.
install_discard_re='(dnf|apt-get|dotnet tool)[^#]*[[:space:]]install[[:space:]].*\|\|[[:space:]]*(true|:($|[[:space:]#;]))'
terra_allowance_re='install -y --nogpgcheck --repofrompath [^ ]+ terra-release terra-gpg-keys \|\| (true|:)$'
offenders=$(grep -inE "$install_discard_re" "${rendered[@]}" |
  grep -vE "$terra_allowance_re" || true)
[[ -z "$offenders" ]] || fail "an install call still discards its failure with || true or || ::
$offenders"
grep -qE -- '--repofrompath .*terra-release.*\|\| true$' "$scratch/rendered/devtools-fedora.sh" ||
  fail 'the Terra bootstrap is no longer the tolerant repository setup step the allowance names'
pass 'no declared-set install call keeps || true or || :; the Terra bootstrap is the one allowance'

# Scenarios 1-3: verify the widened gate expression rejects || : on dnf, apt-get and dotnet tool
for sample in \
  'dnf install -y foo || :' \
  'apt-get install -y foo || :' \
  'dotnet tool install -g foo || :'; do
  sample_offenders=$(printf '%s\n' "$sample" | grep -inE "$install_discard_re" |
    grep -vE "$terra_allowance_re" || true)
  [[ -n "$sample_offenders" ]] || fail "the gate expression did not reject || : sample: $sample"
done
pass 'the gate expression rejects || : on dnf, apt-get and dotnet tool install calls'

# Scenario 4: verify the widened gate expression still rejects || true forms
for sample in \
  'dnf install -y foo || true' \
  'apt-get install -y foo || true' \
  'dotnet tool install -g foo || true'; do
  sample_offenders=$(printf '%s\n' "$sample" | grep -inE "$install_discard_re" |
    grep -vE "$terra_allowance_re" || true)
  [[ -n "$sample_offenders" ]] || fail "the gate expression did not reject || true sample: $sample"
done
pass 'the gate expression still rejects || true on install calls'

# Scenario 5: verify the Terra bootstrap line is still allowed by the widened expression
for terra_sample in \
  'dnf install -y --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra$releasever" terra-release terra-gpg-keys || true' \
  '"${DNF[@]}" install -y --nogpgcheck --repofrompath '\''terra,https://repos.fyralabs.com/terra$releasever'\'' terra-release terra-gpg-keys || true' \
  'dnf install -y --nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra$releasever" terra-release terra-gpg-keys || :' \
  '"${DNF[@]}" install -y --nogpgcheck --repofrompath '\''terra,https://repos.fyralabs.com/terra$releasever'\'' terra-release terra-gpg-keys || :'; do
  sample_offenders=$(printf '%s\n' "$terra_sample" | grep -inE "$install_discard_re" |
    grep -vE "$terra_allowance_re" || true)
  [[ -z "$sample_offenders" ]] || fail "the gate expression falsely rejected the Terra bootstrap line: $terra_sample"
done
pass 'the Terra bootstrap line is still allowed by the widened expression'

# Scenario 6: verify the widened expression adds no false positive on legitimate colons
for sample in \
  "dnf install -y --repofrompath 'terra,https://repos.fyralabs.com/terra' foo" \
  'dnf install -y "${PKG:-default-pkg}"' \
  'apt-get install -y "${PKG:-default-pkg}"' \
  'dotnet tool install -g "${TOOL:-default-tool}"' \
  'dnf install -y "${PKG:-default}" || exit 1'; do
  sample_offenders=$(printf '%s\n' "$sample" | grep -inE "$install_discard_re" |
    grep -vE "$terra_allowance_re" || true)
  [[ -z "$sample_offenders" ]] || fail "the gate expression falsely matched legitimate colon: $sample"
done
pass 'the widened expression adds no false positive on legitimate colons'

sdk_redirect=$(grep -nE 'dnf[^#]*install[^#]*dotnet-sdk.*2>/dev/null' "$scratch/rendered/dotnet-fedora.sh" || true)
[[ -z "$sdk_redirect" ]] || fail "an SDK dnf install hides dnf's stderr: $sdk_redirect"
unsuppressed=$(grep -nE 'DNF.*makecache' "$scratch/rendered/apps-fedora.sh" |
  grep -vE '^[0-9]+:[[:space:]]*if ! .*makecache|makecache.*\|\|' || true)
[[ -z "$unsuppressed" ]] || fail "an apps dnf makecache still aborts the apply: $unsuppressed"
pass 'no SDK install hides stderr and no apps makecache can abort the apply'

if grep -nF -- '--bucket=scriptState' "${rendered[@]}"; then
  fail 'a rendered installer still names --bucket=scriptState'
fi
pass 'no rendered installer names --bucket=scriptState'

hint_sources=(
  "$repo_root/.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl"
  "$repo_root/.chezmoitemplates/skip.sh.tmpl"
  "$repo_root/AGENTS.md"
)
if grep -nF -- '--bucket=scriptState' "${hint_sources[@]}"; then
  fail 'a re-run hint still names --bucket=scriptState'
fi
pass 'no re-run hint names --bucket=scriptState'

awk '/^# fingerprint:/ { inside = 1; next } inside && !/^#/ { exit } inside && /^#[[:space:]]+value:dotnet-present[[:space:]]/ { found = 1 } END { exit !found }' \
  "$scratch/rendered/dotnet-ubuntu.sh" ||
  fail 'the Ubuntu .NET render carries no fingerprint block on dotnet-present'
pass 'the Ubuntu .NET render hashes dotnet-present into its fingerprint'

expect_sentinel() {
  local file=$1 script=$2 site=$3 direction=$4
  grep -qE "^[[:space:]]*# skip-declaration-v1 .* script=$script site=$site form=skip_step direction=$direction " \
    "$scratch/rendered/$file" || fail "$file declares no $script/$site skip_step ($direction)"
}
expect_sentinel devtools-fedora.sh install-devtools-fedora dev-packages-not-installed operator-blocking
expect_sentinel devtools-ubuntu.sh install-devtools-ubuntu dev-packages-not-installed operator-blocking
expect_sentinel apps-fedora.sh install-apps-fedora app-packages-not-installed operator-blocking
expect_sentinel dotnet-fedora.sh install-dotnet-fedora dotnet-absent transient-blocking
expect_sentinel dotnet-fedora.sh install-dotnet-fedora dotnet-tools-not-installed operator-blocking
expect_sentinel dotnet-ubuntu.sh install-dotnet-ubuntu dotnet-absent transient-blocking
expect_sentinel dotnet-ubuntu.sh install-dotnet-ubuntu dotnet-tools-not-installed operator-blocking
expect_sentinel dotnet-darwin.sh install-dotnet-darwin dotnet-tools-not-installed operator-blocking
pass 'every rendered variant carries its declaration sites'

# --- Region extraction ---------------------------------------------------------
#
# A region runs from the first line of the installer's own data to the closing
# brace of its entry function, so it carries the package arrays, the top-level
# FACT_VIRT branch and every helper, but neither the facts prologue, the guards
# nor the trailing entry calls.
extract() {
  local file=$scratch/rendered/$1 start=$2 last_fn=$3 out=$scratch/$4 first end
  first=$(grep -nE -m1 "$start" "$file" | cut -d: -f1)
  end=$(awk -v fn="^$last_fn\\\\(\\\\) \\\\{\$" '$0 ~ fn { inside = 1 } inside && /^\}$/ { print NR; exit }' "$file")
  if [[ -z "$first" || -z "$end" ]] || ((first >= end)); then
    fail "$1 has no $last_fn region starting at $start"
  fi
  sed -n "${first},${end}p" "$file" >"$out"
}
extract devtools-fedora.sh '^DNF=\(' install_devtools devtools-fedora.region
extract devtools-ubuntu.sh '^apt_installed\(\) \{$' install_devtools devtools-ubuntu.region
extract apps-fedora.sh '^DNF=\(' install_app_packages apps-fedora.region
extract dotnet-fedora.sh '^dotnet_tools=\($' install_dotnet_tools dotnet-fedora.region
extract dotnet-ubuntu.sh '^dotnet_tools=\($' install_dotnet_tools dotnet-ubuntu.region
extract dotnet-darwin.sh '^dotnet_tools=\($' install_dotnet_tools dotnet-darwin.region

# --- Stubs ---------------------------------------------------------------------
#
# Installed sets live in files under $STUB_STATE so an install stub can provide a
# package that the following re-inspection then sees. Every call is logged to
# $STUB_LOG as `<tool> <args>`.
stubs=$scratch/bin
sysbin=$scratch/sys
dotnet_dir=$scratch/dotnet-bin
mkdir -p "$stubs" "$sysbin" "$dotnet_dir"
for tool in bash sh env awk grep cat rm mkdir printf cut tr sed head; do
  real=$(type -P "$tool") || fail "$tool is required on PATH"
  ln -s "$real" "$sysbin/$tool"
done

stub() { cat >"$1"; chmod 0755 "$1"; }

stub "$stubs/dnf" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'dnf %s\n' "$*" >>"$STUB_LOG"
args=" $* "
listed() { case " ${1-} " in *" $2 "*) return 0 ;; esac; return 1; }
if [[ "$args" == *' group list '* ]]; then
  [[ "${DNF_GROUP_LIST_EXIT:-0}" == 0 ]] || exit "$DNF_GROUP_LIST_EXIT"
  printf 'ID                   Name                 Installed\n'
  while IFS= read -r g; do printf '%-20s %-20s yes\n' "$g" "$g"; done <"$STUB_STATE/groups"
  exit 0
fi
if [[ "$args" == *' group install '* ]]; then
  for g in "$@"; do
    listed "${DNF_GROUP_PROVIDES:-}" "$g" && printf '%s\n' "$g" >>"$STUB_STATE/groups"
  done
  exit "${DNF_GROUP_INSTALL_EXIT:-0}"
fi
if [[ "$args" == *' makecache '* ]]; then
  exit "${DNF_MAKECACHE_EXIT:-0}"
fi
if [[ "$args" == *' --repofrompath '* ]]; then
  exit "${DNF_TERRA_EXIT:-0}"
fi
if [[ "$args" == *' install '* ]]; then
  for p in "$@"; do
    listed "${DNF_PROVIDES:-}" "$p" && printf '%s\n' "$p" >>"$STUB_STATE/rpms"
  done
  exit "${DNF_INSTALL_EXIT:-0}"
fi
exit 0
EOF

stub "$stubs/rpm" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'rpm %s\n' "$*" >>"$STUB_LOG"
case "${1-}" in
  -q) grep -qxF -- "${2-}" "$STUB_STATE/rpms" ;;
  --import) exit "${RPM_IMPORT_EXIT:-0}" ;;
  *) exit 1 ;;
esac
EOF

stub "$stubs/apt-get" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'apt-get %s\n' "$*" >>"$STUB_LOG"
[[ "${1-}" == update ]] && exit "${APT_UPDATE_EXIT:-0}"
[[ "${1-}" == install ]] || exit 1
shift
rc=0
for p in "$@"; do
  [[ "$p" == -* ]] && continue
  case " ${APT_FAIL:-} " in
    *" $p "*) printf 'E: Unable to locate package %s\n' "$p" >&2; rc=100 ;;
    *)
      printf '%s\n' "$p" >>"$STUB_STATE/debs"
      for rule in ${APT_PULLS:-}; do
        [[ "$rule" == "$p:"* ]] && printf '%s\n' "${rule#*:}" >>"$STUB_STATE/debs"
      done
      ;;
  esac
done
exit "$rc"
EOF

stub "$stubs/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
pkg=${!#}
if grep -qxF -- "$pkg" "$STUB_STATE/debs"; then
  printf 'installed'
  exit 0
fi
printf 'dpkg-query: no packages found matching %s\n' "$pkg" >&2
exit 1
EOF

stub "$dotnet_dir/dotnet" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'dotnet %s\n' "$*" >>"$STUB_LOG"
[[ "${1-} ${2-}" == 'tool list' ]] && {
  printf 'Package Id      Version      Commands\n'
  printf -- '-------------------------------------\n'
  while IFS= read -r t; do printf '%-15s 1.0.0        %s\n' "$t" "$t"; done <"$STUB_STATE/tools"
  exit 0
}
if [[ "${1-} ${2-}" == 'tool install' ]]; then
  tool=${!#}
  case " ${DOTNET_TOOL_FAIL:-} " in
    *" $tool "*) printf 'Tool %s failed to install.\n' "$tool" >&2; exit 1 ;;
  esac
  printf '%s\n' "$tool" >>"$STUB_STATE/tools"
  exit 0
fi
exit 1
EOF

stub "$stubs/tee" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'tee %s\n' "$*" >>"$STUB_LOG"
mkdir -p "$STUB_STATE/tee"
out="$STUB_STATE/tee/${!#//\//_}"
cat >"$out"
EOF

# --- Driver --------------------------------------------------------------------
#
# run_case <label> <region> <body> [NAME=value...]
# Installed sets come from RPMS, GROUPS, DEBS and TOOLS (space separated);
# DOTNET=1 puts the dotnet stub on PATH; SEED=<script>__<site> pre-seeds a
# record. Everything else is passed to the stubs as environment. The result is
# left in $out, $err, $log, $rc and $skips.
out='' err='' log='' rc=0 skips=''
run_case() {
  local label=$1 region=$2 body=$3
  shift 3
  local case_dir=$scratch/cases/$label kv name
  local rpms='' groups='' debs='' tools='' dotnet=0 seed=''
  local -a pass_env=()
  for kv in "$@"; do
    name=${kv%%=*}
    case "$name" in
      RPMS) rpms=${kv#*=} ;;
      GROUPS) groups=${kv#*=} ;;
      DEBS) debs=${kv#*=} ;;
      TOOLS) tools=${kv#*=} ;;
      DOTNET) dotnet=${kv#*=} ;;
      SEED) seed=${kv#*=} ;;
      *) pass_env+=("$kv") ;;
    esac
  done
  mkdir -p "$case_dir/home" "$case_dir/stub"
  skips=$case_dir/state/chezmoi/skips
  mkdir -p "$skips"
  printf '%s\n' $rpms >"$case_dir/stub/rpms"
  printf '%s\n' $groups >"$case_dir/stub/groups"
  printf '%s\n' $debs >"$case_dir/stub/debs"
  printf '%s\n' $tools >"$case_dir/stub/tools"
  if [[ -n "$seed" ]]; then
    local seed_script=${seed%%__*} seed_site=${seed#*__}
    printf 'v1\t%s\t%s\toperator-blocking\tseeded by the harness\n' "$seed_script" "$seed_site" >"$skips/$seed"
  fi
  local path="$stubs:$sysbin"
  [[ "$dotnet" == 1 ]] && path="$stubs:$dotnet_dir:$sysbin"
  out=$case_dir/stdout err=$case_dir/stderr log=$case_dir/calls.log
  : >"$log"
  rc=0
  env -i HOME="$case_dir/home" XDG_STATE_HOME="$case_dir/state" PATH="$path" \
    STUB_LOG="$log" STUB_STATE="$case_dir/stub" "${pass_env[@]}" \
    "$sysbin/bash" -c '
      set -euo pipefail
      SUDO=()
      DNF=(dnf)
      source "$1"
      eval "$2"
      printf "reached-end\n"
    ' harness "$scratch/$region" "$body" >"$out" 2>"$err" || rc=$?
}

show() { printf -- '--- stdout\n'; cat "$out"; printf -- '--- stderr\n'; cat "$err"; printf -- '--- calls\n'; cat "$log"; }
check() { "$@" || { show >&2; fail "$label: assertion failed: $*"; }; }
returned_zero() { [[ "$rc" == 0 ]] && grep -qx 'reached-end' "$out"; }
called() { grep -qE -- "$1" "$log"; }
not_called() { ! grep -qE -- "$1" "$log"; }
stderr_has() { grep -qF -- "$1" "$err"; }
no_record() { [[ ! -e "$skips/$1" ]]; }
# Exactly one v1 line of five tab-separated fields naming this script, site and
# direction: the shape dotfiles-skips and the pruner parse.
record_is() {
  local file=$skips/$1 direction=$2 script=${1%%__*} site=${1#*__}
  [[ -f "$file" ]] || return 1
  [[ "$(wc -l <"$file")" -eq 1 ]] || return 1
  awk -F'\t' -v s="$script" -v t="$site" -v d="$direction" \
    'NF == 5 && $1 == "v1" && $2 == s && $3 == t && $4 == d && $5 != "" && $5 !~ /seeded/ { ok = 1 } END { exit !ok }' "$file"
}
# An operator-blocking declaration names the bucket that re-runs an onchange
# script (KTD7).
names_entry_state() { stderr_has '--bucket=entryState' && ! stderr_has 'scriptState'; }

# The declared sets are read from the rendered arrays, so a package added to a
# template is covered without editing this harness.
declared() {
  local words
  words=$(sed -n "/^$1=(\$/,/^)\$/p" "$scratch/$2" | grep -vE '^[[:space:]]*(#|$)|[()]' | tr -s ' \n' ' ')
  set -- $words
  [[ $# -gt 0 ]] || fail "could not read the declared set $1 from $2"
  printf '%s' "$*"
}
fd_pkgs=$(declared dev_packages devtools-fedora.region)
fd_groups=$(declared dev_groups devtools-fedora.region)
ud_pkgs=$(declared dev_packages devtools-ubuntu.region)
app_pkgs=$(declared app_packages apps-fedora.region)
all_tools=$(declared dotnet_tools dotnet-fedora.region)
without() { local drop=$1 w; shift; for w in "$@"; do [[ "$w" == "$drop" ]] || printf '%s ' "$w"; done; }
read -r fd_first fd_second _ <<<"$fd_pkgs"
read -r fd_group1 _ <<<"$fd_groups"
read -r tool1 tool2 _ <<<"$all_tools"

DFED=install-devtools-fedora__dev-packages-not-installed
DUBU=install-devtools-ubuntu__dev-packages-not-installed
APPS=install-apps-fedora__app-packages-not-installed
NFED_SDK=install-dotnet-fedora__dotnet-absent
NFED_TOOLS=install-dotnet-fedora__dotnet-tools-not-installed
NUBU_SDK=install-dotnet-ubuntu__dotnet-absent
NUBU_TOOLS=install-dotnet-ubuntu__dotnet-tools-not-installed
NMAC_TOOLS=install-dotnet-darwin__dotnet-tools-not-installed

# --- Devtools, Fedora ----------------------------------------------------------

label=devtools-fedora-install-fails
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$(without "$fd_first" $fd_pkgs)" GROUPS="$fd_groups" DNF_INSTALL_EXIT=1
check returned_zero
check record_is "$DFED" operator-blocking
check stderr_has "$fd_first"
check stderr_has "sudo dnf install -y $fd_first"
check names_entry_state
check called "^dnf install -y $fd_first\$"
pass "$label: a failed dnf install is recorded, reported and the script continues"

label=devtools-fedora-exit-zero-still-missing
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$(without "$fd_second" $fd_pkgs)" GROUPS="$fd_groups" DNF_INSTALL_EXIT=0
check returned_zero
check record_is "$DFED" operator-blocking
check stderr_has "sudo dnf install -y $fd_second"
pass "$label: dnf exiting 0 is not the verdict"

label=devtools-fedora-group-missing
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$fd_pkgs" GROUPS="$(without "$fd_group1" $fd_groups)" DNF_GROUP_INSTALL_EXIT=1
check returned_zero
check record_is "$DFED" operator-blocking
check stderr_has "sudo dnf group install -y $fd_group1"
check called "^dnf group install -y $fd_group1\$"
check not_called '^dnf install '
check names_entry_state
pass "$label: a group the listing still lacks is recorded and reported"

label=devtools-fedora-group-install-fails-but-present
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$fd_pkgs" GROUPS="$(without "$fd_group1" $fd_groups)" DNF_GROUP_PROVIDES="$fd_group1" DNF_GROUP_INSTALL_EXIT=1
check returned_zero
check no_record "$DFED"
check called "^dnf group install -y $fd_group1\$"
pass "$label: a failing group install whose group is listed afterwards is not recorded"

label=devtools-fedora-converged
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$fd_pkgs" GROUPS="$fd_groups" SEED="$DFED"
check returned_zero
check no_record "$DFED"
check not_called '^dnf .*install -y'
check not_called '--repofrompath'
pass "$label: a converged host installs nothing and clears the record"

label=devtools-fedora-converges-now
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$(without "$fd_first" $fd_pkgs)" GROUPS="$fd_groups" DNF_PROVIDES="$fd_first" SEED="$DFED"
check returned_zero
check no_record "$DFED"
check called "^dnf install -y $fd_first\$"
pass "$label: an install that provides the package clears the record"

label=devtools-fedora-terra-fails
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$(without ghostty $fd_pkgs)" GROUPS="$fd_groups" DNF_TERRA_EXIT=1 DNF_INSTALL_EXIT=1
check returned_zero
check called '--repofrompath .* terra-release'
check record_is "$DFED" operator-blocking
check stderr_has 'sudo dnf install -y ghostty'
pass "$label: a failed Terra bootstrap surfaces as the package it could not provide"

label=devtools-fedora-group-list-fails
run_case "$label" devtools-fedora.region install_devtools \
  RPMS="$fd_pkgs" GROUPS="$fd_groups" DNF_GROUP_LIST_EXIT=1
check returned_zero
check record_is "$DFED" operator-blocking
check called "^dnf group install -y $fd_groups"
pass "$label: an unreadable group listing is treated as every group missing"

# --- Devtools, Ubuntu ----------------------------------------------------------

read -r ud1 ud2 ud3 ud_rest <<<"$ud_pkgs"
label=devtools-ubuntu-second-fails
run_case "$label" devtools-ubuntu.region install_devtools \
  DEBS="$ud_rest" APT_FAIL="$ud2"
check returned_zero
check called "^apt-get install -y $ud1\$"
check called "^apt-get install -y $ud2\$"
check called "^apt-get install -y $ud3\$"
check record_is "$DUBU" operator-blocking
check stderr_has "sudo apt-get install -y $ud2"
check names_entry_state
if grep -F 'sudo apt-get install -y' "$err" | grep -qwE "$ud1|$ud3"; then
  show >&2; fail "$label: the by-hand command names a package that installed"
fi
pass "$label: one failed package does not stop the rest and is the one recorded"

label=devtools-ubuntu-recommends-dependency-skipped
run_case "$label" devtools-ubuntu.region install_devtools \
  DEBS="$ud_rest" APT_PULLS="$ud1:$ud2" SEED="$DUBU"
check returned_zero
check no_record "$DUBU"
check called "^apt-get install -y $ud1\$"
check not_called "^apt-get install -y $ud2\$"
check called "^apt-get install -y $ud3\$"
pass "$label: a package pulled in by an earlier install is not requested"

label=devtools-ubuntu-converged
run_case "$label" devtools-ubuntu.region install_devtools DEBS="$ud_pkgs" SEED="$DUBU"
check returned_zero
check no_record "$DUBU"
check not_called '^apt-get install'
pass "$label: a converged host installs nothing and clears the record"

label=devtools-ubuntu-converges-now
run_case "$label" devtools-ubuntu.region install_devtools DEBS="$(without "$ud2" $ud_pkgs)" SEED="$DUBU"
check returned_zero
check no_record "$DUBU"
check called "^apt-get install -y $ud2\$"
pass "$label: an install that provides the package clears the record"

label=devtools-ubuntu-all-fail
run_case "$label" devtools-ubuntu.region install_devtools \
  DEBS="" APT_FAIL="$ud_pkgs"
check returned_zero
check record_is "$DUBU" operator-blocking
check stderr_has "sudo apt-get install -y $ud_pkgs"
check names_entry_state
pass "$label: every package failing is recorded and reported"

label=devtools-ubuntu-update-fails
run_case "$label" devtools-ubuntu.region install_devtools \
  DEBS="$(without "$ud1" $ud_pkgs)" APT_UPDATE_EXIT=1 SEED="$DUBU"
check returned_zero
check called '^apt-get update'
check called "^apt-get install -y $ud1\$"
check no_record "$DUBU"
pass "$label: a failed apt-get update still reaches the install"

# --- Apps, Fedora --------------------------------------------------------------

read -r app1 _ <<<"$app_pkgs"
label=apps-install-fails
run_case "$label" apps-fedora.region install_app_packages \
  RPMS="$(without "$app1" $app_pkgs) steam" DNF_INSTALL_EXIT=1
check returned_zero
check record_is "$APPS" operator-blocking
check stderr_has "sudo dnf install -y $app1"
check names_entry_state
check called "^dnf install -y $app1\$"
check called '^tee /etc/yum.repos.d/'
pass "$label: a failed dnf install is recorded, reported and the script continues"

label=apps-makecache-fails
run_case "$label" apps-fedora.region install_app_packages \
  RPMS="$(without "$app1" $app_pkgs) steam" DNF_MAKECACHE_EXIT=1 DNF_PROVIDES="$app1" SEED="$APPS"
check returned_zero
check called '^dnf makecache'
check called "^dnf install -y $app1\$"
check no_record "$APPS"
pass "$label: a failed makecache still reaches the install and the verdict decides"

label=apps-converged
run_case "$label" apps-fedora.region install_app_packages RPMS="$app_pkgs steam" SEED="$APPS"
check returned_zero
check no_record "$APPS"
check not_called '^dnf install'
pass "$label: a converged host installs nothing and clears the record"

label=apps-converges-now
run_case "$label" apps-fedora.region install_app_packages \
  RPMS="$(without "$app1" $app_pkgs) steam" DNF_PROVIDES="$app1" SEED="$APPS"
check returned_zero
check no_record "$APPS"
check called "^dnf install -y $app1\$"
pass "$label: an install that provides the package clears the record"

label=apps-virt-host-without-steam
run_case "$label" apps-fedora.region install_app_packages RPMS="$app_pkgs" FACT_VIRT=1 SEED="$APPS"
check returned_zero
check no_record "$APPS"
check not_called '^dnf install'
pass "$label: a virtual host does not declare steam missing"

label=apps-bare-metal-steam-missing
run_case "$label" apps-fedora.region install_app_packages RPMS="$app_pkgs" FACT_VIRT=0 DNF_INSTALL_EXIT=1
check returned_zero
check record_is "$APPS" operator-blocking
check called '^dnf install -y steam$'
pass "$label: a bare-metal host still declares steam"

# --- .NET, Fedora --------------------------------------------------------------

label='dotnet-fedora-sdk-fails'
run_case "$label" dotnet-fedora.region 'install_dotnet_sdk; install_dotnet_tools' DNF_INSTALL_EXIT=1
check returned_zero
check called '^dnf install -y dotnet-sdk-8.0 dotnet-sdk-10.0$'
check called '^dnf install -y dotnet-sdk-8.0$'
check stderr_has 'sudo dnf install -y dotnet-sdk-10.0'
check record_is "$NFED_SDK" transient-blocking:dotnet-present
check grep -q 'SDK install' "$skips/$NFED_SDK"
check not_called '^dotnet '
pass "$label: a failed SDK install is recorded on dotnet-present with the by-hand command"

label='dotnet-fedora-tool-fails'
run_case "$label" dotnet-fedora.region 'install_dotnet_sdk; install_dotnet_tools' \
  RPMS=dotnet-sdk-10.0 DOTNET=1 DOTNET_TOOL_FAIL="$tool1"
check returned_zero
check not_called '^dnf '
check called "^dotnet tool install -g $tool1\$"
check called "^dotnet tool install -g $tool2\$"
check record_is "$NFED_TOOLS" operator-blocking
check no_record "$NFED_SDK"
check stderr_has "dotnet tool install -g $tool1"
check names_entry_state
pass "$label: a failed tool install is recorded and reported"

label='dotnet-fedora-tools-converged'
run_case "$label" dotnet-fedora.region install_dotnet_tools DOTNET=1 TOOLS="$all_tools" SEED="$NFED_TOOLS"
check returned_zero
check no_record "$NFED_TOOLS"
check not_called '^dotnet tool install'
pass "$label: a converged host installs no tool and clears the record"

label='dotnet-fedora-tools-converge-now'
run_case "$label" dotnet-fedora.region install_dotnet_tools \
  DOTNET=1 TOOLS="$(without "$tool1" $all_tools)" SEED="$NFED_TOOLS"
check returned_zero
check no_record "$NFED_TOOLS"
check called "^dotnet tool install -g $tool1\$"
pass "$label: an install that provides the tool clears the record"

# --- .NET, Ubuntu --------------------------------------------------------------

label='dotnet-ubuntu-sdk-fails'
run_case "$label" dotnet-ubuntu.region 'install_dotnet_sdk; install_dotnet_tools' APT_FAIL=dotnet-sdk-8.0
check returned_zero
check called '^apt-get install -y dotnet-sdk-8.0$'
check stderr_has 'sudo apt-get install -y dotnet-sdk-8.0'
check record_is "$NUBU_SDK" transient-blocking:dotnet-present
pass "$label: a failed SDK install is recorded on dotnet-present"

label='dotnet-ubuntu-tool-fails'
run_case "$label" dotnet-ubuntu.region 'install_dotnet_sdk; install_dotnet_tools' \
  DOTNET=1 TOOLS="$tool2" DOTNET_TOOL_FAIL="$tool1"
check returned_zero
check not_called '^apt-get '
check record_is "$NUBU_TOOLS" operator-blocking
check stderr_has "dotnet tool install -g $tool1"
check names_entry_state
pass "$label: a failed tool install is recorded and reported"

label='dotnet-ubuntu-tools-converged'
run_case "$label" dotnet-ubuntu.region install_dotnet_tools DOTNET=1 TOOLS="$all_tools" SEED="$NUBU_TOOLS"
check returned_zero
check no_record "$NUBU_TOOLS"
check not_called '^dotnet tool install'
[[ ! -s "$err" ]] || { show >&2; fail "$label: the passing path wrote to stderr"; }
pass "$label: a converged host installs no tool and clears the record"

label='dotnet-ubuntu-tools-converge-now'
run_case "$label" dotnet-ubuntu.region install_dotnet_tools DOTNET=1 SEED="$NUBU_TOOLS"
check returned_zero
check no_record "$NUBU_TOOLS"
pass "$label: installed tools clear the record"

# --- .NET, darwin (bash -u) ----------------------------------------------------

label=darwin-tool-fails
run_case "$label" dotnet-darwin.region install_dotnet_tools DOTNET=1 DOTNET_TOOL_FAIL="$tool2"
check returned_zero
check record_is "$NMAC_TOOLS" operator-blocking
check stderr_has "dotnet tool install -g $tool2"
check names_entry_state
pass "$label: a failed tool install is recorded under bash -u"

label=darwin-converged
run_case "$label" dotnet-darwin.region install_dotnet_tools DOTNET=1 TOOLS="$all_tools" SEED="$NMAC_TOOLS"
check returned_zero
check no_record "$NMAC_TOOLS"
check not_called '^dotnet tool install'
[[ ! -s "$err" ]] || { show >&2; fail "$label: the passing path wrote to stderr"; }
pass "$label: the empty missing set runs clean under bash -u and clears the record"

label=darwin-dotnet-absent
run_case "$label" dotnet-darwin.region install_dotnet_tools
check returned_zero
check not_called '^dotnet '
pass "$label: an absent dotnet is the deferred no-attempt path"

# --- The harness observes the declaration, not only the status -----------------
#
# A report helper that returns non-zero silently skips the declaration inside
# `if <test> && report; then`. Driving that shape must leave no record, which
# proves every record assertion above is observing the declaration path.
label=report-helper-nonzero
run_case "$label" devtools-fedora.region 'report_devtools_missing() { return 1; }; install_devtools' \
  RPMS="$(without "$fd_first" $fd_pkgs)" GROUPS="$fd_groups" DNF_INSTALL_EXIT=1
check returned_zero
check no_record "$DFED"
pass "$label: a non-zero report helper writes no record and the harness sees it"

printf '%s: all %d scenarios passed\n' "$prog" "$scenarios"
