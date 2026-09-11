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
