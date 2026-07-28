---
title: Release Lock Structural Carry-Forward - Plan
type: fix
date: 2026-07-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/106
---

# Release Lock Structural Carry-Forward - Plan

## Goal Capsule

- **Objective:** Make the natural, unredirected release-lock command refresh the repository lock in place, so carry-forward is structural instead of delegated to caller-side merge tooling.
- **Authority:** GitHub issue `hyperlapse122/dotfiles#106` governs behavior; the existing `packages/release-lock/src/lock.ts` merge and malformed-input contracts govern implementation.
- **Execution profile:** Localized TypeScript CLI behavior change with orchestration-level regression tests and contributor documentation.
- **Stop conditions:** Stop rather than change resolver behavior, suppress partial-failure exit status, weaken malformed-lock handling, or alter the scheduled workflow's commit-then-fail semantics.
- **Tail ownership:** The implementation must include package verification, repository diff checks, PR CI, and issue linkage.

---

## Product Contract

### Summary

The release-lock CLI will refresh the repository lock in place by default, retain `--out` for an explicit destination, and reserve stdout for an explicit inspection mode that cannot be mistaken for a safe same-file refresh.

### Problem Frame

`resolveAll` intentionally omits failed tools from its fresh resolution. The existing `--out` path overlays that partial result onto its destination, but plain invocation serializes the partial result directly. A user following the documented stdout usage and redirecting it over the committed lock erases the destination before the CLI starts because the shell truncates it first; the process then cannot recover failed tools and downstream template lookups hard-fail.

The repository already has the correct merge primitive, sorted serialization, missing-file behavior, and strict malformed-file handling. The defect is the executable seam that does not apply those semantics consistently across output modes.

### Requirements

- R1. Plain CLI invocation must read and update the repository's `.chezmoidata/releases.json` lock in place.
- R2. `--out <path>` must read and update that explicit destination with the same merged-lock semantics as the default refresh.
- R3. A tool omitted from a partial resolution must retain its existing locked entry, while a successfully resolved tool replaces its previous entry.
- R4. Any resolution failure must still be written to stderr and leave the process with exit code 1 after the complete merged lock is emitted or written.
- R5. A missing existing lock must behave as a first run, while malformed existing JSON must fail loudly rather than silently reset.
- R6. An explicit `--stdout` inspection mode must emit sorted, newline-terminated merged JSON with diagnostics confined to stderr, and documentation must warn that redirecting any command form over its input lock is destructive before process startup.
- R7. Contributor documentation must distinguish safe in-place refresh from stdout inspection and direct operators to plain invocation or `--out` for lock updates.
- R8. Refresh writes must replace the destination atomically so interruption cannot leave a truncated or partial lock.
- R9. A fully successful resolution must prune lock entries no longer present in the registry; a partial failure must preserve unresolved prior entries and defer pruning until a clean run.

### Acceptance Examples

- AE1. Given a repository lock containing `good@v1` and `failed@v1`, when `good` resolves to `v2` and `failed` errors, plain invocation writes `good@v2` plus `failed@v1` in place, reports the error on stderr, and exits 1.
- AE2. Given the same inputs and an explicit output path, `--out` writes the same merged tool set and exits 1.
- AE3. Given no repository lock, plain invocation creates it from the successful fresh resolution.
- AE4. Given malformed existing JSON, the CLI fails without replacing it.
- AE5. Given an intact repository lock, `--stdout` prints the complete merged lock without modifying the file; redirecting either plain invocation or `--stdout` over the same lock is documented as unsupported because shell truncation happens first.
- AE6. Given a zero-byte or whitespace-only existing lock, the CLI treats it as malformed and leaves it untouched.
- AE7. Given a lock containing a retired tool, a fully successful refresh removes that tool, while a partial refresh retains it until a later clean run.

### Scope Boundaries

- In scope: CLI orchestration, orchestration-level tests, and release-lock README usage.
- Out of scope: resolver implementations, registry entries, lock data, merge-helper semantics, workflow behavior, and chezmoi consumers.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Make safe in-place refresh the default.** Unredirected plain invocation writes the repository lock through the same read-merge-write path as `--out`, so carry-forward cannot be skipped by choosing the natural command. No process can protect an input file from shell truncation that occurs before startup, so same-file redirection is unsupported for every mode.
- KTD2. **Resolve the default repository lock relative to the CLI module.** The default cannot depend on the caller's working directory because documented invocations run from both the repository root and the package directory. Convert a module-relative URL to a local path in the CLI rather than widening the lock helper API.
- KTD3. **Keep `resolveAll` partial by design.** Failed sources remain absent from the fresh resolution and present in `failures`; carry-forward stays at the CLI/lock boundary where prior state is available.
- KTD4. **Extract testable orchestration from the self-executing entry point.** A small importable function with injected resolution, paths, and streams will exercise the real output and failure semantics without triggering live network access on import.
- KTD5. **Treat a clean resolution as authoritative and a partial resolution as an overlay.** This preserves failed entries without making removed registry tools immortal.
- KTD6. **Use atomic destination replacement.** Write the complete serialized lock to a same-directory temporary file and rename it over the destination so interrupted refreshes preserve the prior file.

