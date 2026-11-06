---
title: Jetendard coding fonts and T3 Code typography - Plan
type: feat
date: 2026-11-06
topic: jetendard-coding-fonts
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Jetendard coding fonts and T3 Code typography - Plan

## Goal Capsule

- **Objective:** The repository owner can reproduce Jetendard coding surfaces and Pretendard Variable T3 Code interface text across supported machines.
- **Means:** Extend the existing user-font collection and native managed application preferences through explicit chezmoi application.
- **Product authority:** This Product Contract records the confirmed typography scope and governs implementation planning.
- **Open blockers:** None; native discovery and actual rendering remain execution-time verification.
- **Execution profile:** One pull request; implement, verify, review, and publish through LFG without applying the owner's personal configuration.
- **Stop conditions:** Stop if native font discovery or the supported T3 settings cannot implement the settled font choices.

---

## Product Contract

### Summary

Add Jetendard to the user-font collection and select it for coding surfaces in managed tools.
Use Pretendard Variable for T3 Code's main interface and ordinary conversation text.
Reuse the existing font release locks and application preference reconciliation.

### Problem Frame

The owner wants the same coding font and T3 interface typography on newly prepared and existing machines without repeating manual application settings.
The current collection makes fonts selectable but does not select them in applications.

### Key Decisions

- **Separate coding text from ordinary text.** Governs R3, R4, R5. (session-settled: user-directed — chosen over Jetendard for conversation prose too: the owner selected coding surfaces only.)
- **Use Pretendard Variable for the T3 main font.** Governs R5. (session-settled: user-directed — chosen over retaining the current main font: the owner explicitly expanded the scope to include the variable Pretendard family.)
- **Extend existing management.** Governs R1, R2, R6, R7; the repository already installs fonts and reconciles native app preferences, so a separate typography manager would duplicate ownership.

### Requirements

**Font collection and updates**

- R1. Explicit chezmoi application installs Jetendard's released static TTF weights and styles for the current user on supported Windows, Linux, and macOS targets, alongside the existing font collection.
- R2. Jetendard participates in the existing committed release-lock and font-refresh workflow, including archive and selected-file integrity verification.

**Application typography**

- R3. Managed Ghostty instances use Jetendard as their terminal font on the repository's eligible Linux and macOS targets.
- R4. T3 Code uses Jetendard for code blocks, diffs, code file previews, and its integrated terminal through its native font preferences.
- R5. T3 Code uses the installed variable Pretendard family for its main interface and ordinary conversation text, rather than selecting a static Pretendard face.
- R6. Other repository-managed tools use Jetendard on coding surfaces where a native font preference exists; terminal applications inherit their host terminal's selection.
- R7. Repeated explicit application restores the declared font selections after local changes, while worktree initialization remains read-only for personal settings.
- R8. Font selection changes preserve existing sizes, line spacing, themes, unrelated preferences, and separate prompt-composer preferences.

### Key Flow

- F1. **Apply and use.** The owner explicitly applies the checkout, then restarts affected applications as required by their existing application guidance. Fonts become available through native user-font discovery, and managed applications use the selections in R3–R6. **Covers R1–R8.**

### Acceptance Examples

- AE1. **Fresh machine:** After explicit application on a supported target, native font discovery finds Jetendard and the variable Pretendard family; T3 Code presents ordinary conversation text in the latter and a code block in the former. **Covers R1, R4, R5.**
- AE2. **Repeat application:** After changing a managed font choice locally, applying again restores the declared selection without resetting an unrelated font size or theme. **Covers R7, R8.**
- AE3. **Worktree preparation:** Running `mise install` in a worktree does not install or register desktop fonts or change application font choices. **Covers R7.**
- AE4. **Terminal inheritance:** A managed command-line coding tool launched inside configured Ghostty renders through Ghostty's Jetendard selection without a synthetic per-CLI font setting. **Covers R3, R6.**

### Scope Boundaries

- Adding management for Windows Terminal or a new editor is outside this change; R6 covers tools already managed by the repository.
- The prompt composer keeps its native inheritance behavior unless an existing separate preference overrides it; no independent composer selection is introduced, per R8.
- OTF duplicates, webfont installation, custom font builds, and changes to ligature or rendering-feature preferences are outside this change.
- This work prepares repository configuration; applying it to the owner's actual home requires an explicit personal-configuration request, per R7.

### Dependencies / Assumptions

