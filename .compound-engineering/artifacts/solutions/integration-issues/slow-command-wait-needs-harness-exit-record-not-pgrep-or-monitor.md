---
title: A delegated agent's in-turn wait for a slow command needs the harness's exit record, not pgrep or Monitor
date: "2026-10-22"
last_updated: "2026-10-24"
category: integration-issues
module: Shared agent instructions (Subagents section)
problem_type: integration_issue
component: tooling
symptoms:
  - "A delegated Claude Code task runs a test suite without a timeout, the Bash tool moves it to the background at 120000 ms, and the task stops it with TaskStop and runs it again, so the suite runs twice"
  - "A wait loop built on pgrep -f keeps printing running after the command it waits on has finished"
  - "A pgrep -f wait loop stays blocked until its timeout while another task on the host runs the same test command"
  - "A command an Antigravity agent starts with a shell & inside run_command leaves no output file and no process a few seconds later"
  - "A child told that a suite usually finishes in under a minute still passes a 600000 ms timeout, so a live test of the harness-backgrounded path never reaches it"
root_cause: wrong_api
resolution_type: documentation_update
severity: medium
retire_when: "Claude Code or Antigravity gives its shell tool a blocking wait on a background task that holds the turn, or T3 Code keeps a delegated task open while a command it started still runs; check each harness's shell tool description in a live session"
tags: ["slow-command", "background-command", "foreground-timeout", "in-turn-wait", "pgrep", "monitor", "taskstop", "run-in-background", "run-command", "wait-ms-before-async", "command-status", "claude-code", "antigravity", "t3code", "agent-instructions", "live-run"]
---

# A delegated agent's in-turn wait for a slow command needs the harness's exit record, not pgrep or Monitor

> Historical record: the `# T3 Code`, `# Compound Engineering`, and `# Subagents` sections described here, along with their associated instruction tests, were removed on 2026-10-24. Incidents and former guard behavior below are retained as history; they do not describe current shared instructions or tests.

## Problem

