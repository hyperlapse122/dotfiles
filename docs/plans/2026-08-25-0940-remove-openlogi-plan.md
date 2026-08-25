---
title: Remove OpenLogi - Plan
type: refactor
date: 2026-08-25
topic: remove-openlogi
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Remove OpenLogi - Plan

## Goal Capsule

- **Objective:** OpenLogi is completely removed from the dotfiles repository across all managed platforms (Fedora, macOS), leaving no residual scripts, release locks, package definitions, or CI suites, and mxm4-haptic operates standalone without HID++ co-tenancy assumptions.
- **Means:** Excise OpenLogi package entries, release-lock registry items, installation scripts, config assertion logic, and CI test harnesses; update documentation and decouple mxm4-haptic comments (KTD1, KTD2, KTD3, KTD4, KTD5).
- **Product authority:** The Product Contract Key Decisions (complete removal over replacement/rollback, standalone mxm4-haptic, no GUI/gesture manager) outrank every planning choice below.
- **Stop conditions:** none.
- **Execution profile:** `ce-work` under `lfg`; implementation lands in atomic commits on the working branch.

---

## Product Contract

### Summary

Remove OpenLogi completely from the dotfiles — packages, release locks, configuration scripts, CI tests, and documentation — without introducing a replacement Logitech manager.
mxm4-haptic remains the sole Logitech component in the repository, operating standalone.

### Problem Frame

OpenLogi was previously introduced to unify cross-platform Logitech device management across Fedora and macOS.
The user has decided to eliminate OpenLogi entirely, removing the background agent daemon, configuration reconciliation overhead, and multi-platform packaging complexity without restoring Solaar or Logi Options+.

### Key Decisions

- **Complete removal over replacement or rollback** (session-settled: user-directed — chosen over rolling back to Solaar/Options+ or adopting another tool: complete elimination of Logitech GUI managers). Governs R1, R2, R3, R4, R5, R6.
- **mxm4-haptic kept standalone** (session-settled: user-directed — chosen over removing the entire Logitech stack: 햅틱 피드백 스택은 유지하되 OpenLogi 공존 주석 및 참조만 정리). Governs R7, R8.
- **Clean removal across all dotfiles surfaces** (session-settled: user-approved — chosen over partial disablement: package manifests, release-lock registry, assertion scripts, CI test suites, and documentation are all excised). Governs R1, R2, R3, R4, R5, R6.

### Requirements

**Package and release lock removal**

- R1. Remove OpenLogi from the `logitechGestures` capability in `.chezmoidata/packages.yaml` (releaseLock RPM on Fedora, Homebrew cask on macOS), retiring or removing the capability entry cleanly.
- R2. Remove the `openlogi` tool specification from `packages/release-lock/src/registry.ts` and regenerate `.chezmoidata/releases.json` using the release-lock CLI so that no OpenLogi RPM artifacts are tracked; update release-lock test fixtures (`github.test.ts`, `registry.test.ts`).
- R3. Remove the OpenLogi RPM download, checksum verification, and installation block from `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`.

**Configuration and service removal**

- R4. Delete `.chezmoidata/openlogi.yaml` and the configuration assertion script `.chezmoiscripts/70-agents/run_after_config-openlogi.sh.tmpl`.

**CI and test removal**

- R5. Delete `.ci/test-openlogi-config.sh`, remove its test step from `.github/workflows/ci.yml`, and remove the template rendering assertions for `run_after_config-openlogi.sh.tmpl` from `.github/workflows/render-dotfiles.yml`.

**Documentation and reference updates**

- R6. Remove or update all OpenLogi references in `AGENTS.md` (script-tree table, data table), `.chezmoidata/{kde,networking,system}.yaml`, and `.chezmoiscripts/90-src/`.

**mxm4-haptic decoupling**

- R7. Update comments, doc-comments, and documentation in `crates/mxm4-haptic/` (`Cargo.toml`, `src/lib.rs`, `src/bin/mxm4-haptic.rs`, `src/bin/mxm4-hapticd.rs`) to remove OpenLogi co-tenancy and lease-pool references, framing `mxm4-haptic` as a standalone HID++ client/daemon.
- R8. `mxm4-haptic` compilation and runtime behavior remain fully functional without external daemon dependencies.

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R4.**
  - **Given** a managed host running `chezmoi apply`,
  - **When** the apply runs,
  - **Then** no OpenLogi RPM is downloaded or installed, `run_after_config-openlogi.sh.tmpl` does not execute, and `openlogi.yaml` is not read.
- AE2. **Covers R2, R5.**
  - **When** `bun test` in `packages/release-lock` and CI workflows (`ci.yml`, `render-dotfiles.yml`) run,
  - **Then** all tests pass with zero OpenLogi references or test failures.
