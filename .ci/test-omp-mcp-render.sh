#!/usr/bin/env bash
set -euo pipefail

# Proves dot_omp/private_agent/private_readonly_mcp.json.tmpl renders omp's
# native MCP schema, which differs from every sibling: stdio entries omit
# `type`, HTTP entries carry `type: "http"`, and OAuth metadata is an
# `auth: {type: "oauth"}` record. Those three shapes are the whole reason omp
# has its own renderer instead of reusing the universal one, and nothing else
# in CI exercises them.
#
# 1Password references are resolved through a STUB `op`, never the real vault:
# a render that reached the live store would leave working Context7 and Exa
# keys in scratch files and CI logs. The test asserts only the stub's value
# appears.

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
chezmoi_bin=${CHEZMOI:-chezmoi}
command -v "$chezmoi_bin" >/dev/null 2>&1 || { echo "chezmoi is not on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run this test" >&2; exit 1; }

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-mcp-render
mkdir -p -- "$scratch_root"; chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() { printf 'test-omp-mcp-render: %s\n' "$*" >&2; exit 1; }

target=dot_omp/private_agent/private_readonly_mcp.json.tmpl
[ -f "$repo_root/$target" ] || fail "missing source surface $target"

mkdir -p "$scratch/bin" "$scratch/home" "$scratch/target"
printf '#!/usr/bin/env bash\nprintf %%s DUMMY-OP-VALUE\n' > "$scratch/bin/op"
chmod 0700 "$scratch/bin/op"
printf '[data]\n' > "$scratch/empty.toml"

render() {
  local override=$1 out=$2 err=$3
  env HOME="$scratch/home" PATH="$scratch/bin:/usr/bin:/bin" \
    "$chezmoi_bin" --config "$scratch/empty.toml" --source "$repo_root" \
      --destination "$scratch/target" --override-data "$override" \
      execute-template <"$repo_root/$target" >"$out" 2>"$err"
}

# --- the declared inventory renders omp's native shapes -------------------- #

out="$scratch/mcp.json"
render '{"chezmoi":{"os":"linux"}}' "$out" "$scratch/err" ||
  { cat "$scratch/err" >&2; fail 'the declared inventory failed to render'; }

jq -e 'type == "object" and (.mcpServers | type) == "object"' "$out" >/dev/null ||
  fail 'render is not an object carrying mcpServers'
jq -e '(.mcpServers | length) > 0' "$out" >/dev/null ||
  fail 'render declared no servers'
jq -e '[.mcpServers[] | select(has("command"))] | all(has("type") | not)' "$out" >/dev/null ||
  fail 'a stdio server carries a type key; omp omits it'
jq -e '[.mcpServers[] | select(has("url"))] | all(.type == "http")' "$out" >/dev/null ||
  fail 'an HTTP server is not typed http'

# Secrets resolve through the stub and never appear as unresolved references.
grep -Fq 'op://' "$out" && fail 'an unresolved op:// reference reached the render'
grep -Fq 'DUMMY-OP-VALUE' "$out" || fail 'the stub op value did not reach the render'

# --- oauth metadata becomes omp's auth record ------------------------------ #

oauth='{"chezmoi":{"os":"linux"},"agents":{"mcp":{"servers":[
  {"name":"oauthy","transport":"http","url":"https://example.invalid/mcp","auth":"oauth"}]}}}'
render "$oauth" "$scratch/oauth.json" "$scratch/oauth.err" ||
  { cat "$scratch/oauth.err" >&2; fail 'an oauth server failed to render'; }
jq -e '.mcpServers.oauthy.auth.type == "oauth"' "$scratch/oauth.json" >/dev/null ||
  fail 'oauth metadata did not render as an auth record'

# --- the two fail-closed guards -------------------------------------------- #

stdio_auth='{"chezmoi":{"os":"linux"},"agents":{"mcp":{"servers":[
  {"name":"bad","transport":"stdio","command":"x","args":[],"auth":"oauth"}]}}}'
if render "$stdio_auth" /dev/null "$scratch/stdio.err"; then
  fail 'a stdio server declaring auth was accepted'
fi
grep -q 'cannot declare auth' "$scratch/stdio.err" ||
  fail 'the stdio-auth refusal did not name its reason'

bad_auth='{"chezmoi":{"os":"linux"},"agents":{"mcp":{"servers":[
  {"name":"bad2","transport":"http","url":"https://example.invalid","auth":"basic"}]}}}'
if render "$bad_auth" /dev/null "$scratch/auth.err"; then
  fail 'an unknown auth value was accepted'
fi
grep -q 'unknown auth' "$scratch/auth.err" ||
  fail 'the unknown-auth refusal did not name its reason'

printf 'omp mcp render: ok\n'
