---
title: Provision OpenAI and Anthropic API keys for OpenCode
type: feat
date: 2026-11-19
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan
execution: code
---

# Provision OpenAI and Anthropic API keys for OpenCode

## Goal Capsule

- **Objective:** Use OpenAI and Anthropic API-key accounts from OpenCode on either production host without entering the keys on each machine.
- **Means:** Extend the existing SOPS-to-OpenCode credential path (KTD1).
- **Authority:** The owner's agreed scope and the repository's credential-handling rules govern implementation.
- **Stop condition:** Stop if the two catalog providers need a separate credential path or account-selection policy.
- **Execution profile:** One unit and one PR. The executor verifies and opens the PR; the owner decides when to merge and apply it.

## Product Contract

### Summary

Add OpenAI and Anthropic to the credentials already provisioned for OpenCode during production activation.

### Problem Frame

The owner has entered the keys securely, but the managed OpenCode setup does not yet register them. Without that connection, each host needs its own manual setup and key updates.

### Requirements

- R1. Use the shared encrypted key for each provider on both production hosts. Bootstrap outputs do not provision either key.
- R2. Register both API keys through the same mechanism and lifecycle as the existing Synthetic and OpenCode Go credentials, including rotation. Do not add a separate input workflow, account-selection policy, or model configuration.
- R3. Preserve other accounts and settings. Do not expose plaintext in the checkout, Nix store, command arguments, logs, or CI.

### Key Decisions

- **Share the same keys on both hosts** (session-settled: user-directed — chosen over per-host keys or macOS-only setup: enter and rotate each key once). Governs R1.
- **Use the same setup as Synthetic and OpenCode Go** (session-settled: user-directed — chosen over separate account-selection behavior: keep this a simple credential addition). Governs R2.

## Planning Contract

### Key Technical Decisions

- KTD1. Add the two encrypted fields to the existing NixOS and Darwin publication paths, then pass their file paths to `opencode-auth-sync` using the built-in `openai` and `anthropic` integration IDs. The owner-supplied keys are already encrypted in `secrets/tokens.yaml`; keep that change intact.
- KTD2. Tie the production NixOS Home Manager activation service to the encrypted manifest so a key-only rotation reruns the importer after SOPS publishes. Do not pass decrypted values through evaluation.
- KTD3. Preserve the account already selected when the shared importer rotates a managed key. Restore the managed selection only if it was active before replacement and leave other accounts alone.

## Implementation Units

### U1. Extend managed credential provisioning

- **Goal:** Connect the shared keys to production OpenCode activation.
- **Requirements:** R1–R3.
- **Files:** `modules/nixos/{profile.nix,system/secrets.nix}`, `scripts/{host-secrets,opencode-auth-sync}`, `home/h82/agents/opencode.nix`, `secrets/tokens.yaml`, `secrets/README.md`, `docs/macos.md`, and the existing publication and activation checks and fixtures.
- **Approach:** Follow KTD1–KTD3 and update the macOS first-switch walkthrough and credential inventory.
- **Test scenarios:** Exercise both keys in the existing fake-secret publication fixtures. Check production activation passes both provider IDs and matching files to the importer and bootstrap does not run it. On NixOS, change only the encrypted test manifest and verify activation is triggered. Exercise rotation with two accounts for the same provider, starting with the managed account selected and with the other account selected.
- **Verification:** Run the affected publication and OpenCode checks supported by the local builder. Record platform checks that require CI separately.

## Verification Contract

Use fake keys for automated checks. Keep any live provider calls and host activation separate from repository verification.

## Definition of Done

The PR contains only the agreed credential additions, their encrypted values, related documentation, and evidence from the existing checks.
