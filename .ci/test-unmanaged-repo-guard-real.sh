#!/usr/bin/env bash
set -euo pipefail

# Real-omp install/enable/runtime proof for the unmanaged-repo-guard plugin
# (plan units U7, U8). Modeled on test-omp-real-plugin.sh: version-pinned
# omp, a relocated HOME so nothing escapes the real one, and a scratch
# marketplace built from the already-rendered package this script receives
# as $1.
#
# Step 4 below is the load-bearing assertion for U7 ("Execution note"): it
# drives a real tool call through omp's OWN runtime against a stubbed `gh`,
# proving omp resolves the manifest's raw `./src/index.ts` entry and that the
# guard's `{ block: true, reason }` return actually stops the bash tool. A
# `bun` import of the entry file would only prove the module parses, which
# U7 explicitly forbids substituting here (KTD1's regression detector).
#
# Step 5 below is the load-bearing assertion for U8: the same proof, but for
# an MCP tool call issued by a spawned SUBAGENT's own conversation rather
# than a top-level bash call, so the guard's interception of a
# subagent-originated call is proved end to end rather than inferred.
#
# The "Detection limit, stated honestly" from U7 applies to both: CI pins
# the omp version, so this re-confirms known-good behavior and only catches
# a regression on the run that bumps the pin.

usage='usage: test-unmanaged-repo-guard-real.sh RENDERED_PACKAGE_DIR'
package_dir=${1:?$usage}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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
trap 'kill "${stub_pid:-}" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
home="$scratch/home"
marketplace="$scratch/marketplace"
workdir="$scratch/workdir"
mkdir -p "$home" "$workdir" "$marketplace/.omp-plugin" "$marketplace/plugins"
cp -R -- "$package_dir" "$marketplace/plugins/unmanaged-repo-guard"
cat >"$marketplace/.omp-plugin/marketplace.json" <<'JSON'
{"name":"h82-dotfiles","owner":{"name":"test"},"plugins":[{"name":"unmanaged-repo-guard","source":"./plugins/unmanaged-repo-guard"}]}
JSON

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
# extension resolution -- but it runs with no omp runtime turn at all, and is
# the standing floor for KTD1's no-build claim.
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

# Step 4 (load-bearing): drive one real bash tool call through omp's own
# runtime, twice - once against an unmanaged stub verdict (must block) and
# once against a managed one (must not). Model turns are served by a local
# keyless stub provider (KTD5): a models.yml `auth: none` provider backed by
# .ci/lib/stub-model-server.ts on 127.0.0.1. This needs no model credential,
# so the proof runs unconditionally on every CI run.
# The proof must reach the loopback stub, never a real provider. Rather than
# refusing to run when the invoking shell happens to carry a provider key - a
# developer workstation usually does - strip the whole set from the child
# environment below, so the omp process tree cannot authenticate anywhere even
# when the caller could. Consumed by run_omp_prompt.
omp_credential_vars=(ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY GEMINI_API_KEY)
unset_credentials=()
for var in "${omp_credential_vars[@]}"; do
  unset_credentials+=(-u "$var")
done

gh_stub="$scratch/gh-stub"
mkdir -p "$gh_stub"
# Stubs the two gh shapes probe.ts actually issues: the identity lookup
# (`gh api --hostname <host> user --jq .login`) and the access probe
# (`gh repo view <target> --json viewerPermission,isFork,parent`). Logs
# every invocation so the assertions below can prove `issue create` did or
# did not reach the subprocess boundary.
cat >"$gh_stub/gh" <<'SH'
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
chmod +x "$gh_stub/gh"

gh_command='gh issue create --repo other-owner/other-repo --title "test issue" --body "test body"'
prompt="Run exactly one bash tool call: \`$gh_command\`. Do not run any other command, and do not retry through a different tool or CLI. Report verbatim whatever output or error that single command produces."

# Poll port_file for the stub server's printed port for up to 10s, checking
# stub_pid liveness so a server that exits early fails fast with its stderr
# instead of waiting out the full timeout. Shared by the bash-scenario and
# subagent-scenario stub servers below (both use stub-model-server.ts).
wait_for_stub_port() {
  local port_file=$1 stderr_file=$2 label=$3
  for _ in $(seq 1 100); do
    [[ -s $port_file ]] && break
    kill -0 "$stub_pid" 2>/dev/null ||
      fail "$label exited before printing its port: $(cat "$stderr_file" 2>/dev/null)"
    sleep 0.1
  done
  [[ -s $port_file ]] || fail "$label never printed its port"
  cat "$port_file"
}

