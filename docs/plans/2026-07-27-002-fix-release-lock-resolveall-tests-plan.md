---
title: Test resolveAll Dispatch, Failure Carry-Forward, and Lock Emission - Plan
type: fix
date: 2026-07-27
topic: release-lock-resolveall-tests
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Test resolveAll Dispatch, Failure Carry-Forward, and Lock Emission - Plan

## Goal Capsule

- **Objective:** Cover `resolveAll` in `packages/release-lock` with unit tests: the six-case kind→resolver dispatch, the failed-source carry-forward contract (R11 of `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md`), and the `{ releases: { tools } }` emission nesting with sorted keys — so a mis-wired case, swallowed failure, or reverted nesting fails the suite instead of shipping a bad lock.
- **Authority:** GitHub issue `hyperlapse122/dotfiles#103` governs scope; the existing per-resolver tests in `packages/release-lock/test/` govern the fetch-stub style.
- **Execution profile:** Lightweight — one importable-module refactor inside the package plus one new test file; `vp test` and `vp run typecheck` verified, no live apply.
- **Stop conditions:** Stop rather than broaden scope if the change appears to require altering resolver signatures, changing `src/registry.ts`, or touching anything outside `packages/release-lock/src` and `packages/release-lock/test`.
- **Tail ownership:** The LFG pipeline owns commit, push, pull-request creation, and CI monitoring.

## Product Contract

### Summary

Add `packages/release-lock/test/cli.test.ts` covering the three untested seams the issue names, enabled by a minimal restructure: `resolveAll` and its dispatch move out of the self-executing `src/cli.ts` into an importable module, the dispatch switch becomes an exported `RESOLVERS` table whose wiring a test can assert directly, and `resolveAll` accepts an optional registry so tests resolve a two-entry fixture instead of the full 30-entry `REGISTRY`.

### Problem Frame

`packages/release-lock/src/cli.ts` executes the resolution run at module top level, so nothing can import `resolveAll` without triggering a live network run — and nothing does: `test/` holds the six per-resolver files plus `lock.test.ts`, and `grep` finds no reference to `REGISTRY` or `resolveAll` in any of them. Three seams are therefore unverified. The kind→resolver dispatch (`src/cli.ts:34-49`) is never exercised, so a mis-wired case fails no test. The catch branch (`src/cli.ts:58-71`) that omits a failed source and records it in `failures` — the resolveAll half of the R11 "previous entry carried forward, run marked failed" contract the origin plan's U2 lists as a test scenario — is likewise unverified, as is the `{ releases: { tools } }` emission nesting (`src/cli.ts:73`) every chezmoi consumer depends on via `.releases.tools`. A revert of the nesting or a swallowed failure ships a bad or blanked lock with a green suite, and the hourly `refresh-release-lock.yml` workflow would commit it.

### Requirements

- R1. `test/cli.test.ts` asserts `resolveAll` emits `{ releases: { tools } }` with sorted tool keys (issue item 1).
- R2. With one registry entry's fetch stubbed to 404, the failed tool is omitted from the freshly resolved lock, its source appears in `failures`, and the other tools still resolve — the resolveAll half of the R11 scenario the origin plan promised (issue item 2); prior-entry retention is the overlay merge's job, already covered by `test/lock.test.ts`.
- R3. The dispatch maps each `ResolverKind` to its resolver, asserted directly against the exported table (issue item 3).
- R4. The CLI stays runnable exactly as today (`bun run packages/release-lock/src/cli.ts [--out <path>]`, per `packages/release-lock/README.md` and `.github/workflows/refresh-release-lock.yml`), with no change to resolution behavior, stderr reporting, overlay merge, or exit-code semantics.

### Key Decisions

