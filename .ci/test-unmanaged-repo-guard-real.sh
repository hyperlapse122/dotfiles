#!/usr/bin/env bash
set -euo pipefail

# Real-omp install/enable/runtime proof for the unmanaged-repo-guard plugin
# (plan U6/U7). Modeled on test-omp-real-plugin.sh: version-pinned omp, a
# relocated HOME so nothing escapes the real one, and a scratch marketplace
# built from the already-rendered package this script receives as $1.
#
# Step 4 below is the load-bearing assertion (plan R1/U6): it drives a real
# tool call through omp's OWN runtime against a stubbed `gh`, proving omp
# resolves the manifest's raw `./src/index.ts` entry and that the guard's
# `{ block: true, reason }` return actually stops the bash tool. A `bun`
# import of the entry file would only prove the module parses, which the
# originating guard plan's KTD1 explicitly forbids substituting here (that
# is step 3b below, a weaker, unconditional floor).
#
# Steps 4 and 5 run with NO model credential in the environment (plan R1,
# KTD1): a keyless custom `models.yml` provider points at a Bun HTTP stub
# (`.ci/fixtures/unmanaged-repo-guard/stub-model-server.ts`) that answers by
# matching request content, never by counting turns. Two side-channel logs -
# the stub model's own request log and the `gh`/`glab`/MCP invocation logs -
# are the assertion surface (plan KTD2); the model's own prose is never
# asserted on, because the stub authors that prose itself. Step 5 drives the
# same proof through a `task`-spawned subagent's own MCP tool call (plan R7,
# KTD3), reusing the step-4 stub harness rather than building a second one.
#
# The originating guard plan's KTD1 "Detection limit, stated honestly"
# applies throughout: CI pins the omp version, so this re-confirms known-good
# raw-.ts resolution and only catches a regression on the run that bumps the
# pin.

usage='usage: test-unmanaged-repo-guard-real.sh RENDERED_PACKAGE_DIR'
package_dir=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$repo_root/.ci/fixtures/unmanaged-repo-guard"

fail() {
  printf 'test-unmanaged-repo-guard-real: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf 'test-unmanaged-repo-guard-real: SKIP - %s\n' "$*" >&2
  exit 0
}

command -v omp >/dev/null 2>&1 || skip 'omp is not on PATH'
command -v bun >/dev/null 2>&1 || skip 'bun is not on PATH'
command -v jq >/dev/null 2>&1 || skip 'jq is not on PATH'

[[ -f $package_dir/package.json && -f $package_dir/src/index.ts ]] ||
  fail "rendered guard package is incomplete: $package_dir"

locked_version=$(jq -er '.releases.tools.omp.version | sub("^v"; "")' "$repo_root/.chezmoidata/releases.json")
version_pattern=${locked_version//./\\.}
[[ $(omp --version) =~ (^|[^[:digit:]])${version_pattern}([^[:digit:]]|$) ]] ||
  fail "omp on PATH does not match locked version $locked_version"

# Snapshot the real $HOME plugin lock before touching anything, so the final
# assertion can prove nothing in this script ever escaped the relocated HOME
# below - not the install, not the runtime -p run.
real_lock="$HOME/.omp/plugins/omp-plugins.lock.json"
snapshot_real_lock() {
  if [[ -f $real_lock ]]; then
    sha256sum -- "$real_lock" | awk '{print $1}'
  else
    printf 'absent'
  fi
}
real_lock_before=$(snapshot_real_lock)

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/omp-unmanaged-repo-guard-real
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/smoke.XXXXXX")
stub_model_pid=""
trap '[[ -n $stub_model_pid ]] && kill "$stub_model_pid" 2>/dev/null; rm -rf -- "$scratch"' EXIT
home="$scratch/home"
marketplace="$scratch/marketplace"
workdir="$scratch/workdir"
mkdir -p "$home" "$workdir" "$marketplace/.omp-plugin" "$marketplace/plugins" "$home/.omp/agent"
cp -R -- "$package_dir" "$marketplace/plugins/unmanaged-repo-guard"
cat >"$marketplace/.omp-plugin/marketplace.json" <<'JSON'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"unmanaged-repo-guard","source":"./plugins/unmanaged-repo-guard"}]}
JSON

