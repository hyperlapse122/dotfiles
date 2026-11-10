---
title: "A merge-ready wake can fire on zero check evidence, so the settle timer was load-bearing"
date: 2026-09-22
category: best-practices
module: "Pull request babysitting (ce-babysit-pr watch loop, AGENTS.md readiness rule)"
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Replacing or shortening ce-babysit-pr's `--settle-seconds` quiet window with an evidence-based readiness rule"
  - "Reasoning about a condition that loops over a collection and can only be falsified from inside that loop"
  - "A repository whose reviewers report as GitHub checks, where a review job can skip rather than fail"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
  - documentation
tags:
  - babysit-pr
  - merge-ready
  - settle-window
  - github-actions
  - vacuous-truth
  - claude-code-action
---

# A merge-ready wake can fire on zero check evidence, so the settle timer was load-bearing

## Context

Issue #30 proposed dropping `ce-babysit-pr`'s 300-second settle window. The argument: the window exists to guard against "CI went green, told the user to merge, then feedback landed" (the compound-engineering plugin's `skills/ce-babysit-pr/` (v3.30.5 when last checked), `references/watch-loop.md:169`), and in this repository every reviewer reported as a GitHub check — the Claude review then ran as a `pull_request` workflow (`.github/workflows/claude-code-review.yml:3-5`, deleted on 2026-10-05). If review arrives as a check, the check rollup already carries the review verdict, so a quiet period adds nothing the checks do not already say.

That argument holds for *stale* evidence and fails for *absent* evidence, and the timer was covering the absent case.

## The vacuous condition

`pr-snapshot` computes `checks_terminal` by initializing it optimistically and falsifying it only from inside the loop over observed check runs:

```python
checks_terminal = True
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, where `checks_terminal` is initialized)

```python
if c["status"] != "COMPLETED":
    checks_terminal = False
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, inside the loop over check runs)

With no observed check runs the loop body never executes, so `checks_terminal` stays `True`. "Every check has finished" is vacuously satisfied by having no checks.

The engine knows this. The pipeline-mode aggregate adds an explicit presence term:

```python
all_checks_ok = checks_terminal and not has_failing and bool(cur["checks"]) and awaiting_approval == 0
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, the `all_checks_ok` assignment), and `checks_present` is emitted separately in the snapshot output. The skill's own `skills/ce-babysit-pr/references/pipeline.md:13` and `skills/ce-babysit-pr/references/watch-loop.md:45` both key pipeline success on `all_checks_ok`, and the latter names "an empty check rollup" as not-success.

The **interactive** merge-ready wake deliberately omits that term:

```python
# Interactive merge-ready does NOT require `all_checks_ok`'s "at least one observed check": a repo
# with no configured checks has a CLEAN/MERGEABLE PR that should be callable ready. (That guard
# stays in pipeline success, where a not-yet-created rollup must not read as a pass.)
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, the comment above the merge-ready condition)

The condition it guards is:

