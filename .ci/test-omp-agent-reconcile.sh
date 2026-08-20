#!/usr/bin/env bash
set -euo pipefail

usage='usage: test-omp-agent-reconcile.sh AUTH_SCRIPT PLUGIN_SCRIPT HAPTIC_PACKAGE SETTINGS_SH'
auth_script=${1:?$usage}
plugin_script=${2:?$usage}
haptic_package=${3:?$usage}
settings_script=${4:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
locked_omp_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-agent-reconcile-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT
render_config="$scratch/render.toml"
: >"$render_config"
# A guard that fires AFTER a credential field is resolved (the duplicate check is
# one) still performs a live op read, so isolate the render from host secret
# state: a scratch HOME and a stub op answering with a newline-free value keep
# that read off the host without changing what the guard observes. Set up here,
# ahead of every fixture that renders a template -- including the settings
# section's own U1 null-declaration fixtures below -- rather than only beside
# assert_render_fails/assert_render_ok, so every render shares one HOME.
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"
settings_sh='.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl'

home="$scratch/home"
fake_bin="$scratch/bin"
mkdir -p "$home/.omp/agent" "$fake_bin"

cat >"$home/.omp/agent/.env" <<'EOF'
# user-owned values stay byte-identical
OTHER_TOKEN='keep me'
OPENROUTER_API_KEY=stale
OPENROUTER_API_KEY="duplicate"
EOF
chmod 0644 "$home/.omp/agent/.env"

auth="$home/.omp/agent/.env"
run_auth() {
  local target=${1:-$auth}
  env HOME="$home" OMP_AGENT_ENV="$target" bash "$auth_script"
}
run_auth

[[ $(stat -c '%a' "$auth") == 600 ]]
[[ $(grep -c '^OPENROUTER_API_KEY=' "$auth") -eq 1 ]]
grep -F "# user-owned values stay byte-identical" "$auth" >/dev/null
grep -F "OTHER_TOKEN='keep me'" "$auth" >/dev/null
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$auth" >/dev/null

# Inode identity is the signal that no `mv` happened; this job runs on every
# apply, so an unconditional rename rewrites a credential file forever.
auth_inode_before=$(stat -c '%i' "$auth")
run_auth
[[ $(stat -c '%i' "$auth") == "$auth_inode_before" ]] || {
  printf 'config-omp-auth: a converged re-run republished %s\n' "$auth" >&2
  exit 1
}
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$auth" >/dev/null
[[ $(stat -c '%a' "$auth") == 600 ]]

# The skip path is the only place left that can narrow a mode someone widened.
chmod 0644 "$auth"
run_auth
[[ $(stat -c '%a' "$auth") == 600 ]] || {
  printf 'config-omp-auth: a converged re-run left %s at mode %s\n' "$auth" "$(stat -c '%a' "$auth")" >&2
  exit 1
}
[[ $(stat -c '%i' "$auth") == "$auth_inode_before" ]] || {
  printf 'config-omp-auth: repairing the mode republished %s\n' "$auth" >&2
  exit 1
}
missing="$scratch/missing.env"
cat >"$missing" <<'EOF'
OTHER_TOKEN=present
EOF
chmod 0644 "$missing"
run_auth "$missing"
[[ $(grep -c '^OTHER_TOKEN=' "$missing") -eq 1 ]]
[[ $(grep -c '^OPENROUTER_API_KEY=' "$missing") -eq 1 ]]
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$missing" >/dev/null
ambient="$scratch/ambient.env"
printf 'AMBIENT_TOKEN=keep\n' >"$ambient"
run_auth "$ambient"
grep -F 'AMBIENT_TOKEN=keep' "$ambient" >/dev/null
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$ambient" >/dev/null

# The rendered POSIX script must enforce the ordered managed set.
expected_names="$scratch/expected-managed-names"
printf '%s\n' OPENROUTER_API_KEY >"$expected_names"
posix_names="$scratch/posix-managed-names"
grep -m1 '^MANAGED_NAMES=' "$auth_script" |
  grep -oE '"[A-Z0-9_]+"' | tr -d '"' >"$posix_names"
diff -u "$expected_names" "$posix_names"

printf 'NOT A DOTENV ASSIGNMENT\n' >"$auth"
if run_auth >"$scratch/malformed.out" 2>"$scratch/malformed.err"; then
  printf 'auth reconcile accepted malformed dotenv input\n' >&2
  exit 1
fi
[[ $(cat "$auth") == 'NOT A DOTENV ASSIGNMENT' ]]
grep -F 'refusing malformed dotenv line' "$scratch/malformed.err" >/dev/null

referent="$scratch/referent"
printf 'do not overwrite\n' >"$referent"
rm "$auth"
ln -s "$referent" "$auth"
if run_auth >"$scratch/auth.out" 2>"$scratch/auth.err"; then
  printf 'auth reconcile accepted a symlink target\n' >&2
  exit 1
fi
[[ $(cat "$referent") == 'do not overwrite' ]]
grep -F 'unsafe target' "$scratch/auth.err" >/dev/null

# The rendered POSIX script must carry the data rows, fail-closed lifecycle
# calls, digest/loader checks, migration boundary, locked OMP version, and
# raw-input fingerprint set.
for needle in \
  'mxm4-haptic@h82-dotfiles' \
  'compound-engineering' \
  'plugin marketplace add' \
  'plugin install --scope user --force' \
  'plugin enable --scope user' \
  'payload digest' \
  'loader health' \
  'legacy'; do
  grep -F "$needle" "$plugin_script" >/dev/null
done

# i-have-adhd is retired from the plugin reconciler: removal commands are
# emitted and no install/enable/marketplace-add commands target it.
grep -F 'i-have-adhd\ti-have-adhd' "$plugin_script" >/dev/null
grep -F 'plugin uninstall --scope user' "$plugin_script" >/dev/null
grep -F 'plugin marketplace remove' "$plugin_script" >/dev/null
if grep -qE 'plugin (install --scope user --force|enable --scope user|marketplace add) .*i-have-adhd' "$plugin_script"; then
  printf 'rendered plugin updater still installs or adds i-have-adhd\n' >&2
  exit 1
fi

# h82-dotfiles still hosts mxm4-haptic, so the removal set must leave it out.
grep -F 'unmanaged-repo-guard\th82-dotfiles' "$plugin_script" >/dev/null
removed_marketplaces="$scratch/removed-marketplaces"
awk '/^MARKETPLACES_REMOVED=\($/{flag=1;next} /^\)/{flag=0} flag' \
  "$plugin_script" >"$removed_marketplaces"
grep -F 'i-have-adhd' "$removed_marketplaces" >/dev/null
if grep -qF 'h82-dotfiles' "$removed_marketplaces"; then
  printf 'rendered plugin updater removes the surviving h82-dotfiles marketplace\n' >&2
  exit 1
fi

grep -F "readonly EXPECTED_OMP_VERSION='$locked_omp_version'" "$plugin_script" >/dev/null
posix_fingerprints="$scratch/posix-plugin-fingerprints"
grep '^#   ' "$plugin_script" >"$posix_fingerprints"
[[ -s $posix_fingerprints ]]
for raw_input in \
  '.chezmoidata/agents.yaml' \
  '.chezmoidata/haptic.yaml' \
  '.chezmoidata/releases.json' \
  'packages/bun.lock' \
  'packages/mxm4-haptic/src/omp-plugin.ts'; do
  grep -F "#   $raw_input  " "$posix_fingerprints" >/dev/null
done
[[ -f $haptic_package/package.json && -f $haptic_package/dist/index.js ]]
source="$home/.local/share/omp-plugins"
mkdir -p "$source/.omp-plugin" "$source/plugins" "$home/.local/share/compound-engineering/v-test/.claude-plugin"
cp -R "$haptic_package" "$source/plugins/mxm4-haptic"
cat >"$source/.omp-plugin/marketplace.json" <<'EOF'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"mxm4-haptic","source":"./plugins/mxm4-haptic"}]}
EOF
cat >"$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json" <<'EOF'
{"name":"compound-engineering-plugin","plugins":[{"name":"compound-engineering","source":"./"}]}
EOF

