---
title: macOS Container Kernel and Service Provisioning - Plan
type: feat
date: 2026-11-09
topic: macos-container-kernel-service
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---
# macOS Container Kernel and Service Provisioning - Plan

## Goal Capsule

- **Objective:** The repository owner can use Apple container after explicit macOS application without manually installing a kernel or starting its service.
- **Means:** Add a dedicated preparation script to the explicit chezmoi apply flow and reconcile service state without disrupting an already running runtime.
- **Authority:** The confirmed user decisions below replace the earlier manual-start-only macOS policy; worktree bootstrap remains read-only for personal settings.
- **Open blockers:** None.

---

## Product Contract

### Summary

Extend explicit macOS application to prepare Apple's container kernel and enable its service at login.
Start a missing or stopped service, preserve an already registered and running service, and allow the rest of application to continue without upgrading an active container runtime.

### Key Decisions

- **Provision the login service through apply.** Governs R1, R2, R3, R8. (session-settled: user-directed — chosen over kernel-only preparation and manual runtime startup: the owner wants the service registered and started automatically.)
- **Start a registered but stopped service.** Governs R4. (session-settled: user-directed — chosen over preserving the stopped state: apply should leave the runtime available.)
- **Preserve an active runtime throughout apply.** Governs R5, R6, R7. (session-settled: user-approved — chosen over blocking the full apply or restarting the runtime during upgrades: running container work must remain undisturbed.)
- **Start the API before kernel installation when stopped.** Governs R2, R3, R4, R8. (session-settled: user-approved — chosen over retaining kernel-before-runtime ordering or pausing implementation: container 1.7.1 needs its API daemon to install the kernel.)

### Requirements

**Kernel and service preparation**

- R1. A dedicated preparation script must run through explicit macOS chezmoi application, within the repository's existing supported host scope.
- R2. When the runtime is stopped, application must first start its API service with kernel installation disabled, then install the recommended kernel without requiring a separate manual command.
- R3. If the user-scope container login service is unregistered, application must ensure its registration after the API service is running and required kernel preparation succeeds.
- R4. If the login service is registered but the runtime is stopped, application must start the API service with kernel installation disabled, prepare the recommended kernel, and verify readiness without unnecessary re-registration.
- R5. If the service is registered and running, application must leave its kernel and service state unchanged, including on repeated applies.

**Package maintenance and failure handling**

- R6. Homebrew maintenance during application must exclude a running container runtime from upgrade and must not unload, stop, restart, or reconfigure its service.
- R7. Container service registration alone must not prevent the remaining application and unrelated eligible Homebrew upgrades from proceeding. Replace the current blanket refusal (`Container services are registered in gui/502. Finish active container tasks before applying and keep the runtime stopped throughout application.`) with behavior that preserves an active runtime under R5 and R6 and prepares a stopped service under R2–R4. Do not require the owner to stop the runtime or unregister services to apply configuration.
- R8. Kernel preparation, registration, or startup failures must fail application with an actionable diagnostic rather than report successful preparation.

**Bootstrap and instruction consistency**

- R9. Worktree initialization and configuration previews must not install kernels, register services, start runtimes, or apply personal configuration.
- R10. Setup documentation and shared macOS harness instructions must reflect R1–R9 while retaining temporary-workload cleanup requirements and Windows runtime behavior.

### Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given a supported fresh Mac without a prepared kernel or registered service, when explicit application succeeds, then the API service has started with kernel installation disabled before recommended-kernel installation, and the login service is registered with the runtime ready.
- AE2. **Covers R2, R4.** Given a registered but stopped service, when application succeeds, then the service runs without unnecessary re-registration.
- AE3. **Covers R5, R6, R7.** Given a registered and running service, when application runs repeatedly, then its kernel and service remain unchanged, container is excluded from upgrade, and unrelated application proceeds.
- AE4. **Covers R8.** Given required kernel installation fails after API-service startup, when application attempts preparation, then application fails with a diagnostic that the API service may remain running and the kernel is unprepared. Application must not claim readiness, proceed with missing login registration, or automatically stop the now-shared runtime.
- AE5. **Covers R9.** Given a new worktree, when bootstrap or a configuration preview runs, then no kernel installation or service mutation occurs.
- AE6. **Covers R10.** Given rendered macOS and Windows harness instructions, when the change is complete, then macOS describes the managed service policy and Windows retains its existing runtime guidance.
- AE7. **Covers R4, R5, R6, R7.** Given container services are registered in `gui/502`, when explicit application runs, then registration alone does not trigger the current refusal. If the runtime is active, application preserves it and continues unrelated package maintenance and configuration; if stopped, application prepares and starts it. Verify runtime state even when Homebrew reports its launcher as stopped while `container system status` reports the runtime as running.

