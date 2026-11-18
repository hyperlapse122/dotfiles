---
title: Fit Repository Instructions Within the Codex Budget - Plan
type: fix
date: 2026-11-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fit Repository Instructions Within the Codex Budget - Plan

## Goal Capsule

- **Objective.** A fresh Codex session in this repository sees the complete root instructions without either byte-budget warning.
- **Means.** Move detailed reference material behind links in the root instructions (KTD1).
- **Authority.** The conversation and active repository instructions govern. This plan authorizes the documentation changes below.
- **Stop condition.** Stop if the root document cannot fit while preserving the agreed rules.
- **Execution profile.** One unit and one pull request. The autonomous workflow implements, verifies, and ships the change.

## Product Contract

### Summary

Keep the default Codex budget and make detailed repository guidance available on demand.

### Problem Frame

The root file is 48,188 bytes, so Codex truncates it at 32,768 bytes. The combined text in the reported session reaches 41,793 bytes after adding global instructions and the separator.

### Requirements

- R1. Fit the complete root instructions and the reported global instruction contribution within 32,768 bytes.
- R2. Keep repository-wide rules in the root, including security, host lifecycle, and verification requirements.
- R3. Preserve the repository map and conditional reading references in a linked document. Keep their applicability clear for agents working from the root.

## Planning Contract

### Key Technical Decisions

- KTD1. Keep `project_doc_max_bytes` at its default and link the repository map and topic-specific reading list from `AGENTS.md` (session-settled: user-directed — chosen over raising the limit to keep automatic loading focused on repository-wide rules).
- KTD2. Use a regular Markdown reference under `docs/`, with separate headings for the repository map and the reading list. Keep the rule against branching on host names in `AGENTS.md` and keep the authentication and boot reading requirement there. Maintain the repository map and new topic-specific entries in the reference.

### Assumptions

The reported session has 9,002 bytes of trimmed global instructions and a 23-byte separator. A root file of at most 23,743 bytes fits that profile. Additional thread instructions change the combined size.

## Implementation Units

### U1. Move reference material out of the root instructions

- **Goal.** Make the complete root instructions available in the reported Codex session.
- **Requirements.** R1, R2, R3.
- **Files.** `AGENTS.md` and `docs/repository-reference.md`.
- **Approach.** Move the detailed project structure, full verification command example, CI job routing details, and topic-specific reading list. Retain the authentication and boot preflight in the root. Update relative links for the new location. Put concise pointers near the top of the root document and retain the root-level rules. Condense redundant prose where needed to fit.
- **Test scenarios.** Start with the reported global instructions and the default budget. Confirm the current file reproduces the warnings and the reorganized file loads in full without them. Compare the moved section and its links with the original.
- **Verification.** Use the checks below.

## Verification Contract

- Check the root file's UTF-8 byte size and exercise a fresh session with the pinned Codex binary and the reported global instruction file.
- Run `nix build --no-link .#checks.x86_64-linux.agent-instructions` because the check consumes the root file.
- Apply the repository's existing pre-push checks. Apply the `full-ci` label and dispatch `check.yml` on the PR branch. The docs-only classifier skips the closure jobs on label events. Verify the required jobs against the PR head SHA.

## Definition of Done

- The root file fits the reported profile, both warnings are absent, and the repository-wide rules remain discoverable from the root.
- The moved material is accessible through valid links at its new location, and the affected repository check passes.