# Point the ci-stub provider at the given stub-model-server.ts port. Called
# once per stub server below, overwriting models.yml each time.
write_stub_models_yml() {
  local port=$1
  mkdir -p "$home/.omp/agent"
  cat >"$home/.omp/agent/models.yml" <<YAML
providers:
  ci-stub:
    baseUrl: http://127.0.0.1:$port/v1
    api: openai-completions
    auth: none
    models:
      - id: stub-1
        name: CI Stub
        contextWindow: 128000
        maxTokens: 4096
YAML
}

# Stand up the stub model server that drives omp's own extension resolution
# (KTD5). It is torn down on any exit, including a failure, by the trap
# declared above.
stub_log="$scratch/stub-model-server.log"
: >"$stub_log"
stub_port_file="$scratch/stub-model-server.port"
stub_stderr_file="$scratch/stub-model-server.stderr"
tool_arguments=$(jq -cn --arg command "$gh_command" '{command: $command}')
STUB_SCENARIO=single-tool bun "$repo_root/.ci/lib/stub-model-server.ts" "$stub_log" bash "$tool_arguments" \
  >"$stub_port_file" 2>"$stub_stderr_file" &
stub_pid=$!
stub_port=$(wait_for_stub_port "$stub_port_file" "$stub_stderr_file" 'stub model server')
write_stub_models_yml "$stub_port"

run_omp_prompt() {
  (
    cd "$workdir" &&
      env "${unset_credentials[@]}" -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        PATH="$gh_stub:$PATH" GH_LOG="$1" GH_REPO_VIEW_JSON="$2" GH_LOGIN='ci-test-user' \
        NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
        omp -p "$prompt" --model ci-stub/stub-1 --auto-approve --no-session --max-time 120
  )
}

unmanaged_log="$scratch/gh-unmanaged.log"
set +e
unmanaged_out=$(run_omp_prompt "$unmanaged_log" '{"viewerPermission":"READ","isFork":false,"parent":null}' 2>&1)
unmanaged_status=$?
set -e
[[ $unmanaged_status -eq 0 ]] || fail "unmanaged-repo run exited $unmanaged_status: $unmanaged_out"
grep -qF 'a repository the user does not manage' <<<"$unmanaged_out" ||
  fail "blocked reason text missing from output: $unmanaged_out"
grep -qF 'other-owner/other-repo' <<<"$unmanaged_out" ||
  fail "blocked reason did not name the target repository: $unmanaged_out"
[[ -f $unmanaged_log ]] || fail 'unmanaged-repo run: gh probe never ran'
grep -qF 'issue create' "$unmanaged_log" &&
  fail 'unmanaged-repo run: gh issue create executed despite the block'

managed_log="$scratch/gh-managed.log"
set +e
managed_out=$(run_omp_prompt "$managed_log" '{"viewerPermission":"WRITE","isFork":false,"parent":null}' 2>&1)
managed_status=$?
set -e
[[ $managed_status -eq 0 ]] || fail "managed-repo run exited $managed_status: $managed_out"
grep -qF 'a repository the user does not manage' <<<"$managed_out" &&
  fail "managed-repo run was unexpectedly blocked: $managed_out"
[[ -f $managed_log ]] || fail 'managed-repo run: gh probe never ran'
grep -qF 'issue create' "$managed_log" ||
  fail 'managed-repo run: gh issue create never executed despite a managed verdict'

# A server that never saw a request would let the steps above pass
# vacuously, and a request that never offered `bash` would mean the tool
# list on the wire wasn't omp's own real one.
[[ -s $stub_log ]] ||
  fail 'stub model server was never contacted - the omp-runtime proof ran vacuously'
grep -qF '"bash"' "$stub_log" ||
  fail "stub model server never saw omp offer the bash tool: $(cat "$stub_log")"

