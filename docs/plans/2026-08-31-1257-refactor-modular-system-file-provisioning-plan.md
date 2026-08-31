---
title: Modular Subsystem Provisioning for Linux System Files - Plan
type: refactor
date: 2026-08-31
topic: modular-system-file-provisioning
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Modular Subsystem Provisioning for Linux System Files - Plan

## Goal Capsule

- **Objective:** Root-owned `/etc` system configuration is provisioned through isolated, subsystem-specific scripts so that changing configuration for one component only deploys and reloads that specific component without running unrelated system tasks or dropping live services.
- **Means:** Split the monolithic `install-system-10-files` script into modular `run_onchange_after_` scripts per subsystem (bluetooth, udev, sysctl, sudoers, desktop/gdm, hardware/thinkpad), convert `keyd` to `run_onchange_after_`, structure `.chezmoidata/system.yaml` by subsystem, and use granular file fingerprints to leverage Chezmoi's native change tracking (KTD1, KTD2).
- **Product Authority:** Product Contract and session-settled isolation decisions in Key Decisions.
- **Open Blockers:** none.

---

## Product Contract

### Summary
Refactor the dotfiles Linux system file installation mechanism from a single monolithic script (`install-system-10-files`) that deploys all `/etc` files in one batch into discrete, subsystem-scoped `run_onchange_after_` scripts. Each subsystem script embeds content fingerprints for only its relevant files in `system/linux/etc/` and `.chezmoidata/system.yaml`, executing and triggering service reloads (e.g. `systemctl restart bluetooth`, `udevadm control --reload`, `dconf update`) strictly when its managed configuration changes.

### Problem Frame
Currently, `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl` hashes the entire `system/linux/etc/**` tree. When any single `/etc` file is modified (such as a udev rule or a sysctl drop-in), Chezmoi re-runs the entire monolithic script. This re-executes file installs across all directories, runs syntax checks, and checks if bluetooth changed. Furthermore, `run_after_keyd.sh.tmpl` runs unconditionally on every `chezmoi apply` regardless of changes. Splitting the installer into granular subsystem scripts with focused fingerprints allows Chezmoi's built-in state engine to skip unchanged subsystems, reducing unnecessary elevated operations and avoiding accidental side effects like dropping active Bluetooth connections.

### Key Decisions
- **Subsystem-specific onchange scripts.** (session-settled: user-directed — chosen over monolithic engine with internal runtime caching: enables native Chezmoi state tracking and isolates service reload boundaries). Governs R1, R2, R4.
- **Subsystem-structured system.yaml manifest.** (session-settled: user-directed — chosen over splitting into multiple data files or retaining flat arrays: keeps single source of truth while organizing overrides and removals by subsystem). Governs R3.
- **Convert keyd to onchange execution.** (session-settled: user-approved — chosen over unconditional run_after: prevents redundant hardware polling and sudo operations when keyboard declarations have not changed). Governs R6.

### Requirements

#### Subsystem Script Decomposition
- R1. The monolithic script `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl` is decomposed into focused subsystem scripts within `.chezmoiscripts/30-linux/` (e.g., `run_onchange_after_install-system-bluetooth.sh.tmpl`, `run_onchange_after_install-system-udev.sh.tmpl`, `run_onchange_after_install-system-sysctl.sh.tmpl`, `run_onchange_after_install-system-sudoers.sh.tmpl`, `run_onchange_after_install-system-desktop.sh.tmpl`, and `run_onchange_after_install-system-hardware.sh.tmpl`).
- R2. Each subsystem script owns the installation, file validation, host gate checking, orphan cleanup, and service reloading strictly for its assigned domain.
- R3. `.chezmoidata/system.yaml` organizes configuration overrides and removed-path lists by subsystem under `system.linux.<subsystem>` while preserving schema validation with `facts-validate.tmpl`.

#### Granular Fingerprinting and State Tracking
- R4. Each subsystem script includes a comment-only fingerprint block via `fingerprint.tmpl` targeting only the files belonging to that subsystem in `system/linux/etc/` and relevant section data from `system.yaml`.
- R5. Modifying a file in one subsystem (e.g., `system/linux/etc/udev/rules.d/`) only triggers the corresponding subsystem script on `chezmoi apply` and leaves other subsystem scripts in an untouched skip/cached state.

#### Keyd and Service Reload Hygiene
- R6. `run_after_keyd.sh.tmpl` is converted to `run_onchange_after_keyd.sh.tmpl`, fingerprinting declared keyboard hardware in `.chezmoidata/system.yaml` and `system/linux/etc/libinput/local-overrides.quirks` so it only executes when configuration or hardware declarations change.
- R7. Service reloads and daemon restarts (such as `systemctl restart bluetooth`, `udevadm control --reload`, `sysctl --system`, `dconf update`, `systemctl daemon-reload`) are localized to their respective subsystem scripts and only execute when that subsystem's configuration is modified.
- R8. Distro and hardware gates (`thinkpad`, `gdm`, `sddmBreeze`, `vm`) remain enforced via `facts-gate.sh.tmpl` and early-exit skip declarations (`skip.sh.tmpl`) within each respective subsystem script.

