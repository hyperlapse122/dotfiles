---
title: Use App-Integration-Compatible 1Password CLI Readiness Probe - Plan
type: fix
date: 2026-08-04
deepened: 2026-08-04
topic: 1password-cli-readiness-probe
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Use App-Integration-Compatible 1Password CLI Readiness Probe - Plan

## Goal Capsule

- **Objective:** Let a new Windows machine pass the prerequisite authentication gate when 1Password desktop app integration is ready, even though `op whoami` cannot validate that integration mode.
- **Product authority:** The user reported the live Windows bootstrap failure. Official 1Password CLI guidance uses `op vault list` to trigger and verify desktop app integration.
- **Execution profile:** Replace the authentication probe on both platform counterparts, add deterministic source-level behavior tests, align CI, and correct the bootstrap documentation.
- **Open blockers:** None.

---

## Product Contract

### Summary

The prerequisite hooks must test whether an authenticated `op` process can perform a standard vault API command. The readiness check must work for 1Password desktop app integration and `OP_SERVICE_ACCOUNT_TOKEN` authentication without reading a secret. It does not prove access to every vault or item that later templates reference.

### Problem Frame

Both prerequisite hooks currently treat `op whoami` as the primary readiness signal and `op user get --me` as a legacy fallback. On a new Windows machine, desktop app integration can authorize normal CLI commands while `op whoami` remains unavailable because no CLI account is configured. The hook therefore blocks before chezmoi can resolve secrets, even though 1Password and its CLI integration are ready. 1Password's app-integration documentation uses `op vault list` as the standard command that triggers desktop authorization.

### Requirements

**Authentication behavior**

- R1. The Windows hook reports 1Password ready when `op vault list` succeeds through desktop app integration, without requiring `op whoami` or a separately configured CLI account.
- R2. The Windows hook reports 1Password ready when `op vault list` succeeds through `OP_SERVICE_ACCOUNT_TOKEN` authentication.
- R3. The hook reports 1Password not ready when `op` is absent or `op vault list` fails.
- R4. The POSIX counterpart uses the same readiness contract so the paired hooks do not retain conflicting authentication rules.

**Regression protection and guidance**

- R5. Deterministic tests prove the desktop-integration-compatible success path and the unavailable or unauthenticated failure paths for both scripts.
- R6. CI runs the new tests on the platform halves that execute each script.
- R7. User documentation describes vault access, not `op whoami`, as the completion signal.

### Acceptance Examples

- AE1. **Covers R1, R3.** Given an `op` stub where `whoami` fails but `vault list` succeeds, when `Test-OpReady` runs, then it returns true.
- AE2. **Covers R2.** Given service-account authentication where `vault list` succeeds, when the readiness check runs, then it returns true without calling a user-only fallback.
- AE3. **Covers R3.** Given an installed but unauthenticated CLI where `vault list` fails, when the readiness check runs, then it returns false and the existing guidance path remains active.
- AE4. **Covers R4.** Given equivalent command outcomes, the PowerShell and shell readiness functions return equivalent results.

### Scope Boundaries

- Do not read a real secret as a readiness probe.
- Do not change secret references, 1Password installation, polling deadlines, headless behavior, or the GitHub token advisory.
- Do not deploy the source state to the live home directory during verification.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use `op vault list` as the single authentication/API-readiness probe.** It is a standard non-secret CLI command that 1Password documents for desktop app integration, and it works with service-account access. Chosen over retaining `op whoami` plus fallbacks because identity-reporting commands do not validate the integration path. A successful list command does not guarantee that the authenticated principal can access each repository secret; later `onepasswordRead` calls remain the authorization check for those exact references.
- KTD2. **Keep the Windows and POSIX hooks in lockstep.** Update `Test-OpReady` and `op_ready` together because both comments declare the scripts as counterparts and both gate the same `onepasswordRead` capability.
- KTD3. **Test functions through their existing source seams with command stubs.** The tests must simulate `whoami` failure and `vault list` success so a regression to the current probe fails observably. Chosen over source-text assertions because executed behavior protects command selection and exit-code handling.
- KTD4. **Run each fixture on its native script runtime.** Register the shell fixture on Linux/macOS-capable CI and the PowerShell fixture on Windows CI. This keeps quoting and command resolution behavior representative.

### Risks and Dependencies

- `op vault list` returns vault metadata. Both hooks must discard stdout and stderr so vault names, account details, and approval diagnostics do not enter bootstrap output or logs. The command does not read item fields or secret values.
- Desktop integration can display an approval prompt. This is expected in an interactive bootstrap; the existing non-interactive guard still prevents indefinite waiting in headless runs.
- A successful `op vault list` can return zero vaults or vaults unrelated to this repository's references. The hook must describe the result as authentication/API readiness, not proof that every later secret lookup will succeed.
- CI stubs used by render jobs currently accept every command. The dedicated fixtures must reject unexpected commands so they detect a return to `whoami`.

---

## Implementation Units

### U1. Replace the paired readiness probes

- **Goal:** Make both prerequisite hooks validate authenticated command access instead of CLI account identity.
- **Requirements:** R1, R2, R3, R4 (mechanism per KTD1 and KTD2).
- **Dependencies:** None.
- **Files:** `.install-prerequisites.ps1`, `.install-prerequisites.sh`
- **Approach:** Replace the identity-command chain in `Test-OpReady` and `op_ready` with one silent `op vault list` check. Update adjacent comments to state the capability contract and authentication modes. Preserve the existing function names, callers, wait loop, and diagnostics.
- **Patterns to follow:** `Invoke-NativeExitCode` in `.install-prerequisites.ps1:39-56` and the silent native-command idiom in `.install-prerequisites.sh:36-40`.
- **Test scenarios:** `op` missing returns not ready; `vault list` exit 0 returns ready even when `whoami` would fail; `vault list` nonzero returns not ready; no user-only fallback is required.
- **Verification:** U2 fixtures execute both functions against strict stubs and pass all scenarios.

