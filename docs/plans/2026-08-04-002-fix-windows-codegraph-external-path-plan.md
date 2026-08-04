---
title: Windows Codegraph External Path - Plan
type: fix
date: 2026-08-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Windows Codegraph External Path - Plan

## Goal Capsule

- **Objective:** Make the Codegraph external valid on Windows by emitting a home-relative `targetPath` that still resolves to `%LOCALAPPDATA%\codegraph\current`.
- **Authority:** GitHub issue #154 defines the failure. Repository ownership rules and chezmoi's external-path contract constrain the fix.
- **Execution profile:** Small configuration bug fix with native Windows regression coverage.
- **Stop condition:** Stop if Local AppData is outside the Windows home represented by chezmoi's destination tree. That location cannot be expressed as a managed external without changing Codegraph ownership or install location.
- **Tail ownership:** Ship through the repository pull-request and CI workflow.

---

## Product Contract

### Summary

Windows apply currently rejects the Codegraph external before installation because its rendered `targetPath` is absolute. The fix keeps Codegraph under the existing Local AppData directory while giving chezmoi the relative path its external parser requires.

### Problem Frame

`.chezmoiexternals/ai-agents.toml` builds the Windows Codegraph target with `joinPath (env "LOCALAPPDATA") "codegraph" "current"`. On a normal Windows profile this renders as an absolute drive path such as `C:\Users\h82\AppData\Local\codegraph\current`. Chezmoi rejects that value with `path is not relative`, so apply cannot construct the external state. The paired PowerShell reconciler already expects the same Local AppData installation and adds its `bin` directory to the user PATH.

### Requirements

- R1. The rendered Windows Codegraph `targetPath` is relative to the managed Windows home and is accepted by the external-path contract.
- R2. The resolved target remains `%LOCALAPPDATA%\codegraph\current` for the standard Windows profile used by the repository and CI.
- R3. Linux and macOS keep the versioned `.codegraph/versions/<tag>` target unchanged.
- R4. Native Windows CI fails when the Codegraph external renders an absolute target or drifts from the PowerShell reconciler's installation directory.

### Acceptance Examples

- AE1. **Covers R1, R2.** Given the Windows CI profile, when `ai-agents.toml` renders, then the Codegraph stanza contains a relative Local AppData path and no drive-qualified `targetPath`.
- AE2. **Covers R3.** Given a Linux or macOS render, when the Codegraph stanza is inspected, then it still targets `.codegraph/versions/<locked-tag>`.
- AE3. **Covers R4.** Given a future change that restores `%LOCALAPPDATA%` as an absolute `targetPath`, when the Windows internals assertion runs, then the workflow fails before artifacts are accepted.

### Scope Boundaries

**In scope:** the Codegraph `targetPath` calculation in `.chezmoiexternals/ai-agents.toml` and a focused assertion in `.github/workflows/render-dotfiles.yml`.

**Out of scope:** Codegraph release resolution, archive layout, checksums, POSIX version pruning, Windows PATH mutation behavior, and any live apply to the user's home directory.

### Source

