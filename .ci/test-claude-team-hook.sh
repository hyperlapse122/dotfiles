#!/usr/bin/env bash
# Guards the SessionStart hook this checkout ships to Claude Code
# (dot_local/share/dotfiles-claude-plugin/hooks/executable_orca-team-lead-orchestration.sh).
#
# Two contracts matter and neither is visible in a diff. The hook must inject the
# orchestration skill in the team LEAD's pane only -- a tmux-backed teammate pane
# inherits CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS but not the pane variables, so a
# bare equality test matches empty against empty and injects into every teammate.
# And it must fail open on every path: a SessionStart hook that errors delays or
# blocks session start.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook_src="$repo_root/dot_local/share/dotfiles-claude-plugin/hooks/executable_orca-team-lead-orchestration.sh"
hooks_json="$repo_root/dot_local/share/dotfiles-claude-plugin/hooks/hooks.json"

fail() { printf 'claude team hook: %s\n' "$*" >&2; exit 1; }
pass() { printf 'claude team hook: %s\n' "$*"; }

[[ -f $hook_src ]] || fail "missing hook source $hook_src"
[[ -f $hooks_json ]] || fail "missing $hooks_json"

scratch_root=${XDG_RUNTIME_DIR:-"$HOME/.cache"}/claude-team-hook
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/bin" "$scratch/home/.agents/skills/orchestration"
hook="$scratch/hook.sh"
cp -- "$hook_src" "$hook"
chmod 0700 -- "$hook"

printf 'SKILL BODY MARKER\n' >"$scratch/home/.agents/skills/orchestration/SKILL.md"

# The hook runs under a scratch HOME. A version-manager shim resolves its state
# through the caller's HOME and fails there, so find a real jq binary on PATH and
# link that into the stub PATH instead.
jq_bin=''
IFS=: read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
  [[ -n $entry && $entry != *"/shims"* ]] || continue
  if [[ -x "$entry/jq" ]]; then
    jq_bin="$entry/jq"
    break
  fi
done
[[ -n $jq_bin ]] || fail 'no jq binary outside a version-manager shim directory is on PATH'
ln -sf -- "$jq_bin" "$scratch/bin/jq"

# Orca installs /usr/bin/orca-ide, so a PATH that keeps the system directories
# cannot express "no Orca CLI". Every case runs against this closed base holding
# only what the hook itself needs.
for tool in bash mktemp sleep rm; do
  tool_path=$(command -v "$tool") || fail "the hook needs $tool and it is not on PATH"
  ln -sf -- "$tool_path" "$scratch/bin/$tool"
done

# Every case runs with a stub PATH so no real Orca CLI is reached.
make_stub() {
  local dir=$1 name=$2 body=$3
  mkdir -p -- "$scratch/$dir"
  printf '#!/bin/sh\n%s\n' "$body" >"$scratch/$dir/$name"
  chmod 0700 -- "$scratch/$dir/$name"
}
make_cli() { make_stub "$1" orca-ide "$2"; }
make_cli cli-ok 'printf "GUIDE BODY MARKER\n"'
make_cli cli-fail 'exit 3'
make_cli cli-hang 'sleep 60'

run_hook_in() {
  local home=$1 bindir=$2
  shift 2
  env -i \
    PATH="$scratch/$bindir:$scratch/bin" \
    HOME="$home" \
    "$@" \
    "$scratch/bin/bash" "$hook"
}
run_hook() { run_hook_in "$scratch/home" "$@"; }

lead_env=(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 TMUX_PANE=%1 ORCA_AGENT_TEAMS_LEADER_PANE=%1)

context_of() {
  "$jq_bin" -er '.hookSpecificOutput.additionalContext' 2>/dev/null
}

# --- The lead injects, and carries both texts (AE1) ---
#
# `$(...)` reads stdout to EOF, which is the assertion that matters: a background
# job holding the write end keeps the reader waiting long after the hook exits.
# A content-only check cannot see that, and it is how a five-second stall on the
# one path the feature exists for once passed this gate green.
lead_start=$SECONDS
out=$(run_hook cli-ok "${lead_env[@]}") || fail 'lead-shaped run exited non-zero'
lead_elapsed=$((SECONDS - lead_start))
ctx=$(printf '%s' "$out" | context_of) || fail 'lead-shaped run emitted no additionalContext'
[[ $ctx == *"SKILL BODY MARKER"* ]] || fail 'injected context is missing the SKILL.md body'
[[ $ctx == *"GUIDE BODY MARKER"* ]] || fail 'injected context is missing the Orca guide body'
(( lead_elapsed <= 2 )) ||
  fail "the lead path held stdout for ${lead_elapsed}s; a fast guide read must not wait on the watchdog"
