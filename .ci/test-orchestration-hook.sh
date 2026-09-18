#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'orchestration hook: %s\n' "$*" >&2; exit 1; }
pass() { printf 'orchestration hook: %s\n' "$*"; }

chezmoi_bin=$(type -P chezmoi) || fail 'no chezmoi binary found on PATH'
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
source_root=$(resolve_source_root "$repo_root")
# Builds the sandbox render() assumes — scratch dir, EXIT trap, bin/ and target/,
# the `op` stub and the empty config. This gate adds only what is its own.
setup_render_scratch orchestration-hook
# The lead path reads this before it ever calls the Orca CLI, and delivers
# nothing when it is absent. Without it the lead cases below would short-circuit
# and the Orca-retrieval assertions would pass without reaching the CLI at all.
mkdir -p "$scratch/home/.agents/skills/orchestration"
printf 'CI ORCHESTRATION SKILL BODY\n' >"$scratch/home/.agents/skills/orchestration/SKILL.md"
# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"

for surface in \
  packages/orchestration-hook/src/cli.ts \
  packages/orchestration-hook/src/payload.ts \
  .chezmoitemplates/orchestration-everyone.tmpl \
  .chezmoitemplates/orchestration-coordinator.tmpl \
  dot_local/share/orchestration-hook/everyone.md.tmpl \
  dot_local/share/orchestration-hook/coordinator.md.tmpl \
  .chezmoitemplates/claude-hook-declaration.tmpl \
  .chezmoitemplates/codex-hook-declaration.tmpl \
  dot_local/share/dotfiles-claude-plugin/hooks/hooks.json.tmpl \
  dot_local/share/dotfiles-codex-plugin/hooks/hooks.json.tmpl \
  .chezmoiscripts/60-build/run_onchange_after_20-build-orchestration-hook.sh.tmpl \
  .chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl; do
  require_file "$repo_root" "$scratch" "$chezmoi_bin" "$surface"
done

# ---------------------------------------------------------------- build once
resolve_bun
[[ -n ${BUN_BIN:-} ]] || fail 'bun is not installed; this gate compiles the hook binary'

# The binary reads its two bodies from managed files under $HOME at run time, so
# every hook case below needs them staged the way an apply would leave them.
# Rendered through the same wrappers chezmoi deploys, not copied from the source
# templates: the source is a template now and its raw bytes are not the payload.
payload_dir="$scratch/home/.local/share/orchestration-hook"
mkdir -p "$payload_dir"
for body in everyone coordinator; do
  render "$repo_root" "$scratch" "$chezmoi_bin" linux \
    "$source_root/dot_local/share/orchestration-hook/$body.md.tmpl" "$payload_dir/$body.md"
  [[ -s "$payload_dir/$body.md" ]] || fail "the rendered $body payload is empty"
done

binary="$scratch/orchestration-hook"
( cd "$repo_root/packages/orchestration-hook" \
    && "$BUN_BIN" build --compile \
         --define process.env.DOTFILES_HOOK_BUILD_ID="'ci-gate'" \
         ./src/cli.ts --outfile "$binary" >/dev/null ) \
  || fail 'the hook binary did not compile'
[[ -x $binary ]] || fail 'the compiled hook binary is not executable'

# A closed PATH is the only way to express "no Orca CLI on this host": every
# real machine has /usr/bin/orca-ide, so a PATH that keeps the system
# directories cannot test the absent-CLI path.
closed_path="$scratch/closed-bin"
mkdir -p "$closed_path"
for tool in bash uname sleep; do
  tool_path=$(type -P "$tool") || continue
  ln -sf -- "$tool_path" "$closed_path/$tool"
done

run_hook() {
  local harness=$1 role_env=$2 extra_path=${3:-}
  local path="$closed_path"
  [[ -n $extra_path ]] && path="$extra_path:$closed_path"
  # `$( )` capture is load-bearing: it waits for EOF, so a leaked background
  # writer still holding the pipe after the hook exits shows up as a hang here
  # rather than passing silently.
  # shellcheck disable=SC2086
  env -i PATH="$path" HOME="$scratch/home" $role_env "$binary" hook --harness "$harness" </dev/null
}

