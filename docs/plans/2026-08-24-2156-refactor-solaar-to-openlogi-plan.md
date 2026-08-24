---
title: Solaar to OpenLogi Migration - Plan
type: refactor
date: 2026-08-24
topic: solaar-to-openlogi
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
deepened: 2026-08-24
---

# Solaar to OpenLogi Migration - Plan

## Goal Capsule

- **Objective:** Logitech devices on every managed host are configured by one cross-platform tool declared in the dotfiles, with no Solaar surface remaining and the custom haptic stack still working alongside it.
- **Means:** Remove Solaar end to end; install OpenLogi through the release-locked Fedora direct-RPM surface and the macOS `openlogi` cask; assert declared config per key through `settings-reconcile` while the agent is stopped (KTD1, KTD2, KTD3).
- **Product authority:** The Product Contract Key Decisions (fresh start, keep mxm4-haptic, drop the panel battery indicator, fully declarative device config, per-key assertion into agent-owned config) outrank every planning choice below.
- **Stop conditions:** runtime evidence that mxm4-hapticd and openlogi-agent cannot share the receiver (KTD6's experiment fails and no daemon change is viable); upstream renaming the OpenLogi RPM asset in a way the release lock cannot express.
- **Execution profile:** `ce-work` under the `lfg` pipeline; units land as atomic commits on one branch.

---

## Product Contract

Product Contract restructured, no scope change: Outstanding Questions resolved in place (OQ1 became KTD6; OQ2 moved to Deferred to Implementation) and R1's wording clarified (the capability's Fedora disposition is re-pointed, not deleted); every R/AE-ID and Key Decision is otherwise unchanged.

### Summary

Remove Solaar from the dotfiles completely — packages, device data, rules, scripts, GNOME extension, udev rule, CI coverage — and adopt OpenLogi as the sole Logitech device manager on Fedora and macOS.
OpenLogi's configuration is managed declaratively by chezmoi through per-key assertion, starting from fresh minimal content: nothing is ported from the Solaar setup.
The mxm4-haptic crate stays and must coexist with the OpenLogi agent.

### Problem Frame

Solaar is Linux-only, so the current setup splits Logitech management across two vendor stacks: Solaar on Fedora, Logi Options+ on macOS.
The user wants one tool and one configuration model across both platforms.
OpenLogi is a native, local-first Options+ alternative that ships for macOS, Linux, and Windows, so it can own both sides.
Solaar's footprint in this repo has also grown costly to carry: a device-settings manifest, a rules engine template with per-desktop D-Bus actions, a config-patching script, a GNOME Shell extension installer, a udev rule, and CI coverage — all for a tool the user no longer wants to run.

### Key Decisions

