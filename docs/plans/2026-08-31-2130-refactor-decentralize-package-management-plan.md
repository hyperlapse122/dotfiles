---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Refactor Decentralized Modular Package Management Plan

## Goal Capsule

- **Objective:** Eliminate the centralized `.chezmoidata/packages.yaml` manifest and decentralize package declarations into feature-scoped scripts across all supported operating systems (Fedora, Ubuntu, macOS).
- **Means:** Remove `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl` (KTD4); unify package installation in `.chezmoiscripts/20-base/` and `.chezmoiscripts/30-components/` with per-OS execution branches (KTD1); extend Flatpak support to Ubuntu (KTD2) and .NET tool support across all platforms (KTD3); update tests and documentation.
- **Product authority:** dotfiles maintainer (iam@h82.dev).
- **Open blockers:** None.

---

## Product Contract

### Summary

This refactoring removes the centralized `.chezmoidata/packages.yaml` data manifest and its accompanying validation template. Package declarations and installations are moved directly into modular scripts (`20-base/` and feature-scoped `30-components/`), with native per-OS branching for Fedora (dnf/flatpak/dotnet), Ubuntu (apt/flatpak/dotnet), and macOS (brew/dotnet).

### Problem Frame

The centralized `.chezmoidata/packages.yaml` and `packages.authority` model introduced high coupling between disparate system components. Adding, updating, or debugging a package for a specific subsystem (e.g., Podman, NVIDIA, DevTools) required editing a large shared YAML file, maintaining strict cross-platform metadata matrices, and updating central schema validators even for localized tools. Shifting ownership directly to feature modules encapsulates package knowledge with the feature logic itself and simplifies maintenance.

### Key Decisions

- **KD1. Feature-scoped component unification.** (session-settled: user-directed — chosen over OS-partitioned directory structure: encapsulates all package logic for a domain in one script/module). Governs R1, R2.
- **KD2. Flatpak provisioning on Ubuntu.** (session-settled: user-directed — chosen over apt-only delivery on Ubuntu: provides consistent Flathub application management across Linux distros). Governs R3.
- **KD3. Universal .NET global tools support.** (session-settled: user-directed — chosen over partial/distro-limited .NET tool provisioning: ensures tools like git-credential-manager and powershell are installed on Fedora, Ubuntu, and macOS). Governs R4.
- **KD4. Complete removal of central package manifest and validation template.** (session-settled: user-directed — chosen over retaining a trimmed metadata schema: fully decouples components from a central YAML registry). Governs R5, R6, R7.

### Requirements

#### Package Decentralization & Module Structure

- R1. Package installation for system components (such as NVIDIA drivers, Podman container tooling, Tailscale, Desktop IME, Applications, and Developer Tooling) MUST be owned by feature-scoped scripts under `.chezmoiscripts/30-components/`.
- R2. Each feature component script MUST determine applicable package managers (DNF, APT, Homebrew, Flatpak, .NET CLI) based on the detected host OS (`.chezmoi.os`, `.chezmoi.osRelease.id`) and install the declared packages.
- R3. The `40-flatpaks` component script MUST support installing declared Flatpak applications (`com.discordapp.Discord`, `org.telegram.desktop`, `io.github.nroduit.Weasis`) on both Fedora and Ubuntu hosts.
- R4. The `50-dotnet` component script MUST support installing declared .NET global tools (`git-credential-manager`, `powershell`, `csharp-ls`) on Fedora, Ubuntu, and macOS hosts.

#### Base Provisioning & Cleanup

- R5. `.chezmoidata/packages.yaml` MUST be completely deleted from the repository, and all template references to `.packages` in base installers (`20-base/`, `20-darwin/`, `20-linux-ubuntu/`) MUST be replaced with direct script-defined package arrays.
- R6. `.chezmoitemplates/packages-validate.tmpl` MUST be removed, and `.ci/test-package-ownership.sh` and `.ci/test-packages-manifest.sh` MUST be updated or retired to reflect the removal of the central package manifest.
- R7. Repository documentation (`AGENTS.md`, `.chezmoitemplates/agents-instructions.tmpl`, and helper scripts such as `executable_host-facts.tmpl`) MUST be updated to remove references to `packages.yaml`.

### Scope Boundaries

- **In scope:**
  - Deleting `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl`.
  - Refactoring `.chezmoiscripts/20-base/` and `.chezmoiscripts/30-components/` into unified feature modules with OS branches.
  - Adding Flatpak support to Ubuntu and .NET tool support across Fedora, Ubuntu, and macOS.
  - Updating CI tests and documentation.
