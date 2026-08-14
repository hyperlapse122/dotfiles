---
title: Defer Linux Service Restarts During Apply - Plan
type: fix
date: 2026-08-15
topic: defer-linux-service-restarts
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Defer Linux Service Restarts During Apply - Plan

## Goal Capsule

- **Objective:** Prevent the named Linux provisioning paths from explicitly restarting or reloading network services during `chezmoi apply`, while telling the operator how to activate pending service changes.
- **Authority:** The requested behavior is to defer explicit service mutations in the Fedora and network installers and to tell the user to restart services manually or reboot. Existing package, one-time Tailscale authentication, time configuration, enablement, and network configuration behavior remains unless this plan names the explicit live service command.
- **Execution profile:** Edit chezmoi source state only. Render changed templates with a scratch source, `--source "$PWD"`, and a stub `op`; never apply to the live home directory.
- **Stop conditions:** Stop if a change would suppress package installation, break the one-time Tailscale authentication prerequisite, or alter service enablement persistence. Stop if a render still contains an explicit affected-service restart or NetworkManager reload in the targeted network installer.
- **Tail ownership:** The implementation executor owns tests and leaves commit, push, and pull-request work to the LFG shipping stages.

---

## Product Contract

### Summary

Defer explicit live service activation in the Fedora installer and remove explicit live network-service restarts from the Linux network installer. Add clear post-apply notices to the Fedora and Jetson installers. The operator can then restart affected services manually after the apply or reboot the system once.

### Problem Frame

The Fedora installer currently calls `systemctl enable --now` for `keyd`, `tailscaled`, and `systemd-timesyncd`. The `--now` behavior starts a unit during provisioning instead of waiting for the operator's chosen restart or reboot point. The network installer explicitly restarts `systemd-resolved`, `NetworkManager`, and `tailscaled`, and reloads `NetworkManager`; these live mutations can interrupt the connection that is carrying the apply.

The Jetson installer has no operator-facing reminder after apt or desktop-package changes. The operator can finish an apply without a clear instruction to restart a service manually or reboot when package changes need activation. The requested notices must be present in both OS-specific installer templates.

This plan does not claim to control indirect activation by apt/dnf maintainer scripts, `timedatectl set-ntp true`, or the one-time Tailscale authentication script's required daemon startup. Those paths remain explicit boundaries because suppressing them would change package, time, or authentication behavior rather than only deferring the targeted network-service restart path.

### Requirements

**Service mutation policy**

- R1. The Fedora installer replaces `systemctl enable --now` in `enable_services` with enable-only operations. It issues no explicit start or restart for `keyd`, `tailscaled`, `systemd-timesyncd`, or `nvidia-persistenced`, while preserving the existing unit-absence guards.
- R2. The network installer does not explicitly restart `systemd-resolved`, `NetworkManager`, or `tailscaled`, and does not explicitly reload `NetworkManager` during apply.
- R3. The change does not suppress package installation, repository configuration, firewall rule reconciliation, resolver symlink creation, service enablement persistence, required time configuration, or one-time Tailscale authentication. Package maintainer scripts and indirect service activation remain outside this repository's control and are not misrepresented as deferred.

**Operator guidance**

- R4. The Fedora installer prints a concise notice when its service enablement path completes. The notice names `keyd`, `tailscaled`, `systemd-timesyncd`, and `nvidia-persistenced` as the units that may need manual activation, then tells the operator to restart affected services after apply or reboot the system.
- R5. The Jetson installer prints a concise notice after every successful gated installer run, including no-op package paths. Because the template does not own the package maintainer service set, the notice tells the operator to restart any affected services manually after apply or reboot the system.
- R6. The network installer prints a concise notice that names the deferred network services and tells the operator to restart them manually after apply or reboot the system.

**Regression safety**

- R7. Rendered Fedora, Jetson, and network scripts remain valid shell and preserve their existing host gates, skip behavior, and idempotency.
- R8. Existing CI fixtures prove the notices are rendered and the affected scripts contain no targeted live start, restart, or reload command. The existing skip-declaration matrix remains aligned with the notice-only NetworkManager applicability guard.