pass 'the lead pane receives both the skill body and the guide, without holding stdout'

# --- The hook leaves no background job behind on the fast path ---
#
# The watchdog's own `sleep` is the one that held stdout. It is signalled through
# its process group, so nothing of the hook survives a fast guide read.
sleep 1
if pgrep -f "$scratch/hook.sh" >/dev/null 2>&1; then
  fail 'the hook left a background job running after it exited'
fi
pass 'the hook leaves no background job behind'

# --- Every non-lead shape stays silent ---
assert_silent_in() {
  local label=$1 home=$2 bindir=$3
  shift 3
  local result
  result=$(run_hook_in "$home" "$bindir" "$@") || fail "$label exited non-zero"
  [[ $result == '{}' ]] || fail "$label emitted $result instead of {}"
}
assert_silent() {
  local label=$1
  shift
  assert_silent_in "$label" "$scratch/home" "$@"
}

# A teammate pane: the team flag is inherited, the pane variables are not. This
# is the case a bare equality test gets wrong.
assert_silent 'a teammate pane' cli-ok CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
assert_silent 'a pane whose id differs from the leader' cli-ok \
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 TMUX_PANE=%2 ORCA_AGENT_TEAMS_LEADER_PANE=%1
# Only the presence guard rejects this one; the equality test would accept it if
# the leader variable were also allowed to be empty.
assert_silent 'a pane with no leader variable' cli-ok \
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 TMUX_PANE=%1
assert_silent 'a session outside team mode' cli-ok TMUX_PANE=%1 ORCA_AGENT_TEAMS_LEADER_PANE=%1
pass 'teammate, mismatched, leaderless and non-team sessions inject nothing'

# --- Compaction re-injects (AE3) ---
"$jq_bin" -er '.hooks.SessionStart[0].matcher' <"$hooks_json" >"$scratch/matcher" ||
  fail 'hooks.json declares no SessionStart matcher'
matcher=$(<"$scratch/matcher")
for source in startup resume clear compact; do
  [[ $matcher == *"$source"* ]] || fail "hooks.json matcher does not register the $source source: $matcher"
done
out=$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | run_hook cli-ok "${lead_env[@]}") ||
  fail 'compact-source run exited non-zero'
ctx=$(printf '%s' "$out" | context_of) || fail 'compact-source run emitted no additionalContext'
[[ $ctx == *"GUIDE BODY MARKER"* ]] || fail 'compact-source run injected no guide body'
pass 'the compact source is registered and re-injects'

# --- The guide is read at fire time, not snapshotted (AE6) ---
make_cli cli-v2 'printf "GUIDE REVISION TWO\n"'
first=$(run_hook cli-ok "${lead_env[@]}" | context_of) || fail 'first fire-time run failed'
second=$(run_hook cli-v2 "${lead_env[@]}" | context_of) || fail 'second fire-time run failed'
[[ $first == *"GUIDE BODY MARKER"* && $first != *"GUIDE REVISION TWO"* ]] ||
  fail 'the first run did not carry the first guide output alone'
[[ $second == *"GUIDE REVISION TWO"* && $second != *"GUIDE BODY MARKER"* ]] ||
  fail 'the second run did not pick up the changed guide output'
pass 'each run injects the guide the CLI serves at that moment'

# --- Fail open (AE4) ---
assert_silent 'a lead pane with no Orca CLI' bin "${lead_env[@]}"
assert_silent 'a lead pane whose Orca CLI fails' cli-fail "${lead_env[@]}"

err=$(run_hook bin "${lead_env[@]}" 2>&1 >/dev/null) || fail 'the no-CLI run exited non-zero'
[[ -z $err ]] || fail "the no-CLI run wrote to stderr: $err"

mkdir -p "$scratch/home-no-skill"
assert_silent_in 'a lead pane with no skill body' "$scratch/home-no-skill" cli-ok "${lead_env[@]}"
pass 'a missing CLI, a failing CLI and a missing skill body all fail open in silence'

# --- The 5-second bound holds, and does not come from timeout(1) ---
# The stub forks a descendant and waits on it, so the bound is reached only by
# signalling the whole group, and the descendant must not outlive the hook.
descendant_marker="ce-team-hook-descendant-$$"
cp -- "$(command -v sleep)" "$scratch/bin/$descendant_marker"
make_stub cli-hang orca-ide "\"$scratch/bin/$descendant_marker\" 300 & wait"
start=$SECONDS
assert_silent 'a lead pane whose Orca CLI hangs' cli-hang "${lead_env[@]}"
elapsed=$((SECONDS - start))
sleep 1
if pgrep -f "$descendant_marker" >/dev/null 2>&1; then
  pkill -f "$descendant_marker" 2>/dev/null
  fail 'a CLI descendant outlived the bound'
