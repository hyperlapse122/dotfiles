---
title: Benchmark a cross-model review peer in T3 Code before changing its model or effort, and never rank models on one sample
date: "2026-10-22"
last_updated: "2026-10-26"
category: best-practices
module: "Cross-model review peers (home/h82/agents/synthetic-models.nix, home/h82/agents/instructions/instructions.md.tmpl)"
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - "Changing which model or reasoning effort a Compound Engineering cross-model peer runs on"
  - "A peer review takes long enough that unattended runs lose it to the no-person deadline"
  - "Comparing Synthetic models (GLM, Kimi, DeepSeek, others) as reviewers"
  - "Deciding whether one large peer or several smaller parallel peers review better"
symptoms:
  - "A GLM-5.3 max peer took 24-25.5 minutes on one doc review, longer than the 1210-second no-person peer deadline"
  - "The same model and prompt found 4 key issues on one run and 6 on another"
related_components:
  - testing_framework
tags: ["cross-model-peer", "reviewer", "benchmark", "t3-code", "delegate-task", "opencode", "synthetic", "glm", "kimi", "deepseek", "reasoning-effort", "wall-time", "opencode-db"]
---

# Benchmark a cross-model review peer in T3 Code before changing its model or effort, and never rank models on one sample

## Context

At the time of the benchmark, the shared instructions selected Synthetic cross-model review peers, with model IDs and per-role efforts in `home/h82/agents/synthetic-models.nix`. Until 2026-10-21 a Claude Code session ran one OpenCode peer, GLM-5.3 at `max`. Reviews felt slow, and the question was whether a lower effort or other Synthetic models would be faster without missing problems. Current peer selection follows each CE workflow and the shared instructions; the Synthetic source supplies model-watch data, not a universal peer roster or T3 startup selection.

Nothing in the repository measured a peer's wall time or coverage, and published benchmarks did not answer it: Artificial Analysis listed GLM-5.3 only at `max` as of 2026-10-21, and Compound Engineering 3.31.0's own peer scripts pick "one model per provider at high reasoning" without numbers for OpenCode models. The answer came from a benchmark run inside T3 Code on a real peer prompt. Two things from it are not recoverable from the final code: how to run such a benchmark so the numbers mean something, and the numbers themselves.

## Guidance

**Reuse the exact prompt a real peer received.** Take a live peer task's first message from T3 Code's state database rather than writing a new prompt:

```sh
sqlite3 -readonly "file:$HOME/.t3/userdata/statev2.sqlite?mode=ro" \
  "select payload_json from orchestration_v2_projection_messages where message_id='message:delegated-task:<encoded task id>';" \
  | jq -r .text > prompt-full.txt
```

The stored text starts with T3 Code's role preamble (`Act as the review sub-agent for this task.`), so launch each benchmark run with `role: "review"` and the rest of the text as `task`, then read the sent message back the same way and `cmp` it against `prompt-full.txt`. A paraphrased or truncated prompt measures a different review.

A delegated thread can disappear when T3 Code compacts its state: on 2026-10-21 a `delegated-task:` thread from earlier the same day returned `thread_not_found`, and neither `statev2.sqlite` nor the OpenCode database still held it. Capture the prompt while the peer is live, or wait for the next real review to launch one.

**Rebuild the fixture the original peer saw, not just its prompt.** A captured prompt points at a reviewed checkout and a scratch directory by path, and both change after the review ends. On 2026-10-23 the prompt of a `ce-code-review` Codex peer named the checkout `~/.t3/worktrees/nix-config/t3-dbe265a0`. That review had covered base `9574dcd` plus uncommitted edits on `5047b1b`, the state its scratch `full.diff` records. By the time of the replay, the checkout sat at `5726717`, which already held the review's fixes, so a replay there would review a different tree. The scratch directory had also gained the rest of that review's outputs after the peer launched: `review.json`, `synthesized-findings.json`, the other reviewers' JSON, and the peer's own `adversarial-codex.json`. A replayed peer may read any of them. Before each run, rebuild the reviewed tree on the same path (base plus `full.diff`, checked against `full.diff`), and reset the scratch directory to the files whose modification time predates the peer's `startedAt`. For a code-review peer, that set was `full.diff`, `files.txt`, `intent.md`, `reviewer-brief.md`, `adversarial-review-brief.md`, and `adversarial-review-constraints.md`. Restore the checkout to its branch afterwards. Budget Codex usage too: one default-tier `gpt-6.1-sol` `xhigh` review took about 9 percent of the 5-hour window (see [The Codex priority service tier costs 2.5x subscription usage](codex-priority-tier-costs-2-5x-subscription-usage-for-review-peer.md)).

**Run the candidates one at a time, with the same isolation as a real peer.** The historical runs used `delegate_task`, `isolation: "worktree"`, `runtimeMode: "full-access"`, and OpenCode's `{"variant": "high"}` in `target.options`. For a new run, discover the provider's current option descriptors and preserve the owning workflow's permission and isolation requirements. A worktree alone does not enforce read-only execution. `task_status` reports the returned model selection and options; these confirm configuration receipt, not actual serving identity or independently attested reasoning effort.

