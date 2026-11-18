---
title: Decide Model Info - Plan
type: feat
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Decide Model Info - Plan

## Goal Capsule

- Objective. A user can check which model a default Decisions request would use and which question types it supports before submitting a judgment.
- Means. Add a CLI inspection command backed by a local status read and an OpenRouter catalog lookup (KTD1, KTD2).
- Authority. The Product Contract carries the agreed behavior. The repository instructions govern verification and shipping.
- Execution. One pull request. The implementation workflow verifies, reviews, and opens it.
- Stop conditions. No open product blockers.

## Product Contract

### Summary

Add `decide info` for terminal users and `decide info --json` for scripts. Both show model identity and decision question support.

### Problem Frame

The current CLI documents defaults but has no way to see whether the local daemon has loaded a model or what a selected remote model supports before making a judgment.

### Requirements

- R1. Show the backend and the model selected by the CLI's existing configuration precedence. Plain text is the default and JSON carries the same facts.
- R2. For MLX and CUDA, show the bundled model ID, pinned revision, and whether the daemon has completed loading it. Show an unknown load state when the daemon cannot answer. Identify when the selected request model differs from the bundled model.
- R3. For OpenRouter, look up the selected model using live official metadata. Report decision types supported by the available evidence and indicate unknown support where the evidence is insufficient.
- R4. The command performs no inference and does not download or load local weights.

### Key Decisions

- **Use live official OpenRouter metadata** (session-settled: user-directed — chosen over a bundled offline lookup: the user chose a live check with an explicit unknown result when confirmation is unavailable). Governs R3, R4.

## Planning Contract

### Key Technical Decisions

- KTD1. Read a small status document over the existing private Unix socket. The server owns the local head and can report its bundled model and revision without acquiring the inference lock. The CLI falls back to package facts when the route is unavailable, including older daemons. Distinguish service and package provenance. Keep the selected model separate from the bundled model because `judge` sends the model chosen by its client.
- KTD2. For the OpenRouter backend, read the public Models API filtered by the Decisions route and match the selected ID or canonical slug. Resolve an alias only using its live catalog target. A matching entry provides model metadata and evidence for the three question types OpenRouter documents for every Decisions adapter. Claim `box` only for a positively documented model that the catalog ties to the selected ID. Keep the other remote `box` results unknown. An unavailable lookup or unmatched entry yields unknown capability and a reason. Send only a GET to the public catalog, without the service's inference credential or request payload. [Models API filters](https://openrouter.ai/docs/guides/overview/models#endpoints) and [Decisions adapter support](https://openrouter.ai/docs/guides/community/multimodal-decisions#what-each-endpoint-accepts).
- KTD3. Render both formats from one result. Include the effective model, backend provenance, applicable revision and load state, available remote model metadata, and a support value per decision type. An inspection with partial facts or an incompatible local model still returns a diagnostic result on stdout. Reserve a nonzero exit for invocation or configuration errors. An incompatible local selection has no supported decision types even if the service has a different model resident.

## Implementation Units

### U1. Expose the serving backend and local model state

**Goal** Observe the configured service without making a Decisions request.

**Requirements** R2, R4.

**Files** `packages/decide/decide/{ipc,server,local,mlx,cuda,openrouter}.py`, `tests/decide-ipc.py`.

**Approach** Implement KTD1 using shared packaged pins and local question types. The service report observes a completed head load at the time of the read. Keep the status handler outside the inference queue and the existing Decisions POST unchanged.

**Test scenarios** A fake local loader starts unloaded and reaches loaded only after a real test judgment. Status reads before and after that judgment do not call the loader or inference. An OpenRouter service reports its backend without contacting OpenRouter.

**Verification** Exercise the status endpoint in the packaged IPC suite.

### U2. Report model information in the CLI

**Goal** Inspect a model in plain text or JSON, including when model information is incomplete.

**Requirements** R1, R2, R3, R4.

**Dependencies** U1.

**Files** `packages/decide/decide/{cli,openrouter}.py`, `tests/decide-ipc.py`, `docs/decide.md`.

**Approach** Apply KTD2 and KTD3. Reuse the existing CLI configuration flags. Query the service for its backend first so a CLI and daemon built from different packages do not give misleading results. When the socket cannot answer, inspect the CLI package and label that source. Use a single bounded catalog request when the backend is OpenRouter.

**Test scenarios** CLI subprocesses exercise both formats, configured model overrides, unavailable local status, and an incompatible selected model. A stub catalog covers a matching model, a documented alias, an unmatched model and a failed response. The stub only accepts GET.

**Verification** Run the packaged test suite and check that the guide documents the output and unknown results.

## Verification Contract

Build `nix build --no-link .#decide` to run the package install checks, including the IPC cases against the packaged CLI. The package test uses fake loaders and catalog data. Platform evidence follows the repository's PR checks.

## Definition of Done

`decide info` exposes the agreed facts in both formats without starting inference or loading local weights. The packaged checks pass and the guide explains what the output means.
