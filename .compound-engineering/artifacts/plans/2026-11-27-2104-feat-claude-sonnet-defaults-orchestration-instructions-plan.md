---
title: Claude Code Sonnet defaults and an orchestration preference for every managed harness
type: feat
date: 2026-11-27
topic: claude-sonnet-defaults-orchestration-instructions
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Claude Code Sonnet defaults and an orchestration preference for every managed harness

## Goal Capsule

- **Objective.** A new Claude Code session on the owner's machines starts on Sonnet at medium effort, and every managed harness (Claude Code, OpenCode, omp) is told to split independent work across subagents while handling small or tightly coupled edits directly.
- **Means.** Change the declared `model` in `settingsTier`, and add one paragraph to the shared user-scope instruction template, with a Claude-only addition for `Workflow`.
- **Product authority.** The owner's choices below. They chose not to enable Ultracode by default after a `ce-pov` review.
- **Open blockers.** None. Two facts are verified during U1 (see KTD2).
- **Delivery.** One pull request, finished and shipped by the implementing agent under `AGENTS.md`. No host switch is run.

## Product Contract

### Summary

Claude Code defaults move from Opus to Sonnet, with effort kept at medium and the advisor kept at `fable`. Ultracode stays an opt-in for a single session. All three managed harnesses receive the same short orchestration preference through the shared instruction template.

### Key Decisions

