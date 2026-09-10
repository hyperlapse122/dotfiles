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

# `orca` is Orca's own CLI on macOS, but on Linux it resolves through PATH to
# /usr/bin/orca, the GNOME screen reader, and running it would start speech in
# the user's session. Only a confirmed Darwin honours the bare name: if uname is
# missing or unreadable the value is remapped, because starting a screen reader
# is the worse of the two failures.
orca_cli="${ORCA_CLI_COMMAND:-}"
case "$orca_cli" in
  orca | /usr/bin/orca)
    [ "$(uname -s 2>/dev/null)" = Darwin ] || orca_cli="orca-ide"
    ;;
esac
if [ -z "$orca_cli" ]; then
  command -v orca-ide >/dev/null 2>&1 || emit_nothing
  orca_cli="orca-ide"
fi

# BSD mktemp requires a template, so a bare `mktemp` fails on macOS -- which this
# plugin's marketplace declares -- and prints usage to stderr.
guide_file="$(mktemp "${TMPDIR:-/tmp}/orca-orchestration.XXXXXX" 2>/dev/null)" || emit_nothing
trap 'rm -f "$guide_file"' EXIT

# macOS ships no timeout(1) and this plugin's marketplace is declared for darwin,
# so the 5-second bound is a watchdog rather than that binary.
#
# Job control puts each background job in its own process group so a signal
# reaches the whole tree. Signalling a single PID leaves the children alive: the
# CLI is a launcher whose worker holds the pipe, and the watchdog's own `sleep`
# holds this hook's stdout, which stalls a reader that waits for EOF for the full
# five seconds after the hook has already exited.
set -m
"$orca_cli" skills get orchestration >"$guide_file" 2>/dev/null </dev/null &
cli_pid=$!
(
  sleep 5
  kill -TERM -- "-$cli_pid" 2>/dev/null || kill -TERM "$cli_pid" 2>/dev/null
) >/dev/null 2>&1 </dev/null &
watchdog_pid=$!
set +m

wait "$cli_pid"
cli_rc=$?
kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill -TERM "$watchdog_pid" 2>/dev/null
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
        "This session is the lead of an Orca-managed Claude Code team. The Orca orchestration skill is loaded below so that any dispatch of a subagent, worker, or peer reviewer follows it rather than a native subagent tool.\n\nBoth texts below were read at session start from this host'"'"'s installed Orca CLI. The guide is the current output of `skills get orchestration`, so do not re-fetch it.\n\n"
        + "--- orchestration SKILL.md ---\n\n" + $skill
        + "\n\n--- version-matched Orca orchestration guide ---\n\n" + $guide
      )
    }
  }' 2>/dev/null || emit_nothing