run_with_event() {
  local subcommand=$1 harness=$2 role_env=$3 event_json=${4:-} extra_path=${5:-}
  local path="$closed_path"
  [[ -n $extra_path ]] && path="$extra_path:$closed_path"
  # shellcheck disable=SC2086
  printf '%s' "$event_json" \
    | env -i PATH="$path" HOME="$scratch/home" $role_env "$binary" "$subcommand" --harness "$harness"
}

run_guard() { run_with_event guard "$@"; }

# ------------------------------------------------------- fail-open contracts
out=$(run_hook claude "")
[[ $out == "{}" ]] || fail "Claude Code outside Orca must print exactly {} (got: $out)"
out=$(run_hook codex "")
[[ -z $out ]] || fail "Codex outside Orca must print nothing (got: $out)"
pass 'a session outside Orca receives nothing, in both harnesses'

out=$(run_hook claude "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1")
[[ $out == "{}" ]] || fail 'a lead with no Orca CLI on PATH must print exactly {}'
pass 'a lead with no reachable Orca CLI receives nothing, not a partial envelope'

# A hanging CLI must not hold the hook past its deadline, and must not leave a
# descendant holding stdout after it exits — the process-group kill contract.
hang_bin="$scratch/hang-bin"
mkdir -p "$hang_bin"
printf '#!/usr/bin/env bash\nsleep 120 & wait\n' >"$hang_bin/orca-ide"
chmod 0755 "$hang_bin/orca-ide"
started=$(date +%s)
out=$(run_hook claude "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1" "$hang_bin")
elapsed=$(( $(date +%s) - started ))
[[ $out == "{}" ]] || fail 'a lead whose Orca CLI hangs must print exactly {}'
# The ceiling is the code's own budget plus CI margin, not a loose sanity bound.
# Each hooks.json declares `timeout: 15`, so a gate that tolerated 30s would go
# green on a hook the harness had already killed — the exact green-while-red
# shape this gate exists to catch.
(( elapsed <= 12 )) || fail "a hanging Orca CLI held the hook for ${elapsed}s, past its 8s budget"
# The stub sleeps, so a run that returns instantly never reached it — the lead
# path short-circuited somewhere earlier and this case asserted nothing.
(( elapsed >= 1 )) || fail 'the hanging-CLI case returned instantly, so the Orca call was never made'
pass "a hanging Orca CLI is abandoned at the deadline (${elapsed}s) and holds no pipe"

ok_bin="$scratch/ok-bin"
mkdir -p "$ok_bin"
printf '#!/usr/bin/env bash\nprintf "CI GUIDE BODY\\n"\n' >"$ok_bin/orca-ide"
chmod 0755 "$ok_bin/orca-ide"
out=$(run_hook claude "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1" "$ok_bin")
context=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext') \
  || fail 'a lead with a healthy Orca CLI must receive a SessionStart envelope'
for half in 'CI ORCHESTRATION SKILL BODY' 'CI GUIDE BODY' 'orchestration-everyone:begin' 'orchestration-coordinator:begin'; do
  [[ $context == *"$half"* ]] || fail "the lead envelope is missing: $half"
done
pass 'a lead with a healthy Orca CLI receives all four halves in one envelope'

# The screen-reader remap, end to end. On a non-Darwin host the bare name
# reaches /usr/bin/orca, the GNOME screen reader, and running it would start
# speech in the user's session — so this guard is the destructive one in the
# whole package. Unit tests cover resolveOrcaCommand's branches with an injected
# platform; only this case drives the real uname(1) call behind it.
remap_bin="$scratch/remap-bin"
mkdir -p "$remap_bin"
printf '#!/usr/bin/env bash\ntouch %q\nprintf "SCREEN READER GUIDE\\n"\n' "$scratch/screen-reader-ran" \
  >"$remap_bin/orca"
printf '#!/usr/bin/env bash\nprintf "SAFE GUIDE\\n"\n' >"$remap_bin/orca-ide"
chmod 0755 "$remap_bin/orca" "$remap_bin/orca-ide"
for configured in orca /usr/bin/orca; do
  rm -f "$scratch/screen-reader-ran"
  out=$(run_hook claude \
    "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1 ORCA_CLI_COMMAND=$configured" \
    "$remap_bin")
  [[ -e "$scratch/screen-reader-ran" ]] \
    && fail "ORCA_CLI_COMMAND=$configured reached the screen reader instead of orca-ide"
  [[ $out == *'SAFE GUIDE'* ]] \
    || fail "ORCA_CLI_COMMAND=$configured did not remap to orca-ide"
