---
title: "Codex implementation workers use xhigh after a 30-run replay"
date: "2026-11-13"
category: best-practices
module: "T3 delegation and CE model selection"
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Changing the model or effort of a delegated Codex implementation worker"
  - "Comparing a higher Terra effort with promotion to Sol"
  - "Replaying an agent task in T3-created worktrees"
tags: ["codex", "reasoning-effort", "t3-code", "benchmark", "implementation-workers"]
retire_when: "The Codex ladder models or task distribution change, or a repeat using the recorded protocol selects another setting"
---

# Codex implementation workers use xhigh after a 30-run replay

Thirty runs selected `gpt-6.1-terra` at `xhigh` under the owner's rule: keep settings
within one success of the highest count, then choose the lowest median total
tokens over ten runs. Terra/xhigh succeeded 9/10 times; Sol/high succeeded 10/10.
Their medians were 2,145,125 and 2,610,341 total tokens. Terra/high succeeded 0/10
and was ineligible, despite its lower token use.

This branch changes the T3-only instructions to request `xhigh` for middle-rung
Codex implementation workers. Other Codex children retain `high`, and an explicit
user or CE configuration effort still takes precedence. The model ladder stays
unchanged. This is the agreed threshold's outcome on these tasks, not a general
ranking of the models.

## Context and protocol

