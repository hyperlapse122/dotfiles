---
title: Position-Independent Script Rendering - Plan
type: refactor
date: 2026-09-16
topic: position-independent-script-rendering
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** Eliminate false-positive script re-execution cascades across feature worktrees by rendering all Chezmoi onchange scripts with position-independent source path resolution.
- **Means:** Replace compile-time `$sourceDir` path interpolation in 17 script templates with inline runtime parameter expansion `${CHEZMOI_SOURCE_DIR:-$(chezmoi source-path)}` (KTD1).
- **Product Authority:** `github.com/hyperlapse122/dotfiles`
- **Open Blockers:** None

---

## Product Contract

### Summary
Position-Independent Script Rendering (PISR) decouples rendered script bodies from compile-time `$sourceDir` literals across all 17 onchange script templates (`30-linux/install-system-*`, `00-tools/`, and `60-build/`). Rendered script text becomes 100% bit-identical regardless of the invoking checkout directory while preserving strict content-based change detection via `fingerprint.tmpl`.

### Problem Frame
Chezmoi scripts in `.chezmoiscripts/30-linux/` and build templates currently interpolate `{{ $sourceDir }}` directly into executable script bodies (e.g. `SRC_ROOT="{{ $sourceDir }}/system/linux"`). Chezmoi decides whether to run a `run_onchange_` script by hashing the entire rendered script text.

When an operator or autonomous agent works in an Orca feature worktree (`~/.local/share/worktrees/*`), this literal path changes across 48 templates, invalidating rendered script hashes and queuing ~20 root-privileged sudo scripts across the live machine. This breaks worktree isolation and forces hazardous manual workarounds.

### Key Decisions
- **KTD1. Inline Parameter Expansion over Centralized Helper** `(session-settled: user-approved — chosen over centralized partial: eliminates template dependencies and adds zero runtime subshell overhead during standard chezmoi apply)`. Governs R1, R2, R3.
- **KTD2. Comprehensive Decoupling Boundary** `(session-settled: user-directed — chosen over system-only: prevents worktree re-execution cascades across all 12 system installers, 4 build scripts, and mise-trust)`. Governs R1, R2.
- **KTD3. Integrated Test Suite Verification** `(session-settled: user-directed — chosen over dedicated new test file: position-independence assertions integrate directly into .ci/test-fingerprint-gates.sh)`. Governs R4.

### Requirements

#### Template Rendering & Path Resolution
- R1. All 12 `.chezmoiscripts/30-linux/run_onchange_after_install-system-*.sh.tmpl` scripts must replace `SRC_ROOT="{{ $sourceDir }}/system/linux"` with `SRC_ROOT="${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}/system/linux"`.
- R2. All 4 build scripts (`10-build-command-reconcile`, `20-build-orchestration-hook`, `60-build-gem80-rgb`, `build-settings-reconcile`) and `run_once_before_mise-trust.sh.tmpl` must replace literal `$sourceDir` assignments with `${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}`.
- R3. Rendered script text for every updated template must produce identical content whether rendered with `--source` pointing to the primary checkout or any feature worktree path.

#### Verification & CI Invariant
- R4. `.ci/test-fingerprint-gates.sh` must assert that rendering all covered `run_onchange_` scripts against two distinct mock source roots produces bit-identical rendered bodies.
- R5. Existing content-based change detection via `.chezmoitemplates/fingerprint.tmpl` must remain fully intact and functional.

### Key Flows
- F1. Normal apply in primary checkout
  - **Trigger:** Operator or automation runs `chezmoi apply`.
  - **Actors:** Chezmoi engine, script runner.
  - **Steps:** Chezmoi exports `CHEZMOI_SOURCE_DIR`; script consumes variable instantly without subshell fallback; script executes unchanged.
  - **Covered by:** R1, R2, R5.
- F2. Feature worktree apply
  - **Trigger:** Operator or agent runs `chezmoi --source=<worktree> apply`.
  - **Actors:** Orca feature worktree, Chezmoi engine.
  - **Steps:** Chezmoi renders script templates; rendered text is bit-identical to primary checkout; hash matches state bucket; script skips execution unless relative file dependencies changed.
  - **Covered by:** R3, R5.