- **Fresh start over parity port** (session-settled: user-directed — chosen over porting Solaar settings and gesture rules: a clean rebuild in OpenLogi, stated twice). Governs R12.
- **mxm4-haptic kept alongside OpenLogi** (session-settled: user-directed — chosen over retiring it: OpenLogi cannot trigger arbitrary haptic waveforms from bindings or CLI). Governs R13, R14, R15.
- **GNOME panel battery indicator dropped** (session-settled: user-directed — chosen over finding a replacement: OpenLogi has no Linux tray or panel battery surface). Governs R2.
- **Fully declarative device config** (session-settled: user-directed — chosen over GUI-owned config: matches the dotfiles' data-driven ethos). Governs R9, R10, R11.
- **Per-key assertion into the agent-owned config** (session-settled: user-approved — chosen over templating the whole file: the OpenLogi agent rewrites `config.toml` on every change, so wholesale ownership would fight it; reuses the omp `config.yml` assertion precedent). Governs R9, R10.

### Requirements

**Solaar removal**

- R1. Remove the `solaar` and `solaar-udev` DNF packages and replace the Solaar Fedora disposition of the `logitechGestures` capability with OpenLogi in `.chezmoidata/packages.yaml`; an applied host ends with no Solaar package installed.
- R2. Delete Solaar's managed source state: `.chezmoidata/solaar.yaml`, `dot_config/solaar/rules.yaml.tmpl`, `.chezmoiscripts/30-linux/run_onchange_after_config-solaar.sh.tmpl`, and the GNOME extension installer `.chezmoiscripts/50-linux-gnome/run_after_install-gnome-solaar-extension.sh.tmpl` with its `gnome.shellExtensions.solaar` data entry.
- R3. Remove the deployed `/etc/udev/rules.d/70-uinput-solaar.rules` through the `.chezmoidata/system.yaml` `removed:` manifest mechanism, not a teardown script; OpenLogi's own RPM ships the replacement udev rules.
- R4. Remove Solaar's infrastructure entries: the `solaar-present` capability in `.chezmoidata/.capability-registry.tsv` and the Solaar reference in `.chezmoidata/facts.yaml`.
- R5. Remove Solaar's CI coverage (`.ci/skip-declaration-site-matrix.yaml`, `.ci/test-extension-retry.sh`, `.github/workflows/render-dotfiles.yml`), including the sidevesh GNOME extension's test fixtures; add OpenLogi render/CI coverage only where the new managed surface earns it.
- R6. Update every doc and comment that presents Solaar as the Logitech manager (`AGENTS.md` script-tree and data tables, `crates/mxm4-haptic/` docs) to describe the OpenLogi ownership.

**OpenLogi installation**

- R7. On Fedora, install a version-pinned OpenLogi RPM resolved through the release lock (`.chezmoidata/releases.json` via `packages/release-lock`, consumed through `.chezmoitemplates/release-lock-ref.tmpl`); no RPM repo or COPR exists upstream, so the installer follows the direct-download precedent.
- R8. On macOS, replace the `logi-options-plus` cask with the `openlogi` cask in the `logitechGestures` capability; the Ubuntu/Jetson disposition stays `notApplicable`.
- R9. On Linux, the `openlogi-agent` systemd user service is enabled and running after apply.

**Declarative configuration**

- R10. Chezmoi asserts each declared OpenLogi key into the live `config.toml` while the agent is stopped, following the per-key assertion precedent of `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`; keys the dotfiles do not declare stay owned by the OpenLogi GUI.
- R11. Declared device blocks are keyed by OpenLogi's physical device identity (receiver UID/slot or serial), declared per host in chezmoi data; replacing a mouse or receiver means a data edit, by accepted design.
- R12. No Solaar content is ported: the initial declared set contains no gesture bindings, button remaps, or device settings translated from `.chezmoidata/solaar.yaml` or `dot_config/solaar/rules.yaml.tmpl`.

**mxm4-haptic coexistence**

- R13. The mxm4-haptic daemon, notification bridge, and OMP event plugin keep working on a host where `openlogi-agent` owns the primary HID++ session.
- R14. The HID++ software-ID collision risk is resolved: the daemon's fixed `0x0E` sits inside OpenLogi's dynamic 1–15 lease pool, so the daemon stops hardcoding a collidable ID or coexistence is otherwise verified safe with evidence.
- R15. The Solaar-rules trigger path for haptic pulses is removed with `rules.yaml.tmpl`; the `mxm4-haptic` client remains for future OpenLogi `RunShellCommand` bindings, which are out of this plan's scope.

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R9.**
  - **Given** a Fedora host with Solaar installed and paired devices,
  - **When** the migration apply runs,
  - **Then** `command -v solaar` finds nothing, `~/.config/solaar/` is no longer managed state, the Solaar udev rule is gone from `/etc`, and `openlogi-agent` is active with the declared config keys asserted.
- AE2. **Covers R10.**
  - **Given** a declared key whose value the user changed in the OpenLogi GUI,
  - **When** apply runs,
  - **Then** the declared value is re-asserted and the user's undeclared GUI changes survive.
- AE3. **Covers R13, R14.**
  - **Given** `openlogi-agent` and `mxm4-hapticd` both running,
  - **When** a desktop notification or OMP event fires,
  - **Then** the haptic pulse plays and neither agent's HID++ traffic satisfies the other's pending requests.

### Success Criteria

- One tool manages Logitech devices on both Fedora and macOS; a host's Logitech story is readable from chezmoi data alone.
- `chezmoi apply` converges clean on the KDE and GNOME hosts, and `render-dotfiles.yml` plus `ci.yml` are green after the change.
- Device battery remains reachable via `openlogi list` and the OpenLogi GUI.

### Scope Boundaries

- Porting any Solaar device settings, gesture rules, or desktop actions — excluded by the fresh-start decision; bindings are rebuilt in OpenLogi when wanted.
- A GNOME panel battery indicator — dropped; OpenLogi has no Linux tray or panel surface.
- Per-app profiles and OpenLogi's `openlogi-frontmost` GNOME Shell extension — available upstream, not installed initially.
- Retiring or replacing mxm4-haptic, and adopting OpenLogi's Actions Ring — neither is this work.
- Windows — no current Windows Logitech management exists to migrate.
- Automated uninstall of Solaar RPMs or Logi Options+ during apply — handled by operator decommission steps (KTD4), never by teardown scripts.

### Dependencies / Assumptions

- OpenLogi publishes no RPM repo or COPR; Fedora version freshness depends on the hourly release-lock refresh workflow picking up new GitHub releases.
- OpenLogi and Solaar cannot run at the same time (upstream docs: they fight over HID++ access), so removal and installation land in the same apply cycle.
- Assumption: the udev rules shipped in OpenLogi's RPM cover everything the repo's retired `70-uinput-solaar.rules` provided for the remaining stack (uinput access for the OpenLogi hook).

### Outstanding Questions

None blocking. OQ1 (HID++ software-ID coexistence) is resolved as KTD6 with a runtime verification owed by U6. OQ2 (the exact initial declared key set) is deferred to implementation under R12's fresh-start constraint.

### Sources / Research

- OpenLogi configuration reference and schema (`config.toml` is agent-rewritten, device blocks hardware-keyed): <https://openlogi.org/docs/configurations>
- OpenLogi Linux install (RPM direct download, udev rules, agent service; "Quit Solaar" coexistence note): <https://openlogi.org/docs/installation> and `docs/INSTALL-linux.md` in <https://github.com/AprilNEA/OpenLogi>
- OpenLogi sw_id lease pool: `crates/openlogi-hid/src/transport.rs` in <https://github.com/AprilNEA/OpenLogi>; mxm4-haptic fixed ID: `crates/mxm4-haptic/src/lib.rs`
- Repo precedents: `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` (per-key assertion), `.chezmoiscripts/00-tools/run_onchange_after_flutter.sh.tmpl` (script-installed direct-download tool), `.chezmoidata/system.yaml` (`removed:` manifest)

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Fedora install rides the `packages.yaml` direct-RPM surface in the main Fedora pass, fed by the release lock** — over a Flutter-style dedicated phase script. The Fedora pass already owns sudo handling and `rpm -q` version-pin checking (`.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`, direct-RPM precedent at `.chezmoidata/packages.yaml:391-403`); a dedicated phase script exists for tools that rewrite their own tree, which an RPM does not. `packages.yaml` is static data and cannot invoke templates, so the pass's template gains the OpenLogi URL and digest lookup through `release-lock-ref.tmpl` plus a digest check on the downloaded RPM — the existing direct-RPM helper takes plain URLs and verifies no checksum today. Governs U1, U2.
- KTD2. **Config assertion reuses `packages/settings-reconcile` for in-place TOML leaf reconciliation** (session-settled: user-approved — chosen over templating the whole file: the OpenLogi agent rewrites `config.toml` on every change, so wholesale ownership would fight it; reuses the omp `config.yml` assertion precedent). Governs R9, R10; lands in U3. The how-level choice is `settings-reconcile` over a new writer: it already preserves undeclared keys, creates the file atomically on fresh hosts, and validates its contract (`packages/settings-reconcile/src/reconcile.ts`), as proven by `run_after_config-aoe.sh.tmpl`.
- KTD3. **The assertion script is a `run_after_` script that stops `openlogi-agent` when active, reconciles, and restarts it, with an EXIT trap that restores the prior service state on any failure.** `run_after_` because live agent rewrites never change chezmoi source fingerprints, so `run_onchange_` would miss drift until data changes. The 2026-08-15 deferral learning scopes to system/network services whose restart drops provisioning or SSH; it does not govern a user-session desktop utility, and OpenLogi overwrites hand edits made while its agent runs, so the stop is load-bearing. The trap guarantees the daemon is never left stopped by a failed assert. Governs U3.
- KTD4. **Existing-host migration hazards are handled by operator decommission documentation plus `.chezmoiremove`, never by teardown scripts.** `chezmoi apply` does not uninstall removed packages or kill running daemons; the ydotool precedent (`docs/decommission/ydotool.md`) is the sanctioned channel, and the repo prohibits teardown scripts. `.chezmoiremove` covers deployed targets (the rendered `~/.config/solaar/rules.yaml`). Governs U4, U7.
- KTD5. **Declared OpenLogi config lives in a new `.chezmoidata/openlogi.yaml`**, taking over the retired `solaar.yaml`'s single-source-of-truth role: keys and per-host device blocks are data, the script is a dumb reconciler. Governs U3.
- KTD6. **Keep mxm4-hapticd's software ID `0x0E`; rely on reply classification plus a runtime experiment before changing the daemon.** The fixed ID is used only during sub-second discovery windows; haptic playback is fire-and-forget with software ID 0 and awaits no reply, and mismatched discovery replies are already classified `NotForUs` (`crates/mxm4-haptic/src/lib.rs`). OpenLogi leases IDs from the full 1–15 pool with no exclusion option, so no fixed value is provably collision-free; resilience is the only available posture without an upstream change. Governs R14; U6 owes the AE3 runtime evidence.

### High-Level Technical Design

The only cross-process lifecycle in this plan is the config assertion (KTD3):

```mermaid
sequenceDiagram
    participant C as chezmoi apply
    participant S as run_after_config-openlogi
    participant A as openlogi-agent
    participant T as config.toml
    C->>S: run every apply
    S->>A: systemctl --user is-active?
    alt agent active
        S->>S: install EXIT trap (restore prior state)
        S->>A: stop
    end
    S->>T: settings-reconcile: assert declared leaves, preserve undeclared
    alt agent was active
        S->>A: start
    end
    S-->>C: converged (declared keys owned; GUI keys intact)
```

### Assumptions

- A1. An existing-host apply does not uninstall Solaar RPMs, remove the Logi Options+ cask, or kill their running daemons; the operator performs those steps from `docs/decommission/solaar.md` (KTD4).
- A2. `brew bundle` never uninstalls the retired `logi-options-plus` cask; macOS removal is a documented manual step (KTD4).
- A3. The 2026-08-15 service-restart deferral learning does not cover user-session desktop utilities, so KTD3's stop/assert/start is permitted (verified against the learning's plan text and both service precedents).
- A4. OpenLogi's RPM ships udev rules that cover hidraw, uinput, and input-node access, so retiring `70-uinput-solaar.rules` strands nothing the remaining stack needs (per the Product Contract's stated assumption).