# Rendered local paths are immutable desired state. Relocate them into the
# isolated HOME without letting the provisioner consult the live HOME.
test_plugin="$scratch/plugins.sh"
cp "$plugin_script" "$test_plugin"
haptic_row=$(grep -m1 'mxm4-haptic\\th82-dotfiles\\tlocalDir\\t' "$test_plugin")
rendered_haptic=${haptic_row#*localDir\\t}
rendered_haptic=${rendered_haptic%%\\t*}
ce_row=$(grep -m1 'compound-engineering\\tcompound-engineering-plugin\\tlocalArchive\\t' "$test_plugin")
rendered_ce=${ce_row#*localArchive\\t}
rendered_ce=${rendered_ce%%\\t*}
sed -i "s|$rendered_haptic|$source|g; s|$rendered_ce|$home/.local/share/compound-engineering/v-test|g" "$test_plugin"
chmod 0700 "$test_plugin"

path_guard_line=$(grep -m1 -nF 'case ":$PATH:"' "$test_plugin" | cut -d: -f1)
omp_probe_line=$(grep -m1 -nF 'command -v omp' "$test_plugin" | cut -d: -f1)
[[ $path_guard_line -lt $omp_probe_line ]]
grep -F 'PATH="$HOME/.local/bin:$PATH"' "$test_plugin" >/dev/null
grep -F 'export PATH' "$test_plugin" >/dev/null


# The stub answers --version in the real binary's omp/<version> format so the
# reconciler's preflight is tested against reality, not a shape omp never prints.
# OMP_STUB_VERSION replaces the whole emitted string for reject coverage.
cat >"$fake_bin/omp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OMP_CALLS"
[[ ${1-} == --version ]] && { printf '%s\n' "${OMP_STUB_VERSION:-omp/${EXPECTED_OMP_VERSION:?}}"; exit 0; }
if [[ -n ${OMP_FAIL_MATCH:-} && "$*" == *"$OMP_FAIL_MATCH"* ]]; then exit 72; fi
root="$HOME/.omp/plugins"
mkdir -p "$root"
case "$*" in
  "plugin marketplace add "*/omp-plugins) printf '%s\n' "${*:4}" >"$HOME/.haptic-source" ;;
  "plugin install --scope user --force mxm4-haptic@h82-dotfiles")
    source=$(cat "$HOME/.haptic-source")
    install="$root/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0"
    rm -rf "$install"; mkdir -p "$(dirname "$install")"; cp -R "$source/plugins/mxm4-haptic" "$install"
    mkdir -p "$root/node_modules/@h82"; ln -sfn "$install" "$root/node_modules/@h82/omp-mxm4-haptic"
    cat >"$root/installed_plugins.json" <<JSON
{"version":2,"plugins":{"mxm4-haptic@h82-dotfiles":[{"scope":"user","installPath":"$install","version":"0.0.0"}]}}
JSON
    ;;
  "plugin enable --scope user mxm4-haptic@h82-dotfiles")
    printf '%s\n' '{"plugins":{"@h82/omp-mxm4-haptic":{"version":"0.0.0","enabled":true}},"settings":{}}' >"$root/omp-plugins.lock.json"
    ;;
esac
EOF
chmod 0755 "$fake_bin/omp"

run_plugins() {
  OMP_CALLS="$1" OMP_FAIL_MATCH="${2-}" OMP_STUB_VERSION="${3-}" EXPECTED_OMP_VERSION="$locked_omp_version" \
    env HOME="$home" PATH="$fake_bin:$PATH" bash "$test_plugin"
}
legacy="$home/.omp/agent/extensions/mxm4-haptic.ts"
mkdir -p "$(dirname "$legacy")"
printf 'legacy owner\n' >"$legacy"
if run_plugins "$scratch/fail.calls" 'plugin enable --scope user mxm4-haptic@h82-dotfiles' >"$scratch/fail.out" 2>"$scratch/fail.err"; then
  printf 'injected enable failure unexpectedly succeeded\n' >&2
  exit 1
