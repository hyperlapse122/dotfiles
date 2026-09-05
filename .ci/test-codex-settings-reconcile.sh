#!/usr/bin/env bash
# Guards the Codex config.toml reconciler: the render-time declaration guard
# (.chezmoitemplates/codex-settings-validate.tmpl), the render-time composition of
# the declared object (settings leaves plus mcp_servers tables with resolved
# op:// headers), and the runtime assertion through settings-reconcile
# (.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl).
#
# config.toml is shared with Codex itself, which writes project trust, hook state
# and `codex mcp add` results into it. A reconciler that quietly replaced one of
# those tables would look identical to one that preserved it until a user lost
# their trusted projects, so every runtime assertion below checks what SURVIVED as
# well as what was written.
set -euo pipefail

usage='usage: test-codex-settings-reconcile.sh SETTINGS_SCRIPT'
settings_script=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
settings_sh='.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl'

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/codex-settings-reconcile-fixtures
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }

# Renders resolve secrets live, so isolate them from host state: a scratch HOME
# plus a stub op answering newline-free.
render_config="$scratch/render.toml"
printf '[data]\n' >"$render_config"
neg_home="$scratch/neg-home"
neg_bin="$scratch/neg-bin"
mkdir -p "$neg_home" "$neg_bin"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' >"$neg_bin/op"
chmod 0700 "$neg_bin/op"

render() {
  env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" execute-template "$@"
}

# The reconciler under test. RECONCILER wins when set; a provisioned host has the
# built binary in ~/.local/bin; a bare CI runner compiles it from source, which
# needs `bun` and an installed packages/ workspace (smol-toml).
resolve_reconciler() {
  if [[ -n ${RECONCILER:-} ]]; then
    printf '%s' "$RECONCILER"
  elif [[ -x "$HOME/.local/bin/settings-reconcile" ]]; then
    printf '%s' "$HOME/.local/bin/settings-reconcile"
  elif command -v bun >/dev/null 2>&1; then
    bun build --compile "$repo_root/packages/settings-reconcile/src/cli.ts" \
      --outfile "$scratch/settings-reconcile" >"$scratch/bun-build.log" 2>&1 \
      || { sed 's/^/  /' "$scratch/bun-build.log" >&2; fail 'could not compile settings-reconcile from source'; }
    printf '%s' "$scratch/settings-reconcile"
  else
    fail 'no settings-reconcile available: set RECONCILER, install ~/.local/bin/settings-reconcile, or provide bun'
  fi
}
reconciler=$(resolve_reconciler)
[[ $("$reconciler" contracts) == '{"settings":"settings-reconcile/v1"}' ]] \
  || fail "the reconciler at $reconciler does not speak settings-reconcile/v1"

# TOML is read back through a real parser, never by grep: the reconciler rewrites
# the whole file through smol-toml, so table layout is not stable text.
python3 -c 'import tomllib' 2>/dev/null || fail 'python3 with tomllib (3.11+) is required to read config.toml back'
toml_json() {
  python3 -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$1"
}

real_stat=$(command -v stat)
identity() { "$real_stat" -c '%i %Y' "$1"; }
mode() { "$real_stat" -c '%a' "$1"; }

# The label step is host-dependent: restorecon may be absent, and no scratch
# directory carries codex_config_t. Stub both ends so every run is deterministic;
# `label_ok` makes the step quiet, the other two force each notice.
make_label_bin() {
  local dir=$1 restorecon_rc=$2 context=$3
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit %s\n' "$restorecon_rc" >"$dir/restorecon"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "$context" >"$dir/stat"
  chmod 0700 "$dir/restorecon" "$dir/stat"
}
label_ok=$scratch/label-ok
label_fail=$scratch/label-fail
label_wrong=$scratch/label-wrong
make_label_bin "$label_ok" 0 'unconfined_u:object_r:codex_config_t:s0'
make_label_bin "$label_fail" 1 'unconfined_u:object_r:codex_config_t:s0'
make_label_bin "$label_wrong" 0 'unconfined_u:object_r:user_home_t:s0'

