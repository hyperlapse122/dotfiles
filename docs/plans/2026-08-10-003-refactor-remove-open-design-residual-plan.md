---
title: Complete Open Design Removal - Plan
date: 2026-08-10
topic: remove-open-design-residual
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Complete Open Design Removal - Plan

## Goal Capsule

- **Objective:** Complete the removal of Open Design across host runtime state and repository documentation by executing local host cleanup on this machine and purging residual decommission documentation from the repository.
- **Product authority:** Repository policy (`AGENTS.md`) governs system-file provisioning, manual decommission checklists, and no-teardown-script rules.
- **Execution profile:** Two units, executed in order. U1 mutates live host state outside the repository. U2 deletes one tracked documentation file. No chezmoi apply is triggered by either unit.
- **Stop conditions:** A deployed path cannot be removed because a process still holds it; a port stays bound after the service stop; a git-tracked `open-design` reference appears outside `docs/` and the `.chezmoidata/system.yaml` `removed:` entry; any command requires `sudo` or touches the unmanaged developer checkout.
- **Open blockers:** None.

---

## Product Contract

### Summary

Proposes completing the removal of Open Design by executing local operator host cleanup on this machine (stopping live background processes, purging `~/.config/systemd/user/open-design.service`, `~/.local/bin/open-design*`, `~/.local/share/open-design/`, and persistent app data `~/.od`) and removing the residual operator decommission checklist (`docs/decommission/open-design.md`) from the repository.

### Problem Frame

The managed Open Design source integration (CLI wrappers, service unit, build scripts, MCP declarations, system-sleep hook, and CI integration tests) was removed from active chezmoi source state in PR #151 (commit 47889c5). However, residual artifacts remain: `docs/decommission/open-design.md` in the repository, `.chezmoidata/system.yaml`'s `removed:` entry for the system sleep hook, and deployed runtime files/data on local hosts. To achieve total decommission, the operator host state must be cleaned up and obsolete decommission documentation pruned from the repository while preserving historical plan history per repository policy.

### Key Decisions

- KD1. **Execute immediate operator host cleanup on this machine.** (session-settled: user-directed — chosen over keeping local runtime files/data: stop any live process, delete `~/.config/systemd/user/open-design.service`, `~/.local/bin/open-design*`, `~/.local/share/open-design/`, and `~/.od`). Governs R1, R2, R3, R4.
- KD2. **Purge `~/.od` persistent data.** (session-settled: user-approved — chosen over preserving SQLite DB and project artifacts: complete removal requires clearing all local application state). Governs R3.
- KD3. **Delete `docs/decommission/open-design.md` from repository source state.** (session-settled: user-directed — chosen over keeping decommission guidance: source removal is complete and local host cleanup is executed). Governs R5.
- KD4. **Retain `.chezmoidata/system.yaml` `removed:` entry for `/etc/systemd/system-sleep/open-design.sh`.** (session-settled: user-approved — chosen over immediate deletion: system.yaml policy mandates keeping `removed:` entries for a release cycle or two so secondary machines pull and execute the `/etc` hook deletion on their next apply). Governs R6.
- KD5. **Preserve historical plans in `docs/plans/`.** (session-settled: user-approved — chosen over deleting historical plans: the prior removal precedent (`docs/plans/2026-08-03-004-feat-cross-platform-workstation-parity-plan.md` U2, "Preserve all Open Design historical plans") keeps historical plans intact as immutable architectural audit records). Governs R7.

### Requirements

**Host Runtime Cleanup**

- R1. Any running `open-design.service` or background Open Design process on the host must be stopped, and TCP ports `127.0.0.1:36947` and `127.0.0.1:43909` must be verified free.
- R2. Deployed binaries, launchers, and user systemd units must be deleted from `~/.config/systemd/user/open-design.service`, `~/.local/bin/open-design`, `~/.local/bin/open-design-desktop`, `~/.local/libexec/open-design/`, and `~/.local/share/applications/open-design.desktop`.
- R3. Disposable execution checkout (`~/.local/share/open-design/`) and persistent application data (`~/.od`) must be deleted from the host filesystem.
- R4. Host cleanup must be performed via direct command execution, maintaining compliance with `AGENTS.md:22` (no teardown scripts added to chezmoi apply).

**Repository Source and Documentation Purge**

- R5. `docs/decommission/open-design.md` must be removed from the git repository.
- R6. The `.chezmoidata/system.yaml` `removed:` entry for `/etc/systemd/system-sleep/open-design.sh` must be retained to ensure multi-host reclamation on next apply.
- R7. Historical integration and fix plans (`docs/plans/2026-07-24-002-feat-open-design-integration-plan.md`, `2026-07-24-003-fix-open-design-mcp-startup-plan.md`, `2026-07-25-001-feat-open-design-hibernate-stop-plan.md`, `2026-08-03-002-refactor-open-design-cli-name-plan.md`) must be left intact.