done
pass 'a configured bare orca remaps to orca-ide; the screen reader is never launched'

# An unrelated configured command is honoured rather than overridden.
printf '#!/usr/bin/env bash\nprintf "CUSTOM GUIDE\\n"\n' >"$remap_bin/orca-dev"
chmod 0755 "$remap_bin/orca-dev"
out=$(run_hook claude \
  "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1 ORCA_CLI_COMMAND=$remap_bin/orca-dev" \
  "$remap_bin")
[[ $out == *'CUSTOM GUIDE'* ]] \
  || fail 'an explicitly configured non-screen-reader command was not honoured'
pass 'an unrelated configured Orca command is used as given'

interactive_env="ORCA_TERMINAL_HANDLE=term_ci ORCA_CLI_COMMAND=$remap_bin/orca-dev"
out=$(run_hook claude "$interactive_env" "$remap_bin")
context=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.additionalContext')
for half in 'CI ORCHESTRATION SKILL BODY' 'CUSTOM GUIDE' 'orchestration-everyone:begin' 'orchestration-coordinator:begin'; do
  [[ $context == *"$half"* ]] || fail "interactive Claude lead envelope is missing: $half"
done
pass 'an interactive Orca terminal without pane variables receives lead context'

worker_env="ORCA_TERMINAL_HANDLE=term_ci TMUX_PANE=%9"
out=$(run_hook claude "$worker_env")
[[ $out == *'orchestration-everyone:begin'* ]] \
  || fail 'an Orca-managed worker must receive the everyone payload'
[[ $out == *'orchestration-coordinator:begin'* ]] \
  && fail 'a worker must not receive the coordinator payload'
pass 'an Orca-managed worker receives the everyone payload alone'
# Lead eligibility follows the role, not the harness. Give each non-Claude
# harness a real guide so the envelope can actually be composed — without one
# the lead path ends in a no-op and an assertion here would pass vacuously,
# which is how the superseded Codex-never-leads case survived this gate.
lead_env="ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1 ORCA_CLI_COMMAND=$remap_bin/orca-dev"
out=$(run_hook codex "$lead_env" "$remap_bin")
[[ $out == *'orchestration-coordinator:begin'* ]] \
  || fail 'a Codex lead must receive the coordinator payload'
[[ $out == *'orchestration-everyone:begin'* ]] \
  || fail 'a Codex lead must receive the everyone payload'
pass 'a Codex lead receives the whole envelope, like any other served harness'

out=$(run_hook omp "$lead_env" "$remap_bin")
[[ $out == *'orchestration-coordinator:begin'* && $out == *'orchestration-everyone:begin'* ]] \
  || fail 'omp lead context is incomplete'
out=$(run_hook omp "$interactive_env" "$remap_bin")
[[ $out == *'orchestration-coordinator:begin'* && $out == *'orchestration-everyone:begin'* && $out == *'CI ORCHESTRATION SKILL BODY'* ]] \
  || fail 'omp interactive session must receive lead context'
pass 'an interactive omp session receives the full lead context'

out=$(run_hook omp "$worker_env")
[[ $out == *'orchestration-everyone:begin'* && $out != *'orchestration-coordinator:begin'* ]] \
  || fail 'omp worker context has the wrong role'
pass 'an omp worker receives only worker context'

mkdir -p "$scratch/home/.config/orca"
sqlite3 "$scratch/home/.config/orca/orchestration.db" <<'SQL'
CREATE TABLE worker_dispatches (dispatch_id TEXT PRIMARY KEY, agent_terminal_handle TEXT, state TEXT);
INSERT INTO worker_dispatches VALUES ('d1', 'term_db_worker', 'ready');
SQL
out=$(run_hook omp "ORCA_TERMINAL_HANDLE=term_db_worker")
[[ $out == *'orchestration-everyone:begin'* && $out != *'orchestration-coordinator:begin'* ]] \
  || fail 'omp active dispatch worker must receive only worker context'
pass 'an omp active dispatch worker receives only worker context'
out=$(run_hook omp "")
[[ -z $out ]] || fail 'omp outside Orca must receive no context'