### Risks & Dependencies

- **Upstream asset rename breaks the lock refresh.** OpenLogi's RPM name (`openlogi-<tag>-linux-<arch>.rpm`) is pinned in the `packages/release-lock` registry with test coverage (U1); a rename fails the hourly refresh loudly, never silently.
- **Ungated release-lock lookups break non-Fedora renders.** Every `release-lock-ref.tmpl` call for OpenLogi stays inside the Fedora OS gate, because the lock carries no darwin or ubuntu-arm64 RPM entries (U2).
- **Dual-manager window on existing hosts.** Between the migration apply and the operator's decommission steps, Solaar or Options+ may still run and fight openlogi-agent for HID++; the decommission doc leads with stopping them (KTD4, U7).
- **Software-ID cross-talk.** Bounded by KTD6 to discovery windows and covered by AE3; the daemon changes only if the runtime experiment shows collisions.
- **Hardware replacement churns declared device blocks.** Accepted by R11; the data edit is the price of physical-key identity.

### Open Questions

**Resolved during planning**

- Running Solaar on existing Fedora hosts during the migration apply — resolved by KTD4 (decommission doc, no teardown automation).
- Stopping openlogi-agent during apply — resolved by KTD3 (permitted; trap-protected).
- macOS Options+ removal — resolved by KTD4 / A2 (manual, documented).
- Stale GNOME extension state (enabled-extensions entry, extension directory) — resolved by KTD4 (manual cleanup in the decommission doc); chezmoi-managed files go to `.chezmoiremove`.