### Key Flows

- F1. Single-subsystem configuration edit:
  - **Trigger:** Developer modifies `system/linux/etc/bluetooth/main.conf`.
  - **Actors:** Operator running `chezmoi apply`.
  - **Steps:** Chezmoi evaluates rendered script fingerprints; detects change only in `install-system-bluetooth`; runs only that script under sudo; restarts `bluetooth.service`; skips udev, sysctl, sudoers, keyd, and network scripts.
  - **Outcome:** Bluetooth configuration updated with zero disruption to udev, firewall, or display manager services.
  - **Covered by:** R1, R4, R5, R7.

- F2. Unchanged apply run:
  - **Trigger:** Operator runs `chezmoi apply` without modifying any `system/linux/etc/` files or hardware facts.
  - **Actors:** Operator.
  - **Steps:** Chezmoi compares fingerprints for all `run_onchange_` scripts against stored state; finds all identical.
  - **Outcome:** All system file scripts skip execution immediately with zero sudo invocations.
  - **Covered by:** R4, R5, R6.

### Acceptance Examples

- AE1. Modifying a udev rule:
  - **Given:** A host with up-to-date chezmoi state.
  - **When:** An edit is made to `system/linux/etc/udev/rules.d/99-btd700.rules` and `chezmoi apply` is executed.
  - **Then:** Only `install-system-udev` executes, deploying the file and running `udevadm control --reload`. `install-system-bluetooth`, `install-system-sysctl`, `keyd`, and other scripts are not executed.
  - **Covers:** R1, R4, R5, R7.

- AE2. ThinkPad module config on non-ThinkPad host:
  - **Given:** A non-ThinkPad machine (`FACT_THINKPAD=0`).
  - **When:** `chezmoi apply` runs `install-system-hardware`.
  - **Then:** The script records a clean skip declaration (`not_applicable` on `thinkpad-absent`) without executing `modprobe thinkpad_acpi`.
  - **Covers:** R2, R8.

- AE3. Unchanged keyd state:
  - **Given:** Keyd is already configured and hardware ID declarations are unchanged in `system.yaml`.
  - **When:** `chezmoi apply` is executed.
  - **Then:** `run_onchange_after_keyd.sh.tmpl` is skipped by Chezmoi without performing `/proc/bus/input/devices` scans or restarting `keyd.service`.
  - **Covers:** R6.

### Scope Boundaries

#### Deferred for later
- Refactoring `00-tools`, `10-auth`, `20-linux-fedora`, or desktop theme scripts (`50-linux-*`).
- Migration of custom tools not currently in `system/linux/etc/`.

#### Outside this product's identity
- Managing user-scoped `$HOME` dotfiles through system scripts.
- macOS system-level configuration (macOS configurations are user-scoped in `Library/`).
- Replacing Chezmoi's built-in `run_onchange_` hashing mechanism with custom external daemon state.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Subsystem-scoped script prefixing.** Name scripts with ordered numeric prefixes under `.chezmoiscripts/30-linux/`:
  - `run_onchange_after_install-system-10-desktop.sh.tmpl` (locale, sddm, gdm dconf)
  - `run_onchange_after_install-system-12-sudoers.sh.tmpl` (sudoers drop-ins)
  - `run_onchange_after_install-system-14-sysctl.sh.tmpl` (sysctl drop-ins)
  - `run_onchange_after_install-system-16-udev.sh.tmpl` (udev rules, libinput quirks)
  - `run_onchange_after_install-system-18-hardware.sh.tmpl` (kernel modules, ThinkPad config)
  - `run_onchange_after_install-system-20-bluetooth.sh.tmpl` (bluez config, autosuspend)
  - `run_onchange_after_install-system-22-host.sh.tmpl` (renamed from `20-host` to retain ordering before network)
  - `run_onchange_after_install-system-24-keyd.sh.tmpl` (converted from `run_after_keyd.sh.tmpl`)
  - `run_onchange_after_install-system-30-network.sh.tmpl` (firewalld, resolv.conf, NetworkManager)
  Governs R1, R2, R7.

- KTD2. **Explicit per-script fingerprint globbing.** Each script invokes `includeTemplate "fingerprint.tmpl"` referencing its exact source files (e.g. `system/linux/etc/bluetooth/**` and `system/linux/etc/modprobe.d/bluetooth-no-autosuspend.conf` for bluetooth). Governs R4, R5.

- KTD3. **Subsystem grouping in `.chezmoidata/system.yaml`.** Structure `system.linux` with explicit subsystem blocks (`bluetooth`, `udev`, `sysctl`, `sudoers`, `desktop`, `hardware`, `keyd`, `general_removed`), each holding their specific `overrides` and `removed` arrays. Governs R3.

- KTD4. **Preserve skip declaration contracts and test suite.** Every script early exit uses `.chezmoitemplates/skip.sh.tmpl` (`skip_here`, `not_applicable`, `skip_step`), verified by `.ci/check-skip-declarations.sh`. Governs R8.

