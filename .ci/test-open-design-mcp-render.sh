#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}
scratch=$(mktemp -d "$scratch_root/open-design-mcp-render.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

empty_config="$scratch/empty.toml"
: >"$empty_config"

fixture='{"agents":{"mcp":{"servers":[
  {"name":"ungated","transport":"stdio","command":"ungated","args":[]},
  {"name":"linux-only","transport":"stdio","command":"linux-only","args":[],"os":["linux"],"container":"skip"},
  {"name":"container-kept","transport":"stdio","command":"container-kept","args":[],"os":["linux"],"container":"keep"},
  {"name":"darwin-only","transport":"stdio","command":"darwin-only","args":[],"os":["darwin"]}
]}}}'

render_servers() {
  local os=$1
  local container=$2
  local harness=${3:-pi}
  local data=${4:-$fixture}
  chezmoi --config "$empty_config" --source "$repo_root" --override-data "$data" \
    execute-template \
    "{{ includeTemplate \"agent-mcp-servers-json.tmpl\" (dict \"ctx\" . \"harness\" \"$harness\" \"os\" \"$os\" \"container\" $container) }}"
}

assert_names() {
  local actual=$1
  shift
  local expected
  expected=$(printf '%s\n' "$@" | sort)
  [[ $(jq -r '.[].name' <<<"$actual" | sort) == "$expected" ]]
}

linux_host=$(render_servers linux false)
assert_names "$linux_host" ungated linux-only container-kept

linux_container=$(render_servers linux true)
assert_names "$linux_container" ungated container-kept

darwin_host=$(render_servers darwin false)
assert_names "$darwin_host" ungated darwin-only

windows_host=$(render_servers windows false)
assert_names "$windows_host" ungated

# harnessSkip is an exclusion list: an omitted field keeps the server for every
# harness, and a named harness loses only that server.
harness_fixture='{"agents":{"mcp":{"servers":[
  {"name":"everywhere","transport":"stdio","command":"everywhere","args":[]},
  {"name":"not-omp","transport":"stdio","command":"not-omp","args":[],"harnessSkip":["omp"]}
]}}}'
assert_names "$(render_servers linux false pi "$harness_fixture")" everywhere not-omp
assert_names "$(render_servers linux false omp "$harness_fixture")" everywhere

# The real inventory declares Open Design only after its managed `od` wrapper
# exists, and the common gate omits it outside a Linux host runtime.
render_real() {
  local os=$1
  local container=$2
  local harness=pi
  chezmoi --config "$empty_config" --source "$repo_root" execute-template \
    "{{ includeTemplate \"agent-mcp-servers-json.tmpl\" (dict \"ctx\" . \"harness\" \"$harness\" \"os\" \"$os\" \"container\" $container) }}"
}

real_linux=$(render_real linux false)
jq -e '.[] | select(
  .name == "open-design" and
  .transport == "stdio" and
  .command == "od" and
  .args == ["mcp"] and
  .os == ["linux"] and
  .container == "skip"
)' <<<"$real_linux" >/dev/null
if jq -e '.[] | select(.name == "open-design")' <<<"$(render_real linux true)" >/dev/null; then
  printf 'Open Design MCP rendered in a real-container context\n' >&2
  exit 1
fi
if jq -e '.[] | select(.name == "open-design")' <<<"$(render_real darwin false)" >/dev/null; then
  printf 'Open Design MCP rendered on darwin\n' >&2
  exit 1
fi
if jq -e '.[] | select(.name == "open-design")' <<<"$(render_real windows false)" >/dev/null; then
  printf 'Open Design MCP rendered on windows\n' >&2
  exit 1
fi

mkdir -p "$scratch/home" "$scratch/bin" "$scratch/rendered"
cat >"$scratch/bin/op" <<'EOF'
#!/usr/bin/env bash
printf 'dummy-secret'
EOF
chmod 0700 "$scratch/bin/op"

render_consumer() {
  local name=$1
  local template=$2
  local output="$scratch/rendered/$name"
  env HOME="$scratch/home" PATH="$scratch/bin:$PATH" \
    chezmoi --config "$empty_config" --source "$repo_root" \
    execute-template <"$repo_root/$template" >"$output"
  printf '%s\n' "$output"
}