for bad in "--harness nonesuch" "--harness" ""; do
  # shellcheck disable=SC2086
  if ! env -i PATH="$closed_path" HOME="$scratch/home" "$binary" hook $bad </dev/null >/dev/null 2>"$scratch/stderr"; then
    fail "hook must exit 0 on malformed arguments (${bad:-none})"
  fi
  [[ -s "$scratch/stderr" ]] && fail "hook must keep stderr silent on malformed arguments (${bad:-none})"
done
pass 'malformed hook arguments still exit 0 with a silent stderr'

# The drain stops at the event's own newline. Nothing else exercises that: every
# case above closes stdin immediately, so the hook would pass them even if it
# waited for EOF. Here a writer sends one JSON line and then holds the
# descriptor open for far longer than the drain's backstop — which is what Codex
# actually does.
#
# A FIFO, not a pipeline: `$( )` waits for every process in a pipeline, so the
# writer's own sleep would be what the clock measured rather than the hook's.
# The writer is detached here and the hook alone is timed.
fifo="$scratch/stdin.fifo"
mkfifo "$fifo"
{ printf '{"hook_event_name":"SessionStart"}\n'; sleep 30; } >"$fifo" &
writer=$!
started=$(date +%s)
out=$(env -i PATH="$closed_path" HOME="$scratch/home" "$binary" hook --harness codex <"$fifo")
elapsed=$(( $(date +%s) - started ))
kill "$writer" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
rm -f "$fifo"
[[ -z $out ]] || fail 'a Codex session outside Orca must print nothing even when stdin stays open'
(( elapsed <= 12 )) || fail "the hook waited ${elapsed}s on a held-open stdin instead of stopping at the newline"
pass "a held-open stdin is consumed at its newline (${elapsed}s), not waited on for EOF"

# Every other subcommand takes the opposite contract: loud, non-zero, stderr.
if env -i PATH="$closed_path" "$binary" role --nope </dev/null >/dev/null 2>&1; then
  fail 'role must exit non-zero on an unknown option'
fi
pass 'non-hook subcommands fail loudly, so an operator typo is not a silent no-op'

# ------------------------------------------------------------ payload parity
# The binary must print byte-for-byte what chezmoi writes to the managed target,
# or the rules a session receives are not the rules this repository reviewed.
# Each body is rendered fresh here, placed at the env-overridden payload path,
# and diffed against `print-payload` reading that same path.
parity_dir="$scratch/parity-payloads"
mkdir -p "$parity_dir"
for body in everyone coordinator; do
  render "$repo_root" "$scratch" "$chezmoi_bin" linux \
    "$source_root/dot_local/share/orchestration-hook/$body.md.tmpl" "$parity_dir/$body.md"
  env -i DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$parity_dir" \
    "$binary" print-payload --body "$body" </dev/null >"$scratch/$body.binary"
  diff -q "$parity_dir/$body.md" "$scratch/$body.binary" >/dev/null \
    || fail "the binary emits a different $body payload than the managed target holds"
  # A rendered body that still carried a template action would mean the roster
  # never reached it and a session would read `{{ ... }}` as a rule.
  if grep -F '{{' "$parity_dir/$body.md" >/dev/null || grep -F '}}' "$parity_dir/$body.md" >/dev/null; then
    fail "the rendered $body payload contains template action delimiters"
  fi
done

# A managed file that is not there is not an operator's typo to swallow: every
# other subcommand is loud, and this one names the path it could not read.
if env -i DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$scratch/absent-payloads" \
    "$binary" print-payload --body everyone </dev/null >/dev/null 2>"$scratch/print-payload.err"; then
  fail 'print-payload must fail loudly when the managed payload file is absent'
fi
grep -qF "$scratch/absent-payloads/everyone.md" "$scratch/print-payload.err" \
  || fail 'print-payload must name the payload path it could not read'

# The hook path, by contrast, stays fail-open: a session that starts before the
# first apply gets no rules and no error.
out=$(env -i PATH="$closed_path" HOME="$scratch/empty-home" \
  ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%9 \
  "$binary" hook --harness claude </dev/null)
[[ $out == "{}" ]] || fail "a worker with no staged payload file must print exactly {} (got: $out)"
pass 'an unwritten payload file delivers nothing and never fails session start'

