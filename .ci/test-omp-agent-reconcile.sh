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
[[ ${#calls[@]} -eq 2 ]]
[[ ${calls[0]} == "plugin marketplace add $source" ]]
[[ ${calls[1]} == "plugin install --scope user compound-engineering@compound-engineering-plugin" ]]

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

# One assertion per declared path, and never at a parent namespace.
run_settings full "$scratch/catalog-full.json"
[[ $(wc -l <"$scratch/full.calls") -eq $declared_count ]]
while IFS= read -r path; do
  grep -qF "config set $path " "$scratch/full.calls" || {
    printf 'settings assertion never set declared path %s\n' "$path" >&2
    exit 1
  }
done < <(jq -r 'keys_unsorted[]' "$declared_json")
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
# divergence. Pin the one that already bit: piping a collection to ConvertTo-Json
# enumerates it, so a single-element array would serialize as a bare scalar on
# Windows while POSIX renders a JSON list.
grep -F 'ConvertTo-Json -InputObject $value' "$settings_ps1" >/dev/null || {
  printf 'the Windows half must pass -InputObject so a single-element array is not enumerated\n' >&2
  exit 1
}
printf 'omp auth, plugin, and settings reconcile tests passed\n'