open_design_eligible=$(
  chezmoi --config "$empty_config" --source "$repo_root" execute-template \
    '{{ includeTemplate "facts.tmpl" . | fromYaml | toJson }}' |
    jq -r '.os == "linux" and (.container | not)'
)

# One canonical inventory of every MCP consumer: rendered name, source template,
# and the harness id it must identify as. Every loop below derives from it, so a
# seventh consumer is one edit.
consumers=(
  "agents.toml:dot_agents/private_readonly_agents.toml.tmpl:claude"
  "pi.json:dot_pi/private_agent/private_readonly_mcp.json.tmpl:pi"
  "opencode.json:dot_config/opencode/readonly_opencode.json.tmpl:opencode"
  "gemini.json:dot_gemini/config/private_readonly_mcp_config.json.tmpl:agy"
  "omp.json:dot_omp/private_agent/private_readonly_mcp.json.tmpl:omp"
  "kimi.json:private_dot_kimi-code/private_readonly_mcp.json.tmpl:kimi"
)

for entry in "${consumers[@]}"; do
  IFS=: read -r consumer_name consumer_template _ <<<"$entry"
  output=$(render_consumer "$consumer_name" "$consumer_template")
  # agents.toml is TOML, so its Open Design assertions are textual; the rest are
  # JSON documents whose nesting differs per harness.
  if [[ $consumer_name == agents.toml ]]; then
    if [[ $open_design_eligible == true ]]; then
      grep -F 'name = "open-design"' "$output" >/dev/null
      grep -F 'command = "od"' "$output" >/dev/null
      grep -F 'args = ["mcp"]' "$output" >/dev/null
    elif grep -F 'name = "open-design"' "$output" >/dev/null; then
      printf 'Open Design MCP rendered in ineligible agents.toml\n' >&2
      exit 1
    fi
    continue
  fi
  if [[ $open_design_eligible == true ]]; then
    jq -e '
      [
        paths(objects) as $path
        | getpath($path)
        | select(has("open-design"))
        | .["open-design"]
      ] as $servers
      | ($servers | length) == 1
        and (
          ($servers[0].command == "od" and $servers[0].args == ["mcp"])
          or $servers[0].command == ["od", "mcp"]
        )
    ' "$output" >/dev/null
  elif jq -e '
    paths(objects) as $path
    | getpath($path)
    | select(has("open-design"))
  ' "$output" >/dev/null; then
    printf 'Open Design MCP rendered in ineligible %s\n' "$output" >&2
    exit 1
  fi
done

# omp resolves Exa through its native search provider, so the shared websearch
# server must be absent from its inventory and present in every other one.
for entry in "${consumers[@]}"; do
  IFS=: read -r consumer_name _ consumer_harness <<<"$entry"
  if [[ $consumer_harness == omp ]]; then
    if grep -F 'websearch' "$scratch/rendered/$consumer_name" >/dev/null; then
      printf 'websearch leaked into the omp MCP inventory\n' >&2
      exit 1
    fi
  elif ! grep -F 'websearch' "$scratch/rendered/$consumer_name" >/dev/null; then
    printf 'websearch missing from the %s MCP inventory\n' "$consumer_name" >&2
    exit 1
  fi
done

for entry in "${consumers[@]}"; do
  IFS=: read -r _ consumer_template consumer_harness <<<"$entry"
  grep -F "includeTemplate \"agent-mcp-servers-json.tmpl\" (dict \"ctx\" . \"harness\" \"$consumer_harness\")" \
    "$repo_root/$consumer_template" >/dev/null
  if grep -F 'range .agents.mcp.servers' "$repo_root/$consumer_template" >/dev/null; then
    printf '%s still bypasses the shared MCP applicability helper\n' "$consumer_template" >&2
    exit 1
  fi
