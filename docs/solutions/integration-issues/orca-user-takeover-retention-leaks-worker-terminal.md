---
title: Orca Records Keystroke Input as User Takeover and Retains Finished Worker Terminals Across Release Calls
date: 2026-09-18
category: integration-issues
module: agents
problem_type: integration_issue
component: development_workflow
severity: medium
symptoms:
  - worker-release on a settled dispatch returns state retained with reason user_takeover and processAction none
  - state query reports the dispatch inactive while the agent process and terminal remain running
  - finished workers remain visible in the Orca desktop app after a coordinator run completes
  - worker-list --terminal-state reclaimable never enumerates the retained worker terminal
root_cause: design_limitation
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - orca
  - worker-release
  - worker-stop
  - terminal-ownership
  - user-takeover
  - dispatch-lifecycle
---

# Orca Records Keystroke Input as User Takeover and Retains Finished Worker Terminals Across Release Calls

## Problem

After a coordinator run completes, `orca orchestration worker-release` on a settled dispatch
returns `state: retained`, `reason: user_takeover`, and `processAction: none`. A follow-up state
query reports that the dispatch is no longer active. The agent process and its terminal pane
remain running in the Orca desktop application.

Under the previous coordinator release contract, the coordinator treated any dispatch that
reported inactive under a proven-identity retention as settled. The contract listed
`a recorded user takeover` as a proven identity. The coordinator therefore walked away without
recording a gap. Finished worker processes and terminals stayed resident indefinitely.

All findings below were verified against installed Orca version **1.4.205** on Fedora Linux.

## Symptoms

- Calling `orca orchestration worker-release` for a completed dispatch returns:
  `state: retained`, `reason: user_takeover`, `processAction: none`.
- The `worker-list` row for the dispatch reports `terminalState: retained` and
  `projection.attention.categories` carrying `root_completion`, while `projection.liveness.verdict`
  is still `live` and `projection.nextAction` is `none`; the worker process and its terminal pane
  stay open in the Orca user interface.
- `orca orchestration worker-list --terminal-state reclaimable` omits the leaked terminal entirely.
- The coordinator logs no release failure or gap under contracts that credit `user_takeover` as a
  settled state.

## Root Causes

Investigation of the Orca 1.4.205 application bundle identified how terminal ownership transitions
to `user_owned`, why keystroke inspection triggers that transition, and why CLI commands refuse
reclamation.

### 1. Release decision switches on terminal ownership state

Orca's internal release handler evaluates the terminal resource's `ownership_state` field. When
`ownership_state` equals `user_owned`, the release handler maps the result to `state: retained`
with `reason: user_takeover`.

The sole writer of `ownership_state = 'user_owned'` is the database method
`markWorkerTerminalUserOwned(paneKey)`. Exactly one RPC invokes this method:
`orchestration.workerTerminalUserInput`. That RPC has two renderer call sites:

1. A structured chat send, dispatched only after the user's message is accepted.
2. An xterm `onUserInput` event subscription, which fires on user keystrokes and clipboard pastes.

Orca debounces calls to `orchestration.workerTerminalUserInput` to at most once per 30 seconds per pane.
When the method runs, it durably sets `ownership_state = 'user_owned'` and `release_state = 'retained'`.
The same database transaction deletes the dispatch's archived worker output.

### 2. Single keystrokes trigger takeover while terminal viewing does not

Viewing, focusing, or scrolling a worker terminal does **not** trigger `user_takeover`.

xterm triggers `onUserInput` only when `triggerDataEvent` executes with `wasUserInput: true`.
Automatic terminal replies — such as device status reports and focus-in or focus-out tracking sequences —
set `wasUserInput: false` and do not reach the RPC.

However, any single interactive keypress into the pane passes `wasUserInput: true`. Pressing an arrow
key to scroll, pressing `Esc`, or typing `Ctrl-C` while inspecting a worker terminal immediately marks
the terminal as `user_owned`.

The release receipt does not record which call site set `user_owned`. A coordinator reading the receipt
cannot distinguish whether an operator submitted an interactive prompt or merely pressed an arrow key
while inspecting terminal output.

### 3. Neither stop nor release reclaims user-owned terminals

Orca's CLI commands explicitly refuse to close terminals marked `user_owned`:

