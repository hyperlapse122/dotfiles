---
title: Skip Inapplicable Apply Scripts - Plan
type: refactor
date: 2026-09-19
topic: skip-inapplicable-apply-scripts
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Skip Inapplicable Apply Scripts - Plan

## Goal Capsule

- **Objective:** `chezmoi apply` on any managed host runs only the scripts that can do work on that host; a script that host facts alone prove inapplicable no longer runs, prints, or records a skip.
- **Means:** exclude those scripts from deployment through fact-gated `.chezmoiignore` entries and keep each script's runtime guard as a second line (KTD1).
- **Product authority:** the repository owner, in the session that produced this plan. The Product Contract wins on behavior; KTDs win on mechanism.
- **Stop conditions:** stop and report if any frozen total in the skip-declaration audit has to move, or if a guard consumer turns out to do work before its guard.
- **Execution profile:** four units, CI helper first; all verification runs through the stub-`op` render recipe in `AGENTS.md`, never against the live `$HOME`.
- **Finishing:** `ce-work` implements, then the change ships through a pull request with `render-dotfiles.yml` and `ci.yml` green.
- **Open blockers:** none.

---

## Product Contract

Product Contract preservation: changed Dependencies / Assumptions only — the re-run assumption and the inert-record assumption were corrected by planning research for returns to an earlier host state (see Scope Boundaries); R1-R9 and AE1-AE5 unchanged.

### Summary

Scripts whose whole-script skip is decided entirely by render-time host facts stop deploying on hosts where that skip would fire. The runtime guards stay in place, and a CI check keeps the exclusion rules and the guard consumers in step. On the owner's Fedora KDE ThinkPad this removes the seven GNOME scripts and thermald from every apply.

### Problem Frame

Every apply on the owner's KDE laptop runs scripts that can never do anything there. `install-gnome-kimpanel-extension` and `install-system-thermald` are `run_after_` scripts, so they start on every apply only to print a skip line. The other GNOME scripts are `run_onchange_`, and they run again each time their fingerprint moves, only to exit through `gnome-guard`.

This is deliberate. The fact-registry refactor kept the guards as runtime self-selection (KTD12 in `docs/plans/2026-07-14-001-refactor-chezmoidata-fact-registry-plan.md`) and deferred the non-deploy alternative "once the registry has settled". The registry has since settled: every guard reads a baked render-time fact, so chezmoi already knows before the apply which of these scripts will skip.

### Key Decisions

