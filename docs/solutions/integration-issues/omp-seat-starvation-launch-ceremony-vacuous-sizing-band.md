---
title: An omp/Gemini Roster Seat Named First in Two Routing Rows Received Zero Dispatches for Ten Days
date: 2026-09-18
last_updated: 2026-09-18
category: integration-issues
module: agents
problem_type: integration_issue
component: development_workflow
severity: medium
symptoms:
  - an omp/Gemini roster seat declared as the first recipient for two of four coordinator routing rows received zero dispatches over a ten-day window
  - a sibling recipient (codex-luna) sitting in the same fallback column of the same two rows received 496 dispatches in that same window
  - the roster declaration and the routing-table prose both rendered and validated without error
  - the gap was found only by an operator noticing the seat's absence from a usage-export screenshot, not by any test, lint, or dispatch-time error
root_cause: design_limitation
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - orca
  - omp
  - gemini
  - dispatch-routing
  - worker-roster
  - worker-start
  - sizing-band
  - coordinator
---

# An omp/Gemini Roster Seat Named First in Two Routing Rows Received Zero Dispatches for Ten Days

## Problem

`.chezmoidata/agents.yaml` declared an `omp` worker on `google-antigravity/gemini-3.8-flash`,
and `.chezmoitemplates/orchestration-coordinator.tmpl`'s dispatch table named that seat the
**first recipient** for two of the table's four routing rows. Both declarations were internally
correct and rendered without error. Over a ten-day window that seat received zero dispatches,
while `codex-luna` — a worker sitting in the same fallback column of the same two rows — received
496. The absence was found only because an operator happened to notice it missing from a usage
export; nothing in the render, the roster validator, or CI flagged the gap, because nothing about
the declaration was syntactically wrong.

## Symptoms

- The omp/Gemini seat is present in the roster, present in the routing table as the named first
  recipient of two rows, and never appears in a ten-day dispatch usage export.
- `codex-luna`, named as a later column of those same two rows, accounts for 496 dispatches in
  that window. omp itself is not idle — it ran 632 sessions total in the same period — so the
  seat was reachable, just never chosen first (`docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md:39`).
- No test, lint, or runtime error surfaces the gap. `.chezmoitemplates/agent-roster-validate.tmpl`
  and the CI roster tests check structural properties of the roster (duplicate ids, unknown
  agents, missing rungs) and had nothing to say about a row whose membership was empty by
  construction, or about a coordinator's own per-dispatch cost calculus.

## Root Causes

Two independent causes were present, and fixing either alone would have left the seat starved.

### 1. Launch ceremony made the cheaper recipient always win

Orca's `worker-start --model`/`--effort` flags forward to Claude, Codex, and Cursor launches
only. On `main` (`.chezmoitemplates/orchestration-coordinator.tmpl:53`, pre-fix), reaching the
omp seat required the lead to open a terminal running omp with the entry's model and thinking
level, read back the terminal handle, confirm the model, and then call
`worker-start --terminal <handle>` — four lead tool calls, against the one call a `codex` or
`claude` launch costs via `worker-start --model`/`--effort` directly. `codex-luna` sits in the
same fallback column of the same two routing rows the omp seat leads
(`docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md:39`). Faced with two
eligible recipients of otherwise-equal standing, the coordinating model chose the one-call
neighbor every time. The routing table's stated priority order was never what decided the
dispatch; the per-call cost was.

### 2. A vacuous sizing band

Before the fix, the second implementation row read (`main:.chezmoitemplates/orchestration-coordinator.tmpl:43`):

> Frontend, non-Markdown deliverables, and Implementation Units the four signals place below
> `{{ $sonnet.rung }}`

but the sizing paragraph immediately below it (`main:.chezmoitemplates/orchestration-coordinator.tmpl:55`)
defined `{{ $sonnet.rung }}` as the **smallest** shape the rule describes: "a Unit whose approach
the plan fixes, that stays inside one module and a few files, and whose acceptance a test or a
command settles." Nothing below that band was ever defined. The set "Units the four signals
place below `sonnet`" was therefore empty by construction
(`docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md:35`), and every sized
Implementation Unit landed on the `claude` row regardless of size, leaving the omp row's
"first recipient" cell unreachable on its own terms — independent of cause 1.

## Detection Signal (the transferable part)

The reusable diagnostic is not "check whether a seat is used" — it is:

> Compare dispatch counts across rows of **equal rank**. Two recipients named in the same row's
> same column, one at hundreds of dispatches and one at zero over the same window, is a dead
> row, not a preference.

A routing table can render, validate, and read correctly while still being unreachable in
practice, because rank-on-paper and rank-in-practice are decided by different mechanisms (prose
priority vs. per-call cost). A usage export grouped by roster entry and by routing row turns this
into a one-query check: any row where a same-column peer's count is zero while another peer's is
not is a candidate for one of these two causes, without needing to read the routing prose at all.

## The Fix

Landed on branch `hyperlapse122/refactor-shift-agent-roster`, PR #546 (pending, not yet merged).

**Cause 1 — ceremony moved from per-dispatch to per-run.**
`.chezmoitemplates/orchestration-coordinator.tmpl:53` now opens an omp seat once per shape per
run and re-engages it for every later dispatch of that shape with one call,
`worker-start --task <task_id> --terminal <handle>`, instead of repeating the open/read/confirm
sequence on every dispatch. The standing seat is exempted from the review-and-peer contract's
same-turn release rule so it can persist across dispatches, and is released before the run ends.

