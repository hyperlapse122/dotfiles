---
title: Test Registry Asset Selector Byte-Parity - Plan
type: feat
date: 2026-07-28
topic: release-lock-registry-selector-tests
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Test Registry Asset Selector Byte-Parity - Plan

## Goal Capsule

- **Objective:** Commit the V4 baseline as a durable regression test — `packages/release-lock/test/registry.test.ts` asserts, for every `REGISTRY` tool with an `asset` selector, the exact upstream asset name for each targeted platform, and asserts every version-only entry carries no selector — so a future selector edit that still matches some real upstream asset fails the suite instead of locking a wrong URL with a valid digest.
- **Authority:** GitHub issue `hyperlapse122/dotfiles#104` governs scope; the committed `.chezmoidata/releases.json` lock supplies the V4 baseline asset names; the existing `packages/release-lock/test/` files govern test style.
- **Execution profile:** Lightweight — one new test file, no `src/` changes; `vp test` and `vp run typecheck` verified, no live CLI run.
- **Stop conditions:** Stop rather than broaden scope if the change appears to require editing `src/registry.ts`, any resolver, or anything outside `packages/release-lock/test`.
- **Tail ownership:** The LFG pipeline owns commit, push, pull-request creation, and CI monitoring.

## Product Contract

### Summary

Add `packages/release-lock/test/registry.test.ts` — the first test that imports `REGISTRY` — containing a static expected-asset-name table (the committed form of the V4 baseline) and table-driven assertions over every registered tool and platform.

### Problem Frame

DoD6 of `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` requires migrated tools to resolve byte-identical URLs to the pre-migration render on all three OSes. The ~20 selector functions in `packages/release-lock/src/registry.ts` encode that parity (buf's linux-only `aarch64`, kimi's `win32`/`x64`, shellcheck's tag-embedded name, codegraph's win32 zip, the musl/emulated cases), but no test exercises them: every resolver test builds an inline throwaway `ToolSpec`, and `grep` of `packages/release-lock/test/` for `REGISTRY` returns nothing. The only guard was the origin plan's V0/V4 manual baseline comparison, which that plan's Risks section calls "unrecoverable once templates change." The refresh-time hard-error net (`.github/workflows/refresh-release-lock.yml`) only fires when a selector matches *no* published asset; a selector edit that still matches some real upstream asset locks a wrong URL with a valid digest and passes. After the migration merged, no durable regression check remains.

### Requirements

- R1. `test/registry.test.ts` imports `REGISTRY` from `../src/registry.js` and asserts, per tool with an `asset` selector, the exact expected asset name for each targeted platform, using the V4 baseline values (e.g. kimi windows → `kimi-code-win32-x64.zip`, buf linux-arm64 → `buf-Linux-aarch64.tar.gz`, shellcheck → `shellcheck-<tag>.linux.x86_64.tar.gz`) (issue suggested fix, part 1).
- R2. The same file asserts that every version-only entry (kubectl, helm, glab, the npm packages, the gitRef skills, the githubTag pins, the vendorManifest tools, and the version-only githubRelease entries) carries no `asset` selector (issue suggested fix, part 2).
- R3. The test needs no network and no lock-file read: expected names are static literals with a sentinel tag substituted into the tag-embedding selectors, so the test is immune to version drift from the hourly lock refresh.
- R4. No changes to `packages/release-lock/src/**` or any other file outside the new test.

### Key Decisions

