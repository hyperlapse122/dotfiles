#!/usr/bin/env bash
set -euo pipefail

# Proves the omp plugin reconciler rendered from
# .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl:
# it carries the declared row, re-points the marketplace instead of trusting an
# already-registered one, converges on a re-run, skips a host without omp, and
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
  mkdir -p "$home/.omp/plugins"
  : > "$omp_calls"
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
case "$*" in
  "plugin marketplace add "*)
    src=$4
    [[ -f $src/.claude-plugin/marketplace.json ]] ||
      { printf 'no marketplace manifest: %s\n' "$src" >&2; exit 1; }
    [[ -e $state/declared-marketplace ]] &&
      { printf 'marketplace already registered\n' >&2; exit 1; }
    printf '%s\n' "$src" >"$state/declared-marketplace"
    ;;
  "plugin marketplace remove "*)
    [[ -e $state/declared-marketplace ]] || { printf 'no such marketplace\n' >&2; exit 1; }
    rm -f "$state/declared-marketplace"
    ;;
  "plugin install --scope user --force "*)
    [[ -e $state/declared-marketplace ]] || { printf 'unknown marketplace\n' >&2; exit 1; }
    src=$(cat "$state/declared-marketplace")
    [[ -f $src/skills/demo/SKILL.md ]] || { printf 'bundle skills unreadable\n' >&2; exit 1; }
    : >"$state/installed"
    ;;
  "plugin enable --scope user "*)
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

# --- convergence: a second run re-points instead of failing ---------------- #

: > "$omp_calls"
run_omp || fail 'second run failed instead of converging'
grep -Fq 'plugin marketplace remove compound-engineering-plugin' "$omp_calls" ||
  fail 'second run did not remove the stale marketplace registration'
[[ -e $home/.omp/plugins/enabled ]] || fail 'plugin lost its enabled state on re-run'

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

printf 'omp plugin reconcile: ok\n'