run() {
  local home=$1 label_bin=${2:-$label_ok}
  CODEX_HOME="$home" RECONCILER="$reconciler" PATH="$label_bin:$PATH" bash "$settings_script"
}

# ---------------------------------------------------------------------------
# Render-time composition: the declared object the rendered script carries.
# ---------------------------------------------------------------------------

declared=$(sed -n "/^cat >\"\$config\" <<'JSON'\$/,/^JSON\$/p" "$settings_script" | sed '1d;$d')
jq -e 'type == "object"' <<<"$declared" >/dev/null \
  || fail 'could not extract the declared JSON object from the rendered script'

# The settings half must be exactly the dotted declaration expanded into nested
# tables, read back from agents.yaml the same way the script does.
expected_settings=$(render <<<'{{ .agents.codex.settings | toJson }}' \
  | jq -c 'reduce to_entries[] as $e ({}; setpath($e.key | split("."); $e.value))')
[[ $(jq -Sc 'del(.mcp_servers)' <<<"$declared") == "$(jq -Sc . <<<"$expected_settings")" ]] \
  || fail 'the declared settings leaves do not expand to the rendered agents.codex.settings'
jq -e '.approval_policy == "never" and .sandbox_mode == "workspace-write"
  and .sandbox_workspace_write.network_access == true
  and .model_reasoning_effort == "high" and (has("model") | not)' <<<"$declared" >/dev/null \
  || fail 'the declared headless posture is not the one agents.yaml declares'

# The MCP half must carry exactly the codex-eligible inventory, in Codex's shape.
eligible=$(render <<<'{{ includeTemplate "agent-mcp-servers-json.tmpl" (dict "ctx" . "harness" "codex") }}')
[[ $(jq -Sc '.mcp_servers | keys' <<<"$declared") == "$(jq -Sc '[.[].name] | sort' <<<"$eligible")" ]] \
  || fail 'the declared mcp_servers names differ from the codex-eligible inventory'
jq -e '.mcp_servers.codegraph == {"command":"codegraph","args":["serve","--mcp"]}' <<<"$declared" >/dev/null \
  || fail 'codegraph did not render as a stdio table with command and args'
jq -e '.mcp_servers.websearch.url == "https://mcp.exa.ai/mcp"
  and .mcp_servers.websearch.http_headers["x-api-key"] == "dummy-secret"' <<<"$declared" >/dev/null \
  || fail 'websearch did not render as url plus a resolved http_headers value'
jq -e '[.. | objects | has("type")] | any | not' <<<"$declared" >/dev/null \
  || fail 'a mcp_servers table carries a type key, which is a ~/.mcp.json shape Codex does not use'
jq -e '[.. | objects | has("headers")] | any | not' <<<"$declared" >/dev/null \
  || fail 'a mcp_servers table carries headers instead of http_headers'
jq -e '[.mcp_servers[] | select(has("url")) | has("http_headers")] | all' <<<"$declared" >/dev/null \
  || fail 'an HTTP server rendered without its http_headers table'
jq -e '[.mcp_servers[] | select(has("command")) | has("url") or has("http_headers")] | any | not' <<<"$declared" >/dev/null \
  || fail 'a stdio server rendered with HTTP fields'

# Every resolved secret lands only under mcp_servers.<name>.http_headers, and the
# rendered script carries no copy of it anywhere else (no echo, no log line).
jq -e '[paths(. == "dummy-secret")]
  | length > 0 and all(length == 4 and .[0] == "mcp_servers" and .[2] == "http_headers")' <<<"$declared" >/dev/null \
  || fail 'a resolved header value appears outside mcp_servers.<name>.http_headers'
[[ $(grep -o -F dummy-secret "$settings_script" | wc -l) -eq $(jq '[paths(. == "dummy-secret")] | length' <<<"$declared") ]] \
  || fail 'the rendered script carries a resolved secret outside the declared JSON'
