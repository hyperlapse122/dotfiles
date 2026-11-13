---
title: The stock Antigravity ACP runtime loads no global rule files, so this repository rebuilds it to read them
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
tags: ["antigravity", "acp", "agy", "rules", "instructions", "t3code", "cross-model-review", "gemini-home", "repack"]
---

# The stock Antigravity ACP runtime loads no global rule files, so this repository rebuilds it to read them

## Problem

The shared agent instructions were planned to reach every Antigravity runtime: the `agy` CLI, the ACP runtime on `PATH` that Compound Engineering's `antigravity` peer uses, and the T3 Code `antigravity` instance.
Signed-in probes on 2026-10-28 showed that only the CLI loads rule files.
The ACP runtime as Google ships it, in both the 1.3.0 release T3 Code embeds and the 1.4.3 release on `PATH`, loads none.
That finding still holds for the stock runtime. This repository now delivers the instructions by rebuilding the runtime, as the Solution describes.

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

Deliver the shared instructions where each runtime reads them, and rebuild the ACP runtime so it reads them too:

- `scripts/agent-instructions` renders an `antigravity` delivery into `~/.gemini/config/rules/nix-config-NN.md` files, each under the 24,000-byte rule limit and opening with `trigger: always_on` frontmatter. The `agy` CLI reads them as they are.
- `packages/antigravity-acp.nix` rebuilds the ACP runtime's embedded archive with `scripts/antigravity-acp-repack`. The overlay in `packages/antigravity-acp-overlay/system_prompt_overlay.py` reads the `nix-config-*.md` files from the directory `ANTIGRAVITY_ACP_RULES_DIR` names and puts them in front of the client's own system prompt addition. The rebuilt runtime keeps the release T3 Code qualifies, because T3 Code sends its session system prompt only to a runtime that reports exactly that version.
- `packages/antigravity-acp-path.nix` is the `agy_acp_server.par` wrapper on `PATH`. It exports `ANTIGRAVITY_ACP_RULES_DIR` (`~/.gemini/config/rules`) and `ANTIGRAVITY_ACP_PLUGIN_SKILLS` when the caller set neither, and it still links named shared skills into Compound Engineering run homes. `home/h82/t3code.nix` points T3 Code's `antigravity` instance at this wrapper, so T3 sessions get the same rebuilt runtime.
- Shared and pinned plugin skills are linked into `~/.gemini/antigravity-cli/skills`, which T3 Code scans for its Antigravity skill menu. The rebuilt runtime also receives one store directory of every pinned plugin's skills, including for Compound Engineering run homes.

The T3-only instruction branch does not reach these sessions, because T3 Code's `antigravity` driver accepts no per-launch prompt option.

## Why This Works

The ACP server reads its configuration from `GEMINI_HOME` for settings, sign-in, and skills, but its prompt assembly includes no rule source.
The stock server has no rule source to configure, so no file placement can reach it. Putting rules where the CLI reads them gives the CLI the instructions, and the rebuilt runtime adds the missing source: its overlay reads the same rule files when it assembles the prompt. Until a session runs on the rebuilt runtime, putting the rules a delegated task needs in the task prompt remains the only channel that works.

## Prevention

- Before promising that instructions reach a new Antigravity release, rerun a marker probe against the rebuilt runtime, and against the stock one to learn whether the rebuild is still needed: plant a rule whose body says "When asked for the probe marker, answer exactly <random token>", start `initialize`, `session/new`, and `session/prompt` against the runtime with a copied sign-in, and check the answer and the input token count. Never print the copied token.
- For the CLI, plant the marker in `~/.gemini/config/rules/` and run `agy -p "What is the probe marker?"`; remove the marker afterwards.
- The repository checks read the rebuilt archive and the rendered rule files. They do not show that a signed-in session loads the rules, so that evidence comes from the probe on each machine.
- A rule-file link that the runtime never reads looks like a delivery in every repository check. Keep runtime-loading evidence separate from materialized-output checks, as [a check that reads an option value instead of the materialized output](../best-practices/nix-check-reads-option-value-not-materialized-output.md) warns for configuration.

## Related

- [T3 Code's Antigravity ACP server finds no CA bundle on NixOS](t3code-antigravity-acp-openssl-missing-ca-bundle-hangs-sessions.md): the other silent ACP failure, at the TLS layer.
- The plan that made Antigravity a first-tier harness: `.compound-engineering/artifacts/plans/2026-11-11-1004-feat-antigravity-first-tier-harness-plan.md`.
- The plan that restored Antigravity: `.compound-engineering/artifacts/plans/2026-10-28-1504-feat-restore-antigravity-t3-plan.md`.