### Scope Boundaries

- This work changes macOS container preparation and the associated package-maintenance and instruction policies.
- It does not add Kubernetes provisioning, another container runtime, registry authentication changes, or automatic workload creation.
- Temporary workload cleanup remains required; the managed login service and provisioned kernel are host infrastructure rather than task-owned disposable workloads.

### Outstanding Questions

**Deferred to Planning**

- Determine the supported native checks for kernel readiness, login-service registration, and service execution state in the installed container and Homebrew versions; choose mechanisms that satisfy R2–R6.
- Account for the observed distinction between the Homebrew launcher and the actual runtime: `brew services info container --json` reported `registered: true`, `running: false`, and `status: stopped`, while `container system status` reported `status: running`. A stopped launcher must not authorize disrupting a running runtime.
- Choose how to exclude container from upgrades under R6 without changing the owner's persistent Homebrew pin choices.
- Determine script ordering and verification commands for R1–R10, including missing-kernel and repeated-apply cases in disposable homes.

### Sources / Research

- `scripts/macos-apps.sh`: currently rejects registered container services before package maintenance and runs a global Homebrew upgrade; this behavior must change for R6 and R7.
- `home/.chezmoitemplates/agent-instructions` and `docs/setup/macos.md`: currently require manual startup and prohibit login startup; these statements are superseded for macOS by R10.
- `tests/test_macos_apps.py`: existing checks cover the old no-startup policy and package-maintenance refusal behavior.
- Owner-reported apply failure: `Container services are registered in gui/502. Finish active container tasks before applying and keep the runtime stopped throughout application.` The owner explicitly requested capturing its resolution in this plan before implementation.
- `.compound-engineering/artifacts/plans/2026-11-09-1928-feat-macos-container-harness-instructions-plan.md`: earlier implementation context; this contract supersedes its macOS manual-start policy only.
- [Homebrew container formula](https://formulae.brew.sh/formula/container): distinguishes recommended-kernel installation from service startup and login registration.
- [Apple container command reference](https://github.com/apple/container/blob/main/docs/command-reference.md): documents kernel installation and runtime startup; planning must verify behavior against the installed release.
- Apple container 1.7.1 sources: [kernel API client](https://github.com/apple/container/blob/1.7.1/Sources/Services/ContainerAPIService/Client/ClientKernel.swift), [API startup](https://github.com/apple/container/blob/1.7.1/Sources/ContainerCommands/System/SystemStart.swift), and [recommended-kernel command](https://github.com/apple/container/blob/1.7.1/Sources/ContainerCommands/System/Kernel/KernelSet.swift) establish the required API-first order.

---

## Planning Contract

Product Contract changed: R2–R4 and AE1/AE4 now use the owner-approved API-first ordering required by container 1.7.1. All other product decisions remain unchanged. The deferred planning questions above are resolved by the decisions below; implementation must verify the remaining command-output details against the installed release.

### Approach and evidence

Keep package maintenance in `scripts/macos-apps.sh`. Add a dedicated macOS container preparation script and a guarded chezmoi hook after application installation. Follow the existing shell-script and isolated `MacFixture` patterns rather than adding another setup entry point.

The installed container 1.7.1 CLI exposes `container system kernel set --recommended`, `container system status`, and `container system start --disable-kernel-install`. Kernel setup calls the API service over XPC, so a stopped runtime must start its API service before recommended-kernel installation. The formula's login launcher also invokes the start command; its process can exit successfully while the actual runtime remains active. Its `running` flag is not runtime readiness.

Homebrew's installed `cmd/upgrade.rb` excludes pinned formulae, and `formula_installer.rb` rejects unsatisfied pinned dependencies rather than replacing them. Filtering only the direct upgrade arguments would leave dependency upgrades able to touch container. Protect container through Homebrew's pin mechanism during maintenance when the runtime is active or its service state cannot safely authorize an upgrade. Keep any owner pin, and remove only a pin this invocation added, including on command failure and ordinary interruption. A required newer pinned dependency may make that package ineligible; report the reason rather than unpinning container to force it.

### Key Technical Decisions

- KTD1. Inspect the actual runtime separately from Homebrew login-service registration. A running runtime takes the preservation branch even when Homebrew reports its launcher stopped. Governs R5–R7 and AE7.
- KTD2. Use a temporary Homebrew pin where needed to protect container throughout maintenance. Preserve the owner's pin choices and fail with a diagnostic if protection or restoration fails. Governs R6 and R7.
- KTD3. For a stopped runtime, start the API service with `container system start --disable-kernel-install`, install the recommended kernel, then ensure login registration and verify readiness. Skip kernel and startup mutations when the runtime is already active and the login service registered. Governs R1–R5 and R8. (session-settled: user-approved — chosen over retaining kernel-before-runtime ordering or pausing implementation: container 1.7.1 requires the API daemon for kernel installation.)
- KTD4. Run preparation only from explicit macOS apply, after package maintenance, with the same Darwin/arm64/macOS 26+ scope. Bootstrap and previews retain their existing read-only boundary. Governs R9 and R10.

### High-Level Technical Design

These sketches describe behavior and boundaries; exact helpers and parsing belong to implementation.

```text
Explicit apply
  -> package hook -> inspect runtime/service -> protect container when needed
                  -> install missing apps and update eligible packages
                  -> restore invocation-owned pin
  -> preparation hook -> inspect actual runtime and login registration
                      -> start stopped API with kernel installation disabled
                      -> install recommended kernel after API startup
                      -> ensure missing login registration
                      -> verify actual runtime readiness
```

```text
Registered + active  -> preserve kernel and service
Registered + stopped -> start API -> prepare kernel -> verify
Unregistered/stopped -> start API -> prepare kernel -> register login -> verify
Unregistered/active  -> preserve active runtime -> ensure login registration
Unknown state        -> diagnose; never assume it is safe to disrupt runtime
```

```text
Temporary pin lifecycle
  owner pin exists -> retain throughout and after apply
  no owner pin     -> add protection -> maintenance -> remove own protection
  failure/signal   -> restore own change -> report original and restoration errors
```

### Assumptions and limits

- Registration and readiness are distinct. A successful `brew services start` alone does not prove the runtime is available; use a bounded readiness check.
- For a registered stopped launcher with an active runtime, preserve both states. For an active runtime without login registration, register only through a native operation verified not to stop or restart that runtime; diagnose unsupported behavior rather than disrupt active work.
- Kernel readiness must come from a supported native check or the recommended installer’s documented idempotent behavior. Do not invent a kernel filename or replace a runtime's kernel when it was already active on entry. The stopped-on-entry branch may install its kernel after starting the API service.
- Treat malformed output and unexpected inspection failures as unknown, not stopped. Verify the installed release's stopped-status behavior during implementation using fixtures or read-only source/help inspection.
- Package protection cannot serialize an unrelated owner-initiated runtime start against Homebrew maintenance. Document the limitation; do not stop shared work to eliminate it.

### Risks and Dependencies

Homebrew may change service metadata or upgrade dependency behavior. Keep tests for its relevant output and command boundaries. A stopped runtime may have registered Apple launchd services; registration alone is not an apply blocker. Handle service-start failure, kernel download failure, malformed status, and pin restoration failure without reporting readiness. If kernel preparation fails after API startup, report the remaining running API and failed stage; do not stop it automatically because another task may already depend on it. Give recovery guidance for completing kernel preparation before claiming readiness.

The existing fixture's command wrappers prevent host mutations in tests. Extend those wrappers for status, kernel setup, service registration/start, and pin operations. Retain native chezmoi integration in disposable homes. Do not create workloads or download test images to prove provisioning.

---

## Implementation Units

### U1 — Preserve container during package maintenance

**Requirements:** R5, R6, R7; AE3, AE7; KTD1, KTD2.

**Files:** `scripts/macos-apps.sh`, `tests/test_macos_apps.py`, `tests/test_macos_bootstrap.py`; a small shared state helper is acceptable if both scripts need the same inspection behavior.

**Approach:** Replace the blanket launchd-registration refusal with runtime-aware protection. Keep installation and unrelated upgrades functional. Preserve persistent pin state and restore temporary protection on all ordinary exits. Retain existing unsupported-host and command-failure behavior.

**Test scenarios:** Registered active runtime continues unrelated maintenance with no container upgrade or service mutation; registered stopped launcher with active runtime takes the same branch; a registered stopped runtime does not trigger the old refusal; owner-pinned container remains pinned; invocation-added pin is removed after success, upgrade failure, and interruption; inspection/protection failures cannot expose an active runtime to upgrade. Recheck state at the maintenance boundary so a runtime that starts during update is protected. Keep manual-app reuse and unrelated package tests.

### U2 — Provision the kernel and login service

**Requirements:** R1–R5, R8, R9; AE1–AE5, AE7; KTD1, KTD3, KTD4.

**Files:** new `scripts/macos-container.sh`, new guarded `home/.chezmoiscripts/run_before_16-prepare-macos-container.sh.tmpl`, new `tests/test_macos_container.py`, `tests/test_macos_bootstrap.py`.

**Approach:** After package maintenance, reconcile native kernel, login registration, and actual runtime state. Keep inspection read-only until the necessary change is established. For a stopped runtime, start the API with kernel installation disabled, install the recommended kernel, then ensure login registration and verify readiness. Avoid re-registering an existing login service. Apply platform guards in template and script. Use bounded readiness verification and actionable diagnostics. Kernel failure must fail apply and describe the running API without automatically stopping it.

**Test scenarios:** Fresh host starts the API with kernel installation disabled before recommended-kernel installation and login registration; registered stopped runtime uses the same API-first sequence without rewriting registration; registered active runtime, including a stopped Homebrew launcher, makes no kernel/service mutations across repeated applies; API-start failure prevents kernel installation; kernel-install failure after API startup fails apply, skips missing login registration, reports the remaining API, and never stops it automatically; registration and readiness failures fail apply; malformed status fails safely; unsupported platforms render no hook. In a disposable home, native chezmoi applies run hooks in order and unchanged repeated apply preserves an active runtime.

**Depends on:** U1, including fixture extensions needed for isolation.

### U3 — Align instructions and validate the full apply boundary

**Requirements:** R9, R10; AE5, AE6; KTD4.

**Files:** `docs/setup/macos.md`, `docs/maintenance/chezmoi-source.md` where its managed script inventory applies, `home/.chezmoitemplates/agent-instructions`, `tests/test_agent_instructions.py`, `tests/test_macos_bootstrap.py`, and directly affected instruction smoke tests.

**Approach:** Replace obsolete macOS manual-start/no-login statements with the managed kernel/service policy. Explain active-runtime preservation and package protection. Keep temporary workload cleanup, the Apple container default, bootstrap isolation, and Windows guidance intact.

**Test scenarios:** Rendered macOS instructions describe apply-managed service startup; Windows retains its runtime guidance; foreign harness branches remain excluded; bootstrap and preview checks show no kernel, service, or personal configuration mutation. Documentation gives recovery guidance for failed provisioning without telling owners to stop an active runtime merely to apply dotfiles.

**Depends on:** U1 and U2.

---

## Verification Contract

- Run the targeted macOS applications, new provisioning, bootstrap, readiness, and shared instruction tests with isolated command wrappers and disposable homes.
- Run the repository's required checks from `mise.toml` for the changed surface. Verify shell syntax and template platform guards.
- Cover AE1–AE7 through the unit and native chezmoi integration scenarios above. The old `gui/502` refusal must be covered as a regression.
- Before any explicitly authorized real-home apply, inspect the existing runtime and service read-only. An already active runtime must remain active, its kernel/service untouched, and unrelated application must continue. Do not stop or reset it for testing.
- No container workloads, images, volumes, or Kubernetes clusters are needed. If execution introduces disposable resources, identify ownership and remove them before completion under repository cleanup rules.

---

## Definition of Done

A supported explicit apply prepares a stopped or missing container service and recommended kernel, preserves an active runtime, and continues unrelated configuration and eligible Homebrew maintenance without the registration-only refusal. Repeated applies are idempotent. Tests cover fresh, stopped, active, mismatched launcher/runtime, and failure states. Bootstrap and previews remain read-only for personal settings, and macOS documentation and harness instructions match the resulting behavior.

All implementation units ship together in one PR because package protection must precede automatic startup. No separate follow-up work is required by this plan.