fi
(( elapsed >= 3 )) || fail "the hanging run returned in ${elapsed}s, so the bound was not exercised"
# Tight enough to fail a bound that drifts: a 15s ceiling would pass a hook that
# waits ten seconds, which is the guarantee this case exists to hold.
(( elapsed <= 8 )) || fail "the hanging run took ${elapsed}s, past the declared 5s bound"

# macOS ships no timeout(1) and this plugin is declared for darwin. Shadowing it
# with a failing stub proves the bound never calls it.
make_cli cli-ok-notimeout 'printf "GUIDE BODY MARKER\n"'
make_stub cli-ok-notimeout timeout 'exit 127'
ctx=$(run_hook cli-ok-notimeout "${lead_env[@]}" | context_of) ||
  fail 'the run with timeout(1) shadowed emitted no additionalContext'
[[ $ctx == *"GUIDE BODY MARKER"* ]] || fail 'shadowing timeout(1) broke the guide read'
pass 'the 5s bound holds and does not depend on timeout(1)'

# --- A bare `orca` override never reaches the GNOME screen reader ---
#
# On Linux `orca` resolves to /usr/bin/orca, the screen reader, which would start
# speech in the user's session. The stubs are distinguishable so the assertion
# names which binary actually ran.
make_stub cli-both orca-ide 'printf "SAFE CLI MARKER\n"'
make_stub cli-both orca 'printf "SCREEN READER MARKER\n"'
for unsafe in orca /usr/bin/orca; do
  ctx=$(run_hook cli-both "${lead_env[@]}" ORCA_CLI_COMMAND="$unsafe" | context_of) ||
    fail "ORCA_CLI_COMMAND=$unsafe produced no additionalContext"
  [[ $ctx != *"SCREEN READER MARKER"* ]] ||
    fail "ORCA_CLI_COMMAND=$unsafe launched the GNOME screen reader"
  [[ $ctx == *"SAFE CLI MARKER"* ]] ||
    fail "ORCA_CLI_COMMAND=$unsafe did not fall back to orca-ide"
done
make_stub cli-custom orca-ide 'printf "SAFE CLI MARKER\n"'
make_stub cli-custom my-orca 'printf "CUSTOM CLI MARKER\n"'
ctx=$(run_hook cli-custom "${lead_env[@]}" ORCA_CLI_COMMAND=my-orca | context_of) ||
  fail 'a custom ORCA_CLI_COMMAND produced no additionalContext'
[[ $ctx == *"CUSTOM CLI MARKER"* ]] ||
  fail 'a custom ORCA_CLI_COMMAND was not honoured'
pass 'a bare orca override is remapped, and a real custom override still runs'

# --- The declared hook command is the script that was tested ---
#
# Every case above runs a copy of the source directly. That leaves the wiring
# untested: a typo in the hooks.json command path, or a matcher that merely
# contains the right words, ships silently while this gate stays green.
[[ $("$jq_bin" -r '.hooks.SessionStart | length' <"$hooks_json") -eq 1 ]] ||
  fail 'hooks.json declares more than one SessionStart matcher group'
[[ $matcher == 'startup|resume|clear|compact' ]] ||
  fail "hooks.json matcher is '$matcher', not the exact declared expression"
declared_command=$("$jq_bin" -r '.hooks.SessionStart[0].hooks[0].command' <"$hooks_json")
[[ $("$jq_bin" -r '.hooks.SessionStart[0].hooks[0].type' <"$hooks_json") == command ]] ||
  fail 'the declared SessionStart hook is not a command hook'

plugin_root="$scratch/plugin-root"
mkdir -p "$plugin_root/hooks"
cp -- "$hook_src" "$plugin_root/hooks/orca-team-lead-orchestration.sh"
chmod 0700 -- "$plugin_root/hooks/orca-team-lead-orchestration.sh"
resolved_command=${declared_command//\$\{CLAUDE_PLUGIN_ROOT\}/$plugin_root}
resolved_command=${resolved_command//\"/}
[[ -x $resolved_command ]] ||
  fail "hooks.json points at $declared_command, which is not an executable file under the plugin root"
ctx=$(env -i PATH="$scratch/cli-ok:$scratch/bin" HOME="$scratch/home" \
  CLAUDE_PLUGIN_ROOT="$plugin_root" "${lead_env[@]}" \
  "$scratch/bin/bash" "$resolved_command" | context_of) ||
  fail 'invoking the exact declared hook command produced no additionalContext'
[[ $ctx == *"GUIDE BODY MARKER"* ]] ||
  fail 'the declared hook command did not inject the guide'
pass 'the command hooks.json declares resolves under the plugin root and injects'