fi
[[ -f $legacy ]]

# The version gate rejects mismatched, digit-adjacent, and suffixed decoys
# before any marketplace mutation, and still accepts the bare version form.
for decoy in "omp/0.0.0" "omp/9$locked_omp_version" "omp/$locked_omp_version-rc.1" "omp/${locked_omp_version}9"; do
  label=${decoy//[^a-z0-9]/-}
  if run_plugins "$scratch/version$label.calls" '' "$decoy" >"$scratch/version$label.out" 2>"$scratch/version$label.err"; then
    printf 'version decoy %s unexpectedly passed preflight\n' "$decoy" >&2
    exit 1
  fi
  grep -F 'preflight: expected omp' "$scratch/version$label.err" >/dev/null
  if grep -qF 'plugin marketplace add' "$scratch/version$label.calls"; then
    printf 'version decoy %s reached marketplace mutation\n' "$decoy" >&2
    exit 1
  fi
done
run_plugins "$scratch/version-bare.calls" '' "$locked_omp_version"
# The bare-accept run is a full reconcile and removes the legacy sentinel;
# recreate it so the success runs below still prove their own removal.
printf 'legacy owner\n' >"$legacy"

run_plugins "$scratch/omp.calls"
[[ ! -e $legacy ]]
run_plugins "$scratch/repeat.calls"
[[ ! -e $legacy ]]
[[ $(grep -c 'plugin install --scope user --force mxm4-haptic@h82-dotfiles' "$scratch/repeat.calls") -eq 1 ]]
[[ $(grep -c 'plugin enable --scope user mxm4-haptic@h82-dotfiles' "$scratch/repeat.calls") -eq 1 ]]
grep -F 'plugin install --scope user --force compound-engineering@compound-engineering-plugin' "$scratch/omp.calls" >/dev/null
grep -F 'plugin enable --scope user compound-engineering@compound-engineering-plugin' "$scratch/omp.calls" >/dev/null

# The removal loop runs before install, so a removed plugin is not re-added.
grep -F 'plugin uninstall --scope user i-have-adhd@i-have-adhd' "$scratch/omp.calls" >/dev/null
grep -F 'plugin marketplace remove i-have-adhd' "$scratch/omp.calls" >/dev/null
if grep -qE 'plugin (install --scope user --force|enable --scope user) i-have-adhd@i-have-adhd|plugin marketplace add [^ ]*i-have-adhd' "$scratch/omp.calls"; then
  printf 'reconciler still installs or adds i-have-adhd\n' >&2
  exit 1
fi

# The install loop's remove-then-re-add refresh is also a marketplace remove,
# so the proof is count plus the immediately following re-add, not absence.
grep -F 'plugin uninstall --scope user unmanaged-repo-guard@h82-dotfiles' "$scratch/omp.calls" >/dev/null
[[ $(grep -cF 'plugin marketplace remove h82-dotfiles' "$scratch/omp.calls") -eq 1 ]]
grep -A1 -F 'plugin marketplace remove h82-dotfiles' "$scratch/omp.calls" |
  tail -1 | grep -F 'plugin marketplace add' >/dev/null

mv "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json" \
  "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json.off"
if run_plugins "$scratch/ce-manifest.calls" >"$scratch/ce-manifest.out" 2>"$scratch/ce-manifest.err"; then
  printf 'missing compound-engineering manifest unexpectedly succeeded\n' >&2
  exit 1
fi
mv "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json.off" \
  "$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json"
grep -F 'preflight: pinned marketplace is missing' "$scratch/ce-manifest.err" >/dev/null
if grep -qF 'plugin marketplace add' "$scratch/ce-manifest.calls"; then
  printf 'missing CE manifest reached marketplace mutation\n' >&2
  exit 1
fi

# Same-version package/config changes must replace the full installed payload.
printf '\n// same-version payload change\n' >>"$source/plugins/mxm4-haptic/dist/index.js"
run_plugins "$scratch/update.calls"
cmp "$source/plugins/mxm4-haptic/package.json" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/package.json"
cmp "$source/plugins/mxm4-haptic/dist/index.js" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/dist/index.js"
bun "$(dirname "$0")/test-omp-haptic-plugin.ts" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0"

fallback_bin="$scratch/fallback-bin"
mkdir -p "$fallback_bin"
bun_source=$(command -v bun)
ln -s "$bun_source" "$fallback_bin/bun"

run_fallback() {
  OMP_CALLS="$1" OMP_FAIL_MATCH="${2-}" OMP_STUB_VERSION="${3-}" EXPECTED_OMP_VERSION="$locked_omp_version" \
    env HOME="$home" PATH="$fallback_bin:/usr/bin:/bin" bash "$test_plugin"
}

if run_fallback "$scratch/fallback-noomp.calls" >"$scratch/fallback-noomp.out" 2>"$scratch/fallback-noomp.err"; then
  printf 'fallback run without local omp unexpectedly succeeded\n' >&2
  exit 1
fi
grep -F 'preflight: omp is not on PATH' "$scratch/fallback-noomp.err" >/dev/null

mkdir -p "$home/.local/bin"
cp "$fake_bin/omp" "$home/.local/bin/omp"
printf 'legacy owner\n' >"$legacy"
run_fallback "$scratch/fallback.calls"
grep -F 'plugin install --scope user --force mxm4-haptic@h82-dotfiles' "$scratch/fallback.calls" >/dev/null
grep -F 'plugin enable --scope user mxm4-haptic@h82-dotfiles' "$scratch/fallback.calls" >/dev/null
grep -F 'plugin install --scope user --force compound-engineering@compound-engineering-plugin' "$scratch/fallback.calls" >/dev/null
grep -F 'plugin enable --scope user compound-engineering@compound-engineering-plugin' "$scratch/fallback.calls" >/dev/null
rm -f "$home/.local/bin/omp"


# --- declared omp settings assertion ---------------------------------------
# CI can prove the provisioner's CALL SHAPE and its catalog branches. It cannot
# prove omp's file-merge semantics: this stub writes no config.yml and the job
# installs no omp, so a byte-level preservation assertion would pass vacuously.
# R10's sibling-preservation guarantee is the documented manual probe against a
# relocated PI_CODING_AGENT_DIR, not this test.
settings_home="$scratch/settings-home"
settings_bin="$scratch/settings-bin"
mkdir -p "$settings_home" "$settings_bin"
cat >"$settings_bin/omp" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = "models" ]; then
  if [ -n "${CANNED_CATALOG-}" ]; then
    cat "$CANNED_CATALOG"
    exit 0
  fi
  printf 'no catalog\n' >&2
  exit 1