**Deferred to implementation**

- The macOS agent stop/start mechanism for the assertion script (LaunchAgent label and reload behavior are inspected on a Mac at implementation time; Linux uses `systemctl --user` per KTD3).
- The exact initial declared key set in `.chezmoidata/openlogi.yaml`, minimal per R12 (candidates: `app_settings` values only; no device blocks until the operator configures devices in the GUI once and reads the physical keys back).

---

## Implementation Units

### U1. Release-lock registry entry for OpenLogi

- **Goal:** The release lock resolves and pins OpenLogi's Fedora RPMs.
- **Requirements:** R7
- **Dependencies:** none
- **Files:** `packages/release-lock/src/registry.ts`, `packages/release-lock/src/registry.test.ts` (or the package's existing test file), `.chezmoidata/releases.json` (regenerated, never hand-edited)
- **Approach:** Add a `githubRelease` `ToolSpec` for `AprilNEA/OpenLogi` whose asset selector emits `openlogi-<tag>-linux-<arch>.rpm` for linux amd64/arm64 and `null` for other platforms, so the lock omits them. Regenerate the lock through the package's own CLI.
- **Patterns to follow:** Existing `githubRelease` entries in the registry; the `buf` arch-naming lesson recorded in `AGENTS.md` (upstream arch spellings differ per platform).
- **Test scenarios:**
  - Registry test: the selector returns `openlogi-v0.7.10-linux-x86_64.rpm`-shaped names for linux amd64 and the `aarch64` variant for arm64.
  - Registry test: the selector returns `null` for darwin and windows platforms, so the lock carries no such entries.
  - Error path: a release missing the expected RPM asset fails resolution loudly (the lock's declared-target hard-error rule).
- **Verification:** The package's test suite passes and the regenerated `.chezmoidata/releases.json` carries OpenLogi entries with URL and digest for both linux platforms.

### U2. Package authority switch to OpenLogi

- **Goal:** Fedora installs the locked OpenLogi RPM and macOS installs the `openlogi` cask; Solaar leaves the package authority.
- **Requirements:** R1, R7, R8
- **Dependencies:** U1
- **Files:** `.chezmoidata/packages.yaml`, `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` (mandatory per KTD1: gains the release-lock lookup and digest verification)
- **Approach:**
  1. Delete the `solaar` and `solaar-udev` rows from the Fedora package list.
  2. Declare the OpenLogi RPM on the Fedora direct-RPM surface; the pass's template resolves the URL and digest through `release-lock-ref.tmpl` inside the Fedora gate and verifies the downloaded RPM, because the static YAML cannot carry template calls (KTD1).
  3. Re-point the `logitechGestures` capability: Fedora disposition names the OpenLogi RPM, macOS cask becomes `openlogi`, sentinel becomes `openlogi`; the Ubuntu `notApplicable` entry and its reason stay.
- **Patterns to follow:** The direct-RPM rows at `.chezmoidata/packages.yaml:391-403` and the capability shape of the current `logitechGestures` entry.
- **Execution note:** This is mostly packaging/config; prefer render and dry-run verification over unit coverage.
- **Test scenarios:**
  - Render the Fedora pass on a fixture: the OpenLogi RPM appears with the locked version and digest; `solaar` strings are gone.
  - Render the macOS Homebrew pass: the Brewfile carries `cask "openlogi"` and no `logi-options-plus`.
  - Render on a non-Fedora Linux fixture and a container fixture: no OpenLogi lock lookup fires and rendering succeeds (covers the ungated-lookup risk).
- **Verification:** Rendered Fedora and macOS scripts show the switch; a scratch `chezmoi apply` diff against a fixture destination contains no Solaar package references.

### U3. OpenLogi config assertion

- **Goal:** Declared OpenLogi keys are asserted into the agent-owned `config.toml` on every apply, on Linux and macOS.
- **Requirements:** R9, R10, R11, R12 (session-settled declarative-config decision, per KTD2)
- **Dependencies:** U2 (the agent and its service exist on applied hosts)
- **Files:** `.chezmoidata/openlogi.yaml` (new), a new assertion script under `.chezmoiscripts/` placed per the repo's phase conventions (Linux phase certain; macOS placement decided at implementation), `.ci/test-*.sh` fixture coverage for the script, `.github/workflows/render-dotfiles.yml` render assertions
- **Approach:**
  1. Declare the initial key set in `.chezmoidata/openlogi.yaml` (KTD5); per R12 it starts minimal and carries no Solaar-derived content.
  2. The script follows the KTD3 lifecycle: detect agent state, trap-guard, stop when active, reconcile through `settings-reconcile` (KTD2), restart when it was active.
  3. On Linux it also enables `openlogi-agent.service` for the user (R9); macOS agent control is the deferred implementation question.
  4. Gate containers and headless hosts through the repo's capability/fact probes, exactly as the retired config-solaar script did.
- **Patterns to follow:** `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl` (settings-reconcile invocation), `run_after_config-omp-settings.sh.tmpl` (run-after lifecycle and bounded probes), the retired config-solaar script's gating.
- **Test scenarios:**
  - Fresh host fixture: no `config.toml` exists; the script creates it with the declared keys and starts/enables the agent (AE1's assertion half).
  - Drift fixture (AE2): a declared key differs in the live file and an undeclared GUI-written key exists; after the script, the declared key is re-asserted and the undeclared key is byte-identical.
  - Agent-active fixture: a stub `systemctl --user` reports active; the script stops and restarts the agent around the reconcile, and the stub log shows that order.
  - Failure path: make the reconciler fail with the agent stub active; the EXIT trap still restarts the agent and the script exits non-zero.
  - Container fixture: the script skips through its declared gate without touching services.
- **Verification:** The fixture harness passes, the render assertions pass in CI, and the second-apply-cleanliness metric holds (an unchanged second apply reruns nothing and rewrites nothing).

### U4. Solaar source removal

- **Goal:** Every managed Solaar surface leaves the source state, and the retired `/etc` file is reclaimed by manifest.
- **Requirements:** R2, R3, R4
- **Dependencies:** none (lands in the same change as U2/U3)
- **Files:** `.chezmoidata/solaar.yaml` (delete), `dot_config/solaar/rules.yaml.tmpl` (delete), `.chezmoiscripts/30-linux/run_onchange_after_config-solaar.sh.tmpl` (delete), `.chezmoiscripts/50-linux-gnome/run_after_install-gnome-solaar-extension.sh.tmpl` (delete), `.chezmoidata/gnome.yaml` (drop the `shellExtensions.solaar` entry and its comment), `.chezmoidata/.capability-registry.tsv` (drop `solaar-present`), `.chezmoidata/facts.yaml` (drop the Solaar mention), `system/linux/etc/udev/rules.d/70-uinput-solaar.rules` (delete), `.chezmoidata/system.yaml` (add the `removed:` entry), `.chezmoiremove` (add the deployed `~/.config/solaar/rules.yaml` target)
- **Approach:** Deletions only, plus the two manifest entries. The `system.yaml` `removed:` entry reclaims the deployed udev rule through the existing installer (KTD4 prohibits a teardown script).
- **Patterns to follow:** The existing `removed:` entries in `.chezmoidata/system.yaml` and the `.chezmoiremove` standing cases.
- **Test scenarios:**
  - Scratch apply against a fixture destination pre-seeded with the deployed rules file: after apply, the target tree contains no `.config/solaar` content.
  - `git grep -i solaar` over the source state returns only the decommission doc (U7), historical plans/solutions, and mxm4-haptic text handled by U6.
  - The system-files installer's `removed:` handling deletes a fixture `/etc` copy of the udev rule (existing harness pattern).
- **Verification:** No Solaar source remains outside the documented exceptions; the skip-declaration check passes with the retired script's sites gone (U5 keeps the matrix consistent).

### U5. CI coverage switch

- **Goal:** CI proves the new OpenLogi surface and stops proving Solaar.
- **Requirements:** R5
- **Dependencies:** U3, U4
  - **Files:** `.github/workflows/render-dotfiles.yml`, `.github/workflows/ci.yml`, `.ci/test-extension-retry.sh`, `.ci/skip-declaration-site-matrix.yaml`, new `.ci` fixture test for U3's script
- **Approach:**
  1. Delete the Solaar gesture-rules render step from `render-dotfiles.yml` and add render assertions for the U3 script (both OS renders; container gating).
  2. Remove the Solaar extension and its fixtures from `test-extension-retry.sh`; kimpanel and VSCodium coverage stays.
  3. Remove the four config-solaar sites and the GNOME-extension guard site from the skip-declaration matrix; register any skip sites the new scripts introduce (a `run_after_` script is lifecycle-exempt unless it inlines shared guards).
  4. Wire the new U3 fixture test into `.github/workflows/ci.yml` with the other `.ci` harnesses.
- **Patterns to follow:** The existing matrix entries and the retry-test fixture layout.
- **Test scenarios:** Covered by the harnesses themselves; the check is that `ci.yml` and `render-dotfiles.yml` pass with Solaar cases absent.
- **Verification:** Both workflows are green on the change, and `.ci/check-skip-declarations.sh` passes.

### U6. mxm4-haptic decoupling from Solaar

- **Goal:** The crate's docs and comments describe the OpenLogi world, and coexistence with openlogi-agent is verified at runtime.
- **Requirements:** R6 (crate docs), R13, R14, R15
- **Dependencies:** U3, U4 (U4 for source decoupling; U3 for the running openlogi-agent that AE3's runtime verification needs)
- **Files:** `crates/mxm4-haptic/Cargo.toml`, `crates/mxm4-haptic/src/lib.rs`, `crates/mxm4-haptic/src/bin/mxm4-haptic.rs`, `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs` (comments/docs only unless the runtime experiment forces a daemon change per KTD6)
- **Approach:** Reword Solaar-coupled prose: the client is no longer spawned by rules (R15); the `SW_ID` comment's collision rationale now names OpenLogi's lease pool instead of Solaar's `0x0B`; the daemon doc names openlogi-agent as the session co-tenant. No behavior change unless the AE3 experiment shows discovery collisions — then the smallest daemon change that restores reliable discovery lands here (KTD6).
- **Patterns to follow:** The crate's existing citation style for protocol claims.
- **Execution note:** The runtime check is the point of this unit; run it on a host with the MX Master 4 receiver, openlogi-agent, and mxm4-hapticd all live before declaring the unit done.
- **Test scenarios:**
  - Runtime (AE3): with both agents running, fire a notification through the bridge and confirm the pulse plays and the daemon log shows no unanswered-discovery retry storm.
  - Runtime: restart openlogi-agent several times so it re-leases software IDs, then re-fire; discovery still succeeds.
  - Build: the crate's existing build/test pass with comment-only changes.
- **Verification:** AE3 evidence is captured (daemon log excerpt) and R14's resolution is recorded; if a daemon change was needed, its test coverage lands with it.

### U7. Decommission doc and instruction updates

- **Goal:** Operators get the manual migration steps, and repo instructions describe the OpenLogi ownership.
- **Requirements:** R6 (AGENTS.md)
- **Dependencies:** U2, U3, U4 (the doc describes their final state)
- **Files:** `docs/decommission/solaar.md` (new), `AGENTS.md`
- **Approach:** The decommission doc follows the ydotool precedent shape (KTD4): pre-apply stop steps (quit Solaar on Fedora; quit Logi Options+ on macOS), package removal (`dnf remove solaar solaar-udev`; `brew uninstall --zap logi-options-plus`), GNOME extension cleanup (remove the `enabled-extensions` entry and the extension directory), and leftover `~/.config/solaar` removal. AGENTS.md edits: the script-tree table loses the Solaar mention and gains the U3 script, the data table swaps `solaar.yaml` for `openlogi.yaml`, and stale prose (GNOME pointer-speed comment naming the Solaar GUI, facts.yaml-adjacent descriptions) is updated.
- **Patterns to follow:** `docs/decommission/ydotool.md`.
- **Test expectation:** none — documentation; verified by review against R6's source list and by the doc matching the final applied state.
- **Verification:** A cold reader can migrate an existing host using only the doc, and no instruction text still names Solaar as the manager.

---

## Verification Contract

- Render every new or changed template through `chezmoi execute-template` with the repo's scratch/stub rig from `AGENTS.md` (`--source "$PWD"`, stub `op`, throwaway destination); scripts are compared as rendered text.
- Run the affected `.ci` harnesses: the U3 fixture test, `.ci/test-extension-retry.sh`, `.ci/check-skip-declarations.sh`, and the release-lock package tests for U1.
- `git diff --check`, `git status`, and a scope-limited diff review before commit, per the repo's verification rules.
- On push, both `render-dotfiles.yml` and `ci.yml` are watched to terminal success.
- Runtime evidence owed on a real host (not CI): AE1's converged state after the migration apply, and AE3's coexistence check from U6.
- Success signals from the Product Contract: clean second apply (`chezmoi diff` empty against scratch), no Solaar package or process on migrated hosts after the decommission steps, battery readable via `openlogi list`.

---

## Definition of Done

**Global**

- Every R-ID is satisfied or explicitly deferred with the deferral recorded in this plan.
- AE1 and AE2 are demonstrated (fixture/scratch), AE3 is demonstrated on real hardware.
- Both CI workflows are green; the idempotent-apply metric holds (second apply changes zero targets and reruns zero onchange scripts).
- No abandoned-attempt code, commented-out Solaar remnants, or dead fixtures remain in the diff.

**Per unit**

- U1: lock carries OpenLogi RPM entries for both linux arches; registry tests pass.
- U2: rendered Fedora/macOS scripts show the switch; non-Fedora renders are unaffected.
- U3: fixture harness proves fresh-create, drift re-assert with undeclared-key preservation, agent stop/start ordering, trap recovery, and container gating.
- U4: no Solaar source outside documented exceptions; `removed:` and `.chezmoiremove` entries land.
- U5: CI green with Solaar coverage absent and OpenLogi render coverage present.
- U6: crate docs name OpenLogi; AE3 evidence captured; any daemon change carries its own test.
- U7: decommission doc matches the final applied state; AGENTS.md tables current.
