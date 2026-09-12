---
title: Fail Release Lock Refresh on Disappeared Skill Subtree - Plan
type: fix
date: 2026-09-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fail Release Lock Refresh on Disappeared Skill Subtree - Plan

## Goal Capsule

- **Objective:** Fail the `packages/release-lock` refresh loudly when an upstream repository relocates or removes a pinned skill subtree, preventing `refresh-release-lock.yml` from advancing branch pins to broken commits and preventing `chezmoi apply` from silently deleting skills across managed hosts.
- **Means:** Extend `ToolSpec` and `gitRef` resolution in `packages/release-lock` to assert that the target `skillPath` exists at the resolved commit sha via GitHub's contents API, raising a `ResolutionError` if missing or unreachable.
- **Authority:** This plan; GitHub Issue #469; `.chezmoiexternals/ai-agents.toml` external skill contract.
- **Execution profile:** TypeScript modifications in `packages/release-lock` (`types.ts`, `registry.ts`, `git-ref.ts`, `resolve-all.ts`) and accompanying tests.
- **Stop conditions:** Stop and report if GitHub contents API cannot verify subtrees with branch shas, or if existing `gitRef` entries fail verification against live repositories.
- **Tail ownership:** LFG owns commit, push, PR, and CI watch.

---

## Product Contract

### Summary

When upstream branch pins advance in `refresh-release-lock.yml`, `gitRef` resolution previously recorded the commit sha from `git ls-remote` without verifying that the skill directory existed in that commit. If upstream removed or relocated the skill directory (such as in a monorepo like `cursor/plugins`), the lock advanced, the archive downloaded, but `include = ["*/<skillPath>/**"]` matched nothing, causing `chezmoi apply` to silently delete `~/.agents/skills/<name>`.

We fix this by asserting that `skillPath` exists at the resolved sha during `gitRef` resolution. If it does not exist (HTTP 404), `resolveGitRef` raises a `ResolutionError`. In `resolveAll`, this failure routes into `failures`, causing `refresh-release-lock.yml` to fail while keeping the previous working lock entry via `mergeLocks`.

### Problem Frame

Reported in Issue #469 after #468 added `unslop` and `deslop` from the active monorepo `cursor/plugins`. While dormant repos rarely move subtrees, active monorepos frequently reorganize. Because `.ci/check-release-lock-digests.sh` only checks `.artifacts` and `gitRef` entries have no artifacts block, no CI check catches missing subtrees after `git ls-remote` advances the sha. The resolver is the single authoritative place to catch this before writing or committing the lock.

### Requirements

- R1. `ToolSpec` in `packages/release-lock/src/types.ts` supports an optional `skillPath?: string` field for `gitRef` tools.
- R2. When resolving a `gitRef` tool in `packages/release-lock/src/git-ref.ts`, the target subtree path is determined as `spec.skillPath ?? `skills/${name}``, matching `.chezmoiexternals/ai-agents.toml`.
- R3. After `resolveGitRef` parses the 40-character sha from `git ls-remote`, it asserts that `skillPath` exists at that commit sha by querying the GitHub Contents API (`repos/${spec.source}/contents/${skillPath}?ref=${sha}`).
- R4. If the subtree does not exist (HTTP 404), `resolveGitRef` raises a `ResolutionError` stating that `skillPath` does not exist at the resolved sha.
- R5. If the request fails due to an unexpected HTTP status or network error, `resolveGitRef` raises a `ResolutionError` detailing the error.
- R6. `resolveGitRef` accepts an optional `token?: string` parameter and uses `authHeaders(token)` for the GitHub API request.
- R7. `RESOLVERS.gitRef` in `packages/release-lock/src/resolve-all.ts` passes the caller-provided `token` to `resolveGitRef`.
- R8. `REGISTRY` in `packages/release-lock/src/registry.ts` declares `skillPath: "pstack/skills/unslop"` for `unslop` and `skillPath: "cursor-team-kit/skills/deslop"` for `deslop`.
- R9. Unit tests in `packages/release-lock/test/git-ref.test.ts` cover successful subtree verification, custom vs default `skillPath`, 404 missing subtree rejection, HTTP error handling, and authentication token header propagation.

### Key Decisions

- **Verify via GitHub Contents API rather than git clone/archive.** Governs R3. `git archive --remote` is rejected by GitHub (HTTP 422), and `git ls-tree` requires a local clone which `packages/release-lock` does not maintain. GitHub Contents API (`/repos/{owner}/{repo}/contents/{path}?ref={sha}`) checks directory and file existence directly over HTTPS in a single lightweight call.
- **Default `skillPath` to `skills/<name>`.** Governs R2. Mirrors `.chezmoiexternals/ai-agents.toml`, where skills without an explicit `skillPath` assume `skills/<name>`. Only tools with non-standard paths (`unslop`, `deslop`) need an explicit `skillPath` in `REGISTRY`.
- **Route resolution failures through existing `ResolutionError` pipeline.** Governs R4, R5. `resolve-all.ts` catches `ResolutionError` and collects it into `failures`. This ensures `--out` merges and preserves the prior good sha in `.chezmoidata/releases.json` while signaling failure to the workflow runner.

### Scope Boundaries

- In scope: `packages/release-lock` types, registry, gitRef resolver, resolveAll dispatch, and tests.
- Out of scope: Adding network verification to template render time (rendering must remain zero-network-IO).
- Out of scope: Modifying `.chezmoiexternals/ai-agents.toml` or `.chezmoidata/agents.yaml` (their schemas and mappings already support `skillPath`).

### Sources