fi
# A read is never recorded: every call-count assertion below counts mutations.
if [ "${1-}" = "config" ] && [ "${2-}" = "list" ]; then
  if [ -n "${CANNED_LIVE-}" ]; then
    cat "$CANNED_LIVE"
    exit 0
  fi
  printf 'no live config\n' >&2
  exit 1
fi
printf '%s\n' "$*" >>"$OMP_CALLS"
EOF
chmod 0755 "$settings_bin/omp"

# The declared map is embedded in the rendered script, so the fixtures below
# track the data instead of hardcoding a model list that would rot.
declared_json="$scratch/declared.json"
awk '/^cat >"\$declared"/{flag=1;next}/^JSON$/{flag=0}flag' "$settings_script" >"$declared_json"
jq -e 'type == "object" and (keys | length) > 0' "$declared_json" >/dev/null
jq -e '
  .enabledModels == [
    "anthropic/claude-fable-5",
    "anthropic/claude-opus-5",
    "anthropic/claude-sonnet-5",
    "google-antigravity/gemini-3.*",
    "kimi-code/*"
  ]
  and (."retry.fallbackChains" | has("default"))
' "$declared_json" >/dev/null || {
  printf 'model whitelist policy is not rendered as expected\n' >&2
  exit 1
}

# kimi-code stays whitelisted for manual /model switching while its
# subscription winds down, but nothing automatic may route to it: the
# apply-time catalog gate fails open once the provider is unauthenticated, so
# this assertion is the only barrier between a retune and a dead recovery.
# It covers roles, agent overrides, and chain hops, because a hop written as
# a role alias would otherwise bypass a chains-only check. It stays true
# after the eventual whitelist removal and may be dropped together with the
# `kimi-code/*` entry, never before.
kimi_refs=$(jq -r '
  [ (.modelRoles // {} | to_entries[].value),
    (."task.agentModelOverrides" // {} | to_entries[].value),
    (."retry.fallbackChains" // {} | to_entries[].value[]) ]
  | map(select(type == "string"))
  | map(select(startswith("kimi-code/"))) | .[]
' "$declared_json")
if [[ -n $kimi_refs ]]; then
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    printf 'kimi-code automatic-routing guard: %s names kimi-code, but kimi-code is whitelisted for manual /model switching only while its subscription winds down; no role, agent override, or fallback chain may route to it\n' "$ref" >&2
  done <<<"$kimi_refs"
  exit 1
fi

# The harvest is shared by the catalog fixture and the shape check. A chain KEY
# is a selector too when it is model-oriented, so it must be harvested alongside
# the hop values. It is filtered HERE rather than downstream because the shape
# check below consumes this harvest raw: a role-keyed chain key is not a selector
# and would fail that check as a malformed one.
harvest_selectors='
  def strip_thinking: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  [ (.modelRoles // {} | to_entries[].value),
    (."task.agentModelOverrides" // {} | to_entries[].value),
    (."retry.fallbackChains" // {} | to_entries[].value[]),
    (."retry.fallbackChains" // {} | to_entries[] | .key | select(contains("/"))) ]
  | map(select(type == "string")) | map(select(startswith("@") | not))'

jq -r "$harvest_selectors
  | map(strip_thinking) | map(select(endswith(\"/*\") | not))
  | map(select(contains(\"/\"))) | unique
  | {models: map({provider: (split(\"/\")[0]), selector: .})}
" "$declared_json" >"$scratch/catalog-full.json"
jq -e '(.models | length) > 0' "$scratch/catalog-full.json" >/dev/null

# Chain reachability, asserted against the SHIPPED data rather than a fixture.
# omp looks a chain up by the failing model id, so a model-keyed chain whose
# model no role, agent override, or hop ever produces is dead data — the symptom
# is a tier that silently loses its recovery path after a retune.
#
# This cannot be a render-time check in the validator, and that is not a style
# choice: `--override-data` DEEP-MERGES, so every fixture that retunes one role
# inherits the real chains and manufactures an orphan the validator would then
# reject. The invariant is global over one complete policy, so it is checked once
# here, over exactly the data that ships. A key naming a HOP is legitimate: that
# hop can fail and own a chain in turn.
unnamed=$(jq -r '
  def strip_thinking: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  ([ (.modelRoles // {} | to_entries[].value),
     (."task.agentModelOverrides" // {} | to_entries[].value),
     (."retry.fallbackChains" // {} | to_entries[].value[])
   ] | map(select(type == "string") | select(startswith("@") | not) | strip_thinking) | unique) as $named
  | (."retry.fallbackChains" // {} | keys | map(select(contains("/"))))
  | map(select(strip_thinking as $k | ($named | index($k)) == null))
  | .[]
' "$declared_json")
if [[ -n $unnamed ]]; then
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    printf 'chain-reachability: retry.fallbackChains is keyed on %s, which no modelRoles selector, task.agentModelOverrides value, or chain hop names; omp looks a chain up by the failing model id, so it can never be consulted\n' "$key" >&2
  done <<<"$unnamed"
  exit 1
fi

declared_count=$(jq -r 'keys | length' "$declared_json")

# An absent third argument leaves CANNED_LIVE empty, so the live read fails and
# the provisioner asserts every declared path. That keeps every pre-existing
# two-argument case below at its original meaning.
run_settings() {
  local label=$1 catalog=$2 live=${3-}
  : >"$scratch/$label.calls"
  # An empty CANNED_CATALOG and an unset one take the same stub path, so the
  # assignment needs no fork.
  OMP_CALLS="$scratch/$label.calls" CANNED_CATALOG="$catalog" CANNED_LIVE="$live" \
    env HOME="$settings_home" PATH="$settings_bin:$PATH" \
    bash "$settings_script" >"$scratch/$label.out" 2>"$scratch/$label.err"
}

# One assertion per declared path, at the exact value the contract requires, and
# never at a parent namespace. Comparing the whole recorded call is what makes
# this load-bearing: a prefix match passes even when the provisioner delivers
# every record as a literal string, which is the entire model policy.
run_settings full "$scratch/catalog-full.json"
[[ $(wc -l <"$scratch/full.calls") -eq $declared_count ]]
while IFS=$'\t' read -r verb path want; do
  case $verb in
    set)
      grep -qxF "config set $path $want" "$scratch/full.calls" || {
        printf 'settings assertion did not deliver declared path %s as %s\n' "$path" "$want" >&2
        printf '  recorded: %s\n' "$(grep -F "config set $path " "$scratch/full.calls" || echo '(absent)')" >&2
        exit 1
      }
      ;;
    reset)
      grep -qxF "config reset $path" "$scratch/full.calls" || {
        printf 'settings assertion did not reset declared null path %s\n' "$path" >&2
        exit 1
      }
      ;;
  esac
done < <(jq -r '
  to_entries[]
  | [ (if .value == null then "reset" else "set" end),
      .key,
      (if .value == null then "" elif (.value | type) == "string" then .value else (.value | tojson) end) ]
  | @tsv
' "$declared_json")
# Derived from the declared keys, so a newly declared dotted path is guarded too.
while IFS= read -r parent; do
  if grep -qF "config set $parent " "$scratch/full.calls" || grep -qxF "config reset $parent" "$scratch/full.calls"; then
    printf 'settings assertion wrote parent namespace %s\n' "$parent" >&2
    exit 1
  fi
done < <(jq -r 'keys[] | select(contains(".")) | split(".")[0]' "$declared_json" | sort -u)
grep -F "asserted $declared_count of $declared_count declared omp settings paths" "$scratch/full.out" >/dev/null

# A selector the catalog covers by provider but does not serve aborts the apply
# before anything is written.
absent_selector=$(jq -r 'first(.models[] | select(.provider == "anthropic") | .selector) // ""' "$scratch/catalog-full.json")
[[ -n $absent_selector ]] || {
  printf 'fixture found no anthropic selector to withhold; the absent-selector case is not being exercised\n' >&2
  exit 1
}
jq --arg s "$absent_selector" '
  .models |= (map(select(.selector != $s)) + [
    {provider: "anthropic", selector: "anthropic/fixture-survivor"}
  ])
' "$scratch/catalog-full.json" >"$scratch/catalog-absent.json"
if run_settings absent "$scratch/catalog-absent.json"; then
  printf 'settings assertion accepted a selector the catalog does not serve\n' >&2
  exit 1
fi
grep -F "names $absent_selector" "$scratch/absent.err" >/dev/null
grep -F 'does not serve' "$scratch/absent.err" >/dev/null
[[ ! -s "$scratch/absent.calls" ]]

# A provider the catalog cannot speak for is not evidence of an absent selector.
jq '.models |= map(select(.provider != "anthropic"))' \
  "$scratch/catalog-full.json" >"$scratch/catalog-noprovider.json"
run_settings noprovider "$scratch/catalog-noprovider.json"
grep -F 'catalog has no anthropic models' "$scratch/noprovider.err" >/dev/null
[[ $(wc -l <"$scratch/noprovider.calls") -eq $declared_count ]]

# An unparseable catalog and a failing probe both fail open.
printf 'not json\n' >"$scratch/catalog-bad.json"
run_settings badcatalog "$scratch/catalog-bad.json"
grep -F 'model catalog unavailable' "$scratch/badcatalog.err" >/dev/null
[[ $(wc -l <"$scratch/badcatalog.calls") -eq $declared_count ]]

run_settings failcatalog ''
grep -F 'model catalog unavailable' "$scratch/failcatalog.err" >/dev/null
[[ $(wc -l <"$scratch/failcatalog.calls") -eq $declared_count ]]

# --- convergence against the live config -----------------------------------
# A blind `omp config set` per declared path spends one subprocess per path on
# every apply, so the provisioner must read live state and mutate only drift.
jq 'to_entries
  | map({key: .key, value: (if .value == null then {type: "any", description: ""} else {value: .value, type: "any", description: ""} end)})
  | from_entries' "$declared_json" >"$scratch/live-converged.json"
run_settings converged "$scratch/catalog-full.json" "$scratch/live-converged.json"
[[ ! -s "$scratch/converged.calls" ]] || {
  printf 'settings assertion re-asserted %d already-correct paths\n' \
    "$(wc -l <"$scratch/converged.calls")" >&2
  sed 's/^/  /' "$scratch/converged.calls" >&2
  exit 1
}
grep -F "asserted 0 of $declared_count declared omp settings paths" "$scratch/converged.out" >/dev/null

# Exactly the drifted paths are asserted, and both drift shapes count: a live
# value that differs, and a path the live config does not carry at all. The
# absent shape is what keeps an unset declared path converging.
drift_key=$(jq -r 'to_entries | map(select((.value | type) == "boolean")) | .[0].key // ""' "$declared_json")
absent_key=$(jq -r --arg d "$drift_key" 'to_entries | map(select(.key != $d and .value != null)) | .[0].key // ""' "$declared_json")
[[ -n $drift_key && -n $absent_key ]] || {
  printf 'fixture found no boolean plus spare declared key; the partial-drift case is not being exercised\n' >&2
  exit 1
}
jq --arg d "$drift_key" --arg a "$absent_key" '
  (.[$d].value) |= (. | not) | del(.[$a])
' "$scratch/live-converged.json" >"$scratch/live-partial.json"
run_settings partial "$scratch/catalog-full.json" "$scratch/live-partial.json"
[[ $(wc -l <"$scratch/partial.calls") -eq 2 ]] || {
  printf 'settings assertion delivered %d calls for exactly two drifted paths\n' \
    "$(wc -l <"$scratch/partial.calls")" >&2
  sed 's/^/  /' "$scratch/partial.calls" >&2
  exit 1
}
drift_want=$(jq -r --arg d "$drift_key" '.[$d] | tojson' "$declared_json")
grep -qxF "config set $drift_key $drift_want" "$scratch/partial.calls" || {
  printf 'settings assertion did not re-assert drifted path %s as %s\n' "$drift_key" "$drift_want" >&2
  exit 1
}
grep -qF "config set $absent_key " "$scratch/partial.calls" || {
  printf 'settings assertion did not assert live-absent path %s\n' "$absent_key" >&2
  exit 1
}
grep -F "asserted 2 of $declared_count declared omp settings paths" "$scratch/partial.out" >/dev/null

# An unreadable live config fails OPEN: a provisioner that cannot see live state
# must still deliver the declared set, exactly as it did before this check.
run_settings nolive "$scratch/catalog-full.json" "$scratch/does-not-exist.json"
[[ $(wc -l <"$scratch/nolive.calls") -eq $declared_count ]] || {
  printf 'an unreadable live config suppressed %d of %d declared assertions\n' \
    "$((declared_count - $(wc -l <"$scratch/nolive.calls")))" "$declared_count" >&2
  exit 1
}
grep -F 'could not read the live config' "$scratch/nolive.err" >/dev/null

# --- null-value reconcile (U1) ----------------------------------------------
# A declared null resets a path to omp's upstream default (KTD1), and the
# shipped data carries the first one: providers.webSearchGeminiModel. The
# harvested fixtures above already exercise that real declaration end-to-end
# through their null-aware branches. These fixtures instead render a second
# settings script with one synthetic null-valued scalar added via
# --override-data -- the same mechanism assert_render_ok and
# assert_render_fails use below -- so the single-reset arithmetic and the
# admission rules stay pinned independently of whatever the shipped data
# happens to declare. Convergence for a null path is proven against the
# live-entry shape real omp emits for empty-default keys (the unset entry
# omits `value`); a key whose unset entry carries its schema default under
# `value` would reset on every apply, so null is only valid for the
# empty-default class.
null_path=u1NullFixturePath
null_settings_script="$scratch/null-settings.sh"
env HOME="$neg_home" PATH="$neg_bin:$PATH" \
  chezmoi --config "$render_config" --source "$repo_root" \
  --override-data "{\"chezmoi\":{\"os\":\"linux\"},\"agents\":{\"omp\":{\"settings\":{\"$null_path\":null}}}}" \
  execute-template <"$repo_root/$settings_sh" >"$null_settings_script"
chmod 0755 "$null_settings_script"

null_declared_json="$scratch/null-declared.json"
awk '/^cat >"\$declared"/{flag=1;next}/^JSON$/{flag=0}flag' "$null_settings_script" >"$null_declared_json"
jq -e --arg p "$null_path" 'has($p) and (.[$p] == null)' "$null_declared_json" >/dev/null
null_declared_count=$(jq -r 'keys | length' "$null_declared_json")

run_settings_for() {
  local script=$1 label=$2 catalog=$3 live=${4-}
  : >"$scratch/$label.calls"
  OMP_CALLS="$scratch/$label.calls" CANNED_CATALOG="$catalog" CANNED_LIVE="$live" \
    env HOME="$settings_home" PATH="$settings_bin:$PATH" \
    bash "$script" >"$scratch/$label.out" 2>"$scratch/$label.err"
}

jq 'to_entries
  | map({key: .key, value: (if .value == null then {type: "any", description: ""} else {value: .value, type: "any", description: ""} end)})
  | from_entries' "$null_declared_json" >"$scratch/null-live-converged.json"

# Declared null + live entry has `value` -> exactly one reset, and no set
# fires for that path.
jq --arg p "$null_path" '.[$p] = {value: "stale", type: "any"}' \
  "$scratch/null-live-converged.json" >"$scratch/null-live-reset.json"
run_settings_for "$null_settings_script" null-reset "$scratch/catalog-full.json" "$scratch/null-live-reset.json"
[[ $(wc -l <"$scratch/null-reset.calls") -eq 1 ]] || {
  printf 'declared null with a live value delivered %d calls, want exactly one reset\n' \
    "$(wc -l <"$scratch/null-reset.calls")" >&2
  sed 's/^/  /' "$scratch/null-reset.calls" >&2
  exit 1
}
grep -qxF "config reset $null_path" "$scratch/null-reset.calls" || {
  printf 'declared null with a live value did not reset %s\n' "$null_path" >&2
  exit 1
}
grep -F "asserted 1 of $null_declared_count declared omp settings paths" "$scratch/null-reset.out" >/dev/null

# Declared null + live entry lacks `value` -> converged; zero calls, proving
# second-apply idempotence.
run_settings_for "$null_settings_script" null-converged "$scratch/catalog-full.json" "$scratch/null-live-converged.json"
[[ ! -s "$scratch/null-converged.calls" ]] || {
  printf 'declared null with no live value still fired %d calls\n' \
    "$(wc -l <"$scratch/null-converged.calls")" >&2
  sed 's/^/  /' "$scratch/null-converged.calls" >&2
  exit 1
}
grep -F "asserted 0 of $null_declared_count declared omp settings paths" "$scratch/null-converged.out" >/dev/null

# Mixed declaration -- one null path plus one drifted scalar -> one reset and
# one set, and examined equals the declared count so the incomplete-stream
# guard does not fire.
null_drift_key=$(jq -r --arg p "$null_path" \
  'to_entries | map(select((.value | type) == "boolean" and .key != $p)) | .[0].key // ""' \
  "$null_declared_json")
[[ -n $null_drift_key ]] || {
  printf 'null fixture found no boolean declared key alongside the null path; the mixed case is not being exercised\n' >&2
  exit 1
}
jq --arg p "$null_path" --arg d "$null_drift_key" '
  (.[$d].value) |= (. | not) | .[$p] = {value: "stale", type: "any"}
' "$scratch/null-live-converged.json" >"$scratch/null-live-mixed.json"
run_settings_for "$null_settings_script" null-mixed "$scratch/catalog-full.json" "$scratch/null-live-mixed.json"
[[ $(wc -l <"$scratch/null-mixed.calls") -eq 2 ]] || {
  printf 'mixed null-plus-drift declaration delivered %d calls, want exactly two\n' \
    "$(wc -l <"$scratch/null-mixed.calls")" >&2
  sed 's/^/  /' "$scratch/null-mixed.calls" >&2
  exit 1
}
grep -qxF "config reset $null_path" "$scratch/null-mixed.calls" || {
  printf 'mixed null-plus-drift declaration did not reset %s\n' "$null_path" >&2
  exit 1
}
null_drift_want=$(jq -r --arg d "$null_drift_key" '.[$d] | tojson' "$null_declared_json")
grep -qxF "config set $null_drift_key $null_drift_want" "$scratch/null-mixed.calls" || {
  printf 'mixed null-plus-drift declaration did not re-assert drifted path %s as %s\n' \
    "$null_drift_key" "$null_drift_want" >&2
  exit 1
}
grep -F "asserted 2 of $null_declared_count declared omp settings paths" "$scratch/null-mixed.out" >/dev/null

# Failed live read (the {} fallback) -> a null-declared path still records a
# reset call, so every no-live fixture keeps its one-call-per-declared-path
# arithmetic.
run_settings_for "$null_settings_script" null-nolive "$scratch/catalog-full.json" "$scratch/does-not-exist.json"
[[ $(wc -l <"$scratch/null-nolive.calls") -eq $null_declared_count ]] || {
  printf 'an unreadable live config suppressed %d of %d declared assertions for the null fixture\n' \
    "$((null_declared_count - $(wc -l <"$scratch/null-nolive.calls")))" "$null_declared_count" >&2
  exit 1
}
grep -qxF "config reset $null_path" "$scratch/null-nolive.calls" || {
  printf 'an unreadable live config did not blind-fire a reset for null-declared %s\n' "$null_path" >&2
  exit 1
}
grep -F 'could not read the live config' "$scratch/null-nolive.err" >/dev/null

# omp lists every schema key even when unset, so a null path absent from a
# successful live listing is dead data (a typo); it must fail loudly.
jq --arg p "$null_path" 'del(.[$p])' \
  "$scratch/null-live-converged.json" >"$scratch/null-live-unknown.json"
if run_settings_for "$null_settings_script" null-unknown "$scratch/catalog-full.json" "$scratch/null-live-unknown.json"; then
  printf 'declared null on a schema-absent path converged silently; want a loud failure\n' >&2
  exit 1
fi
grep -F 'is absent from the live omp settings schema' "$scratch/null-unknown.err" >/dev/null

# A missing omp binary is a soft skip, not a failed apply.
env HOME="$settings_home" PATH="/usr/bin:/bin" bash "$settings_script" \
  >"$scratch/noomp.out" 2>"$scratch/noomp.err"
grep -F 'omp is unavailable' "$scratch/noomp.err" >/dev/null

# A live-catalog freshness probe is not possible here: the job installs no omp
# and holds no provider credentials. This shape check is the feasible
# substitute — it catches a typo in a provider, a model id, or a thinking level
# at PR time, while the provisioner's own catalog gate catches a retired id on
# the host that actually has the credentials.
mapfile -t declared_selectors < <(jq -r "$harvest_selectors | unique | .[]" "$declared_json")
[[ ${#declared_selectors[@]} -gt 0 ]] || {
  printf 'no declared model selectors extracted; the selector shape check would pass vacuously\n' >&2
  exit 1
}
for selector in "${declared_selectors[@]}"; do
  if [[ ! $selector =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?/[A-Za-z0-9._*-]+(:(off|minimal|low|medium|high|xhigh|max))?$ ]]; then
    printf 'malformed declared model selector: %s\n' "$selector" >&2
    exit 1
  fi
done

# Render-time guards are structurally invisible to every test above, which receives
# already-rendered scripts. These cases fail the RENDER, the only layer that can
# still catch them: the apply-time catalog gate skips role aliases by design, and
# omp stores a nonsense selector silently. Requires chezmoi, which the job that
# rendered the scripts under test already installed. repo_root, render_config,
# and the neg_home/neg_bin op stub were set up near the top of this script.
assert_render_fails() {
  local label=$1 template=$2 data=$3 want=$4
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$template" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    printf 'render-negative %s: expected a failed render, got exit 0\n' "$label" >&2
    exit 1
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-negative %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}
# `--override-data` DEEP-MERGES into the repo's real agents.yaml, so a fixture can
# only add a bad value — it can never express an ABSENT key, because the real
# declaration survives the merge. This renders inline template text that builds
# its own settings dict, which is the only way to test absence.
assert_partial_fails() {
  local label=$1 body=$2 want=$3
  printf '%s\n' "$body" >"$scratch/partial.tmpl"
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" \
    execute-template <"$scratch/partial.tmpl" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    printf 'render-partial %s: expected a failed render, got exit 0\n' "$label" >&2
    exit 1
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-partial %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}
assert_render_ok() {
  local label=$1 template=$2 data=$3
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$template" >"$scratch/pos.out" 2>"$scratch/pos.err" || {
    printf 'render-positive %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$scratch/pos.err" >&2
    exit 1
  }
}

auth_sh='.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl'
linux='"chezmoi":{"os":"linux"}'
roles='"modelRoles":{"default":"anthropic/claude-opus-5:xhigh"}'
models_yml='dot_omp/private_agent/private_readonly_models.yml.tmpl'
closed_set='OPENROUTER_API_KEY'

# The credential set is closed on both platforms so a data edit cannot inject a
# variable into the environment omp loads for every session, nor silently drop
# one.
assert_render_fails auth-outside-closed-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"NODE_OPTIONS\",\"key\":\"x\"}]}}}}" \
  "declares unsupported variable \"NODE_OPTIONS\"; the closed set is $closed_set"
assert_render_fails auth-emptied-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[]}}}}" \
  'must declare OPENROUTER_API_KEY'
assert_render_fails auth-duplicate-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"OPENROUTER_API_KEY\",\"key\":\"a\"},{\"variable\":\"OPENROUTER_API_KEY\",\"key\":\"b\"}]}}}}" \
  'duplicates variable "OPENROUTER_API_KEY"'
assert_render_fails auth-empty-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"OPENROUTER_API_KEY\",\"key\":\"\"}]}}}}" \
  'resolved to an empty value'
assert_render_fails auth-non-string-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"OPENROUTER_API_KEY\",\"key\":[\"not-a-string\"]}]}}}}" \
  'field `key` must resolve to a string'

# Role indirection is the one value shape no later layer validates.
assert_render_fails settings-dangling-alias "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"task.agentModelOverrides\":{\"commit\":\"@no-such-role\"}}}}}" \
  'names role alias @no-such-role'
# A chain key means a model when it contains a slash and a role when it does not.
# Both illegal shapes are invisible to the catalog gate: it strips the thinking
# suffix before comparing, and it treats a wildcard as routing syntax.
assert_render_fails settings-orphan-chain "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"ghost\":[\"anthropic/claude-opus-5:xhigh\"]}}}}}" \
  'is neither a provider/model-id selector nor a declared modelRoles role'
assert_render_fails settings-wildcard-chain-key "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/*\":[\"anthropic/claude-sonnet-5\"]}}}}}" \
  'is a provider wildcard'
assert_render_fails settings-suffixed-chain-key "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5:max\":[\"anthropic/claude-sonnet-5\"]}}}}}" \
  'carries a thinking suffix'
# The positive fixture uses a surviving Anthropic selector. The model metadata
# checks below must stay coupled to a declared selector without a retired
# provider fixture.
assert_render_ok settings-model-keyed-chain "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5\":[\"anthropic/claude-sonnet-5\"]}}}}}"
# agents.omp.models is parasitic on the settings: an override nothing declares is
# dead data omp ignores, only modelOverrides may appear under a provider, and the
# credential-free contract applies to it too. Its diagnostics name that surface.
models_settings="$roles,\"retry.fallbackChains\":{\"anthropic/claude-opus-5\":[\"anthropic/claude-sonnet-5\"]}"
assert_render_ok models-declared-override "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"anthropic\":{\"modelOverrides\":{\"claude-opus-5\":{\"contextWindow\":262144}}}}}}}}"
assert_render_fails models-undeclared-override "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"anthropic\":{\"modelOverrides\":{\"claude-k9\":{\"contextWindow\":262144}}}}}}}}" \
  'which no declared agents.omp.settings selector names'
assert_render_fails models-non-override-key "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"anthropic\":{\"baseUrl\":\"https://x.invalid\"}}}}}}" \
  'but only modelOverrides is permitted here'
assert_render_fails models-credential-reference "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"anthropic\":{\"modelOverrides\":{\"claude-opus-5\":{\"headers\":{\"X\":\"op://Private/x/y\"}}}}}}}}}" \
  'provider anthropic carries an op:// reference'
assert_render_fails models-credential-provider-key "$models_yml" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$models_settings},\"models\":{\"providers\":{\"op://Private/x/y\":{}}}}}}" \
  'agents.omp.models carries an op:// reference'
# A selector never reaches the shell as a word or a script fragment, but the
# top-level charset check cannot see one: it is gated on a string-typed top-level
# value, and every selector lives inside a record. These two prove the nested
# check that closes that gap — one quote in a selector must not survive a render.
assert_render_fails settings-unsafe-role-selector "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":{\"default\":\"anthropic/claude-opus-5:xhigh\",\"advisor\":\"evil'; touch /tmp/x #/y\"},\"advisor.enabled\":true}}}}" \
  'has a value outside the safe charset'
assert_render_fails settings-unsafe-chain-hop "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"default\":[\"a';id;'/b\"]}}}}}" \
  'has a value outside the safe charset'
# advisor.enabled and modelRoles.advisor are paired by convention only; without
# an advisor role the seat goes inert with nothing naming a cause. This needs the
# inline-text helper: an override cannot delete the real advisor role.
assert_partial_fails settings-advisor-without-role \
  '{{- includeTemplate "omp-settings-validate.tmpl" (dict "ctx" . "settings" (dict "modelRoles" (dict "default" "anthropic/claude-opus-5:xhigh") "advisor.enabled" true) "models" dict) -}}' \
  'modelRoles declares no advisor role'
# A control character anywhere in the value breaks the tab-separated transport.
assert_render_fails settings-nested-control-char "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":{\"default\":\"anthropic/claude-opus-5\txhigh\"}}}}}" \
  'control character or backslash somewhere in its value'
assert_render_fails settings-parent-namespace "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"exa\":true,\"exa.enableSearch\":true}}}}" \
  'is a parent namespace of'
# A declared null resets a path to the upstream default, but only for a plain
# scalar: nulling a record- or list-typed path would silently restore every
# member omp owns beneath it to the upstream default and could bypass selector
# validation (KTD2).
assert_render_fails settings-null-modelRoles "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-agent-overrides "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"task.agentModelOverrides\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-fallback-chains "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-tools-approval "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"tools.approval\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
# The list-typed routing gates get the same fail-closed rejection: a reset
# would restore the upstream default list, re-enabling a disabled provider or
# handing a search order back to the built-in scan.
assert_render_fails settings-null-enabled-models "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"enabledModels\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-disabled-providers "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"disabledProviders\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-websearch-order "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"providers.webSearchOrder\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_fails settings-null-image-order "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"providers.imageOrder\":null}}}}" \
  'owns a record or list that a reset cannot safely wipe'
assert_render_ok settings-null-scalar "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"$null_path\":null}}}}"

printf 'omp auth, plugin, and settings reconcile tests passed\n'
