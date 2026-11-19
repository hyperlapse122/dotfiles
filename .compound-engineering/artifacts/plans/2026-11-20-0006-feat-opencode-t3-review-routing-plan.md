---
title: OpenCode T3 Review Routing - Plan
type: feat
date: 2026-11-20
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# OpenCode T3 Review Routing - Plan

## Goal Capsule

- **Objective:** A user running a CE review from OpenCode in T3 gets a second model's judgment without a second harness for the automatic route.
- **Means:** Route the peer through the current OpenCode instance and authorize OpenCode in the shared review allowlist (KTD1, KTD2).
- **Authority:** The Product Contract defines scope. The Planning Contract defines the route and its delivery. Existing CE egress and review rules govern everything not changed here.
- **Execution profile:** One PR. The implementer verifies the change and hands it to the shipping workflow; no host switch is part of this work.
- **Stop conditions:** Stop if the proposed route needs a weaker CE check than the Product Contract allows.

## Product Contract

### Summary

Make the current OpenCode instance the automatic route for `ce-doc-review` and `ce-code-review` peers in T3. Select a different model family without switching harnesses.

### Problem Frame

The shared T3 instructions preserve CE's usual harness routing even when the current OpenCode instance already offers the selected peer family. The owner does not need a separate Claude Code or Codex launch for those reviews.

### Requirements

**Routing**

- R1. When either review skill activates a peer in T3 OpenCode, use the same OpenCode instance to request an eligible model from a family different from the host's attested serving family.
- R2. Preserve CE's target preference order and respect any explicitly bound harness or route. If the same-instance path fails or is unavailable, follow CE recovery and report the gap without automatically switching harnesses.
- R3. Allow the OpenCode route in all managed sessions, without changing default routing outside T3 OpenCode or outside the two review skills.

**Disclosure and evidence**

- R4. Preserve CE's review gates and result validation. Before any OpenCode peer dispatch, check and disclose both OpenCode and the concrete serving recipient. Report the T3 isolation limit and do not treat a requested model as proof of independence.

### Key Decisions

- **Keep the automatic peer in OpenCode.** (session-settled: user-approved — chosen over starting a separate review harness: the OpenCode instance already exposes models from multiple families.) Governs R1.
- **Allow OpenCode in all managed sessions.** (session-settled: user-directed — chosen over a T3 OpenCode-only allowlist entry: other sessions should be able to select the OpenCode route.) Governs R3.

## Planning Contract

### Key Technical Decisions

- KTD1. **Keep peer preference separate from dispatch.** Honor CE's preference order: conversation, checkout config, active project instructions, then defaults. A family preference chooses a family, not a harness. Requests that explicitly bind a route keep it. An OpenCode target without a family uses the first eligible CE family from its current instance. Pass the current `providerInstanceId` and a catalog-qualified model to `delegate_task`. Apply the ladder by serving family and resolve effort from OpenCode's options. Do not fall back to the host family or replace a pinned model or effort. Governs R1 and R2.
- KTD2. **Register OpenCode alongside the other installed review harnesses.** Use `my.agents.crossModelPeers` so the same managed list reaches shells and GUI sessions. Deliver common instructions to all managed harnesses to bind a concrete OpenCode provider/model and check each recipient before sending review material. If the route would use Auto, an unknown intermediary, or an unlisted recipient, report it as unavailable instead of dispatching. Governs R3 and R4.
- KTD3. **Distinguish a model selection from run evidence.** Use a runtime-published serving identity to establish the host family. If T3 does not publish it, OpenCode's completed assistant-message metadata for the current session can identify the request that actually produced a response. Use only same-session, run-correlated metadata; never rely on a catalog, configured model, child self-report, or unrelated history. Do not promote agreement without the identity evidence CE requires for the peer too. Governs R1 and R4.

### Grounding

`home/h82/t3code.nix` already provides the selected harness flag to the renderer. `home/h82/agents/cross-model-peers.nix` renders the shared allowlist from harness contributions. In a live T3 dispatch, the current OpenCode instance returned a review requested from `anthropic/claude-opus-5-5`. T3 reported no `executedModel`, but the assistant message for that run has OpenCode model metadata and token usage. OpenCode records the host session's completed assistant messages in the same way.

## Implementation Units

### U1. Deliver the OpenCode review route

- **Goal:** Deliver the scoped instruction and its route authorization together.
- **Requirements:** R1–R4.
- **Dependencies:** None.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `home/h82/agents/opencode.nix`, `home/h82/agents/cross-model-peers.nix`, `docs/agent-routing.md`, `tests/agent-instructions.py`, `tests/t3code-launch.py`, `tests/lib/cross-model-peers.nix`.
- **Approach:** Put KTD1 and KTD3 in the T3-only `.opencode` branch. For KTD2, add the token in the OpenCode module, extend the installed-package expectation, and put the recipient check in the shared baseline. Document the route and evidence in the routing guide.
- **Patterns to follow:** Shared template dispatch flags, receipt hashes, and scratch-home activation in the existing T3 launch check.
- **Test scenarios:**
  - Render every harness with and without T3. Pin the OpenCode T3 output separately. All baseline renders carry the recipient check; other T3 additions stay unchanged.
  - Activate into a scratch home. The OpenCode instance reads its distinct T3 addition; other instances retain the shared T3 addition.
  - Verify the shared environment lists `opencode` where OpenCode is installed, alongside the other declared peers.
- **Verification:** Materialized instruction and settings checks prove delivery and scope. Separately record a same-instance dispatch and its run identity evidence as a routing smoke check, without counting it as activation or verification of either skill's full workflow.

## Verification Contract

- Verify `agent-instructions`, `t3code-traits`, and the platform's shared session allowlist (`session-variables` on NixOS; `darwin-config` and `darwin-outputs` on macOS). Report evidence pending in CI under the repository's normal shipping rules.
- The routing guide must describe the instruction actually delivered, including what happens when OpenCode cannot supply an eligible peer.

## Definition of Done

U1 is complete when the scoped instruction, launch allowlist, and routing guide agree, and the affected delivery checks pass. No experimental configuration or temporary files are included in the diff.