OpenCode and Pi are now retired. The unified `omp` instance offers Synthetic and selected OpenRouter models alongside native Codex subscription discovery, with effort passed as `thinking` in `target.options`. The former `omp-codex` entry is removed by settings reconciliation. The OpenCode options, instance, database, and measurements below remain historical evidence from 2026-10-21. They do not establish current OMP performance or authorize changing its default model.

**Time the run, not the setup or the last step.**

- Wall time is the child run's `startedAt` to `completedAt`, both in `payload_json` of `orchestration_v2_projection_runs` (and in `t3_thread_read`'s `recentRuns`), which excludes worktree preparation.
- OpenCode's `~/.local/share/opencode/opencode.db` holds tokens and cost per session in `session_v2`, found by the worktree path in `directory`. Its `time_updated` is the last step, not completion: read mid-run on 2026-10-21, a GLM-5.3 `max` peer showed 1249 s there while its run was still going; it finished at 1444 s.

**Score coverage against a verified issue list, not finding counts.** Merge every run's findings, check each against the reviewed document and the repository, keep the real ones as a key-issue list, and count how many each run found. Mark false positives separately: two models flagged a "missing" archived plan that the prompt itself said was an uncommitted parent edit.

**Take at least two samples before ranking.** Same model, same prompt, two runs:

| Run | Wall time | Key issues |
| --- | --- | --- |
| GLM-5.3 `max` | 24:04, 25:28 | 6, 4 |
| Kimi K3 `high` | 13:35, 10:08 | 3, 3 plus the one P1 any run found (an eleventh issue, found only by the second run) |
| GLM-5.3-Flash `high` | 19:17, 10:14 | 3, 1 |

Kimi's two runs found almost disjoint issue sets. One sample can put a model on either side of another, so a decision from one run is a coin flip. Peers from different families find different things, which is why two parallel smaller peers can cover more than one larger peer.

## Why This Matters

The 2026-10-21 numbers on one 25 KB doc-review prompt (time, key issues of 10, OpenCode's cost in USD):

| Model and effort | Wall time | Key issues | Cost |
| --- | --- | --- | --- |
| GLM-5.3 `max` | 24:04-25:28 | 4-6 | 0.77-0.92 |
| GLM-5.3 `high` | 20:29 | 3 | 1.31 |
| GLM-5.3 `low` | stopped after 14:03 | 0 | - |
| GLM-5.3-Flash `max` | 14:22-16:55 | 1-2 | 0.085 |
| GLM-5.3-Flash `high` | 10:14-19:17 | 1-3 | 0.06-0.11 |
| Kimi K3 `high` | 10:08-13:35 | 3, plus the P1 once | 1.01-1.62 |
| DeepSeek V4.1 Flash 1017 `max` | 47:38 | 5 | 0.46 |
| DeepSeek V4.1 Flash 1017 `high` | 100:42 | 4 | 1.03 |

- GLM-5.3 `max` always overran the 1210-second no-person deadline the instructions give a peer batch, so every unattended review lost its only peer.
- GLM-5.3 `low` fell into a reasoning loop: about 210,000 characters of one-word variants of "read", "go", and "begin", with no tool call and no output, until it was stopped. The catalog offering an effort does not make it usable.
- DeepSeek found 4-5, within the range GLM-5.3 `max` found, and took two to four times as long; `high` was slower than `max`, with 11 M cache-read tokens from long exploration.
- MiniMax M3 and Qwen3.6 27B returned `Model unavailable` because they had left the live Synthetic catalog (`https://api.synthetic.new/openai/v1/models`), though T3 Code's model catalog (`orchestrator_capabilities`) still listed them at the time. Check the catalog before benchmarking a candidate.
- Three Synthetic peers launched together finished in 15:22 with no slowdown; Flash `high` even ran faster concurrent than alone. Parallel peers cost the slowest member's time, not the sum.
- Cost does not track effort: GLM-5.3 `high` cost more than `max` because it read more input.

Without these, the next change repeats the guess the original `max` pin was: a higher effort assumed to review better, with no measure of what it costs in time or whether it finishes at all.

## When to Apply

- Before changing a `reviewer` role effort or a candidate in `home/h82/agents/synthetic-models.nix` or wherever peer model and effort are configured for the workflow under review.
- When a reviewer model is bumped (the `synthetic-models-watch` workflow reports a newer build), to re-measure rather than assume the new build times like the old one.
- When adding a peer family, to confirm it is in the live catalog and finishes inside the deadline.

## Examples

The decision that followed (plan dated 2026-10-22, on branch `feature/parallel-review-peers`): a `claude` host runs GLM-5.3-Flash and Kimi K3, both at `high`, in parallel, and GLM-5.3 `max` runs only when the user names it. The plan is `.compound-engineering/artifacts/plans/2026-10-22-0413-feat-parallel-review-peers-plan.md`; its Sources table carries every run. A code-review diff was not measured, so the follow-up is the same benchmark on a diff before revisiting the `glm` host default or the Flash effort.

Related: [T3 Code delegated waits end the turn because t3_thread_wait cannot carry in-turn delegation waits alone](../integration-issues/t3-thread-wait-cannot-carry-in-turn-delegation-waits-alone.md) holds the peer-deadline rule the timings are measured against (`CROSS_MODEL_HARD_SECS` plus 10 seconds, 1210 seconds by default in the instructions template).
