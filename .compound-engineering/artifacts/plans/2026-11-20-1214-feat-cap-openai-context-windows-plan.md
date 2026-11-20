---
title: OpenAI Context Window Cap - Plan
date: 2026-11-20
type: feat
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# OpenAI Context Window Cap - Plan

## Goal Capsule

- **Objective:** Keep repository-managed OpenAI context windows within the size of OpenAI's short-input pricing tier.
- **Means:** Declare the cap in generated configuration and apply it when each harness resolves a model (KTD1, KTD2).
- **Authority:** [Issue #267](https://github.com/hyperlapse122/dotfiles/issues/267) defines scope; repository instructions govern verification and shipping.
- **Execution:** One pull request. The implementer verifies the generated configuration and leaves merge to the owner. Stop if either harness cannot apply the cap without increasing a smaller declared limit.

## Product Contract

### Summary

Apply an effective context-window cap to the direct OpenAI chat models managed by the repository.

### Problem Frame

The shared OpenAI snapshot contains context windows of 1,050,000 tokens. [OpenAI pricing](https://developers.openai.com/api/docs/pricing?context-length=long) puts requests above 272,000 **input** tokens in the long-context tier for models such as [GPT-6.2 Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol). The configured context window is a budgeting policy, not a measurement of billed input or a hard per-request billing guarantee.

### Requirements

- R1. Set each repository-managed OpenAI context window to the smaller of its existing limit and the integer `272000`.
- R2. Leave other providers, output limits, and transport unchanged.

### Scope Boundaries

The policy covers the direct `openai` models declared by the shared Pi and OpenCode list. Codex and T3 select models but do not configure their context windows. Models supplied solely by a harness or by another provider, including OpenCode Go, are outside this change. WebSocket configuration belongs to #264.

## Planning Contract

### Key Technical Decisions

- KTD1. **Cap the generated configuration, not the snapshot.** Both consumers read `home/h82/agents/openai-models.json`. Keep the source metadata and scheduled updater unchanged so a refresh does not undo the policy. Share the limit between the consumers.
- KTD2. **Treat Pi's per-model cap as a ceiling, not a replacement value.** Pi applies `modelOverrides` after loading its catalog overlays, so a fixed `contextWindow` override could raise a smaller limit from a refresh. Add a cap field to Pi's model overrides and take the minimum of the declared cap, the resolved window, and any window in the current catalog for the same chat model. Keep the existing rules for adding missing models.

## Implementation Units

### U1. Apply the cap to Pi and OpenCode

- **Requirements:** R1, R2. **Dependencies:** None.
- **Files:** `home/h82/agents/pi.nix`, `home/h82/agents/opencode.nix`, a shared cap under `home/h82/agents/`, `packages/pi-runtime.nix` and its source patch, `tests/pi-runtime.py`, `tests/opencode.nix`, and `docs/repository-reference.md`.
- **Approach:** Declare KTD2 overrides for the shared OpenAI list. Set OpenCode's `limit.context` only for the declared `openai` provider. Document the cap and its distinction from upstream metadata.
- **Patterns to follow:** Pi's offline RPC model probe and OpenCode's activation check against an isolated settings file.
- **Test scenarios:**
  - Pi offers a repository-supplied GPT-6.2 model at `272000` and changes no non-context fields in the listed built-in models.
  - OpenCode activation writes `272000` for the listed GPT-6.2 models without altering output limits, other providers, or user-owned entries.
  - Pi reads a newer cached OpenAI catalog overlay. A limit below `272000` stays below the cap, and a higher one is reduced.
- **Verification:** Check Pi's effective runtime model list and OpenCode's materialized settings with the existing flake checks.

## Verification Contract

Build `.#checks.x86_64-linux.pi` and `.#checks.x86_64-linux.opencode`. Use the repository's pre-push and full CI requirements in `AGENTS.md`.

## Definition of Done

Both harness checks demonstrate R1 and R2. Only the policy, its checks, and its documentation remain in the diff.