! grep -qF 'op://' "$settings_script" || fail 'the rendered script still carries an unresolved op:// reference'

# ---------------------------------------------------------------------------
# Runtime: the rendered reconciler against fixtures, driven by CODEX_HOME.
# ---------------------------------------------------------------------------

assert_declared_present() {
  local file=$1 label=$2
  toml_json "$file" | jq -e --argjson d "$declared" '
    . as $live
    | [ $d | paths(scalars) as $p | ($live | getpath($p)) == ($d | getpath($p)) ]
    | all' >/dev/null \
    || fail "$label: a declared leaf is missing or holds the wrong value in $file"
}

# Codex-owned state next to a hand-changed declared leaf: project trust, a server
# added with `codex mcp add`, and a key this declaration does not name.
seeded=$scratch/seeded
mkdir -p "$seeded"
cat >"$seeded/config.toml" <<'TOML'
approval_policy = "on-request"
notify = ["notify-send"]

[projects."/tmp/repo"]
trust_level = "trusted"

[mcp_servers.foo]
command = "foo"
args = ["--bar"]
TOML
chmod 0600 "$seeded/config.toml"

run "$seeded" >/dev/null
assert_declared_present "$seeded/config.toml" 'seeded run'
seeded_json=$(toml_json "$seeded/config.toml")
[[ $(jq -r '.approval_policy' <<<"$seeded_json") == never ]] \
  || fail 'a hand-changed approval_policy was not reverted to the declared value'
[[ $(jq -Sc '.projects' <<<"$seeded_json") == '{"/tmp/repo":{"trust_level":"trusted"}}' ]] \
  || fail 'the Codex-owned projects table did not survive the assert'
[[ $(jq -Sc '.mcp_servers.foo' <<<"$seeded_json") == '{"args":["--bar"],"command":"foo"}' ]] \
  || fail 'a hand-added [mcp_servers.foo] did not survive the assert'
[[ $(jq -Sc '.notify' <<<"$seeded_json") == '["notify-send"]' ]] \
  || fail 'an undeclared top-level key was rewritten'
[[ $(mode "$seeded/config.toml") == 600 ]] || fail 'reconciler widened the config.toml mode'
[[ -z $(find "$seeded" -maxdepth 1 -name '.config.toml.*.tmp' -print -quit) ]] \
  || fail 'the reconciler left its temp file behind'

# Convergence is the success case, not a skip: a second apply on unchanged source
# must change zero bytes. Inode identity is the signal that no rename happened --
# this job runs on every apply.
identity_before=$(identity "$seeded/config.toml")
converged_out=$(run "$seeded" 2>&1)
[[ $(identity "$seeded/config.toml") == "$identity_before" ]] \
  || fail 'a converged re-run republished config.toml'
[[ -z $converged_out ]] || fail "a converged re-run was not silent: $converged_out"

# A host with no ~/.codex yet gets exactly the declared content, at mode 0600.
created=$scratch/created/.codex
run "$created" >/dev/null
[[ -f "$created/config.toml" ]] || fail 'a missing config.toml was not created'
[[ $(toml_json "$created/config.toml" | jq -Sc .) == "$(jq -Sc . <<<"$declared")" ]] \
  || fail 'a created config.toml does not hold exactly the declared content'
[[ $(mode "$created/config.toml") == 600 ]] || fail 'a created config.toml is not mode 0600'

# An orphaned reconciler temp file would hold resolved secrets, so a stale one is
# removed before the write rather than left for a later sweep.
stale=$scratch/stale
mkdir -p "$stale"
printf 'approval_policy = "never"\n' >"$stale/config.toml"
printf 'leaked = "secret"\n' >"$stale/.config.toml.deadbeef.tmp"
run "$stale" >/dev/null
[[ ! -e "$stale/.config.toml.deadbeef.tmp" ]] || fail 'a stale .config.toml.*.tmp survived the run'
assert_declared_present "$stale/config.toml" 'stale temp run'

