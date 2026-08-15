---
title: Make OMP Plugin Reconciliation Find Local Binaries - Plan
type: fix
date: 2026-08-15
topic: omp-plugin-path-bootstrap
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Make OMP Plugin Reconciliation Find Local Binaries - Plan

## Goal Capsule

- **Objective:** Make the OMP plugin reconciliation script find the managed `omp` binary in `$HOME/.local/bin` when chezmoi runs it with a `PATH` that does not expose that directory.
- **Authority:** The requested fallback path and the existing `.local/bin` installation target define the behavior. Preserve plugin validation, version checks, marketplace reconciliation, migration cleanup, and failure boundaries.
- **Execution profile:** Edit chezmoi source state and its deterministic fixture only. Render the changed template with `chezmoi execute-template` using `--source "$PWD"`, a scratch destination, and a newline-free `op` stub. Never deploy to the live home directory.
- **Stop conditions:** Stop if the fallback changes command precedence outside the managed local binary, bypasses the OMP version gate, or makes a missing OMP binary fail instead of following the existing preflight contract.
- **Tail ownership:** The implementation executor owns source changes and targeted verification. The LFG shipping stages own review, commit, push, pull request, and CI.

---

## Product Contract

### Summary

The phase-70 OMP plugin updater currently requires `omp` to be discoverable through the inherited `PATH`. Chezmoi's non-interactive environment can omit `$HOME/.local/bin`, even though the chezmoi external installs `omp` there. The updater must add that managed directory to its process `PATH` before it probes or invokes `omp`, so new bootstrap devices can reconcile plugins without a shell-profile refresh.

### Problem Frame

`.chezmoiexternals/ai-agents.toml` installs the OMP executable at `.local/bin/omp`. The plugin updater runs in a non-interactive chezmoi process and currently calls `command -v omp` before every later OMP operation. If the invoking environment omits `$HOME/.local/bin`, the updater stops at `preflight: omp is not on PATH` even when the executable exists at its managed target. A sibling OMP settings script already prepends this directory before its probe, which is the repository pattern to reuse.

This work does not modify shell startup files, external target paths, OMP plugin data, or the behavior for a genuinely missing or invalid OMP binary.

### Requirements

**Bootstrap discovery**

- R1. The rendered phase-70 plugin updater prepends `$HOME/.local/bin` to `PATH` when that directory is not already present, before its OMP preflight and all plugin operations.
- R2. The updater does not duplicate an existing `$HOME/.local/bin` entry; when it adds the directory, it places it before inherited PATH entries.
- R3. The updater continues to use the same `omp` command name after PATH preparation, so its version check and every marketplace, install, enable, and uninstall operation resolve the same binary.

**Existing contract preservation**

- R4. The updater retains the current preflight failure for a missing OMP binary, the locked-version check, the Bun helper check, and all plugin reconciliation and migration behavior.
- R5. The fallback is local to the rendered phase-70 updater. It does not change the external's `.local/bin/omp` target, persistent user shell configuration, or command lookup outside this updater process.

**Regression proof**

- R6. The OMP reconciliation fixture proves a full reconcile succeeds when `omp` exists only at `$HOME/.local/bin` and the process PATH excludes that directory.
- R7. The fixture and rendered-script checks prove the PATH fallback is present, idempotent, and applied before the OMP probe without deploying to a real home or invoking a real plugin mutation.

### Acceptance Examples

- AE1. **Bootstrap PATH omission:** Given a rendered updater, a scratch home containing an executable `$HOME/.local/bin/omp`, and a PATH without that directory, when the updater runs, then it passes version preflight and reaches the existing fake plugin operations successfully.
- AE2. **Existing PATH entry:** Given a PATH that already contains `$HOME/.local/bin`, when the updater runs, then the directory appears once and command resolution remains unchanged.
- AE3. **Missing binary:** Given a PATH without `$HOME/.local/bin` and no `$HOME/.local/bin/omp`, when the updater runs, then it keeps the existing `preflight: omp is not on PATH` failure boundary.

### Scope Boundaries

**Included**