- **Out of scope:**
  - Modifying non-package configuration manifests (`facts.yaml`, `system.yaml`, `commands.yaml`, `agents.yaml`, `fonts.yaml`, `networking.yaml`).
  - Changing the set of installed packages or application versions beyond the requested Flatpak/dotnet additions.

### Acceptance Examples

- AE1. **Fedora component execution:** On a Fedora host, running `chezmoi apply` triggers `20-base` and `30-components` using DNF, Flatpak, and .NET CLI to install all required packages without reading `.packages`. (Covers R1, R2, R3, R4, R5)
- AE2. **Ubuntu component execution:** On an Ubuntu/Jetson host, running `chezmoi apply` triggers `20-base` and `30-components` using APT, Flatpak, and .NET CLI to install all required packages without reading `.packages`. (Covers R1, R2, R3, R4, R5)
- AE3. **macOS component execution:** On a macOS host, running `chezmoi apply` triggers `20-darwin` and `30-components` using Homebrew and .NET CLI without reading `.packages`. (Covers R1, R2, R4, R5)
- AE4. **Manifest and validator removal verification:** Rendering all templates via `chezmoi execute-template` succeeds in the absence of `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl`. (Covers R5, R6, R7)

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Flat feature-based script layout in `30-components/`.** (session-settled: user-directed — chosen over `30-components/<os>/` subdirectories). Each component script (e.g. `run_onchange_before_10-nvidia.sh.tmpl`, `run_onchange_before_20-podman.sh.tmpl`, `run_onchange_before_30-tailscale.sh.tmpl`, `run_onchange_before_40-flatpaks.sh.tmpl`, `run_onchange_before_50-dotnet.sh.tmpl`, `run_onchange_before_60-desktop-ime.sh.tmpl`, `run_onchange_before_70-apps.sh.tmpl`, `run_onchange_before_80-devtools.sh.tmpl`) is located directly in `.chezmoiscripts/30-components/` and uses Go template conditionals (`{{ if eq .chezmoi.os "linux" }}`, `{{ if eq .chezmoi.os "darwin" }}`) to execute per-OS installation logic. (Governs R1, R2)
- **KTD2. Direct Homebrew and Apt definitions.** In `20-darwin/run_onchange_before_homebrew.sh.tmpl` and `20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl`, replace loop iterations over `.packages.authority.capabilities` with static, explicit package lists in the script templates. (Governs R5)
- **KTD3. Complete elimination of `.packages` data dependency.** Remove `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl`. Remove `.packages` lookups from `executable_host-facts.tmpl`. (Governs R5, R6, R7)
- **KTD4. Test modernization.** Update `.ci/` test scripts to validate template rendering and absence of stale manifest lookups rather than asserting `.packages.authority` schema. (Governs R6)

---

## Implementation Units

### U1. Refactor and Unify `30-components/` Scripts

- **Goal:** Consolidate `30-components/fedora/` and `30-components/ubuntu/` into unified, feature-scoped scripts directly under `.chezmoiscripts/30-components/`, supporting Fedora, Ubuntu, and Darwin as applicable.
- **Requirements:** R1, R2, R3, R4
- **Files:**
  - `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_20-podman.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_30-tailscale.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_50-dotnet.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`
  - `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`
  - Delete `.chezmoiscripts/30-components/fedora/*` and `.chezmoiscripts/30-components/ubuntu/*`
- **Approach:** Move and merge the scripts into `.chezmoiscripts/30-components/`. For `40-flatpaks`, support both Fedora and Ubuntu. For `50-dotnet`, support Fedora, Ubuntu, and Darwin (`darwin`, `linux`).
- **Test Scenarios:**
  - Render each component script for Fedora (`os: linux, osRelease.id: fedora`).
  - Render each component script for Ubuntu (`os: linux, osRelease.id: ubuntu`).
  - Render `50-dotnet` for macOS (`os: darwin`).
  - Shellcheck on all rendered scripts.
- **Verification:** Shellcheck passes; rendered scripts output valid bash for targeted platforms.

### U2. Update Base Installers

- **Goal:** Remove `.packages` references from `20-base/`, `20-darwin/`, and `20-linux-ubuntu/`.
- **Requirements:** R5
- **Files:**
  - `.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`
  - `.chezmoiscripts/20-base/ubuntu/run_onchange_before_base.sh.tmpl`
  - `.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl`
  - `.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl`
