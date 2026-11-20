---
title: Keep Pi's question tool available on OpenAI
date: 2026-11-20
type: fix
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Keep Pi's question tool available on OpenAI

## Goal Capsule

- **Objective:** A T3 Code user can start a Pi turn on the affected OpenAI model without a tool-schema error interrupting the turn.
- **Product authority:** The user confirmed the scope below. Usage-based routing and WebSocket transport are issue-only deliverables.
- **Open blockers:** None.

## Product Contract

### Summary

Fix the request that OpenAI rejects before any tool runs. Keep the interactive question tool available and track the two independent follow-ups separately.

### Problem Frame

In [the affected thread](t3-thread://v2/1ebbbe60-ea03-4173-a7aa-74536495041f/6a6b642c-30ed-435c-a16f-f5175b1b03b8), four Pi runs on `openai/gpt-6.2-sol` failed with HTTP 400. OpenAI identified `uniqueItems` in `tools[6].parameters` as unsupported. The `question` tool declares that keyword in `home/h82/agents/pi-question.ts`; the error names the array index, not the tool.

### Key Decisions

- **Fix the rejected request first.** Governs R1, R3. (session-settled: user-directed — chosen over implementing quota preflight first: skipping Codex would still leave the Pi request failure.)

### Requirements

**Pi requests**

- R1. With `question` enabled, OpenAI must accept the tool definitions on the first request to the affected model, without retrying the request or switching models.
- R2. The question tool must still reject duplicate choices and let the user select a listed choice or type an answer.

**Follow-up issues**

- R3. Register an issue to consult `agent-usage` before native harness delegation so that a fresh result confirming exhaustion for the target model allows fallback without a failed model call. An unknown or stale result alone does not establish exhaustion.
- R4. Register a separate issue to establish the transport Pi currently uses for its OpenAI provider and use WebSocket transport for that provider.

### How This Work Fits Together

<!-- ce-section: work-relationships -->

R3 concerns the decision to launch a native harness. R4 concerns how Pi connects to OpenAI. Neither change is a prerequisite for the schema fix; this work ends with those two issues filed, not implemented.

## Planning Contract

Keep the fix in the managed question extension rather than altering every schema Pi sends to OpenAI. The provider rejects the schema before Pi receives a tool call; Pi can still reject invalid choices locally before opening a dialog.

## Implementation Units

### U1. Separate request compatibility from input validation

Remove `uniqueItems` from the array schema in `home/h82/agents/pi-question.ts`. Reject repeated strings at execution time without displaying them. Extend `tests/pi-tools.mjs`, which already loads the packaged extension and exercises both answer paths.

### U2. Track the independent changes

File the two issues in R3 and R4 and link them in the pull request without closing them.

## Verification Contract

Check the loaded tool definition for the rejected keyword and submit duplicate choices to the tool. Exercise the affected model with `question` enabled in isolation; do not use the tool's position as its identity.

## Definition of Done

The affected request passes without a schema rejection, valid answers still work, and the pull request links both open follow-ups.