- `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`.
- The existing `.ci/test-omp-agent-reconcile.sh` fixture and its rendered-script assertions.
- Comments needed to explain the non-interactive PATH bootstrap.

**Deferred**

- Updating every OMP-related script. The settings and zsh-completion scripts already implement the same local-bin PATH preparation; unrelated scripts remain unchanged.
- Refreshing interactive shell configuration. This fix makes the chezmoi subprocess self-sufficient and does not claim to repair a user's running shell.

**Outside this work**

- Live `chezmoi apply`, plugin marketplace changes on a real user account, OMP version changes, and external-release resolution.
- Changes to `.chezmoiignore`, `.chezmoiexternals/ai-agents.toml`, or the managed OMP plugin catalog.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Prepend the managed local-bin directory to `PATH` before probing OMP.** Reuse the existing `case ":$PATH:"` membership guard used by the OMP settings and completion scripts. When the directory is absent, this gives the managed external precedence over inherited entries, keeps all existing `omp` calls unchanged, and avoids maintaining a separate absolute-path command variable.
- KTD2. **Extend the existing OMP reconciliation fixture instead of adding a new test harness.** The fixture already renders the updater, relocates its desired-state paths into a scratch home, and drives a fake OMP binary through full reconciliation. A PATH-omission case proves the new process boundary without adding another test entry point.
- KTD3. **Test the rendered shell contract and the fallback execution path.** Source-template text alone cannot prove that PATH preparation occurs before the probe. The fixture will assert the rendered guard and run the fake OMP binary from `$HOME/.local/bin` with no OMP binary on PATH.

### High-Level Technical Design

The rendered updater will set `PATH` after `set -euo pipefail` and before its existing `command -v omp` check. A colon-delimited membership check prevents duplicate insertion and leaves an existing local-bin entry in its current position. When the directory is absent, it is prepended and exported. The rest of the script continues to call `omp`, so the version check and every mutation use the resolved executable.

The existing fixture will keep its normal fake-bin run and add a fallback run. The fallback copies the fake OMP executable into the scratch home’s `.local/bin`, resolves the fixture’s working Bun executable before restricting PATH, places that Bun executable in a scratch-only helper directory, and runs with that directory plus `/usr/bin:/bin` but no OMP binary. The call log and successful cleanup establish that the local executable handled the complete reconcile.

### Sequencing and Dependencies

1. Add the PATH preparation block to the phase-70 updater template.
2. Add rendered-text assertions and a scratch-home fallback execution to `.ci/test-omp-agent-reconcile.sh`.
3. Render the template with the repository’s scratch `op` stub, run the targeted fixture, and run shell syntax checks on the rendered output.
4. Run the repository’s required diff and status checks before shipping.

### System-Wide Impact

The fix changes only the environment inherited by one chezmoi updater process. It improves first-apply convergence on hosts where the external binary is already installed but the invoking shell has not refreshed PATH. It does not alter the persistent user environment, the external installation location, command lookup outside this process, or OMP plugin lifecycle semantics. Bun and the helper subprocess inherit the adjusted process-local PATH by design.

### Risks and Mitigations

- **Risk:** A duplicate PATH entry changes command lookup or causes noisy environment growth. **Mitigation:** Use the colon-delimited membership guard and assert the guard in the rendered fixture.
- **Risk:** The process-local PATH also affects Bun and helper subprocess lookup. **Mitigation:** Keep the mutation inside the updater process, retain the OMP version preflight, and make the fallback fixture expose only its resolved Bun helper plus `/usr/bin:/bin`.
- **Risk:** The fallback masks a missing binary. **Mitigation:** Leave the existing `command -v omp` preflight in place and retain the current missing-binary acceptance case.

### Research Breadcrumbs

- `.chezmoiexternals/ai-agents.toml:35-48` installs the managed OMP binary at `.local/bin/omp`.
- `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl:18-31` already prepends `$HOME/.local/bin` before its OMP probe.
- `.chezmoiscripts/70-agents/run_onchange_after_install-omp-zsh-completion.sh.tmpl:34-46` documents the same non-interactive PATH omission and precedence rule.
- `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl:98-115` contains the OMP version preflight that currently depends on inherited PATH.
- `.ci/test-omp-agent-reconcile.sh:142-252` renders the desired plugin paths, installs a fake OMP binary, and proves the full reconciliation contract.

