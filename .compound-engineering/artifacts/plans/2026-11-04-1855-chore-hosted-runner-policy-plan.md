---
title: Hosted Runner Policy - Plan
type: chore
date: 2026-11-04
artifact_contract: ce-unified-plan/v1
product_contract_source: github-issue-11
execution: code
---

# Hosted Runner Policy - Plan

## Goal Capsule

- **Objective:** The owner can rely on CI installation and configuration checks for the supported current operating systems and architectures.
- **Means:** Update the existing runner matrices and remove Intel Mac declarations (KTD1, KTD2).
- **Authority:** Issue #11 defines product scope; requirements govern behavior; technical decisions govern implementation.
- **Execution profile:** One separate pull request, not a change to PR #9. The LFG caller owns review and shipping; merging remains with the user.
- **Stop condition:** A requested runner label is unavailable, verification cannot establish the changed behavior, or implementation would require changing the requested platform policy.

---

## Product Contract

### Summary

Adopt the latest Xcode ARM64 runner and the two newest Ubuntu LTS releases for unit and native-installation coverage. Remove Intel Mac support while preserving Windows and Linux x64 support.

### Problem Frame

The existing CI covers one Ubuntu LTS release and retains Intel macOS installation coverage and documentation. Those choices no longer match the owner's requested supported-device policy.

### Requirements

**Runner coverage**

- R1. macOS unit and native jobs use the latest Xcode runner, currently `xcode-27`, on ARM64 only.
- R2. Unit and native-installation/PATH jobs cover the two newest Ubuntu LTS releases, currently 24.04 and 26.04, without dropping Linux x64 or ARM64.
- R3. Windows units remain on `windows-2025`; native jobs retain `windows-2025` x64 and `windows-11-arm` ARM64.

**Supported devices and handoff**

- R4. Remove `darwin-amd64` from personal-app declarations and generated pins, update affected tests, and remove Intel Mac support claims without removing Linux or Windows AMD64 support.
- R5. Document the rolling latest-Xcode/two-newest-Ubuntu-LTS policy as well as its current labels.
- R6. Issue #11 and PR #9 contain reciprocal non-closing references; PR #9 merging must not close this issue.

### Scope Boundaries

Do not change development-tool declarations, refresh the pinned omp version, alter the scheduled updater's publication behavior, add runner-discovery automation, or merge a pull request.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Keep explicit matrices.** Extend the existing unit runner list and native include list rather than introduce dynamic runner discovery. Native job names include both runner and target so the two Ubuntu versions remain distinguishable. Covers R1–R3.
- KTD2. **Keep catalog ownership of app platforms.** Remove the obsolete target from the catalog and regenerate the lock through the existing resolver using release metadata for its committed tag. Preserve all remaining URLs, digests, and tag. The renderer already emits no application on undeclared platforms. Covers R4.
- KTD3. **Remove obsolete Intel GPG defaults.** The remaining macOS Homebrew default is `/opt/homebrew/bin`; simplify the existing architecture-specific GPG selection without introducing compatibility aliases. Preserve user path overrides and Linux/Windows defaults. Covers R4.
- KTD4. **Prefer runtime proof to configuration-copy tests.** Exercise real chezmoi rendering, existing lock-resolution tests, and isolated native smoke; the hosted workflow proves OS-specific PATH integration. Do not add permanent tests that merely copy matrix labels. Covers R1–R5.

### Assumptions

- Unit coverage runs on both Linux architectures for each selected Ubuntu release, matching the native matrix and avoiding an ambiguous interpretation of R2.
- Historical CE artifacts and the closed PR #9's original verification record are historical evidence, not current support claims, and remain intact.
- Single-runner pin-update orchestration remains on its current Ubuntu runner: R2 explicitly targets unit and native-installation/PATH matrices, not every orchestration job.

### Risks and Evidence

GitHub's [runner image catalog](https://github.com/actions/runner-images#available-images) lists every requested label, including `ubuntu-26.04-arm` and ARM64 `xcode-27`. The [Xcode announcement](https://github.com/actions/runner-images/issues/14404) still marks that image as preview and warns about software instability and queue capacity; use the requested label without a fallback.