In T3 Code the last message of a delegated task's turn is its result, so a task must wait inside its turn for every command its report depends on. A command that outlasts the shell tool's foreground timeout leaves the task two bad moves: end the turn on it ([#301](https://github.com/hyperlapse122/nix-config/issues/301)) or stop it and run it again ([#303](https://github.com/hyperlapse122/nix-config/issues/303)). The obvious waits that avoid both, `Monitor` and a `pgrep -f` loop, do not work.

## Symptoms

- The #303 incident: a Claude Code child ran `uv run pytest -q` with no `timeout`, the Bash tool moved it to the background at 120000 ms, and the child stopped it with `TaskStop` and reran it with a longer timeout.
- In a live Antigravity run on 2026-10-22, a loop of `pgrep -f "sleep 60"` printed `running` after the command had ended, because the loop's own `bash -c` command line contains the pattern.
- During code review, a bracketed loop `pgrep -f '[u]v run pytest'` stayed blocked until its timeout because a concurrent T3 session in another worktree was running the same suite.
- In the same Antigravity run, two starts with a shell `&` inside `run_command` (one with `nohup`) left no output file and no process seconds later.

## What Didn't Work

- **`Monitor`.** Claude Code's Bash tool description tells the agent to wait with `Monitor`, but `Monitor` streams events as notifications while the agent keeps working, expires after at most 1800000 ms, and holds nothing open when the agent ends its turn. An agent with nothing else to do ends the turn, which is the #301 failure.
- **`pgrep -f '<command>'`.** Unbracketed, it matches the loop itself. The `[u]v` bracket trick stops that self-match, but the pattern still matches any process on the host with the same command line. That includes a sibling task's run, and the instructions launch sibling tasks in parallel on purpose. It also misses the same suite started with other flags, such as `uv run --frozen pytest` or `python -m pytest`, and then exits at once.
- **A shell `&` for a deliberate background start.** On Antigravity the child disappears when `run_command` returns.
- **Telling a live-test child that a 150-second suite "usually finishes in under a minute".** Under the timeout rule the child still set 600000 ms, so the harness never backgrounded the command and the wait path went untested.

## Solution

Wait on the harness's own record of that one command, in blocking foreground calls that each stay under the tool's limit:

- **Claude Code 2.1.308.** The Bash tool returns an output file path when it backgrounds a command, and the file ends with an `[exited with code N]` line once the command finishes. That line is there for a command moved at its timeout and for one started with `run_in_background`; this session's output files for both end with it. The Bash tool description says a foreground `sleep` is blocked, yet this loop ran unblocked in the live runs on 2026-10-22, and its pattern reads a file, so it cannot match a process. Repeat it until it exits, then read the output and exit status from the file:

  ```bash
  until grep -q '^\[exited with code' <output-file>; do sleep 5; done   # Bash tool timeout below 600000 ms
  ```

- **Antigravity CLI 1.4.5.** `run_command` waits at most `WaitMsBeforeAsync` (500 to 10000 ms) and then backgrounds the command; its arguments seen in the binary are `CommandLine`, `Cwd`, and `WaitMsBeforeAsync`, with no timeout. Wait with `command_status` on the returned background command ID; the live runs also read the task log Antigravity keeps in its own data directory for the session. For a deliberate background start, use a short `WaitMsBeforeAsync` instead of `&`.
- **OpenCode 2.1.2** (removed from this repository on 2026-10-23; the rerun-once rule below came from it and still covers any harness that kills a command at its timeout). The shell tool kills a foreground command at its timeout (default 120000 ms; `timeout: 0` disables it) instead of backgrounding it. Set the timeout up front. Its description also tells the agent, while a background command runs, to end its response when it has nothing else to do, which the instructions override.

Historically, the `# Subagents` section of `home/h82/agents/instructions/instructions.md.tmpl` carried these as four rules, right after the bullet that starts "Tell each subagent to run the commands its report depends on in the foreground" a parent passes to each subagent, native or delegated. Set the timeout before the command. Wait in the turn on the harness's record, never on a process name. Never stop and rerun a background command, except a wrong command, one still running at twice its expected time, or one that reaches the task prompt's time limit; report afterwards. Start a command longer than the foreground limit through the tool's own background option. The self-wake rule under `## Delegated tasks` in the `# T3 Code` section, the bullet that starts "In a run with a person present, never wait for a delegated task", also allows a foreground wait inside the turn on a command the agent runs.

## Why This Works

A wait holds the turn only while a tool call is in flight, so the blocking call must be a foreground shell call, re-issued until the command ends. The completion signal has to belong to that one command. Only the harness's record does: the output file it named, its task ID, or its exit status. A process name belongs to every process on the host. A task that waits on the record runs the command once and reads its real exit status, so its report holds the result rather than a guess.

## Prevention

- Historically, `tests/agent-instructions.nix` pinned the four sentences, like the foreground sentence before them, with removal and negation mutants. It also runs the background wait sentence's example loop (the check that prints "the example wait loop ends before the exit line appears"). The loop must keep waiting on an output file without the exit line and end once the line lands.
- The former check's `harnessFacts` list grepped the packaged Claude Code and Antigravity CLI binaries for the strings these facts rest on: `[exited with code`, `moved to the background`, `run_in_background`, ``Foreground `sleep` is blocked``, `WaitMsBeforeAsync`, and the `command_status` description. At the time, a harness update that dropped one turned the check red, prompting a reread of the harness before the rules went stale.
- To test the harness-backgrounded path live, tell the child to pass no `timeout`; describing the command as short is not enough. Judge the child from its T3 Code session's `activity` view, which shows every tool call. A child's own summary can leave out a rerun that the activity view shows.
- Read [T3 Code delegated waits end the turn because t3_thread_wait cannot carry them in-turn](t3-thread-wait-cannot-carry-in-turn-delegation-waits-alone.md) for the parent's side of the same wait.