render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$source_root/dot_omp/private_agent/private_readonly_AGENTS.md.tmpl" "$scratch/omp.rendered"
if grep -F 'orchestration-everyone:begin' "$scratch/omp.rendered" >/dev/null; then
  fail 'omp instructions must not carry a stale static payload'
fi
pass 'payloads match source and omp receives context dynamically'

# --------------------------------------------------------- declared commands
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$source_root/dot_local/share/dotfiles-claude-plugin/hooks/hooks.json.tmpl" "$scratch/claude-hooks.json"
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$source_root/dot_local/share/dotfiles-codex-plugin/hooks/hooks.json.tmpl" "$scratch/codex-hooks.json"

expected_binary="$scratch/home/.local/libexec/orchestration-hook"
claude_command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$scratch/claude-hooks.json")
[[ $claude_command == "$expected_binary" ]] \
  || fail "Claude Code must declare the staged binary by absolute path (got: $claude_command)"
# Exec form is required, not preferred: Claude Code runs a bare command string
# through `sh -c`, which would put a shell back on the session-start path.
jq -e '.hooks.SessionStart[0].hooks[0].args == ["hook","--harness","claude"]' \
  "$scratch/claude-hooks.json" >/dev/null \
  || fail 'Claude Code must declare exec form, or a shell is spawned at session start'
pass 'Claude Code declares the staged binary in exec form, by absolute path'

codex_command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$scratch/codex-hooks.json")
[[ $codex_command == "$expected_binary hook --harness codex" ]] \
  || fail "Codex must declare the staged binary by absolute path (got: $codex_command)"
# No args key: codex-hook-trust.tmpl normalizes no args member, so one would sit
# outside the hashed identity and silently untrust the hook.
jq -e '.hooks.SessionStart[0].hooks[0] | has("args") | not' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'the Codex declaration must carry no args key while the trust record cannot hash one'
pass 'Codex declares the staged binary without an args key the trust record would miss'


# -------------------------------------------------------- subagent tool guard
TEAM='ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1'
lead_healthy_env="ORCA_TERMINAL_HANDLE=term_ci"

# compact and startup SessionStart events
compact_event='{"hook_event_name":"SessionStart","source":"compact"}'
startup_event='{"hook_event_name":"SessionStart","source":"startup"}'
out_compact=$(run_with_event hook claude "$lead_healthy_env" "$compact_event" "$ok_bin")
out_startup=$(run_with_event hook claude "$lead_healthy_env" "$startup_event" "$ok_bin")
[[ $out_compact == "$out_startup" ]] \
  || fail 'SessionStart compact and startup events must produce byte-identical envelopes'
context=$(jq -er '.hookSpecificOutput.additionalContext' <<<"$out_compact") \
  || fail 'SessionStart compact output missing additionalContext'
[[ $context == *"Before each dispatch, MUST open the \`orchestration\` skill"* ]] \
  || fail 'the lead envelope does not contain the skill re-entry instruction'
pass 'the compact and startup SessionStart envelopes are byte-identical and carry the re-entry instruction'

# subagent tool calls are denied for both roles
claude_agent_event=$(<"$repo_root/packages/orchestration-hook/test/fixtures/pretooluse-claude-agent.json")
claude_task_event='{"hook_event_name":"PreToolUse","tool_name":"Task"}'
codex_spawn_event=$(<"$repo_root/packages/orchestration-hook/test/fixtures/pretooluse-codex-spawn-agent.json")
codex_bare_spawn_event='{"hook_event_name":"PreToolUse","tool_name":"spawn_agent"}'