### Key Flows

- F1. **Fedora apply with service packages present:** The installer reconciles packages and unit enablement, does not issue an explicit start or restart from `enable_services`, prints the manual-action notice, and exits successfully.
- F2. **Jetson apply with apt or desktop changes:** The installer completes its existing package and desktop-app work, prints the manual-action notice on every successful gated run, and does not add a system-service mutation.
- F3. **Network configuration apply:** The installer updates the resolver link and firewall state, leaves the three network services untouched, prints the named-service notice, and lets the operator choose manual restart or reboot.
- F4. **Idempotent re-apply:** A second render and execution path keeps the same gates, deterministic notice behavior, and absence of targeted service mutations.

### Acceptance Examples

- AE1. **No Fedora live activation:** Given a Fedora render, when the installer reaches `enable_services`, then it uses enable-only operations and contains neither `systemctl enable --now` nor a restart for the managed units.
- AE2. **Fedora operator notice:** Given a Fedora apply, when service enablement completes, then output tells the operator to restart services manually after apply or reboot.
- AE3. **Jetson operator notice:** Given a Jetson render, when the gated installer completes successfully, including when packages are already current, then output tells the operator to restart affected services manually after apply or reboot.
- AE4. **Network connection safety:** Given an active NetworkManager host, when the network installer runs, then it does not call `systemctl restart` or `systemctl reload NetworkManager` and prints the manual-action notice instead.
- AE5. **Existing package behavior:** Given a missing declared package, when either package installer runs, then the existing apt or dnf installation path remains present and unchanged apart from the service-deferral handling.

### Scope Boundaries

**Included**

- The requested Fedora and Jetson installer templates.
- The Linux network installer that currently performs the explicit NetworkManager, systemd-resolved, and tailscaled mutations named by the problem.
- Render and shell-fixture coverage and comments that describe the new deferral behavior.

**Deferred**

- Preventing service restarts performed inside third-party apt/dnf package maintainer scripts, indirect activation from `timedatectl set-ntp true`, or the required one-time Tailscale daemon startup. The repository cannot guarantee those paths without changing unrelated package, time, or authentication behavior.
- Automatic discovery of exactly which package changed and which service needs a restart. The notices use the affected service set and give the operator a safe manual choice.
- Reworking firewalld's own `--reload`; it is not a systemd service restart and remains the existing runtime-versus-permanent reconciliation mechanism.

**Outside this work**

- Live deployment to `$HOME` or any host.
- Changes to macOS, Windows, desktop-session services, or the haptic daemon.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Defer explicit live service mutations in the targeted installers.** (session-settled: user-directed — chosen over restarting or reloading affected services during apply: live network mutations can break the connection carrying the apply.) Fedora service units remain enabled for future boots, the network installer leaves service activation to the operator, and unrelated package, time, and one-time authentication paths keep their existing contracts.
- KTD2. **Keep the notices inline in the two requested OS installers and the network installer.** (session-settled: user-directed — chosen over adding a new shared template partial: the wording is small, the three scripts have different affected-service context, and inline text keeps each rendered script self-contained.)
- KTD3. **Test rendered output and source-level absence of the removed commands.** (session-settled: user-approved — chosen over a live service fixture: a live fixture would be privileged, network-sensitive, and nondeterministic, while rendered-shell assertions prove the repository contract without touching a host.)

### High-Level Technical Design

The Fedora helper keeps its unit-presence guard but changes the normal path from `enable --now` to enable-only. Calls that previously requested immediate activation no longer pass a `now` mode. The existing time configuration and the one-time Tailscale authentication path remain outside this targeted deferral, and the operator notice is emitted after the service-enablement phase.

The Jetson template adds an operator notice after the existing gated installation flow on every successful run. It does not add a service command, and no changed-state flag is required.

