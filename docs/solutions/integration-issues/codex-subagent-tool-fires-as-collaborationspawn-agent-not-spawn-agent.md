---
title: Codex's Subagent Tool Fires as collaborationspawn_agent, Not the spawn_agent String Its Binary Contains
date: 2026-09-18
category: integration-issues
module: agents
problem_type: integration_issue
component: development_workflow
symptoms:
  - "a guard keyed on the binary string spawn_agent would never match Codex's real PreToolUse event"
  - "Codex 0.155.0 reports the multi-agent spawn tool as tool_name collaborationspawn_agent: the collaboration tool namespace concatenated directly onto spawn_agent with no separator"
  - "the mismatch was invisible to source review of the guard code and to a hand-written fixture built from the same assumption; only a captured live event exposed it"
root_cause: incorrect_assumption
resolution_type: workflow_improvement
severity: high
related_components:
  - tooling
tags:
  - orca
  - orchestration-hook
  - subagent-guard
  - codex
  - tool-name
  - headless-capture
  - pretooluse-hook
---

# Codex's Subagent Tool Fires as collaborationspawn_agent, Not the spawn_agent String Its Binary Contains

## Problem

`packages/orchestration-hook/src/guard.ts` denies each harness's own subagent
tool during an Orca-managed session, keyed on an exact-match `tool_name`
list per harness (`packages/orchestration-hook/src/guard.ts:28-36`). The
plan drafted that list from tool names found by reading each harness's
binary; for Codex, the binary's strings contain `spawn_agent`. Codex
0.155.0's real `PreToolUse` event instead carries
`tool_name: "collaborationspawn_agent"`
(`packages/orchestration-hook/test/fixtures/pretooluse-codex-spawn-agent.json:12`)
— the `collaboration` tool namespace concatenated directly onto
`spawn_agent` with no separator. A guard keyed on the bare string would
have matched no real Codex event and denied nothing, while looking
complete: it would compile, a hand-written fixture built from the same
assumption would pass against it, and nothing in a render or a code review
would show the gap.

## Symptoms

- A guard keyed on the binary string `spawn_agent` would never match Codex's
  real `PreToolUse` event.
- Codex 0.155.0 reports the multi-agent spawn tool as `tool_name`
  `collaborationspawn_agent`, not `spawn_agent`.
- The mismatch was invisible to source review of the guard code and to a
  hand-written fixture built from the same assumption; only a captured live
  event exposed it.

## What Didn't Work

- **Reading `spawn_agent` out of the Codex binary and trusting it as the
  `tool_name` a `PreToolUse` event carries.** A binary's static strings show
  what an internal symbol is called; they do not show how the harness
  composes the wire-level field a hook actually receives.
- **A hand-written fixture built from that same assumption**, e.g.
  `{tool_name: "spawn_agent"}`. It would have passed against the guard's own
  code, because both were written from one mental model — the same failure
  mode as the self-written GnuPG stubs in
  `docs/solutions/test-failures/self-written-stubs-certify-gnupg-formats-that-never-occur.md`:
  a fixture and the code under test agreeing proves only internal
  consistency, not correctness against the real producer.
- **`codex exec --enable multi_agent_v2`**, tried once to see whether Codex
  exposes a second spawn tool under that flag. The run timed out; the flag
  was dropped rather than debugged, and the default `--enable multi_agent`
  surface was enough to capture the real event.

## Solution

The real event was captured headlessly, per harness, without touching any
live config file and without a human answering a prompt:

- **Strip the Orca injection first.** `env -u ORCA_TERMINAL_HANDLE -u ORCA_AGENT_TEAMS_LEADER_PANE -u TMUX_PANE`
  before launching the capture session. Leaving these set means the capture
  session receives the orchestration injection itself, and the model then
  refuses to call its own subagent tool — the exact thing being captured.
- **Claude Code:** `claude -p "<prompt that calls the subagent tool once>" --settings <scratch settings with a PreToolUse matcher "*" logger hook> --dangerously-skip-permissions --add-dir <scratch cwd>`, run from a scratch cwd. Result: `tool_name` `Agent`.
- **Codex:** `codex exec --enable multi_agent --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c 'hooks={PreToolUse=[{hooks=[{type="command",command="<scratch logger>",timeout=10,additionalContextLimit=0}]}]}' "<prompt that calls spawn_agent once>"`. No edit to `~/.codex/config.toml` and no scratch `CODEX_HOME` — a scratch `CODEX_HOME` would need its own credentials, which the capture does not need. Result: `tool_name` `collaborationspawn_agent`.
- **omp:** `omp -p "<prompt that calls task once>" -e <scratch extension that logs the tool_call event> --auto-approve --no-session --cwd <scratch cwd>`. Result: `toolName` `task`
  (`packages/omp-orca/src/index.ts:280-282`), matching the assumption.