> **Superseded on 2026-09-18, cause 1 only.** Issue #551 forbids omp seat reuse: every dispatch opens a new omp terminal, takes its one Dispatch with `worker-start --task <task_id> --terminal <handle>`, and is released in the turn that Dispatch settles, so the ceremony is per dispatch again and the same-turn release exemption is gone. The pressure this cause describes is now held by the cause 2 fix alone — the omp row's default membership and the recorded-signal rule for a `claude` implementation dispatch — and the launch cost is tracked in issue #550. Cause 2 and its fix stand as written.

**Cause 2 — the vacuous band was deleted, and omp named as the sizing rule's own floor.**
`.chezmoitemplates/orchestration-coordinator.tmpl:43` now reads "Implementation Units of every
deliverable format — code, frontend, and repository Markdown alike — that no recorded signal
places at `{{ $sonnet.rung }}`" as the omp row's membership, and the sizing paragraph
(`.chezmoitemplates/orchestration-coordinator.tmpl:55`) states directly: "`omp`
`{{ $ompImpl.model }}` {{ $ompImpl.effort }} ... also takes every Unit the `{{ $sonnet.rung }}`
signals do not claim." The omp seat became the unmarked default for every Implementation Unit; a
`claude` worker is used only when the lead has recorded, before dispatch, which of the four
sizing signals sent the Unit there — an unrecorded `claude` implementation dispatch is now a
named rule violation. `.chezmoidata/agents.yaml:62-86` and `AGENTS.md:74` describe the resulting
six-entry roster and the omp seat's role.

The same landing also removed the `opus` worker rung entirely (renamed to a `fable`-backed
`authoring` entry for plan/approach-generation work) and split two seats that had been serving
two purposes at one effort into dedicated entries — this is broader roster cleanup from the same
plan and outside the two-cause scope of this learning; see
`docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md` for the full Product
Contract if that context is needed.

## A Third Fact, Caught Only by Cross-Model Review

The first attempt at the standing-seat rule told the lead to re-engage a live seat with
`worker-start --terminal <handle>` alone (recorded in the plan's own KTD6 decision text,
`docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md:198`, and it shipped
into the coordinator payload the same way — see the pre-review state of
`.chezmoitemplates/orchestration-coordinator.tmpl` at commit `a00b3eee`). Orca's `worker-start`
requires `--task` or `--spec`; a bare `--terminal` argv is rejected before the seat receives any
work. A one-call steady state that does not parse is strictly worse than the four-call ceremony
it was meant to replace — it would have replaced a starved seat with a broken one. Per the
session's own account, seven local review passes let this through; a cross-model review pass
caught it. The fix landed in commit `af07bc7d` ("fix(review): apply cross-model review
findings"), changing the re-engage call to `worker-start --task <task_id> --terminal <handle>`
in `.chezmoitemplates/orchestration-coordinator.tmpl:53` and the matching prose in `AGENTS.md`.
This fact is recorded here because "the fix compiled/rendered and reviewers approved it" is
exactly the false confidence that let both original causes ship in the first place — a syntactic
check on a coordination protocol proves nothing about whether the CLI on the other end accepts
the call.

> **Updated 2026-09-18.** The re-engage call this section corrects is retired by issue #551. The corrected spelling survives as the one dispatch call into a freshly launched terminal, and the lesson stands: an argv acceptance check is a different guarantee from a render.

## Why This Works

Both original causes were invisible to structural validation because they are properties of
*behavior over time and under a specific cost/ambiguity condition*, not properties of a single
render:

- The launch-ceremony asymmetry only shows up as a distribution across many dispatch decisions;
  a single dispatch, or a unit test of one, cannot exhibit "the cheaper option keeps winning."
- The vacuous band only shows up as "this row is provably unreachable," which requires reading
  the sizing paragraph and the routing row together and noticing their boundaries don't meet —
  something no schema or renderer check was written to do, because both are separately
  well-formed.

The fix addresses each mechanism directly rather than nudging the coordinator's preference:
cause 1 is fixed by making the cheap path and the omp path the same path (one call either way in
steady state), and cause 2 is fixed by removing the empty set so there is no longer a gap between
what the row claims and what the sizing rule defines.

## Prevention

- When a routing/priority table names a recipient by rank, verify that at least one path through
  the table's own logic actually reaches that recipient — an empty "below X" or "above Y" band is
  a silent full-row exclusion, not a conservative default.
- When two recipients occupy the same rank or the same fallback column, check whether the
  mechanism that reaches each of them costs the same number of calls or the same latency. An
  agent (human or model) picking between formally-equal options will consistently prefer the
  cheaper one to invoke, regardless of stated priority.
- Build the detection signal into routine review: pull dispatch counts by roster entry and by
  routing row, and flag any row where same-rank peers diverge from hundreds of dispatches to
  zero. This is a one-query check against a usage export and does not require reading the
  routing prose.
- Do not treat "renders without error" or "reviewers approved it" as evidence that a
  steady-state control-flow rule works end to end, when that rule's own steady-state path (here,
  the re-engage call) was never executed against the real CLI before landing. A syntactic pass
  and an argv acceptance check are different guarantees.

## Related Issues

- GitHub issue #543 ("chore(agents): tighten orca session release, wait timeout, and omp
  dispatch") item 3 raises the same launch-ceremony inefficiency (three-step
  open → confirm → attach vs. a single non-interactive call) independently, and is still open;
  this fix reduces the ceremony's steady-state cost from per-dispatch to per-run but does not
  investigate whether omp supports a genuinely single-call non-interactive launch, which is what
  that issue asks for.