The network template keeps configuration writes and firewalld reconciliation but replaces the explicit restart loop and `NetworkManager` reload action with a notice-only applicability check using the existing NetworkManager skip site. Its notice names `systemd-resolved`, `NetworkManager`, and `tailscaled` so the operator has an actionable manual path. The existing skip-declaration row remains valid because the check still gates the notice when NetworkManager is not running.

### Sequencing and Dependencies

1. Change Fedora service activation and its notice.
2. Add the Jetson notice without introducing service control.
3. Replace network service mutations with the notice-only path.
4. Update render fixtures, expected Fedora render hashes, and behavior comments.
5. Render all three scripts and run the targeted CI fixtures before broader repository checks.

### System-Wide Impact

The apply remains able to install packages and write configuration, but targeted service changes may not be active until the operator restarts them or reboots. The notices are therefore part of the operational contract. Network connectivity is protected from the repository's explicit restart and reload calls at the cost of delayed activation; package, time, and one-time authentication side effects remain explicit boundaries.

### Risks and Mitigations

- **Risk:** A user assumes configuration is active because the apply succeeded. **Mitigation:** Print explicit notices in the Fedora, Jetson, and network paths, naming the manual restart or reboot action.
- **Risk:** A removed command leaves stale comments or an invalid applicability guard. **Mitigation:** Keep the existing NetworkManager skip site, update rendered fixtures, and update script headers in the same change.
- **Risk:** A package maintainer script or indirect command still activates a service. **Mitigation:** State that boundary in the plan and avoid claiming repository-level control over third-party or unrelated activation paths.

### Research Breadcrumbs

- `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl:562-593` contains the unit-presence guard and `enable --now` path.
- `.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl:40-152` contains the Jetson package and desktop-app flow with no current service notice.
- `.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl:99-153` contains the explicit service restart loop and NetworkManager reload.
- `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl:29-31` is a required one-time daemon startup boundary and is not changed by this plan.
- `.ci/test-fedora-fact-block-baseline.sh` and `.ci/test-jetson-installer-render.sh` are the existing deterministic render fixtures to extend.
- `.ci/skip-declaration-site-matrix.yaml` records the existing NetworkManager applicability skip site, which remains valid for the notice-only path.

---

## Implementation Units

### U1. Defer Fedora service activation

- **Goal:** Keep Fedora service enablement persistent while removing explicit live starts from the target helper and adding the operator notice.
- **Requirements:** R1, R4, R7, R8.
- **Files:** `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`; `.ci/test-fedora-fact-block-baseline.sh`.
- **Approach:** Simplify `enable_unit` to the enable-only behavior or route every call through the existing enable-only branch. Preserve unit discovery, sudo usage, error tolerance, MOK ordering, time configuration, one-time auth behavior, and all package gates. Emit one notice after `enable_services` completes. Update the normalized Fedora render hash and add assertions for enable-only commands and notice text.
- **Test scenarios:**
  - Fedora render contains `systemctl enable` but not `systemctl enable --now` in the target helper.
  - Fedora render contains the manual restart-or-reboot notice.
  - Existing keyd, tailscaled, systemd-timesyncd, and NVIDIA unit guards remain in the render.
  - The baseline fixture still passes after its expected hash is updated for the intentional behavior change.
- **Verification:** Run `.ci/test-fedora-fact-block-baseline.sh`, then render the Fedora template with `chezmoi execute-template` and run `bash -n` on the output.

### U2. Add Jetson operator guidance

- **Goal:** Tell Jetson operators how to activate service changes without adding a live service mutation.
- **Requirements:** R3, R5, R7, R8.
- **Files:** `.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl`; `.ci/test-jetson-installer-render.sh`.
- **Approach:** Add a concise notice at the end of the existing gated installer flow on every successful run, including no-op package paths. Keep apt package checks, the L4T source preflight, signature verification, extraction, desktop-entry installation, and `after-install.sh` message unchanged. Do not add a changed-state flag or service command.
- **Test scenarios:**
  - Jetson-true render is valid shell and includes the manual restart-or-reboot notice.
  - Jetson-false render remains empty.
  - The render contains no systemctl restart, reload, or enable-now command.
  - Existing JetPack, signature, and desktop-entry assertions remain present.
