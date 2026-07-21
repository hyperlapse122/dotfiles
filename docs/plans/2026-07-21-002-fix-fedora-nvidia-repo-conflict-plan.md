---
title: Fedora NVIDIA Repository Conflict - Plan
type: fix
date: 2026-07-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fedora NVIDIA Repository Conflict - Plan

## Goal Capsule

- **Objective:** Make Fedora provisioning converge when NVIDIA's CUDA repository and RPM Fusion expose mutually incompatible NVIDIA driver package families.
- **Authority:** Preserve this repository's existing choice of NVIDIA's CUDA repository and DKMS driver packages on Fedora; treat RPM Fusion as the source for unrelated nonfree software, not a second NVIDIA driver source.
- **Execution profile:** Configuration and packaging change with render-time assertions plus an isolated DNF-command smoke harness; do not deploy to the live home directory during verification.
- **Stop conditions:** Stop if DNF cannot express repository-scoped package exclusions without disabling unrelated RPM Fusion packages, or if the proposed policy would remove installed drivers in an unattended transaction.
- **Tail ownership:** The implementation is complete after source-only rendering, shell validation, targeted smoke coverage, and the repository's standard CI checks pass.

---

## Product Contract

### Summary

Fedora provisioning will configure one NVIDIA driver authority before any package-presence fast path can return. NVIDIA's CUDA repository remains authoritative for the existing `cuda-drivers`, `nvidia-driver`, and `kmod-nvidia-latest-dkms` stack, while RPM Fusion's NVIDIA driver packages are excluded at repository scope so they cannot enter the same DNF transaction.

### Problem Frame

The Fedora installer enables both the NVIDIA CUDA repository and RPM Fusion. Both repositories publish packages that provide the NVIDIA CUDA driver capability, but their package layouts conflict: the installed `nvidia-driver-cuda` package from `cuda-fedora44-x86_64` conflicts with RPM Fusion's `xorg-x11-drv-nvidia-cuda`. DNF then cannot choose a best installation candidate.

The current installer also runs repository setup only when a declared package is missing. A host that already has every declared package can therefore return before a corrected repository policy is reconciled, leaving later installs and updates exposed to the same conflict.

### Requirements

**Repository ownership**

- R1. Fedora NVIDIA hosts must retain NVIDIA's CUDA repository as the sole source of NVIDIA driver packages already declared in `.chezmoidata/packages.yaml`.
- R2. RPM Fusion repositories must remain enabled for non-driver packages while their NVIDIA driver package namespace is excluded from consideration.
- R3. Repository exclusions must be declared in `.chezmoidata/packages.yaml` and rendered by the Fedora installer rather than embedded as an untracked one-off command.

**Convergence and safety**

- R4. The NVIDIA repository policy must run before `install_fedora_packages` can take its all-packages-present fast path.
- R5. A missing or unavailable RPM Fusion repository must be a clean no-op, and non-NVIDIA hosts must not receive NVIDIA-specific repository changes.
- R6. The fix must not remove, swap, downgrade, or replace installed NVIDIA packages automatically.
- R7. Repeated applies must leave the same repository configuration and complete without introducing duplicate repository definitions.

**Verification**

- R8. CI must prove that the rendered Fedora installer carries the repository exclusion policy, executes it before the package fast path, and preserves the NVIDIA CUDA/DKMS package set.
- R9. Verification must exercise both an NVIDIA host with the conflicting RPM Fusion repository present and a host where that repository is absent.

### Acceptance Examples

- AE1. Given an NVIDIA Fedora host where all declared packages are installed and `rpmfusion-nonfree-nvidia-driver` is enabled, when the rendered installer runs, then it applies the repository-scoped NVIDIA package exclusions before reporting that all packages are present.
- AE2. Given an NVIDIA Fedora host where the conflicting RPM Fusion repository is absent, when the installer reconciles repository policy, then it skips that repository and continues successfully.
- AE3. Given a Fedora host without an NVIDIA GPU, when the installer runs, then it does not mutate RPM Fusion's NVIDIA repository settings.
- AE4. Given the reported Fedora 44 package state, when DNF next resolves the managed package set after reconciliation, then `xorg-x11-drv-nvidia-cuda` is not considered from RPM Fusion and the installed `nvidia-driver-cuda` package is not replaced or erased by this installer.