---

## Implementation Units

### U1. Restructure `.chezmoidata/system.yaml` by Subsystem
- **Goal:** Group overrides, gates, modes, and removed lists by subsystem in `.chezmoidata/system.yaml` while ensuring all gates validate against `.chezmoidata/facts.yaml`.
- **Requirements:** R3, R8
- **Files:**
  - `.chezmoidata/system.yaml`
- **Approach:**
  - Refactor `system.linux` into maps: `desktop`, `sudoers`, `sysctl`, `udev`, `hardware`, `bluetooth`, `keyd`, and `removed`.
  - Maintain all existing gate identifiers (`thinkpad`, `vm`, `sddmBreeze`, `gdm`, `fprintdPam`) and modes (`0440` for sudoers).
- **Verification:** Run `facts-validate.tmpl` via test render; verify syntax and gate schema.

### U2. Decompose `install-system-10-files` into Modular Subsystem Scripts
- **Goal:** Replace monolithic `install-system-10-files` with discrete subsystem scripts in `.chezmoiscripts/30-linux/`.
- **Requirements:** R1, R2, R4, R5, R7, R8
- **Files:**
  - Delete `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-12-sudoers.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-14-sysctl.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-18-hardware.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-20-bluetooth.sh.tmpl`
  - Rename/Update `.chezmoiscripts/30-linux/run_onchange_after_install-system-20-host.sh.tmpl` -> `run_onchange_after_install-system-22-host.sh.tmpl`
- **Approach:**
  - Each script includes `sudo-usable` capability fingerprint, `headless-guard.sh.tmpl`, `shared-host-guard.sh.tmpl`, `sudo-skip-guard.sh.tmpl`, and its specific file content fingerprint.
  - Inlines its specific service reload action (`dconf update`, `sysctl --system`, `udevadm control --reload`, `modprobe thinkpad_acpi`, `systemctl restart bluetooth`).
  - Implements required skip declarations (`skip.sh.tmpl`).
- **Verification:** Render each script through `chezmoi execute-template` in scratch environment.

### U3. Convert Keyd to `run_onchange_`
- **Goal:** Convert `run_after_keyd.sh.tmpl` to `run_onchange_after_install-system-24-keyd.sh.tmpl` so keyd hardware check and installation only runs on change.
- **Requirements:** R6
- **Files:**
  - Delete `.chezmoiscripts/30-linux/run_after_keyd.sh.tmpl`
  - Create `.chezmoiscripts/30-linux/run_onchange_after_install-system-24-keyd.sh.tmpl`
- **Approach:**
  - Include file fingerprint for `system/linux/etc/libinput/local-overrides.quirks` and value fingerprint for declared keyd hardware IDs in `.chezmoidata/system.yaml`.
  - Retain hardware presence probe and service enable/restart logic.
- **Verification:** Test rendering with `chezmoi execute-template`; check skip declarations.

### U4. Update Documentation and Reference Links
- **Goal:** Update `system/README.md` and repository `AGENTS.md` to document the new subsystem script structure and manifest layout.
- **Requirements:** R1, R3
- **Files:**
  - `system/README.md`
  - `.chezmoitemplates/agents-instructions.tmpl` (if references exist)
- **Approach:**
  - Document the granular script layout (`10-desktop` through `30-network`) in `system/README.md`.
  - Ensure all documentation adheres to clear and concise ASD-STE100 guidelines.
- **Verification:** Review docs for consistency and accuracy against new file layout.

### U5. Execute Full Repository Validation
- **Goal:** Run CI skip declaration check, render verification across all modified scripts, and ensure zero regressions.
- **Requirements:** R1-R8
- **Files:**
  - `.ci/check-skip-declarations.sh`
- **Approach:**
  - Execute `.ci/check-skip-declarations.sh`.
  - Run scratch chezmoi template execution for all new scripts.
  - Verify `git diff --check`.
- **Verification:** All tests pass with zero errors or warnings.

---

## Verification Contract

- **Automated Checks:**
  - `.ci/check-skip-declarations.sh` — verifies all early exits adhere to `.chezmoitemplates/skip.sh.tmpl`.
  - Scratch chezmoi rendering:
    ```sh
    scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
    mkdir -p "$scratch/bin" "$scratch/target"
    : > "$scratch/empty.toml"
    printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
    chmod 700 "$scratch/bin/op"
    for s in .chezmoiscripts/30-linux/run_onchange_after_install-system-*.sh.tmpl; do
      env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < "$s" >/dev/null
    done
    ```
  - `git diff --check`

---

## Definition of Done

- All subsystem scripts exist, render without syntax errors, and have isolated `fingerprint.tmpl` triggers.
- `.chezmoidata/system.yaml` is clean and structured by subsystem.
- `keyd` runs via `run_onchange_after_`.
- Old monolithic scripts (`install-system-10-files`, `run_after_keyd`) are removed.
- `.ci/check-skip-declarations.sh` exits 0.
- `system/README.md` is updated.
- Zero leftover temporary/experimental files.