- **Verification:** Run `.ci/test-jetson-installer-render.sh` and inspect the rendered shell with `bash -n`.

### U3. Defer network service activation

- **Goal:** Stop the network installer from changing targeted live service state during apply while preserving network configuration reconciliation.
- **Requirements:** R2, R3, R6, R7, R8.
- **Files:** `.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl`; `.ci/test-fedora-fact-block-baseline.sh`; `.ci/skip-declaration-site-matrix.yaml`.
- **Approach:** Remove the explicit restart loop for `systemd-resolved`, `NetworkManager`, and `tailscaled`, and replace the `NetworkManager` reload helper with a notice-only applicability check that keeps the existing `networkmanager-not-running` skip declaration valid. Keep resolver symlink, stale-drop-in cleanup, and firewalld permanent/runtime reconciliation. Add the network-specific notice after the configuration writes. Extend the existing Fedora render fixture instead of adding an uninvoked standalone test, and assert the three service names, notice text, and absence of the removed restart/reload calls.
- **Test scenarios:**
  - Rendered network script contains no `systemctl restart` for the affected services.
  - Rendered network script contains no `systemctl reload NetworkManager`.
  - Existing firewalld and resolver commands remain present.
  - The existing NetworkManager-not-running skip site still renders and the skip-declaration validation accepts the unchanged matrix.
- **Verification:** Run `.ci/test-fedora-fact-block-baseline.sh` and `.ci/check-skip-declarations.sh`.

### U4. Align operational text and repository checks

- **Goal:** Keep comments, instructions, and the CI contract consistent with deferred service activation.
- **Requirements:** R3, R7, R8.
- **Files:** `AGENTS.md`; `.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl`; `.ci/test-fedora-fact-block-baseline.sh`; `.ci/test-jetson-installer-render.sh`.
- **Approach:** Replace comments that claim the network script restarts or reloads the affected services with the deferred-activation behavior. Update only the relevant baseline and fixture assertions. Do not add a deployment script or a teardown path.
- **Test scenarios:**
  - Repository comments and tests describe manual restart or reboot as the activation path.
  - The existing NetworkManager skip assertion remains present and does not require the removed reload helper.
  - `git diff --check` reports no whitespace errors.
- **Verification:** Run the targeted fixtures, the skip-declaration check, and `git diff --check`.


---

## Verification Contract
| Check | Applies when | Pass signal |
| --- | --- | --- |

| `.ci/test-fedora-fact-block-baseline.sh` | Always | Fedora and network renders pass; service notices and enable-only assertions pass. |
| `.ci/test-jetson-installer-render.sh` | Always | Jetson gate, signature, package, desktop-entry, and notice assertions pass. |
| `.ci/check-skip-declarations.sh` | Always | Skip matrix matches the retained NetworkManager applicability site. |
| `bash -n` on each rendered script | Always | All generated scripts parse successfully. |
| `git diff --check` | Before delivery | No whitespace errors. |
| `git status --short --branch` and scoped diff review | Before delivery | Only planned source, fixture, metadata, and plan files changed. |

The test fixtures must use scratch source and destination paths, a newline-free `op` stub, and no live service or network mutation. The verification must not deploy to `$HOME`.

---

## Definition of Done

- The Fedora and Jetson templates named in the request print clear manual restart-or-reboot guidance.
- The Fedora `enable_services` path enables units for persistence without issuing explicit starts during apply; indirect activation from the existing time command remains the documented boundary.
- The network installer no longer explicitly restarts or reloads `systemd-resolved`, `NetworkManager`, or `tailscaled` during apply.
- Package installation, host gates, firewalld reconciliation, resolver-link handling, and existing Jetson signature checks remain intact.
- Render fixtures prove the notices, command absence, shell validity, and gate behavior.
- Skip-declaration metadata and operational comments match the new control flow.
- The targeted verification contract and `git diff --check` pass.
- No abandoned helper, stale assertion, placeholder, or TODO remains in the diff.