# Step 5 (load-bearing, U8): drive one real MCP tool call issued by a
# SUBAGENT's own conversation through omp's own runtime, twice - once
# against an unmanaged stub verdict (must block) and once against a managed
# one (must not). This proves the interception claim for a
# subagent-originated MCP tool call (e.g. mcp__glab_issue_create) end to
# end, rather than inferring it from step 4's top-level bash proof plus
# triggers.ts's in-process classify() unit coverage separately.
#
# omp only mounts a connected MCP server's tools directly in a session's
# own tool list when the `write` tool is unavailable, or when
# `tools.xdev` is false; otherwise MCP tools are folded behind a generic
# `xd://` device transport reached through `write`, and never appear as a
# distinct `mcp__<server>_<tool>` entry a scripted model could name
# (confirmed empirically against the locked omp version). `tools.xdev` is
# set to `false` only now, after steps 3b and 4 above have already run and
# asserted, so their behavior is exactly what it was before this unit.
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true

cat >"$home/.omp/agent/config.yml" <<'YAML'
tools:
  xdev: false
YAML

# The stub MCP server (.ci/lib/stub-mcp-issue-server.ts) is registered
# under the server name "glab", so omp mints the runtime tool name
# `mcp__glab_issue_create` (confirmed empirically against the locked omp
# version; see the plan's U8 execution note - the guard's pattern, not
# this name, is what is actually under test). Every `issue_create`
# invocation is appended to MCP_ISSUE_LOG, mirroring how the `gh` stub
# above uses GH_LOG to prove a subprocess boundary was or wasn't crossed.
mcp_log="$scratch/mcp-issue-server.log"
: >"$mcp_log"
cat >"$home/.omp/agent/mcp.json" <<JSON
{
  "\$schema": "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json",
  "mcpServers": {
    "glab": {
      "command": "bun",
      "args": ["$repo_root/.ci/lib/stub-mcp-issue-server.ts"],
      "env": { "MCP_ISSUE_LOG": "$mcp_log" }
    }
  }
}
JSON

# Stubs the two `glab` shapes probe.ts issues for a gitlab-hostKind
# target: the identity lookup (`glab api --hostname <host> user`) and the
# access probe (`glab api --hostname <host> projects/<path>`). Logs every
# invocation, mirroring the `gh` stub above.
cat >"$gh_stub/glab" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log=${GLAB_LOG:?GLAB_LOG unset}
printf 'GLAB_INVOKED:' >>"$log"
printf ' %q' "$@" >>"$log"
printf '\n' >>"$log"