# The declaration is authoritative, so a run that cannot assert must say so and
# fail the apply: a silent skip leaves the user believing the values are pinned.
absent=$scratch/absent
mkdir -p "$absent"
printf 'approval_policy = "on-request"\n' >"$absent/config.toml"
absent_before=$(cat "$absent/config.toml")
absent_err=$(CODEX_HOME="$absent" RECONCILER="$scratch/no-such-reconciler" PATH="$label_ok:$PATH" \
  bash "$settings_script" 2>&1 >/dev/null) && fail 'a missing reconciler did not fail the apply'
grep -qF 'settings-reconcile is unavailable' <<<"$absent_err" \
  || fail "a missing reconciler was not reported clearly; stderr was: $absent_err"
[[ $(cat "$absent/config.toml") == "$absent_before" ]] || fail 'a missing reconciler still touched config.toml'

wrong_contract=$scratch/wrong-contract
mkdir -p "$wrong_contract"
printf '#!/usr/bin/env bash\nprintf %%s\\\\n %s\n' "'{\"settings\":\"settings-reconcile/v0\"}'" >"$wrong_contract/settings-reconcile"
chmod 0700 "$wrong_contract/settings-reconcile"
contract_err=$(CODEX_HOME="$absent" RECONCILER="$wrong_contract/settings-reconcile" PATH="$label_ok:$PATH" \
  bash "$settings_script" 2>&1 >/dev/null) && fail 'an incompatible reconciler contract did not fail the apply'
grep -qF 'incompatible settings contract' <<<"$contract_err" \
  || fail "an incompatible contract was not reported clearly; stderr was: $contract_err"
[[ $(cat "$absent/config.toml") == "$absent_before" ]] || fail 'an incompatible reconciler still touched config.toml'

# The label step reports rather than swallows: a failed restorecon and a wrong
# resulting context each print a notice, and neither fails the apply, because the
# declared leaves were already asserted.
label_home=$scratch/label
label_err=$(run "$label_home" "$label_fail" 2>&1 >/dev/null) || fail 'a failed restorecon should not fail the apply'
grep -qF 'could not restore' <<<"$label_err" || fail "a failed restorecon was not reported; stderr was: $label_err"
assert_declared_present "$label_home/config.toml" 'restorecon failure'
label_err=$(run "$label_home" "$label_wrong" 2>&1 >/dev/null) || fail 'a wrong label should not fail the apply'
grep -qF 'codex_config_t' <<<"$label_err" || fail "a wrong resulting label was not reported; stderr was: $label_err"
grep -qF 'user_home_t' <<<"$label_err" || fail "the wrong-label notice does not name the observed context: $label_err"

# ---------------------------------------------------------------------------
# Render-time: the declaration guard. These cases are structurally invisible to
# every runtime assertion above, which receives an already-rendered script.
# ---------------------------------------------------------------------------

# `--override-data` DEEP-MERGES into the repo's real agents.yaml, so a fixture can
# only ADD a key. That is enough for every rejection, which is about a key that is
# present and wrong.
assert_render_fails() {
  local label=$1 data=$2 want=$3
  if env HOME="$neg_home" PATH="$neg_bin:$PATH" \
    chezmoi --config "$render_config" --source "$repo_root" --override-data "$data" \
    execute-template <"$repo_root/$settings_sh" >"$scratch/neg.out" 2>"$scratch/neg.err"; then
    fail "render-negative $label: expected a failed render, got exit 0"
  fi
  grep -qF -e "$want" -- "$scratch/neg.err" || {
    printf 'render-negative %s: render failed without the expected diagnostic %s\n' "$label" "$want" >&2
    sed 's/^/  /' "$scratch/neg.err" >&2
    exit 1
  }
}

