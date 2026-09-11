#!/usr/bin/env bash
set -euo pipefail

# Guards the SessionStart orchestration hook this checkout ships to Claude Code
# and Codex, now one compiled binary rather than two bash scripts.
#
# This gate replaces .ci/test-claude-team-hook.sh and
# .ci/test-codex-orchestration-hook.sh. It covers both harnesses in one script
# because the binary is ~81 MB and building it twice would blow the job's
# ~90-second budget; the contracts each old gate held are all asserted below.
#
# It is also a NEW gate shape for this repository: every other build gate
# fabricates a fake dist artifact and asserts staging behavior only. Nothing
# else here compiles and executes a real binary. That is deliberate — the
# contracts that matter are not visible in a diff and not reachable from the
# package's own unit tests:
#
#   - The hook must fail open on every path. A SessionStart hook that errors
#     delays or blocks session start, and the binary's own code never runs when
#     the binary itself is the thing that is missing or wrong.
#   - The payload text an agent receives must be the text in the source body.
#     Package tests compare a module against a module; only the built artifact
#     proves what a deployed host would actually emit.
#   - The declared command must name the path staging actually produces, in the
#     form each harness needs.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'orchestration hook: %s\n' "$*" >&2; exit 1; }
pass() { printf 'orchestration hook: %s\n' "$*"; }

chezmoi_bin=$(type -P chezmoi) || fail 'no chezmoi binary found on PATH'
# shellcheck source=.ci/lib/render-scratch.sh
source "$repo_root/.ci/lib/render-scratch.sh"
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"
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


