---
title: GNOME Ubuntu LTS Workstation - Plan
type: feat
date: 2026-11-10
topic: gnome-ubuntu-lts-workstation
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# GNOME Ubuntu LTS Workstation - Plan

## Goal Capsule

- **Objective:** The owner can prepare, apply and check the repository's Linux workstation environment on standard Ubuntu Desktop (GNOME) 26.04 LTS, and the repository no longer claims or gates on Ubuntu Studio.
- **Means:** Swap the Studio-specific host evidence, entry points, terminal integration and documentation for their Ubuntu Desktop GNOME equivalents (KTD1–KTD5).
- **Product authority:** The owner directed the replacement and directed that the Ubuntu and Ubuntu Studio unification issue (#120) be closed as wontfix.
- **Execution profile:** One PR, implemented and shipped by the autonomous workflow. The owner performs OS installation and native acceptance on the target host.
- **Stop conditions:** Stop if the change would require supporting both flavors at once, or if the hook-free bootstrap boundary in `AGENTS.md` cannot be kept.
- **Open blockers:** None for code implementation. Native GNOME desktop, hardware and runtime acceptance stay unverified until the owner runs them on an eligible host.

---

## Product Contract

### Summary

Replace Ubuntu Studio 26.04 LTS with standard Ubuntu Desktop 26.04 LTS on GNOME as the only supported Linux workstation.
The host check, the provisioning and bootstrap entry points, the Ghostty default-terminal integration, the readiness report, the package declaration and the documentation all move to the GNOME target.
The release and architecture stay 26.04 LTS on amd64.

### Problem Frame

PR #121 added Linux workstation support for Ubuntu Studio only.
Its host check requires an `ubuntustudio-desktop` metapackage, its terminal integration writes KDE `kdeglobals` keys, and its guide tells the owner not to use the generic Ubuntu Desktop image.
The owner now uses GNOME Ubuntu LTS instead, so every one of those gates rejects the machine the owner will actually run.

### Key Decisions

- **Support GNOME Ubuntu LTS instead of Ubuntu Studio.** Governs R1–R10. (session-settled: user-directed — chosen over supporting Ubuntu and Ubuntu Studio through a shared `bootstrap-ubuntu.sh` as issue #120 proposed: the owner asked for GNOME Ubuntu LTS in place of Studio and for #120 to be closed as wontfix.)

### Requirements

**Host eligibility**

- R1. A host is supported when it is Linux, `ID=ubuntu`, `VERSION_ID=26.04`, dpkg architecture `amd64`, and has an installed `ubuntu-desktop` or `ubuntu-desktop-minimal` metapackage.
- R2. A host without either metapackage is unsupported, including a host that has only an `ubuntustudio-desktop` metapackage.
- R3. Desktop session evidence is reported separately from host support and passes when `XDG_CURRENT_DESKTOP` contains `GNOME` in a `wayland` or `x11` session.

**Entry points**

- R4. Provisioning and bootstrap run from `provision-ubuntu.sh` and `bootstrap-ubuntu.sh`, with the behavior the Studio entry points have today; the Studio-named files no longer exist.

**Terminal and desktop integration**

- R5. Explicit application makes Ghostty the default terminal by placing its installed desktop entry first in the user's `ubuntu-xdg-terminals.list`, keeping the other entries.
- R6. Status reports a pending action when the `xdg-terminal-exec` dispatcher does not select Ghostty, and never writes.
- R7. Explicit application installs the GNOME pinentry and the terminal dispatcher instead of the Qt pinentry.

**Readiness and documentation**

- R8. The read-only readiness report checks GNOME evidence and commands, and names GNOME acceptance checks in its pending items.
- R9. The setup guide, README, guides, maintenance notes and harness instructions describe Ubuntu Desktop 26.04 LTS on GNOME, with a verified download from the Ubuntu release directory.
- R10. No managed file, test or guide outside historical plan records names Ubuntu Studio, KDE Plasma, Dolphin, `kdeglobals`, or the #120 consolidation follow-up as current behavior.

**Existing hosts**

- R11. Applying the new source on a host that was configured under the Studio support removes nothing: existing `kdeglobals` keys and the installed `pinentry-qt` package stay as they are.

### Scope Boundaries

- Ubuntu 24.04 LTS and arm64 workstations stay unsupported. The validated tool, package-source and minikube matrix is 26.04 amd64.
- CI runner coverage does not change. Hosted Ubuntu runners have no `ubuntu-desktop` metapackage, so the Ghostty and desktop-backed T3 lanes stay excluded on them.
- The earlier plan record `.compound-engineering/artifacts/plans/2026-11-10-0927-feat-ubuntu-studio-workstation-plan.md` is kept unchanged as history.
- Considered and not built: an explicit blocker that rejects hosts carrying a Studio metapackage next to `ubuntu-desktop`. Such a host meets R1 and its GNOME session works with the GNOME integration; a report of a broken mixed-flavor host would change this.
- Considered and not built: cleanup of KDE terminal keys or removal of `pinentry-qt` on previously configured hosts. `AGENTS.md` forbids cleanup as a consequence of dropping support, and the leftovers are inert under GNOME.

### Assumptions

- "Ubuntu LTS" means the current LTS line the repository already validates, 26.04, not a multi-release matrix.
- "GNOME Ubuntu" means the standard Ubuntu Desktop flavor identified by its desktop metapackages, not any Ubuntu host that happens to run a GNOME session.
- The new entry points take the names issue #120 proposed, since the owner's wontfix concerns the dual-flavor unification, not the file name.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Identify the flavor by `ubuntu-desktop` or `ubuntu-desktop-minimal`.** This mirrors the existing Studio check in `scripts/linux-platform.py`, which reads `dpkg-query` status for two metapackages. It also keeps hosted CI runners unsupported, which the CI exclusions and `docs/maintenance/development-and-testing.md` rely on. The report's evidence key becomes `desktop_packages`. Implements the Key Decision governing R1–R3.
- KTD2. **Select the terminal through `xdg-terminal-exec`.** The repository shipped this for Ubuntu 26.04 GNOME before PR #121: `git show 'ef08e30^1:scripts/terminal-environment.sh'` holds the 26.04 branch that writes `$XDG_CONFIG_HOME/ubuntu-xdg-terminals.list` and verifies with `XTE_CACHE_ENABLED=0 xdg-terminal-exec --print-id`. Restore that mechanism and drop the `kwriteconfig6` and `kreadconfig6` path. Keep the current desktop-entry resolver, which matches an installed entry's `Exec` to the active Ghostty binary, as the source of the desktop ID in place of the older hardcoded `/snap/bin/ghostty` test.
- KTD3. **Keep the unconditional native-acceptance pending line on Linux.** `scripts/terminal-environment.sh status` cannot prove that Ctrl+Alt+T, a file-manager action or a `Terminal=true` launcher opened Ghostty. The line stays and names the GNOME checks. Status therefore still returns `2` on Linux when every inspected setting matches.
- KTD4. **Swap `pinentry-qt` for `pinentry-gnome3` and add `xdg-terminal-exec` in `home/.chezmoidata/linux.yaml`.** The managed agent configuration points at the repository's own `dotfiles-pinentry` with `/usr/bin/pinentry` as fallback (`home/.chezmoidata/gpg.yaml`), so only the package name changes. `scripts/linux-apps.py` installs missing packages only and never removes one, which satisfies R11.
- KTD5. **Rename files rather than alias them.** `bootstrap-ubuntu-studio.sh`, `provision-ubuntu-studio.sh` and `docs/setup/ubuntu-studio.md` move to `bootstrap-ubuntu.sh`, `provision-ubuntu.sh` and `docs/setup/ubuntu.md` with `git mv`. The credential guide anchor becomes `#ubuntu-native-credential-acceptance`. No redirect stub is kept, because the Studio support merged one PR ago and has no external consumers.

### Sources

- `scripts/linux-platform.py` — the single host probe every Linux action calls.
- Callers of the probe: `scripts/linux-apps.py`, `scripts/linux-build-environment.sh`, `scripts/install-ghostty.sh`, `scripts/terminal-environment.sh`, `scripts/linux-readiness.py`, `home/.chezmoiscripts/run_before_17-install-aria2.sh.tmpl`, `home/.chezmoitemplates/t3-code-desktop`.
- `git diff 'ef08e30^1' ef08e30 -- scripts/terminal-environment.sh tests/smoke_ghostty.py docs/guides/terminal.md` — the GNOME to KDE change this plan reverses for the 26.04 branch.
- `.compound-engineering/artifacts/solutions/` holds no entry on Linux desktop integration.

---

## Implementation Units

### U1. Host probe and its callers

- **Goal:** The shared probe accepts Ubuntu Desktop and rejects everything else, and every caller's message names the new target.
- **Requirements:** R1, R2, R3 (KTD1).
- **Dependencies:** None.
- **Files:** `scripts/linux-platform.py`, `scripts/linux-apps.py`, `scripts/linux-build-environment.sh`, `scripts/install-ghostty.sh`, `home/.chezmoitemplates/t3-code-desktop`, `tests/test_linux_platform.py`, `tests/test_linux_apps.py`, `tests/test_linux_build_environment.py`, `tests/test_ghostty_install.py`, `tests/test_t3_code_desktop.py`, `tests/test_t3_code_settings.py`.
- **Approach:**
  1. Replace `STUDIO_PACKAGES` with the two Ubuntu Desktop metapackages and rename the evidence key per KTD1.
  2. Reword blockers and the desktop detail to Ubuntu Desktop 26.04 LTS and GNOME; the release blocker keeps the 26.04.1-or-later media wording.
  3. Change the desktop check from `KDE` to `GNOME`.
  4. Reword caller failure messages and docstrings, and rename the `$studio` template variable in `home/.chezmoitemplates/t3-code-desktop`.
- **Patterns to follow:** The injected `system`, `os_release`, `environ` and `run` parameters of `inspect_host`, and the fixture style in `tests/test_linux_platform.py`.
- **Test scenarios:**
  - `ubuntu-desktop` installed, 26.04, amd64, `XDG_CURRENT_DESKTOP=ubuntu:GNOME`, `wayland` → supported, desktop `passed`.
  - Only `ubuntu-desktop-minimal` installed → supported.
  - Only `ubuntustudio-desktop` installed → unsupported with the metapackage blocker.
  - Version `24.04`, architecture `arm64`, non-Linux system → each unsupported with its own blocker.
  - Supported host with `XDG_CURRENT_DESKTOP=KDE`, or GNOME on a `tty` session → supported, desktop `pending`.
  - A metapackage in a removed state (`deinstall ok config-files`) → not counted as installed.
  - `dpkg` or `dpkg-query` raising or failing → unsupported, no exception.
- **Verification:** The Linux platform, apps, build-environment, Ghostty-install and T3 desktop test modules pass, and `git grep -i studio` over this unit's own files returns no match. The repository-wide check belongs to U5.

### U2. Entry points

- **Goal:** Provisioning and bootstrap run under Ubuntu names.
- **Requirements:** R4 (KTD5).
- **Dependencies:** U1.
- **Files:** `bootstrap-ubuntu.sh` and `provision-ubuntu.sh` (renamed from the `-studio` files), `tests/test_linux_bootstrap.py`.
- **Approach:** Move both files with history, then reword usage lines, failure prefixes and the closing hints, which name each other. Behavior and ordering stay the same.
- **Test scenarios:**
  - Existing bootstrap and provisioning scenarios pass against the new file names.
  - An unsupported host leaves the home directory unchanged for both entry points, and the output names the `ubuntu-desktop` blocker.
  - `bootstrap-ubuntu-studio.sh` and `provision-ubuntu-studio.sh` do not exist in the tree.
- **Verification:** `tests/test_linux_bootstrap.py` passes and both scripts pass `sh -n`.

### U3. GNOME terminal selection and packages

- **Goal:** Explicit application selects Ghostty through the Ubuntu dispatcher and installs the GNOME-side packages.
- **Requirements:** R5, R6, R7, R11 (KTD2, KTD3, KTD4).
- **Dependencies:** U1.
- **Files:** `scripts/terminal-environment.sh`, `home/.chezmoidata/linux.yaml`, `tests/test_terminal_environment.py`, `tests/smoke_ghostty.py`, `tests/test_linux_apps.py`.
- **Approach:**
  1. Replace the KDE read/write loop with the dispatcher list write and `--print-id` check from KTD2. Write through a temporary file in the same directory and replace only when content differs.
  2. Fail when `xdg-terminal-exec` is missing, as the pre-#121 script did.
  3. Reword the pending line per KTD3 to name Ctrl+Alt+T, the Files terminal action and a `Terminal=true` launcher.
  4. Update package names per KTD4.
  5. In `tests/smoke_ghostty.py`, set `XDG_CURRENT_DESKTOP=ubuntu:GNOME` and `XTE_CACHE_ENABLED=0` for the temporary account and assert the dispatcher's selected ID instead of `kreadconfig6` values.
- **Execution note:** Rewrite the KDE fixture command in `tests/test_terminal_environment.py` as an `xdg-terminal-exec` fixture first, so the new scenarios fail before the script changes.
- **Patterns to follow:** The pre-#121 26.04 branch named in KTD2, and the fixture command dispatcher in `tests/test_terminal_environment.py`.
- **Test scenarios:**
  - Apply with no list file → creates `ubuntu-xdg-terminals.list` with the Ghostty desktop ID as its only line.
  - Apply with a list holding other terminals and Ghostty lower down → Ghostty first, the others kept in order, no duplicate.
  - Apply twice → the second run leaves the file's content and modification time unchanged.
  - Status when the dispatcher prints another terminal → exit `2` with the pending line, and the list file is not written.
  - Status when everything matches → exit `2` with only the native-acceptance pending line.
  - A retained Snap installation → the list holds `ghostty_ghostty.desktop`.
  - No desktop entry matches the active Ghostty binary → error, list unchanged.
  - `xdg-terminal-exec` missing, or `--print-id` failing → error.
  - An existing `kdeglobals` file with terminal keys → unchanged after apply, and no `kwriteconfig6` or `kreadconfig6` call is made.
  - The package declaration contains `pinentry-gnome3` and `xdg-terminal-exec` and no `pinentry-qt`.
  - macOS scenarios keep passing unchanged.
- **Verification:** `tests/test_terminal_environment.py` and `tests/test_linux_apps.py` pass on the development host; the test seam covers the script's decisions with fixture commands and does not prove a real GNOME session launches Ghostty.

### U4. Readiness report

- **Goal:** The read-only report inspects and describes the GNOME workstation.
- **Requirements:** R8.
- **Dependencies:** U1, U3.
- **Files:** `scripts/linux-readiness.py`, `tests/test_linux_readiness.py`.
- **Approach:** In `COMMANDS`, replace `pinentry-qt` with `pinentry-gnome3` and the two KDE commands with `xdg-terminal-exec`. Rename the `KDE session` check to `GNOME session`. Reword the supported-host detail, `DESKTOP_DETAIL`, the terminal and Dock items in `NATIVE_CHECKS`, and the guide path to `docs/setup/ubuntu.md`.
- **Test scenarios:**
  - Every installation present on a supported host → exit `2`, with a `GNOME session` check and all native checks pending.
  - Host without the Ubuntu Desktop metapackage, version `24.04`, or `arm64` → exit `1` with only the supported-host check.
  - No graphical session → `GNOME session` is `pending`, not `failed`.
  - The command allowlist contains `pinentry-gnome3` and `xdg-terminal-exec`, and none of `pinentry-qt`, `kwriteconfig6`, `kreadconfig6`.
- **Verification:** `tests/test_linux_readiness.py` passes.

### U5. Documentation and instructions

- **Goal:** Every guide and instruction describes the GNOME target, and nothing points at Studio or #120.
- **Requirements:** R9, R10.
- **Dependencies:** U1–U4.
- **Files:** `docs/setup/ubuntu.md` (renamed from `docs/setup/ubuntu-studio.md`), `README.md`, `docs/README.md`, `docs/guides/terminal.md`, `docs/guides/secrets-and-authentication.md`, `docs/guides/t3-code.md`, `docs/guides/zsh.md`, `docs/guides/personal-applications.md`, `docs/maintenance/development-and-testing.md`, `home/.chezmoitemplates/agent-instructions`, `mise.toml`, `tests/smoke_linux_minikube.py`, `tests/test_agent_instructions.py`.
- **Approach:**
  1. Rewrite the setup guide for Ubuntu Desktop: the ISO comes from `https://releases.ubuntu.com/26.04/` as `ubuntu-26.04.1-desktop-amd64.iso`, the session is GNOME, the pinentry is `pinentry-gnome3`, and launch checks use the GNOME Activities overview, Settings and Files. Remove the sentence that forbids the generic Ubuntu Desktop image and the closing #120 paragraph.
  2. In `docs/guides/terminal.md`, describe the dispatcher list from KTD2 in the platform table, the defaults section and the acceptance checklist.
  3. In `docs/guides/secrets-and-authentication.md`, rename the section per KTD5 and name gnome-keyring as the provider an Ubuntu Desktop session normally supplies, keeping the rule that the existing provider is checked and never replaced.
  4. Update the remaining files' wording and links, including the `linux-build` task description and the minikube smoke docstring.
- **Test scenarios:** Test expectation: none for prose. `tests/test_agent_instructions.py` and any test that asserts guide paths or wording are updated to the new text.
- **Verification:** `git grep -n -i -w 'studio\|ubuntustudio\|kde\|plasma\|kdeglobals\|dolphin\|pinentry-qt\|qt pinentry\|kwriteconfig6\|kreadconfig6'` and `git grep -n 'ubuntu-studio\|issues/120'` match only the historical plan records and Visual Studio wording, and every relative link to `docs/setup/ubuntu.md` and the renamed anchor resolves.

---

## Verification Contract

| Check | Command | Applies to |
| --- | --- | --- |
| Worktree preparation | `mise install` | All units, before any test |
| Unit and fixture tests | `mise exec -- python -m unittest discover -s tests -p 'test_*.py'`, or the repository's area runner `scripts/run-test-area.py` when it selects these modules | U1–U5 |
| Shell syntax | `sh -n` on `bootstrap-ubuntu.sh`, `provision-ubuntu.sh`, `scripts/terminal-environment.sh`, `scripts/install-ghostty.sh`, `scripts/linux-build-environment.sh` | U1–U3 |
| Hook-free source check | `mise run bootstrap` | U1, U3, U5 |
| Residual references | the `git grep` in U5 | U5 |
| CI | The existing workflow on the PR | All units |

The development host is macOS, so no check here exercises a real Ubuntu Desktop session. The PR description states that native acceptance is pending on the owner's host.

## Definition of Done

- R1–R11 hold and each unit's verification passes.
- The test suite passes locally for the modules that run on macOS, and CI is green on the PR.
- No file named for Ubuntu Studio remains outside `.compound-engineering/artifacts/plans/`.
- No abandoned experiment, compatibility alias or unused fixture command is left in the diff.
- Issue #120 is closed as not planned with the `wontfix` label and a comment that links the PR.