assert_guard_denies() {
  local label=$1 harness=$2 role_env=$3 event=$4 extra_bin=${5:-}
  local out decision reason
  out=$(run_guard "$harness" "$role_env" "$event" "$extra_bin")
  decision=$(jq -er '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null) \
    || fail "$label guard must return a decision document (got: $out)"
  [[ $decision == "deny" ]] || fail "$label guard must deny (got: $decision)"
  reason=$(jq -er '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)
  [[ $reason == *orchestration* ]] || fail "$label deny reason must contain orchestration (got: $reason)"
}

for role in "healthy lead|$lead_healthy_env|$ok_bin" "worker|$worker_env|"; do
  IFS='|' read -r env_label role_env extra_bin <<<"$role"
  assert_guard_denies "Claude Code $env_label" claude "$role_env" "$claude_agent_event" "$extra_bin"
  assert_guard_denies "Claude Code $env_label" claude "$role_env" "$claude_task_event" "$extra_bin"
  assert_guard_denies "Codex $env_label" codex "$role_env" "$codex_spawn_event" "$extra_bin"
done

out=$(run_guard codex "$lead_healthy_env" "$codex_bare_spawn_event" "$ok_bin")
[[ -z $out ]] || fail "Codex guard must allow bare spawn_agent in lead (got: $out)"
out=$(run_guard codex "$worker_env" "$codex_bare_spawn_event")
[[ -z $out ]] || fail "Codex guard must allow bare spawn_agent in worker (got: $out)"
pass 'subagent tool calls are denied for both roles, and bare spawn_agent is allowed for Codex'

# exceptions and edge cases
out=$(run_guard claude "" "$claude_agent_event")
[[ $out == '{}' ]] || fail "Claude Code outside Orca must allow Agent (got: $out)"
out=$(run_guard claude "" "$claude_task_event")
[[ $out == '{}' ]] || fail "Claude Code outside Orca must allow Task (got: $out)"
out=$(run_guard codex "" "$codex_spawn_event")
[[ -z $out ]] || fail "Codex outside Orca must allow collaborationspawn_agent (got: $out)"

out=$(run_guard claude "$lead_healthy_env HOME=$scratch/empty-home" "$claude_agent_event" "$ok_bin")
[[ $out == '{}' ]] || fail "Claude Code with unwritten payload must allow Agent (got: $out)"

out=$(run_guard claude "$TEAM" "$claude_agent_event" "$ok_bin")
[[ $out == '{}' ]] || fail "Orca agent-teams session must allow Agent (got: $out)"

fail_bin="$scratch/fail-bin"
mkdir -p "$fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fail_bin/orca-ide"
chmod 0755 "$fail_bin/orca-ide"

assert_guard_denies 'Claude Code with failing Orca CLI' claude "$lead_healthy_env" "$claude_agent_event" "$fail_bin"
pass 'outside Orca, unwritten payload, and agent-teams allow; failing CLI still denies'

# fail-open cases (no stdin, malformed stdin, unknown harness, and stale Bash)
out=$(run_guard claude "$lead_healthy_env" "" "$ok_bin")
[[ $out == '{}' ]] || fail "guard --harness claude with no stdin must still print {} (got: $out)"
out=$(run_guard claude "$lead_healthy_env" "not json" "$ok_bin")
[[ $out == '{}' ]] || fail "guard --harness claude with malformed stdin must still print {} (got: $out)"
pass 'guard never blocks on stdin: no input and malformed input both exit 0 immediately'

out=$(run_guard nonesuch "$lead_healthy_env" "$claude_agent_event" "$ok_bin")
[[ -z $out ]] || fail "guard with an unknown --harness must print nothing (got: $out)"
pass 'guard with a missing or unknown --harness prints nothing'

bash_event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"codex exec x"}}'
out=$(run_guard claude "$lead_healthy_env" "$bash_event" "$ok_bin")
[[ $out == '{}' ]] || fail "guard --harness claude must allow a Bash event (got: $out)"
out=$(run_guard codex "$lead_healthy_env" "$bash_event" "$ok_bin")
[[ -z $out ]] || fail "guard --harness codex must allow a Bash event (got: $out)"
pass 'guard allows a stale Bash declaration, in both harnesses'

# declarations and trust record
claude_guard=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$scratch/claude-hooks.json")
[[ $claude_guard == "$expected_binary" ]] \
  || fail "Claude Code must declare the guard by absolute path (got: $claude_guard)"
jq -e '.hooks.PreToolUse[0].hooks[0].args == ["guard","--harness","claude"]' \
  "$scratch/claude-hooks.json" >/dev/null \
  || fail 'Claude Code must declare exec form for the guard'
jq -e '.hooks.PreToolUse[0].matcher == "Agent|Task"' \
  "$scratch/claude-hooks.json" >/dev/null \
  || fail 'Claude Code PreToolUse hook must match Agent|Task'
pass 'Claude Code declares the PreToolUse guard in exec form, matching Agent|Task'

codex_guard=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$scratch/codex-hooks.json")
[[ $codex_guard == "$expected_binary guard --harness codex" ]] \
  || fail "Codex must declare the guard by absolute path (got: $codex_guard)"
