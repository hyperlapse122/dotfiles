---
title: Delegated Codex children gave up once in 30 runs at T3's default effort and never at high, and high cost eight times the tokens on a review
date: "2026-11-13"
category: best-practices
module: "T3 delegation and CE model selection (home/h82/agents/instructions/instructions.md.tmpl)"
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Changing the reasoning effort of delegated Codex children in T3 Code"
  - "A delegated Codex child returns without its assigned output and an LFG run stops on it"
  - "Deciding whether a child's own summary is enough evidence that it produced its artifact"
  - "Measuring delegated children again after a model or T3 Code update"
symptoms:
  - "A `gpt-6.1-sol` review child returned `status: failed` after 22 seconds and three tool calls"
  - "A `gpt-6.1-terra` implementation child sent Ctrl-C to its own `nix build` and reported blocked on verification"
  - "A `gpt-6-luna` scout reported that it created a dossier file that does not exist"
related_components:
  - development_workflow
tags: ["codex", "reasoning-effort", "delegate-task", "t3-code", "benchmark", "give-up", "lfg", "ce-code-review", "truncated-output", "false-completion"]
retire_when: "T3 Code's default `reasoningEffort` for `gpt-6.1-sol` or `gpt-6.1-terra` is no longer `low`, the Codex ladder models change, or a repeat of this measurement shows a different result"
---

# Delegated Codex children gave up once in 30 runs at T3's default effort and never at high, and high cost eight times the tokens on a review

## Context

