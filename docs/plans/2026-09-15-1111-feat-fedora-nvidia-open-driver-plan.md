---
title: Fedora NVIDIA Open Driver Transition - Plan
type: feat
date: 2026-09-15
topic: fedora-nvidia-open-driver
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Fedora NVIDIA Open Driver Transition - Plan

## Goal Capsule

- **Objective:** Configure Fedora provisioning so that NVIDIA hosts on supported architectures (Ampere and newer) use the upstream open GPU kernel modules (`nvidia-open` and `kmod-nvidia-open-dkms`) from the NVIDIA CUDA repository.
- **Means:** Update `.chezmoidata/nvidia.yaml` to declare `nvidia-open` and `kmod-nvidia-open-dkms` for `currentBranch` and `ampere`, exclude `nvidia-open` in legacy CUDA repo policy, and align CI smoke assertions.
- **Product authority:** Preserve dotfiles' single-source driver policy where the NVIDIA CUDA repository is authoritative for current architectures and RPM Fusion is authoritative for legacy architectures.
- **Open blockers:** None.

## Product Contract

Product Contract preservation: Product Contract unchanged.

### Summary

Update Fedora NVIDIA package declarations in `.chezmoidata/nvidia.yaml` to specify `nvidia-open` and `kmod-nvidia-open-dkms` as the default driver stack for `currentBranch` and Ampere hosts. Exclude `nvidia-open` from the CUDA repository on legacy branches so RPM Fusion driver packages continue to win without interference.

### Problem Frame

NVIDIA's upstream CUDA repository for Fedora 44 updated to driver version 615.71.09, where `nvidia-open` and `kmod-nvidia-open-dkms` explicitly obsolete `cuda-drivers` and `kmod-nvidia-latest-dkms`. When a host running Fedora 44 with an Ampere GPU (GeForce RTX 3060) runs a routine system update, DNF automatically installs the open driver packages and removes the proprietary packages.

However, dotfiles' driver policy in `.chezmoidata/nvidia.yaml` still expects `cuda-drivers` and `kmod-nvidia-latest-dkms` as the declared packages and branch marker. Consequently, subsequent `chezmoi apply` runs detect the proprietary packages as missing and fail or attempt to revert the update. Furthermore, repository exclusion policies in the installer and test assertions in `.ci/smoke-fedora-nvidia-repo-policy.sh` still enforce the obsolete package names.

### Key Decisions

- **Transition `currentBranch` directly to the open driver stack** — Aligns with NVIDIA's upstream transition for 615+ where open kernel modules are the only available 615 packages and explicitly obsolete the proprietary packages for Turing and newer architectures. (session-settled: user-directed — chosen over introducing an explicit flavor or separate open branch: upstream NVIDIA CUDA 615+ obsoleted proprietary packages for current architectures). Governs R1, R2, R3.
- **Maintain existing DKMS MOK signing workflow** — `kmod-nvidia-open-dkms` uses the same DKMS module building and MOK signing path (`/var/lib/dkms/mok.pub`) as the previous proprietary DKMS package, requiring no alterations to Secure Boot enrollment. Governs R4.
- **Protect legacy branch isolation via CUDA exclusions** — Add `nvidia-open` to `legacyBranchCudaExcludes` so older GPUs (e.g. Pascal) relying on RPM Fusion's `akmod-nvidia-580xx` do not inadvertently pull open driver packages from the CUDA repository. Governs R5.

### Requirements

**Package declarations and driver policy**

- R1. `.chezmoidata/nvidia.yaml` must declare `nvidia-open` and `kmod-nvidia-open-dkms` under `currentBranch.packages` in place of `cuda-drivers` and `kmod-nvidia-latest-dkms`.
- R2. `.chezmoidata/nvidia.yaml` must set `currentBranch.marker` to `kmod-nvidia-open-dkms`.
- R3. `.chezmoidata/nvidia.yaml` must update `branches.ampere.marker` to `kmod-nvidia-open-dkms`.
- R4. Module build system configuration for `currentBranch` and `ampere` must remain `dkms`, preserving the existing MOK keypair generation and Secure Boot enrollment flow.
- R5. `.chezmoidata/nvidia.yaml` must include `nvidia-open` in `legacyBranchCudaExcludes` so legacy RPM Fusion hosts exclude it from the vendor CUDA repository.