jq -e '.hooks.PreToolUse[0] | has("matcher") | not' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'Codex PreToolUse hook must carry no matcher'
jq -e '.hooks.PreToolUse[0].hooks[0] | has("args") | not' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'Codex PreToolUse hook must carry no args key'
jq -e '.hooks.PreToolUse[0].hooks[0].additionalContextLimit == 0' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'Codex PreToolUse hook must declare additionalContextLimit 0'
pass 'Codex declares the PreToolUse guard with no matcher and no args key'

# The trust record is the silent-failure surface: a Codex hook whose recorded
# hash disagrees with the deployed declaration simply never runs. Adding the
# PreToolUse event must not disturb the SessionStart record, whose key is
# positional WITHIN its own event, and the record must now hash both events.
trust_wrapper="$scratch/trust-wrapper.tmpl"
printf '{{ includeTemplate "codex-hook-trust.tmpl" (dict "ctx" .) }}\n' >"$trust_wrapper"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$trust_wrapper" "$scratch/trust.json"
session_keys=$(jq -r '.state | keys[] | select(endswith(":session_start:0:0"))' "$scratch/trust.json")
[[ -n $session_keys ]] || fail 'the SessionStart trust record disappeared'
pretooluse_keys=$(jq -r '.state | keys[] | select(endswith(":pre_tool_use:0:0"))' "$scratch/trust.json")
[[ -n $pretooluse_keys ]] || fail 'the PreToolUse trust record disappeared'
[[ $(jq -r '.state | keys | length' "$scratch/trust.json") == 2 ]] \
  || fail 'the Codex trust record must hash exactly two events'
[[ $(jq -r ".state[\"$session_keys\"].trusted_hash" "$scratch/trust.json") == sha256:* ]] \
  || fail 'the SessionStart trust hash is not a sha256 record'
[[ $(jq -r ".state[\"$pretooluse_keys\"].trusted_hash" "$scratch/trust.json") == sha256:* ]] \
  || fail 'the PreToolUse trust hash is not a sha256 record'
pass 'the Codex trust record hashes both events, SessionStart and PreToolUse'

# --------------------------------------------------- every-apply path assertion
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$source_root/.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl" "$scratch/assert.sh"
mkdir -p "$scratch/home/.local/libexec"
rm -f "$expected_binary"
if bash "$scratch/assert.sh" 2>"$scratch/assert.err"; then
  fail 'a missing staged binary must fail the apply, not converge green'
fi
grep -q "$expected_binary" "$scratch/assert.err" \
  || fail 'the assertion must name the missing path'
install -m 0644 "$binary" "$expected_binary"
if bash "$scratch/assert.sh" >/dev/null 2>&1; then
  fail 'a non-executable staged binary must fail the apply'
fi
chmod 0755 "$expected_binary"
out=$(bash "$scratch/assert.sh" 2>&1) || fail 'the assertion must pass once the binary is staged'
[[ -z $out ]] || fail "the assertion must stay silent on a converged host (got: $out)"
pass 'a missing or non-executable staged binary fails the apply; a converged host is silent'

# ------------------------------------------------------------ retired surfaces
for retired in \
  dot_local/share/dotfiles-claude-plugin/hooks/executable_orca-team-lead-orchestration.sh.tmpl \
  dot_local/share/dotfiles-codex-plugin/hooks/executable_orchestration.sh.tmpl \
  dot_local/share/dotfiles-claude-plugin/payloads \
  dot_local/share/dotfiles-codex-plugin/payloads \
  .chezmoitemplates/orchestration-role-detect.sh.tmpl; do
  [[ -e "$repo_root/$retired" ]] && fail "retired surface still present: $retired"
done
for target in \
  .local/share/dotfiles-claude-plugin/hooks/orca-team-lead-orchestration.sh \
  .local/share/dotfiles-claude-plugin/payloads/everyone.md \
  .local/share/dotfiles-claude-plugin/payloads/coordinator.md \
  .local/share/dotfiles-codex-plugin/hooks/orchestration.sh \
  .local/share/dotfiles-codex-plugin/payloads/everyone.md; do
  grep -Fxq "$target" "$source_root/.chezmoiremove" \
    || fail "retired target is not declared for removal: $target"
done
pass 'the retired hook scripts and payload wrappers are gone and declared for removal'

