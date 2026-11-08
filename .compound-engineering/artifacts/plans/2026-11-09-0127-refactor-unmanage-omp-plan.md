---
title: Stop managing omp and remove its T3 provider
type: refactor
date: 2026-11-09
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Stop managing omp and remove its T3 provider

## Goal Capsule

**Objective:** Future dotfiles applies leave existing omp installations under user control and remove omp from T3 Code's configured providers.

**Means:** Withdraw omp declarations and consumers, with targeted provider removal through the existing modify template (KTD1, KTD2).

**Authority:** The user's clarified retirement policy governs scope; requirements govern behavior; technical decisions govern mechanisms.

**Execution profile:** One branch and one PR. The LFG host owns verification, commits, review, and publication. Do not merge or apply personal configuration.

**Stop conditions:** Any required deletion of existing omp files, loss of another harness's shared resources, or unresolved failing verification.

## Product Contract

### Summary

Retire omp from repository management while preserving installed files. Remove its T3 provider during explicit apply and update current operational documentation and verification.

### Problem Frame

omp is no longer wanted as a managed harness. Its install declarations, native plugin reconciliation, completion generation, and T3 provider currently cause later applies to continue maintaining it.

### Requirements

- **R1:** Remove omp installation declarations, binary release pins, managed configuration sources, instruction adapter, CE integration, and completion generation from the repository.
- **R2:** Applying the retired source must preserve existing omp executables, configuration, credentials, plugins, sessions, and completion files without reconciling or reinstalling them.
- **R3:** Remove the `omp` provider entry from existing T3 settings through the modify transformation, preserving unrelated providers and settings; repeated apply must keep it absent.
- **R4:** Fresh disposable homes must receive no omp installation, managed configuration, or T3 provider.
- **R5:** Preserve shared CE release pins, assets, instructions, and skills used by remaining harnesses, and retain their meaningful test and native smoke coverage.
- **R6:** Current guides must describe the supported harnesses and the retirement behavior without rewriting historical plans or solutions.

### Key Decisions

- **D1. Preserve retired destination state.** Governs R1, R2, R4. (session-settled: user-directed — chosen over uninstalling the executable or deleting user state: retirement means unmanaged, with definitions and pins removed only from the repository.)
- **D2. Remove the T3 provider from destination settings.** Governs R3. (session-settled: user-directed — chosen over merely stopping registration: the user explicitly wants the provider removed through the modify pattern.)

### Scope Boundaries

Do not delete or apply anything in the real user home, add uninstall machinery, or change other harness behavior. Existing historical artifacts retain their original evidence. General standing-policy changes remain tracked separately in issue #106, already created at the user's request.

## Planning Contract

### Key Technical Decisions

- **KTD1:** Remove omp-specific source files, templates, scripts, data keys, and ignore branches rather than leaving empty compatibility implementations (R1, R2, D1). `harness-plugin-marketplaces`, `harness-plugin-script-inputs`, and the two `run_onchange_after_20-harness-plugins` scripts currently serve omp alone. Keep shared CE extraction and other native installers.
- **KTD2:** Omit the exact `omp` key from `providerInstances` after validating its containing object, replacing the current managed ACP insertion loop (R3, D2). No inference from command paths and no removal of other ACP providers.
- **KTD3:** Convert generic installer fixtures currently keyed by omp to a neutral test application or a remaining supported app; remove omp-only native integration tests while preserving shared extraction and Antigravity tests (R4, R5). Keep the existing smoke entry point where useful for shared payload acquisition rather than weakening remaining harness checks.
- **KTD4:** Use disposable homes and hook-free config for all apply proofs. Verify retained destination bytes and fresh-home absence through actual existing asset/config entry points, including repeated application (R2–R5).

### Research Basis

`home/.chezmoitemplates/t3-code-settings` currently registers omp unconditionally. `home/.chezmoiignore` chooses its YAML configuration target. `home/.chezmoitemplates/external-assets/harness-plugins.toml.tmpl` shares CE acquisition among harnesses, whereas the marketplace/action templates are omp-specific. `tests/test_harness_plugins.py` combines omp and Antigravity coverage. `tests/test_personal_apps.py` uses the production omp declaration as a generic installer fixture.

## Implementation Units

### U1. Withdraw omp management

**Goal:** Implement R1–R5 using KTD1, KTD2, and KTD4.

**Dependencies:** None.

**Files:** omp-related sources under `home/`; `tests/test_t3_code_settings.py`; `tests/test_harness_plugins.py`.

**Approach:** Remove exclusive declarations and consumers. Preserve shared extraction and native integrations. Replace provider insertion with exact-key removal. Update the two directly affected test modules, including destination-state preservation.

**Test scenarios:**

- Existing T3 settings containing omp and unrelated providers lose only omp, on first and repeated applies.
- Existing retired executable and configuration bytes survive explicit disposable apply; fresh destinations do not acquire them.
- Shared CE extraction and Antigravity instruction/config behavior remain covered.

**Verification:** Relevant settings/plugin tests pass on the host; rendered manifests and scripts contain no omp management on supported platform fixtures.

### U2. Update remaining tests and native smokes

**Goal:** Preserve R4 and R5 verification after U1.

**Dependencies:** U1 before final verification; disjoint authoring may proceed concurrently.

**Files:** Other omp-related modules in `tests/`; affected workflow steps in `.github/workflows/test.yml` only if needed; `scripts/run-test-area.py` only if module ownership changes.

**Approach:** Remove omp ACP/native discovery from smoke entry points without removing Codex/Claude startup or shared plugin verification. Decouple generic fixtures from retired production declarations. Use a still-managed harness as the foreign-branch sentinel in instruction tests.

**Test scenarios:**

- Generic asset download, pin integrity, caching, repair, and platform selection assertions still execute.
- T3 native Codex and Claude initialization paths remain intact with omp absent.
- Every test module remains assigned to its CI area; shared native CE smoke checks remain enabled.

**Verification:** Application-area tests and smoke syntax checks pass; run eligible affected native smoke checks in disposable homes and report platform limitations.

### U3. Correct current guides

**Goal:** Implement R6.

**Dependencies:** U1 and U2 before final consistency review; disjoint authoring may proceed concurrently.

**Files:** `README.md`; `docs/README.md`; current guides/setup/maintenance documents referencing omp; `AGENTS.md` only to remove the stale omp-specific example.

**Approach:** Remove active omp setup, plugin repair, CA, completion, and native-validation instructions. Explain preserved destination state and T3 removal in the relevant operational guide. Keep general policy work in #106.

**Test expectation:** None for prose. Check references against final code and inspect Markdown formatting.

**Verification:** No current guide claims omp is installed, configured, or validated by dotfiles.

## Verification Contract

Run the existing application CI area via `mise exec chezmoi python usage powershell -- python scripts/run-test-area.py --area applications`, plus CI workflow/area tests if workflows change. Start with focused changed modules for faster diagnosis. Compile changed smoke scripts and run native affected smoke entry points on eligible macOS ARM64 using disposable homes. Use actual modify application to demonstrate provider removal and idempotency. No authenticated model calls or personal apply is required. Record skips by platform and unavailable prerequisites.

## Definition of Done

All units are implemented and relevant checks pass. Existing retired files survive disposable application, fresh homes do not acquire omp, and repeated T3 apply removes its provider without damaging other entries. Shared integration coverage remains meaningful. Remove abandoned code and stale current instructions. Simplify and review the final diff, commit owned files, publish an open PR, and obtain the bounded CI result without merging.
