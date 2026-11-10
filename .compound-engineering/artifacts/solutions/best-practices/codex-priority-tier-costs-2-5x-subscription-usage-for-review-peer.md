---
title: The Codex priority service tier costs 2.5x subscription usage, so the review peer stays on the default tier
date: "2026-10-23"
last_updated: "2026-10-27"
category: best-practices
module: "Cross-model review peers (home/h82/agents/instructions/instructions.md.tmpl)"
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Considering `serviceTier` `priority` (Codex fast mode) for the Codex cross-model review peer or any other delegated Codex role"
  - "Estimating how much Codex usage a review peer or a benchmark of one will consume"
  - "Reopening issue #320 or a request like it"
symptoms:
  - "A planned four-run tier benchmark would have needed about 62 percent of the Codex 5-hour usage window, which was already 67 percent used"
related_components:
  - development_workflow
tags: ["codex", "service-tier", "priority", "fast-mode", "cross-model-peer", "usage-limits", "rate-limits", "t3-code", "delegate-task"]
retire_when: "OpenAI's Codex pricing page (https://learn.chatgpt.com/docs/pricing) lists Fast mode at 2x or less on included subscription usage, or this host's `codex login status` stops reporting a ChatGPT login"
---

# The Codex priority service tier costs 2.5x subscription usage, so the review peer stays on the default tier

## Context

Issue #320 proposed running the Codex cross-model review peer (`gpt-6.1-sol`, `reasoningEffort` `xhigh`) at `serviceTier` `priority`, Codex's fast mode, because every `ce-code-review` and `ce-doc-review` in a `claude` session waits on that peer. T3 Code's `delegate_task` passes `serviceTier` through, and `task_status` echoes it. The user set the adoption rule before any measurement: two runs per tier, the `priority` mean at least 30 percent below the `default` mean, the two ranges not overlapping, and Codex usage at most 2x the default tier. The issue closed as wontfix on 2026-10-23 without a benchmark run. The repository holds nothing about this decision, so the reasoning lives here.

## Guidance

**Check the billing basis before measuring speed.** OpenAI's Codex pricing page (`https://learn.chatgpt.com/docs/pricing`, read 2026-10-23) charges Fast mode at 2.5x Standard on included subscription usage and 2x on purchased credits and Enterprise pay-as-you-go. `codex login status` on this host prints `Logged in using ChatGPT`, so the subscription multiplier applies, and `priority` fails a 2x usage cap however much faster it runs. A benchmark cannot change that verdict, so it is only worth running when the billing basis or the cap changes.

**Read per-run usage from Codex's session rollouts, not `/status`.** Every Codex session writes `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, and its token-count events carry `rate_limits`. In those, `primary.used_percent` is the 5-hour window, `secondary.used_percent` is the weekly window, and each has a `resets_at` Unix time. The first and last values in one rollout bracket that session's usage, although the gauge is account-wide, so concurrent Codex work leaks in. Find a peer's rollout by grepping for its scratch directory name.

```sh
f=~/.codex/sessions/2026/10/23/rollout-2026-10-23T10-31-26-01a16662-6201-72d3-a6fd-bb2f252ef1e9.jsonl
grep -o '"primary":{"used_percent":[0-9.]*' "$f" | sed -n '1p;$p'
```

The 2026-10-23 `ce-code-review` Codex peer (default tier, 7:09 from `startedAt` to `completedAt` on a PR #318 diff of about 4,200 lines) moved the 5-hour window from 13 to 22 percent and the weekly window from 2 to 4 percent. At 2.5x, one `priority` review would take about 22 percent of the 5-hour window. A two-runs-per-tier benchmark needs about 62 percent of that window, so start one only right after the window resets.

**The route outside T3 Code cannot take a tier anyway.** Compound Engineering 3.31.1 starts its codex peer through `acpx` with only `--config-option mode=read-only` and `--config-option reasoning_effort=...` (in the installed plugin, not this repository: `cross-model-adversarial-review.sh` line 437 under its `ce-code-review` skill and `cross-model-doc-review.sh` line 442 under its `ce-doc-review` skill), and no environment variable sets a service tier. The one lever left is a root `service_tier` key in `~/.codex/config.toml`. The user rejected it, because it would also move every interactive Codex session to `priority` and to 2.5x usage.

**Status on 2026-10-27.** The review peer and the `review` role still run at `default`. The account is now on ChatGPT Pro (`planType` `promax` in Codex's rate-limit reply), which has a weekly window and no 5-hour window, and the user chose Fast for the roles where oh-my-openagent uses it: Luna in `scout` and `quick`, and Sol in the Codex `root` chain and the `deep` fallback (see `docs/agent-routing.md`). That was the user's call after weighing the 2.5x cost, not a reversal of this record's billing finding, which still holds. The 5-hour figures above describe the earlier Plus account; on Pro, budget against the weekly window, which `agent-usage --json` reports.

## Why This Matters

Without this record, the next attempt repeats the same path: plan a timing benchmark, then find out partway through that the usage cap had already decided it, after spending a large share of the 5-hour window. Issue #309, which decides whether spare Codex usage can take other delegated roles, draws on the same budget, so a `priority` peer would also shrink what #309 can hand to Codex.

## When to Apply

- Before proposing `serviceTier` `priority` for any delegated Codex role.
- Before benchmarking a Codex peer, to budget the 5-hour window from the rollout figures above.
- When OpenAI changes the Fast mode multipliers or the host switches to credit or API-key billing. Under credits Fast costs 2x, which meets the cap, so the timing benchmark becomes the deciding test.

## Examples

The plan that would have run the benchmark specified replaying the 2026-10-23 peer prompt from T3 Code's state database, alternating `default` and `priority` runs. It was dropped with the issue. Replaying a captured peer prompt has fixture traps of its own, recorded in [Benchmark a cross-model review peer in T3 Code before changing its model or effort](benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md).