### Assumptions

- The committed lock remains at `.chezmoidata/releases.json` relative to the repository root.
- The scheduled workflow remains on `--out`; this fix makes plain invocation equally safe without changing CI behavior.
- A malformed committed lock is operator-visible corruption and must remain a hard error.

### Sequencing

Implement the importable CLI orchestration and its tests together, then update usage documentation against the verified behavior. No workflow or consumer render changes are needed.

---

## Implementation Units

### U1. Unify CLI carry-forward behavior

- **Goal:** Make default and explicit-file refreshes persist the same complete merged lock, with stdout available only through an explicit inspection mode.
- **Requirements:** R1-R6, R8-R9; AE1-AE7; KTD1-KTD6.
- **Dependencies:** None.
- **Files:**
  - Modify `packages/release-lock/src/cli.ts`
  - Modify or create an adjacent importable CLI orchestration module if needed
  - Modify `packages/release-lock/test/cli.test.ts`
- **Approach:** Parse mutually exclusive default, `--out`, and `--stdout` modes. Resolve the existing-lock path from `--out` or the module-relative repository default, load it with `readLock`, merge it with the fresh `resolveAll` result, then write the merged lock for refresh modes or serialize it for explicit inspection. Keep diagnostics on stderr and return an exit status that the thin executable tail assigns to `process.exitCode`.
- **Patterns to follow:** Reuse `packages/release-lock/src/lock.ts`; follow dependency-injected CLI testing in `packages/figma-auth/src/cli.ts` and `packages/figma-auth/test/cli.test.ts`; use the repository's module-relative URL pattern.
- **Test scenarios:**
  - Covers AE1. A partial failure in default mode retains the failed tool's previous entry, updates the successful tool in place, reports the failure on stderr, and returns 1.
  - Covers AE2. The same partial resolution with `--out` writes an equivalent merged lock to the explicit destination and returns 1.
  - Covers AE3. An absent default lock is created from the successful fresh resolution and returns 0.
  - Covers AE4. Malformed existing JSON rejects without replacing or emitting a fresh lock.
  - Covers AE5. `--stdout` reads the intact default lock, emits merged JSON without modifying it, and returns the resolution status; CLI usage text documents that same-file redirection is unsupported for both plain and `--stdout` forms.
  - Covers AE6. Empty and whitespace-only existing locks reject as malformed without being overwritten.
  - Covers AE7. A clean refresh prunes a retired entry, while a partial refresh retains it.
  - Invalid or conflicting output flags fail without resolving or writing.
  - The exported module-relative default resolves to the repository-root `.chezmoidata/releases.json`.
  - A failed atomic replacement leaves the previous destination content intact and cleans up its temporary file.
  - A fully successful resolution overwrites prior entries and returns 0; output remains sorted and newline-terminated through the existing serializer.
- **Verification:** Focused CLI and lock tests prove sink parity and carry-forward; package type checking accepts the extracted boundary.

### U2. Document safe refresh usage

- **Goal:** Make the CLI's complete merged emission and partial-failure behavior unambiguous to operators.
- **Requirements:** R6 (redirection warning), R7.
- **Dependencies:** U1.
- **Files:**
  - Modify `packages/release-lock/README.md`
- **Approach:** Replace the existing stdout-first example with the unredirected plain refresh and explicit `--out` forms. Explain that `--stdout` is inspection-only and warn that redirecting any command form over the lock it reads is unsafe because the shell truncates the input before the CLI starts. Retain the warning that partial failure persists successful updates but exits nonzero.
- **Patterns to follow:** Keep the existing root-relative command examples and concise operational wording.
- **Test scenarios:** Test expectation: none — documentation describes behavior covered by U1.
- **Verification:** Usage examples and prose match the implemented default path, sink behavior, and exit semantics.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Package tests | `vp test` from `packages/release-lock` | Carry-forward, clean-run pruning, atomic replacement, refresh-mode parity, stdout inspection, error handling, and existing resolver behavior |
| Package types | `vp run typecheck` from `packages/release-lock` | CLI orchestration and injected boundary type safety |
| Repository formatting | `git diff --check` | Patch cleanliness |
| Repository scope | `git status --short` and a scoped diff | Only the plan, release-lock CLI/orchestration module/tests, and README changed |
| Mirror invariant | Verify `CLAUDE.md` is exactly `@AGENTS.md` | Repository instruction mirror remains intact |

No live `chezmoi apply`, real release refresh, or service operation is part of verification.

---

## Definition of Done

- U1 satisfies R1-R6, R8-R9, and AE1-AE7 with orchestration-level regression coverage.
- U2 documents safe unredirected default and `--out` refreshes plus the same-file redirection hazard for every mode.
- Existing package tests and type checking pass.
- The scheduled workflow and lock consumers remain unchanged.
- Partial failures still produce usable successful updates and a nonzero exit signal.
- No abandoned experimental code or unrelated changes remain in the diff.