**Installer reconciliation and verification**

- R6. `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` must continue rendering dynamically from `.chezmoidata/nvidia.yaml` without hardcoded driver package names.
- R7. `.ci/smoke-fedora-nvidia-repo-policy.sh` must assert that current branch resolution selects `kmod-nvidia-open-dkms` and `nvidia-open`, and that legacy branch policy correctly excludes `nvidia-open` alongside `cuda-drivers`.

### Acceptance Examples

- AE1. Given a Fedora 44 host with an RTX 3060 where `nvidia-open` and `kmod-nvidia-open-dkms` are installed, when the rendered NVIDIA installer runs, then it identifies all declared packages as present and exits without attempting to install `cuda-drivers` or `kmod-nvidia-latest-dkms`. Covers R1, R2, R3.
- AE2. Given a Fedora host resolving to the legacy Pascal branch, when repository policy is configured, then `cuda-fedora*.excludepkgs` includes both `cuda-drivers` and `nvidia-open`. Covers R5.
- AE3. Given the rendered installer, when `.ci/smoke-fedora-nvidia-repo-policy.sh` runs in CI, then it passes all branch resolution and exclusion assertions for both Ampere and Pascal architectures. Covers R7.

### Scope Boundaries

- **In scope:** Updating `.chezmoidata/nvidia.yaml` for `currentBranch`, `ampere`, and `legacyBranchCudaExcludes`, verifying `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` dynamic generation, and updating CI smoke test assertions in `.ci/smoke-fedora-nvidia-repo-policy.sh`.
- **Out of scope:** Modifying legacy driver branches (`pascal` / `580xx`), hybrid integrated-only policies, Jetson/Ubuntu provisioning, or MOK signing infrastructure.

### Sources / Research

- Upstream DNF transaction logs in `/home/h82/다운로드/dnf logs.md` confirmed DNF update replaced `cuda-drivers` and `kmod-nvidia-latest-dkms` (3:610.57.04-1.fc44) with `nvidia-open` and `kmod-nvidia-open-dkms` (3:615.71.09-1.fc44).
- `rpm -q --obsoletes nvidia-open kmod-nvidia-open-dkms` verified that `nvidia-open` obsoletes `cuda-drivers < 3:615.71.09` and `kmod-nvidia-open-dkms` obsoletes `kmod-nvidia-latest-dkms < 3:615.71.09`.
- `modinfo nvidia` verified kernel module version 615.71.09 is built with `license: Dual MIT/GPL`.
- `.chezmoidata/nvidia.yaml` defines driver architecture mapping and repository exclusion lists.
- `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` generates package lists and exclusions directly from `.chezmoidata/nvidia.yaml`.
- `.ci/smoke-fedora-nvidia-repo-policy.sh` validates repository exclusions and branch markers across all architectures.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Update `.chezmoidata/nvidia.yaml` data schema: replace `cuda-drivers` and `kmod-nvidia-latest-dkms` with `nvidia-open` and `kmod-nvidia-open-dkms` in `currentBranch.packages`, set `currentBranch.marker` and `branches.ampere.marker` to `kmod-nvidia-open-dkms`. (Governs R1, R2, R3; session-settled: user-directed).
- KTD2. Extend `legacyBranchCudaExcludes` in `.chezmoidata/nvidia.yaml` to include `nvidia-open`. RPM Fusion legacy hosts must exclude open packages from the vendor CUDA repo so RPM Fusion driver packages take precedence. (Governs R5).
- KTD3. Update `.ci/smoke-fedora-nvidia-repo-policy.sh` test harness to assert `kmod-nvidia-open-dkms` as the expected current branch marker and verify both `cuda-drivers` and `nvidia-open` are excluded on legacy branch runs. (Governs R7).