- Jetendard v0.1.0 provides a TTF release archive; its exact files and integrity metadata must be resolved by the existing font lock workflow under R2.
- The font collection already includes the canonical `PretendardVariable.ttf`; native font metadata must establish the correct selectable variable family name for R5.
- T3 v0.1.7 source exposes separate interface, code, composer, and terminal font preferences; actual application rendering remains execution-time verification.

### Outstanding Questions

- **Deferred to Implementation:** Verify actual native discovery and rendering for the configured family names without applying the owner's personal configuration.

### Sources / Research

- `docs/guides/fonts.md` and `home/.chezmoidata/fonts.json`: existing user-font installation, the variable Pretendard selection, and release-lock updates.
- `scripts/update-font-lock.py`: release selection and archive/member checksum ownership.
- `home/.chezmoitemplates/ghostty-config` and `docs/guides/terminal.md`: shared Ghostty configuration and eligible platform scope.
- `home/.chezmoitemplates/t3-code-preferences`, `home/.chezmoidata/t3-code.json`, and `docs/guides/t3-code.md`: declared preference reconciliation and existing ownership boundaries.
- [Jetendard project](https://github.com/kuskhan/jetendard) and [v0.1.0 assets](https://github.com/kuskhan/jetendard/releases/tag/v0.1.0): family intent and desktop distribution.
- [T3 v0.1.7 typography settings](https://github.com/pingdotgg/t3code/blob/v0.1.7/apps/web/src/components/settings/TypographySettings.tsx), [settings contract](https://github.com/pingdotgg/t3code/blob/v0.1.7/packages/contracts/src/settings.ts), and [font resolution](https://github.com/pingdotgg/t3code/blob/v0.1.7/apps/web/src/appearanceFonts.ts): native preference separation and terminal inheritance on the managed compatibility baseline.

---

## Planning Contract

**Product Contract preservation:** Clarified resolved technical questions and added the motivation; requirements, scope, and stable IDs are unchanged.

### Key Technical Decisions

- KTD1. **Use the existing release archive pipeline.** Add a `jetendard` declaration selecting `Jetendard-TTF.zip` and `ttf/Jetendard-*.ttf` with minimum 16 members; this excludes the archive's `__MACOSX` sidecar files. Extend the committed font lock with the generated v0.1.0 entry without refreshing unrelated font pins. Implements R1, R2 using `scripts/update-font-lock.py` and the shared `home/.chezmoitemplates/external-assets/fonts.toml.tmpl` preparation manifest; no legacy `.chezmoiexternals` entry is added.
- KTD2. **Use native family identifiers.** Actual release metadata identifies the regular Jetendard face as `Jetendard` and the canonical variable Pretendard file as `Pretendard Variable`; use those names instead of filenames. Implements R3–R5.
- KTD3. **Own only the three T3 family preferences.** Declare `fontFamilySans`, `fontFamilyCode`, and `fontFamilyTerminal` in the existing client map. The supported T3 font resolver takes the terminal family in advanced mode and the code family otherwise, so both coding preferences must be set without changing its local advanced-mode flag. Preserve the separate composer preference through the existing reconciler. Implements R4, R5, R7, R8.
- KTD4. **Keep one shared Ghostty configuration.** Add the family selection to `home/.chezmoitemplates/ghostty-config`, which the existing terminal helper copies to primary and legacy paths. No installer, OS terminal ownership, or terminal-helper change is needed for R3, R7.
- KTD5. **Leave terminal-rendered tools with their host.** The managed Claude Code, Codex, omp, and Antigravity CLI/ACP integrations do not own a desktop coding font; R6 is satisfied through configured Ghostty or T3 rendering. No new editor or Windows Terminal management is introduced.

### Assumptions and Risks

- The v0.1.0 archive and T3 v0.1.7 source are the planning baseline; the implementer must verify downloaded bytes and actual application metadata before accepting KTD1–KTD3.
- Existing manually installed duplicates can affect family selection, as documented in `docs/guides/fonts.md`; do not remove unrelated fonts to resolve such duplicates.
- No new retry system, font manager, renderer patch, or fallback-font policy is planned because existing download verification and native application behavior already cover this configuration change.

---

## Implementation Units

### U1. Add the pinned Jetendard collection

**Goal:** Make the released desktop family reproducibly installable.

**Requirements:** R1, R2; supports AE1.

**Dependencies:** None.

**Files:** `home/.chezmoidata/fonts.json`, `home/.chezmoidata/font-lock.json`; existing `tests/test_font_lock.py`, `tests/test_fonts.py`, and `tests/smoke_fonts.py` are verification seams.

**Approach:** Follow KTD1 and KTD2 using the existing declaration and resolver, preserving unrelated lock entries. Inspect the exact downloaded archive and native name records; do not add a new build dependency or installer branch.

**Execution note:** Prefer real archive staging and native font discovery evidence over tests that merely duplicate the new JSON values.

**Test scenarios:** Run the existing archive-integrity and desktop-selection fixtures; verify the real package stages only its 16 TTF members and native discovery finds the declared family.

**Verification:** Existing font tests pass and the font smoke reconciles the extended collection in its disposable ownership scope.

### U2. Configure native application font selections

**Goal:** Apply the confirmed typography split through existing application configuration.

**Requirements:** R3–R8, F1; AE2–AE4.

**Dependencies:** U1.

**Files:** `home/.chezmoitemplates/ghostty-config`, `home/.chezmoidata/t3-code.json`, `tests/test_t3_code_settings.py`, `tests/test_terminal_environment.py`.

**Approach:** Implement KTD2–KTD5 without changing application preference reconciliation or platform gates. Extend the existing disposable-home convergence and terminal apply/status fixtures at the behavior boundary.

**Test scenarios:**

- Covers AE2. Start T3 settings with different font families, a separate composer family, sizes, and unrelated settings; apply the actual declarations and verify the three owned family choices converge while the others survive.
- Covers AE2. Repeat the isolated T3 application and verify an empty diff.
- Covers AE4. Apply Ghostty configuration with existing legacy content and verify primary and legacy files select the same family; apply/status remains idempotent.
- Covers AE3. Existing hook-free bootstrap checks still run without installing fonts or changing application settings.

**Verification:** The focused T3 and terminal fixtures pass; supported T3 source and native discovery agree with the configured names, and any rendering check uses disposable application state.

### U3. Document selection ownership and finish verification

**Goal:** Explain the new selections, update procedure, and platform boundaries accurately.

**Requirements:** R1–R8; documents F1 and AE1.

**Dependencies:** U1, U2.

**Files:** `docs/guides/fonts.md`, `docs/guides/terminal.md`, `docs/guides/t3-code.md`.

**Approach:** Update the collection count and application-selection guidance, remove superseded default-only appearance claims, and document the three owned T3 choices. Keep existing close-and-reopen guidance and state which tools inherit their renderer's font.

**Test expectation:** None for prose; validate statements against the final declarations and actual verification evidence.

**Verification:** Documentation no longer claims application fonts or Ghostty appearance are entirely unmanaged, and reports native/GUI evidence at the level actually obtained.

---

## Verification Contract

- Run `mise exec -- python -m unittest discover -s tests -p 'test_font*.py'` for archive locking, staging, platform gates, and installer reconciliation.
- Run `mise exec -- python -m unittest discover -s tests -p 'test_t3_code_settings.py'` for actual preference convergence, preservation, and repeated application.
- Run `mise exec -- python -m unittest discover -s tests -p 'test_terminal_environment.py'` and `mise exec -- python -m unittest discover -s tests -p 'test_ghostty_install.py'` for shared Ghostty configuration and unchanged native platform behavior.
- Run `mise exec -- python tests/smoke_fonts.py` on this eligible Windows host using its temporary owned files and registrations; it must clean up its registrations and report any OS-held files accurately.
- Verify the T3 v0.1.7 schema accepts the declared native preferences and the regular and variable font metadata matches KTD2; use disposable T3 state for an available rendering check and report separately if a GUI check could not run.
- Run hook-free `mise install` and `git diff --check`; supported non-Windows native checks remain covered by the existing CI platform matrix.

---

## Definition of Done

- U1 delivers the exact Jetendard release entry with unchanged unrelated pins.
- U2's declared application choices converge without resetting the preferences protected by R8.
- U3 describes the final ownership and supported platform scope without claiming unperformed GUI checks.
- Required focused checks and eligible native smoke pass; remaining platform or rendering limits are recorded in the PR.
- No personal chezmoi application, unrelated cleanup, temporary font artifact, or abandoned implementation is included in the branch.
- Review fixes are applied and the configuration, documentation, tests, and this plan ship together in one open PR.
