---
title: Remaining Package Installer Failure Policy - Plan
date: 2026-09-18
type: fix
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/hyperlapse122/dotfiles/issues/541
---

# Remaining Package Installer Failure Policy - Plan

## Goal Capsule

- **Objective:** After any `chezmoi apply` on a managed host, a package that the tailscale, flatpaks, podman, desktop-IME or base installer attempted and could not install is visible to the operator through `dotfiles-skips` and the apply output, with a by-hand command that actually clears it, and every later apply phase still ran. None of these installers records a host as converged while a package it attempted to install is missing, and none hides an install failure behind `|| true`.
- **Means:** Apply the failure policy `AGENTS.md` already records (KTD1) to the five remaining installers: after each install attempt, the installer re-inspects its declared package set, and a set that is still incomplete exits 0 through a declared `skip_step` site whose state record survives until the success path clears it.
- **Product authority:** the Key Decisions, then the Requirements, then `AGENTS.md`'s skip-direction rules.
- **Execution profile:** seven Implementation Units in one pull request; `.ci/check-skip-declarations.sh` and `.ci/test-package-installer-verdict.sh` are the acceptance gate, and the matrix's frozen totals move together with the new rows.
- **Stop conditions:** renaming an installer to a `run_after_` lifecycle is a stop; adding a capability registry row or a hook resolver kind is a stop — the policy needs neither; removing a declared package, adding `--keep-going`, or touching the NVIDIA or direct-RPM-reconciler installers is a stop, because issue #541 does not name them.
- **Who finishes:** the implementing run ships all seven units; no further installer conversion remains open after this plan (see Scope Boundaries).
- **Open blockers:** none.

---

## Product Contract

### Summary

The tailscale, flatpaks, podman, desktop-IME and base (`20-base/fedora`, `20-base/ubuntu`) installers stop hiding an install failure behind `|| true` or an unguarded abort. After each installer's install attempt, it re-inspects the packages it declared. When any are still missing, the installer prints what is missing and the by-hand command to install it, then leaves through a declared `skip_step` that keeps a state record, so the script exits 0, later apply phases run, and `dotfiles-skips` reports the host as unconverged until the record is cleared. Repository/bootstrap setup steps inside these installers (repo file writes, key import, `apt-get update`, `dnf makecache`) stay tolerant of failure, exactly as they already do in the three installers #537 converted; only the final package-set verdict decides the site's direction. `AGENTS.md` is updated to record that these installers now follow the policy.

### Problem Frame

Issue #537 decided the failure policy once and #537's implementation applied it to the devtools, apps and .NET installers only, deferring the rest to a follow-up issue (`docs/plans/2026-09-17-2131-fix-installer-failure-policy-plan.md`, Deferred to Follow-Up Work). Issue #541 is that follow-up. Two failure shapes remain in the five listed installers: `run_onchange_before_30-tailscale.sh.tmpl:41` suppresses `apt-get install -y tailscale` with `|| true`, so a failed install is recorded as a clean run; and every other declared-set install in these five installers (tailscale-Fedora, flatpaks, podman, desktop-IME, both base installers) runs under `set -euo pipefail` with no re-inspection, so the first failing package aborts the rest of that `chezmoi apply`, including unrelated file targets in later phases.

### Requirements

**Failure policy**

- R1. A covered installer never records a clean success while a package it declared is still missing after its install attempt.
- R2. The verdict is a re-inspection of the declared set after the install attempt, using the same inspection the installer already uses to find missing entries (`rpm -q`, `dpkg-query -W`/`command -v`, `flatpak list --app`). The package manager's own exit status is never the verdict, and its stderr stays visible.
- R3. A failed verdict exits 0 through a declared `skip_step` site that keeps its state record, so every later chezmoi phase and every file target of that apply still lands.
- R4. Before the declaration, the installer prints the missing entries and the by-hand install command to stderr, so the apply output and the record together name the operator action.
- R5. When the verdict passes, the installer removes its own state record, so a host that converged by hand or on a later run stops being reported.
- R6. Every new site's direction is `operator-blocking`. `.chezmoidata/.capability-registry.tsv` has one adjacent probe, `fcitx5-present`, but its predicate is a single `command -v fcitx5` check, not the desktop-IME installer's compound multi-package verdict (R10) — the same exact-predicate-match convention the `dotnet-present`/`dotnet-absent` site already uses means this site does not qualify for `transient-blocking`. No other target installer has an adjacent probe. No new capability probe is added (mirrors origin plan R6).

