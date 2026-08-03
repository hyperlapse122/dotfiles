#!/usr/bin/env bash
set -euo pipefail

usage='usage: test-omp-agent-reconcile.sh AUTH_SCRIPT AUTH_PS1 PLUGIN_SCRIPT PLUGIN_PS1 HAPTIC_PACKAGE SETTINGS_SH SETTINGS_PS1'
auth_script=${1:?$usage}
auth_ps1=${2:?$usage}
plugin_script=${3:?$usage}
plugin_ps1=${4:?$usage}
haptic_package=${5:?$usage}
settings_script=${6:?$usage}
settings_ps1=${7:?$usage}
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

home="$scratch/home"
fake_bin="$scratch/bin"
mkdir -p "$home/.omp/agent" "$fake_bin"

cat >"$home/.omp/agent/.env" <<'EOF'
# user-owned values stay byte-identical
OTHER_TOKEN='keep me'
ZAI_API_KEY=stale
ZAI_API_KEY="duplicate"
OPENROUTER_API_KEY=stale
OPENCODE_API_KEY="duplicate"
EOF
chmod 0644 "$home/.omp/agent/.env"

auth="$home/.omp/agent/.env"
run_auth() {
  env HOME="$home" OMP_AGENT_ENV="$auth" bash "$auth_script"
}
run_auth

[[ $(stat -c '%a' "$auth") == 600 ]]
[[ $(grep -c '^ZAI_API_KEY=' "$auth") -eq 1 ]]
[[ $(grep -c '^EXA_API_KEY=' "$auth") -eq 1 ]]
[[ $(grep -c '^OPENROUTER_API_KEY=' "$auth") -eq 1 ]]
[[ $(grep -c '^OPENCODE_API_KEY=' "$auth") -eq 1 ]]
grep -F "# user-owned values stay byte-identical" "$auth" >/dev/null
grep -F "OTHER_TOKEN='keep me'" "$auth" >/dev/null
grep -F 'ZAI_API_KEY="dummy-secret"' "$auth" >/dev/null
grep -F 'EXA_API_KEY="dummy-secret"' "$auth" >/dev/null
grep -F 'OPENROUTER_API_KEY="openrouter-test-secret"' "$auth" >/dev/null
grep -F 'OPENCODE_API_KEY="opencode-test-secret"' "$auth" >/dev/null
ambient="$scratch/ambient.env"
printf 'AMBIENT_TOKEN=keep\n' >"$ambient"
OMP_AGENT_ENV="$ambient" run_auth
[[ $(cat "$ambient") == 'AMBIENT_TOKEN=keep' ]]

# The rendered POSIX and PowerShell scripts must enforce the same ordered set.
expected_names="$scratch/expected-managed-names"
printf '%s\n' ZAI_API_KEY EXA_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY >"$expected_names"
posix_names="$scratch/posix-managed-names"
grep -m1 '^MANAGED_NAMES=' "$auth_script" |
  grep -oE '"[A-Z0-9_]+"' | tr -d '"' >"$posix_names"
ps1_names="$scratch/ps1-managed-names"
grep -m1 '^\$managedNames = ' "$auth_ps1" |
  grep -oE '"[A-Z0-9_]+"' | tr -d '"' >"$ps1_names"
diff -u "$expected_names" "$posix_names"
diff -u "$expected_names" "$ps1_names"

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

# Both rendered platform scripts must carry the same data rows, fail-closed
# lifecycle calls, digest/loader checks, migration boundary, locked OMP
# version, and raw-input fingerprint set.
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
  grep -F "$needle" "$plugin_ps1" >/dev/null