- **Ultracode is not enabled by default.** Governs R3. (session-settled: user-approved after `ce-pov` — chosen over declaring `ultracode: true`.) A default-on setting raises token and time cost on every request, lifts the large-workflow warning and the concurrent-subagent limit, and skips the first workflow approval in auto mode. This repository already declares `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=20`, and `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1`. The earlier delegation experiment (`.compound-engineering/artifacts/feedback-sweep/optional-delegation-evaluation.md`) kept the current routing policy.
- **The preference goes to all managed harnesses.** Governs R4, R5. (session-settled: user-directed — chosen over a Claude-only instruction.)
- **Instructions cannot grant the `Workflow` opt-in.** Governs R5. (session-settled: judgment — the tool requires the user's own words or Ultracode, so the instruction only names it as available after that opt-in.)

### Requirements

**Defaults**

- R1. A rebuild declares `model = "sonnet"` and keeps `effortLevel = "medium"` and `advisorModel = "fable"` for Claude Code. The stale `opus[1m]` mentions in the comment, README, and tests are updated.
- R2. A fresh Claude Code session started with the declared settings runs Sonnet at medium effort. If the user-settings `effortLevel` does not reach Sonnet, the declaration uses the mechanism that does.
- R3. `ultracode` is not declared. `/effort ultracode` and the `ultracode` keyword keep working for one session.

**Instructions**

- R4. The shared template renders one orchestration paragraph for Claude Code, OpenCode, and omp: with several independent units, prefer CE skill dispatch or subagent orchestration; do small or tightly coupled edits directly.
- R5. Only the Claude Code render mentions `Workflow` and Ultracode, stating that they require the user's own opt-in. OpenCode and omp renders do not mention them.
- R6. The paragraph is plain English prose that `ce-noslop` accepts.

### Key Flows and Acceptance Examples

- F1. After a rebuild, the user starts Claude Code and runs `/model` and `/effort`. Covers R1, R2.
- AE1. The settings file written by activation holds `model: "sonnet"`, `effortLevel: "medium"`, `advisorModel: "fable"`, and no `ultracode` key. Covers R1, R3.
- AE2. The delivered `~/.claude/CLAUDE.md` contains the paragraph and the Claude-only sentence; `~/.config/opencode/AGENTS.md` and `~/.omp/agent/AGENTS.md` contain the paragraph and neither of the words `Workflow` and `Ultracode`. Covers R4, R5.

### Scope Boundaries

Out of scope: enabling Ultracode by default, changing `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` or `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, and changing OpenCode or omp model settings.

## Planning Contract

- KTD1. **Edit the shared template, not per-harness files.** `home/h82/agents/instructions/instructions.md.tmpl` already receives `.claude`, `.opencode`, and `.omp`. The common paragraph sits outside any branch and the `Workflow` sentence sits in `{{ if .claude }}`. This follows `docs/contributing.md` "User-scope harness instructions". Covers R4, R5.
- KTD2. **Verify the effort path before declaring it.** Documentation says a top-level `effortLevel` in user settings does not apply to Opus 5.5 and later models, and does not say whether it applies to Sonnet 5.5. Measure it on a copied config directory as `.compound-engineering/artifacts/solutions/integration-issues/claude-code-global-config-keys-ignored-in-settings-json.md` describes, so the real settings file is never touched. If it does not apply, declare the per-model value in the file where Claude Code reads it, and keep the merger's rule that `modelSettings` written by `/effort` survives rebuilds. Also check whether `sonnet` already selects the 1M window, and drop the `[1m]` wording from the comment if so. Covers R1, R2.
- KTD3. **Receipts stay byte-exact.** `tests/agent-instructions.py` currently asserts an empty render. Replace that with the exact rendered bytes checked against `tests/lib/agent-instruction-receipts.json`. The `nixos-claude` and `darwin-claude` keys already exist and take the Claude digest. OpenCode and omp fall back to the `nixos` and `darwin` keys. The existing branch probe and the negated-text mutations keep working because a full digest sees any added word. Covers R4, R5.

## Implementation Units

### U1. Declare the Sonnet default

Change `model` in `settingsTier` of `home/h82/agents/claude.nix` and rewrite its comment. Resolve the two facts in KTD2 first and follow their outcome. Update the mirrored declarations in `tests/claude.nix` (the declared set near line 92 and the fixture near line 399) and `tests/test_agent_settings.py` (`DECLARED` and the two assertions). Update the README Claude Code paragraph that names `opus[1m]`. Keep the existing test that an effort level stored per model survives the merge. Covers R1–R3.

### U2. Add the orchestration paragraph

Write the paragraph in `instructions.md.tmpl` through `ce-noslop`, keeping the template's source comments out of the render. Add the `.claude` branch sentence. Replace every empty-output assertion in `tests/agent-instructions.py` (`assert text == ''` in `exercise`, `omp_destination.read_bytes() == b''` and `destination.stat().st_size == 0` in the activation block) with a receipt or content check, compute the three digests from the real renderer, and update `tests/lib/agent-instruction-receipts.json`. Keep independent assertions that OpenCode and omp renders lack `Workflow` and `Ultracode` and the Claude render has them. Covers R4–R6.

### U3. Update the documents that describe the render

Rewrite the byte-empty statements in `docs/agent-routing.md` (line 3) and in `docs/contributing.md` (the two "User-scope harness instructions" bullets) so they describe the rendered paragraph and the digest rule. Covers R4, R5.

## Verification Contract

Run `./scripts/agent-check` from the checkout root, or `nix develop .#agent-check -c ./scripts/agent-check`. Run the focused `claude` and `agent-instructions` checks, and `agent-instructions` again because `docs/agent-routing.md` changes. Report the measured effort result for Sonnet from U1. Do not run `nr switch`, `darwin-rebuild switch`, or `nixos-rebuild switch`.

## Definition of Done

The declared Claude Code settings hold Sonnet at medium effort with no `ultracode` key, and the measured effort path is recorded in the PR. All three harness instruction files carry the paragraph and only the Claude file names `Workflow`. Receipts, tests, README, and the two documents agree, and `agent-check` passes.

## Sources

- `ce-pov` judgment in the session on enabling Ultracode by default (Reject).
- Claude Code documentation on Ultracode and the `ultracode` settings key, read through a research subagent: [workflows](https://code.claude.com/docs/en/workflows.md) and [settings reference](https://code.claude.com/docs/en/settings-reference.md)
- `.compound-engineering/artifacts/feedback-sweep/optional-delegation-evaluation.md`