### Scope Boundaries

- **Unmanaged developer checkout (`~/src/github.com/nexu-io/open-design`):** Excluded — this developer checkout was never managed by dotfiles and remains untouched.
- **Chezmoi apply teardown scripts:** Excluded — no teardown/revert script is added to chezmoi scripts per `AGENTS.md:22`.

### Deferred to Follow-Up Work

- Dropping the `.chezmoidata/system.yaml` `removed:` entry for `/etc/systemd/system-sleep/open-design.sh` after a release cycle or two, once secondary machines have applied the reclamation (KD4).

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R4.** Given deployed Open Design files exist under `~/.config/systemd/user/`, `~/.local/bin/`, `~/.local/share/open-design/`, and `~/.od`, when host cleanup is executed, then all specified paths are removed, no processes listen on ports 36947 or 43909, and systemd user daemon is reloaded.
- AE2. **Covers R5, R6, R7.** Given the repository source state, when the decommission removal is applied, then `docs/decommission/open-design.md` is deleted, `.chezmoidata/system.yaml` retains `/etc/systemd/system-sleep/open-design.sh` in its `removed:` list, and all four historical `docs/plans/*open-design*` files remain present.

Product Contract preservation: changed: KD5 citation — research found `AGENTS.md` carries no plans-preservation clause, so the annotation's authority was corrected to the actual precedent (PR #151's plan U2) without changing the decision, its provenance class, or any requirement.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Execute host cleanup as direct operator commands in the live shell session, never through chezmoi.** (session-settled: user-directed — chosen over adding a chezmoi `run_*` teardown script: `AGENTS.md:22` forbids teardown/revert scripts; decommissioned software is reclaimed by source deletion, `system.yaml` `removed:`, or a documented one-time manual reversal). Instantiates KD1 and KD2; governs R1, R2, R3, R4. The checklist in `docs/decommission/open-design.md` sections 1-4 is the authoritative procedure and is executed before that file is deleted.
- KTD2. **Run host cleanup (U1) before the repository purge (U2).** KD3's rationale for deleting the checklist is that local host cleanup is already executed; landing U2 first would commit a deletion whose justification is not yet true on this host. The units touch disjoint surfaces (host state vs. one tracked file), so the ordering costs nothing.

### Assumptions

- The systemd user unit may already be stopped, disabled, or absent on this host; every stop/disable command tolerates `not loaded` / `no such unit` outcomes and proceeds.
- `$XDG_RUNTIME_DIR/open-design/` is tmpfs IPC state; it is removed when present but requires no persistent handling.
- `/etc/systemd/system-sleep/open-design.sh` on this host is reclaimed by the retained `system.yaml` `removed:` entry on the next chezmoi apply (KD4); U1 does not delete it manually.

### Sources and Research

