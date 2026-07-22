---
title: Fix stale Vite+ task cache for bun-compiled CLIs - Plan
type: fix
date: 2026-07-23
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix stale Vite+ task cache for bun-compiled CLIs - Plan

## Goal Capsule

- **Objective:** Make `vp run build` rebuild `packages/figma-auth` and `packages/kimi-reconcile` whenever their source or manifest inputs change, with no manual `--force`/cache-clean step.
- **Authority:** This plan governs scope; the vendored Vite+ docs under `packages/node_modules/vite-plus/docs/` govern cache-config semantics; repo conventions in `packages/README.md` and `packages/AGENTS.md` govern validation.
- **Stop conditions:** Do not migrate the two members off `bun build --compile`; do not touch the four `vp pack` members; do not edit the chezmoi install scripts (their fingerprints are already correct).
- **Execution profile:** Two small units, config + docs. Smoke-first verification (cache-miss on source edit) rather than new unit tests.

## Product Contract

### Summary

Declare explicit `input`/`output` sets on the `build` task of the two workspace members that compile with the external `bun` binary, so Vite+ Task caching invalidates on real source changes, and correct the stale cache references in `packages/README.md`.

### Problem Frame

Vite+ caches `run.tasks` by default with `input: [{ auto: true }]` — file reads are tracked while the command runs (`packages/node_modules/vite-plus/docs/config/run.md:228-233`). Automatic tracking can miss files a command actually reads (`docs/guide/automatic-data-tracking.md:42-46`); the miss was observed here with `bun build --compile` running as an external process, and `figma-auth`/`kimi-reconcile` are the only members whose `build` works that way. The result: after source-only changes landed (gemini support in `82ded2b`, kimi-code support in `6ffca4c`), `vp run build` replayed the cached build. The chezmoi install scripts (`.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl:19`, `run_onchange_after_build-kimi-reconcile.sh.tmpl:7`) correctly fingerprinted the change and reran, but installed the stale `dist/` binary and recorded success. The user's workaround, `vp run build --force`, "worked" only because extra arguments are part of the cache key (`docs/guide/cache.md:9`) — `vp run` has no `--force` flag.

### Requirements

- R1. Editing any file under `packages/figma-auth/src/**` causes the next `vp run build` to rebuild (cache miss), not replay.
- R2. Editing any file under `packages/kimi-reconcile/src/**` causes the next `vp run build` to rebuild (cache miss), not replay.
- R3. The declared input sets mirror the fingerprint glob sets in the two chezmoi install scripts (member `src/**` and manifests, workspace-root manifests), so the vp task layer and the chezmoi layer invalidate on the same changes; repo-root `mise.toml` is mirrored only when vp accepts the parent-traversing glob per KTD-2, and its omission is an accepted residual mitigated by `vp cache clean`.
- R4. An unedited second run of `vp run build` still cache-hits (caching is preserved, not disabled).
- R5. `packages/README.md` names the real cache location (`packages/node_modules/.vite/task-cache`, `vp cache clean`) instead of the stale `packages/.turbo/` references, and its new-package recipe mentions cache inputs for external-binary build commands.

### Scope Boundaries

- Provisionally out of scope: the four `vp pack` members. Cooperative tracking is documented only for `vp build` (`automatic-data-tracking.md:50`), not for `vp pack` spawned as an external command, so U1 smoke-tests one pack member for the same staleness. If it rebuilds on a source edit, the four stay out of scope on that observed evidence; if it cache-hits, they receive the same explicit-input treatment (member `src/**` + manifests, workspace manifests, `output: ["dist/**"]`).
- Out of scope: changing the build tool (`bun build --compile` stays; it produces the single-file executables the install scripts expect).

#### Deferred to Follow-Up Work

- The `typecheck` (`tsc`, also an external binary) and `test` (`vp test`) tasks share the auto-tracking limitation class. No staleness has been observed there; add explicit inputs if it appears.

## Planning Contract

### Key Technical Decisions

- KTD-1. **Explicit `input`/`output` on the two `bun build --compile` build tasks**, chosen over keeping `{ auto: true }` (demonstrated to miss external-binary reads) and over disabling caching for the tasks (R4 requires cache hits on unchanged inputs). Follows the documented override pattern at `docs/config/run.md:247-256` and `docs/guide/automatic-data-tracking.md:64-76`.
- KTD-2. **Input set mirrors the chezmoi script fingerprints** — package `src/**`, `package.json`, `tsconfig.json`, `vite.config.ts`, plus workspace-root `package.json`, `bun.lock`, `bunfig.toml`, `vite.config.ts` via `{ pattern: ..., base: "workspace" }` (`docs/config/run.md:258-289`). Repo-root `mise.toml` is in the script fingerprints too; include it as `{ pattern: "../mise.toml", base: "workspace" }` only if vp accepts a parent-traversing glob (unverified in vendored docs), otherwise omit it — a bun toolchain bump may then still replay a cached build, mitigated by `vp cache clean`.
- KTD-3. **Fully explicit inputs, no `{ auto: true }`**, so the fingerprint is the declared set and nothing the external `bun` binary happens to touch.

