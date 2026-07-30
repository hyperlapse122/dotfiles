#!/usr/bin/env bash
set -euo pipefail

usage='usage: test-omp-agent-reconcile.sh AUTH_SCRIPT PLUGIN_SCRIPT HAPTIC_EXTENSION SETTINGS_SH SETTINGS_PS1'
auth_script=${1:?$usage}
plugin_script=${2:?$usage}
haptic_extension=${3:?$usage}
settings_script=${4:?$usage}
settings_ps1=${5:?$usage}
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/omp-agent-reconcile.XXXXXX")
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
EOF
chmod 0644 "$home/.omp/agent/.env"

env HOME="$home" bash "$auth_script"

auth="$home/.omp/agent/.env"
[[ $(stat -c '%a' "$auth") == 600 ]]
[[ $(grep -c '^ZAI_API_KEY=' "$auth") -eq 1 ]]
grep -F "# user-owned values stay byte-identical" "$auth" >/dev/null
grep -F "OTHER_TOKEN='keep me'" "$auth" >/dev/null
grep -F 'dummy-secret' "$auth" >/dev/null
[[ $(grep -c '^EXA_API_KEY=' "$auth") -eq 1 ]]

printf 'NOT A DOTENV ASSIGNMENT\n' >"$auth"
if env HOME="$home" bash "$auth_script" >"$scratch/malformed.out" 2>"$scratch/malformed.err"; then
  printf 'auth reconcile accepted malformed dotenv input\n' >&2
  exit 1
fi
[[ $(cat "$auth") == 'NOT A DOTENV ASSIGNMENT' ]]
grep -F 'refusing malformed dotenv line' "$scratch/malformed.err" >/dev/null

referent="$scratch/referent"
printf 'do not overwrite\n' >"$referent"
rm "$auth"
ln -s "$referent" "$auth"
if env HOME="$home" bash "$auth_script" >"$scratch/auth.out" 2>"$scratch/auth.err"; then
  printf 'auth reconcile accepted a symlink target\n' >&2
  exit 1
fi
[[ $(cat "$referent") == 'do not overwrite' ]]
grep -F 'unsafe target' "$scratch/auth.err" >/dev/null

source="$home/.local/share/compound-engineering/v3.20.0"
mkdir -p "$source/.claude-plugin"
printf '{"name":"compound-engineering-plugin"}\n' >"$source/.claude-plugin/marketplace.json"
cat >"$fake_bin/omp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$OMP_CALLS"
EOF
chmod 0755 "$fake_bin/omp"

OMP_CALLS="$scratch/omp.calls" env HOME="$home" PATH="$fake_bin:$PATH" bash "$plugin_script"

mapfile -t calls <"$scratch/omp.calls"
[[ ${#calls[@]} -eq 3 ]]
[[ ${calls[0]} == "plugin marketplace remove compound-engineering-plugin" ]]
[[ ${calls[1]} == "plugin marketplace add $source" ]]
[[ ${calls[2]} == "plugin install --scope user --force compound-engineering@compound-engineering-plugin" ]]

bun "$(dirname "$0")/test-omp-haptic-extension.ts" "$haptic_extension"


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
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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
settings_sh='.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl'
settings_win='.chezmoiscripts/70-agents/run_after_config-omp-settings.ps1.tmpl'
linux='"chezmoi":{"os":"linux"}'
windows='"chezmoi":{"os":"windows"}'
roles='"modelRoles":{"default":"anthropic/claude-opus-5:xhigh"}'

# The credential set is closed so a data edit cannot inject a variable into the
# environment omp loads for every session, nor silently drop one.
assert_render_fails auth-outside-closed-set "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"NODE_OPTIONS\",\"key\":\"x\"}]}}}}" \
  'declares unsupported variable "NODE_OPTIONS"'
assert_render_fails auth-emptied-set "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[]}}}}" \
  'must declare ZAI_API_KEY'
assert_render_fails auth-duplicate "$auth_sh" \
  "{$linux,\"agents\":{\"omp\":{\"auth\":{\"env\":[{\"variable\":\"ZAI_API_KEY\",\"key\":\"a\"},{\"variable\":\"ZAI_API_KEY\",\"key\":\"b\"}]}}}}" \
  'duplicates variable "ZAI_API_KEY"'

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

printf 'omp auth, plugin, and settings reconcile tests passed\n'