bundle="$scratch/dotfiles-orca.js"
(
  cd "$repo_root/packages/omp-orca"
  "$BUN_BIN" build ./src/index.ts --target=bun --format=esm --outfile "$bundle" >/dev/null
) || fail 'the extension bundle did not compile'
[[ -s $bundle ]] || fail 'the extension bundle is empty'

extension_hook="$scratch/extension-hook"
extension_env="$scratch/extension-env"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s" "$ORCA_TERMINAL_HANDLE" "$ORCA_AGENT_TEAMS_LEADER_PANE" "$TMUX_PANE" >%q\nexec %q "$@"\n' "$extension_env" "$binary" >"$extension_hook"
chmod 0755 "$extension_hook"
runner="$scratch/extension-runner.mjs"
cat >"$runner" <<'RUNNER'
const { default: load } = await import(process.argv[2]);
const mode = process.argv[3] ?? "before_agent_start";
const toolName = process.argv[4] ?? "task";
let beforeHandler;
let toolHandler;
await load({
  on(event, next) {
    if (event === "before_agent_start") beforeHandler = next;
    else if (event === "tool_call") toolHandler = next;
    else throw new Error(`wrong event: ${event}`);
  },
});
if (mode === "before_agent_start") {
  const result = await beforeHandler({ prompt: "test", systemPrompt: ["BASE"] });
  process.stdout.write(JSON.stringify(result));
} else if (mode === "tool_call") {
  const result = await toolHandler({ toolName });
  process.stdout.write(JSON.stringify(result ?? null));
} else {
  throw new Error(`unknown mode: ${mode}`);
}
RUNNER
result=$(DOTFILES_ORCHESTRATION_HOOK="$extension_hook" \
  DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$payload_dir" \
  ORCA_TERMINAL_HANDLE=term_ext ORCA_AGENT_TEAMS_LEADER_PANE=%7 TMUX_PANE=%9 \
  "$BUN_BIN" "$runner" "$bundle") || fail 'the extension integration runner failed'
jq -e '.systemPrompt | length == 2' <<<"$result" >/dev/null \
  || fail 'the extension did not return the original prompt plus one managed block'
jq -e '.systemPrompt[1] | contains("dotfiles-orca:begin") and contains("orchestration-everyone:begin") and contains("dotfiles-orca:end")' <<<"$result" >/dev/null \
  || fail 'the extension block does not contain hook context'
[[ $(cat "$extension_env") == 'term_ext|%7|%9' ]] \
  || fail 'the extension did not pass the current role environment to the child'
pass 'the built extension calls the real hook binary path contract without credentials'

task_blocked=$(DOTFILES_ORCHESTRATION_HOOK="$extension_hook" \
  DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$payload_dir" \
  ORCA_TERMINAL_HANDLE=term_ci TMUX_PANE=%9 \
  "$BUN_BIN" "$runner" "$bundle" tool_call task) || fail 'the extension runner failed on task tool_call'
jq -e '.block == true and (.reason | contains("orchestration"))' <<<"$task_blocked" >/dev/null \
  || fail "the extension did not block task with orchestration reason in worker (got: $task_blocked)"

bash_allowed=$(DOTFILES_ORCHESTRATION_HOOK="$extension_hook" \
  DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$payload_dir" \
  ORCA_TERMINAL_HANDLE=term_ci TMUX_PANE=%9 \
  "$BUN_BIN" "$runner" "$bundle" tool_call bash) || fail 'the extension runner failed on bash tool_call'
jq -e '. == null' <<<"$bash_allowed" >/dev/null \
  || fail "the extension must not block bash (got: $bash_allowed)"

outside_task_allowed=$(DOTFILES_ORCHESTRATION_HOOK="$extension_hook" \
  DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR="$payload_dir" \
  ORCA_TERMINAL_HANDLE= \
  TMUX_PANE=%9 \
  "$BUN_BIN" "$runner" "$bundle" tool_call task) || fail 'the extension runner failed on outside task tool_call'
jq -e '. == null' <<<"$outside_task_allowed" >/dev/null \
  || fail "the extension must not block task without ORCA_TERMINAL_HANDLE (got: $outside_task_allowed)"
pass 'the built extension blocks task in worker and allows bash and non-managed task'

printf 'orchestration hook: all gates passed\n'