- **Scope is every whole-script skip that render-time facts alone decide, on every host.** (session-settled: user-directed — chosen over only the every-apply `run_after_` scripts and over only the desktop guards: the rule is the same for all of them, so a partial cut leaves the same waste elsewhere.) Governs R1, R2.
- **Exclude at deployment and keep the runtime guards.** (session-settled: user-directed — chosen over wrapping each script body in a render-time condition and over a new per-script applicability declaration: this leaves script bodies, skip declarations and the frozen skip-declaration audit untouched.) Governs R5, R7.
- **Drop the deploy-everywhere-and-self-select property of KTD12.** (session-settled: user-approved — chosen over keeping every script deployed on every host: that property is the reason the waste exists.) Governs R1, R9.
- **The headless guard is not a deployment gate.** `INSTALL_SYSTEM_CONFIG_FORCE=1` overrides it for one run, so the headless fact alone does not decide that skip. Governs R3.
- **A return to an earlier host state is re-run by hand, not by a new mechanism.** (session-settled: user-approved — chosen over invalidating chezmoi's run-state when a script re-enters deployment: returns are rare and the manual reset already exists for operator-blocking skips.) Governs R6.
- **A blocking skip record left by a now-excluded script is cleared by hand.** (session-settled: user-approved — chosen over extending the pre-apply record pruner: the case needs a failure followed by a fact change.) Governs R9.

### Requirements

**Coverage**

- R1. A script is not deployed on a host where one of these render-time conditions holds: desktop is not GNOME for `gnome-guard` consumers; desktop is not KDE for `kde-guard` consumers; `sharedHost` for `shared-host-guard` consumers; `virt`, no `battery`, or `thinkpad` for thermald; no `fingerprintReader` for the fingerprint installer; no `irCamera` for the face-auth installer; `jetson` for the Tailscale login.
- R2. The exclusion reads those conditions from the fact registry, the same source the guards read, and adds no new probe.
- R3. `headless-guard` consumers stay deployed on a headless host, so `INSTALL_SYSTEM_CONFIG_FORCE=1` keeps working.
- R4. A skip that depends on runtime state stays a runtime skip in a deployed script. Examples: thermald's non-Intel CPU check, tool presence, a live session bus, and a missing Plasma applet.

**Safety**

- R5. The scripts' runtime guards and skip declarations stay unchanged. The frozen totals in `.ci/skip-declaration-site-matrix.yaml`, `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` do not move.
- R6. When a host's facts change, for example a desktop swap, the next apply deploys and runs the newly applicable scripts with no manual step.

**Verification and record**

- R7. CI fails when a script that includes one of the R1 guards, or carries one of the R1 fact skips, has no matching exclusion rule. A new consumer cannot silently return to running on every host.
- R8. On the owner's host (Fedora, KDE, ThinkPad, bare metal, not shared), `chezmoi ignored` lists the seven GNOME scripts and thermald, and an apply prints no kimpanel or thermald skip line.
- R9. The repository's written record matches the new rule. This covers the guard partials that describe deploy-everywhere, the `sharedHost` fact description, and the relevant `AGENTS.md` text, including the manual recovery steps the last two Key Decisions accept.

### Acceptance Examples

- AE1. **Covers R1.** **Given** a KDE host, **when** chezmoi computes the target state, **then** every `gnome-guard` consumer is ignored and every `kde-guard` consumer is deployed.
- AE2. **Covers R3.** **Given** a headless host, **when** the operator runs an apply with `INSTALL_SYSTEM_CONFIG_FORCE=1`, **then** the `headless-guard` consumers are deployed and run past the headless guard.
- AE3. **Covers R4.** **Given** a bare-metal AMD laptop that is not a ThinkPad, **when** chezmoi computes the target state, **then** thermald is deployed and skips at runtime on the CPU check.
- AE4. **Covers R6.** **Given** a host that moves from KDE to GNOME for the first time, **when** the next apply runs, **then** the GNOME scripts are deployed and run, and the KDE scripts are ignored.
- AE5. **Covers R7.** **Given** a new script that includes `gnome-guard` with no exclusion rule, **when** CI runs, **then** the check fails and names the script.

### Scope Boundaries

- Step-level skips inside a script that otherwise does work stay as they are. Examples: KDE applet discovery, MOK and Secure Boot steps, keyd hardware detection, and the `thinkpad-absent` step in the hardware installer.
- No new fact is added. A CPU-vendor fact that would let thermald's Intel check move to deployment time is out of scope.
- The skip-declaration contract, its matrix, and the `dotfiles-skips` reader are unchanged.
- Returning to an earlier host state (KDE to GNOME and back, shared to single-owner and back) does not re-run the returning `run_onchange_` scripts by itself. chezmoi keeps their last run-state while they are ignored, so the returning render matches it. The operator re-runs them with `chezmoi apply --force` or by deleting the `entryState` bucket.
- A `transient-blocking` or `operator-blocking` record written by a script that later becomes excluded stays in `dotfiles-skips` until the operator deletes it, because no later run of that script clears it.

### Dependencies / Assumptions

- The exclusion goes in the existing fact-gated `home/.chezmoiignore`. That file already holds the precedent: `features.*` exclusions such as `72-camera-ipu6`, and KDE scripts ignored on a Jetson.
- Hook facts (`virt`, `battery`, `fingerprintReader`, `irCamera`) are written by the pre-read hook before `.chezmoiignore` renders. With no cache they resolve to their fail-safe `absentDefault`, which excludes the gated script; the next command with a cache deploys it.
- Every `shared-host-guard` include sits at the top level of its script, before any work, so excluding the whole script changes nothing that ran before.

### Sources / Research

- `docs/plans/2026-07-14-001-refactor-chezmoidata-fact-registry-plan.md` — KTD12 and the deferred non-deploy follow-up this plan picks up.
- `home/.chezmoitemplates/gnome-guard.sh.tmpl`, `kde-guard.sh.tmpl`, `headless-guard.sh.tmpl`, `shared-host-guard.sh.tmpl` — the guards and their stated rationale; only `headless-guard` has a per-run override.
- `home/.chezmoiscripts/30-linux/run_after_install-system-19-thermald.sh.tmpl` — the thermald fact and runtime skips.
- `home/.chezmoidata/facts.yaml` — `desktop`, `sharedHost`, `virt`, `battery`, `thinkpad`, `fingerprintReader`, `irCamera`, `jetson`.
- `.ci/skip-declaration-site-matrix.yaml` — the frozen audit that R5 keeps unchanged.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **One fact-gated block per R1 condition in `home/.chezmoiignore`, written in normalized target names.** (session-settled: user-directed — chosen over render-time emptying of script bodies and over a data declaration: see the Product Contract Key Decisions; governs R1, R2, R5.) Script targets drop the `run_*_` prefix and `.tmpl` (`run_after_install-system-19-thermald.sh.tmpl` → `.chezmoiscripts/30-linux/install-system-19-thermald.sh`), which `.ci/test-chezmoiignore-script-paths.sh` already enforces. The blocks read `$f` from the existing `facts.tmpl` binding at the top of the file.
- KTD2. **Desktop guards use directory globs; `shared-host-guard` consumers are listed one by one.** Every file in `50-linux-gnome/` (7) and `50-linux-kde/` (10) is a guard consumer, so `.chezmoiscripts/50-linux-gnome/*.sh` under `ne $f.desktop "gnome"` covers future files too. The 29 shared-host consumers sit in directories that also hold unguarded scripts (`chsh-zsh`, `import-wifi-1password`), so a glob would over-exclude. The existing Jetson KDE rule stays; it becomes redundant only on a Jetson whose desktop is not KDE.
- KTD3. **The CI render helper pins every fact the rendered template references, not a fixed list.** `write_fact_stub` in `.ci/lib/render-gate-helpers.sh` hard-codes six facts; any new `$f.<name>` in `.chezmoiignore` makes every caller fail with `map has no entry for key`. The helper reads the variable each source binds to `facts.tmpl` (`$f` in `.chezmoiignore`, `$facts` in `sudo-elevation-guard.sh.tmpl`), collects that variable's `.<name>` references, keeps its current explicit pins, and defaults every other referenced fact to `false`. A source with no facts include passes through unchanged; only a facts include that neither the `.` nor the `.ctx` substitution rewrote is an error. All five callers keep their current arguments.
- KTD4. **The parity check lives in `.ci/test-chezmoiignore-script-paths.sh`, discovers consumers from source, and is differential.** Guard consumers are found by their `includeTemplate "<guard>.sh.tmpl"` line, so a new consumer is caught without editing the test (R7). The six single-script fact skips across four scripts are found by their skip `site` ids (`thermald-virt-host`, `thermald-no-battery`, `thermald-dytc-platform`, `no-fingerprint-reader`, `no-ir-camera`, `jetson-off-tailnet`) against a small table of the fact value that fires each. U2 wraps the new block in begin and end marker comments. For each profile the test renders the ignore file twice, as-is and with the marked block removed; the scripts that only the as-is render ignores must equal the discovered consumers of every guard and fact skip that fires under that profile, minus any the stripped render already ignores. That one equality proves both halves: a missing rule leaves a firing consumer deployed, and an over-reaching rule ignores a script that is not a firing consumer.
- KTD5. **The profiles are the KDE baseline plus one firing profile per fact trigger, with every `features.*` flag enabled and each profile rendered once per managed distro.** The baseline is Linux, KDE, `battery`, `fingerprintReader`, `irCamera`, `nvidia` true, and `virt`, `thinkpad`, `sharedHost`, `jetson`, `container` false; under it only `gnome-guard` fires. Eight firing profiles each flip one trigger from the baseline: GNOME (covers `kde-guard`), `sharedHost`, `virt`, no `battery`, `thinkpad`, no `fingerprintReader`, no `irCamera`, `jetson`. Thermald's three triggers get separate profiles so every disjunct of its rule is exercised. Enabling every feature through `--override-data` and pinning `nvidia` true keep the existing feature and `nvidia` rules from hiding `30-components/10-nvidia.sh`. Every profile is rendered with the distro id set to `fedora` and again to `ubuntu`, not from the CI runner's real `.chezmoi.osRelease.id`, so each distro's shared-host base installer is deployed in the stripped render of at least one pass and cannot drop out of the equality.

### Implementation Constraints

- Verification renders only through the stub-`op` recipe in `AGENTS.md` (`PATH="$scratch/bin:/usr/bin:/bin"`, empty `--config`, throwaway `--destination`, `--source "$PWD"`). No unit runs `chezmoi apply` against the live `$HOME`.
- No script body, guard partial logic, skip declaration or `.ci/skip-declaration-site-matrix.yaml` row changes (R5). Comment text in guard partials may change (R9).

### Sequencing

U1 first: without it, U2 breaks every render gate that calls `render_ignore`. U3 follows U2, and U4 can land with U2 or after it.

---

## Implementation Units

### U1. Pin every referenced fact in the CI render helper

**Goal:** `render_ignore` keeps working when `.chezmoiignore` references facts beyond the six it pins today.

**Requirements:** R5 (no gate breaks), enables R7; KTD3.

**Dependencies:** none.

**Files:**
- `.ci/lib/render-gate-helpers.sh`
- Callers exercised as tests: `.ci/test-top-level-deployment-boundary.sh`, `.ci/test-gnupg-config-render.sh`, `.ci/test-source-root.sh`, `.ci/test-sudo-elevation-guard.sh`, `.ci/test-pinentry-card-wrapper.sh`

**Approach:**
1. Build the stub `dict` in `write_fact_stub` from the fact references KTD3 describes, instead of the fixed list.
2. Keep the positional parameters (`container`, `jetson`, `desktop`) and the fixed `distro`/`headless`/`nvidia` values as explicit pins; every other referenced fact defaults to `false`.
3. Keep both substitution forms (`.` and `.ctx`) the helper already rewrites.

**Patterns to follow:** reference extraction in `.ci/test-chezmoiignore-script-paths.sh` `render_ignore_variant`; the helper's own comment block on why `desktop` is a parameter.

**Test scenarios:**
- Given an ignore template that references a fact the helper never pinned, `render_ignore` renders it with that fact `false` instead of failing on a missing key.
- Given a partial that binds `$facts` from `.ctx`, the helper pins the facts that partial references.
- Given a source with no facts include, such as the `test-source-root.sh` fixture, the helper passes it through unchanged.
- Given a facts include that neither substitution form rewrote, the helper fails loudly rather than rendering unpinned facts.

**Verification:** the five caller tests pass before and after U2 lands.

### U2. Exclude inapplicable scripts in `.chezmoiignore`

**Goal:** every R1 script is ignored on a host where its whole-script skip would fire.

**Requirements:** R1, R2, R3, R4, R6, R8; KTD1, KTD2.

**Dependencies:** U1.

**Files:**
- `home/.chezmoiignore`
- Any existing assertion that expects a now-ignored script to deploy, in `.ci/test-chezmoiignore-script-paths.sh` or `.ci/top-level-boundary-inventory.yaml`

**Approach:**
1. Add a commented block after the `features.*` block, one conditional per R1 condition, as KTD1 and KTD2 define: GNOME directory, KDE directory, thermald (`or $f.virt (not $f.battery) $f.thinkpad`), fingerprint installer, face-auth installer, Tailscale login under `jetson`, and the 29 shared-host consumers under `$f.sharedHost`.
2. Wrap the block in begin and end marker comments that U3's differential render strips (KTD4).
3. The block comment states the rule once: a script leaves deployment only when a render-time fact alone decides its whole-script skip, and its runtime guard stays.
4. Do not add a `headless` condition (R3) and do not touch the container block.

**Patterns to follow:** the `features.intelIpu6` and `$f.jetson` blocks in `home/.chezmoiignore`.

**Test scenarios:**
- Covers AE1. KDE baseline profile: all seven `50-linux-gnome` targets ignored, all ten `50-linux-kde` targets deployed.
- GNOME profile: the reverse of AE1.
- Headless profile (`desktop` none): both desktop directories ignored, every `headless-guard` consumer outside the R1 lists deployed.
- Covers AE3. Bare-metal laptop with `battery` true, `thinkpad` false, `virt` false: thermald deployed.
- Owner's host profile (KDE, `thinkpad` true, `battery` true): `chezmoi ignored` lists the seven GNOME targets and thermald (R8).
- `sharedHost` true: all 29 consumers ignored; `chsh-zsh` and `import-wifi-1password` still deployed.

**Verification:** the stub-`op` `chezmoi ignored` render on the owner's host lists the R8 set among scripts, no other script changed status versus `main`, and `.ci/test-chezmoiignore-script-paths.sh` passes.

### U3. Enforce guard and exclusion parity in CI

**Goal:** CI fails when an R1 guard consumer or fact-skip script has no matching exclusion, or when an exclusion over-reaches.

**Requirements:** R7, R5; KTD4, KTD5.

**Dependencies:** U1, U2.

**Files:**
- `.ci/test-chezmoiignore-script-paths.sh`

**Approach:**
1. Extend `render_ignore_variant` to accept a full fact profile and `features` override data, keeping the existing six variants working.
2. Discover consumers per KTD4 and normalize them with the existing `normalize_script_path`.
3. For the KTD5 baseline and each firing profile, run KTD4's differential equality and report any missing or extra target by name.
4. Add mutant cases in the file's existing mutant style for the scenarios below.

**Patterns to follow:** `is_path_ignored`, `validate_rendered_rules` and the mutant harness in the same file.

**Test scenarios:**
- Covers AE5. A consumer of `gnome-guard` outside `50-linux-gnome/` with no rule fails the check and the message names its target.
- A `shared-host-guard` consumer added to `30-linux/` without a per-file rule fails under the `sharedHost` firing profile.
- Removing thermald's rule fails under the `thinkpad` firing profile.
- A rule in the `sharedHost` block that also ignores an unguarded `30-linux` script fails under the `sharedHost` firing profile.
- A consumer that an unrelated rule already ignores in one pass, such as the Fedora base installer in the `ubuntu` pass of the `sharedHost` profile, does not fail the check.
- Removing `30-components/10-nvidia.sh` or `20-base/fedora/base.sh` from the `sharedHost` block fails under the `sharedHost` firing profile, on a runner of either distro.
- Removing the `virt` or the no-`battery` disjunct from thermald's rule fails under that trigger's firing profile.
- The unchanged repository passes every assertion.

**Verification:** the test passes on the U2 tree and fails on each mutant; `.github/workflows/ci.yml` already runs it in the render-gates job, so no workflow edit is needed.

### U4. Update the written record

**Goal:** the repository describes the new deployment rule and the two accepted manual recoveries (R9).

**Requirements:** R9; the last two Product Contract Key Decisions.

**Dependencies:** U2.

**Files:**
- `home/.chezmoitemplates/gnome-guard.sh.tmpl` (comment)
- `home/.chezmoitemplates/kde-guard.sh.tmpl` (comment)
- `home/.chezmoitemplates/shared-host-guard.sh.tmpl` (comment)
- `home/.chezmoidata/facts.yaml` (`sharedHost` `gates:` text)
- `AGENTS.md`

**Approach:**
1. `gnome-guard.sh.tmpl` and `kde-guard.sh.tmpl` comments: replace "Deploy-everywhere-and-self-select is unchanged (KTD12) … stays a runtime skip, not a non-deployment gate" with the new rule — `.chezmoiignore` keeps non-matching hosts from deploying the script, and the guard is the second line.
2. `shared-host-guard.sh.tmpl` comment and `facts.yaml` `sharedHost` `gates:`: drop the stale claim that package installation and package-source trust are not gated (every installer that includes the guard skips whole), and name the deployment exclusion.
3. `AGENTS.md`, host facts and skip sections: state that a whole-script skip decided purely by render-time facts is also a `.chezmoiignore` exclusion checked by `.ci/test-chezmoiignore-script-paths.sh`; that `headless-guard` is exempt because of its override; and the two manual recoveries (`chezmoi apply --force` or deleting `entryState` after returning to an earlier host state; deleting a stale blocking record reported by `dotfiles-skips`).

**Test expectation:** none — comment and documentation text only; the rendered guard output does not change.

**Verification:** `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` pass with unchanged totals; `git diff` shows comment-only changes in the three partials.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Ignore parity and paths | `.ci/test-chezmoiignore-script-paths.sh` | R1, R3, R4, R7 (U2, U3) |
| Render gates on the helper | `.ci/test-top-level-deployment-boundary.sh`, `.ci/test-gnupg-config-render.sh`, `.ci/test-source-root.sh`, `.ci/test-sudo-elevation-guard.sh`, `.ci/test-pinentry-card-wrapper.sh` | U1 keeps existing gates green |
| Frozen skip audit | `.ci/check-skip-declarations.sh`, `.ci/test-capability-cache.sh` | R5 |
| Owner's host | stub-`op` `chezmoi ignored` per the `AGENTS.md` recipe, filtered to `.chezmoiscripts` | R8 |
| Hygiene | `git diff --check`; diff limited to the files the units name | scope |
| Delivery | `render-dotfiles.yml` and `ci.yml` green on the pull request | whole change |

## Definition of Done

- U1-U4 are implemented and every Verification Contract gate passes.
- On the owner's host the stub-`op` `chezmoi ignored` output lists the seven GNOME targets and thermald among scripts, and nothing else changed status versus `main` except R1 targets.
- No script body, skip declaration, or skip-matrix row changed.
- No abandoned experiment remains in the diff.