---

## Implementation Units

### U1. Bootstrap OMP PATH in the updater

- **Goal:** Make the rendered phase-70 updater resolve the managed OMP executable without changing its existing command flow.
- **Requirements:** R1, R2, R3, R4, R5.
- **Files:** `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`.
- **Approach:** Add the repository-standard colon-delimited PATH membership check immediately before the existing preflight. Prepend and export `$HOME/.local/bin` only when absent. Keep the current `command -v omp`, Bun probe, version comparison, helper setup, and plugin lifecycle calls unchanged.
- **Test scenarios:**
  - The rendered updater contains the local-bin PATH guard before `command -v omp`.
  - An existing local-bin PATH entry is not duplicated by the guard.
  - A missing OMP binary still fails at the existing preflight boundary.
  - A managed OMP binary in `$HOME/.local/bin` is selected when the inherited PATH omits that directory.
- **Verification:** Render with `chezmoi execute-template` under the scratch `op` stub, run `bash -n` on the rendered script, and execute the fallback case in U2.

### U2. Prove bootstrap reconciliation in the existing fixture

- **Goal:** Exercise the rendered updater with OMP available only through the fallback directory while retaining existing reconciliation coverage.
- **Requirements:** R6, R7.
- **Files:** `.ci/test-omp-agent-reconcile.sh`.
- **Approach:** Reuse the fixture’s fake OMP implementation and expected version. Place a copy in the scratch home’s `.local/bin`, resolve the active Bun executable before restriction, expose it through a scratch-only helper directory, and run with `PATH="$fallback_bin:/usr/bin:/bin"` so no ambient OMP can satisfy the probe. Then assert the fallback call log and normal cleanup. Add structural assertions that the PATH guard and export occur before the preflight.
- **Test scenarios:**
  - Full plugin reconciliation succeeds with OMP only at `$HOME/.local/bin`.
  - The fake OMP call log contains the expected version and plugin operations from the fallback run.
  - A restricted run with neither an inherited nor managed OMP binary still fails at `preflight: omp is not on PATH` before marketplace mutation.
  - The existing PATH-backed run, version-decoy failures, missing-manifest failure, migration removal, and repeat-reconcile checks still pass.
- **Verification:** Run `.ci/test-omp-agent-reconcile.sh` with rendered auth, plugin, haptic package, and settings inputs. Keep all fixture HOME and PATH values scratch-scoped.

---

## Verification Contract

| Check | Applies when | Pass signal |
| --- | --- | --- |
| `.ci/test-omp-agent-reconcile.sh` | Always | Rendered OMP auth, plugin, and settings reconciliation tests pass, including the PATH-omission fallback. |
| `chezmoi execute-template` for `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl` | Always | The template renders successfully from the repository source with the scratch `op` stub and no live-home writes. |
| `bash -n` on the rendered updater | Always | The generated shell script parses successfully. |
| `git diff --check` | Before delivery | No whitespace errors. |
| `git status --short --branch` and scoped diff review | Before delivery | Only the plan, updater template, and targeted fixture changed. |

The render and fixture must use `--source "$PWD"`, scratch HOME and destination paths, and a newline-free `op` stub. Do not run a live plugin reconcile or deploy to `$HOME`.

---

## Definition of Done

- The phase-70 updater prepends and exports `$HOME/.local/bin` when it is absent from PATH before probing or invoking OMP.
- Existing OMP version, Bun, plugin, migration, failure, and idempotency behavior remains intact.
- The existing reconciliation fixture proves fallback execution from the managed local-bin path and retains the normal PATH-backed coverage.
- The rendered updater passes shell syntax validation and the targeted fixture passes without live-home or real-plugin mutation.
- `git diff --check` and scoped status/diff review pass.
- No abandoned helper, stale assertion, placeholder, or TODO remains in the diff.