if [[ ${1-} == api && ${2-} == --hostname ]]; then
  if [[ ${4-} == user ]]; then
    printf '%s' "$GLAB_USER_JSON"
    exit 0
  fi
  if [[ ${4-} == projects/* ]]; then
    printf '%s' "$GLAB_PROJECT_JSON"
    exit 0
  fi
  printf 'unhandled glab api invocation: %s\n' "$*" >&2
  exit 1
fi
printf 'unhandled glab invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$gh_stub/glab"

subagent_prompt='Spawn exactly one subagent via the task tool. Do not do the work yourself. Report verbatim whatever the subagent reports back as its result.'

# Same stub-model-server.ts, driving a different scripted conversation
# (STUB_SCENARIO=subagent): see that file for the parent/child turn
# sequence and why it matches on the last user message text instead of
# tool-list containment.
subagent_stub_log="$scratch/stub-model-server-subagent.log"
: >"$subagent_stub_log"
subagent_stub_port_file="$scratch/stub-model-server-subagent.port"
subagent_stub_stderr_file="$scratch/stub-model-server-subagent.stderr"
STUB_SCENARIO=subagent bun "$repo_root/.ci/lib/stub-model-server.ts" "$subagent_stub_log" "$subagent_prompt" \
  >"$subagent_stub_port_file" 2>"$subagent_stub_stderr_file" &
stub_pid=$!
subagent_stub_port=$(wait_for_stub_port "$subagent_stub_port_file" "$subagent_stub_stderr_file" 'subagent stub model server')
write_stub_models_yml "$subagent_stub_port"

run_omp_subagent_prompt() {
  (
    cd "$workdir" &&
      env "${unset_credentials[@]}" -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        PATH="$gh_stub:$PATH" GLAB_LOG="$1" GLAB_USER_JSON='{"username":"ci-test-user"}' GLAB_PROJECT_JSON="$2" \
        NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
        omp -p "$subagent_prompt" --model ci-stub/stub-1 --auto-approve --no-session --max-time 120
  )
}

unmanaged_glab_log="$scratch/glab-unmanaged.log"
: >"$mcp_log"
set +e
unmanaged_subagent_out=$(run_omp_subagent_prompt "$unmanaged_glab_log" '{"permissions":{"project_access":{"access_level":20}}}' 2>&1)
unmanaged_subagent_status=$?
set -e
[[ $unmanaged_subagent_status -eq 0 ]] ||
  fail "unmanaged subagent run exited $unmanaged_subagent_status: $unmanaged_subagent_out"
grep -qF 'a repository the user does not manage' <<<"$unmanaged_subagent_out" ||
  fail "subagent block reason text missing from output: $unmanaged_subagent_out"
grep -qF 'other-owner/other-repo' <<<"$unmanaged_subagent_out" ||
  fail "subagent block reason did not name the target repository: $unmanaged_subagent_out"
[[ ! -s $mcp_log ]] ||
  fail "unmanaged subagent run: mcp__glab_issue_create executed despite the block: $(cat "$mcp_log")"

managed_glab_log="$scratch/glab-managed.log"
: >"$mcp_log"
set +e
managed_subagent_out=$(run_omp_subagent_prompt "$managed_glab_log" '{"permissions":{"project_access":{"access_level":40}}}' 2>&1)
managed_subagent_status=$?
set -e
[[ $managed_subagent_status -eq 0 ]] ||
  fail "managed subagent run exited $managed_subagent_status: $managed_subagent_out"
grep -qF 'a repository the user does not manage' <<<"$managed_subagent_out" &&
  fail "managed subagent run was unexpectedly blocked: $managed_subagent_out"
[[ -s $mcp_log ]] ||
  fail 'managed subagent run: mcp__glab_issue_create never executed despite a managed verdict'
mcp_invocations=$(wc -l <"$mcp_log")
[[ $mcp_invocations -eq 1 ]] ||
  fail "managed subagent run: expected exactly 1 mcp__glab_issue_create invocation, got $mcp_invocations: $(cat "$mcp_log")"

# A server that never saw a request would let the steps above pass
# vacuously. The ordered request log must show exactly one parent request
# that issued the `task` call, then one child request that issued the MCP
# call, for each of the two runs above (unmanaged then managed) - and the
# child request's own tool list must actually have offered the MCP tool,
# or the proof shows nothing. A request whose last user message matched
# neither known text (see stub-model-server.ts) is logged with an "error"
# key instead of a "tag", which is rejected below too.
[[ -s $subagent_stub_log ]] ||
  fail 'subagent stub model server was never contacted - the subagent-runtime proof ran vacuously'
mismatched=$(jq -s '[.[] | select(has("error"))]' "$subagent_stub_log")
[[ $(jq 'length' <<<"$mismatched") -eq 0 ]] ||
  fail "subagent stub model server saw a request matching neither known last-user text: $mismatched"
tags=$(jq -s -c '[.[] | select(.toolMsgCount == 0) | .tag]' "$subagent_stub_log")
[[ $tags == '["parent","child","parent","child"]' ]] ||
  fail "subagent stub model server request sequence was $tags, expected [parent,child,parent,child]"
jq -e -s 'all(.[] | select(.toolMsgCount == 0 and .tag == "child"); (.tools | index("mcp__glab_issue_create")) != null)' \
  "$subagent_stub_log" >/dev/null ||
  fail "a child request's own tool list omitted mcp__glab_issue_create"

# Step 6 (load-bearing, U11): the SAME MCP issue write, but on omp's DEFAULT
# `tools.xdev`. Step 5 had to set `tools.xdev: false` to make
# `mcp__glab_issue_create` appear as a distinct tool name at all; with the
# default, omp mounts every connected MCP tool as an `xd://` device that is
# absent from the model's tool list and reached only by calling the ordinary
# `write` tool with the JSON arguments as `content`. That is the shipped
# configuration, and step 5 never exercises it.
#
# What this pins is an omp RUNTIME behaviour the guard silently depends on.
# Tracing every toolName the handler receives shows omp fires the hook TWICE
# for a device write: once for the outer `write` (path `xd://<tool>`, arguments
# as `content`), then again for the expanded `mcp__<server>_<tool>` with its
# parsed arguments. `classify` deliberately ignores the outer `write` - the
# expansion is what it matches. So the guard covers the default mounting only
# because omp re-enters the hook after expanding. If a future omp stopped
# re-firing, step 5 would still pass and the default configuration would fail
# open with nothing to catch it; this step is that detector.
rm -f "$home/.omp/agent/config.yml"
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true

device_arguments=$(
  printf '{"path":"xd://mcp__glab_issue_create","content":%s,"i":"file the issue"}' \
    "$(printf '{"repo":"other-owner/other-repo","title":"test issue","body":"test body"}' | jq -Rs .)"
)
device_stub_log="$scratch/stub-model-server-device.log"
: >"$device_stub_log"
device_stub_port_file="$scratch/stub-model-server-device.port"
device_stub_stderr_file="$scratch/stub-model-server-device.stderr"
STUB_SCENARIO=single-tool bun "$repo_root/.ci/lib/stub-model-server.ts" "$device_stub_log" write "$device_arguments" \
  >"$device_stub_port_file" 2>"$device_stub_stderr_file" &
stub_pid=$!
device_stub_port=$(wait_for_stub_port "$device_stub_port_file" "$device_stub_stderr_file" 'device stub model server')
write_stub_models_yml "$device_stub_port"

device_prompt='Write the issue payload to the xd:// device exactly once. Do not use any other tool.'
run_omp_device_prompt() {
  (
    cd "$workdir" &&
      env "${unset_credentials[@]}" -u PI_CODING_AGENT_DIR -u OMP_AGENT_ENV \
        HOME="$home" USERPROFILE="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
        PATH="$gh_stub:$PATH" GLAB_LOG="$1" GLAB_USER_JSON='{"username":"ci-test-user"}' GLAB_PROJECT_JSON="$2" \
        NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
        omp -p "$device_prompt" --model ci-stub/stub-1 --auto-approve --no-session --max-time 120
  )
}

: >"$mcp_log"
set +e
unmanaged_device_out=$(run_omp_device_prompt "$scratch/glab-device-unmanaged.log" '{"permissions":{"project_access":{"access_level":20}}}' 2>&1)
unmanaged_device_status=$?
set -e
[[ $unmanaged_device_status -eq 0 ]] ||
  fail "unmanaged device run exited $unmanaged_device_status: $unmanaged_device_out"
grep -qF 'a repository the user does not manage' <<<"$unmanaged_device_out" ||
  fail "device block reason text missing from output: $unmanaged_device_out"
grep -qF 'other-owner/other-repo' <<<"$unmanaged_device_out" ||
  fail "device block reason did not name the target repository: $unmanaged_device_out"
[[ ! -s $mcp_log ]] ||
  fail "unmanaged device run: the xd:// device executed despite the block: $(cat "$mcp_log")"

: >"$mcp_log"
set +e
managed_device_out=$(run_omp_device_prompt "$scratch/glab-device-managed.log" '{"permissions":{"project_access":{"access_level":40}}}' 2>&1)
managed_device_status=$?
set -e
[[ $managed_device_status -eq 0 ]] ||
  fail "managed device run exited $managed_device_status: $managed_device_out"
grep -qF 'a repository the user does not manage' <<<"$managed_device_out" &&
  fail "managed device run was unexpectedly blocked: $managed_device_out"
[[ -s $mcp_log ]] ||
  fail 'managed device run: the xd:// device never executed despite a managed verdict'
device_invocations=$(wc -l <"$mcp_log")
[[ $device_invocations -eq 1 ]] ||
  fail "managed device run: expected exactly 1 device invocation, got $device_invocations: $(cat "$mcp_log")"

# The device route only proves anything if the MCP tool was genuinely absent
# from the model's own tool list - otherwise the run silently reverted to
# step 5's direct-name route and this step tested nothing new.
[[ -s $device_stub_log ]] ||
  fail 'device stub model server was never contacted - the U11 proof ran vacuously'
jq -e -s 'all(.[]; (.tools | index("mcp__glab_issue_create")) == null and (.tools | index("write")) != null)' \
  "$device_stub_log" >/dev/null ||
  fail "device run's tool list did not match omp's default xd:// mounting: $(cat "$device_stub_log")"

real_lock_after=$(snapshot_real_lock)
[[ $real_lock_before == "$real_lock_after" ]] ||
  fail "real \$HOME plugin lock changed during the run: $real_lock"

printf 'real OMP unmanaged-repo-guard: install, enable, lock, raw-.ts load, top-level bash block/allow, subagent MCP block/allow, and default-xdev device block/allow proof passed\n'