The [source session](t3-thread://v2/1ebbbe60-ea03-4173-a7aa-74536495041f/bebc053a-c9b7-469b-aa7b-041409e9b586)
first used Terra/high for console help copy. One worker returned without changes;
a narrower worker wrote generic copy. Sol/high later finished the feature on a
sharper brief with existing draft files, so that history could not isolate model
from prompt and starting state.

The controlled replay used Codex CLI 0.167.2 and the two actual original worker briefs: a wide task
covering the help catalog and UI, and a narrow catalog task. Each ran five times
at Terra/high, Terra/xhigh, and Sol/high, always with service tier `default`.
The [measurement session](t3-thread://v2/1ebbbe60-ea03-4173-a7aa-74536495041f/mcp:launch:bd7936bae71bd854394755b05d47891d3cf3c5298639d4fb3f93cb8af3a7bf08)
created separate T3-managed worktrees in the source project at the original
baseline, `3bf8c54876db80ee3503f1928dbea9d7cac6db73` (an external repository commit,
not a commit in this flake).

Original stored prompts were replayed with only the approved checkout and branch
identifiers substituted. The absent original checkout became `.`, and its branch
name became `the current branch`. Every stored first message matched the expected
text, including exactly one T3 implementation-role preamble. The wide brief's
research files were preserved at their original paths. Batches alternated wide
and narrow, with one fresh worker per setting and at most three at once.

A valid run required successful verified preparation and natural completion.
Returning early or leaving incomplete work was a valid failure. Infrastructure
failures or external interruptions would be recorded and replaced. None occurred
in the accepted thirty-run wave.

Success required the brief's named files, its verification commands rerun by the
scorer, and both fixed copy assertions: distinct purpose and usage lines across
all twenty menus in each language, and no step shared by more than two menus.
Wide runs also had to complete the UI. Scores came from files and command logs,
not worker summaries. The scorer was frozen before measurement; its five controls
proved baseline failure, known catalog success, known complete-feature success,
wide catalog-only failure, and isolated copy-only failure. The last control
removed the known-good fixture's duplicate copy assertion before introducing one
step shared by three menus, so the extra check was tested independently.

Wall time spans the first and last native session timestamps. Tool calls count
`response_item` entries of type `custom_tool_call`, `function_call`, or
`local_shell_call`, once each. Reasoning and total tokens come from the final
`token_count` entry's `total_token_usage`. These rules reproduced the historical
wide failure's four calls, 203 reasoning tokens, and 250,396 total tokens.

## Results

All six cells contain five valid runs. No run was replaced. Wide catalog-only
failures were zero in every cell.

| Brief | Setting | Valid | Success | No file | Copy only | Wide catalog only | Median seconds | Calls | Reasoning tokens | Total tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| wide | terra/high | 5 | 0 | 5 | 0 | 0 | 31.947 | 5 | 186 | 300,976 |
| wide | terra/xhigh | 5 | 4 | 1 | 0 | 0 | 579.378 | 56 | 4,105 | 7,033,080 |
| wide | sol/high | 5 | 5 | 0 | 0 | 0 | 511.448 | 30 | 3,693 | 3,692,598 |
| narrow | terra/high | 5 | 0 | 0 | 5 | N/A | 133.567 | 15 | 358 | 757,493 |
| narrow | terra/xhigh | 5 | 5 | 0 | 0 | N/A | 287.662 | 26 | 1,647 | 1,956,552 |
| narrow | sol/high | 5 | 5 | 0 | 0 | N/A | 329.935 | 18 | 1,803 | 1,415,947 |

| Setting | Success / 10 | Median total tokens | Selection |
| --- | ---: | ---: | --- |
| Terra/high | 0 | 567,314 | Outside the one-success band |
| Terra/xhigh | 9 | 2,145,125 | Selected |
| Sol/high | 10 | 2,610,341 | Eligible; higher pooled median |

The pooled median selected Terra/xhigh, but the wide task's median was higher
than Sol/high's. This rule does not minimize aggregate tokens or wall time.
The thirty sessions used 74,673,154 total tokens, 758 tool calls, and 57,356
reasoning tokens. Totals include repeated cached input and are not monetary cost
or a share of the subscription limit. Pilot costs are excluded.

The [per-run ledger](codex-worker-tier-measurement-2026-11-13.csv) preserves all
thirty scores, metrics, verbatim T3 thread links, native session IDs, and SHA-256
hashes of the original session files. Original sessions remain in the local Codex
session store; the ledger contains no source code, credentials, or full transcripts.
Root independently recomputed all thirty native metrics, inspected each score and
preparation receipt, and reproduced the selected setting.

## Preparation failures and the accepted environment

An earlier wave of fifteen attempts is historical only. Seven of its first twelve
natural completions had dotagents preparation errors, and the last batch had three
invalid attempts. Five scored runs had complete preparation logs, but their full
tool bundle identity was unproven. None enters the table above. Those attempts
used 37,012,674 recorded total tokens and 365 tool calls, separately from the new
sample.

The effective T3 setup was an existing project override running `mise install -yq`,
even though the project object exposed an empty scripts array. Concurrent
processes of dotagents 3.4.0 raced on shared shallow Git caches. Later successful
Yarn steps left an overall zero setup status. One partial install left unignored
tool files that the scorer counted as modifications. A successful pilot or a
zero final status therefore did not establish successful preparation for each run.

The owner approved a fresh wave with fixed tool materialization, isolated caches,
and a gate before agent startup. The accepted bundle recorded 56,238 normalized
files, directories, and symlinks, including modes, hashes, source commits, ignore
rules, runtime configuration, Node dependencies, and hook-engine bytes. Replay
used baseline lockfiles without moving-source fetches. Only checkout and private
cache roots were relocated. Its manifest SHA-256 was
`d5dadfa89c8ecdea7e0259addd5889829b3db8e8cf8d35f83adf5e99522266df`.

File identity alone was insufficient. A first runtime pilot saw all requested
environment variables unset despite the copied project config. Codex documents
that untrusted projects skip their project-local configuration. A fresh pilot
using a temporary trust entry for only its exact task-owned worktree path received
all six intended values. The source project, common Git directory, and ancestor
paths were never trusted by the measurement. The entry was removed after each
worker. See [OpenAI's configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
The pilot establishes this route worked; it does not prove trust was the only
possible explanation for the earlier failed route.

The accepted pilot also proved the pinned Impeccable 0.1.23 engine hash and probe,
local Toss MCP 0.0.31 registration, and the unchanged Intent command resolving to
0.5.6 from an offline private npm cache. Node was 26.12.1, Yarn 4.18.1, TypeScript
7.0.2, and Vitest 5.0.5. It passed the baseline web suite of 85 files and 1,385
tests, typecheck, i18n checks, and lint. A missing required craft-floor file was
rejected with setup exit 86 before an agent started. Both positive and negative
pilots passed before preparation was frozen.

Every accepted run has a matching manifest receipt and first-message comparison.
After collection, worker and pilot worktrees, branches, dependency trees, caches,
extra trust entries, and tool processes were removed. No containers or volumes
were created. The effective T3 setup values were restored while preserving
unrelated configuration. The protected source stayed clean on main at
`515991306d3577fa951af848bcb6c0a9cf2a2df3` (external repository).

## Limits and reuse

- Two briefs in one repository and five runs per cell separate only large
  differences. One Terra/xhigh wide run returned without changes; Sol/high had no
  measured failures. Neither count establishes reliability on unrelated tasks.
- The tasks required investigation. Settled implementation units were not
  measured, although the approved instruction change applies to all middle-rung
  Codex implementation workers. The sample supplies no measured benefit there.
- The copy assertions test uniqueness, not every semantic claim in the help text.
  The original verification commands were run once by the scorer; worker recovery
  exercises and intermediate failures remain in their session records.
- Requested T3 options and native session settings agreed, but are not independent
  attestation of the actual serving model or effort.
- The shared host and account can affect timing. Keep service tier separate from
  reasoning effort, and retain raw counters rather than estimating account usage.

Before repeating the comparison, recover the exact briefs and baseline from the
linked T3 records, validate the scorer controls, freeze the effective preparation,
and verify it for every run. Preserve failed preparations separately. Change the
selection rule only before collecting a new sample.

Related: [earlier Codex effort measurement](codex-child-give-up-rate-by-reasoning-effort.md),
[review-peer replay protocol](benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md),
and [priority-tier subscription usage](codex-priority-tier-costs-2-5x-subscription-usage-for-review-peer.md).