### Scope Boundaries

- **In scope:** Fedora repository policy, the source package manifest, the rendered installer, and focused render/smoke assertions.
- **Out of scope:** Switching Fedora to RPM Fusion's `akmod-nvidia` stack, changing Ubuntu NVIDIA provisioning, removing already-installed packages, or deploying the source state to the live home directory.
- **Deferred to follow-up work:** Re-evaluate whether Fedora should adopt RPM Fusion's driver stack and its separate Secure Boot signing lifecycle; that migration is broader than resolving this package transaction conflict.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Keep NVIDIA's CUDA repository as Fedora's driver authority. The existing manifest, DKMS MOK comments, service flow, and Ubuntu parity all assume `cuda-drivers`, `nvidia-driver`, and `kmod-nvidia-latest-dkms`; changing authority would turn a package-conflict fix into a driver and Secure Boot migration.
- KTD2. Apply repository-scoped exclusions to RPM Fusion's NVIDIA driver package namespace rather than disabling RPM Fusion wholesale. Steam and other nonfree packages still depend on RPM Fusion, so only incompatible driver candidates should be filtered.
- KTD3. Reconcile the policy in a dedicated NVIDIA-gated function invoked before `install_fedora_packages`. Keeping the reconciliation outside `setup_fedora_repos` ensures existing fully provisioned hosts are repaired instead of exiting early.
- KTD4. Guard each repository option by repository presence and make the operation idempotent. Fedora releases can expose different RPM Fusion repository IDs, so absent configured IDs are expected rather than fatal.
- KTD5. Do not add unattended package erasure or swapping. Preventing the competing candidate is sufficient for the reported conflict and avoids risking a temporarily driverless graphical host.

### Assumptions

- DNF 5 continues to support persistent repository-scoped `exclude`/`excludepkgs` options through `dnf config-manager setopt`; implementation must confirm the accepted spelling against the Fedora version in the repository's render/smoke environment.
- The reported conflict comes from RPM Fusion package names in the `xorg-x11-drv-nvidia`, `akmod-nvidia`, or `kmod-nvidia` families; the data declaration should cover the complete incompatible namespace without excluding unrelated RPM Fusion packages.
- Existing NVIDIA CUDA repository setup remains valid and continues to supply the declared Fedora packages.

### Sources and Research

- `.chezmoidata/packages.yaml` declares both NVIDIA CUDA driver metapackages and the toolkit under `fedora.nvidiaPackages`.
- `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` enables RPM Fusion and NVIDIA repositories, but repository setup occurs only after the package-presence check.
- NVIDIA's CUDA 13.3 Linux installation guide recommends the `cuda-toolkit` package for toolkit-only installation and documents that conflicting package-manager installations must not be mixed: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html
- RPM Fusion's CUDA guide states that the NVIDIA and RPM Fusion driver package layouts conflict and must not be mixed; its alternative recommendation is RPM Fusion's driver plus exclusions in the CUDA repository: https://rpmfusion.org/Howto/CUDA

---

## Implementation Units

### U1. Declare and reconcile Fedora NVIDIA repository ownership

- **Goal:** Prevent RPM Fusion NVIDIA driver packages from participating in DNF resolution while preserving the existing CUDA-repository driver stack.
- **Requirements:** R1-R7; AE1-AE4; KTD1-KTD5.
- **Dependencies:** None.
- **Files:** `.chezmoidata/packages.yaml`, `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`.
- **Approach:** Add a Fedora data declaration for repository-scoped NVIDIA package exclusions. Render it into a dedicated NVIDIA-gated reconciliation function that discovers configured repository IDs, applies options only to matching repositories, and runs before `install_fedora_packages`. Keep `setup_nvidia_repos` responsible for adding NVIDIA's own repositories and preserve the current NVIDIA package list and post-install lifecycle.
- **Execution note:** This is packaging/config work; establish the rendered command and no-op behavior with a stubbed smoke harness before relying on a live DNF transaction.
- **Patterns to follow:** The manifest-driven package arrays in `.chezmoidata/packages.yaml`; the installer's guarded/idempotent `setup_*_repos` functions; the existing `HAS_NVIDIA` fact gate; `.github/workflows/render-dotfiles.yml` isolated rendering conventions.
- **Test scenarios:**
  - Covers AE1. Render an NVIDIA-host variant with a stubbed DNF repository list containing the conflicting RPM Fusion repository and all RPM queries succeeding; verify the exclusion command is recorded before the package fast-path message.
  - Covers AE2. Run the same harness without the configured RPM Fusion repository; verify no repository option is applied and execution succeeds.
  - Covers AE3. Render or execute the non-NVIDIA branch; verify no NVIDIA repository exclusion command runs.
  - Covers AE4. Inspect the rendered exclusion set; verify it includes RPM Fusion's conflicting `xorg-x11-drv-nvidia-cuda` family while the managed package array still contains the CUDA-repository driver packages.
  - Run the reconciliation twice against the stubbed repository state; verify the second run emits the same effective option and does not create duplicate definitions.
