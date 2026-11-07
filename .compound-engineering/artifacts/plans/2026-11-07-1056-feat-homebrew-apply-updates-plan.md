---
title: Homebrew Updates During Apply - Plan
type: feat
date: 2026-11-07
topic: homebrew-apply-updates
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Homebrew Updates During Apply - Plan

## Goal Capsule

**Objective:** The owner keeps Homebrew packages current as part of applying personal configuration.
**Means:** Extend the existing macOS application step (KTD1).
**Authority:** The session's agreed behavior and repository AGENTS.md govern this plan; implementation details remain planning-owned.
**Stop conditions:** Report evidence that invalidates a settled decision or requires changing the agreed update scope.
**Execution profile:** One bounded unit, one PR; the caller implements, verifies, reviews, rebases on origin/main before pushing, and opens the PR.

## Product Contract

### Summary

Every full personal-configuration application on supported macOS updates Homebrew metadata and upgrades installed Homebrew packages, including packages outside this repository's declarations.

### Problem Frame

The owner misses manual package updates and wants ordinary configuration application to keep the machine current.

### Requirements

- R1. Every explicit full chezmoi apply on the supported native Apple Silicon macOS host runs plain `brew update` followed by plain `brew upgrade`, even when declared applications are already present.
- R2. Upgrade selection covers the full Homebrew installation using native pin and cask defaults, without a package allowlist or forced upgrades.
- R3. An update failure prevents upgrade and fails application; an upgrade failure also fails application.
- R4. Worktree preparation, bootstrap, and configuration preview must not run either operation; Windows and Linux application behavior stays unchanged.
- R5. Existing missing-application installation remains available and development-tool version ownership remains with mise.

### Key Decisions

- **Use native updates without a lockfile.** Governs R1, R2. (session-settled: user-directed — chosen over exact-version locking: the owner chose simple Homebrew updates.)
- **Update the whole Homebrew installation.** Governs R2. (session-settled: user-directed — chosen over repository-owned packages only: the owner explicitly chose the full scope.)
- **Run during application.** Governs R1, R4. (session-settled: user-directed — chosen over a daily scheduled job: the owner prefers updating whenever chezmoi apply runs.)

### Scope Boundaries

No new scheduler, Homebrew lockfile, Actions updater, explicit cleanup, greedy upgrade flags, pin overrides, or package ownership declarations.
No automatic Podman installation or VM management is added; a Homebrew-installed Podman package participates in R2.
No retries or custom package failure classification are added because R3 exposes failures directly.

## Planning Contract

### Key Technical Decisions

- KTD1. **Reuse the existing per-apply macOS application hook.** Extend `scripts/macos-apps.sh` after its existing install loop, relying on its existing platform and prefix checks and `set -eu` for R1-R3 and R5. `home/.chezmoiscripts/run_before_15-install-macos-apps.sh.tmpl` is already an every-run hook, so no new hook or task is needed. This is a local two-command pattern application, not an architectural change.
- KTD2. **Verify through the existing isolated application fixture.** Extend `tests/test_macos_apps.py` and, only as needed, `tests/test_macos_bootstrap.py` to model individual update/upgrade failures. The fake command PATH protects the real host; it proves ordering and exit behavior, but does not prove upstream package installations.
- KTD3. **Correct the setup guide's update boundary.** Revise `docs/setup/macos.md` and `docs/guides/terminal.md` to explain R1-R5 and qualify its statement about leaving existing Podman installations untouched: Homebrew-installed packages now receive R2, while VM lifecycle remains unmanaged.

## Implementation Units

### U1. Update Homebrew packages during macOS application

- **Goal:** Deliver R1-R5 without another configuration entry point.
- **Requirements:** R1-R5; KTD1-KTD3.
- **Dependencies:** Existing per-apply macOS hook and its isolated MacFixture tests.
- **Files:** `scripts/macos-apps.sh`, `tests/test_macos_apps.py`, `tests/test_macos_bootstrap.py` if required for command-specific failure injection, `docs/setup/macos.md`, and `docs/guides/terminal.md`.
- **Approach:** Append the update pair after required applications are ensured; retain native Homebrew behavior. Adjust existing reuse assertions to forbid repeated installation while expecting the global upgrade. Preserve native Podman command and VM-state noninterference assertions.
- **Patterns:** Existing script failure propagation, `MacFixture` isolated PATH, and platform-gated hook rendering tests.
- **Execution note:** Add focused failure and repeated-run proof without executing real Homebrew upgrades.
- **Test scenarios:**
  - A first application installs missing declared packages, then requests update and global upgrade in that order.
  - Two real chezmoi applies against a disposable source containing the rendered native hook request both update commands each time without reinstalling declared packages.
  - An empty declaration list still requests global update and upgrade with no package allowlist or extra flags.
  - Update failure exits unsuccessfully without requesting upgrade; upgrade failure exits unsuccessfully.
  - Existing unsupported-host guards stop before any package mutation, and the native hook remains absent off the supported platform.
  - Application never invokes Podman VM commands, even when an installed Homebrew Podman package exists.
- **Verification:** Focused tests prove update selection, repeat execution, ordering, failure propagation, and retained platform boundaries; the platform area remains green.

## Verification Contract

Run `mise exec -- python -m unittest discover -s tests -p test_macos_apps.py`, then `mise exec -- python scripts/run-test-area.py --area platform`.
Run shell syntax validation on the changed shell script and `git diff --check`.
Use the existing hook-rendering and bootstrap tests to cover R4; run no real chezmoi apply or Homebrew update on the owner's machine.
Browser testing and release validation are inapplicable to this shell-only change.

## Definition of Done

U1 satisfies R1-R5, focused and platform checks pass, setup documentation describes the new all-package update behavior, and no experimental code or unrelated changes remain.