- KD1. The expected table is keyed `tool → platformKey → assetName | null`, covering `ALL_PLATFORMS` for every selector tool plus `MUSL_PLATFORMS` for `agent-browser` (`linuxMusl: true`), with `null` for deliberately untargeted platforms (jq non-darwin, pi/aoe windows). Rationale: an explicit `null` row proves the non-target is deliberate — a missing row and a wrongly-null selector are indistinguishable without it. (session-settled: user-directed — issue #104's "for each targeted platform", extended to record the deliberate nulls the README documents.)
- KD2. Tag-embedding selectors (shellcheck, wasm-pack, gh, garden, docker-credential-helpers) are called with one sentinel tag (`v0.0.0`), and the expected names embed that sentinel verbatim — including `gh`/`garden`'s `versionFromTag` stripping (`gh_0.0.0_…`, `garden-0.0.0-…`) and docker-credential-helpers' raw-tag embedding (`…-v0.0.0.linux-amd64`). Rationale: parity lives in the name *shape*, not the version; a static sentinel keeps the test green across hourly lock refreshes, unlike reading `.chezmoidata/releases.json` (which would also make a unit test depend on a data file outside the package). (session-settled: user-directed — issue #104's `<tag>` placeholder.)
- KD3. Coverage of the selector set is asserted by set difference: `Object.keys(REGISTRY)` partitioned into tools present in the table (must have `asset`) and tools absent (must not have `asset`). Rationale: adding a selector tool without extending the table fails loudly (untested selector), and adding a version-only tool is covered by the no-selector assertion with no edit — the two failure directions the issue names. Chosen over a hardcoded version-only list, which decays silently as tools are added.

### Scope Boundaries

- Out of scope: editing `src/registry.ts` or any resolver; testing resolver-level asset *matching* against stubbed API responses (already covered per-kind by the existing test files, e.g. `test/github.test.ts`); asserting `emulatedPlatforms` borrowing mechanics (resolver behavior, covered in `test/github.test.ts`); reading or validating `.chezmoidata/releases.json`.

## Planning Contract

### Key Technical Decisions

KTD1 (= KD1), KTD2 (= KD2), KTD3 (= KD3) under Key Decisions above are the technical decisions; no additional plan-level forks remain.

### Assumptions

- `AssetSelector`'s second parameter is the upstream tag verbatim (per `src/types.ts` and selector usage), so the sentinel drives every tag-embedding branch.
- Every tag-embedding selector (shellcheck, wasm-pack, gh, garden, docker-credential-helpers) interpolates the tag verbatim or via `versionFromTag` — none performs semver parsing or tag-shape validation that could reject or reshape the `v0.0.0` sentinel (audited in `src/registry.ts` during planning).
- The V4 baseline names are not circular selector output: each locked name matched a real published upstream asset at resolution time (the digest-carrying release response is how its sha256 was recorded — a wrong name hard-errors the refresh), and the origin plan's V4 comparison checked the same names against the pre-migration render. The table therefore freezes an externally validated baseline, not an unverified one.
- `vite-plus/test` (Vitest re-export) supports `describe`/`test`/`expect` with `toBe`/`toEqual` — established by every existing test file.

### Open Questions

None. The expected names were captured from the committed lock during planning (Sources & Research).

## Implementation Units

### U1. Add test/registry.test.ts asserting per-platform asset names and version-only purity

(Only unit.)

---

### U1. Add test/registry.test.ts asserting per-platform asset names and version-only purity

- **Goal:** The ~20 selector functions and the version-only contract fail loudly on regression.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none
- **Files:**
  - Create `packages/release-lock/test/registry.test.ts`
- **Approach:** Import `REGISTRY` from `../src/registry.js` and `ALL_PLATFORMS`, `MUSL_PLATFORMS`, `platformKey` from `../src/platforms.js`. Define `const TAG = "v0.0.0"` and a static `EXPECTED: Record<string, Record<string, string | null>>` table keyed by tool name then `PlatformKey`, populated with the V4 baseline names captured from `.chezmoidata/releases.json` at planning time (sentinel tag substituted). For each tool in the table, iterate its platforms — `ALL_PLATFORMS`, plus `MUSL_PLATFORMS` when the spec has `linuxMusl` — and assert `spec.asset?.(platform, TAG)` `toBe` the table value (including the `null` rows). Then assert the partition (KD3): every `REGISTRY` key is either in `EXPECTED` with an `asset` function present, or absent from `EXPECTED` with `asset` undefined.
- **Patterns to follow:** the existing test files — `import { describe, expect, test } from "vite-plus/test"`, one `describe` per concern, JSDoc-free self-naming tests; no fetch stub needed (selectors are pure).
- **Test scenarios:**
  - Per-tool name parity (R1): each of the 20 selector tools asserts every platform row, including the parity traps the issue names — buf `buf-Linux-aarch64.tar.gz` vs `buf-Darwin-arm64.tar.gz`; kimi `kimi-code-win32-x64.zip`; shellcheck `shellcheck-v0.0.0.linux.x86_64.tar.gz` and arch-less `shellcheck-v0.0.0.zip` on both windows rows; codegraph `codegraph-win32-x64.zip`; agent-browser musl rows `agent-browser-linux-musl-x64`/`-arm64`; uv/codex/wasm-pack musl-target linux rows; marksman's three unrelated shapes; gh's `gh_0.0.0_macOS_amd64.zip` (macOS spelling, stripped `v`); docker-credential-helpers' per-OS store names; wasm-pack `.tar.gz` on windows; minikube `.tar.gz` on windows.
  - Deliberate nulls (R1): jq returns `null` on all four non-darwin rows; pi and aoe return `null` on both windows rows.
  - Version-only purity (R2, KD3): every `REGISTRY` key absent from `EXPECTED` — kubectl, helm, playwright-cli, compound-engineering, open-design, oh-my-openagent, opencode-wakatime, @ex-machina/opencode-anthropic-auth, glab, the seven npm entries, claude, agy, winbox, improve, pi-compound-engineering — has `asset` undefined.
  - Table completeness (KD3): every `REGISTRY` key present in `EXPECTED` has `typeof spec.asset === "function"`; no `REGISTRY` key is left unclassified (the partition covers all keys exactly once).
  - Emulated-name evidence: the borrowed amd64 names the emulated lock keys use are pinned by the amd64 rows themselves (agent-browser/garden/minikube/wasm-pack windows-amd64), so an edit breaking the emulated arm64 URL breaks the row it borrows from.
- **Verification:** `vp test` passes with the new file; one manual mutation check — flip one selector (e.g. buf's linux `aarch64` → `arm64`) and confirm the suite goes red, then restore. `vp run typecheck` passes.

## Verification Contract

- `vp test` (network-free) passes, including `test/registry.test.ts`.
- `vp run typecheck` passes.
- One manual mutation check per the U1 verification note, restored afterward.

## Definition of Done

- `packages/release-lock/test/registry.test.ts` exists, imports `REGISTRY`, and covers R1–R3 with the scenarios enumerated in U1.
- No changes outside `packages/release-lock/test` (R4).
- `vp test` and `vp run typecheck` pass.

## Risks

- **Version drift invalidates static names.** Hourly lock refreshes bump versions; the sentinel-tag design (KD2) keeps names version-independent, and no selector embeds anything but the tag. Residual: a future selector that embeds something volatile (e.g. a date) would need a second sentinel — documented here, not handled.
- **A legitimate upstream rename now fails the test.** That is the intended behavior — the test is the parity contract; the fix is updating selector and table together in one commit.

## Sources & Research

- GitHub issue `hyperlapse122/dotfiles#104` (P1, confidence 75, reviewer: testing) — problem statement, suggested fix, evidence pointers.
- `packages/release-lock/src/registry.ts` — the 20 selector functions and 21 version-only entries under test.
- `packages/release-lock/src/platforms.ts` — `ALL_PLATFORMS`, `MUSL_PLATFORMS`, `platformKey`, and the shared spelling helpers the selectors compose.
- `packages/release-lock/src/types.ts` — `AssetSelector` signature `(platform, tag) => string | null`.
- `.chezmoidata/releases.json` (committed lock) — the V4 baseline asset names per tool/platform, captured during planning (e.g. `buf-Linux-aarch64.tar.gz`, `kimi-code-win32-x64.zip`, `shellcheck-v0.11.0.linux.x86_64.tar.gz`, `agent-browser-linux-musl-x64`).
- `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` — DoD6 parity contract and the "baseline unrecoverable once templates change" risk this test retires.
- `packages/release-lock/test/github.test.ts` — the local test-style pattern (vite-plus/test imports, describe/test shape).
- Local research only: seven sibling test files establish a strong local pattern, and the baseline values live in the committed lock, so no external research was needed.