- F3. Standalone manual execution
  - **Trigger:** Developer or debug test invokes a rendered script directly from `/tmp/`.
  - **Actors:** Developer, shell.
  - **Steps:** `CHEZMOI_SOURCE_DIR` is unset; shell parameter expansion falls back to `chezmoi source-path` or `pwd`; path resolves correctly.
  - **Covered by:** R1, R2.

### Acceptance Examples
- AE1. Worktree Path Invariance
  - **Covers:** R1, R2, R3
  - **Given:** A system script template `run_onchange_after_install-system-16-udev.sh.tmpl`
  - **When:** Rendered with `--source /home/user/src/dotfiles` and with `--source /home/user/.local/share/worktrees/dotfiles/feat-branch`
  - **Then:** Diff between both rendered script outputs is completely empty.
- AE2. Content Change Sensitivity
  - **Covers:** R5
  - **Given:** A modified file in `system/linux/etc/udev/rules.d/`
  - **When:** Rendered via `chezmoi execute-template`
  - **Then:** The SHA256 in the fingerprint comment line changes, causing Chezmoi to detect change and execute only that owning script.

### Scope Boundaries
- **In Scope:**
  - Decoupling `$sourceDir` across all 12 system installer scripts in `30-linux/`.
  - Decoupling `$sourceDir` across the 4 build scripts in `00-tools/` and `60-build/`.
  - Decoupling `$sourceDir` in `run_once_before_mise-trust.sh.tmpl`.
  - Adding position-independence verification assertions into `.ci/test-fingerprint-gates.sh`.
- **Out of Scope:**
  - Modifying `fingerprint.tmpl`'s hashing algorithm (it already trims `$sourceDir` and emits relative path comments).
  - Implementing targeted CLI runner `dotfiles-apply-targeted` (separate follow-up work).
  - Modifying `AGENTS.md` instructions or Orca worktree management workflows.

### Sources / Research
- `docs/solutions/integration-issues/chezmoi-worktree-root-etc-file-deployment.md` (documented failure mode and root cause)
- `docs/ideation/2026-09-16-repo-exploration-ideation.html` (provenance: Idea 1 from ce-ideate)

---

## Planning Contract

### Key Technical Decisions
- KTD1. **Pure Parameter Expansion with Two-Tier Fallback:**
  Scripts resolve the root path via:
  ```bash
  "${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}"
  ```
  During all normal Chezmoi apply runs, `CHEZMOI_SOURCE_DIR` is set by Chezmoi's process environment, executing as an instant parameter expansion without spawning subshells. For manual execution outside Chezmoi, it falls back to `chezmoi source-path`, then current working directory. Governs R1, R2.
- KTD2. **Relative Path Preservation in Fingerprints:**
  `.chezmoitemplates/fingerprint.tmpl` continues to receive `.chezmoi.sourceDir` at template render time so its `glob` functions can scan the physical source directory on disk. `fingerprint.tmpl` already trims the source directory prefix from emitted comment lines (e.g. `#   system/linux/etc/...  <hash>`). The template requires zero modifications because its rendered output is already position-independent. Governs R5.
- KTD3. **Matrix Verification in `.ci/test-fingerprint-gates.sh`:**
  The existing test harness creates two temporary source directories with identical relative contents and asserts that rendering each script template across both roots produces byte-for-byte identical output. Governs R4.

### Technical Assumptions & Implementation Constraints
- Chezmoi 2.x guarantees `CHEZMOI_SOURCE_DIR` is exported to child script processes during `chezmoi apply`.
- All paths referenced relative to `$SRC_ROOT` or `$SRC` exist inside the repository source tree (`system/linux/etc/*`, `packages/*`, `crates/*`, `mise.toml`).

---

## Implementation Units

