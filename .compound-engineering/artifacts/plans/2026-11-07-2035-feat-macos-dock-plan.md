---
title: macOS Dock Preferences and Pinned Apps - Plan
type: feat
date: 2026-11-07
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# macOS Dock Preferences and Pinned Apps - Plan

## Goal Capsule

**Objective:** Restore the owner's preferred macOS Dock for personal, work, and development use through the dotfiles repository.

**Product authority:** The owner-approved Dock settings and ordering in this Product Contract.

**Means:** Native per-key Dock preference reconciliation through the existing chezmoi lifecycle (KTD1–KTD3).

**Execution profile:** One PR; implementation and local verification return to LFG for review and shipping.

**Open blockers:** None.

## Product Contract

### Summary

Manage Dock preferences and the ordered pinned applications through explicit dotfiles application.
The layout groups shared tools, personal apps, work apps, and development/AI apps.

### Key Decisions

- **Personal before work, then development/AI.** Governs R3–R7 (session-settled: user-directed — chosen over work and development preceding personal apps: the owner selected this order).
- **Keep both AI desktop apps.** Governs R7 (session-settled: user-directed — chosen over a ChatGPT-only pin: the owner uses both ChatGPT and Claude).
- **Exclude password management and OneNote from pins.** Governs R9 (session-settled: user-directed — chosen over pinning installed utility and note-taking apps: the owner explicitly excluded them).

### Requirements

**Preferences**

- R1. Set the Dock icon size to 32.
- R2. Disable the Dock's suggested and recent applications section; running applications may still appear normally.

**Pinned layout**

- R3. Order the application groups left to right as common, personal, work, and development/AI; these are logical groups without added spacer tiles.
- R4. The common group is Finder → Google Chrome → App Store.
- R5. The personal group is Mail → Calendar → Reminders → Notes → Messages → FaceTime → Phone → Photos → Music → iPhone Mirroring.
- R6. The work group is Microsoft Outlook → Microsoft Teams → Microsoft Word → Microsoft Excel → Microsoft PowerPoint.
- R7. The development/AI group is Ghostty → T3 Code → ChatGPT → Claude.
- R8. Keep Downloads followed by the system Trash in the Dock's right-hand area.
- R9. Reconcile pinned entries to R3–R8, removing other pins, including 1Password and Microsoft OneNote.
- R10. Skip unavailable applications without changing the relative order of the available entries.

**Application boundary**

- R11. Apply these settings only through explicit chezmoi application from the current worktree; worktree preparation must not change the user's Dock.
- R12. Reapplying restores the declared preferences and pins without creating duplicate entries.
- R13. Restrict Dock management to the repository's supported macOS platform and leave other Dock preferences unchanged.

### Key Flow

The owner explicitly applies dotfiles; the available pinned apps are reconciled to R3–R10 and preferences to R1–R2.
Subsequent applications restore the same declared state under R11–R13.

### Acceptance Examples

- AE1. **Covers R1–R9, R12:** Given all listed apps are installed and the Dock has different settings and pins, explicit application produces the declared settings and exact pin order; a second application adds no duplicates.
- AE2. **Covers R10:** Given Microsoft Word is absent, application omits its pin while Microsoft Teams still precedes Microsoft Excel; after Word is installed, a later application places it between them.
- AE3. **Covers R11, R13:** Preparing a worktree leaves the current Dock untouched, and non-macOS application performs no Dock changes.
- AE4. **Covers R9, R12:** Given an extra manually pinned app or a manually reordered entry, a later explicit application restores the declared list and order.

### Scope Boundaries

- Installing or configuring Microsoft 365 apps and signing into iCloud or Microsoft accounts are outside this work.
- No app usage tracking or changes to account synchronization are required.
- Other Dock behaviors, including position, magnification, and automatic hiding, are outside this work.

### Sources

- `AGENTS.md`: worktree bootstrap and explicit chezmoi application boundaries.
- `STRATEGY.md`: repository-managed settings take precedence over local changes.
- `home/.chezmoidata/macos.yaml` and `docs/guides/t3-code.md`: existing application-management context.
- Local application bundles and current Dock preferences were inspected read-only on the owner's MacBook during this brainstorm; installation was checked, not account synchronization or usage frequency.

## Planning Contract

### Key Technical Decisions