- KD1. Extract `resolveAll` and its dispatch from `src/cli.ts` into a new `src/resolve-all.ts`; `cli.ts` keeps `outPath` and the executable tail, importing `resolveAll`. Rationale: the top-level run at `src/cli.ts:76-84` makes `cli.ts` unimportable in tests; a split keeps the entry point and its side effects in one small file and the testable logic in another. Chosen over a run-main guard (e.g. an argv/import-meta check), which leaves executable and library code entangled in one module.
- KD2. Replace the private dispatch switch with an exported `RESOLVERS: Record<ResolverKind, ResolverFn>` table that `resolveAll` consults. Five kinds map to the resolver function reference directly (a two-parameter resolver is assignable to the three-parameter `ResolverFn`); `gitRef` gets a thin wrapper because `resolveGitRef`'s third parameter is the `GitExec`, not the token. Rationale: a table's wiring is assertable by identity (`toBe` against the imported resolver functions); a switch is not. Resolver signatures are deliberately not churned to make the table uniform.
- KD3. `resolveAll(token, registry = REGISTRY)` takes an optional registry parameter. Rationale: testing against the full `REGISTRY` would require stubbing all six source shapes at once, including `git ls-remote` (a child process, not fetch); a two-entry fixture registry exercises the same code path through the real dispatch with fetch stubbed per URL. The production call in `cli.ts` passes no registry and behaves identically.

### Scope Boundaries

- Out of scope: changing any resolver's signature or behavior; editing `src/registry.ts`; testing the `cli.ts` executable tail (stderr lines, `--out` overlay, exit code — the overlay merge is already covered by `test/lock.test.ts`); new resolver kinds.

## Planning Contract

### Key Technical Decisions

KTD1 (= KD1), KTD2 (= KD2), KTD3 (= KD3) under Key Decisions above are the technical decisions; no additional plan-level forks remain.

### Assumptions

- `vite-plus/test`'s `describe`/`expect`/`test` supports identity assertions (`toBe`) on function references — it re-exports Vitest's API, as the existing tests' usage indicates.

### Open Questions

None. Exact helper names and the fixture shape are implementation-time details.

## Implementation Units

### U1. Extract an importable resolve-all module with an exported dispatch table

### U2. Add test/cli.test.ts covering dispatch, failure carry-forward, and emission nesting

(Units ordered by dependency; details below.)

---

### U1. Extract an importable resolve-all module with an exported dispatch table

- **Goal:** Make `resolveAll` and the kind→resolver dispatch importable without side effects, with the dispatch wiring exported for direct assertion.
- **Requirements:** R3, R4 (enables R1, R2)
- **Dependencies:** none
- **Files:**
  - Create `packages/release-lock/src/resolve-all.ts`
  - Modify `packages/release-lock/src/cli.ts`
- **Approach:** Move `resolveAll` and the dispatch out of `cli.ts` into `resolve-all.ts` (KD1). In the new module, define `ResolverFn = (name: string, spec: ToolSpec, token: string | undefined) => Promise<LockedTool>` and `export const RESOLVERS: Record<ResolverKind, ResolverFn>` mapping each kind to its resolver reference — `gitRef` via a one-line wrapper `(name, spec) => resolveGitRef(name, spec)` (KD2). `resolveAll(token, registry: Registry = REGISTRY)` keeps the current settle-all loop and return shape verbatim, reading the registry from its parameter (KD3). `cli.ts` keeps `githubToken`, `outPath`, and the unchanged executable tail, importing `resolveAll` from `./resolve-all.js`.
- **Patterns to follow:** the existing resolver modules — one concern per file, JSDoc header explaining the seam, `import type` for types.
- **Test scenarios:** `Test expectation: none` — pure code motion; U2 supplies the behavioral coverage, and the typecheck gate proves the `Record<ResolverKind, …>` table is total (a missing kind is a compile error).
- **Verification:** `vp run typecheck` passes; no live CLI run is needed — typecheck plus U2's suite is the proof that behavior is unchanged.

### U2. Add test/cli.test.ts covering dispatch, failure carry-forward, and emission nesting

- **Goal:** The three seams the issue names fail loudly on regression.
- **Requirements:** R1, R2, R3
- **Dependencies:** U1
- **Files:**
  - Create `packages/release-lock/test/cli.test.ts`