### U1. Decouple System Installer Templates (30-linux)
- **Goal:** Replace compile-time `$sourceDir` path interpolation with runtime parameter expansion across all 12 system installer scripts.
- **Requirements:** R1, R3, R5
- **Files:**
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-desktop.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-12-sudoers.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-14-sysctl.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-18-hardware.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-20-bluetooth.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-22-host.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-24-keyd.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-26-swap-hibernate.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-28-sleep.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-30-network.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_onchange_after_install-system-32-fingerprint.sh.tmpl`
- **Approach:**
  Replace:
  ```bash
  SRC_ROOT="{{ $sourceDir }}/system/linux"
  ```
  with:
  ```bash
  SRC_ROOT="${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}/system/linux"
  ```
  Retain `{{ $sourceDir := .chezmoi.sourceDir -}}` at the top of templates where passed to `fingerprint.tmpl`.
- **Test Scenarios:**
  Render templates with `--source=/tmp/mock-source-a` and `--source=/tmp/mock-source-b`; verify `diff` between outputs is empty.
- **Verification:**
  `chezmoi --source="$PWD" execute-template < .chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl` does not contain `$PWD` in the rendered script body.

### U2. Decouple Tool Build & Trust Templates (00-tools, 60-build)
- **Goal:** Decouple `$sourceDir` from the 4 build scripts and `run_once_before_mise-trust.sh.tmpl`.
- **Requirements:** R2, R3, R5
- **Files:**
  - `.chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl`
  - `.chezmoiscripts/00-tools/run_once_before_mise-trust.sh.tmpl`
  - `.chezmoiscripts/60-build/run_onchange_after_20-build-orchestration-hook.sh.tmpl`
  - `.chezmoiscripts/60-build/run_onchange_after_60-build-gem80-rgb.sh.tmpl`
  - `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl`
- **Approach:**
  In build templates, replace:
  ```bash
  SRC="{{ $sourceDir }}"
  ```
  with:
  ```bash
  SRC="${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}"
  ```
  In `mise-trust.sh.tmpl`, replace:
  ```bash
  config="{{ .chezmoi.sourceDir }}/mise.toml"
  ```
  with:
  ```bash
  config="${CHEZMOI_SOURCE_DIR:-$(command -v chezmoi >/dev/null 2>&1 && chezmoi source-path || pwd)}/mise.toml"
  ```
- **Test Scenarios:**
  Render each template across two mock source roots; verify rendered text is bit-identical.
- **Verification:**
  `chezmoi execute-template < .chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl` contains no hardcoded source path.

### U3. Integrate Position-Independence Gate into CI Test Suite
- **Goal:** Add an automated regression gate into `.ci/test-fingerprint-gates.sh` verifying that rendered scripts do not leak `$sourceDir` literals.
- **Requirements:** R4
- **Files:**
  - `.ci/test-fingerprint-gates.sh`
- **Approach:**
  Add a test loop in `test-fingerprint-gates.sh` that renders all covered `run_onchange_` templates against two distinct mock source directories and asserts that `diff -u` between the two outputs is empty. Fails the test if any template embeds an absolute path.
- **Test Scenarios:**
  - Run `.ci/test-fingerprint-gates.sh` and verify it passes.
  - Temporarily inject a literal `{{ $sourceDir }}` and verify the test gate catches it and fails.
- **Verification:**
  `bash .ci/test-fingerprint-gates.sh` exits 0.

---

## Verification Contract

- Run `.ci/test-fingerprint-gates.sh` to prove position independence across all templates.
- Run `bash .ci/test-ci-wiring.sh` to ensure CI configuration remains valid.
- Run `git diff --check` to ensure no trailing whitespace or formatting defects.

---

## Definition of Done

1. All 12 `install-system-*.sh.tmpl` scripts in `.chezmoiscripts/30-linux/` use runtime `SRC_ROOT` resolution.
2. All 4 build scripts in `00-tools/` and `60-build/` plus `mise-trust` use runtime `SRC`/`config` resolution.
3. `.ci/test-fingerprint-gates.sh` gates against position-dependent path leaks and passes.
4. Clean working tree with no temporary files.
