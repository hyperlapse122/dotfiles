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
  chezmoi --config "$empty_config" --source "$repo_root" --override-data "$fixture" \
    execute-template \
    "{{ includeTemplate \"agent-mcp-servers-json.tmpl\" (dict \"ctx\" . \"os\" \"$os\" \"container\" $container) }}"
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

# The real inventory declares Open Design only after its managed `od` wrapper
# exists, and the common gate omits it outside a Linux host runtime.
render_real() {
  local os=$1
  local container=$2
  chezmoi --config "$empty_config" --source "$repo_root" execute-template \
    "{{ includeTemplate \"agent-mcp-servers-json.tmpl\" (dict \"ctx\" . \"os\" \"$os\" \"container\" $container) }}"
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

agents_output=$(render_consumer agents.toml dot_agents/private_readonly_agents.toml.tmpl)
grep -F 'name = "open-design"' "$agents_output" >/dev/null
grep -F 'command = "od"' "$agents_output" >/dev/null
grep -F 'args = ["mcp"]' "$agents_output" >/dev/null

for entry in \
  "pi.json:dot_pi/agent/private_readonly_mcp.json.tmpl" \
  "opencode.json:dot_config/opencode/readonly_opencode.json.tmpl" \
  "gemini.json:dot_gemini/config/private_readonly_mcp_config.json.tmpl" \
  "kimi.json:dot_kimi-code/private_readonly_mcp.json.tmpl"
do
  output=$(render_consumer "${entry%%:*}" "${entry#*:}")
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
done

for template in \
  dot_agents/private_readonly_agents.toml.tmpl \
  dot_pi/agent/private_readonly_mcp.json.tmpl \
  dot_config/opencode/readonly_opencode.json.tmpl \
  dot_gemini/config/private_readonly_mcp_config.json.tmpl \
  dot_kimi-code/private_readonly_mcp.json.tmpl
do
  grep -F 'includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" .)' \
    "$repo_root/$template" >/dev/null
  if grep -F 'range .agents.mcp.servers' "$repo_root/$template" >/dev/null; then
    printf '%s still bypasses the shared MCP applicability helper\n' "$template" >&2
    exit 1
  fi
done

fingerprint="$repo_root/.chezmoiscripts/70-agents/run_onchange_after_install-dotagents-skills.sh.tmpl"
grep -F '"dot_agents/private_readonly_agents.toml.tmpl" ".chezmoitemplates/agent-mcp-servers-json.tmpl"' \
  "$fingerprint" >/dev/null

assert_invalid() {
  local name=$1
  local fixture=$2
  local diagnostic=$3
  if chezmoi --config "$empty_config" --source "$repo_root" --override-data "$fixture" \
    execute-template \
    '{{ includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" . "os" "linux" "container" false) }}' \
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

printf 'open-design MCP render tests passed\n'