- **Approach:** Import `resolveAll` and `RESOLVERS` from `../src/resolve-all.js` and the resolver functions from their modules. Stub `globalThis.fetch` per test with a URL-routing stub, restoring it in `afterEach` — the established pattern in `test/github.test.ts`. Build tiny fixture registries (two entries) rather than touching `REGISTRY`. The happy-path fixture uses version-only `githubRelease` specs (no `asset` selector) so one stubbed JSON response per tool suffices.
- **Execution note:** Implement the failure-carry-forward test first; it is the R11 contract the origin plan promised and the one most likely to reveal a surprise in the current code.
- **Test scenarios:**
  - Dispatch table (R3): `Object.keys(RESOLVERS).sort()` equals the six `ResolverKind` values sorted; `RESOLVERS.githubRelease` is `resolveGitHubRelease`, `.githubTag` is `resolveGitHubTag`, `.gitlabRelease` is `resolveGitLabRelease`, `.npm` is `resolveNpmPackage`, `.vendorManifest` is `resolveVendorManifest` (identity, `toBe`); `RESOLVERS.gitRef` is a function and is not aliased to any of the other five table values (distinctness — a mis-wire of `gitRef` to another resolver is caught).
  - Emission nesting and sorted keys (R1): a two-entry fixture registry (insert "zed" then "abc") with fetch stubbed to return a release for each; the resolved lock deep-equals `{ releases: { tools: { … } } }` at the top level, `Object.keys(lock.releases.tools)` is `["abc", "zed"]`, and each entry carries its `kind`, `source`, and stubbed `version`.
  - Covers R11 (R2): a two-entry fixture where the URL-routing fetch stub returns 404 for one tool and 200 for the other; the failed tool is absent from `lock.releases.tools`, `failures` has exactly one entry naming the failed tool's source, and the healthy tool resolves with its stubbed version.
  - Edge case: an empty fixture registry resolves to `{ releases: { tools: {} } }` with `failures: []`.
  - Edge case: a resolver that throws a non-`Error` value (fixture spec wired so the stub rejects with a string) records `String(error)` in `failures` rather than crashing `resolveAll`.
- **Patterns to follow:** `test/github.test.ts` — module-level `realFetch` capture, `afterEach` restore, `stubRelease`-style helpers, `Response` JSON stubs.
- **Verification:** `vp test` passes with the new file included; deliberately reverting one covered seam (e.g. dropping the `releases` nesting or aliasing `RESOLVERS.npm` to the GitLab resolver) makes the suite red — confirm at least one such mutation manually during implementation, then restore.

## Verification Contract

- `vp test` (network stubbed) passes, including `test/cli.test.ts`.
- `vp run typecheck` passes — the `Record<ResolverKind, ResolverFn>` totality check is part of the dispatch proof.
- One manual mutation check per the U2 verification note, restored afterward.

## Definition of Done

- `src/cli.ts` is the executable entry only; `src/resolve-all.ts` exports `resolveAll` and `RESOLVERS`; CLI usage, stderr reporting, overlay merge, and exit-code semantics are unchanged (R4).
- `test/cli.test.ts` covers R1, R2 (Covers R11), and R3 with the scenarios enumerated in U2, following the existing fetch-stub style.
- `vp test` and `vp run typecheck` pass.
- No changes outside `packages/release-lock/src` and `packages/release-lock/test`.

## Sources & Research

- GitHub issue `hyperlapse122/dotfiles#103` (P1, confidence 75, reviewer: testing) — problem statement, three-part suggested fix, and evidence pointers.
- `packages/release-lock/src/cli.ts:34-84` — dispatch switch, catch branch, emission nesting, executable tail.
- `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` — origin plan; R11 carry-forward contract promised as a U2 test scenario there.
- `packages/release-lock/test/github.test.ts` — the fetch-stub pattern the new tests follow; `packages/release-lock/test/lock.test.ts` — existing overlay-merge coverage.
- Local research only: six per-resolver test files establish a strong local pattern, so no external research was needed.
