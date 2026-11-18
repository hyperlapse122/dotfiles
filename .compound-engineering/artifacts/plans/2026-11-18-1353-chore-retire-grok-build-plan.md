---
title: Retire Grok Build - Plan
type: chore
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Retire Grok Build - Plan

## Goal Capsule

**Objective.** After switching either managed host, the owner no longer sees the repository's Grok Build provider or its subscription usage reports.

**Means.** Retire the Grok Build integration and remove its usage reader (KTD1, KTD2).

**Authority.** The owner's request and repository retirement policy govern this plan. Preserve existing user data described in R3.

**Execution.** Implement and verify in this branch, then open one pull request and monitor CI. Stop if retirement requires deleting Grok user data or changing another provider's behavior.

## Product Contract

### Summary

Retire Grok Build from the NixOS and macOS configurations and remove its subscription usage integration.

### Problem Frame

The Grok Build subscription is ending. The hosts still manage the tool and T3 provider, and `agent-usage` still tries to read its subscription.

### Requirements

- R1. End Grok Build installation and reconciliation by the repository. Remove its managed T3 instance from existing settings and omit it from fresh settings.
- R2. Remove Grok usage collection and the Grok entry from both text and JSON output. Continue reporting usage for the other providers.
- R3. Preserve existing Grok files, credentials, plugin state, and session history. Preserve unrelated T3 settings and shared agent integrations.

## Planning Contract

### Key Technical Decisions

- KTD1. Remove the Grok-only modules, packages, pins, helpers, and updater steps. Use the existing `agent-settings` retirement entries for the managed T3 instance and legacy Grok settings that can recreate it. Keep historical documentation and the separate Grok Bot retirement behavior.
- KTD2. Remove the Grok reader and its authentication, refresh, and cache identity code from `agent-usage`. The reader registry drives both output modes. Leave existing cache files on disk.

## Implementation Units

### U1. Retire Grok Build integration

- **Goal and requirements.** Remove active management on both hosts and reconcile existing T3 settings (R1, R3).
- **Files.** `flake.nix`, `home/h82/agents/`, `home/h82/t3code.nix`, Grok-specific packages and scripts, `.github/workflows/update-dependencies.yml`, affected tests, and active repository documentation.
- **Approach.** Apply KTD1. Remove Grok from the shared instruction and plugin consumers and their tests while retaining the shared assets. Update active docs and the workflow fixture.
- **Test scenarios.** Exercise fresh and previously managed T3 settings, including the legacy per-driver config. Assert that activation removes the managed entries and preserves unrelated settings and existing Grok files.
- **Verification.** Build the existing T3 launch, agent instruction, and update reconciliation checks on Linux. Verify Darwin outputs in CI.

### U2. Remove Grok subscription usage

- **Goal and requirements.** Stop Grok usage queries and reporting (R2, R3).
- **Files.** `scripts/agent-usage` and `tests/test_agent_usage.py`.
- **Approach.** Apply KTD2 and remove the Grok fixtures, keeping coverage for all remaining providers.
- **Test scenarios.** The CLI returns the four supported providers in both output modes, even with an old Grok cache.
- **Verification.** Build the existing `agent-usage` check.

## Verification Contract

Run affected checks through `nix build --no-link` on the local builder. Apply the repository's formatting and full-CI rules when shipping.

## Definition of Done

Both units pass their affected checks. The diff contains only Grok Build retirement and the corresponding test and documentation changes.