### U2. Add deterministic authentication fixtures

- **Goal:** Protect the app-integration and service-account-compatible readiness contract on both script runtimes.
- **Requirements:** R5 (mechanism per KTD3 and KTD4).
- **Dependencies:** U1.
- **Files:** `.ci/test-install-prerequisites-op-auth.sh`, `.ci/test-install-prerequisites-op-auth.ps1`
- **Approach:** Source each hook through its existing `_INSTALL_PREREQUISITES_TEST_SOURCE` seam. Put a strict task-scoped `op` stub first on `PATH`. Drive success and failure through an environment-controlled `vault list` exit code, record invocations, and fail if the readiness function calls `whoami`, `user get --me`, or an unexpected verb. Make the stub emit sentinel metadata on stdout and stderr, then assert that the readiness function suppresses both streams. For the absent-command case, replace `PATH` with an otherwise empty scratch directory so an ambient host installation cannot satisfy command discovery; restore the original value during cleanup.
- **Patterns to follow:** Isolated fixture setup, command logs, and explicit assertions in `.ci/test-omp-agent-reconcile.sh` and `.ci/test-omp-agent-reconcile.ps1`.
- **Test scenarios:**
  - Desktop integration shape: `whoami` is defined to fail, `vault list` succeeds, and readiness succeeds.
  - Service-account shape: `OP_SERVICE_ACCOUNT_TOKEN` is present, `vault list` succeeds, and readiness succeeds through the same command.
  - Unauthenticated CLI: `vault list` fails and readiness fails.
  - Missing CLI: an exclusive empty scratch `PATH` makes command discovery fail and readiness returns false without invoking an ambient host installation.
  - Command and output contract: every successful or unauthenticated probe contains only `vault list`, and sentinel stdout and stderr do not escape the readiness function.
- **Verification:** Both fixture scripts exit 0 and print their success marker.

### U3. Register coverage and correct user guidance

- **Goal:** Run the regression fixtures in CI and remove the incorrect `op whoami` completion claim.
- **Requirements:** R6, R7.
- **Dependencies:** U2.
- **Files:** `.github/workflows/ci.yml`, `README.md`
- **Approach:** Add the shell fixture to an existing Linux portable-fixture step and the PowerShell fixture to the native Windows PowerShell step. Update the 1Password authentication section to state that bootstrap continues when `op vault list` confirms desktop-integration or service-account authentication, while exact secret authorization is checked later by chezmoi.
- **Patterns to follow:** Existing grouped fixture invocations in `.github/workflows/ci.yml:493-501` and Windows PowerShell exit-code guards in `.github/workflows/ci.yml:543-545`.
- **Test scenarios:** Workflow syntax remains valid; both new fixture paths are registered exactly once; README guidance matches the executable readiness contract.
- **Verification:** Local fixture execution proves behavior; a static exact-count check proves that each fixture path appears once in the workflow; the edited native Linux and Windows CI jobs complete successfully.

---

## Verification Contract

- **POSIX behavior:** Run `.ci/test-install-prerequisites-op-auth.sh`; it must prove success on `vault list`, failure on unavailable authentication, absence handling, and rejection of unexpected commands.
- **Windows behavior:** Run `.ci/test-install-prerequisites-op-auth.ps1` with `pwsh`; it must prove the same contract through `Test-OpReady` and `Invoke-NativeExitCode`.
- **Static checks:** Run `bash -n .install-prerequisites.sh .ci/test-install-prerequisites-op-auth.sh` and parse both PowerShell files with the installed PowerShell runtime.
- **CI registration:** Assert that each new fixture path appears exactly once in `.github/workflows/ci.yml`, then require the edited native Linux and Windows jobs to pass.
- **Repository gates:** Run `git diff --check`, inspect `git status`, and inspect a diff limited to the requested files. Keep root `CLAUDE.md` and `packages/CLAUDE.md` as exact `@AGENTS.md` mirrors.
- **No deployment:** Do not run `chezmoi apply`; this change affects a pre-read hook and the fixtures can verify it without touching the deployed home state.

## Definition of Done

- A Windows-style stub where `op whoami` fails but `op vault list` succeeds makes `Test-OpReady` return true.
- Both hooks use the same non-secret vault-access readiness probe and retain existing headless, polling, and guidance behavior.
- Both deterministic fixtures pass and CI invokes them on the applicable platform halves.
- README no longer claims that `op whoami` is the readiness signal.
- The branch contains no abandoned probe fallback or unused fixture scaffolding.

---

## Sources and Research

- `.install-prerequisites.ps1:71-79` and `.install-prerequisites.sh:32-40` — current identity-based readiness probes.
- `.install-prerequisites.ps1:273-276` and the corresponding shell test-source gate — existing source seams for function-level fixtures.
- `README.md:145-163` — bootstrap instructions and the incorrect completion claim.
- [1Password CLI app integration](https://www.1password.dev/cli/app-integration) — official guidance runs `op vault list` to trigger desktop app authentication.
- [1Password CLI vault commands](https://www.1password.dev/cli/reference/management-commands/vault) — `op vault list` lists accessible vaults without reading item secrets.