- KTD1. **Declare the layout as repository data.** Add `home/.chezmoidata/macos-dock.json` and consume it from an always-run, macOS ARM64-only after hook using the worktree's mise Python. The hook runs after application installation and uses the declared destination for Downloads. Covers R1–R13.
- KTD2. **Use native defaults per key.** A small standard-library Python helper exports current preferences through `/usr/bin/defaults`, then changes only the four owned keys: icon size, recent suggestions, pinned apps, and pinned folders. Do not replace the whole Dock domain or write its backing plist directly. Preserve unrelated settings and reuse existing tile metadata for retained URLs. Covers R1–R2, R9, R12–R13.
- KTD3. **Resolve installed bundles deterministically.** Use explicit app-bundle candidates under system, global, and user Applications roots, including both T3 Code bundle names. Finder and Trash are system-owned anchors, not duplicate persistent entries. Missing bundles are omitted and reconsidered on each apply. Covers R3–R10.
- KTD4. **Separate native preference proof from the live desktop.** Test native defaults against an absolute plist domain in a temporary directory and stub Dock restart; never point verification at the owner's `com.apple.dock`. Restart the user's Dock only after a changed production reconciliation, and surface write failures. Covers R11–R13.

### Constraints and Risks

- A changed application may briefly restart Dock; unchanged application should not restart it.
- A temporary HOME alone does not isolate macOS preference services. Native tests must use a temporary absolute domain, including every read and write.
- Preference and tile serialization must be verified natively; a command double alone does not establish compatibility.
- Concurrent manual Dock edits during application are outside this work; no lock or continuous enforcement service is added.

## Implementation Units

### U1. Declare and reconcile Dock configuration

- **Goal:** Implement R1–R13 without changing unrelated preferences.
- **Files:** `home/.chezmoidata/macos-dock.json`, `home/.chezmoiscripts/run_after_90-macos-dock.sh.tmpl`, `scripts/macos-dock.py`.
- **Approach:** Render the configuration into the hook's invocation, resolve bundles and Downloads, compare owned preference values, and write changed keys through native defaults. Preserve retained tile metadata and fail on preference errors. Use an ordinary always-run after hook so drift and newly installed apps reconcile on repeated application.
- **Test scenarios:** Initial configuration, reordering and extra-pin removal, excluded apps, absent and later-installed bundles, T3 naming variants, user Applications, spaces and Unicode in URLs, unchanged application, unrelated keys, write failures, supported-platform guards.
- **Verification:** U2 tests and native temporary-domain readback establish the helper and lifecycle contract.

### U2. Verify and document the apply boundary

- **Goal:** Make the configuration and ownership rules maintainable and verify AE1–AE4.
- **Files:** `tests/test_macos_dock.py`, `scripts/run-test-area.py`, `docs/guides/macos-dock.md`, `docs/setup/macos.md`, `docs/README.md`.
- **Approach:** Add focused behavioral tests, render the real hook for eligible and ineligible targets, and prove repeated isolated chezmoi execution. Include a macOS-only real-defaults fixture using a temporary absolute domain. Register the module with the existing platform test area so native coverage runs in macOS CI.
- **Test scenarios:** All U1 scenarios plus two actual chezmoi applications, a drifted third application, no-op render on other platforms, and actual native defaults readback without live Dock access.
- **Verification:** Focused Dock tests, adjacent lifecycle/bootstrap coverage, test ownership validation, and whitespace checks.

## Verification Contract

- Focused tests: `mise exec -- python -m unittest discover -s tests -p test_macos_dock.py -v`.
- Adjacent coverage: macOS application/bootstrap and CI area tests through unittest discovery or the platform area runner.
- Ownership: `mise exec -- python scripts/run-test-area.py --validate-only`.
- Repository hygiene: `git diff --check`.
- Native proof: the macOS-only Dock test must round-trip arrays, booleans, and integers using real defaults in a temporary absolute domain, retain unrelated preferences, and leave the second application unchanged.
- Live-desktop visual confirmation is not claimed by these isolated checks; no personal Dock settings are applied during implementation.

## Definition of Done

- U1 and U2 satisfy the Product Contract and all applicable verification above passes.
- The exact approved order is declared once in repository configuration and missing apps are omitted without reordering the rest.
- Repeated isolated application restores drift and remains unchanged when already reconciled.
- Documentation explains editing the declaration, explicit application, pin ownership, missing apps, and the brief restart on change.
- The change is independently reviewed and shipped as one open PR; merging remains with the owner.