An LFG run on `gpt-6-astra` stopped twice on 2026-11-12 because two delegated Codex children returned without their assigned output (issue #161, PR #162). The Codex session records on the NixOS workstation showed what happened:

- The `gpt-6.1-terra` implementation child started a `nix build` with a one-second wait, polled it in five-second waits, and sent Ctrl-C about three minutes in. Nothing in the harness ends a slow command: Codex's `exec_command` waits at most 30 seconds per call and returns a session ID for a command that is still running.
- The `gpt-6.1-sol` review child had been handed the whole `ce-code-review` skill. It read several files in one command, two outputs were cut at the default 10,000 tokens per call, and it returned `failed` after 22 seconds and 30 reasoning tokens. The cut output held the skill's own rule to read a shortened result again.
- In 278 delegated Codex children recorded from 2026-11-10 to 2026-11-13, 104 of the 112 `gpt-6.1-sol` children that finished had also received truncated output. Truncation is routine and does not by itself make a child give up.

The shared instructions told orchestrators to pass no effort for a ladder-selected child, which gives `gpt-6.1-sol` and `gpt-6.1-terra` children T3's default of `low` and `gpt-6-luna` children `medium`. The measurement below asked whether `high` reduces give-ups.

## Guidance

**Judge a child from its artifact and its session record, not from its summary.** One default-effort scout made two read calls, wrote nothing, and returned "Created the quote-only grounding dossier" with a link to a file that does not exist. A caller that reads only the summary accepts that return as complete.

**Name the artifact and its path in the brief.** Every measured brief named one output file. 59 of 60 children produced it, including all 20 default-effort children on the two task shapes that had failed in the LFG run.

**Keep `ce-code-review` in the orchestrator.** The failed review brief told a child to run the whole skill and allowed further delegation. The measured review brief told the child to review in its own context and write one receipt file; all ten default-effort runs finished in 39 to 58 seconds.

**`high` costs most where the task is open-ended.** On the review, `high` read more and ran more checks: a median of 25 tool calls against 6, and several runs evaluated the flake at the reviewed commit. On the fixed work unit it changed nothing measurable.

## Measurement

The protocol was fixed before the first run. Each run was a T3 Code `delegate_task` child on Codex CLI 0.167.1, launched from a Claude Fable 5.2 orchestrator on 2026-11-13, six children at a time: one of each task shape in each arm. The default arm passed no options. The raised arm passed `reasoningEffort: high`. The T3 threads are titled `M161 <shape> <arm>-<NN>`.

| Task shape | Model | Brief |
| --- | --- | --- |
| review | `gpt-6.1-sol` | Run `ce-code-review` in agent mode on commit `ef32731` against its parent (18 files, 14 additions, 990 deletions), in the child's own context, and write the receipt as JSON to a named file |
| work | `gpt-6.1-terra` | Implement one function in a five-test Python fixture project, then run its `check.sh`, which prints progress for 240 seconds before running the tests, and report the exit status |
| scout | `gpt-6-luna` | Quote six named sources into a dossier of at most 150 lines at a named path |

A run was valid when the child started and its turn ended on its own. A give-up was a valid run whose artifact was missing: no parseable receipt with a status other than failed, no `check.exit` marker written after at least 230 seconds with the check script unchanged, or no dossier file. A present artifact that was wrong was counted separately.

| Shape | Arm | Valid runs | Give-ups | Wrong artifact | Median time | Median tool calls | Median reasoning tokens | Total tokens |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| review | default | 10 | 0 | 0 | 47 s | 6 | 10 | 3.6 M |
| review | high | 10 | 0 | 0 | 274 s | 25 | 3,581 | 29.8 M |
| work | default | 10 | 0 | 0 | 251 s | 15 | 7 | 6.4 M |
| work | high | 10 | 0 | 0 | 251 s | 14 | 130 | 5.1 M |
| scout | default | 10 | 1 | 0 | 39 s | 3 | 55 | 1.7 M |
| scout | high | 10 | 0 | 0 | 122 s | 7 | 1,201 | 4.1 M |

No run was invalid, so none was replaced. No child sent Ctrl-C to the slow check. Every review run and 18 of 20 scout runs received at least one truncated output.

The one give-up was `M161 scout d-07` (T3 thread ending `5ad57688-8745-4471-9490-e2864db38523`): two tool calls, both truncated, no reasoning tokens, 16 seconds, and the false "Created" summary quoted above.

Total tokens are mostly cached input. Uncached input was 0.6 M for the ten default reviews and 1.7 M for the ten `high` reviews; output was 16 K against 104 K. The owner's other Codex sessions ran on the same account during the measurement, so no subscription-window percentage is recorded.

## Decision

The plan's rule changes the effort for Codex children when the default arm has at least one give-up and the raised arm has at most half as many, over the three shapes combined. The counts are 1 and 0, so the rule applies, and the T3-only instructions now pass `high` for a ladder-selected Codex child.

The evidence for that change is one event in 30 runs. It cannot separate a real difference from chance, and the measured briefs, which each named an output file, did not reproduce the give-up rate of the session record (22 of 140 `gpt-6.1-terra` children at default effort, counted by a wording match on each child's final message and not checked by hand). The cost is certain: about eight times the tokens and six times the wall time on an open-ended review. Read the decision as "the pre-agreed threshold was met", not as "high effort is shown to prevent give-ups".

## Why This Matters

Without the counts, the next change repeats the guess: that children give up because of truncation, or a time limit, or low effort. The record shows the time limit never existed, truncation is routine, and a brief that names its artifact removes most give-ups at any effort. It also shows a failure the give-up framing misses: a child that claims an output it never wrote.

## When to Apply

- Before changing the Codex effort sentence in the T3 CE model selection section, repeat this measurement and compare it with the table above.
- When a delegated child's return is the only evidence of its work, check the named artifact before treating the return as complete.
- When measuring again, reuse the three briefs and the judging rules so the numbers stay comparable. This measurement ran in the shared checkout with one scratch directory per run instead of one worktree per run; every task wrote only under its own directory, and the checkout was clean after every batch.

## Related

- [Benchmark a cross-model review peer in T3 Code before changing its model or effort](benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md): how to replay a prompt and why one sample cannot rank models.
- [The Codex priority service tier costs 2.5x subscription usage](codex-priority-tier-costs-2-5x-subscription-usage-for-review-peer.md): service tier is a separate setting from reasoning effort.
- [A delegated agent's in-turn wait for a slow command needs the harness's exit record](../integration-issues/slow-command-wait-needs-harness-exit-record-not-pgrep-or-monitor.md): the earlier slow-command rules for Claude Code and Antigravity.