- **Verification:** The rendered Fedora script is valid Bash, the stub harness proves order and no-op behavior, and source comments describe the single-driver-authority policy without changing the Ubuntu path.

### U2. Lock the Fedora NVIDIA solver policy into CI

- **Goal:** Make future package-list or installer refactors fail CI if they reintroduce mixed NVIDIA driver ownership or move reconciliation behind the package fast path.
- **Requirements:** R8-R9; AE1-AE3.
- **Dependencies:** U1.
- **Files:** `.github/workflows/render-dotfiles.yml`, `.chezmoidata/packages.yaml`, `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`.
- **Approach:** Extend the existing Fedora internals assertions with focused checks for the rendered repository policy, package-family ownership, and call ordering. Use the workflow's per-user/container scratch conventions and stub commands; do not execute the full privileged installer or contact live package repositories.
- **Execution note:** Keep CI deterministic: test rendered text and stubbed command behavior, not current remote repository metadata.
- **Patterns to follow:** The workflow's `render_from` helper, negative contract fixtures under `Assert fact-registry failure contracts`, and rendered-script `bash -n`/grep assertions.
- **Test scenarios:**
  - The normal Fedora render contains the repository exclusion data and the reconciliation call before `install_fedora_packages`.
  - A fixture that removes or renames the exclusion declaration fails the targeted assertion.
  - A fixture with no matching RPM Fusion repository exits successfully and records no `config-manager setopt` call.
  - The Ubuntu render and Ubuntu package declaration remain unchanged.
- **Verification:** `render-dotfiles.yml` exercises the new contract on Fedora, existing render jobs still produce all platform artifacts, and shellcheck continues to pass for the rendered installer.

---

## Verification Contract

| Gate | Applies to | Evidence |
|---|---|---|
| Source render | U1, U2 | Render the Fedora installer with `chezmoi --source "$PWD" execute-template` under the repository's isolated config and newline-free `op` stub; no template markers or render errors remain. |
| Shell validity | U1 | `bash -n` and the repository shellcheck job accept the rendered Fedora installer. |
| Repository-policy smoke | U1, U2 | Stubbed DNF/RPM execution proves present-repository, absent-repository, all-packages-present, non-NVIDIA, and repeated-apply behavior without privileged host mutation. |
| Workflow validation | U2 | The repository's workflow/static checks accept `.github/workflows/render-dotfiles.yml`, and both `render-dotfiles.yml` and `ci.yml` pass in CI. |
| Repository hygiene | All | `git diff --check`, `git status`, and a requested-scope diff show only the plan, Fedora package data/installer, and focused verification changes. |

---

## Definition of Done

- R1-R9 and AE1-AE4 are covered by U1-U2 evidence.
- Fedora uses one managed NVIDIA driver package authority per DNF transaction while RPM Fusion remains usable for unrelated packages.
- The corrective policy runs on already-provisioned NVIDIA hosts before the package fast path.
- No unattended package erase, swap, downgrade, live-home apply, or Ubuntu behavior change is introduced.
- Rendered Fedora Bash passes syntax and shellcheck, the stubbed repository-policy scenarios pass, and both repository workflows are green.
- Comments and data remain the source of truth, `CLAUDE.md` remains exactly `@AGENTS.md`, and abandoned experimental code is absent from the final diff.