done
grep -F "readonly EXPECTED_OMP_VERSION='$locked_omp_version'" "$plugin_script" >/dev/null
grep -F "\$expectedOmpVersion = '$locked_omp_version'" "$plugin_ps1" >/dev/null
posix_fingerprints="$scratch/posix-plugin-fingerprints"
ps1_fingerprints="$scratch/ps1-plugin-fingerprints"
grep '^#   ' "$plugin_script" >"$posix_fingerprints"
grep '^#   ' "$plugin_ps1" >"$ps1_fingerprints"
[[ -s $posix_fingerprints ]]
diff -u "$posix_fingerprints" "$ps1_fingerprints"
for raw_input in \
  '.chezmoidata/agents.yaml' \
  '.chezmoidata/haptic.yaml' \
  '.chezmoidata/releases.json' \
  'packages/bun.lock' \
  'packages/mxm4-haptic/src/omp-plugin.ts'; do
  grep -F "#   $raw_input  " "$posix_fingerprints" >/dev/null
done
posix_ids=$(grep -oE '[a-z0-9.-]+@[a-z0-9.-]+' "$plugin_script" | sort -u)
ps_ids=$(grep -oE '[a-z0-9.-]+@[a-z0-9.-]+' "$plugin_ps1" | sort -u)
[[ $posix_ids == "$ps_ids" ]]
[[ -f $haptic_package/package.json && -f $haptic_package/dist/index.js ]]
source="$home/.local/share/omp-plugins"
mkdir -p "$source/.omp-plugin" "$source/plugins" "$home/.local/share/compound-engineering/v-test/.claude-plugin"
cp -R "$haptic_package" "$source/plugins/mxm4-haptic"
cat >"$source/.omp-plugin/marketplace.json" <<'EOF'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"mxm4-haptic","source":"./plugins/mxm4-haptic"}]}
EOF
printf '{"name":"compound-engineering-plugin"}\n' >"$home/.local/share/compound-engineering/v-test/.claude-plugin/marketplace.json"

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

# Same-version package/config changes must replace the full installed payload.
printf '\n// same-version payload change\n' >>"$source/plugins/mxm4-haptic/dist/index.js"
run_plugins "$scratch/update.calls"
cmp "$source/plugins/mxm4-haptic/package.json" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/package.json"
cmp "$source/plugins/mxm4-haptic/dist/index.js" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0/dist/index.js"
bun "$(dirname "$0")/test-omp-haptic-plugin.ts" "$home/.omp/plugins/cache/plugins/h82-dotfiles___mxm4-haptic___0.0.0"


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
printf '%s\n' "$*" >>"$OMP_CALLS"
EOF
chmod 0755 "$settings_bin/omp"

# The declared map is embedded in the rendered script, so the fixtures below
# track the data instead of hardcoding a model list that would rot.
declared_json="$scratch/declared.json"
awk '/^cat >"\$declared"/{flag=1;next}/^JSON$/{flag=0}flag' "$settings_script" >"$declared_json"
jq -e 'type == "object" and (keys | length) > 0' "$declared_json" >/dev/null

