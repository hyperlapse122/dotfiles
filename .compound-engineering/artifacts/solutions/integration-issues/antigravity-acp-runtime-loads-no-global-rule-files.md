---
title: The Antigravity ACP runtime loads no global rule files, so shared instructions reach only the agy CLI
date: "2026-10-28"
category: integration-issues
module: Antigravity CLI, ACP runtime, and the shared agent instructions delivery
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "A marker rule planted in $GEMINI_HOME/config/rules/ never reaches an ACP session; asked for the marker, the model answers NONE"
  - "ACP input token counts are identical with and without rule files present"
  - "The same marker rule in ~/.gemini/config/rules/ is answered correctly by agy -p"
root_cause: config_error
resolution_type: config_change
related_components:
  - documentation
retire_when: "An Antigravity ACP release answers a marker rule placed in $GEMINI_HOME/config/rules/ (or another documented global location) during a signed-in session/prompt"
tags: ["antigravity", "acp", "agy", "rules", "instructions", "t3code", "cross-model-review", "gemini-home"]
---

# The Antigravity ACP runtime loads no global rule files, so shared instructions reach only the agy CLI

## Problem

The shared agent instructions were planned to reach every Antigravity runtime: the `agy` CLI, the ACP runtime on `PATH` that Compound Engineering's `antigravity` peer uses, and the T3 Code `antigravity` instance.
Signed-in probes on 2026-10-28 showed that only the CLI loads rule files.
The ACP runtime, in both the 1.3.0 release T3 Code embeds and the 1.4.3 release on `PATH`, loads none.

## Symptoms

- An ACP session asked for a marker defined in a planted rule answers `NONE`.
- Input token counts stay the same with and without rule files, so nothing is injected.
- `agy -p` (CLI 1.4.9) answers the same marker from `~/.gemini/config/rules/`.

## What Didn't Work

Each of these locations was tried against the 1.3.0 runtime in a scratch `GEMINI_HOME` holding a copied sign-in, and none reached the session:

- `$GEMINI_HOME/config/rules/` holding a real file, a file symlink, and a symlinked directory;
- `$GEMINI_HOME/config/AGENTS.md`, `$GEMINI_HOME/config/GEMINI.md`, and `$GEMINI_HOME/GEMINI.md`;
- `$GEMINI_HOME/antigravity-acp/rules/`, `$GEMINI_HOME/antigravity-acp/GEMINI.md`, and `$GEMINI_HOME/antigravity-acp/AGENTS.md`;
- `HOME` pointed at a scratch home holding `~/.gemini/config/rules/` and `~/.gemini/GEMINI.md`;
- a workspace git repository holding `AGENTS.md`, `GEMINI.md`, and an `.agents/rules` directory.

The 1.4.3 runtime gave the same negative result.
The `localharness_external` binary documents `~/.gemini/config/` as the customization root with a `rules` directory, `AGENTS.md`, and `GEMINI.md`, but that documentation describes the CLI, not the ACP server.

## Solution

Deliver the shared instructions only where they load, and say so where agents read it:

- `scripts/agent-instructions` renders an `antigravity` delivery into `~/.gemini/config/rules/nix-config-NN.md` files, each under the 24,000-byte rule limit and opening with `trigger: always_on` frontmatter (`scripts/agent-instructions:22-24`, `rule_files` at `scripts/agent-instructions:79`).
- The `PATH` wrapper links only skills into CE run homes, and its header records why it links no rules (`packages/antigravity-acp-path.nix:21-22`).
- The instruction template tells delegating agents that Antigravity ACP sessions load none of the instructions, not even a repository's `AGENTS.md`, so every rule a delegated task needs goes in its prompt (`home/h82/agents/instructions/instructions.md.tmpl:213`).

Skills still reach every runtime: T3 Code links `~/.gemini/antigravity-cli/skills` into each instance home, and the wrapper links named skills into CE run homes.

## Why This Works

The ACP server reads its configuration from `GEMINI_HOME` for settings, sign-in, and skills, but its prompt assembly includes no rule source.
Putting rules where the CLI reads them gives the CLI the instructions, and moving the rules for ACP sessions into the task prompt is the only channel the runtime honors.

## Prevention

- Before promising that instructions reach a new Antigravity release, rerun a marker probe: plant a rule whose body says "When asked for the probe marker, answer exactly <random token>", start `initialize`, `session/new`, and `session/prompt` against the runtime with a copied sign-in, and check the answer and the input token count. Never print the copied token.
- For the CLI, plant the marker in `~/.gemini/config/rules/` and run `agy -p "What is the probe marker?"`; remove the marker afterwards.
- A rule-file link that the runtime never reads looks like a delivery in every repository check. Keep runtime-loading evidence separate from materialized-output checks, as [a check that reads an option value instead of the materialized output](../best-practices/nix-check-reads-option-value-not-materialized-output.md) warns for configuration.

## Related

- [T3 Code's Antigravity ACP server finds no CA bundle on NixOS](t3code-antigravity-acp-openssl-missing-ca-bundle-hangs-sessions.md): the other silent ACP failure, at the TLS layer.
- The plan that restored Antigravity: `.compound-engineering/artifacts/plans/2026-10-28-1504-feat-restore-antigravity-t3-plan.md`.