- AE3. **Covers R7, R8.**
  - **When** `cargo check --workspace` and `cargo test --workspace` run,
  - **Then** `mxm4-haptic` builds cleanly and all unit/integration tests pass.

### Success Criteria

- Zero OpenLogi code, scripts, configuration, or release-lock artifacts remain in the repository.
- `chezmoi apply` and template rendering succeed cleanly without errors across Fedora, macOS, containers, and test fixtures.
- `mxm4-haptic` continues to build and function as a standalone daemon.

### Scope Boundaries

- Re-introducing Solaar, Logi Options+, or another Logitech manager — excluded; the repository will not manage a Logitech GUI tool.
- Automated operator decommission scripts for already-installed hosts — excluded; per repository policy, host uninstallation (`dnf remove openlogi`, `brew uninstall --zap openlogi`, stopping user services) is operator-owned or documented in decommissioning notes.
- Functional changes to `mxm4-haptic` logic — excluded; comments and documentation are updated without altering core haptic waveforms or daemon event handling.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Retire the `logitechGestures` capability and clean release-lock registry** (session-settled: user-directed — chosen over keeping stub entries: delete `logitechGestures` from `.chezmoidata/packages.yaml` and `openlogi` from `packages/release-lock/src/registry.ts`, regenerating `.chezmoidata/releases.json` via release-lock CLI). Governs R1, R2; lands in U1.
- KTD2. **Excise Fedora installer and configuration assertion scripts directly** (session-settled: user-approved — delete `.chezmoidata/openlogi.yaml` and `.chezmoiscripts/70-agents/run_after_config-openlogi.sh.tmpl`, and remove lines 333-352 in `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`). Governs R3, R4; lands in U2.
- KTD3. **Remove test-openlogi-config.sh and CI render assertions** (delete `.ci/test-openlogi-config.sh`, remove workflow job in `.github/workflows/ci.yml`, and remove rendering test steps in `.github/workflows/render-dotfiles.yml`). Governs R5; lands in U3.
- KTD4. **Decouple mxm4-haptic documentation without modifying Rust logic** (session-settled: user-directed — update doc comments and crate metadata in `crates/mxm4-haptic/` to describe standalone operation, removing references to `openlogi-agent` and lease pools; code logic remains intact). Governs R7, R8; lands in U4.
- KTD5. **Clean documentation and repository references** (update `AGENTS.md` tables, `.chezmoidata/{kde,networking,system}.yaml`, and `.chezmoiscripts/90-src/` comments). Governs R6; lands in U5.

### Assumptions

- A1. Removing `logitechGestures` capability causes no issues for other package capabilities in `.chezmoidata/packages.yaml`.
- A2. Existing hosts already running `openlogi-agent` will have the service stopped and package removed manually by the operator (or when running decommission steps).
- A3. `mxm4-haptic` daemon and client have no compile-time or runtime dependency on `openlogi-agent` or OpenLogi RPMs.

---

## Implementation Units

### U1. Release-lock registry and capability removal

- **Goal:** Remove OpenLogi from the release-lock registry, regenerate `releases.json`, update release-lock tests, and remove `logitechGestures` capability.
- **Requirements:** R1, R2
- **Dependencies:** none
- **Files:** `packages/release-lock/src/registry.ts`, `packages/release-lock/test/github.test.ts`, `packages/release-lock/test/registry.test.ts`, `.chezmoidata/releases.json`, `.chezmoidata/packages.yaml`
- **Approach:**
  1. Remove `openlogi` entry from `packages/release-lock/src/registry.ts`.
  2. Remove openlogi test cases from `packages/release-lock/test/github.test.ts` and `packages/release-lock/test/registry.test.ts`.
  3. Run `packages/release-lock/src/cli.ts --out` or edit `releases.json` to eliminate the `openlogi` key.
  4. Remove the `logitechGestures` capability entry from `.chezmoidata/packages.yaml`.
- **Patterns to follow:** `packages/release-lock` conventions and `packages.yaml` capability schema.
- **Test scenarios:**
  - `bun test` in `packages/release-lock`: all tests pass with zero failures.
  - Verification that `.chezmoidata/releases.json` contains no `openlogi` block.
- **Verification:** `bun test` passes in `packages/release-lock`.

### U2. Host provisioning and configuration script removal

- **Goal:** Remove the Fedora direct-RPM download/install block, delete the OpenLogi YAML manifest and assertion script.
- **Requirements:** R3, R4
- **Dependencies:** U1
- **Files:** `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`, `.chezmoidata/openlogi.yaml` (deleted), `.chezmoiscripts/70-agents/run_after_config-openlogi.sh.tmpl` (deleted)
- **Approach:**
  1. Delete lines 333-352 in `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`.
  2. Delete `.chezmoidata/openlogi.yaml`.
  3. Delete `.chezmoiscripts/70-agents/run_after_config-openlogi.sh.tmpl`.
