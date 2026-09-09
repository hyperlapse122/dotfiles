#!/usr/bin/env bash
set -euo pipefail

# Proves the omp plugin reconciler rendered from
# .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl:
# it carries the declared row, re-points the marketplace instead of trusting an
# already-registered one, converges on a re-run, fails loudly on a host without
# omp, recovers the previous marketplace registration on refresh failures, and
# refuses a marketplace source that would make omp drop most of its skills.
#
# It is separate from test-claude-agy-plugin-reconcile.sh because omp's identity
# grammar (<name>@<marketplace>) and its non-idempotent verbs share no lifecycle
# facts with those three harnesses; folding it in would mean teaching that
# harness a fourth stub shape for no reuse.
#
# The rendered script holds an ABSOLUTE marketplace path resolved against the
# renderer's home, so the fixture rewrites that path into its own scratch HOME
# rather than letting a run consult the live one.
#
# Live declaration of agents.omp.pluginsRemoved is empty, which is why the
# removal-loop variant is rendered inside this test via --override-data rather
# than read from the CI-rendered script.
#
# Known defect filed separately: the removal loop builds <name>@<registry key>
# while the install path builds <name>@<manifest marketplace name>. In current
# data these differ (compound-engineering-omp vs compound-engineering-plugin),
# so a declared removal hands omp an id it does not know. The test asserts
# only the shape and the call, not that the id matches the manifest name.
usage='usage: test-omp-plugin-reconcile.sh OMP_SCRIPT'
omp_script=${1:?$usage}

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-plugin-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() {
  printf 'test-omp-plugin-reconcile: %s\n' "$*" >&2
  exit 1
}
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
chezmoi_bin=$(command -v "${CHEZMOI:-chezmoi}") ||
  { echo "chezmoi is not on PATH" >&2; exit 1; }
mkdir -p "$scratch/render-bin" "$scratch/render-home" "$scratch/render-target"
printf '#!/usr/bin/env bash\nprintf %%s DUMMY-OP-VALUE\n' > "$scratch/render-bin/op"
chmod 0700 "$scratch/render-bin/op"
printf '[data]\n' > "$scratch/render-empty.toml"

render_variant() {
  local override=$1 out=$2 err=$3
  env HOME="$scratch/render-home" PATH="$scratch/render-bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/render-empty.toml" --source "$repo_root" \
      --destination "$scratch/render-target" --override-data "$override" \
      execute-template <"$repo_root/.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl" \
      >"$out" 2>"$err"
}

# --- rendered surface ------------------------------------------------------ #

for needle in \
  'compound-engineering\tcompound-engineering-omp\tlocalArchive\t' \
  'omp plugin marketplace remove' \
  'omp plugin marketplace add' \
  'omp plugin install --scope user --force' \
  'omp plugin enable --scope user'
do
  grep -F "$needle" "$omp_script" >/dev/null ||
    fail "rendered omp script lost: $needle"
done

# The row must name the omp-only archive. Pointing at the shared copy is the
# defect this whole split exists to prevent.
grep -F 'compound-engineering\tcompound-engineering-plugin\t' "$omp_script" >/dev/null &&
  fail 'omp row points at the shared compound-engineering archive'

bash -n "$omp_script" || fail 'rendered omp script is not valid bash'

# --- fixtures -------------------------------------------------------------- #

home="$scratch/home"
bin="$scratch/bin"
market="$home/.local/share/compound-engineering-omp/v0.0.0"
omp_calls="$scratch/omp-calls"
mkdir -p "$bin" "$market/.claude-plugin" "$market/skills/demo"

build_market() {
  rm -rf "$market"
  mkdir -p "$market/.claude-plugin" "$market/skills/demo"
  printf '{"name":"compound-engineering-plugin","plugins":[{"name":"compound-engineering"}]}\n' \
    > "$market/.claude-plugin/marketplace.json"
  printf -- '---\nname: demo\n---\n' > "$market/skills/demo/SKILL.md"
}