- Captured events were stored unedited except for redacting host paths,
  session ids, tool-use ids, and opaque encrypted blobs; synthetic events
  are reserved for parser edge cases, never for the primary name assertion.
  Two of the three now have a committed fixture the guard's tests assert
  against verbatim:
  `packages/orchestration-hook/test/fixtures/pretooluse-claude-agent.json`
  and `pretooluse-codex-spawn-agent.json`
  (`packages/orchestration-hook/test/guard.test.ts:133-141`). omp's `task`
  value has no committed fixture in that unit's scope and stays synthetic
  (`packages/orchestration-hook/test/guard.test.ts:131-132, 142`).

With the real name in hand, two changes landed together, not one:

1. `SUBAGENT_TOOLS.codex` was corrected to `["collaborationspawn_agent"]`
   (`packages/orchestration-hook/src/guard.ts:28-36`).
2. The Codex `PreToolUse` hook declaration was written with **no matcher**
   (`home/.chezmoitemplates/codex-hook-declaration.tmpl:29-30`), so the
   binary decides whether to fire the hook by dispatching every tool call to
   it, and `guard.ts`'s own exact-string check is the sole place that
   decides whether a given call is the subagent tool.

## Why This Works

A binary's static strings are a symbol table, not a wire contract. Codex
assembles `tool_name` at call time by concatenating a tool's namespace onto
its base name; no single string in the binary spells out the concatenated
result, so reading the binary cannot substitute for observing an actual
event. A hand-written fixture cannot substitute either, because it is
written from the same mental model as the code it is meant to check — it
can only certify self-consistency.

The matcherless hook declaration is a separate, narrower guarantee: it
keeps a wrong or stale *matcher* from silently stopping the hook from
firing at all. It does not protect against a wrong entry in
`SUBAGENT_TOOLS` itself — `decide()` allows any `tool_name` it does not
recognize (`packages/orchestration-hook/src/guard.ts:81-88`), so a future
Codex rename would once again deny nothing, silently, until re-captured.
The one thing that keeps `SUBAGENT_TOOLS` correct is re-running this
capture, not re-reading a binary.

## Prevention

- Before keying a guard, allowlist, or parser on a harness's own tool-call
  identifier, capture one real event from that harness headlessly and
  assert against it verbatim. Do not trust a name found in binary strings,
  vendor docs, or a hand-written fixture — none of them prove what the
  harness actually emits.
- Remove the Orca injection env vars (`ORCA_TERMINAL_HANDLE`,
  `ORCA_AGENT_TEAMS_LEADER_PANE`, `TMUX_PANE`) before any capture session
  that itself needs to call the tool under observation; otherwise the
  capture session is denied the very call it exists to observe.
- Prefer a capture path that needs no live config edit and no scratch
  credential store: a scratch `--settings`/`-c hooks=...`/`-e` argument
  beats editing `~/.codex/config.toml`, and a fresh `CODEX_HOME` is worth
  avoiding because it would need its own credentials the capture does not
  otherwise need.
- When a hook framework supports a matcher, leave it off for a guard whose
  safety property depends on an exact-match list elsewhere in the code. A
  present-but-wrong matcher fails closed at the config layer with no
  runtime signal; an absent matcher pushes the exact-match decision into
  code that at least has a test suite watching it.
- Give a cross-model or source-reading review lens the captured raw event,
  not just the guard code that consumes it — the same rule the GnuPG stub
  learning draws from a different domain.
- omp's `task` entry in `SUBAGENT_TOOLS` still rests on a synthetic test
  case, not a committed fixture (`packages/orchestration-hook/test/guard.test.ts:131-132`).
  A capture pass that adds a redacted `pretooluse-omp-task.json` fixture
  alongside the Claude and Codex ones would close that gap the same way.

## Related Issues

- `docs/solutions/test-failures/self-written-stubs-certify-gnupg-formats-that-never-occur.md` —
  the same meta-lesson from an unrelated domain: a fixture or assumption
  written from one mental model proves nothing about the real producer;
  only a captured or quoted artifact from the actual source does.
