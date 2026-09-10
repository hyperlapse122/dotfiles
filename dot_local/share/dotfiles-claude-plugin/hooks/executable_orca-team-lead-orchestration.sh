#!/usr/bin/env bash
# SessionStart hook: place the Orca orchestration skill in a team lead's context.
#
# Every failure path prints an empty JSON object and exits 0. A SessionStart hook
# that errors would delay or block session start, so nothing here is allowed to
# fail loudly.
set -u

emit_nothing() {
  printf '{}\n'
  exit 0
}

# A tmux-backed teammate pane inherits CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS but
# NOT TMUX_PANE or ORCA_AGENT_TEAMS_LEADER_PANE. Comparing the two variables
# without checking presence first matches empty against empty, which injects into
# every teammate instead of the lead alone.
[ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" ] || emit_nothing
[ -n "${TMUX_PANE:-}" ] || emit_nothing
[ -n "${ORCA_AGENT_TEAMS_LEADER_PANE:-}" ] || emit_nothing
[ "$TMUX_PANE" = "$ORCA_AGENT_TEAMS_LEADER_PANE" ] || emit_nothing

command -v jq >/dev/null 2>&1 || emit_nothing

SKILL_PATH="${HOME}/.agents/skills/orchestration/SKILL.md"
[ -r "$SKILL_PATH" ] || emit_nothing

# Bare `orca` on Linux resolves to /usr/bin/orca, the GNOME screen reader, which
# would start speech on the user's machine.
if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
  orca_cli="$ORCA_CLI_COMMAND"
elif command -v orca-ide >/dev/null 2>&1; then
  orca_cli="orca-ide"
else
  emit_nothing
fi

guide_file="$(mktemp)" || emit_nothing
trap 'rm -f "$guide_file"' EXIT

# macOS ships no timeout(1) and this plugin's marketplace is declared for darwin,
# so the 5-second bound is a watchdog rather than that binary.
"$orca_cli" skills get orchestration >"$guide_file" 2>/dev/null &
cli_pid=$!
(
  sleep 5
  kill -TERM "$cli_pid" 2>/dev/null
) &
watchdog_pid=$!

wait "$cli_pid"
cli_rc=$?
kill -TERM "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

[ "$cli_rc" -eq 0 ] || emit_nothing
[ -s "$guide_file" ] || emit_nothing

jq -n \
  --rawfile skill "$SKILL_PATH" \
  --rawfile guide "$guide_file" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: (
        "This session is the lead of an Orca-managed Claude Code team. The Orca orchestration skill is loaded below so that any dispatch of a subagent, worker, or peer reviewer follows it rather than a native subagent tool.\n\n"
        + "--- orchestration SKILL.md ---\n\n" + $skill
        + "\n\n--- version-matched Orca orchestration guide ---\n\n" + $guide
      )
    }
  }' 2>/dev/null || emit_nothing
