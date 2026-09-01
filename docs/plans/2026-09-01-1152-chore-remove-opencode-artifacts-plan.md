---
title: Remove OpenCode Configuration and References - Plan
type: chore
date: 2026-09-01
topic: remove-opencode-configuration-and-references
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
origin: user request
---

# Remove OpenCode Configuration and References - Plan

## Goal Capsule

- **Objective:** Eliminate all active OpenCode provider gates, compatibility toggles, test assertions, and documentation references from the repository source state.
- **Authority:** User session direction; `AGENTS.md` source management and no-teardown policies.
- **Execution profile:** `execution: code` — declarative source-state cleanup and test alignment without modifying live host files or historical plan records.
- **Stop conditions:** Stop if any removed setting causes omp settings validation, test fixtures, or template rendering to fail.

---

## Product Contract

### Summary

Remove all surviving OpenCode configurations and references across `.chezmoidata/agents.yaml`, `AGENTS.md`, `.gitignore`, `README.md`, and `packages/figma-auth/test/cli.test.ts`. This completes the decommission of OpenCode by cleaning up lingering compatibility settings, temporary disabled provider entries, and documentation text.

### Problem Frame

OpenCode was retired as a managed harness in earlier migrations. However, residual traces remain across several active source files: temporary disabled provider entries (`opencode-go`, `opencode-zen`) in `agents.yaml`, compatibility command toggles (`commands.enableOpencodeUser`, `commands.enableOpencodeProject`), obsolete `opencode.json` references in `AGENTS.md`, `.opencode` in `.gitignore`, manual cleanup instructions in `README.md`, and `opencode` test assertions in `packages/figma-auth`. Removing these items keeps source state clean and prevents confusion.

### Key Decisions