### Assumptions

- The NVIDIA CUDA repository for Fedora 44 remains the authoritative source for `currentBranch` driver packages.
- `kmod-nvidia-open-dkms` builds modules via DKMS and continues signing them using `/var/lib/dkms/mok.pub`, preserving the existing MOK Secure Boot trust chain.
- No changes to `run_onchange_before_10-nvidia.sh.tmpl` are required beyond verifying its template expansion matches the new data values.

### Outstanding Questions

- None. All requirements and technical designs are resolved.

---

## Implementation Units

### U1. Update NVIDIA driver declarations and exclusion policy in data

- **Goal:** Update `.chezmoidata/nvidia.yaml` to declare the open driver packages and marker for `currentBranch` and `ampere`, and add `nvidia-open` to legacy CUDA repository exclusions.
- **Requirements:** R1, R2, R3, R4, R5
- **Dependencies:** None
- **Files:** `.chezmoidata/nvidia.yaml`
- **Approach:**
  1. In `branches.ampere`: update `marker: kmod-nvidia-open-dkms`.
  2. In `currentBranch`: update `marker: kmod-nvidia-open-dkms`.
  3. In `currentBranch.packages`: replace `cuda-drivers` with `nvidia-open` and `kmod-nvidia-latest-dkms` with `kmod-nvidia-open-dkms`.
  4. In `legacyBranchCudaExcludes`: add `nvidia-open`.
- **Patterns to follow:** Existing structure of `.chezmoidata/nvidia.yaml`.
- **Test scenarios:**
  - Verify `.chezmoidata/nvidia.yaml` is valid YAML.
  - Verify `kmod-nvidia-open-dkms` is recognized as the marker for Ampere and current branch.

### U2. Update CI smoke test assertions for repository and branch policy

- **Goal:** Align `.ci/smoke-fedora-nvidia-repo-policy.sh` with the open driver package set and marker.
- **Requirements:** R6, R7
- **Dependencies:** U1
- **Files:** `.ci/smoke-fedora-nvidia-repo-policy.sh`
- **Approach:**
  1. Update current branch assertions: check `packages=.*kmod-nvidia-open-dkms` and `packages=.*nvidia-open`.
  2. Update `ampere_clean_out` stub from `RPM_INSTALLED='kmod-nvidia-latest-dkms'` to `RPM_INSTALLED='kmod-nvidia-open-dkms'`.
  3. Ensure legacy branch exclusions check asserts `nvidia-open` is excluded from the CUDA repository.
- **Patterns to follow:** Existing structure and extraction harness in `.ci/smoke-fedora-nvidia-repo-policy.sh`.
- **Test scenarios:**
  - Covers AE3. Execute `.ci/smoke-fedora-nvidia-repo-policy.sh` with a rendered installer script and ensure all tests pass cleanly.

### U3. Verify template rendering and package state reconciliation

- **Goal:** Verify that the rendered installer accurately reflects `.chezmoidata/nvidia.yaml` and succeeds on the current host.
- **Requirements:** R1, R2, R3, R4, R5, R6
- **Dependencies:** U1, U2
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`
- **Approach:**
  1. Render the script using chezmoi template execution or render test helpers.
  2. Confirm `nvidia_packages`, `nvidia_branch_markers`, and exclusions match the updated data.
- **Test scenarios:**
  - Covers AE1, AE2. Verify `install_nvidia_packages` identifies `nvidia-open` and `kmod-nvidia-open-dkms` without error.

---

## Verification Contract

- Run smoke test: `.ci/smoke-fedora-nvidia-repo-policy.sh`
- Run MOK smoke test: `.ci/smoke-fedora-dkms-mok.sh`
- Run render test: `.github/workflows/render-dotfiles.yml` or local render check
- Run skip declaration check: `.ci/check-skip-declarations.sh`

---

## Definition of Done

- All implementation units (U1, U2, U3) completed.
- All verification tests pass.
- Git working directory clean with changes committed.
