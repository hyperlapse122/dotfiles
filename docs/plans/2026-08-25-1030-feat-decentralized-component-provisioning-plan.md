---
title: Decentralize Dotfiles Provisioning into Vertical Component Scripts - Plan
type: feat
date: 2026-08-25
topic: decentralized-component-provisioning
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Decentralize Dotfiles Provisioning into Vertical Component Scripts - Plan

## Goal Capsule

- **Objective:** Provisioning logic is modularized into vertical component scripts (handling their own packages, configs, and services) so that components can be enabled, disabled (prospectively), and gated independently without entangling unrelated systems.
- **Means:** Extract all non-essential tools and configurations from horizontal stages (`20-linux-fedora`, `30-linux`) into isolated component scripts located in a new `30-components` phase, separated into OS-specific directories and gated via `.chezmoiignore` using explicit hardware and feature flags.
- **Product Authority:** This requirements-only unified plan and the session-settled isolation decisions in Key Decisions.
- **Open Blockers:** none.

---

## Product Contract

### Summary
Refactor the dotfiles provisioning architecture from a monolithic horizontal structure (all packages, then all configs) into a fully decentralized vertical structure. A minimal `20-base` phase will bootstrap essential system tools (e.g., git, curl, zsh), itself split by OS. All other logical features (NVIDIA, Podman, Tailscale, etc.) move to a new `30-components` phase where individual scripts self-manage their package installations, configuration, and service states. OS differences are handled via strict directory separation (`fedora/`, `ubuntu/`) and `.chezmoiignore` gating, eliminating in-script conditional branching entirely. Enablement relies on explicit declarative flags and hardware facts evaluated at render time, and disabling a component prospectively prevents rendering without performing active teardown.
### Problem Frame
Currently, dotfiles provisioning uses a horizontal architecture where `.chezmoidata/packages.yaml` acts as a monolithic package registry, and stages like `.chezmoiscripts/20-linux-fedora` install all packages before `.chezmoiscripts/30-linux` deploys all configurations. This tightly couples unrelated systems and creates massive scripts with complex in-script branching (e.g., `if nvidia...`) to handle hardware and OS variations. A recent experiment isolating `keyd` into its own vertical script proved successful, and this effort expands that pattern globally.

### Key Decisions
- **Decentralize package and configuration data.** (session-settled: user-directed — chosen over maintaining packages.yaml as a single source of truth). Governs R3.
- **Separate minimal base from component provisioning.** (session-settled: user-directed — chosen over flattening all phases). Governs R1, R2.
- **Use `.chezmoiignore` template logic for OS, hardware, and feature gating.** (session-settled: user-directed — chosen over script-level exit codes for broad platform filtering). Governs R5, R6, R7.
- **Disabling is prospective only.** (inferred — active deprovisioning is impossible for scripts excluded by `.chezmoiignore`). Governs R8.
- **Sacrifice bulk package installation speed for script isolation.** By invoking DNF/APT per component script, overall execution time increases, but component modularity and debuggability are perfectly preserved.

### Requirements

#### Phase Restructuring
- R1. Base system bootstrapping (git, curl, zsh, and core networking) remains in a consolidated base phase (e.g., `20-base`). To comply with the no-branching rule, the base phase itself is also split into OS-specific subdirectories (e.g., `20-base/fedora/` and `20-base/ubuntu/`).
- R2. All optional, hardware-dependent, or feature-specific tools (NVIDIA, Podman, KDE, Tailscale, etc.) move to a new dedicated execution phase (e.g., `30-components`).

#### Component Decentralization
- R3. Component scripts internally declare and execute their own package installation commands (COPRs, `dnf install`, `apt install`), generate their configurations, and manage their systemd services. The central `packages.yaml` is trimmed to only serve the base phase or removed entirely if no longer needed.

#### OS and Hardware Gating
- R4. Component scripts must contain no in-script branching for OS differences (e.g., no `if ubuntu then apt else dnf` logic).
- R5. OS implementations are separated into dedicated directories (e.g., `30-components/fedora/10-nvidia.sh` and `30-components/ubuntu/10-nvidia.sh`). Entire OS-specific or distro-specific subtrees are gated out from rendering and execution using template conditionals in the repository root's `.chezmoiignore`. Unrecognized or missing OS values must fail-closed, excluding all OS-specific directories by default.
- R6. Hardware-dependent components (like NVIDIA) require a two-dimensional gate in `.chezmoiignore`: the OS directory must match the host, AND the hardware fact (e.g., `has_nvidia_gpu`) must be true.

#### Feature Selection and Lifecycle
- R7. Optional components are gated by explicit selection booleans (e.g., `.chezmoidata/features.yaml` or host-specific facts). A user enables a feature declaratively, and `.chezmoiignore` includes the relevant component directory based on this flag.
- R8. "Disabling" a component means gating it out of future runs (prospective exclusion). Because an ignored script cannot execute teardown logic, active deprovisioning (removing previously installed packages or files) is out of scope for this architecture.

### Scope Boundaries
- **Deferred for later**
  - Migration of existing unmanaged custom tools not currently in the dotfiles horizontal scripts.