assert_partial_ok() {
  local label=$1 body=$2
  printf '%s\n' "$body" >"$scratch/partial.tmpl"
  render <"$scratch/partial.tmpl" >"$scratch/pos.out" 2>"$scratch/pos.err" || {
    printf 'render-partial %s: expected a successful render, got a failure\n' "$label" >&2
    sed 's/^/  /' "$scratch/pos.err" >&2
    exit 1
  }
}

owned_elsewhere='which another writer owns'
bad_path='is not a valid config.toml path'
posture_reject='approval or sandbox posture'

# The declaration owns scalar leaves; mcp_servers belongs to the MCP half of this
# same script, and projects, hooks, plugins and marketplaces belong to Codex.
assert_render_fails mcp-servers-namespace \
  '{"agents":{"codex":{"settings":{"mcp_servers.x":"x"}}}}' "$owned_elsewhere"
assert_render_fails mcp-servers-bare \
  '{"agents":{"codex":{"settings":{"mcp_servers":"x"}}}}' "$owned_elsewhere"
assert_render_fails projects-namespace \
  '{"agents":{"codex":{"settings":{"projects.x":"x"}}}}' "$owned_elsewhere"
assert_render_fails hooks-namespace \
  '{"agents":{"codex":{"settings":{"hooks.x":"x"}}}}' "$owned_elsewhere"
assert_render_fails plugins-namespace \
  '{"agents":{"codex":{"settings":{"plugins.x":"x"}}}}' "$owned_elsewhere"
assert_render_fails marketplaces-namespace \
  '{"agents":{"codex":{"settings":{"marketplaces.x":"x"}}}}' "$owned_elsewhere"

# A sandbox or approval key enters through the same data edit as a reasoning
# toggle, so the ownership list cannot screen it. The allowlist does, by name.
assert_render_fails sandbox-unreviewed-leaf \
  '{"agents":{"codex":{"settings":{"sandbox_workspace_write.exclude_tmpdir_env_var":true}}}}' "$posture_reject"
assert_render_fails sandbox-writable-roots \
  '{"agents":{"codex":{"settings":{"sandbox_workspace_write.writable_roots":"x"}}}}' "$posture_reject"
assert_render_fails sandbox-bare \
  '{"agents":{"codex":{"settings":{"sandbox_workspace_write":"x"}}}}' "$posture_reject"

assert_render_fails doubled-dot \
  '{"agents":{"codex":{"settings":{"sandbox_workspace_write..network_access":true}}}}' "$bad_path"
assert_render_fails trailing-dot \
  '{"agents":{"codex":{"settings":{"model_reasoning_effort.":"x"}}}}' "$bad_path"
assert_render_fails segment-leading-digit \
  '{"agents":{"codex":{"settings":{"tui.9bad":"x"}}}}' "$bad_path"
assert_render_fails container-value \
  '{"agents":{"codex":{"settings":{"tui":{"notifications":true}}}}}' 'must name a LEAF'
assert_render_fails ancestor-and-descendant \
  '{"agents":{"codex":{"settings":{"model_reasoning_effort.x":"x"}}}}' 'is an ancestor of'

# An empty declaration is a legal state; the reviewed posture keys render clean;
# the real declaration must always render clean.
assert_partial_ok empty-declaration \
  '{{- includeTemplate "codex-settings-validate.tmpl" (dict "ctx" . "settings" dict) -}}'
assert_partial_ok reviewed-posture-paths \
  '{{- includeTemplate "codex-settings-validate.tmpl" (dict "ctx" . "settings" (dict "approval_policy" "never" "sandbox_mode" "workspace-write" "sandbox_workspace_write.network_access" true)) -}}'
assert_partial_ok non-posture-leaf \
  '{{- includeTemplate "codex-settings-validate.tmpl" (dict "ctx" . "settings" (dict "tui.notifications" true)) -}}'
assert_partial_ok real-declaration \
  '{{- includeTemplate "codex-settings-validate.tmpl" (dict "ctx" . "settings" .agents.codex.settings) -}}'

printf 'test-codex-settings-reconcile: all runtime and render-time assertions passed\n'