# omp's own agent config for the scratch HOME (plan KTD1, KTD3). `mcp.json`
# registers the stub MCP server under key "glab" so its tool resolves as
# `mcp__glab_issue_create`, matching the guard's allowlist entry. `config.yml`
# pins the `task` role to the stub model explicitly (omp's documented model
# priority for a subagent ends in an unspecified session fallback otherwise)
# and disables async task execution, so a `task` spawn runs synchronously -
# without this, the -p invocation can exit before its background subagent
# ever calls the guarded tool, which would silently pass step 5 vacuously.
stub_mcp_log="$scratch/stub-mcp.log"
cat >"$home/.omp/agent/mcp.json" <<JSON
{
  "mcpServers": {
    "glab": {
      "command": "bun",
      "args": ["$fixtures/stub-mcp-server.ts"],
      "env": { "STUB_MCP_LOG": "$stub_mcp_log" }
    }
  }
}
JSON
cat >"$home/.omp/agent/config.yml" <<'YAML'
modelRoles:
  task: stub/stub-model
async:
  enabled: false
YAML

run_omp() {
  (
    cd "$workdir" &&
      env -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        omp "$@"
  )
}

run_omp plugin marketplace add "$marketplace"
run_omp plugin install --scope user --force unmanaged-repo-guard@h82-dotfiles
run_omp plugin enable --scope user unmanaged-repo-guard@h82-dotfiles
run_omp plugin list >"$scratch/list.out"
grep -F 'unmanaged-repo-guard' "$scratch/list.out" >/dev/null ||
  fail 'omp plugin list did not name unmanaged-repo-guard'

installed="$home/.omp/plugins/installed_plugins.json"
lock="$home/.omp/plugins/omp-plugins.lock.json"
jq -e '
  .plugins["unmanaged-repo-guard@h82-dotfiles"] as $rows
  | ($rows | type) == "array"
    and ($rows | length) == 1
    and $rows[0].scope == "user"
    and ($rows[0].installPath | type) == "string"