The generated-lock updater in `scripts/update-personal-app-lock.py` accepts a release-fetch callback, allowing regeneration against the existing committed release instead of an unrelated upgrade. The existing render tests in `tests/test_personal_apps.py` use real chezmoi with isolated destinations and loopback payloads.

---

## Implementation Units

### U1. Align runner matrices

**Goal:** Make hosted jobs implement R1–R3 consistently.
**Dependencies:** None.
**Files:** `.github/workflows/test.yml`.
**Approach:** Follow KTD1 and KTD4; preserve all existing job steps, Windows prerequisites, and smoke isolation. Remove six-target wording.
**Execution note:** Pure CI configuration; verify expanded matrix coverage locally and exercise the workflow on the PR rather than add source-text tests.
**Test expectation:** None — permanent matrix-copy assertions would not prove hosted execution.
**Verification:** Each Linux release/architecture pair appears in unit and native coverage; macOS has only its requested ARM64 job; Windows selections and steps are unchanged. Hosted jobs execute the unit suite and real installation/PATH smoke.

### U2. Retire Intel Mac configuration

**Goal:** Align supported app and GPG configuration with R4.
**Dependencies:** None; independent of the workflow file.
**Files:** `home/.chezmoidata/personal-apps.json`, `home/.chezmoidata/personal-app-lock.json`, `home/.chezmoidata/gpg.yaml`, `home/.chezmoitemplates/gpg-settings`, `tests/test_personal_apps.py`, `tests/test_personal_app_lock.py`, and any existing GPG rendering tests that assert obsolete defaults.
**Approach:** Follow KTD2–KTD4. Keep the existing generic app renderer; update fixture coverage to the supported targets and remove the obsolete six-platform test name. Extend the existing unsupported-platform scenario to Intel macOS, verifying empty externals and no network requests.
**Patterns to follow:** Catalog-driven app rendering; the updater's atomic complete-lock publication; shared GPG settings partial with config overrides.
**Test scenarios:**
1. Every supported platform renders its own pinned executable and checksum, including Linux and Windows AMD64.
2. Intel macOS renders no personal app and performs no app download, even if an old Intel pin exists.
3. Updating release digests and rejecting incomplete or ambiguous releases still obey existing atomic lock behavior with the reduced target fixture.
4. macOS ARM64 GPG defaults retain Apple Silicon paths and explicit path overrides remain effective.
**Verification:** Existing relevant suites pass, regenerated pins preserve the five retained records exactly, and the actual committed Windows x64 executable runs from an isolated destination.

### U3. Document policy and link follow-up

**Goal:** Make current support and the issue's relationship to PR #9 explicit (R5, R6).
**Dependencies:** U1, U2.
**Files:** `README.md`, `home/README.md` if its target guidance needs qualification; GitHub issue #11 and PR #9 bodies/comments.
**Approach:** Remove the Intel Homebrew row and broad all-OS/both-architectures claim. Document macOS ARM64 only, Linux/Windows x64 and ARM64, and the policy behind current runner labels. Preserve an existing correct reciprocal link rather than duplicate it.
**Test expectation:** None — documentation and tracker updates.
**Verification:** Current docs no longer claim Intel Mac support; live issue/PR state contains reciprocal links with no closing keyword between PR #9 and issue #11.

---

## Verification Contract

- Run the existing Python unittest suite through mise; inspect failures for platform prerequisites rather than changing unrelated behavior.
- Run `tests/smoke_personal_apps.py` through mise on the current Windows x64 host, without PATH integration, and observe the pinned omp version from the isolated installation.
- Use a throwaway matrix/target inspection to verify both LTS releases and both Linux architectures, unchanged Windows assignments, and one ARM64 macOS assignment. Do not retain that script as a source-copy test.
- Run the PR's hosted Test workflow for the native OS-specific installation/PATH proof and unit suite. Do not run PATH integration against the owner's persistent settings.
- Read issue #11 and PR #9 after any tracker update to establish R6 from live state.

---

## Definition of Done

- All requirements are implemented and each unit's verification outcome is evidenced.
- Catalog and generated lock agree on supported targets; retained app pins and Windows runner selection are unchanged.
- Current support documentation reflects the policy, and reciprocal non-closing tracker links are observed.
- No compatibility shim, abandoned experiment, or throwaway verification script remains in the repository.
- Review findings are resolved or recorded durably, and a separate PR reaches a decided CI state without being merged automatically.