- `docs/decommission/open-design.md` sections 1-4 — the authoritative operator procedure U1 executes: service stop, port verification (web `36947`, daemon `43909`), deployed-file removal, and checkout/data removal — plus the section 5 credential boundary (informational, no executable commands: no chezmoi-managed credentials exist; vendor OAuth lives only under `~/.od`, and sessions may be ended through each provider's own flows before the purge).
- Repository-wide search (case-insensitive `open[-_]design`): the only non-`docs/` match is the `.chezmoidata/system.yaml` `removed:` entry (path-only, unscoped); all other matches are the deletion target and historical `docs/plans/` records. No live managed source, CI, workflow, template, or data file references Open Design.
- `docs/plans/2026-08-03-004-feat-cross-platform-workstation-parity-plan.md` U2 — the PR #151 removal unit; established both the `system.yaml` `removed:` reclamation and the historical-plans preservation precedent.
- No `docs/solutions/` corpus exists in this repository.

---

## Implementation Units

### U1. Host runtime cleanup

- **Goal:** Stop all live Open Design processes and delete every deployed runtime artifact and all persistent data from this host.
- **Requirements:** R1, R2, R3, R4 (AE1); KTD1.
- **Dependencies:** None.
- **Files:** No repository files. Host state only: `~/.config/systemd/user/open-design.service`, `~/.local/bin/open-design`, `~/.local/bin/open-design-desktop`, `~/.local/libexec/open-design/`, `~/.local/share/applications/open-design.desktop`, `~/.local/share/open-design/`, `~/.od`, `$XDG_RUNTIME_DIR/open-design/`.
- **Approach:** Execute the procedure in `docs/decommission/open-design.md` sections 1-4 as direct shell commands, in this order:
  1. Stop the user service (`systemctl --user stop open-design.service`), tolerating an absent or already-stopped unit; kill any residual `open-design` process still bound to the managed ports.
  2. Verify with `ss -ltnp` that nothing listens on `127.0.0.1:36947` or `127.0.0.1:43909` before deleting anything.
  3. Delete the user unit file, then `systemctl --user daemon-reload`; delete both `~/.local/bin/` wrappers, `~/.local/libexec/open-design/`, and the desktop launcher.
  4. Delete `~/.local/share/open-design/` and `~/.od`; remove `$XDG_RUNTIME_DIR/open-design/` when present.
  5. Never touch `~/src/github.com/nexu-io/open-design` or `/etc/systemd/system-sleep/open-design.sh` (see Assumptions).
- **Execution note:** Destructive host operation — verify each path exists before removal, report removed-vs-absent per path, and use no `sudo`; everything listed is user-owned. Before step 4, vendor OAuth sessions under `~/.od` may optionally be ended through each provider's own flows (checklist section 5, "if desired"); never read, print, or copy tokens out of the data directory. The purge of `~/.od` itself is settled (KD2) and proceeds regardless.
- **Test expectation:** none — host-state operation with no repo test surface; the Verification post-conditions below are the proof.
- **Verification:** All of the following hold on the host: `ss -ltnp` shows no listener on ports `36947` or `43909`; every path in **Files** is absent; `systemctl --user status open-design.service` reports the unit could not be found; `systemctl --user daemon-reload` exits clean.

### U2. Repository decommission-doc purge

- **Goal:** Remove the obsolete operator decommission checklist from repository source state, leaving the `system.yaml` reclamation entry and all historical plans untouched.
- **Requirements:** R5, R6, R7 (AE2).
- **Dependencies:** U1 (KTD2).
- **Files:** `docs/decommission/open-design.md` (delete). Verified unchanged: `.chezmoidata/system.yaml`, `docs/plans/2026-07-24-002-feat-open-design-integration-plan.md`, `docs/plans/2026-07-24-003-fix-open-design-mcp-startup-plan.md`, `docs/plans/2026-07-25-001-feat-open-design-hibernate-stop-plan.md`, `docs/plans/2026-08-03-002-refactor-open-design-cli-name-plan.md`.
- **Approach:**
  1. `git rm docs/decommission/open-design.md` as the only repository change; `docs/decommission/` keeps its three sibling checklists (`cli-proxy-api.md`, `ydotool.md`, `unmanaged-repo-guard.md`).
  2. No chezmoi metadata changes: `docs/` is internal source, not a deployed target, so `.chezmoiignore` and `.chezmoiremove` stay untouched.
- **Test expectation:** none — single documentation deletion; the Verification checks below are the proof.
- **Verification:** The file is absent from the git index; a case-insensitive `open[-_]design` search matches only historical `docs/plans/` records and the `system.yaml` `removed:` entry; `git diff` shows no change to `.chezmoidata/system.yaml`; the four historical plans in **Files** are present and unmodified.

---

## Verification Contract

| Gate | Proof | Applies to |
|---|---|---|
| Host post-conditions | `ss -ltnp` shows no listener on `127.0.0.1:36947`/`43909`; every U1 **Files** path absent; `systemctl --user status open-design.service` reports not-found; `systemctl --user daemon-reload` exits clean | U1 |
| Repository residual scan | `git grep -iE 'open[-_]design'` (git-tracked files only — the gitignored `packages/node_modules/qs/README.md` contains unrelated `numi-hq/open-design` logo links a filesystem-wide grep would false-match) matches only `docs/plans/` historical records and the `.chezmoidata/system.yaml` `removed:` entry | U2 |
| Retention invariants | `.chezmoidata/system.yaml` diff empty; the four historical `docs/plans/*open-design*` files present and unmodified; `docs/decommission/` still holds its three sibling checklists | U2 |
| Diff hygiene | `git diff --check` clean; change scope limited to the plan file and the deleted checklist | U2 |
| Push CI | `render-dotfiles.yml` and `ci.yml` terminal green after push (repository delivery rule) | U2 |

No unit-test, build, or template-render gate applies: the change deletes one markdown document and mutates host state; it touches no template, script, data file, or CI harness.

---

## Definition of Done

- **Global:** U1 and U2 Verification Contract gates all hold; no chezmoi teardown script was added; the unmanaged developer checkout is untouched; the work lands as conventional-commit history on the current branch, is pushed, and both push workflows reach terminal success.
- **U1:** Every host post-condition in the Verification Contract holds, observed on this machine after execution.
- **U2:** `docs/decommission/open-design.md` is deleted from the git index and the retention invariants hold.
- **Cleanup:** No abandoned-attempt artifacts (scratch scripts, temporary files) remain in the working tree or on the host beyond the deletions themselves.