reset_home() {
  rm -rf "$home/.omp"
  mkdir -p "$home/.omp/plugins/marketplaces"
  : > "$omp_calls"
}

register_marketplace() {
  local mid=$1 msrc=$2
  mkdir -p "$home/.omp/plugins/marketplaces"
  printf '%s\n' "$msrc" >"$home/.omp/plugins/marketplaces/$mid"
}

get_registered_marketplace() {
  local mid=$1
  if [[ -f $home/.omp/plugins/marketplaces/$mid ]]; then
    cat "$home/.omp/plugins/marketplaces/$mid"
  fi
}

# Rewrite the renderer's absolute marketplace path to this fixture's.
rewrite() {
  local rendered=$1 target=$2 path
  path=$(grep -oE '\\tlocalArchive\\t[^"]+' "$rendered" | head -1)
  path=${path#*\\tlocalArchive\\t}
  [[ -n $path ]] || fail 'could not resolve the rendered marketplace path'
  sed "s|$path|$market|g" "$rendered" >"$target"
  chmod 0700 "$target"
}

omp_test="$scratch/omp-plugins.sh"
rewrite "$omp_script" "$omp_test"
grep -F "$market" "$omp_test" >/dev/null || fail 'fixture path rewrite did not take'

# --- omp stub -------------------------------------------------------------- #

# Reproduces the lifecycle facts the script is written against: a marketplace
# already registered under the same name keeps its recorded source until it is
# removed, and install refuses a source whose manifest does not declare the
# plugin.
cat >"$bin/omp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMP_CALLS"
state="$HOME/.omp/plugins"
mkdir -p "$state/marketplaces"

case "$*" in
  "plugin marketplace list"*)
    printf 'Configured Marketplaces:\n\n'
    for f in "$state/marketplaces"/*; do
      [[ -f $f ]] || continue
      mid=$(basename "$f")
      msrc=$(cat "$f")
      printf '  %s  %s\n' "$mid" "$msrc"
    done
    ;;
  "plugin marketplace add "*)
    src=$4
    if [[ -e $state/fail-marketplace-add ]]; then
      printf 'simulated marketplace add failure\n' >&2; exit 1
    fi
    if [[ -e $state/fail-marketplace-add-source ]] && grep -Fqx "$src" "$state/fail-marketplace-add-source"; then
      printf 'simulated marketplace add failure for source: %s\n' "$src" >&2; exit 1
    fi
    [[ -f $src/.claude-plugin/marketplace.json ]] ||
      { printf 'no marketplace manifest: %s\n' "$src" >&2; exit 1; }
    id=$(jq -r '.name // empty' "$src/.claude-plugin/marketplace.json" 2>/dev/null)
    [[ -n $id ]] || { printf 'nameless manifest: %s\n' "$src" >&2; exit 1; }
    [[ -e $state/marketplaces/$id ]] &&
      { printf 'marketplace already registered: %s\n' "$id" >&2; exit 1; }
    printf '%s\n' "$src" >"$state/marketplaces/$id"
    ;;
  "plugin marketplace remove "*)
    id=$4
    if [[ -e $state/marketplaces/$id ]]; then
      rm -f "$state/marketplaces/$id"
    else
      printf 'no such marketplace: %s\n' "$id" >&2; exit 1
    fi
    ;;
  "plugin install --scope user --force "*)
    if [[ -e $state/fail-plugin-install ]]; then
      printf 'simulated plugin install failure\n' >&2; exit 1
    fi
    id=$6
    market_name=${id#*@}
    [[ -f $state/marketplaces/$market_name ]] || { printf 'unknown marketplace: %s\n' "$market_name" >&2; exit 1; }
    src=$(cat "$state/marketplaces/$market_name")
    [[ -f $src/skills/demo/SKILL.md ]] || { printf 'bundle skills unreadable: %s\n' "$src" >&2; exit 1; }
    : >"$state/installed"
    ;;
  "plugin enable --scope user "*)
    if [[ -e $state/fail-plugin-enable ]]; then
      printf 'simulated plugin enable failure\n' >&2; exit 1
    fi
    [[ -e $state/installed ]] || { printf 'not installed\n' >&2; exit 1; }
    : >"$state/enabled"
    ;;
  "plugin uninstall --scope user "*)
    rm -f "$state/installed" "$state/enabled"
    ;;
  *) printf 'unexpected omp call: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0700 "$bin/omp"

# A bounded PATH, not the inherited one: the reconciler shells out to jq, and an
# inherited PATH can resolve it through a version-manager shim that fails for
# reasons unrelated to this script, which would look like a preflight refusal.
run_omp() { env HOME="$home" PATH="$bin:/usr/bin:/bin" OMP_CALLS="$omp_calls" bash "$omp_test"; }

# --- happy path ------------------------------------------------------------ #

build_market
reset_home
run_omp || fail 'first run failed'
[[ -e $home/.omp/plugins/installed ]] || fail 'plugin was not installed'
[[ -e $home/.omp/plugins/enabled ]] || fail 'plugin was not enabled'
# The id must come from the manifest's own name, NOT from the chezmoi registry
# key that resolved the source. The fixture manifest deliberately carries the
# upstream name so a script that used the key would fail here.
grep -Fq "plugin install --scope user --force compound-engineering@compound-engineering-plugin" \
  "$omp_calls" || fail 'install did not use the marketplace id from the source manifest'
grep -Fq "compound-engineering@compound-engineering-omp" "$omp_calls" &&
  fail 'install built the id from the chezmoi registry key instead of the manifest'
grep -Fq "plugin marketplace add $market" "$omp_calls" ||
  fail 'initial registration did not add marketplace'
[[ $(get_registered_marketplace compound-engineering-plugin) == "$market" ]] ||
  fail 'initial registration did not register marketplace'

# --- convergence: a second run over a converged host skips remove and add -- #

: > "$omp_calls"
run_omp || fail 'second run failed instead of converging'
grep -Fq 'plugin marketplace remove' "$omp_calls" &&
  fail 'second run called marketplace remove on already-converged host'
grep -Fq 'plugin marketplace add' "$omp_calls" &&
  fail 'second run called marketplace add on already-converged host'
grep -Fq "plugin install --scope user --force compound-engineering@compound-engineering-plugin" \
  "$omp_calls" || fail 'second run did not run install --force'
grep -Fq "plugin enable --scope user compound-engineering@compound-engineering-plugin" \
  "$omp_calls" || fail 'second run did not run enable'
[[ -e $home/.omp/plugins/enabled ]] || fail 'plugin lost its enabled state on re-run'
[[ $(get_registered_marketplace compound-engineering-plugin) == "$market" ]] ||
  fail 'second run changed the registered marketplace source'

# --- stale source re-pointed ----------------------------------------------- #

build_market
reset_home
stale_market="$scratch/stale-market"
mkdir -p "$stale_market/.claude-plugin"
printf '{"name":"compound-engineering-plugin","plugins":[{"name":"compound-engineering"}]}\n' \
  > "$stale_market/.claude-plugin/marketplace.json"
register_marketplace "compound-engineering-plugin" "$stale_market"
: > "$omp_calls"
run_omp || fail 'stale source re-point failed'
grep -Fq 'plugin marketplace remove compound-engineering-plugin' "$omp_calls" ||
  fail 're-point did not remove the stale marketplace registration'
grep -Fq "plugin marketplace add $market" "$omp_calls" ||
  fail 're-point did not add the desired marketplace source'
[[ $(get_registered_marketplace compound-engineering-plugin) == "$market" ]] ||
  fail 'stale source was not updated to desired source'
[[ -e $home/.omp/plugins/installed ]] || fail 'plugin was not installed after re-point'
[[ -e $home/.omp/plugins/enabled ]] || fail 'plugin was not enabled after re-point'

# --- failing marketplace add restores previous source ---------------------- #

build_market
reset_home
register_marketplace "compound-engineering-plugin" "$stale_market"
printf '%s\n' "$market" > "$home/.omp/plugins/fail-marketplace-add-source"
: > "$omp_calls"
if run_omp 2>"$scratch/add_fail.err"; then
  fail 'marketplace add failure on differs branch did not exit non-zero'
fi
[[ $(get_registered_marketplace compound-engineering-plugin) == "$stale_market" ]] ||
  fail 'previous marketplace source was not restored after failed add'
grep -q 'marketplace add failed' "$scratch/add_fail.err" ||
  fail 'error message did not name add failure'

# --- failing plugin install restores previous source ----------------------- #

build_market
reset_home
register_marketplace "compound-engineering-plugin" "$stale_market"
: > "$home/.omp/plugins/fail-plugin-install"
: > "$omp_calls"
if run_omp 2>"$scratch/install_fail.err"; then
  fail 'plugin install failure did not exit non-zero'
fi
[[ $(get_registered_marketplace compound-engineering-plugin) == "$stale_market" ]] ||
  fail 'previous marketplace source was not restored after failed install'
grep -q 'plugin install failed' "$scratch/install_fail.err" ||
  fail 'error message did not name install failure'

# --- failing plugin enable restores previous source ------------------------ #

build_market
reset_home
register_marketplace "compound-engineering-plugin" "$stale_market"
: > "$home/.omp/plugins/fail-plugin-enable"
: > "$omp_calls"
if run_omp 2>"$scratch/enable_fail.err"; then
  fail 'plugin enable failure did not exit non-zero'
fi
[[ $(get_registered_marketplace compound-engineering-plugin) == "$stale_market" ]] ||
  fail 'previous marketplace source was not restored after failed enable'
grep -q 'plugin enable failed' "$scratch/enable_fail.err" ||
  fail 'error message did not name enable failure'

# --- restore whose own re-add fails names both failures --------------------- #

build_market
reset_home
register_marketplace "compound-engineering-plugin" "$stale_market"
: > "$home/.omp/plugins/fail-plugin-install"
printf '%s\n' "$stale_market" > "$home/.omp/plugins/fail-marketplace-add-source"
: > "$omp_calls"
if run_omp 2>"$scratch/restore_fail.err"; then
  fail 'failed restore did not exit non-zero'
fi
grep -q 'plugin install failed' "$scratch/restore_fail.err" ||
  fail 'error did not name original install failure'
grep -q 'failed to restore marketplace' "$scratch/restore_fail.err" ||
  fail 'error did not name failed restore'
grep -q 'compound-engineering-plugin' "$scratch/restore_fail.err" ||
  fail 'error did not name marketplace id'
grep -Fq "$stale_market" "$scratch/restore_fail.err" ||
  fail 'error did not name source that could not be restored'

# --- unregistered marketplace failure dies without restore attempt --------- #

build_market
reset_home
: > "$home/.omp/plugins/fail-plugin-install"
: > "$omp_calls"
if run_omp 2>"$scratch/unregistered_fail.err"; then
  fail 'install failure on unregistered marketplace did not exit non-zero'
fi
grep -q 'plugin install failed' "$scratch/unregistered_fail.err" ||
  fail 'error did not name install failure'
grep -q 'failed to restore' "$scratch/unregistered_fail.err" &&
  fail 'attempted restore when marketplace was not registered initially'
# --- a source carrying a root plugin.json is refused ----------------------- #

build_market
reset_home
printf '{"name":"compound-engineering"}\n' > "$market/plugin.json"
if run_omp 2>"$scratch/rootmanifest.err"; then
  fail 'a marketplace with a root plugin.json was accepted'
fi
grep -q 'root plugin.json' "$scratch/rootmanifest.err" ||
  fail 'the root-plugin.json refusal did not name its reason'
[[ ! -e $home/.omp/plugins/installed ]] || fail 'refused source still reached install'
rm -f "$market/plugin.json"

# --- a manifest that does not declare the plugin is refused ---------------- #

build_market
reset_home
printf '{"name":"compound-engineering-plugin","plugins":[{"name":"something-else"}]}\n' \
  > "$market/.claude-plugin/marketplace.json"
if run_omp 2>"$scratch/manifest.err"; then
  fail 'a manifest that does not declare the plugin was accepted'
fi
grep -q 'does not declare plugin' "$scratch/manifest.err" ||
  fail 'the manifest refusal did not name its reason'

# --- a missing manifest is refused ----------------------------------------- #

build_market
reset_home
rm -f "$market/.claude-plugin/marketplace.json"
if run_omp 2>"$scratch/missing.err"; then
  fail 'a marketplace without a manifest was accepted'
fi
grep -q 'no marketplace manifest' "$scratch/missing.err" ||
  fail 'the missing-manifest refusal did not name its reason'

# --- a host without omp fails loudly --------------------------------------- #

# The command manifest installs omp in the same apply, so an absent binary here
# is a provisioning failure, not a host that opted out. A silent success would
# also be an undeclared conditional exit, which check-skip-declarations rejects.
build_market
reset_home
no_omp="$scratch/no-omp-bin"
mkdir -p "$no_omp"
if env HOME="$home" PATH="$no_omp:/usr/bin:/bin" OMP_CALLS="$omp_calls" bash "$omp_test" \
  2>"$scratch/skip.err"; then
  fail 'a host without omp exited successfully instead of failing loudly'
fi
grep -q 'omp is not on PATH' "$scratch/skip.err" ||
  fail 'the omp-absent failure did not state its reason'

# --- removal loop coverage (U5) -------------------------------------------- #

# Live declaration is empty, so it renders neither the array nor the loop.
grep -Fq 'PLUGINS_REMOVED=(' "$omp_script" &&
  fail 'live empty declaration rendered PLUGINS_REMOVED array'
grep -Fq 'omp plugin uninstall --scope user' "$omp_script" &&
  fail 'live empty declaration rendered uninstall loop'

# An override injecting a removal row renders PLUGINS_REMOVED and the loop.
removed_override='{"agents":{"omp":{"pluginsRemoved":[{"name":"old-plugin","marketplace":"compound-engineering-omp"}]}}}'
rendered_removed="$scratch/omp-removed.sh"
render_variant "$removed_override" "$rendered_removed" "$scratch/render_removed.err" ||
  fail 'rendering variant with pluginsRemoved failed'
grep -Fq 'PLUGINS_REMOVED=(' "$rendered_removed" ||
  fail 'override declaration did not render PLUGINS_REMOVED array'
grep -Fq 'omp plugin uninstall --scope user' "$rendered_removed" ||
  fail 'override declaration did not render uninstall loop'
grep -Fq 'old-plugin\tcompound-engineering-omp' "$rendered_removed" ||
  fail 'override declaration did not carry declared removal row'

# Run the removal variant against the omp stub.
# Tests:
# - uninstall called with <name>@<marketplace> shaped argument
# - uninstall of an id the stub does not know exits zero and does not fail the run
# - uninstall runs before the first marketplace add
removed_test="$scratch/omp-removed-test.sh"
rewrite "$rendered_removed" "$removed_test"
reset_home
build_market
: > "$omp_calls"
run_removed() { env HOME="$home" PATH="$bin:/usr/bin:/bin" OMP_CALLS="$omp_calls" bash "$removed_test"; }
run_removed || fail 'removal variant failed against omp stub'
grep -Fq 'plugin uninstall --scope user old-plugin@compound-engineering-omp' "$omp_calls" ||
  fail 'uninstall was not called for the declared removal row'

uninstall_line=$(grep -n 'plugin uninstall --scope user' "$omp_calls" | head -1 | cut -d: -f1)
add_line=$(grep -n 'plugin marketplace add' "$omp_calls" | head -1 | cut -d: -f1)
[[ -n $uninstall_line && -n $add_line && $uninstall_line -lt $add_line ]] ||
  fail 'uninstall did not run before the first marketplace add'

printf 'omp plugin reconcile: ok\n'