**Installer coverage**

- R7. The tailscale installer applies the policy to its single-package install on both branches: the Fedora `dnf install tailscale` (which aborts today) and the Ubuntu `apt-get install -y tailscale` (which suppresses with `|| true` today, the exact defect issue #541 names).
- R8. The flatpaks installer applies the policy to `flatpak install --system -y --noninteractive flathub "${flatpaks[@]}"` on both Fedora and Ubuntu; the `flatpak` runtime package install and the `flatpak remote-add` call stay tolerant, matching R12, because the app-install verdict already re-inspects the full declared set and reports it whether the runtime or the remote setup is what actually failed. The re-inspection itself must not assume the `flatpak` binary exists (R2 note).
- R9. The podman installer applies the policy to its Fedora bulk `dnf install` and to its Ubuntu per-package `apt-get install` loop, which today aborts the apply on the first failing package exactly like the pre-conversion devtools Ubuntu branch.
- R10. The desktop-IME installer applies the policy to its Fedora bulk `dnf install` and to its Ubuntu per-package `apt-get install` loop, which has the same first-failure-aborts defect as R9.
- R11. Both base installers (`20-base/fedora`, `20-base/ubuntu`) apply the policy to their declared-package install. The Fedora branch's `setup_base_repos` (workstation-repositories package, RPM Fusion release packages, `dnf makecache`) stays tolerant, matching how repository setup already stays tolerant in the three installers #537 converted; only the final `core_packages` verdict decides the site.

**Repository setup steps**

- R12. Tailscale's Fedora repo add and `dnf makecache`, tailscale's Ubuntu keyring/list/`apt-get update`, flatpaks' runtime install and `flatpak remote-add`, and base's repository/mirrorlist/RPM-Fusion setup all stay tolerant of failure; the package verdict that follows each is what reports their effect.

**Operator re-run command**

- R13. Every new message and instruction that tells an operator how to re-run one of these `run_onchange_` scripts names `chezmoi state delete-bucket --bucket=entryState`, matching the existing convention (origin plan R15, KTD7).

**CI and documentation**

- R14. Every new declaration site gets its own owner row in `.ci/skip-declaration-site-matrix.yaml`, and the matrix's frozen totals in that file, `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` move together with the new rows.
- R15. `.ci/test-package-installer-verdict.sh` gains scenarios that drive the five converted installers with stub package managers and prove the verdict, the record, the clearing and the continuation for each branch, following the existing devtools/apps/.NET scenario shape.
- R16. `AGENTS.md`'s package-installation paragraph is updated to name the tailscale, flatpaks, podman, desktop-IME and base installers alongside the devtools, apps and .NET installers as following the policy, and drops the "still await conversion" clause it currently carries.

### Key Decisions

- **KTD1 — Record and continue; never abort the apply on a package install failure, and never hide it behind `|| true`.** Already settled for the devtools/apps/.NET installers by #537 and recorded in `AGENTS.md`; this plan applies the identical decision to the five remaining installers rather than choosing a new mechanism. *(session-settled: user-approved — chosen over inventing a per-installer failure strategy: `AGENTS.md` already states this as the binding policy for every package installer, and issue #541 asks only for conversion, not redesign.)* Governs R1, R3, R7-R11.
- **KTD2 — Scope is exactly the five installers issue #541 names.** The NVIDIA installer's unsuppressed `dnf install`/`dnf makecache` and the direct-RPM reconciler's `exit 1` paths are excluded, matching the origin plan's own Scope Boundaries. *(session-settled: user-approved — chosen over also converting NVIDIA or the direct-RPM reconciler: issue #541's "Remaining conversions" section names exactly these five, and widening scope would re-litigate a decision #537's plan already made.)* Governs R7-R11.
- **KTD3 — Flatpaks' runtime/remote-setup steps stay tolerant; only the app-ID verdict decides the site.** The `flatpak` package install and `flatpak remote-add` are prerequisites analogous to the repo-setup steps R11/R12 already keep tolerant elsewhere: if either fails, the subsequent re-inspection of the declared `flatpaks` array still finds every app ID missing and reports it, so a separate site for the runtime step would duplicate the same operator action. Governs R8, R12.

---

## Planning Contract

### Key Technical Decisions

- KTD4. **Podman's and desktop-IME's Ubuntu per-package loop is fixed the same way the devtools Ubuntu branch was fixed in #537**, not by switching to a bulk `apt-get install`: make the per-package `install_apt` call tolerant (discard its status under `set -e` via the `if ! cmd; then :; fi` form the apps installer already uses), keep the loop running through every package, then re-inspect the full declared set once after the loop. *(session-settled: user-approved — chosen over converting the loop to a single bulk `apt-get install` call: the existing devtools-Ubuntu pattern is the repository's proven precedent for a per-package apt loop under this policy, and `ce-simplify-code`/review would flag an unexplained divergence.)* Governs R9, R10.
- KTD5. **Tailscale, being a one-package declared set on both branches, uses a scalar re-inspection (`rpm -q tailscale` / `command -v tailscale`) rather than a missing-array loop**, mirroring how the existing `dotnet-absent` site already uses a scalar `command -v dotnet` predicate instead of an array. Governs R7.

### High-Level Technical Design

Every converted installer follows the same shape, already established by `run_onchange_before_70-apps.sh.tmpl` (Pattern to follow for every unit below):

```text
compute_missing_<set>()        # re-inspection: rpm -q / dpkg-query / flatpak list, fills a missing[] array (or a scalar test)
clear_<set>_skip_record()      # skip.sh.tmpl clear_record form
report_<set>_missing()         # prints missing entries + by-hand command to stderr, returns 0
install_<set>()
  compute_missing_<set>
  if missing non-empty:
    <repo/runtime setup, already tolerant>
    if ! <install attempt>; then :; fi     # discard status, never || true
    compute_missing_<set>
  if missing non-empty && report_<set>_missing:
    skip_step operator-blocking <script>/<site>
  clear_<set>_skip_record
```

### Assumptions

- No declared package is removed from any of the five installers; only the failure path changes (Key Decision KTD1, `AGENTS.md`).
- No new capability probe is added; every new site is `operator-blocking` (R6) because none of these installers has a registry probe whose predicate already observes the verdict.
- The base installers' existing `done_here` site (`base-packages-already-present`) is untouched; the new `skip_step` site only fires on the post-attempt path, which today is unreachable without an abort.

---

## Implementation Units

### U1. Tailscale installer, Fedora and Ubuntu

- **Goal:** R7 holds on both branches: a tailscale install that fails is recorded and reported instead of aborting (Fedora) or being silently discarded (Ubuntu).
- **Requirements:** R1-R6, R7, R12, R13.
- **Dependencies:** none.
- **Files:** `home/.chezmoiscripts/30-components/run_onchange_before_30-tailscale.sh.tmpl`; test coverage in `.ci/test-package-installer-verdict.sh` (U6).
- **Approach:**
  1. Fedora branch: keep `setup_tailscale_repo` tolerant (KTD1/R12; `dnf makecache` already has no `|| true` today and should gain one, matching the apps installer's `dnf makecache` tolerance). Change `install_tailscale` so the `dnf install -y tailscale` call discards its status (`if ! ...; then :; fi`) instead of running under bare `set -e`, then re-check `rpm -q tailscale` (KTD5). On a still-missing verdict, print the by-hand `sudo dnf install -y tailscale` command and declare `skip_step` `operator-blocking` for script `install-tailscale-fedora`, site `tailscale-not-installed`. On the passing path, clear that record.
  2. Ubuntu branch: remove the `|| true` from `apt-get install -y tailscale` (the exact defect issue #541 names) and replace it with the discard-status form; keep the curl/tee/`apt-get update` repo-setup lines tolerant as they already are (R12). Re-check with `command -v tailscale`. On a still-missing verdict, print the by-hand `sudo apt-get install -y tailscale` command and declare `skip_step` `operator-blocking` for script `install-tailscale-ubuntu`, site `tailscale-not-installed`, with a clearing twin.
  3. Leave `enable_tailscale` unchanged; it is not a package install and already tolerates a missing unit file.
- **Patterns to follow:** `install_app_packages`/`report_apps_missing`/`clear_apps_skip_record` in `run_onchange_before_70-apps.sh.tmpl`; the scalar `dotnet-absent` predicate in `run_onchange_before_50-dotnet.sh.tmpl`.
- **Test scenarios:**
  - Fedora: `dnf install tailscale` exits non-zero; the record `install-tailscale-fedora__tailscale-not-installed` exists with direction `operator-blocking`, stderr names the package and the `dnf install` command, and the script exits 0.
  - Fedora: `dnf install` exits 0 and `rpm -q tailscale` confirms it; a pre-seeded record is removed and no report is printed.
  - Ubuntu: `apt-get install -y tailscale` exits non-zero; the record `install-tailscale-ubuntu__tailscale-not-installed` exists, stderr names the by-hand `apt-get install` command, and the script exits 0 (proves the `|| true` removal did not reintroduce an abort).
  - Ubuntu: tailscale already present (`command -v tailscale` succeeds); no install call is logged and a pre-seeded record is removed.
- **Verification:** the rendered branch never aborts on a failed tailscale install, and `dotfiles-skips` lists the new record only while the package stays missing.

### U2. Flatpaks installer, Fedora and Ubuntu

- **Goal:** R8 holds: a flatpak app ID that stays missing after the install attempt is recorded and reported on both branches, without a separate site for the runtime package.
- **Requirements:** R1-R6, R8, R12.
- **Dependencies:** none.
- **Files:** `home/.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl`; test coverage in `.ci/test-package-installer-verdict.sh` (U6).
- **Approach:**
  1. Make `install_flatpak_runtime`'s package-manager install (both the Fedora `dnf install flatpak` and the Ubuntu `apt-get install -y flatpak`) and the `flatpak remote-add` call tolerant, discarding status the same way repo-setup steps already do elsewhere (KTD3, R12).
  2. Add `compute_missing_flatpaks` using `flatpak list --system --app --columns=application` (or equivalent) against the declared `flatpaks` array. Guard it with `command -v flatpak` first: when the runtime install from step 1 was itself tolerated and the `flatpak` binary is still absent, treat every declared app ID as missing without invoking `flatpak list` — calling it on a missing binary would fail under `set -euo pipefail` and defeat the tolerance step 1 just added.
  3. Change `install_flatpak_apps` so the `flatpak install --system -y --noninteractive flathub "${flatpaks[@]}"` call discards its status, then re-inspects. On a still-missing verdict, print the missing app IDs and the by-hand `flatpak install --system flathub <ids>` command, and declare `skip_step` `operator-blocking` for script `install-flatpaks`, site `flatpak-apps-not-installed` (KTD3: one shared owner across both OS renders, since the app-install function is OS-agnostic). Clear the record on the passing path, including when nothing was missing.
- **Patterns to follow:** `install_app_packages` in `run_onchange_before_70-apps.sh.tmpl`, adapted from `rpm -q` to `flatpak list`.
- **Test scenarios:**
  - Fedora and Ubuntu: `flatpak install` exits non-zero and one declared app ID is still absent from `flatpak list`; the record `install-flatpaks__flatpak-apps-not-installed` exists, stderr names the app ID and the by-hand command, and the script exits 0.
  - Every declared app ID present: a pre-seeded record is removed and no install call is logged.
  - The `flatpak` runtime package install fails (stubbed to fail) and the `flatpak` binary stays absent from `PATH`: `compute_missing_flatpaks` reports every declared app ID missing without invoking `flatpak list`, the record is written, and the apply does not abort (proves the `command -v flatpak` guard, not just the tolerated install).
- **Verification:** neither branch aborts when the runtime install, the remote add, or the app install fails; the verdict always reflects the declared app-ID set.

### U3. Podman installer, Fedora and Ubuntu

- **Goal:** R9 holds: a podman package that stays missing after the install attempt is recorded and reported on both branches, and the Ubuntu per-package loop no longer aborts on the first failure.
- **Requirements:** R1-R6, R9.
- **Dependencies:** none.
- **Files:** `home/.chezmoiscripts/30-components/run_onchange_before_20-podman.sh.tmpl`; test coverage in `.ci/test-package-installer-verdict.sh` (U6).
- **Approach:**
  1. Fedora branch: change `install_podman_packages`'s `"${DNF[@]}" install -y "${missing[@]}"` to discard status, then re-inspect with the same `rpm -q` loop. On a still-missing verdict, print the missing packages and the `dnf install` command, and declare `skip_step` `operator-blocking` for script `install-podman-fedora`, site `podman-packages-not-installed`, with a clearing twin.
  2. Ubuntu branch: make `install_apt` tolerant per package with a report helper naming the failed package (KTD4), keep `apt-get update` tolerant as it already is, then re-inspect with the same `dpkg-query` status check and declare `skip_step` `operator-blocking` for script `install-podman-ubuntu`, site `podman-packages-not-installed`, with a clearing twin.
  3. Leave `configure_user_namespaces` unchanged; it is host configuration, not a package install, and its `usermod`/`gpasswd` calls already tolerate failure.
- **Patterns to follow:** the devtools Ubuntu branch's `install_apt` tolerance (U1 of the #537 plan, now in `run_onchange_before_80-devtools.sh.tmpl`); `install_app_packages` in `run_onchange_before_70-apps.sh.tmpl` for the Fedora shape.
- **Test scenarios:**
  - Fedora: `dnf install` exits non-zero, one package stays missing; the record is written with the missing package named on stderr, and the script exits 0.
  - Fedora: every package present; a pre-seeded record is removed and no install call is logged.
  - Ubuntu: `apt-get install` fails for the second of six packages; the third through sixth are still attempted, and the record names the second package.
  - Ubuntu: every package present; a pre-seeded record is removed and no install runs.
- **Verification:** neither branch aborts the apply on a failed podman package install; `configure_user_namespaces` still runs afterward regardless of the verdict.

### U4. Desktop-IME installer, Fedora and Ubuntu

- **Goal:** R10 holds: a desktop-IME package that stays missing after the install attempt is recorded and reported on both branches, and the Ubuntu per-package loop no longer aborts on the first failure.
- **Requirements:** R1-R6, R10.
- **Dependencies:** none.
- **Files:** `home/.chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl`; test coverage in `.ci/test-package-installer-verdict.sh` (U6).
- **Approach:**
  1. Fedora branch: change `install_desktop_ime_packages`'s bulk `dnf install -y "${missing[@]}"` to discard status, then re-inspect with the same `rpm -q` loop (covering the desktop-conditional `ksshaskpass`/`openssh-askpass` entries too, since they are part of the same declared array). On a still-missing verdict, declare `skip_step` `operator-blocking` for script `install-desktop-ime-fedora`, site `ime-packages-not-installed`, with a clearing twin.
  2. Ubuntu branch: apply KTD4 exactly as in U3 — tolerant per-package `install_apt`, then a single re-inspection and `skip_step` `operator-blocking` for script `install-desktop-ime-ubuntu`, site `ime-packages-not-installed`, with a clearing twin.
- **Patterns to follow:** U3 (podman) for both branches; `install_app_packages` in `run_onchange_before_70-apps.sh.tmpl`.
- **Test scenarios:**
  - Fedora: `dnf install` exits non-zero, `fcitx5-hangul` stays missing; the record is written naming it, and the script exits 0.
  - Fedora, KDE desktop: `ksshaskpass` stays missing after the attempt; the record names it alongside any other missing package in the same report.
  - Fedora: every package present; a pre-seeded record is removed.
  - Ubuntu: `apt-get install` fails for `wl-clipboard`; the record names it, and the other declared packages were still attempted.
  - Ubuntu: every package present; a pre-seeded record is removed and no install runs.
- **Verification:** neither branch aborts the apply on a failed IME package install.

### U5. Base installers, Fedora and Ubuntu

- **Goal:** R11 holds: a base package that stays missing after the install attempt is recorded and reported on both `20-base` installers, without disturbing the existing `base-packages-already-present` `done_here` site.
- **Requirements:** R1-R6, R11, R12.
- **Dependencies:** none.
- **Files:** `home/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`, `home/.chezmoiscripts/20-base/ubuntu/run_onchange_before_base.sh.tmpl`; test coverage in `.ci/test-package-installer-verdict.sh` (U6).
- **Approach:**
  1. Fedora: make every call inside `setup_base_repos` tolerant (the `fedora-workstation-repositories` install, the RPM Fusion release-package install, and `dnf makecache`), matching R12 — these are repository bootstrap, not the declared-set verdict. Change `install_base_packages`'s final `"${DNF[@]}" install -y "${core_packages[@]}"` to discard status, then re-inspect with the same `rpm -q` loop used for the already-present early exit. On a still-missing verdict, print the missing packages and the `dnf install` command, and declare `skip_step` `operator-blocking` for script `install-base-fedora`, site `base-packages-not-installed`, with a clearing twin. Leave the existing `base-packages-already-present` `done_here` site and `configure_time`/`enable_base_services` untouched.
  2. Ubuntu: keep `apt-get update` tolerant as it already is. Change `install_base_packages`'s final `"${SUDO[@]}" apt-get install -y "${missing[@]}"` to discard status, then re-inspect with the same `dpkg-query` loop used for the already-present early exit. On a still-missing verdict, declare `skip_step` `operator-blocking` for script `install-base-ubuntu`, site `base-packages-not-installed`, with a clearing twin. Leave the existing `base-packages-already-present` `done_here` site untouched.
- **Patterns to follow:** `install_app_packages` in `run_onchange_before_70-apps.sh.tmpl`; the existing `done_here` early-exit shape already present in both base installers.
- **Test scenarios:**
  - Fedora: `dnf install` of `core_packages` exits non-zero, `ripgrep` stays missing; the record `install-base-fedora__base-packages-not-installed` exists, stderr names it, and the script exits 0.
  - Fedora: the RPM Fusion release-package install fails but every core package still installs; no record is written, proving repo-setup tolerance doesn't mask a real package failure.
  - Fedora: every core package already present; the existing `done_here` path still fires unchanged (no regression).
  - Ubuntu: `apt-get install` exits non-zero, `tmux` stays missing; the record is written naming it, and the script exits 0.
  - Ubuntu: every core package already present; the existing `done_here` path still fires unchanged.
- **Verification:** neither base installer aborts the apply on a failed core-package install; `configure_time`/`enable_base_services` (Fedora) still run after a failed verdict.

### U6. CI matrix rows and verdict test scenarios

- **Goal:** R14, R15 hold: every new `skip_step` site from U1-U5 has an owner row in the matrix with correct digests, the frozen totals move with it, and `.ci/test-package-installer-verdict.sh` proves every scenario listed in U1-U5.
- **Requirements:** R14, R15.
- **Dependencies:** U1, U2, U3, U4, U5 (the matrix rows and test scenarios describe the rendered code those units produce).
- **Files:** `.ci/skip-declaration-site-matrix.yaml`, `.ci/check-skip-declarations.sh`, `.ci/test-capability-cache.sh`, `.ci/test-package-installer-verdict.sh`.
- **Approach:**
  1. For each new `skip_step` site from U1-U5 (nine total: tailscale-fedora, tailscale-ubuntu, flatpaks (one owner, two render profiles), podman-fedora, podman-ubuntu, desktop-ime-fedora, desktop-ime-ubuntu, base-fedora, base-ubuntu), add an owner row following the exact field shape of the existing `install-apps-fedora/app-packages-not-installed` row: `owner`, `scope: '30-components'` or `'20-base'`, `template`, `anchor_line`, `anchor`, `predicate`, `predicate_digest`, `continuation: 'abandon-step-return-0'`, `continuation_digest`, `render_profile`, `form: 'skip_step'`, `direction: 'operator-blocking'`, `instances`. Compute `anchor_line`/`anchor` from the rendered installer after U1-U5 land, and compute `predicate_digest`/`continuation_digest` by running `.ci/check-skip-declarations.sh`'s own `normalize_predicate`/`digest` functions against the final predicate and continuation text, matching how the existing rows were produced — do not hand-write a hash.
  2. Move the matrix's frozen `totals` (currently 150 classified owners / 225 rendered instances) by the new owner and instance counts (nine new owners; instances equal to owners except flatpaks, which is one owner with two instances for its two render profiles), and move the matching totals in `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` together, per the matrix header's own obligation.
  3. In `.ci/test-package-installer-verdict.sh`, add `_src` render entries for the five newly-covered templates (tailscale, flatpaks, podman, desktop-ime, and both base templates) alongside the existing `devtools_src`/`apps_src`/`dotnet_src`, render each for its applicable OS profile(s), extract each installer's install region the same way the existing driver does, add stub package managers for any newly-needed command (`flatpak`), and add one `--- <Name>, <OS> ---` driver section per branch implementing the test scenarios listed in U1-U5.
- **Test scenarios:** Test expectation: none beyond the scenarios already enumerated in U1-U5 — this unit is the harness that proves them; verification is that `.ci/test-package-installer-verdict.sh` passes with every U1-U5 scenario represented.
- **Verification:** `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` pass against the moved totals, and `.ci/test-package-installer-verdict.sh` passes with the new scenarios.

### U7. AGENTS.md policy paragraph update

- **Goal:** R16 holds: `AGENTS.md` names the newly-covered installers and no longer claims they await conversion.
- **Requirements:** R16.
- **Dependencies:** U1, U2, U3, U4, U5 (the paragraph should describe the coverage those units produce).
- **Files:** `AGENTS.md`.
- **Approach:**
  1. In the package-installation paragraph (the sentence ending "The devtools, apps and .NET installers follow this policy today; the other package installers still await conversion."), replace it with a sentence naming all eight covered installers (devtools, apps, .NET, tailscale, flatpaks, podman, desktop-IME, base) and drop the "still await conversion" clause, since this plan closes issue #541's named list.
- **Test scenarios:** Test expectation: none -- documentation-only change with no behavioral surface.
- **Verification:** the updated sentence accurately lists every installer converted by #537 and this plan, and names no installer this plan did not touch.

---

## Verification Contract

| Command | Applies to | Gate |
|---|---|---|
| `.ci/check-skip-declarations.sh` | U1-U6 | Matrix rows match rendered predicates/continuations; frozen totals consistent |
| `.ci/test-capability-cache.sh` | U6 | Frozen totals and any fingerprint blocks stay consistent |
| `.ci/test-package-installer-verdict.sh` | U1-U6 | Every scenario in U1-U5 passes against the rendered installers |
| `shellcheck` on each edited `.sh.tmpl`'s rendered output | U1-U5 | No new shellcheck regressions from the tolerance/re-inspection changes |
| `.ci/test-source-root.sh` (or equivalent render smoke check already run in CI) | U1-U5 | Templates still render under both OS profiles with no template syntax error |

## Definition of Done

- Every requirement R1-R16 is implemented and its unit's test scenarios pass.
- `.ci/check-skip-declarations.sh`, `.ci/test-capability-cache.sh` and `.ci/test-package-installer-verdict.sh` all pass with the matrix's frozen totals moved to match the nine new owner rows.
- No declared package was removed from any of the five installers, and no installer was renamed to a `run_after_` lifecycle.
- `AGENTS.md`'s package-installation paragraph names all eight covered installers.
- No code from an abandoned approach remains in the diff.

---

## Scope Boundaries

- **Outside this work:** the NVIDIA installer's unsuppressed `dnf install`/`dnf makecache` and the direct-RPM reconciler's `exit 1` paths — issue #541 does not name them, matching the origin plan's own Scope Boundaries (KTD2).
- **Outside this work:** removing a declared package, adding `--keep-going`, or changing `prune_stale_skip_records`/`dotfiles-skips`. The only `skip.sh.tmpl` change is adding new sites in the established shape; forms, directions and sentinels stay as they are.
- **Outside this work:** a new capability probe (R6) — none of these five installers has a predicate an existing registry probe already observes.

### Deferred to Follow-Up Work

- None. Issue #541's "Remaining conversions" list is fully covered by U1-U5; no installer named by #537's or #541's deferral sections remains unconverted after this plan.

## Sources & Research

- `AGENTS.md` package-installation paragraph (policy text and current coverage claim).
- `docs/plans/2026-09-17-2131-fix-installer-failure-policy-plan.md` — origin plan for #537, whose Deferred to Follow-Up Work section is issue #541's origin, and whose Implementation Units (U1-U3) are the direct pattern source for this plan's U1-U5.
- `home/.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`, `run_onchange_before_80-devtools.sh.tmpl`, `run_onchange_before_50-dotnet.sh.tmpl` — the three already-converted installers, read in full as the pattern to follow.
- `home/.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` — `install_nvidia_packages`/`report_unavailable_packages`/`clear_nvidia_skip_record`, the earliest instance of this shape, explicitly out of scope for conversion itself (KTD2) but still the naming pattern.
- `.ci/skip-declaration-site-matrix.yaml` rows for `install-apps-fedora/app-packages-not-installed`, `install-dotnet-fedora/dotnet-absent`, `install-devtools-ubuntu/dev-packages-not-installed` — the exact row shape U6 reproduces.
- `.ci/test-package-installer-verdict.sh` — existing render/extract/stub/driver structure U6 extends.
- `home/.chezmoiscripts/30-components/run_onchange_before_30-tailscale.sh.tmpl:41` — the `|| true` suppression issue #541 names directly.