- **Outside this product's identity**
  - Maintaining a centralized package list (`packages.yaml`) for optional components. Component autonomy takes precedence.
  - Active deprovisioning (teardown) of components that have been disabled.

---

## Planning Contract

### Key Technical Decisions
- KTD1. (session-settled: user-directed — chosen over maintaining packages.yaml as a single source of truth). Component scripts handle their own package installations using direct `dnf`/`apt` calls. Governs R3.
- KTD2. (session-settled: user-directed — chosen over flattening all phases). The phase structure splits into `20-base` and `30-components`. Governs R1, R2.
- KTD3. (session-settled: user-directed — chosen over in-script branching or helper abstractions). OS implementations are strictly separated into dedicated directories (e.g., `30-components/fedora/` and `30-components/ubuntu/`). Governs R4, R5.
- KTD4. (session-settled: user-directed — chosen over script-level exit codes for broad platform filtering). `.chezmoiignore` template logic handles OS, hardware, and feature gating. Unrecognized OS values fail-closed. Governs R5, R6, R7.
- KTD5. (inferred — active deprovisioning is impossible for scripts excluded by `.chezmoiignore`). Disabling a component is prospective only. Governs R8.

---

## Implementation Units

### U1. Split Base Phase by OS
- **Goal:** Split existing base package installations into OS-specific subdirectories under `20-base` (e.g., `20-base/fedora`, `20-base/ubuntu`) while retaining only core tools (git, curl, zsh, core network).
- **Requirements:** R1
- **Dependencies:** none
- **Files:** 
  - `.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`
  - `.chezmoiscripts/20-base/ubuntu/run_onchange_before_base.sh.tmpl`
- **Approach:** Create the new `20-base` directory structure. Move the essential bootstrapping logic from the old `20-linux-fedora` script into the new OS-specific base scripts. Remove optional components from this phase.
- **Test scenarios:**
  - Test expectation: none -- purely refactoring base tool installation without behavioral changes.
- **Verification:** `chezmoi apply` successfully installs core tools on a fresh host without executing component scripts.

### U2. Establish .chezmoiignore Gating Logic
- **Goal:** Add template logic to `.chezmoiignore` to gate OS directories (`fedora/`, `ubuntu/`), hardware features (e.g. `has_nvidia_gpu`), and component selection flags.
- **Requirements:** R4, R5, R6, R7, R8
- **Dependencies:** U1
- **Files:** 
  - `.chezmoiignore`
  - `.chezmoidata/features.yaml`
- **Approach:** Define explicit feature flags in `.chezmoidata/features.yaml`. Update `.chezmoiignore` to read `chezmoi.os` and the hardware/feature facts, fail-closing unmapped operating systems. Write strict exclusion rules for `30-components/fedora/**` on Ubuntu, and vice versa, plus component-specific exclusion rules based on the feature flags.
- **Test scenarios:**
  - Unmapped OS: all `30-components` OS directories are ignored.
  - Ubuntu OS: `fedora` directories are ignored, `ubuntu` directories are processed.
  - Feature disabled: component directory is ignored regardless of OS.
- **Verification:** `chezmoi managed` shows only the correct OS directories and enabled features.

### U3. Extract Optional Components into Vertical Scripts
- **Goal:** Move optional tools (NVIDIA, Podman, Tailscale, etc.) out of horizontal phases into their respective OS directories under `30-components` (e.g., `30-components/fedora/10-nvidia.sh`). Trim `packages.yaml`.
- **Requirements:** R2, R3
- **Dependencies:** U2
- **Files:** 
  - `.chezmoiscripts/30-components/fedora/10-nvidia.sh.tmpl`
  - `.chezmoiscripts/30-components/ubuntu/10-nvidia.sh.tmpl`
  - `.chezmoidata/packages.yaml`
  - `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`
- **Approach:** For each feature, create the vertical script in the respective OS directory. The script must contain its own package manager commands (e.g., `dnf install`, `apt install`), generate its config files, and enable its services. Remove the corresponding entries from `.chezmoidata/packages.yaml` and the old monolithic scripts. Delete the old horizontal monolithic script once fully extracted.
- **Test scenarios:**
  - Component enabled and hardware matched: script executes and installs packages.
  - Component disabled or hardware mismatched: script is ignored by chezmoi and does not execute.
- **Verification:** `chezmoi apply` triggers individual component scripts and installs packages directly.

---

## Verification Contract

| Command / Action | Applicability | Covered Units | Done Signal |
|---|---|---|---|
| `chezmoi managed` | All hosts | U2 | Only directories matching the host OS and enabled features are listed. |
| `chezmoi apply` | Fedora, Ubuntu test envs | U1, U3 | Component scripts run individually. No in-script branching occurs. DNF/APT run per component. |

---

## Definition of Done

- [ ] Base phase (`20-base`) is isolated and split into dedicated OS directories.
- [ ] Optional components are fully encapsulated in vertical scripts under `30-components/fedora` and `30-components/ubuntu`.
- [ ] `.chezmoiignore` successfully gates by OS, hardware, and feature flags, failing closed on unmapped OS types.
- [ ] Old horizontal monolithic package/config scripts are removed.
- [ ] `packages.yaml` is trimmed down to minimal shared data or removed.