done
# The array above is hand-maintained, so prove it is the WHOLE set: a target
# template that calls the helper but is missing here would ship unverified, which
# is exactly how omp's own inventory went uncovered until this change.
#
# Compared with shell builtins on purpose. This job runs in a minimal container
# that ships no `diff`, and a missing comparison tool exits non-zero exactly like
# a real mismatch — a verdict that reports the wrong cause is worse than no gate.
mapfile -t helper_callers < <(
  grep -rl --include='*.tmpl' -F 'includeTemplate "agent-mcp-servers-json.tmpl"' "$repo_root" |
    sed "s@^$repo_root/@@" |
    grep -v -e '^\.ci/' -e '^\.chezmoitemplates/'
)
consumer_report=$(printf '  declared: %s\n' "${consumers[@]}")
for template in "${helper_callers[@]}"; do
  found=0
  for entry in "${consumers[@]}"; do
    IFS=: read -r _ consumer_template _ <<<"$entry"
    if [[ $consumer_template == "$template" ]]; then
      found=1
      break
    fi
  done
  if ((found == 0)); then
    printf 'MCP helper caller %s is missing from the consumers list, so it ships unverified\n' "$template" >&2
    printf '%s\n' "$consumer_report" >&2
    exit 1
  fi
done
# The membership loop above cannot see the reverse direction: a consumer listed
# here that no longer calls the helper.
if ((${#helper_callers[@]} != ${#consumers[@]})); then
  printf 'the consumers list has %d entries but %d templates call the helper\n' \
    "${#consumers[@]}" "${#helper_callers[@]}" >&2
  printf '  caller: %s\n' "${helper_callers[@]}" >&2
  printf '%s\n' "$consumer_report" >&2
  exit 1
fi


fingerprint="$repo_root/.chezmoiscripts/70-agents/run_onchange_after_install-dotagents-skills.sh.tmpl"
grep -F '"dot_agents/private_readonly_agents.toml.tmpl" ".chezmoitemplates/agent-mcp-servers-json.tmpl"' \
  "$fingerprint" >/dev/null

assert_invalid() {
  local name=$1
  local fixture=$2
  local diagnostic=$3
  if chezmoi --config "$empty_config" --source "$repo_root" --override-data "$fixture" \
    execute-template \
    '{{ includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" . "harness" "pi" "os" "linux" "container" false) }}' \
    >"$scratch/$name.stdout" 2>"$scratch/$name.stderr"
  then
    printf 'invalid MCP fixture %s rendered successfully\n' "$name" >&2
    exit 1
  fi
  grep -F "$diagnostic" "$scratch/$name.stderr" >/dev/null
}

assert_invalid missing-name \
  '{"agents":{"mcp":{"servers":[{"transport":"stdio","command":"bad","args":[]}]}}}' \
  'missing required field name'
assert_invalid transport-type \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":7,"command":"bad","args":[]}]}}}' \
  'field transport must be a string'
assert_invalid invalid-os \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"os":["plan9"]}]}}}' \
  'unknown os "plan9"'
assert_invalid container-type \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"container":true}]}}}' \
  'field container must be a string'
assert_invalid invalid-container \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"container":"maybe"}]}}}' \
  'unknown container value "maybe"'
assert_invalid harness-skip-type \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"harnessSkip":"omp"}]}}}' \
  'field harnessSkip must be a list'
assert_invalid invalid-harness-skip \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"harnessSkip":["emacs"]}]}}}' \
  'unknown harnessSkip "emacs"'
# A valid CALLER id that renders no file of its own is NOT a valid exclusion: the
# dot_agents consumer serves Codex as "claude", so accepting it here would render
# green and still ship the server to Codex.
assert_invalid inexpressible-harness-skip \
  '{"agents":{"mcp":{"servers":[{"name":"bad","transport":"stdio","command":"bad","args":[],"harnessSkip":["codex"]}]}}}' \
  'cannot skip harness "codex", which renders no file of its own'

# The helper's own required input, not a record field.
if chezmoi --config "$empty_config" --source "$repo_root" execute-template \
  '{{ includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" .) }}' \
  >"$scratch/missing-harness.stdout" 2>"$scratch/missing-harness.stderr"
then
  printf 'helper rendered without a harness id\n' >&2
  exit 1
fi
grep -F 'harness is required' "$scratch/missing-harness.stderr" >/dev/null
if chezmoi --config "$empty_config" --source "$repo_root" execute-template \
  '{{ includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" . "harness" "emacs") }}' \
  >"$scratch/unknown-harness.stdout" 2>"$scratch/unknown-harness.stderr"
then
  printf 'helper rendered with an unknown harness id\n' >&2
  exit 1
fi
grep -F 'unknown harness "emacs"' "$scratch/unknown-harness.stderr" >/dev/null

printf 'open-design MCP render tests passed\n'