### Assumptions

- A1. `kimi-reconcile` is in scope: identical build shape and the same latent defect; the user reported the figma-auth instance of one bug class.
- A2. No chezmoi script changes are needed — the defect is solely in the vp task layer; script fingerprints already fire correctly.
- A3. Existing stale cache entries on user hosts need no cleanup: this change edits `vite.config.ts`, which is itself a declared input, so old entries invalidate on first run.

## Implementation Units

### U1. Explicit cache inputs for the bun-compiled build tasks

- **Goal:** `vp run build` for figma-auth and kimi-reconcile rebuilds exactly when a declared input changes.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none
- **Files:** `packages/figma-auth/vite.config.ts`, `packages/kimi-reconcile/vite.config.ts`
- **Approach:** On each member's `run.tasks.build`, add `input` per KTD-2/KTD-3 and `output: ["dist/**"]`; keep `command` and `dependsOn` unchanged. Verify whether `{ pattern: "../mise.toml", base: "workspace" }` is accepted (config loads, task runs); drop that one entry if rejected and note the drop in the commit message. Also probe one `vp pack` member (e.g. mxm4-haptic) with the smoke sequence; only if it cache-hits on a source edit, apply the same input/output pattern to all four pack members' `build` tasks.
- **Patterns to follow:** Documented override shape at `packages/node_modules/vite-plus/docs/config/run.md:247-256`; sibling task blocks in the same files for formatting.
- **Execution note:** This is config work; prove it with the cache smoke sequence below, not new unit tests.
- **Test scenarios:**
  - `vp cache clean`, then `vp run build` in each member → build executes, `dist/` binary produced.
  - Immediate second `vp run build` → cache hit, command skipped (R4).
  - Edit a file under `src/**` (e.g. touch a comment) → next `vp run build` reports a cache miss and rebuilds (R1, R2). Revert the edit → the next run either misses or hits the original content-addressed entry; both pass, since a hit restores the original binary.
  - Touch the member `package.json` and `packages/bun.lock` (whitespace-only, reverted after) → each triggers a cache miss (R3).
  - Pack-member probe (once, e.g. mxm4-haptic): clean → build → src edit → re-run. A cache miss keeps the four `vp pack` members out of scope per Scope Boundaries; a cache hit extends the explicit-input treatment to them.
  - Delete `dist/`, re-run with otherwise-unchanged inputs → cached output files are restored or rebuilt; install target exists.
  - `vp check` and `vp test` pass for the workspace (per `packages/AGENTS.md`).
- **Verification:** All scenarios above pass on both members; `git diff --check` clean.

### U2. Correct cache references in packages/README.md

- **Goal:** README cache documentation matches Vite+ reality.
- **Requirements:** R5
- **Dependencies:** U1 (the documented input pattern should match the shipped config)
- **Files:** `packages/README.md`
- **Approach:** Replace the stale `packages/.turbo/` mentions (lines ~70 and ~104) with `packages/node_modules/.vite/task-cache` plus `vp cache clean`; in the new-package recipe area (lines ~138-165), add one line: build tasks that shell out to external binaries (e.g. `bun build --compile`) must declare explicit `input`/`output` on the task.
- **Test scenarios:** Test expectation: none — documentation-only unit; verify by reading the rendered diff.
- **Verification:** No `.turbo/` reference remains; the new-cache location and the external-binary input rule are stated.

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Workspace checks | `mise -C packages exec -- vp check` | lint/format/typecheck green |
| Workspace tests | `mise -C packages exec -- vp test` | existing vitest suites unaffected |
| Cache smoke (both members + one pack probe) | U1 scenario sequence: clean → build → replay-hit → src edit → miss → manifest touch → miss → revert → miss-or-restore | R1, R2, R3, R4 |
| Diff hygiene | `git diff --check` | no whitespace errors |

## Definition of Done

- Both `build` tasks carry explicit `input`/`output` per KTD-1..3 and the U1 smoke sequence passes on both members; the pack-member probe outcome is recorded (pack members excluded on observed evidence, or the fix extended to them).
- README contains no `.turbo/` reference and documents the real cache location plus the external-binary input rule.
- `vp check` and `vp test` pass; `git diff --check` is clean; the diff contains no abandoned-attempt code.