- **Clean up all active source and documentation references while preserving historical plans.** (session-settled: user-directed — chosen over deleting historical plans or touching settings only: maintains a clean active source while preserving durable historical plan records per repository conventions.) Governs R1, R2, R3, R4, R5, R6, R7.
- **Purge OpenCode entirely from README documentation.** (session-settled: user-directed — chosen over retaining legacy harness mentions: removes all OpenCode manual cleanup entries and harness list mentions completely from README.md.) Governs R5.
- **No host teardown or residue scripts.** (session-settled: user-approved — chosen over automated file pruning: conforms to the repository's strict no-teardown rule; unmanaged local files are left for manual cleanup if needed.) Governs R8.

### Requirements

**Configuration and settings**

- R1. `agents.omp.settings.disabledProviders` in `.chezmoidata/agents.yaml` contains no `opencode-go` or `opencode-zen` entries.
- R2. `agents.omp.settings` in `.chezmoidata/agents.yaml` contains no `commands.enableOpencodeUser` or `commands.enableOpencodeProject` toggles.

**Rules and documentation**

- R3. `AGENTS.md` removes `opencode.json` from the root non-dot metadata rule in the source layout section, and removes the `opencode-go`/`opencode-zen` explanation from the provider availability gate section.
- R4. `.gitignore` removes the `### opencode ###` header and `.opencode` pattern.
- R5. `README.md` removes OpenCode completely from the manual cleanup instructions and retired harness lists.

**Test fixtures and verification**

- R6. `packages/figma-auth/test/cli.test.ts` removes `opencode` from the unsupported harness argument test cases and assertions.
- R7. All historical records under `docs/plans/**` remain untouched.
- R8. No teardown, revert, or prune scripts are introduced.

### Acceptance Examples

- AE1. **Configuration purity.** Given `.chezmoidata/agents.yaml`, when `run_after_config-omp-settings.sh.tmpl` is rendered, then the rendered settings contain no OpenCode provider gates or command discovery settings.
- AE2. **Rule accuracy.** Given `AGENTS.md`, when audited against current repository source, then no text references non-existent `opencode.json` or retired OpenCode providers.
- AE3. **Test passage.** Given `packages/figma-auth`, when `bun test` is executed, then the test suite passes with surviving harness test cases.
- AE4. **Zero active references.** Given a repository-wide search outside `docs/plans/**`, when searching for `opencode` (case-insensitive), then zero matches are returned.

### Scope Boundaries

- **Historical records:** `docs/plans/**` files are archival records and will not be edited.
- **Host filesystem:** Deployed `~/.config/opencode` or `~/.local/share/opencode` files on user machines are not modified or deleted by repository automation.
- **Other retired harnesses:** References to other retired harnesses (e.g. Pi, Kimi, Claude Code) are unaffected unless sharing a line with OpenCode.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Clean removal from YAML data structures without restructuring.** (Governs R1, R2) Removing the two entries from `disabledProviders` and the two command flags from `settings` preserves the surrounding YAML structure and schema validity.
- **KTD2. Inline documentation reconciliation.** (Governs R3, R4, R5) Cleanly excise paragraphs and entries without leaving empty headers or broken sentences.
- **KTD3. Test assertion maintenance.** (Governs R6) Keep `packages/figma-auth` test coverage strong by testing the remaining legacy harness names (`pi`, `antigravity`, `kimi`) and general invalid input.
- **KTD4. Verification via absence sweep and isolated render.** (Governs AE1, AE2, AE3, AE4) Proof is provided by template execution with stubbed secrets and a case-insensitive grep across the active repository.

---

## Implementation Units

### U1. Clean up OpenCode provider gates and command toggles in agents.yaml

- **Goal:** Remove `opencode-go`, `opencode-zen`, and opencode command flags from `.chezmoidata/agents.yaml`.
- **Requirements:** R1, R2.
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:**
  - In `disabledProviders`: remove `- opencode-go` and `- opencode-zen`.
  - In `settings`: remove `commands.enableOpencodeUser: false` and `commands.enableOpencodeProject: false`.
- **Test scenarios:**
  - `.chezmoidata/agents.yaml` parses as valid YAML.
  - No `opencode` string remains in `.chezmoidata/agents.yaml`.
- **Verification:** Render `run_after_config-omp-settings.sh.tmpl` with the stub-`op` recipe.

### U2. Clean up AGENTS.md, .gitignore, and README.md

- **Goal:** Remove OpenCode references from repository documentation, rules, and gitignore.
- **Requirements:** R3, R4, R5.
- **Files:** `AGENTS.md`, `.gitignore`, `README.md`
- **Approach:**
  - `AGENTS.md`: Remove `opencode.json` from the non-dot metadata rule; remove the sentence explaining `opencode-go` and `opencode-zen` in `disabledProviders`.
  - `.gitignore`: Remove `### opencode ###` and `.opencode`.
  - `README.md`: Remove `OpenCode` from the retired harness list and delete the OpenCode bullet under manual cleanup instructions.
- **Test scenarios:**
  - `git diff` shows clean removal without dangling bullets or broken sentences.
  - Searching these three files for `opencode` yields 0 results.
- **Verification:** `grep -i "opencode" AGENTS.md .gitignore README.md` returns no matches.

### U3. Update figma-auth test assertions

- **Goal:** Remove `opencode` from `packages/figma-auth/test/cli.test.ts`.
- **Requirements:** R6.
- **Files:** `packages/figma-auth/test/cli.test.ts`
- **Approach:**
  - Remove `[["opencode"]]` from the parameterized test matrix.
  - Remove `expect(stderr.output).not.toContain("opencode");` assertion.
- **Test scenarios:**
  - `bun test` in `packages/figma-auth` passes completely.
- **Verification:** Run `bun test` in `packages/figma-auth`.

### U4. Full verification and active reference sweep

- **Goal:** Verify all templates render, tests pass, and zero active OpenCode references exist outside historical plans.
- **Requirements:** R7, R8, AE1, AE2, AE3, AE4.
- **Files:** All modified files.
- **Approach:**
  - Run `grep` across the entire codebase excluding `docs/plans/**` to verify zero `opencode` matches.
  - Run template execution with scratch/stub environment to ensure all scripts render without error.
- **Test scenarios:**
  - Grep returns 0 matches outside `docs/plans/**`.
  - Template renders exit 0.
- **Verification:** Absence sweep and render script execution.

---

## Verification Contract

| Check | Tool / Command | Target | Pass Criteria |
|---|---|---|---|
| YAML Syntax & Settings Render | `chezmoi execute-template` with scratch stub | `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` | Exits 0, output contains no opencode keys |
| Test Suite | `bun test` | `packages/figma-auth` | All tests pass |
| Documentation & Rules | `grep -ri "opencode" .` (excluding `docs/plans`) | Repository root | Zero matches |
| Git Diff Hygiene | `git diff --check` | Working tree | Clean diff with no trailing whitespace or syntax errors |

---

## Definition of Done

- All OpenCode entries removed from `.chezmoidata/agents.yaml`, `AGENTS.md`, `.gitignore`, `README.md`, and `packages/figma-auth/test/cli.test.ts`.
- No `opencode` references exist in active source files outside `docs/plans/**`.
- `bun test` passes in `packages/figma-auth`.
- All chezmoi templates render without errors.
- Changes are committed and pushed via the autonomous shipping pipeline.
