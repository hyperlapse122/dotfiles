---
title: Declare GPG Stack and Paper-Backup Packages - Plan
type: chore
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Declare GPG Stack and Paper-Backup Packages - Plan

## Goal Capsule

- **Objective:** A converged host always carries the full GPG stack (`gnupg`, `scdaemon`, `pcscd`, `secret-tool`) and the paper-backup ceremony tools (`paperkey`, `qrencode`, `zbarimg`) after `chezmoi apply`, even when one was removed by hand after the initial bootstrap.
- **Means:** Declare the package set per distro in `.chezmoidata`, install it from a new steady-state chezmoiscript, and gate drift with a CI parity check against `.install-prerequisites.sh`'s existing preflight arrays (KTD1-KTD7).
- **Authority hierarchy:** GitHub issue [#575](https://github.com/hyperlapse122/dotfiles/issues/575) is the requirement source; `AGENTS.md`'s "Single source of truth" section and existing `home/.chezmoiscripts/` conventions govern implementation shape.
- **Stop conditions:** Any change to `.install-prerequisites.sh`'s `preflight_fedora`/`preflight_ubuntu` behavior; the preflight bootstrap must stay byte-identical (R3).
- **Execution profile:** Unattended `lfg` run, no human checkpoint. Judgment calls this plan could not settle from repo evidence are recorded as assumptions below rather than left open.
- **Who finishes and ships:** `ce-work` implements the units; the `lfg` pipeline carries the change through review, CI, and merge.

---

## Product Contract

### Summary

Add a new `home/.chezmoidata/gpg.yaml` declaring the GPG smartcard stack and the three key-ceremony tools (`paperkey`, `qrencode`, `zbar`/`zbar-tools`) per distro, a steady-state chezmoiscript that installs the declared set on every `chezmoi apply`, and a CI gate that fails when the declaration drifts from `.install-prerequisites.sh`'s bootstrap preflight arrays.

### Problem Frame

`.install-prerequisites.sh`'s `preflight_fedora`/`preflight_ubuntu` (`.install-prerequisites.sh:1183`, `:1218`) install the GPG stack once, before chezmoi can even decrypt the repository's encrypted files. That bootstrap path has to keep its own literals — it cannot depend on `.chezmoidata` being readable yet. But it only runs on a fresh host: if a package is later removed by hand, nothing restores it on the next `chezmoi apply`. `.chezmoidata` plus a steady-state consumer script closes that gap for every host already past bootstrap, redundantly by design (see issue #575). The two lists must not silently drift apart, and issue #574's key ceremony additionally needs three tools (`paperkey`, `qrencode`, `zbarimg`) the bootstrap has no need to install.

### Requirements

- R1. `home/.chezmoidata` declares the GPG stack and the three ceremony tools with per-distro (Fedora / Debian-Ubuntu) package names.
- R2. The desktop-conditional pinentry variant is expressed: KDE selects `pinentry-qt`, GNOME selects `pinentry-gnome3`, matching both preflight functions' `case "$(hook_desktop)")` arms.
- R3. `.install-prerequisites.sh` is unchanged; `preflight_fedora`/`preflight_ubuntu` keep bootstrapping a host with no chezmoi data exactly as they do today.
- R4. A CI test asserts the preflight arrays and the declared per-distro set agree, following `.ci/test-gpg-key-data.sh`'s extraction-and-parity style, so the two lists cannot drift apart silently.
- R5. The Debian/Ubuntu package names for the three new tools are verified, not guessed.
- R6. After `chezmoi apply` on a Fedora or Ubuntu host, `gpg`, `scdaemon`, `pcscd`, `secret-tool`, `paperkey`, `qrencode`, and `zbarimg` are all present, restored on the next apply if removed.

### Scope Boundaries

- Out of scope: any change to `.install-prerequisites.sh` (R3 requires it byte-identical).
- Out of scope: `pcscd.socket` enable/disable. No existing chezmoiscript manages that today (only the bootstrap preflight does, via `pcscd_socket_needs_enable`); adding steady-state socket convergence is a separate concern from package presence, which is all R6 asks for.
- Out of scope: macOS. `preflight_macos` uses Homebrew and is not part of the per-distro table this issue declares; the new consumer script targets Linux only, matching the issue's Fedora/Debian-Ubuntu scope.
- Out of scope: broadening package coverage to Debian or Pop!_OS hosts beyond Ubuntu. `hook_distro_id` (the function `preflight_card_stack` dispatches on) matches the literal string `"ubuntu"` only, so a broader declared set would cover hosts the bootstrap itself does not; kept in lockstep instead (KTD3).

### Sources & Research

- `.install-prerequisites.sh:1183-1240` (`preflight_fedora`, `preflight_ubuntu`, `preflight_card_stack`) — the literal package arrays and the `hook_distro_id` dispatch this plan mirrors and must not modify.
- `.ci/test-gpg-key-data.sh` — the sibling CI test's extraction-helper and fixture-mutant style, reused for the new parity gate (R4).
- `home/.chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl` — the `$isFedora`/`$isUbuntu` distro-gate pattern and the desktop-conditional package addition, reused in U2.
- `home/.chezmoiscripts/30-linux/run_after_install-system-19-thermald.sh.tmpl` — the unconditional (non-`onchange`) per-apply idempotent install pattern reused in U2 (see KTD2).
- `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl` — how an existing consumer reads a `.chezmoidata` package list into a rendered bash array (`{{ range $face.packages }} {{ . | quote }} {{ end }}`).
- `docs/solutions/integration-issues/chezmoi-run-onchange-entrystate-bucket.md` — measured proof that a `run_onchange_` script re-runs only when its rendered content hash changes, never on unrelated host drift; directly decided KTD2.
- `.github/workflows/ci.yml:315-330` ("Run repository meta gates" job) — where `test-gpg-key-data.sh` is invoked; the new parity gate is added to the same list.
- `.github/workflows/render-dotfiles.yml` (Task 1 `chezmoi apply --init`, `shellcheck` job) — already runs a real `chezmoi apply --init` on an `ubuntu-latest` GitHub Actions runner and shellchecks every rendered script on every PR. Once this PR's CI runs, that job performs a genuine `apt-get install` of the declared Ubuntu package names — the closest available confirmation to "on an Ubuntu host" in this unattended run (R5; see KTD6).
- Package-archive verification (R5): [`packages.ubuntu.com/noble/paperkey`](https://packages.ubuntu.com/noble/paperkey), [`packages.ubuntu.com/en/noble/qrencode`](https://packages.ubuntu.com/en/noble/qrencode), and [`packages.ubuntu.com/jammy/zbar-tools`](https://packages.ubuntu.com/jammy/zbar-tools) / [`packages.debian.org/en/sid/zbar-tools`](https://packages.debian.org/en/sid/zbar-tools) confirm `paperkey` and `qrencode` exist verbatim and that `zbar-tools` (not `zbar`) is the Debian/Ubuntu package providing `zbarimg`.

---

## Planning Contract

- KTD1. **New `home/.chezmoidata/gpg.yaml`, scoped locally rather than generalized.** Top-level `gpg.packages.{fedora,debian}.{core,paperBackup}` plus `gpg.packages.desktopPinentry.{kde,gnome}`. The `core`/`paperBackup` split mirrors the issue's own two-table structure (redundant-with-preflight vs. new-for-#574) and lets the CI gate (R4) compare only the redundant subset. Rejected: a repo-wide generalized per-distro package schema (e.g. a shared template partial or a `facts.yaml`-level helper) — no second consumer needs cross-distro name mapping today (`system.yaml`'s `faceAuth` and `nvidia.yaml`'s branches are single-distro lists), so a shared schema would be speculative generalization for a population of one.
- KTD2. **Consumer script is `run_after_`, not `run_onchange_*`.** `docs/solutions/integration-issues/chezmoi-run-onchange-entrystate-bucket.md` measured that a `run_onchange_` script re-runs only when its own rendered content hash changes — never in response to unrelated host drift such as a hand-removed package. R6 explicitly requires restoration "on the next apply," which only an unconditional per-apply script (`run_after_`, no `onchange`) provides. Mirrors `run_after_install-system-19-thermald.sh.tmpl`'s idempotent check-then-install shape rather than the `run_onchange_before_*` package-installer shape (`70-apps.sh.tmpl`, `60-desktop-ime.sh.tmpl`), which only reinstalls when the script's own template output changes.
- KTD3. **Distro gate matches `hook_distro_id`'s literal values, not the broader `60-desktop-ime.sh.tmpl` family match.** `preflight_card_stack` (`.install-prerequisites.sh:1276-1287`) dispatches on `hook_distro_id` returning exactly `"fedora"` or `"ubuntu"` — no Debian or Pop!_OS branch. The new script's `$isFedora`/`$isUbuntu` gate is scoped the same way, so the declared set's OS coverage never exceeds what the bootstrap itself supports (see Scope Boundaries).
- KTD4. **Script placement: `home/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl`.** Chezmoi runs all `before`-phase scripts ahead of all `after`-phase scripts, ties broken by path; placing it beside `run_onchange_after_reload-gpg-agent.sh.tmpl` in the same "after" phase, alphabetically ordered before it (`install-gpg-packages` < `reload-gpg-agent`), ensures packages are present before that script checks the pinentry delegate's executable path.
- KTD5. **`pcscd.socket` and `scdaemon.conf` stay out of scope.** R6 asks only for package *presence*; no existing chezmoiscript activates `pcscd.socket` today (only the bootstrap preflight's `pcscd_socket_needs_enable` does), and `scdaemon.conf` is already owned by `.install-prerequisites.sh`'s `seed_scdaemon_conf` plus the managed `private_dot_gnupg/scdaemon.conf` (parity already CI-gated by `.ci/test-gpg-key-data.sh`'s `check_scdaemon_conf_parity`). Adding either here would be an unrequested scope expansion.
- KTD6. **Debian/Ubuntu names for the three new tools, verified against package archives instead of a live Ubuntu host.** `paperkey` and `qrencode` exist verbatim on Debian/Ubuntu; the package providing `zbarimg` is `zbar-tools`, not `zbar` (confirmed via `packages.ubuntu.com`/`packages.debian.org`, cited above). No Ubuntu host is reachable in this unattended run; `render-dotfiles.yml`'s `chezmoi apply --init` job already performs a real `apt-get install` of these names on an `ubuntu-latest` runner on every PR, which is the closest available substitute and will fail the PR's CI loudly if any name is wrong.
- KTD7. **New CI test file, not an addition to `test-gpg-key-data.sh`.** `.ci/test-gpg-packages-parity.sh` is a separate concern (installed packages vs. key/serial data) and a separate issue acceptance item; it follows that file's extraction-helper and fixture-mutant style (R4) and is wired into `.github/workflows/ci.yml`'s existing "Run repository meta gates" step immediately after `test-gpg-key-data.sh`.

### Assumptions

- The `core`/`paperBackup` split in `gpg.yaml` (KTD1) is this plan's own scope decision, not dictated by the issue text; recorded here per the headless scoping-confirmation skip (no human present in this unattended run).
- `zbar-tools` (Debian/Ubuntu) vs. `zbar` (Fedora) is treated as settled from package-archive evidence (KTD6); the issue itself already flagged this as the likely case ("zbarimg ships in a differently named package there").
- `paperkey`, `qrencode`, and `zbar-tools` are tagged `[universe]` in Ubuntu's package archive (unlike the existing `core` packages, which are `main`). Ubuntu's `universe` component is assumed enabled, matching a standard Ubuntu Desktop/Server install and the `ubuntu-latest` GitHub Actions runner image; no existing script in this repository proves that assumption today, since `preflight_ubuntu`'s packages are all `main`. `render-dotfiles.yml`'s real `apt-get install` on the `ubuntu-latest` runner (KTD6) is what actually verifies this for both CI and the common target host.

---

## Implementation Units

### U1. Declare the GPG stack and paper-backup packages in `.chezmoidata`

**Goal:** Add the per-distro package declaration and the desktop-conditional pinentry variant.

**Requirements:** R1, R2, R5

**Dependencies:** None

**Files:**
- `home/.chezmoidata/gpg.yaml` (new)
- `AGENTS.md` (add one row to the "Single source of truth" table, after the `system.yaml` row)

**Approach:**
1. Create `home/.chezmoidata/gpg.yaml` with a top-level `gpg:` key (matching the `system:`/`user:`/`nvidia:` convention where the top key names the file), per KTD1's shape: `packages.fedora.core` (the 6 packages from `preflight_fedora`'s base array), `packages.fedora.paperBackup` (`paperkey`, `qrencode`, `zbar`), `packages.debian.core` (the 5 packages from `preflight_ubuntu`'s base array), `packages.debian.paperBackup` (`paperkey`, `qrencode`, `zbar-tools`), and `packages.desktopPinentry` (`kde: pinentry-qt`, `gnome: pinentry-gnome3`).
2. Add a header comment naming the redundancy-by-design intent and pointing at the CI gate (U3), following `home/.chezmoidata/system.yaml`'s and `nvidia.yaml`'s header-comment style.
3. Add one row to `AGENTS.md`'s "Single source of truth" table (after the `system.yaml` row, line 142) describing `home/.chezmoidata/gpg.yaml`'s consumers.

**Patterns to follow:** `home/.chezmoidata/nvidia.yaml` (top-level key name matches filename; per-branch package lists); `home/.chezmoidata/system.yaml`'s `faceAuth` (a named, purpose-commented package list).

**Test scenarios:**

Test expectation: none -- pure YAML data declaration with no executable behavior of its own. Its correctness (package-name parity with the preflight arrays) is proven by U3's CI gate, and its consumability by U2's render.

**Verification:** `home/.chezmoidata/gpg.yaml` parses as valid YAML; U2's script renders against it without error; U3's parity gate passes.

---

### U2. Steady-state chezmoiscript installs the declared package set every apply

**Goal:** Restore any missing declared package on every `chezmoi apply`, on Fedora and Ubuntu, without touching `pcscd.socket` or `scdaemon.conf`.

**Requirements:** R1, R2, R3, R6

**Dependencies:** U1

**Files:**
- `home/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl` (new, `run_after_` — not `run_onchange_` — per KTD2; placed in `80-keys/` ahead of `run_onchange_after_reload-gpg-agent.sh.tmpl` in the same execution phase per KTD4)

**Approach:**
1. Top-level template gate: `$isFedora` / `$isUbuntu` on `.chezmoi.os "linux"` and `.chezmoi.osRelease.id` exactly `"fedora"` / `"ubuntu"` (KTD3), same shape as `run_onchange_before_60-desktop-ime.sh.tmpl:1-3`.
2. Include `facts-sh.tmpl`, `shared-host-guard.sh.tmpl`, and `sudo-elevation-guard.sh.tmpl` in that order, matching `run_after_install-system-19-thermald.sh.tmpl` and `run_onchange_before_60-desktop-ime.sh.tmpl`.
3. Render two package arrays — one per distro branch — from `.gpg.packages.fedora.core` + `.gpg.packages.fedora.paperBackup` (or the `debian` equivalents on the Ubuntu branch), using the `{{ range … }} {{ . | quote }} {{ end }}` shape from `run_onchange_after_install-system-34-face-auth.sh.tmpl:77-80`.
4. Append the desktop-conditional pinentry package (`.gpg.packages.desktopPinentry.kde` / `.gnome`) when `${FACT_DESKTOP:-none}` is `kde` / `gnome`, matching both preflight functions' `case` arms and `run_onchange_before_60-desktop-ime.sh.tmpl:26-30`'s bash-side desktop check.
5. Fedora branch: `rpm -q` each package to compute the missing set, `dnf install -y` only the missing ones — mirror `preflight_fedora` (`.install-prerequisites.sh:1183-1201`) and `run_after_install-system-19-thermald.sh.tmpl:32-35`.
6. Ubuntu branch: check each package with `dpkg-query -f '${db:Status-Status}' -W`, `apt-get install -y` only the missing ones — mirror `preflight_ubuntu` (`.install-prerequisites.sh:1218-1240`) and the `install_apt` helper in `run_onchange_before_60-desktop-ime.sh.tmpl:46-53`.
7. Do not enable/disable `pcscd.socket` and do not write `scdaemon.conf` (KTD5) — those stay exclusively owned by `.install-prerequisites.sh` and the managed dotfile.

**Execution note:** This is packaging/config; prefer install/runtime smoke verification (real `chezmoi apply --init` in `render-dotfiles.yml`, per Sources & Research) over unit coverage.

**Test scenarios:**
- Happy path: on a Fedora host missing `paperkey`, `qrencode`, and `zbar`, the script installs exactly those three and leaves the already-present core packages untouched.
- Happy path: on an Ubuntu host missing the same three, the script installs exactly those three via `apt-get`.
- Edge case: a KDE host's install set includes `pinentry-qt`; a GNOME host's includes `pinentry-gnome3`; a host with neither desktop fact adds no pinentry variant package.
- Edge case: a host where every declared package is already present makes no install call (idempotent no-op) — asserted the same way `run_after_install-system-19-thermald.sh.tmpl` proves its own idempotency.
- Integration: the template renders to an empty script (fully skipped) on a non-Fedora, non-Ubuntu `osRelease.id` such as `darwin` or `debian`.

**Verification:** `chezmoi execute-template` renders the script without error for Fedora, Ubuntu, and a non-matching OS fixture; `render-dotfiles.yml`'s real `chezmoi apply --init` (Ubuntu runner) and `shellcheck` jobs pass on the PR.

---

### U3. CI parity gate between the preflight arrays and the declared set

**Goal:** Fail CI when `.install-prerequisites.sh`'s preflight arrays and `home/.chezmoidata/gpg.yaml`'s declared `core` sets drift apart.

**Requirements:** R4

**Dependencies:** U1

**Files:**
- `.ci/test-gpg-packages-parity.sh` (new, executable)
- `.github/workflows/ci.yml` (add one line to the "Run repository meta gates" step, immediately after `.ci/test-gpg-key-data.sh`, around line 330)

**Approach:**
1. Resolve `repo_root` and `source_root` the same way `.ci/test-gpg-key-data.sh` does, via `.ci/lib/source-root.sh`.
2. Extraction helpers (sed/grep, no YAML parser dependency): pull `preflight_fedora`'s and `preflight_ubuntu`'s base `pkgs=(...)` literal arrays from `.install-prerequisites.sh`, and their `case "$(hook_desktop)")` `kde)`/`gnome)` `pkgs+=(...)` arms.
3. Extraction helpers for `home/.chezmoidata/gpg.yaml`: `packages.fedora.core`, `packages.debian.core`, and `packages.desktopPinentry.kde`/`.gnome`.
4. Assert order-independent set equality between each preflight core array and its `gpg.yaml` counterpart; assert the kde/gnome desktop literals match between both preflight functions and `gpg.yaml`.
5. Add at least one fixture-mutant check (a scratch copy of `gpg.yaml` with one `core` package renamed) proving the gate actually fails on drift and names both values, following `.ci/test-gpg-key-data.sh`'s `check_parity` mutant style (its Fixture 1).
6. Add the invocation line to `.github/workflows/ci.yml`'s "Run repository meta gates" step, directly after the existing `.ci/test-gpg-key-data.sh` line.
7. `chmod 0755` the new script, matching every other `.ci/test-*.sh` file, so `.ci/test-ci-wiring.sh`'s executable-file scan finds it.

**Execution note:** Add characterization coverage before trusting the extraction regexes — run the script against the real (post-U1) `.install-prerequisites.sh` and `gpg.yaml` first, then add the mutant fixture to prove the failure path.

**Test scenarios:**
- Happy path: the post-U1 repository state passes — both distros' `core` sets and the kde/gnome desktop literals match.
- Fixture: a mutated `gpg.yaml` `core` list (one package renamed) fails, naming both the preflight and the `gpg.yaml` values.
- Fixture: a mutated preflight array (one package renamed, in a scratch copy — the real `.install-prerequisites.sh` is never modified) fails the same way.
- Integration: `.ci/test-ci-wiring.sh` passes after this unit — the new script is invoked from `ci.yml` and carries the executable bit.

**Verification:** `.ci/test-gpg-packages-parity.sh` exits 0 against the real repository state and exits non-zero (naming both mismatched values) against each mutant fixture; `.ci/test-ci-wiring.sh` and the existing `.ci/test-gpg-key-data.sh` both still pass.

---

## Verification Contract

| Command | Applicability | Proves |
|---|---|---|
| `.ci/test-gpg-packages-parity.sh` | New gate (U3) | Preflight arrays and the declared `gpg.yaml` core sets agree per distro (R4) |
| `.ci/test-gpg-key-data.sh` | Existing, unaffected | GPG key/serial parity still holds — this plan touches none of its inputs |
| `.ci/test-ci-wiring.sh` | Repo meta gate | The new `.ci/test-gpg-packages-parity.sh` is invoked from `ci.yml` and executable |
| `.github/workflows/render-dotfiles.yml` (`chezmoi apply --init`, Ubuntu + macOS runners) | Real render | U2's template renders and executes without error; the Ubuntu job performs a genuine `apt-get install` of the declared names (R5, R6) |
| `.github/workflows/render-dotfiles.yml` (`shellcheck` job) | Real render | The rendered U2 script passes shellcheck |
| `git diff .install-prerequisites.sh` | Manual check | Empty — confirms R3 (preflight untouched) |

## Definition of Done

- `home/.chezmoidata/gpg.yaml` declares the Fedora and Debian/Ubuntu core GPG-stack packages, the three paper-backup/QR tools, and the KDE/GNOME pinentry variant (R1, R2).
- `home/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl` installs the full declared set on every apply on Fedora and Ubuntu, idempotently, touching neither `pcscd.socket` nor `scdaemon.conf` (R6, KTD5).
- `.install-prerequisites.sh` is byte-identical to its pre-change state (R3).
- `.ci/test-gpg-packages-parity.sh` exists, passes against the real repository state, fails against mutant fixtures, and is wired into `.github/workflows/ci.yml` (R4).
- `.ci/test-ci-wiring.sh` and `.ci/test-gpg-key-data.sh` both still pass.
- `AGENTS.md`'s "Single source of truth" table lists `home/.chezmoidata/gpg.yaml`.
- `render-dotfiles.yml`'s `chezmoi apply --init` (Ubuntu runner) and `shellcheck` jobs pass on the PR, giving a real-host confirmation of the Debian/Ubuntu package names (R5).
- No dead-end or experimental code from an abandoned approach remains in the diff.