- **Patterns to follow:** Chezmoi script and data layout rules.
- **Test scenarios:**
  - Render `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` via `chezmoi execute-template`: renders cleanly without OpenLogi variables or RPM download logic.
  - Verify deleted files no longer exist.
- **Verification:** Template rendering passes cleanly.

### U3. CI workflow and test harness cleanup

- **Goal:** Delete `.ci/test-openlogi-config.sh` and remove its invocations from CI workflows.
- **Requirements:** R5
- **Dependencies:** U2
- **Files:** `.ci/test-openlogi-config.sh` (deleted), `.github/workflows/ci.yml`, `.github/workflows/render-dotfiles.yml`
- **Approach:**
  1. Delete `.ci/test-openlogi-config.sh`.
  2. Remove the step running `test-openlogi-config.sh` from `.github/workflows/ci.yml`.
  3. Remove the rendering test step for `run_after_config-openlogi.sh.tmpl` from `.github/workflows/render-dotfiles.yml`.
- **Patterns to follow:** CI workflow job structure.
- **Test scenarios:**
  - Run `.ci/check-skip-declarations.sh` to ensure no orphaned script references.
  - Verify `.github/workflows/ci.yml` and `render-dotfiles.yml` have no references to `test-openlogi-config.sh` or `run_after_config-openlogi.sh.tmpl`.
- **Verification:** Skip declaration checks pass and CI workflows parse cleanly.

### U4. mxm4-haptic documentation decoupling

- **Goal:** Update doc-comments and crate metadata in `crates/mxm4-haptic` to describe standalone operation.
- **Requirements:** R7, R8
- **Dependencies:** none
- **Files:** `crates/mxm4-haptic/Cargo.toml`, `crates/mxm4-haptic/src/lib.rs`, `crates/mxm4-haptic/src/bin/mxm4-haptic.rs`, `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs`
- **Approach:**
  1. In `crates/mxm4-haptic/Cargo.toml`, update bin descriptions to remove references to `openlogi-agent`.
  2. In `crates/mxm4-haptic/src/lib.rs`, update doc comments referencing OpenLogi's lease pool to reflect standalone HID++ operation.
  3. In `crates/mxm4-haptic/src/bin/mxm4-haptic.rs` and `mxm4-hapticd.rs`, update comments referencing `openlogi-agent`.
- **Patterns to follow:** Rust documentation conventions in `crates/mxm4-haptic/`.
- **Test scenarios:**
  - `cargo check --workspace` and `cargo test --workspace` pass cleanly.
- **Verification:** `cargo test -p mxm4-haptic` succeeds.

### U5. Documentation and repository references cleanup

- **Goal:** Remove OpenLogi references from `AGENTS.md` and dotfiles YAML comments.
- **Requirements:** R6
- **Dependencies:** U1, U2, U3, U4
- **Files:** `AGENTS.md`, `.chezmoidata/kde.yaml`, `.chezmoidata/networking.yaml`, `.chezmoidata/system.yaml`, `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`
- **Approach:**
  1. In `AGENTS.md`, update the `70-agents` script-tree row and `.chezmoidata/openlogi.yaml` data row.
  2. In `.chezmoidata/kde.yaml` and `.chezmoidata/networking.yaml`, remove references to `openlogi.yaml`.
  3. In `.chezmoidata/system.yaml`, update the comment referencing OpenLogi udev rules.
  4. In `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`, update the comment referencing `config-openlogi`.
- **Patterns to follow:** `AGENTS.md` format and dotfiles commenting style.
- **Test scenarios:**
  - `git grep -i openlogi` over source files (excluding `docs/plans/`) returns zero matches.
- **Verification:** Repository search confirms no residual OpenLogi references outside historical plans.

---

## Verification Contract

- **Release-lock tests:** `cd packages/release-lock && bun test`
- **Rust workspace tests:** `cargo test --workspace`
- **Chezmoi template execution:**
  ```sh
  scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
  mkdir -p "$scratch/bin" "$scratch/target"
  : > "$scratch/empty.toml"
  printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
  chmod 700 "$scratch/bin/op"
  env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl
  ```
- **Skip declaration validation:** `.ci/check-skip-declarations.sh`
- **Cleanliness audit:** `git grep -i openlogi -- ':!docs/plans'` returns zero matches.

---

## Definition of Done

- Every implementation unit (U1 through U5) is completed and verified.
- `bun test` in `packages/release-lock` passes.
- `cargo test --workspace` passes.
- Template rendering and skip declaration checks pass.
- No OpenLogi references remain in active source code, configuration data, scripts, tests, or instructions.