- `orca orchestration worker-release --help` documents that it never closes user-taken-over terminals.
- `orca orchestration worker-stop` on an already-settled dispatch returns:
  `alreadySettled: true`, `processAction: none`.
- `orca orchestration worker-stop` on an active dispatch whose resource is `user_owned` marks the stop
  unknown and returns the error:
  `The worker terminal is user_owned; no terminal was closed.`

On Orca 1.4.205, a coordinator cannot force reclamation of a `user_owned` terminal through standard CLI
verbs once Orca records the takeover flag.

## Detection and Enumeration Blind Spot

Coordinators that rely on end-of-run sweep enumeration cannot detect leaked `user_owned` terminals.

Running `orca orchestration worker-list --terminal-state reclaimable` returns only terminals eligible for
immediate cleanup. A terminal marked `user_owned` has terminal state `retained` and
`projection.nextAction: none`. Orca filters it out of reclaimable listings.

The release receipt from `worker-release` is the only signal that surfaces this retention state.
A coordinator must process the receipt directly rather than relying on global reclaim sweeps.

## Why Direct Terminal Close Is Forbidden

Orca's installed orchestration guide explicitly states: "Never substitute `terminal close`" for worker
release.

A coordinating agent cannot verify from its own context whether a `user_owned` mark represents an
accidental keystroke or a human operator actively driving the session. Issuing a forced terminal close
would terminate interactive human debugging sessions and destroy uncommitted user work.

When Orca refuses to reclaim the terminal, the coordinating process must record the condition as an
unproven release and leave terminal closure to the human operator.

## The Fix

The repository updated the coordinator release protocol and its verification gates:

1. **Coordinator contract update**: `.chezmoitemplates/orchestration-coordinator.tmpl` line 66 removed
   `a recorded user takeover` from the proven-identity list. Proven identities now include only reused,
   pre-existing, or run-requested retentions.
2. **Strict settle criteria**: A `user_takeover` retention settles only under the process-gone rule:
   the dispatch query confirms `stage: process_exited` or terminal state released, with no residual
   resources.
3. **Recovery sequence**: When a query reports the dispatch inactive but does not confirm process exit,
   the coordinator issues `worker-stop`, requests `worker-release` again, and queries once more.
4. **Unproven release recording**: If the process remains live, its state remains unknown, or residual
   resources exist after the stop sequence, the coordinator records the dispatch as an unproven
   release. The record notes that the terminal remains resident for operator closure.
5. **Instruction gate assertions**: `.ci/test-agent-instructions.sh` asserts the full-sentence wording
   for each added rule and rejects the retired `a recorded user takeover` phrase.

This change is documented in `docs/plans/2026-09-18-0900-fix-coordinator-release-retention-takeover-plan.md`
and addresses GitHub issue #548.

## Live Reproduction Evidence

The investigation reproduced this retention behavior on a live Orca session during model-elevation
dispatch:

- An elevation worker completed its task.
- `worker-release` returned `state: retained`, `reason: user_takeover`, `processAction: none`, despite
  no intentional user prompt takeover occurring.
- `worker-stop` returned `alreadySettled: true`, `processAction: none`.
- A re-query confirmed the agent process was `live` and the terminal was `retained`.
- In the same coordinator run, two peer reviewer workers that received zero pane keystrokes released
  normally with `processAction: closed_agent_terminal`.

This contrast proved that the issue stems from pane keystroke input marking `user_owned`, not from
a general release-path defect.

## Prevention

- Do not classify `user_takeover` receipts as proven identities in automated coordinator workflows.
- Require verified process termination (`stage: process_exited`, zero residual resources) before
  treating any retained worker as closed.
- Treat `worker-list --terminal-state reclaimable` as an incomplete filter that misses `user_owned`
  and retained resources.
- When an upstream CLI refuses to reclaim user-owned resources, record the condition explicitly in the
  run summary so operators know which terminals require manual closure.
- Never substitute raw window or terminal kill commands for orchestration lifecycle verbs.

## Related Issues

- **GitHub issue #548**: Narrow coordinator release retention takeover to prevent finished worker leaks.
- **GitHub issue #543**: Tighten Orca session release, wait timeout, and omp dispatch lifecycle.
- **Plan**: `docs/plans/2026-09-18-0900-fix-coordinator-release-retention-takeover-plan.md`.
