---
title: Decide Info Decision Types - Plan
type: feat
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Decide Info Decision Types - Plan

## Goal Capsule

- **Objective** Let scripts check whether the selected model supports a decision type with a JSON array membership test.
- **Means** Serialize confirmed decision types as an array in the existing JSON field (KTD1).
- **Authority** The Product Contract governs behavior. Repository instructions govern implementation and verification.
- **Stop condition** Stop if the requested output cannot be implemented while honoring R2.
- **Delivery** The implementing agent verifies the change and opens one pull request.

## Product Contract

### Summary

Return confirmed decision types as a string enum array from `decide info --json`.

### Problem Frame

Scripts currently read a status value from a map to determine whether they can use a type with the selected model.

### Requirements

- R1. Return `decision_types` as an array of confirmed supported types drawn from `noul`, `choice`, `score`, and `box`. Return `[]` when none are confirmed.
- R2. In standard text output, continue to report `supported`, `unsupported`, or `unknown` for each type. Preserve the remaining JSON fields and existing support detection.

### Key Decisions

- **List confirmed support only** (session-settled: user-directed — chosen over separate unknown types or status-bearing entries: scripts can check support with a single membership test). Governs R1.

## Planning Contract

### Key Technical Decisions

- KTD1. Filter the existing support map when emitting JSON in the `info` command. Use that same map for text so both formats derive from the same support assessment.

### High-Level Technical Design

The output boundary can represent the same local-model assessment in these two forms.

| Command | Decision types excerpt |
| --- | --- |
| `decide info --json` | `"decision_types": ["noul", "choice", "score"]` |
| `decide info` | `noul (supported), choice (supported), score (supported), box (unsupported)` |

## Implementation Units

### U1. Emit supported types in JSON

**Goal** Implement the array contract and document how scripts can read it.

**Requirements** R1, R2.

**Files** `packages/decide/decide/cli.py`, `tests/decide-ipc.py`, `docs/decide.md`.

**Approach** Apply KTD1. Update the existing `info` assertions and explain array membership and empty results in the guide.

**Test scenarios**

- A matching local model returns the three supported types. Text shows their statuses and marks `box` unsupported.
- A matched OpenRouter model omits `box` when support is unknown. An alias resolving to a model with confirmed `box` support includes it.
- A local model mismatch, an unlisted remote model, and an unavailable catalog each return `[]`.

**Verification** Run the existing CLI cases through the package install checks.

## Verification Contract

Run `nix build --no-link .#decide` to execute the packaged CLI tests with fake backends and catalog responses.

## Definition of Done

The CLI and guide match R1 and R2, the package checks pass, and the diff contains the final implementation and its regression coverage.