- **Approach:**
  - In `20-base/fedora/`, remove `packages.linux.fedora.gates` validation and `packages-validate.tmpl` include.
  - In `20-darwin/run_onchange_before_homebrew.sh.tmpl`, replace `.packages.authority.capabilities` range with static Brewfile formulas/casks.
  - In `20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl`, replace `.packages.authority.capabilities` range with static apt packages and keep 1Password desktop installation.
- **Test Scenarios:**
  - Render `20-base/fedora/run_onchange_before_base.sh.tmpl` without errors.
  - Render `20-darwin/run_onchange_before_homebrew.sh.tmpl` on macOS context without errors.
  - Render `20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl` on Ubuntu context without errors.
- **Verification:** All base scripts render successfully and pass shellcheck.

### U3. Delete `packages.yaml` and `packages-validate.tmpl`

- **Goal:** Completely remove the centralized package manifest and its schema validator.
- **Requirements:** R5, R6
- **Files:**
  - Delete `.chezmoidata/packages.yaml`
  - Delete `.chezmoitemplates/packages-validate.tmpl`
- **Approach:** Remove the two files from the repository.
- **Test Scenarios:**
  - Verify that `chezmoi execute-template` commands on remaining templates do not attempt to read `packages.yaml` or include `packages-validate.tmpl`.
- **Verification:** Files deleted; no broken template includes.

### U4. Update Helper Scripts and CI Tests

- **Goal:** Remove references to `.packages` from helper scripts and update or retire CI tests that depended on `packages.yaml`.
- **Requirements:** R6, R7
- **Files:**
  - `dot_local/share/chezmoi-command-sources/executable_host-facts.tmpl`
  - `.ci/test-package-ownership.sh`
  - `.ci/test-packages-manifest.sh`
- **Approach:**
  - In `executable_host-facts.tmpl`, remove `.packages.linux` lookups.
  - Update or retire `.ci/test-packages-manifest.sh` and `.ci/test-package-ownership.sh` so CI does not fail on missing `packages.yaml`.
- **Test Scenarios:**
  - Run `.ci/test-packages-manifest.sh` or updated test suite.
  - Render `executable_host-facts.tmpl` across mock facts.
- **Verification:** CI test suite passes cleanly.

### U5. Update Documentation and Instruction Templates

- **Goal:** Remove all mentions of `packages.yaml` from repository documentation.
- **Requirements:** R7
- **Files:**
  - `.chezmoitemplates/agents-instructions.tmpl`
  - `AGENTS.md`
- **Approach:** Remove `packages.yaml` from the single source of truth table and documentation notes.
- **Test Scenarios:**
  - Check `git grep "packages.yaml"` across the repository to ensure no remaining references exist outside archived historical plan docs.
- **Verification:** `git grep -i "packages\.yaml" -- ':!docs/plans' ':!docs/solutions'` returns zero matches.

---

## Verification Contract

| Check | Command | Target | Expected Outcome |
|---|---|---|---|
| No packages.yaml references | `git grep -i "packages\.yaml" -- ':!docs/plans' ':!docs/solutions'` | Repository | 0 matches |
| No .packages template lookups | `git grep -E '\.packages\b' -- ':!docs/plans' ':!docs/solutions'` | Repository | 0 matches |
| Template rendering (Fedora) | Isolated scratch chezmoi execute-template on `20-base`, `30-components` | Templates | Render exits 0 |
| Template rendering (Ubuntu) | Isolated scratch chezmoi execute-template on `20-base`, `30-components`, `20-linux-ubuntu` with Ubuntu override data | Templates | Render exits 0 |
| Template rendering (Darwin) | Isolated scratch chezmoi execute-template on `20-darwin`, `30-components` with Darwin override data | Templates | Render exits 0 |
| Shellcheck | `shellcheck` on rendered bash scripts | Scripts | No errors |
| CI Test Suite | Run existing `.ci/*.sh` tests | CI scripts | All tests pass |
| Git cleanliness | `git diff --check` | Working tree | Clean diff |

---

## Definition of Done

- All 5 Implementation Units (U1–U5) are fully implemented and verified.
- `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl` are removed.
- All scripts in `20-base/`, `20-darwin/`, `20-linux-ubuntu/`, and `30-components/` render and pass shellcheck without reading `.packages`.
- CI tests in `.ci/` pass cleanly without `packages.yaml`.
- `AGENTS.md` and `.chezmoitemplates/agents-instructions.tmpl` reflect the decentralized package architecture.
- `git diff --check` is clean.