' "$installed" >/dev/null
jq -e '.plugins["@h82/omp-unmanaged-repo-guard"].enabled == true' "$lock" >/dev/null
install_root=$(jq -er '.plugins["unmanaged-repo-guard@h82-dotfiles"][0].installPath' "$installed")
case $install_root in
  "$home"/*) ;;
  *) fail "installed plugin escaped relocated HOME: $install_root" ;;
esac

# Step 3b (unconditional): prove the INSTALLED raw .ts entry parses and
# registers exactly one tool_call handler under Bun, the same runtime omp
# embeds. This is a weaker tier than step 4 -- it does not exercise omp's own
# extension resolution -- but unlike step 4 it needs no model credentials, so
# it runs on every CI run and is the standing floor for the guard plan's
# KTD1 no-build claim.
entry="$install_root/src/index.ts"
[[ -f $entry ]] || fail "installed plugin has no src/index.ts entry: $entry"
bun - "$entry" <<'BUN' || fail 'installed raw .ts entry failed to load and register'
const entry = process.argv[2];
const events = [];
const pi = new Proxy(
  {
    exec: async () => ({ stdout: "", stderr: "", code: 0, killed: false }),
    on: (event) => events.push(event),
    logger: { error: () => {} },
  },
  {
    get(target, prop) {
      if (prop in target) return target[prop];
      throw new Error(`extension touched unexpected pi API: ${String(prop)}`);
    },
  },
);
const mod = await import(entry);
if (typeof mod.default !== "function") throw new Error("entry has no default factory");
mod.default(pi);
if (events.length !== 1 || events[0] !== "tool_call") {
  throw new Error(`expected exactly one tool_call registration, got ${JSON.stringify(events)}`);
}
BUN

# Steps 4-5 (load-bearing): drive real tool calls through omp's own runtime -
# once through a top-level bash `gh issue create` (step 4, plan R1) and once
# through a task-spawned subagent's own `mcp__glab_issue_create` MCP call
# (step 5, plan R7) - each against both an unmanaged and a managed stub
# verdict. Every model turn is served by the stub below, so this now runs
# unconditionally: no model credential is required or consulted (plan KTD1).
# `credential_vars` is reused only as the set to unset for the omp
# invocations below, extending the existing `env -u PI_CODING_AGENT_DIR
# -u OMP_AGENT_ENV` pattern - the script is documented as locally runnable,
# so a developer's own exported key must not reach a loopback stub over
# plain HTTP.
credential_vars=(ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY OPENROUTER_API_KEY ZAI_API_KEY OPENCODE_API_KEY GEMINI_API_KEY)
credential_unset_args=(-u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV)
for var in "${credential_vars[@]}"; do
  credential_unset_args+=(-u "$var")
done

cli_stub="$scratch/cli-stub"
mkdir -p "$cli_stub"
# Stubs the two gh shapes probe.ts actually issues: the identity lookup
# (`gh api --hostname <host> user --jq .login`) and the access probe
# (`gh repo view <target> --json viewerPermission,isFork,parent`). Logs
# every invocation so the assertions below can prove `issue create` did or
# did not reach the subprocess boundary.
cat >"$cli_stub/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log=${GH_LOG:?GH_LOG unset}
printf 'GH_INVOKED:' >>"$log"
printf ' %q' "$@" >>"$log"
printf '\n' >>"$log"

if [[ ${1-} == repo && ${2-} == view ]]; then
  printf '%s' "$GH_REPO_VIEW_JSON"
  exit 0
fi
if [[ ${1-} == api ]]; then
  for arg in "$@"; do
    if [[ $arg == user ]]; then
      printf '%s' "$GH_LOGIN"
      exit 0
    fi
  done
  printf 'unhandled gh api invocation: %s\n' "$*" >&2
  exit 1
fi
if [[ ${1-} == issue && ${2-} == create ]]; then
  printf 'https://github.com/other-owner/other-repo/issues/999\n'
  exit 0
fi
printf 'unhandled gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$cli_stub/gh"

# Stubs the same two shapes for glab (plan R7): `glab api --hostname <host>
# user` (identity, raw JSON - unlike gh there is no --jq flag) and
# `glab api --hostname <host> projects/<path>` (access probe).
cat >"$cli_stub/glab" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == api ]]; then
  for arg in "$@"; do
    if [[ $arg == user ]]; then
      printf '%s' "$GLAB_LOGIN"
      exit 0
    fi
  done
  printf '%s' "$GLAB_PROJECT_JSON"
  exit 0
fi
printf 'unhandled glab invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$cli_stub/glab"

# The stub model server's content-matched script (plan KTD1, KTD2). Three
# scenarios, each keyed by a distinct marker substring so matching is never
# ambiguous with the others or with a background-role request:
#   - bash-issue-write: the step-4 prompt asks for a `gh issue create` call.
#   - spawn-mcp-subagent: the step-5 prompt asks the model to spawn a
#     subagent; the scripted `task` call's `tasks[0].task` field carries the
#     child's own instructions, embedding the next marker.
#   - mcp-issue-create: the child's own turn, matched on that embedded
#     marker. omp exposes the MCP proxy tool to a `-p`/subagent session as a
#     mounted device rather than a first-class function (verified empirically
#     against the real runtime): the model calls the built-in `write` tool
#     with `path: "xd://mcp__glab_issue_create"`, and omp's own dispatch
#     resolves that into the real internal `mcp__glab_issue_create` tool_call
#     event the guard intercepts.
bash_marker='BASH_ISSUE_WRITE_PROBE'
bash_command='gh issue create --repo other-owner/other-repo --title "test issue" --body "test body"'
spawn_marker='SPAWN_MCP_SUBAGENT_PROBE'
child_marker='MCP_ISSUE_CREATE_PROBE'
mcp_repo='other-owner/other-mcp-repo'
child_task="$child_marker: Call the write tool with path=\"xd://mcp__glab_issue_create\" and content matching this issue (repo=\"$mcp_repo\", title=\"test mcp issue\", body=\"test mcp body\"). Do not call any other tool, and do not retry through a different tool or CLI."

stub_model_script="$scratch/stub-model-script.json"
jq -n \
  --arg bashMarker "$bash_marker" \
  --arg bashCommand "$bash_command" \
  --arg spawnMarker "$spawn_marker" \
  --arg childMarker "$child_marker" \
  --arg childTask "$child_task" \
  --arg mcpRepo "$mcp_repo" \
  '{rules: [
    {id: "bash-issue-write", match: $bashMarker, tool: "bash", arguments: {command: $bashCommand}},
    {id: "spawn-mcp-subagent", match: $spawnMarker, tool: "task",
     arguments: {context: "Real-runtime CI proof for the unmanaged-repo-guard MCP route (plan U7).", tasks: [{task: $childTask}]}},
    {id: "mcp-issue-create", match: $childMarker, tool: "write",
     arguments: {path: "xd://mcp__glab_issue_create", content: ({repo: $mcpRepo, title: "test mcp issue", body: "test mcp body"} | tostring)}}
  ]}' >"$stub_model_script"

stub_model_log="$scratch/stub-model.log"
: >"$stub_model_log"
STUB_MODEL_LOG="$stub_model_log" bun "$fixtures/stub-model-server.ts" "$stub_model_script" \
  >"$scratch/stub-model.port" 2>"$scratch/stub-model.err" &
stub_model_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$scratch/stub-model.port" ]] && break
  sleep 0.1
done
stub_model_port=$(<"$scratch/stub-model.port")
[[ -n $stub_model_port ]] ||
  fail "stub model server did not print a port: $(cat "$scratch/stub-model.err" 2>/dev/null)"

cat >"$home/.omp/agent/models.yml" <<YAML
providers:
  stub:
    baseUrl: http://127.0.0.1:$stub_model_port/v1
    auth: none
    api: openai-completions
    models:
      - id: stub-model
        name: Stub Model (plan U6/U7)
YAML

# Reads the stub model log's tail since a given 1-indexed line (exclusive of
# everything before it), so each scenario below asserts only its own turns
# against the one persistent stub server. `wc -l` on an empty file is 0, so
# the very first scenario starts at line 1.
model_log_since() {
  tail -n "+$(($1 + 1))" "$stub_model_log"
}
model_log_line_count() {
  wc -l <"$stub_model_log" | tr -d ' '
}

run_omp_prompt() {
  (
    cd "$workdir" &&
      env "${credential_unset_args[@]}" \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
        PATH="$cli_stub:$PATH" GH_LOG="${1:-/dev/null}" GH_REPO_VIEW_JSON="${2:-}" GH_LOGIN='ci-test-user' \
        GLAB_LOGIN='{"username":"ci-test-user"}' GLAB_PROJECT_JSON="${3:-}" \
        timeout --kill-after=10s 45s omp -p "$4" --model stub/stub-model --auto-approve --no-session --max-time 30
  )
}

audit_log="$home/.local/state/unmanaged-repo-guard/audit.jsonl"
audit_count() {
  [[ -f $audit_log ]] && wc -l <"$audit_log" | tr -d ' ' || printf '0'
}

# Fails naming the harness (not the guard) when the stub model server never
# emitted the scripted tool call this scenario depends on - a stub scripted
# to emit nothing must never pass vacuously.
assert_tool_matched() {
  # $1 = new log lines, $2 = expected matchedRule id, $3 = scenario label
  printf '%s\n' "$1" | jq -e --arg id "$2" 'select(.matchedRule == $id)' >/dev/null ||
    fail "$3: stub model server never emitted the scripted $2 tool call"
}
assert_no_catch_all() {
  # $1 = new log lines, $2 = scenario label
  printf '%s\n' "$1" | jq -e 'select(.catchAll == true)' >/dev/null &&
    fail "$2: the stub model server's catch-all branch answered an unscripted request"
  return 0
}
assert_tool_result_contains() {
  # $1 = new log lines, $2 = expected substring, $3 = scenario label
  printf '%s\n' "$1" | jq -r 'select(.toolResultText != null) | .toolResultText' | grep -qF "$2" ||
    fail "$3: no follow-up tool result contained: $2"
}
assert_tool_result_excludes() {
  # $1 = new log lines, $2 = forbidden substring, $3 = scenario label
  printf '%s\n' "$1" | jq -r 'select(.toolResultText != null) | .toolResultText' | grep -qF "$2" &&
    fail "$3: a follow-up tool result unexpectedly contained: $2"
  return 0
}

prompt_bash="$bash_marker: run the guarded issue-write probe now."
prompt_subagent="$spawn_marker: Spawn exactly one subagent to attempt a GitLab MCP issue-write against a specific target repository. Do not call any tool yourself."

# --- Step 4 (plan R1/U6): top-level bash gh issue create ------------------

before=$(model_log_line_count)
unmanaged_log="$scratch/gh-unmanaged.log"
unmanaged_out=$(run_omp_prompt "$unmanaged_log" '{"viewerPermission":"READ","isFork":false,"parent":null}' '' "$prompt_bash" 2>&1) ||
  fail "unmanaged-repo bash run failed: $unmanaged_out"
new_lines=$(model_log_since "$before")
assert_tool_matched "$new_lines" 'bash-issue-write' 'step 4 unmanaged'
assert_no_catch_all "$new_lines" 'step 4 unmanaged'
assert_tool_result_contains "$new_lines" 'a repository the user does not manage' 'step 4 unmanaged'
assert_tool_result_contains "$new_lines" 'other-owner/other-repo' 'step 4 unmanaged'
[[ -f $unmanaged_log ]] || fail 'step 4 unmanaged: gh probe never ran'
grep -qF 'issue create' "$unmanaged_log" &&
  fail 'step 4 unmanaged: gh issue create executed despite the block'
audit_before=$(audit_count)
[[ $audit_before -eq 1 ]] || fail "step 4 unmanaged: audit log has $audit_before entries, expected 1"

managed_log="$scratch/gh-managed.log"
before=$(model_log_line_count)
managed_out=$(run_omp_prompt "$managed_log" '{"viewerPermission":"WRITE","isFork":false,"parent":null}' '' "$prompt_bash" 2>&1) ||
  fail "managed-repo bash run failed: $managed_out"
new_lines=$(model_log_since "$before")
assert_tool_matched "$new_lines" 'bash-issue-write' 'step 4 managed'
assert_no_catch_all "$new_lines" 'step 4 managed'
assert_tool_result_excludes "$new_lines" 'a repository the user does not manage' 'step 4 managed'
[[ -f $managed_log ]] || fail 'step 4 managed: gh probe never ran'
grep -qF 'issue create' "$managed_log" ||
  fail 'step 4 managed: gh issue create never executed despite a managed verdict'
[[ $(audit_count) -eq $audit_before ]] ||
  fail 'step 4 managed: audit log gained an entry on a pass-through call'

# --- Step 5 (plan R7/U7): task-spawned subagent's own MCP call ------------

# Two runtime questions the originating design left open (plan KTD3) were
# resolved empirically against this real runtime before this script was
# written, per plan Assumptions: (a) the `tool_call` hook does NOT fire for
# a tool name nothing registered - a scripted tool_calls response naming an
# undeclared function is discarded by omp's own client-side validation
# before the extension layer ever sees it (observed as repeated
# empty-completion retries, never a block or a pass). This confirms rather
# than narrows the original inference, so the stub MCP server below stays
# required for both the block and pass-through halves. (b) MCP registration
# does NOT survive across separate omp processes sharing one scratch HOME -
# every invocation independently reconnects and re-issues `tools/list`
# (observed directly: each of the many omp invocations exercised while
# developing this script logged its own fresh `tools/list` line). The
# pre-warm below is therefore genuinely belt-and-braces, exactly as plan
# Assumptions hedges: it buys nothing beyond what the registration
# assertion already protects, and is kept only as insurance against a slow
# cold start on a loaded CI runner.
# The pre-warm run itself uses a MANAGED verdict deliberately: it must not
# touch the audit log, or step 5's own before/after counts below would be
# thrown off by a block this throwaway run caused.
: >"$stub_mcp_log"
prewarm_audit_before=$(audit_count)
prewarm_model_before=$(model_log_line_count)
prewarm_out=$(run_omp_prompt '' '' '{"permissions":{"project_access":{"access_level":40}}}' "$prompt_subagent" 2>&1) ||
  fail "step 5 pre-warm run failed: $prewarm_out"
# The pre-warm is a real dispatch through the guard, not a no-op: assert it
# passed through (an audit entry would mean the guard spuriously blocked a
# managed call) and that the MCP tool actually ran (tools/call reached the
# server), so a silent block or skip cannot hide behind "belt-and-braces".
[[ $(audit_count) -eq $prewarm_audit_before ]] ||
  fail "step 5 pre-warm: audit log gained an entry on what must be a pass-through call"
grep -qF '"event":"tools/call"' "$stub_mcp_log" ||
  fail "step 5 pre-warm: the MCP tool never executed (no tools/call) — registration or dispatch failed silently"
: >"$stub_mcp_log"
before=$(model_log_line_count)
audit_before=$(audit_count)
unmanaged_out=$(run_omp_prompt '' '' '{"permissions":{"project_access":{"access_level":10}}}' "$prompt_subagent" 2>&1) ||
  fail "unmanaged-repo subagent run failed: $unmanaged_out"
new_lines=$(model_log_since "$before")
assert_tool_matched "$new_lines" 'spawn-mcp-subagent' 'step 5 unmanaged'
assert_tool_matched "$new_lines" 'mcp-issue-create' 'step 5 unmanaged'
assert_no_catch_all "$new_lines" 'step 5 unmanaged'
assert_tool_result_contains "$new_lines" 'a repository the user does not manage' 'step 5 unmanaged'
assert_tool_result_contains "$new_lines" "$mcp_repo" 'step 5 unmanaged'
grep -qF '"event":"tools/list"' "$stub_mcp_log" ||
  fail 'step 5 unmanaged: the MCP server was never registered (no tools/list)'
grep -qF '"event":"tools/call"' "$stub_mcp_log" &&
  fail 'step 5 unmanaged: tools/call reached the MCP server despite the block'
[[ $(audit_count) -eq $((audit_before + 1)) ]] ||
  fail "step 5 unmanaged: audit log gained $(($(audit_count) - audit_before)) entries, expected 1"
audit_before=$(audit_count)

: >"$stub_mcp_log"
before=$(model_log_line_count)
managed_out=$(run_omp_prompt '' '' '{"permissions":{"project_access":{"access_level":40}}}' "$prompt_subagent" 2>&1) ||
  fail "managed-repo subagent run failed: $managed_out"
new_lines=$(model_log_since "$before")
assert_tool_matched "$new_lines" 'spawn-mcp-subagent' 'step 5 managed'
assert_tool_matched "$new_lines" 'mcp-issue-create' 'step 5 managed'
assert_no_catch_all "$new_lines" 'step 5 managed'
assert_tool_result_excludes "$new_lines" 'a repository the user does not manage' 'step 5 managed'
grep -qF '"event":"tools/list"' "$stub_mcp_log" ||
  fail 'step 5 managed: the MCP server was never registered (no tools/list)'
grep -qF '"event":"tools/call"' "$stub_mcp_log" ||
  fail 'step 5 managed: tools/call never reached the MCP server despite a managed verdict'
[[ $(audit_count) -eq $audit_before ]] ||
  fail 'step 5 managed: audit log gained an entry on a pass-through call'

kill "$stub_model_pid" 2>/dev/null || true
wait "$stub_model_pid" 2>/dev/null || true
stub_model_pid=""

real_lock_after=$(snapshot_real_lock)
[[ $real_lock_before == "$real_lock_after" ]] ||
  fail "real \$HOME plugin lock changed during the run: $real_lock"

printf 'real OMP unmanaged-repo-guard: install, enable, lock, raw-.ts load, and omp-runtime block/allow proof (top-level bash and subagent MCP routes) passed\n'