```python
if (mergeability_certain and a.get("mergeable") == "MERGEABLE"
        and a.get("merge_state_status") == "CLEAN"
        and a.get("checks_terminal") and not a.get("has_failing_checks")
        and a.get("checks_awaiting_approval", 0) == 0
        and a.get("branch_currency_blocker") is None
        and a.get("quiet_seconds", 0) >= settle_seconds):
    return "merge-ready"
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, the merge-ready condition)

Nothing there requires a check to exist. The exemption is intentional and defensible for a repository with no CI at all. It is also unconditional, so it applies equally to a repository with four workflows whose runs have simply not been registered yet.

## What the timer was covering

A push moves the head SHA, and the head SHA is part of the settle signature: `changed_this_tick = head_changed or ...` stamps `last_change_at` (`skills/ce-babysit-pr/scripts/pr-snapshot`, the `changed_this_tick` block), and `quiet_seconds` is measured from that stamp (emitted in the snapshot output). So every push reset the clock, and `DEFAULT_SETTLE_SECONDS = 300.0` (`skills/ce-babysit-pr/scripts/pr-snapshot`, `DEFAULT_SETTLE_SECONDS`) bought five minutes during which the merge-ready branch could not be reached no matter what the rollup said.

In that five-minute gap, GitHub registers the check runs for the new head. By the time the window elapsed, `checks_terminal` was a statement about real runs rather than about an empty set. The timer was never advertised as an evidence-presence guard — `skills/ce-babysit-pr/references/watch-loop.md:33` calls it "the quiet window before a `merge-ready` wake" and the cooling-off bullet there calls it "a cooling-off signal, not a guarantee" — but it was functioning as one.

Remove it (`--settle-seconds 0`) without adding anything, and a CLEAN/MERGEABLE pull request in the window between a push and the first registered check run satisfies merge-ready on *no evidence at all*. The evidence is neither stale nor still running; it does not exist. The removal creates this false positive.

## The practice

**When you remove a timer, first ask what the timer was incidentally covering.** A quiet window in front of a decision is not only a debounce; it is also a delay during which other systems catch up. The stated rationale for this window ("has the PR stopped moving?") was genuinely obsolete here. The unstated function ("has the evidence arrived?") was not, and only reading the wake condition line by line shows which is which.

**Read every condition in a readiness predicate for what it says when the collection it quantifies over is empty.** `checks_terminal`, `not has_failing_checks`, and `checks_awaiting_approval == 0` are all vacuously true on an empty rollup. Three independent-looking green conditions collapse to one piece of information — the rollup is empty — and none of them says so.

## The rule this repository adopted

Rather than patch the skill (it is installed from the compound-engineering plugin outside this repository, so a patch does not survive the next install), the readiness rule is a tracked project instruction in `AGENTS.md`. It arms the watch with `--settle-seconds 0` and supersedes the skill's instruction at `skills/ce-babysit-pr/references/watch-loop.md:33` to leave the flag unset, then replaces the timer with evidence conditions:

- every workflow that runs on pull requests has a run registered against the current head;
- every such run is terminal.

While the Claude review workflow ran, a third condition held: no review check merely skipped, because a skipped review is absent evidence, not a clean review. It was retired on 2026-10-05, when Claude Code was removed from CI. `check.yml` is now the only pull-request workflow, and the jobs it skips by design, such as the Nix jobs on a docs-only change, are part of that run's result.

The first condition is what replaces the timer's incidental cover, and it is stricter than the engine's `checks_present`: presence is judged per workflow against the current head, not "at least one run exists anywhere". Nothing else relaxes; threads, comments, `needs-human`, and the base and branch-currency blockers keep their force. While evidence is incomplete the agent neither declares readiness nor re-arms at a shorter window.

## Why `SKIPPED` needed naming explicitly

This section records why the rule named skipped review checks while the Claude review workflow existed. The lesson about the engine's failing set still holds for any future reviewer that reports as a check.

`pr-snapshot`'s failing set is

```python
FAILING = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"}
```

(`skills/ce-babysit-pr/scripts/pr-snapshot`, the `FAILING` set)

`SKIPPED` is not in it. A skipped run is `COMPLETED`, so it satisfies `checks_terminal`, and its conclusion is not failing, so `has_failing_checks` stays false. To the engine a skipped review check is indistinguishable from a review that ran and found nothing. Only the prose rule can draw that line, which is why `AGENTS.md` named the case by hand.

The case is not hypothetical. The plan records that `anthropics/claude-code-action`'s token exchange fails with a warning and the job *skips* rather than fails when the workflow file is not yet on the default branch (`.compound-engineering/artifacts/plans/2026-09-21-2330-ci-claude-workflow-toolchain-and-settle-window-plan.md:160`; the plan cites that action's own token-exchange source in its upstream repository, which was not re-read here). So every pull request that edits an agent workflow — including the one that introduced these — produces exactly that indistinguishable skipped review.

The review workflow's job gate (as of 2026-10-05 retired, kept here as the example) carried the mirror-image hazard in a comment:

```yaml
# Excluding every bot would
# skip the review on this repository's own flake.lock pull requests, whose
# skipped review then reads as missing evidence and holds them forever.
```

(`.github/workflows/claude-code-review.yml:15-17`; that workflow was retired on 2026-10-05 in cf17c46, so the quote is historical)

Treating a skip as absent evidence is correct, and it turns every over-broad job gate into a permanent readiness stall. The two have to be designed together: the rule that refuses to read a skip as a pass, and the `if:` that refuses to skip for reasons unrelated to evidence.

## How to apply

- Before deleting a delay, enumerate what else finishes during it. Grep for every consumer of the state the delay guards, and check whether any of them reads that state as a fact rather than as a not-yet.
- For any boolean derived by a loop, write down its value for the empty collection. If the empty case is green, the predicate needs a separate presence term — and check whether some *other* aggregate in the same file already carries one, which is a strong hint that the omission elsewhere is deliberate and scoped.
- When two call sites compute nearly the same predicate and one has an extra term, read the comment explaining the difference before assuming either is a bug. The exemption in the merge-ready branch is correct for its stated case and wrong for ours; the fix belongs in the project's rule, not in the engine.
- Express readiness evidence per workflow against the current head, not as a count of runs. "At least one run exists" is satisfied by the fast workflow while the slow one has not started.
- Whenever a rule treats a state as absent evidence, make sure that state cannot be produced routinely for unrelated reasons, or the rule becomes a deadlock. Pair it with a hand-back path: report the missing evidence, do not silently wait.

## See also

`nix-check-reads-option-value-not-materialized-output.md` in this directory carries the same abstract lesson in a different system: an assertion that reads a proxy stays green exactly when the proxy and the property it stands for come apart. There the proxy is an option value beside an `enable` flag; here it is a boolean quantified over an empty collection.

## Out of scope

None of this was verified against a live pull request. The agent workflows skip rather than run on the pull request that edits them, so the behavioral cases are post-merge verification (plan lines 238 and 342). The reasoning here is from reading `pr-snapshot` at the current tree; the false-positive window is argued from the code, not observed on GitHub.