- GitHub Issue #469: `fix(release-lock): fail the refresh when a pinned skill subtree disappears`
- `.chezmoiexternals/ai-agents.toml:226-242` - Skill path resolution and component stripping logic
- `packages/release-lock/src/git-ref.ts` - Existing git ref resolution
- `packages/release-lock/src/github.ts` - `authHeaders` and `ResolutionError` patterns

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Extend `ToolSpec` in `types.ts` with `readonly skillPath?: string;`**. Keeps the interface declarative and consistent with other resolver-specific spec fields (`ref`, `tagPrefix`, `vendor`).
- KTD2. **Import `authHeaders` from `./github.js` and `fetchWithRetry` from `./http.js` into `git-ref.ts`**. Avoids code duplication and ensures transient rate-limiting or network glitches are retried with standard exponential backoff.
- KTD3. **Inject `token` into `RESOLVERS.gitRef` in `resolve-all.ts`**. `resolveAll(token)` already passes `token` to all other resolvers; `gitRef` was the only resolver ignoring it.

### Implementation Constraints

- Zero external package additions: use existing Node / Vite+ / TypeScript utilities.
- Keep `GitExec = defaultExec` parameter in `resolveGitRef` for backwards compatibility in tests.
- Tests must not make real network requests: stub `globalThis.fetch` in test suites.

### Assumptions

- All `gitRef` repositories currently in `REGISTRY` (`cursor/plugins`, `shadcn/improve`, `ayghri/i-have-adhd`, `vercel-labs/agent-skills`) are hosted on GitHub.
- `fetchWithRetry` preserves 404 responses immediately without retrying, which is optimal for missing subtree detection.

### Sequencing

- U1: Update types and registry declarations.
- U2: Implement subtree existence check in `git-ref.ts` and update `resolve-all.ts`.
- U3: Write comprehensive unit tests in `git-ref.test.ts` and `registry.test.ts`, verifying full test suite and typecheck pass.

---

## Implementation Units

### U1. Extend `ToolSpec` and `REGISTRY` with `skillPath`

- **Goal:** Allow `gitRef` specs to declare their repository subtree path.
- **Requirements:** R1, R8.
- **Files:** `packages/release-lock/src/types.ts`, `packages/release-lock/src/registry.ts`.
- **Approach:**
  - In `types.ts`, add `readonly skillPath?: string;` to `ToolSpec`.
  - In `registry.ts`, add `skillPath: "pstack/skills/unslop"` to `unslop` and `skillPath: "cursor-team-kit/skills/deslop"` to `deslop`.
- **Verification:** `mise exec -- vp check` passes with no type errors.

### U2. Assert Subtree Existence in `resolveGitRef`

- **Goal:** Fail resolution with `ResolutionError` if the skill subtree does not exist at the resolved sha.
- **Requirements:** R2, R3, R4, R5, R6, R7.
- **Files:** `packages/release-lock/src/git-ref.ts`, `packages/release-lock/src/resolve-all.ts`.
- **Approach:**
  - In `git-ref.ts`, import `authHeaders` from `./github.js` and `fetchWithRetry` from `./http.js`.
  - Update `resolveGitRef` to accept `token?: string`.
  - Resolve `skillPath = spec.skillPath ?? `skills/${name}``.
  - Perform GET on `https://api.github.com/repos/${spec.source}/contents/${skillPath}?ref=${sha}` with `authHeaders(token)`.
  - If status 404, throw `ResolutionError(spec.source, `${name}: skillPath "${skillPath}" does not exist at ${sha}`)`.
  - If status not ok, throw `ResolutionError(spec.source, `${name}: verifying skillPath "${skillPath}" returned HTTP ${response.status}`)`.
  - If fetch throws, catch and throw `ResolutionError(spec.source, `${name}: verifying skillPath "${skillPath}" failed: ${detail}`)`.
  - In `resolve-all.ts`, pass `token` to `resolveGitRef(name, spec, defaultExec, token)`.
- **Verification:** Run `mise exec -- vp check`.

### U3. Comprehensive Unit Tests and Validation

- **Goal:** Verify all success and failure branches with automated tests.
- **Requirements:** R9.
- **Files:** `packages/release-lock/test/git-ref.test.ts`, `packages/release-lock/test/registry.test.ts`.
- **Approach:**
  - Update `test/git-ref.test.ts` to stub `globalThis.fetch`.
  - Add test cases:
    - 200 OK: resolves successfully with sha.
    - Default `skillPath`: requests `skills/<name>?ref=<sha>`.
    - Explicit `skillPath`: requests declared path `?ref=<sha>`.
    - 404 Not Found: throws `ResolutionError` naming tool, source, path, and sha.
    - 500 Server Error: throws `ResolutionError`.
    - Fetch network failure: throws `ResolutionError`.
    - Token forwarding: verifies `Authorization: Bearer <token>` header is sent when token provided.
  - In `test/registry.test.ts`, add assertion verifying `unslop` and `deslop` define expected `skillPath` properties.
- **Verification:** `mise exec -- vp test` passes all tests.

---

## Verification Contract

- Automated checks:
  - `mise exec -- vp test` in `packages/release-lock` passes 100%.
  - `mise exec -- vp check` in `packages/release-lock` reports 0 lint, type, or format errors.
  - Run CLI check against actual GitHub API (if network/credentials permit) or verified against stubs.
- Regression safety:
  - All existing 253 tests continue passing without regression.

---

## Definition of Done

- `ToolSpec` and `REGISTRY` declare `skillPath` for `unslop` and `deslop`.
- `resolveGitRef` asserts `skillPath` at the resolved commit sha.
- 404 responses raise `ResolutionError`.
- All tests pass in `packages/release-lock`.