run_guard() {
  local harness=$1 role_env=$2 command=$3
  local event
  event=$(jq -nc --arg c "$command" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  # shellcheck disable=SC2086
  printf '%s' "$event" \
    | env -i PATH="$closed_path" HOME="$scratch/home" $role_env "$binary" guard --harness "$harness"
}

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

out=$(run_hook claude "ORCA_TERMINAL_HANDLE=term_ci")
[[ $out == *'orchestration-everyone:begin'* ]] \
  || fail 'an Orca-managed worker must receive the everyone payload'
[[ $out == *'orchestration-coordinator:begin'* ]] \
  && fail 'a worker must not receive the coordinator payload'
pass 'an Orca-managed worker receives the everyone payload alone'

out=$(run_hook codex "ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1")
[[ $out == *'orchestration-coordinator:begin'* ]] \
  && fail 'Codex must never receive the coordinator payload, whatever its role'
pass 'Codex receives the everyone payload even when it resolves as lead'

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
everyone_wrapper="$scratch/everyone.tmpl"
coordinator_wrapper="$scratch/coordinator.tmpl"
printf '%s\n' '{{- includeTemplate "orchestration-everyone.tmpl" (dict "ctx" . "harness" "claude") -}}' >"$everyone_wrapper"
printf '%s\n' '{{- includeTemplate "orchestration-coordinator.tmpl" (dict "ctx" . "harness" "claude") -}}' >"$coordinator_wrapper"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$everyone_wrapper" "$scratch/everyone.rendered"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$coordinator_wrapper" "$scratch/coordinator.rendered"

env -i "$binary" print-payload --body everyone </dev/null >"$scratch/everyone.binary"
env -i "$binary" print-payload --body coordinator </dev/null >"$scratch/coordinator.binary"
diff -q "$scratch/everyone.rendered" "$scratch/everyone.binary" >/dev/null \
  || fail 'the binary emits a different everyone payload than the source body renders'
diff -q "$scratch/coordinator.rendered" "$scratch/coordinator.binary" >/dev/null \
  || fail 'the binary emits a different coordinator payload than the source body renders'

# The third reader: omp has no session-start injection point, so its payload
# rides in a rendered instruction file instead of this binary. All three must
# agree or one harness silently holds rules the others do not.
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$repo_root/dot_omp/private_agent/private_readonly_AGENTS.md.tmpl" "$scratch/omp.rendered"
awk '/<!-- omp-orchestration-payload:begin -->/{flag=1; next} /<!-- omp-orchestration-payload:end -->/{flag=0} flag' \
  "$scratch/omp.rendered" >"$scratch/omp.block"
grep -q 'orchestration-everyone:begin' "$scratch/omp.block" \
  || fail "omp's instruction file carries no everyone payload block"
grep -Fxq "$(head -1 "$scratch/everyone.binary")" "$scratch/omp.block" \
  || fail "omp's payload block and the binary's everyone payload disagree"
pass 'the everyone payload is identical across its three readers'

# --------------------------------------------------------- declared commands
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$repo_root/dot_local/share/dotfiles-claude-plugin/hooks/hooks.json.tmpl" "$scratch/claude-hooks.json"
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$repo_root/dot_local/share/dotfiles-codex-plugin/hooks/hooks.json.tmpl" "$scratch/codex-hooks.json"

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


# ------------------------------------------------------------- the launch gate
# The gate's whole value is that it denies in a real session and stays out of
# the way otherwise. Both halves are invisible in a diff: a wrong tool-name
# assumption, or a fail-open path that swallowed the decision, leaves the unit
# tests green while the deployed hook denies nothing at all.
TEAM='ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%1'
WORKER_ENV='ORCA_TERMINAL_HANDLE=term_ci ORCA_AGENT_TEAMS_LEADER_PANE=%1 TMUX_PANE=%9'

for harness in claude codex; do
  out=$(run_guard "$harness" "$TEAM" 'codex exec "do the thing"')
  decision=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecision') \
    || fail "$harness: a launch in a team session must return a decision document (got: $out)"
  [[ $decision == deny ]] || fail "$harness: a launch must be denied (got: $decision)"
  event_name=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.hookEventName')
  [[ $event_name == PreToolUse ]] || fail "$harness: the deny must name PreToolUse (got: $event_name)"
  reason=$(printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecisionReason')
  [[ $reason == *Orca* ]] || fail "$harness: the deny must name the Orca dispatch path"
done
pass 'a shell launch of an agent CLI is denied in a team session, on both harnesses'

out=$(run_guard claude "$WORKER_ENV" 'codex exec x')
[[ $(printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecision') == deny ]] \
  || fail 'a worker starting its own peer is the same bypass and must be denied'
pass 'the gate binds every Orca role, not the lead alone'

# Outside Orca the same command must run untouched. This is the case that keeps
# the gate from becoming a machine-wide block on the user's own shell.
for harness in claude codex; do
  out=$(run_guard "$harness" "" 'codex exec x')
  [[ $out == '{}' ]] || fail "$harness: outside Orca the gate must allow (got: $out)"
done
pass 'a session outside Orca runs the same command unchanged'

# Allowed surface. `codex plugin add` runs during chezmoi apply, so a gate that
# blocked it would break provisioning on this very repository.
while IFS= read -r command; do
  out=$(run_guard claude "$TEAM" "$command")
  [[ $out == '{}' ]] || fail "the gate must allow: $command (got: $out)"
done <<'ALLOWED'
git status
echo "ask claude about it"
codex plugin add foo
codex mcp list
claude update
claude --version
command -v codex
ALLOWED
pass 'CLI management and unrelated commands are untouched'

# Evasion. Each of these reached the real binary in a shell string; a scanner
# that split naively, or that only looked at the first word, would miss them.
while IFS= read -r command; do
  out=$(run_guard claude "$TEAM" "$command")
  [[ $(printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecision' 2>/dev/null) == deny ]] \
    || fail "the gate must deny: $command (got: $out)"
done <<'DENIED'
codex
bash -c 'codex exec x'
sh -c "bash -c 'codex exec x'"
git status && omp
FOO=bar env claude -p hi
timeout 5 codex exec
/usr/bin/codex exec
DENIED
pass 'wrapped, chained and assigned-prefix launches are all denied'

# Fail open. A guard that errored would break every tool call in the session,
# which is strictly worse than a launch it failed to catch.
# shellcheck disable=SC2086
out=$(printf 'not json' | env -i PATH="$closed_path" HOME="$scratch/home" $TEAM "$binary" guard --harness claude)
[[ $out == '{}' ]] || fail "a body that is not JSON must allow (got: $out)"
# shellcheck disable=SC2086
out=$(printf '' | env -i PATH="$closed_path" HOME="$scratch/home" $TEAM "$binary" guard --harness claude)
[[ $out == '{}' ]] || fail "an empty body must allow (got: $out)"
# shellcheck disable=SC2086
out=$(printf '%s' '{"tool_input":{"command":"codex exec x"}}' \
  | env -i PATH="$closed_path" HOME="$scratch/home" $TEAM "$binary" guard)
[[ $out == '{}' ]] || fail "a missing --harness must allow (got: $out)"
pass 'every malformed guard input allows rather than failing the tool call'

# A pretty-printed body is the shape that breaks a newline-terminated read: it
# would truncate to invalid JSON, parse as nothing, and silently allow.
pretty=$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"codex exec x"}}')
[[ $pretty == *$'\n'* ]] || fail 'the pretty-printed fixture must actually contain newlines'
# shellcheck disable=SC2086
out=$(printf '%s' "$pretty" | env -i PATH="$closed_path" HOME="$scratch/home" $TEAM "$binary" guard --harness claude)
[[ $(printf '%s' "$out" | jq -er '.hookSpecificOutput.permissionDecision' 2>/dev/null) == deny ]] \
  || fail 'a multi-line event body must still be read whole and denied'
pass 'a pretty-printed event body is read to completion, not truncated at a newline'


# The PreToolUse declarations. A gate that is not declared never runs, and the
# unit tests cannot see that.
claude_guard=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$scratch/claude-hooks.json")
[[ $claude_guard == "$expected_binary" ]] \
  || fail "Claude Code must declare the guard by absolute path (got: $claude_guard)"
jq -e '.hooks.PreToolUse[0].hooks[0].args == ["guard","--harness","claude"]' \
  "$scratch/claude-hooks.json" >/dev/null \
  || fail 'the Claude guard must be declared in exec form'
# Bash is the tool name the captured fixture carries, and Claude Code's only
# shell tool; a matcher that missed it would make the gate inert.
jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$scratch/claude-hooks.json" >/dev/null \
  || fail 'the Claude guard must match the Bash tool'
pass 'Claude Code declares the launch gate in exec form, matching its shell tool'

codex_guard=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$scratch/codex-hooks.json")
[[ $codex_guard == "$expected_binary guard --harness codex" ]] \
  || fail "Codex must declare the guard by absolute path (got: $codex_guard)"
jq -e '.hooks.PreToolUse[0].hooks[0] | has("args") | not' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'the Codex guard must carry no args key the trust record cannot hash'
# No matcher, deliberately: Codex renames its shell handler between versions, so
# a matcher written against today's name would silently stop matching and the
# gate would go inert with every gate here still green.
jq -e '.hooks.PreToolUse[0] | has("matcher") | not' "$scratch/codex-hooks.json" >/dev/null \
  || fail 'the Codex guard must carry no matcher while the shell tool name is unpinned'
pass 'Codex declares the launch gate without an args key or an unpinnable matcher'

# The trust record is the silent-failure surface: a Codex hook whose recorded
# hash disagrees with the deployed declaration simply never runs. Adding an
# event must not disturb the SessionStart record, whose key is positional
# WITHIN its own event.
trust_wrapper="$scratch/trust-wrapper.tmpl"
printf '{{ includeTemplate "codex-hook-trust.tmpl" (dict "ctx" .) }}\n' >"$trust_wrapper"
render "$repo_root" "$scratch" "$chezmoi_bin" linux "$trust_wrapper" "$scratch/trust.json"
session_keys=$(jq -r '.state | keys[] | select(endswith(":session_start:0:0"))' "$scratch/trust.json")
[[ -n $session_keys ]] || fail 'the SessionStart trust record disappeared'
pretool_keys=$(jq -r '.state | keys[] | select(endswith(":pre_tool_use:0:0"))' "$scratch/trust.json")
[[ -n $pretool_keys ]] || fail 'the PreToolUse hook has no trust record, so Codex would never run it'
[[ $(jq -r ".state[\"$session_keys\"].trusted_hash" "$scratch/trust.json") == sha256:* ]] \
  || fail 'the SessionStart trust hash is not a sha256 record'
pass 'both Codex hooks carry their own trust record, keyed per event'

# --------------------------------------------------- every-apply path assertion
render "$repo_root" "$scratch" "$chezmoi_bin" linux \
  "$repo_root/.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl" "$scratch/assert.sh"
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
  grep -Fxq "$target" "$repo_root/.chezmoiremove" \
    || fail "retired target is not declared for removal: $target"
done
pass 'the retired hook scripts and payload wrappers are gone and declared for removal'

printf 'orchestration hook: all gates passed\n'