# The three-source harvest is shared by the catalog fixture and the shape check.
harvest_selectors='
  def strip_thinking: sub(":(off|minimal|low|medium|high|xhigh|max)$"; "");
  [ (.modelRoles // {} | to_entries[].value),
    (."task.agentModelOverrides" // {} | to_entries[].value),
    (."retry.fallbackChains" // {} | to_entries[].value[]) ]
  | map(select(type == "string")) | map(select(startswith("@") | not))'

jq -r "$harvest_selectors
  | map(strip_thinking) | map(select(endswith(\"/*\") | not))
  | map(select(contains(\"/\"))) | unique
  | {models: map({provider: (split(\"/\")[0]), selector: .})}
" "$declared_json" >"$scratch/catalog-full.json"
jq -e '(.models | length) > 0' "$scratch/catalog-full.json" >/dev/null

declared_count=$(jq -r 'keys | length' "$declared_json")

run_settings() {
  local label=$1 catalog=$2
  : >"$scratch/$label.calls"
  # An empty CANNED_CATALOG and an unset one take the same stub path, so the
  # assignment needs no fork.
  OMP_CALLS="$scratch/$label.calls" CANNED_CATALOG="$catalog" \
    env HOME="$settings_home" PATH="$settings_bin:$PATH" \
    bash "$settings_script" >"$scratch/$label.out" 2>"$scratch/$label.err"
}

# One assertion per declared path, at the exact value the contract requires, and
# never at a parent namespace. Comparing the whole recorded call is what makes
# this load-bearing: a prefix match passes even when the provisioner delivers
# every record as a literal string, which is the entire model policy.
run_settings full "$scratch/catalog-full.json"
[[ $(wc -l <"$scratch/full.calls") -eq $declared_count ]]
while IFS=$'\t' read -r path want; do
  grep -qxF "config set $path $want" "$scratch/full.calls" || {
    printf 'settings assertion did not deliver declared path %s as %s\n' "$path" "$want" >&2
    printf '  recorded: %s\n' "$(grep -F "config set $path " "$scratch/full.calls" || echo '(absent)')" >&2
    exit 1
  }
done < <(jq -r '
  to_entries[]
  | [.key, (if (.value | type) == "string" then .value else (.value | tojson) end)]
  | @tsv
' "$declared_json")
# Derived from the declared keys, so a newly declared dotted path is guarded too.
while IFS= read -r parent; do
  if grep -qF "config set $parent " "$scratch/full.calls"; then
    printf 'settings assertion wrote parent namespace %s\n' "$parent" >&2
    exit 1
  fi
done < <(jq -r 'keys[] | select(contains(".")) | split(".")[0]' "$declared_json" | sort -u)
grep -F "asserted $declared_count declared omp settings paths" "$scratch/full.out" >/dev/null

# A selector the catalog covers by provider but does not serve aborts the apply
# before anything is written.
absent_selector=$(jq -r 'first(.models[] | select(.provider == "anthropic") | .selector) // ""' "$scratch/catalog-full.json")
[[ -n $absent_selector ]] || {
  printf 'fixture found no anthropic selector to withhold; the absent-selector case is not being exercised\n' >&2
  exit 1
}
jq --arg s "$absent_selector" '.models |= map(select(.selector != $s))' \
  "$scratch/catalog-full.json" >"$scratch/catalog-absent.json"
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

# A missing omp binary is a soft skip, not a failed apply.
env HOME="$settings_home" PATH="/usr/bin:/bin" bash "$settings_script" \
  >"$scratch/noomp.out" 2>"$scratch/noomp.err"
grep -F 'omp is unavailable' "$scratch/noomp.err" >/dev/null

# Both platform halves must derive the same declared path set.
ps_declared="$scratch/declared-ps1.json"
awk "/^\\\$declaredJson = @'\$/{flag=1;next}/^'@\$/{flag=0}flag" "$settings_ps1" >"$ps_declared"
jq -e 'type == "object"' "$ps_declared" >/dev/null
if ! diff -u \
  <(jq -r 'keys[]' "$declared_json") \
  <(jq -r 'keys[]' "$ps_declared"); then
  printf 'POSIX and Windows settings halves declare different paths\n' >&2
  exit 1
fi

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

# The parity diff above compares KEY SETS only, so it cannot see a value-rendering
# divergence, and CI cannot execute the Windows half at all. Pin every rule that
# decides what actually reaches the CLI there; each one has a POSIX counterpart the
# value assertion above already proves behaviorally.
while IFS='|' read -r pattern why; do
  [[ -n $pattern ]] || continue
  grep -F -e "$pattern" -- "$settings_ps1" >/dev/null || {
    printf 'the Windows half must %s\n' "$why" >&2
    exit 1
  }
done <<'PINS'
ConvertTo-Json -InputObject $value|pass -InputObject, so a single-element array is not enumerated into a bare scalar
-Depth 20|serialize nested fallback chains rather than System.Object[] below depth 2
$value -is [string]|store a string verbatim rather than JSON-quoted
$1$1\"|escape embedded quotes where the Windows PowerShell 5.1 argument binder does not
PINS

# Render-time guards are structurally invisible to every test above, which receives
# already-rendered scripts. These cases fail the RENDER, the only layer that can
# still catch them: the apply-time catalog gate skips role aliases by design, and
# omp stores a nonsense selector silently. Requires chezmoi, which the job that
# rendered the scripts under test already installed.
# Reuse the repository root resolved before the release-lock assertions.
render_config="$scratch/render.toml"
: >"$render_config"
# A guard that fires AFTER a credential field is resolved (the duplicate check is
# one) still walks the op:// shim first, so isolate the render from host secret
# state: a HOME with no gpg-cache-ready marker takes the live-op fallback, which
# this stub answers with a newline-free value.
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"
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

auth_sh='.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl'
auth_ps1='.chezmoiscripts/70-agents/run_after_config-omp-auth.ps1.tmpl'
settings_sh='.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl'
settings_win='.chezmoiscripts/70-agents/run_after_config-omp-settings.ps1.tmpl'
linux='"chezmoi":{"os":"linux"}'
windows='"chezmoi":{"os":"windows"}'
roles='"modelRoles":{"default":"anthropic/claude-opus-5:xhigh"}'
closed_set='ZAI_API_KEY, EXA_API_KEY, OPENROUTER_API_KEY, OPENCODE_API_KEY'

# The credential set is closed on both platforms so a data edit cannot inject a
# variable into the environment omp loads for every session, nor silently drop
# one.
assert_render_fails auth-outside-closed-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"NODE_OPTIONS\",\"key\":\"x\"}]}}}}" \
  "declares unsupported variable \"NODE_OPTIONS\"; the closed set is $closed_set"
assert_render_fails auth-outside-closed-set-windows "$auth_ps1" \
  "{$windows,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"NODE_OPTIONS\",\"key\":\"x\"}]}}}}" \
  "declares unsupported variable \"NODE_OPTIONS\"; the closed set is $closed_set"
assert_render_fails auth-emptied-set-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[]}}}}" \
  'must declare ZAI_API_KEY'
assert_render_fails auth-emptied-set-windows "$auth_ps1" \
  "{$windows,\"agents\":{\"omp\":{\"auth\":{\"env\":[]}}}}" \
  'must declare ZAI_API_KEY'
assert_render_fails auth-duplicate-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":\"a\"},{\"variable\":\"ZAI_API_KEY\",\"key\":\"b\"}]}}}}" \
  'duplicates variable "ZAI_API_KEY"'
assert_render_fails auth-duplicate-windows "$auth_ps1" \
  "{$windows,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":\"a\"},{\"variable\":\"ZAI_API_KEY\",\"key\":\"b\"}]}}}}" \
  'duplicates variable "ZAI_API_KEY"'
assert_render_fails auth-empty-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":\"\"}]}}}}" \
  'resolved to an empty value'
assert_render_fails auth-empty-key-windows "$auth_ps1" \
  "{$windows,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":\"\"}]}}}}" \
  'resolved to an empty value'
assert_render_fails auth-non-string-key-linux "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":[\"not-a-string\"]}]}}}}" \
  'field `key` must resolve to a string'
assert_render_fails auth-non-string-key-windows "$auth_ps1" \
  "{$windows,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":[\"not-a-string\"]}]}}}}" \
  'field `key` must resolve to a string'

# Role indirection is the one value shape no later layer validates.
assert_render_fails settings-dangling-alias "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"task.agentModelOverrides\":{\"commit\":\"@no-such-role\"}}}}}" \
  'names role alias @no-such-role'
assert_render_fails settings-dangling-alias-windows "$settings_win" \
  "{$windows,\"agents\":{\"omp\":{\"settings\":{$roles,\"task.agentModelOverrides\":{\"commit\":\"@no-such-role\"}}}}}" \
  'names role alias @no-such-role'
assert_render_fails settings-orphan-chain "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"retry.fallbackChains\":{\"ghost\":[\"anthropic/claude-opus-5:xhigh\"]}}}}}" \
  'is not a declared modelRoles role'
# A control character anywhere in the value breaks the tab-separated transport.
assert_render_fails settings-nested-control-char "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{\"modelRoles\":{\"default\":\"anthropic/claude-opus-5\txhigh\"}}}}}" \
  'control character or backslash somewhere in its value'
assert_render_fails settings-parent-namespace "$settings_sh" \
  "{$linux,\"agents\":{\"omp\":{\"settings\":{$roles,\"exa\":true,\"exa.enableSearch\":true}}}}" \
  'is a parent namespace of'

# --- U7: Windows agent-surface parity (agent-plugins, Claude settings) -------
# The Claude/Codex plugin installer and the Claude settings merge now have
# Windows PowerShell halves behind `eq windows` render guards. These checks
# render both halves and prove: the same managed set, the same unpinned-data
# rejection, undeclared vendor-state preservation, and second-run convergence.
agent_plugins_sh='.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.sh.tmpl'
agent_plugins_ps1='.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.ps1.tmpl'
claude_settings_ps1='.chezmoiscripts/70-agents/run_onchange_after_config-claude-settings.ps1.tmpl'

render_template() {
  # render_template LABEL TEMPLATE OVERRIDE_DATA OUT
  local label=$1 template=$2 data=$3 out=$4
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$template" >"$out" 2>"$scratch/$label.err" || {
    printf 'render %s failed\n' "$label" >&2
    sed 's/^/  /' "$scratch/$label.err" >&2
    exit 1
  }
}

render_template agent-plugins-linux "$agent_plugins_sh" "{$linux}" "$scratch/agent-plugins-linux.sh"
render_template agent-plugins-windows "$agent_plugins_ps1" "{$windows}" "$scratch/agent-plugins-windows.ps1"

# Managed-set convergence: every (agent, plugin, marketplace) triple the
# Windows half installs must also be installed by the POSIX half — Windows may
# narrow the set through marketplace `os` gating, never widen it.
grep -oE '^  "[a-z]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z]+:[^"]+"' "$scratch/agent-plugins-linux.sh" |
  sed -E 's/^  "([a-z]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+):[A-Za-z]+:[^"]+"$/\1/' |
  sort -u >"$scratch/posix-plugin-triples"
grep -oE "Agent = '[a-z]+'; Plugin = '[A-Za-z0-9_.-]+'; Market = '[A-Za-z0-9_.-]+'" \
  "$scratch/agent-plugins-windows.ps1" |
  sed -E "s/Agent = '([a-z]+)'; Plugin = '([A-Za-z0-9_.-]+)'; Market = '([A-Za-z0-9_.-]+)'/\1:\2:\3/" |
  sort -u >"$scratch/windows-plugin-triples"
[[ -s $scratch/posix-plugin-triples ]] || {
  printf 'POSIX plugin installer rendered no rows; the convergence check would pass vacuously\n' >&2
  exit 1
}
while IFS= read -r triple; do
  grep -qxF "$triple" "$scratch/posix-plugin-triples" || {
    printf 'Windows plugin installer widened the managed set with %s\n' "$triple" >&2
    exit 1
  }
done <"$scratch/windows-plugin-triples"
# The haptic marketplaces are gated os: [linux, darwin, windows]; both haptic
# rows MUST converge onto the Windows render (regression: the POSIX allowlist
# once rejected the windows os value at render time).
grep -qxF 'claude:mxm4-haptic:dotfiles' "$scratch/windows-plugin-triples" || {
  printf 'Windows plugin installer lost the claude mxm4-haptic row\n' >&2
  exit 1
}
grep -qxF 'codex:mxm4-haptic:dotfiles-codex' "$scratch/windows-plugin-triples" || {
  printf 'Windows plugin installer lost the codex mxm4-haptic row\n' >&2
  exit 1
}

# Unpinned / undeclared integration rejection must fire on BOTH halves before
# any installation: the validation lives in the templates, so a bad entry
# aborts the render with the same diagnostic on Linux and Windows.
bad_mkt='"kind":"gitfs","container":"keep","os":["linux"]'
assert_render_fails plugins-undefined-marketplace-linux "$agent_plugins_sh" \
  "{$linux,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"ghost-mkt\"}]}}}" \
  'references marketplace "ghost-mkt", which is not defined in agents.marketplaces'
assert_render_fails plugins-undefined-marketplace-windows "$agent_plugins_ps1" \
  "{$windows,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"ghost-mkt\"}]}}}" \
  'references marketplace "ghost-mkt", which is not defined in agents.marketplaces'
assert_render_fails plugins-unknown-kind-linux "$agent_plugins_sh" \
  "{$linux,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"bad-mkt\"}]},\"marketplaces\":{\"bad-mkt\":{$bad_mkt}}}}" \
  'marketplace "bad-mkt" has unknown kind "gitfs"'
assert_render_fails plugins-unknown-kind-windows "$agent_plugins_ps1" \
  "{$windows,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"bad-mkt\"}]},\"marketplaces\":{\"bad-mkt\":{$bad_mkt}}}}" \
  'marketplace "bad-mkt" has unknown kind "gitfs"'
assert_render_fails plugins-invalid-os-linux "$agent_plugins_sh" \
  "{$linux,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"bad-os-mkt\"}]},\"marketplaces\":{\"bad-os-mkt\":{\"kind\":\"github\",\"source\":\"a/b\",\"container\":\"keep\",\"os\":[\"plan9\"]}}}}" \
  'lists invalid os "plan9"'
assert_render_fails plugins-invalid-os-windows "$agent_plugins_ps1" \
  "{$windows,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"bad-os-mkt\"}]},\"marketplaces\":{\"bad-os-mkt\":{\"kind\":\"github\",\"source\":\"a/b\",\"container\":\"keep\",\"os\":[\"plan9\"]}}}}" \
  'lists invalid os "plan9"'
assert_render_fails plugins-unsafe-name-linux "$agent_plugins_sh" \
  "{$linux,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"bad;name\",\"marketplace\":\"compound-engineering-plugin\"}]}}}" \
  'is not a bare identifier (allowed: A-Za-z0-9_.-)'
assert_render_fails plugins-unsafe-name-windows "$agent_plugins_ps1" \
  "{$windows,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"bad;name\",\"marketplace\":\"compound-engineering-plugin\"}]}}}" \
  'is not a bare identifier (allowed: A-Za-z0-9_.-)'
# A github marketplace whose source is not owner/repo is an unpinned fetch.
assert_render_fails plugins-unpinned-github-windows "$agent_plugins_ps1" \
  "{$windows,\"agents\":{\"claude\":{\"plugins\":[{\"name\":\"x\",\"marketplace\":\"bad-gh\"}]},\"marketplaces\":{\"bad-gh\":{\"kind\":\"github\",\"source\":\"https://evil.example/x\",\"container\":\"keep\",\"os\":[\"windows\"]}}}}" \
  'which is not owner/repo'

# Every Windows half must at least PARSE after rendering: a template breakage
# is otherwise invisible until a Windows host applies. The Parser API checks
# syntax without executing a line. The check runs through -File, not -Command:
# pwsh treats the first argument after a -Command string as another command,
# which would EXECUTE the script under test.
command -v pwsh >/dev/null 2>&1 || {
  printf 'pwsh is required for the Windows agent-parity checks\n' >&2
  exit 1
}
render_template claude-settings-windows "$claude_settings_ps1" "{$windows}" "$scratch/claude-settings-windows.ps1"
render_template dotagents-windows '.chezmoiscripts/70-agents/run_onchange_after_install-dotagents-skills.ps1.tmpl' "{$windows}" "$scratch/dotagents-windows.ps1"
render_template claude-link-windows '.chezmoiscripts/00-tools/run_onchange_after_claude.ps1.tmpl' "{$windows}" "$scratch/claude-link-windows.ps1"
render_template codex-link-windows '.chezmoiscripts/00-tools/run_onchange_after_codex.ps1.tmpl' "{$windows}" "$scratch/codex-link-windows.ps1"
cat >"$scratch/parse-check.ps1" <<'EOF'
$failed = $false
foreach ($path in $args) {
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseInput(
    [IO.File]::ReadAllText($path), [ref]$null, [ref]$errors)
  if ($errors.Count -gt 0) {
    $failed = $true
    $errors | ForEach-Object { [Console]::Error.WriteLine("${path}: $($_.Message)") }
  }
}
if ($failed) { exit 1 }
EOF
pwsh -NoProfile -File "$scratch/parse-check.ps1" \
  "$scratch/agent-plugins-windows.ps1" "$scratch/claude-settings-windows.ps1" \
  "$scratch/dotagents-windows.ps1" "$scratch/claude-link-windows.ps1" "$scratch/codex-link-windows.ps1"

# Claude settings merge behavior: undeclared vendor keys (theme, hooks,
# enabledPlugins — the keys Claude Code, aoe, and `claude plugin install`
# live-write) survive a run, declared keys are asserted, and a second run
# converges byte-identically. jq does the merge on Windows exactly as on
# POSIX, so this exercises the real code path under pwsh.
command -v jq >/dev/null 2>&1 || {
  printf 'jq is required for the Windows Claude settings merge check\n' >&2
  exit 1
}
claude_settings_home="$scratch/claude-settings-home"
mkdir -p "$claude_settings_home/.claude"
live_settings="$claude_settings_home/.claude/settings.json"
cat >"$live_settings" <<'EOF'
{
  "theme": "dark",
  "hooks": {"SessionStart": [{"command": "aoe-track"}]},
  "enabledPlugins": {"mxm4-haptic@dotfiles": true},
  "effortLevel": "low",
  "model": "stale-model"
}
EOF
cp "$live_settings" "$scratch/settings-undeclared-seed.json"
env CLAUDE_SETTINGS="$live_settings" pwsh -NoProfile -File "$scratch/claude-settings-windows.ps1" \
  >"$scratch/claude-settings-1.out" 2>"$scratch/claude-settings-1.err" || {
  printf 'Windows Claude settings merge failed\n' >&2
  sed 's/^/  /' "$scratch/claude-settings-1.err" >&2
  exit 1
}
# Undeclared preservation: every seeded vendor key survives with its value.
jq -e '.theme == "dark"
  and .hooks.SessionStart[0].command == "aoe-track"
  and .enabledPlugins["mxm4-haptic@dotfiles"] == true' "$live_settings" >/dev/null || {
  printf 'Windows Claude settings merge clobbered undeclared vendor keys\n' >&2
  exit 1
}
# Declared assertion: values come from the live data file, not this fixture,
# so compare against the declared block embedded in the rendered script (the
# single-quoted here-string payload passed to WriteAllText).
sed -n "/\$declaredPath, @'/,/^'@,/p" "$scratch/claude-settings-windows.ps1" |
  sed '1d;$d' >"$scratch/claude-declared.json"
jq -e 'type == "object"' "$scratch/claude-declared.json" >/dev/null
while IFS=$'\t' read -r key want; do
  got=$(jq -c --arg k "$key" '.[$k]' "$live_settings")
  [[ $got == "$want" ]] || {
    printf 'Windows Claude settings merge asserted %s as %s, want %s\n' "$key" "$got" "$want" >&2
    exit 1
  }
done < <(jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv' "$scratch/claude-declared.json")
# Second-run convergence: re-running changes nothing, byte for byte.
cp "$live_settings" "$scratch/settings-after-first.json"
env CLAUDE_SETTINGS="$live_settings" pwsh -NoProfile -File "$scratch/claude-settings-windows.ps1" \
  >"$scratch/claude-settings-2.out" 2>"$scratch/claude-settings-2.err"
cmp -s "$scratch/settings-after-first.json" "$live_settings" || {
  printf 'Windows Claude settings merge did not converge on the second run\n' >&2
  exit 1
}
# A corrupt live file is backed up, never silently destroyed.
printf 'not json\n' >"$live_settings"
env CLAUDE_SETTINGS="$live_settings" pwsh -NoProfile -File "$scratch/claude-settings-windows.ps1" \
  >"$scratch/claude-settings-3.out" 2>"$scratch/claude-settings-3.err"
# Write-Warning lands on the pwsh warning stream, which a -File run emits on
# stdout, not stderr.
grep -q 'not valid JSON' "$scratch/claude-settings-3.out" || {
  printf 'Windows Claude settings merge did not report the corrupt live file\n' >&2
  exit 1
}
[[ $(cat "$live_settings.bak") == 'not json' ]] || {
  printf 'Windows Claude settings merge lost the corrupt-file backup\n' >&2
  exit 1
}
jq -e 'type == "object"' "$live_settings" >/dev/null

printf 'omp auth, plugin, and settings reconcile tests passed\n'