- [GitHub issue #154](https://github.com/hyperlapse122/dotfiles/issues/154)
- [Chezmoi external format](https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/)
- `.chezmoiscripts/00-tools/run_onchange_after_codegraph.ps1.tmpl`

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Render a normalized home-relative Local AppData path.** Normalize `.chezmoi.homeDir` and `LOCALAPPDATA` to forward slashes before containment and prefix operations, prove that Local AppData is inside the managed home, strip the home prefix, and append `codegraph/current`. This preserves a redirected in-profile Local AppData value without hard-coding `AppData/Local`. An out-of-home value fails the full external render because silently omitting Codegraph would preserve stale ownership and hide an unsupported layout.
- KTD2. **Keep one install-location invariant across the external and reconciler.** The external owns the archive under Local AppData. The existing PowerShell script remains the runtime consumer of that location and does not gain a second path policy.
- KTD3. **Guard the rendered contract in the native Windows workflow.** Extend the Windows internals checks to parse the rendered Codegraph stanza and assert that its target is relative and resolves under the CI profile's Local AppData directory. A template-render-only success is insufficient because the original defect is valid template output that violates external semantics.

### Assumptions

- The managed Windows profile keeps `LOCALAPPDATA` beneath `.chezmoi.homeDir`. A real apply uses that home as the destination root. Isolated render checks must resolve the result against the same profile rather than an unrelated scratch destination.
- Chezmoi accepts forward-slash relative paths in the rendered TOML on Windows.
- The existing locked Codegraph archive still extracts a `bin` directory under `current`, as required by the PowerShell PATH reconciler.

### Sequencing

Implement the path derivation first. Then add the native Windows assertion against the resulting stanza. Verify POSIX rendering after the Windows contract is fixed.

---

## Implementation Units

### U1. Emit a valid Windows Codegraph external target

- **Goal:** Satisfy R1-R3 without changing Codegraph's install ownership or POSIX layout.
- **Requirements:** R1, R2, R3.
- **Dependencies:** None.
- **Files:** `.chezmoiexternals/ai-agents.toml`.
- **Approach:** Add a small Windows-only template calculation near the Codegraph stanza. Normalize the home and Local AppData strings to forward slashes before containment and prefix operations, validate the containment boundary, derive the home-relative segment, and use that segment for `targetPath`. Leave the non-Windows target expression byte-for-byte unchanged where practical.
- **Patterns:** Use the existing fail-closed template validation style in `.chezmoiexternals/ai-agents.toml`. Keep the target as a relative TOML string like other externals in the file.
- **Test scenarios:**
  - Render with a standard Windows profile and confirm the target is relative and resolves to the same directory as `%LOCALAPPDATA%\codegraph\current`.
  - Render with an out-of-home Local AppData override and confirm the template fails with a specific containment message instead of producing an invalid absolute target.
  - Render on Linux and confirm the target remains `.codegraph/versions/<locked-tag>`.
- **Verification:** V1, V2, V3, V5.

### U2. Add native Windows regression coverage

- **Goal:** Make the issue #154 failure mode visible in CI.
- **Requirements:** R4.
- **Dependencies:** U1.
- **Files:** `.github/workflows/render-dotfiles.yml`.
- **Approach:** Add a focused assertion after the Windows internals render. Extract the `[codegraph]` stanza from the rendered `ai-agents.toml`, require a relative `targetPath`, resolve it against the runner profile used as `.chezmoi.homeDir`, and compare the result with `%LOCALAPPDATA%\codegraph\current`. Put the validation in a small PowerShell function so the workflow can feed it the real rendered value and two synthetic negative fixtures. Keep the assertion independent of downloads and live home mutation.
- **Patterns:** Follow the adjacent Windows Figma and compound-engineering assertions that inspect `_artifacts\rendered-internals\.chezmoiexternals\ai-agents.toml` and fail with specific messages.
- **Test scenarios:**
  - The current fixed stanza passes on `windows-latest`.
  - A synthetic drive-qualified target is rejected by the assertion function.
  - A synthetic relative target that resolves outside the profile's Local AppData Codegraph directory is rejected.
- **Verification:** V2, V4, V5.

---

## Verification Contract

- V1. Render `.chezmoiexternals/ai-agents.toml` through an isolated `chezmoi execute-template` invocation with `--source "$PWD"`, an empty config, a throwaway destination, and a stub `op`. Expect a successful native render and the unchanged POSIX Codegraph target.
- V2. Exercise the Windows path calculation with the repository's supported override-data or native PowerShell harness. Expect a relative Codegraph target that resolves to the Local AppData `current` directory.
- V3. Exercise the out-of-home Local AppData case. Expect the new explicit containment failure.
- V4. Validate `.github/workflows/render-dotfiles.yml` as YAML and run the focused PowerShell assertion locally when `pwsh` is available. Native `apply-windows` CI is the authoritative cross-platform proof.
- V5. Run `git diff --check`, inspect the requested-scope diff, and confirm the root `CLAUDE.md` files remain exact `@AGENTS.md` mirrors.

---

## Definition of Done

- U1 is complete when Windows renders a destination-relative Codegraph target that resolves to `%LOCALAPPDATA%\codegraph\current`, unsupported containment fails clearly, and POSIX output is unchanged.
- U2 is complete when native Windows CI detects both absolute-target regressions and Local AppData destination drift.
- Issue #154 is fully addressed without modifying release ownership, the Codegraph archive, or live deployed files.
- All applicable verification gates pass, abandoned approaches are absent from the diff, and both repository CI workflows reach terminal success.
