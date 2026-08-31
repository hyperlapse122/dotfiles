---
title: "refactor: Provision Ghostty via Terra repository instead of COPR"
date: "2026-08-31"
type: refactor
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

## Goal Capsule

- **Objective:** Provision Ghostty terminal emulator on Fedora via the Terra repository rather than the community COPR (`scottames/ghostty`), ensuring reliable, upstream-aligned package delivery and GPG-verified repository management.
- **Means:** Remove `scottames/ghostty` from `fedora.coprs` in `.chezmoidata/packages.yaml`, configure `terra-release` installation in `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl`, and verify package manifest compliance.
- **Product Authority:** Dotfiles repository package management and Fedora component installer scripts.
- **Stop Conditions:** Package ownership and manifest validation checks (`test-packages-manifest.sh`, `test-package-ownership.sh`) pass cleanly with Terra provisioning in place and COPR removed.

---

## Product Contract

### Summary

Ghostty was previously provisioned on Fedora via the `scottames/ghostty` community COPR repository. The upstream Ghostty documentation and Terra packaging project support Ghostty distribution via Terra (`terra-release`). This refactor switches Fedora Ghostty provisioning to use the Terra repository by installing `terra-release` / `terra-gpg-keys` and removing the COPR configuration.

### Problem Frame

COPR repositories are user-maintained personal builds that can vary in maintenance cadence. Terra is a centralized, curated repository for Fedora that maintains packages not shipped directly by upstream Fedora, including Ghostty. Upstream Ghostty binary installation documentation explicitly recommends Terra alongside COPR for Fedora users. Migrating to Terra unifies packaging under a structured third-party release repository package.

### Key Decisions

- KD1. **Terra Package Repository as Authoritative Fedora Ghostty Source** `(session-settled: user-directed — chosen over Fedora COPR: Terra provides official community RPM builds for Ghostty and is referenced in official Ghostty install documentation)`
  - Governs R1, R2, R3.
- KD2. **`terra-release` RPM Bootstrap for Repository Management**
  - Installing `terra-release` and `terra-gpg-keys` via DNF `--repofrompath` is the standard, documented method to establish the Terra repository configuration (`/etc/yum.repos.d/terra.repo`) and import its RPM GPG signing keys.
  - Governs R2.

### Requirements

- R1. Remove `scottames/ghostty` from `fedora.coprs` in `.chezmoidata/packages.yaml`.
- R2. Update `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl` to install `terra-release` and `terra-gpg-keys` when absent, and remove `scottames/ghostty` from `dev_coprs`.
- R3. Maintain `ghosttyTerminal` capability in `.chezmoidata/packages.yaml` with managed DNF ownership on Fedora.
- R4. Validate all changes through existing `.ci/test-packages-manifest.sh` and `.ci/test-package-ownership.sh` suites.

### Acceptance Examples

- AE1. **Package Manifest Compliance**
  - **Given:** `.chezmoidata/packages.yaml` is validated by `.ci/test-packages-manifest.sh`.
  - **When:** Manifest validation runs.
  - **Then:** Validation passes without errors, and `scottames/ghostty` is not present in `coprs`.
  - **Covered by:** R1, R3, R4.

- AE2. **Devtools Script Repository Setup**
  - **Given:** `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl` is rendered.
  - **When:** `setup_dev_repos` executes on a Fedora host.
  - **Then:** `terra-release` is checked and installed if absent, enabling the Terra repository for subsequent `ghostty` installation.
  - **Covered by:** R2, R4.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Terra Repository Bootstrap via `terra-release` RPM**
  - In `run_onchange_before_80-devtools.sh.tmpl`, `setup_dev_repos()` checks `rpm -q terra-release`. If not installed, it runs `${DNF[@]} install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys`. This ensures the `.repo` files and GPG keys are managed cleanly as RPM packages.
- KTD2. **Removal of Stale COPR References**
  - Emptying `dev_coprs` in `run_onchange_before_80-devtools.sh.tmpl` and setting `coprs: []` in `.chezmoidata/packages.yaml` ensures no dangling COPR enablement occurs.

---

## Implementation Units

### U1. Update Package Manifests and Remove COPR Reference

- **Goal:** Update `.chezmoidata/packages.yaml` to remove `scottames/ghostty` from `coprs:`.
- **Requirements:** R1, R3.
- **Dependencies:** None.
- **Files:** `.chezmoidata/packages.yaml`
- **Approach:**
  1. Remove `scottames/ghostty` from `packages.linux.fedora.coprs` (leave `coprs: []` or empty list).
  2. Verify that `ghosttyTerminal` capability under `authority.capabilities` remains valid.
- **Test Scenarios:**
  - Happy path: Manifest validation runs and passes with `coprs` having no `scottames/ghostty`.
- **Verification:** Run `.ci/test-packages-manifest.sh` and `.ci/test-package-ownership.sh`.

### U2. Update Fedora Devtools Provisioning Script for Terra

- **Goal:** Update `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl` to bootstrap the Terra repository and install Ghostty.
- **Requirements:** R2.
- **Dependencies:** U1.
- **Files:** `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl`
- **Approach:**
  1. In `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl`, remove `scottames/ghostty` from `dev_coprs`.
  2. Update `setup_dev_repos()` to install `terra-release` and `terra-gpg-keys` using `--nogpgcheck --repofrompath "terra,https://repos.fyralabs.com/terra\$releasever"` if `rpm -q terra-release` returns non-zero.
- **Test Scenarios:**
  - Script template renders cleanly with `chezmoi execute-template`.
  - Script syntax checks valid with `bash -n`.
- **Verification:** Execute `chezmoi execute-template < .chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl | bash -n`.

---

## Verification Contract

- Run `./.ci/test-packages-manifest.sh` to confirm manifest validation.
- Run `./.ci/test-package-ownership.sh` to confirm capability ownership and sentinel validation.
- Render all Fedora script templates using `chezmoi execute-template` to confirm no template syntax errors.

---

## Definition of Done

- Ghostty provisioning is configured to use Terra repository on Fedora.
- Stale `scottames/ghostty` COPR declarations are removed.
- All manifest tests and template render checks pass with zero errors.
- Abandoned code and temporary files are cleaned up.
