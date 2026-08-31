---
title: Fix SELinux Policies Syntax Error and Verify Modular System Subsystem Scripts - Plan
date: 2026-08-31
type: fix
topic: fix-selinux-policies-syntax-and-verify-modular-system-scripts
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/304 https://github.com/hyperlapse122/dotfiles/issues/305
---

# Fix SELinux Policies Syntax Error and Verify Modular System Subsystem Scripts - Plan

## Goal Capsule

- **Objective:** Fix the bash syntax error in `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl` caused by an unclosed `if ! command -v semodule` check (Issue #305), add regression testing to `.ci/test-selinux-protected-configs.sh`, and verify full compliance with the decentralized subsystem apply scripts and skip declaration matrix (Issue #304).
- **Means:** Add the missing `fi` to `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl`, add `bash -n "$rendered"` to `.ci/test-selinux-protected-configs.sh`, and execute the test suite (`.ci/check-skip-declarations.sh`, `.ci/test-selinux-protected-configs.sh`, `.ci/test-capability-cache.sh`, etc.) across all platforms.
- **Product authority:** GitHub Issues #304 and #305 in hyperlapse122/dotfiles.
- **Execution profile:** Template fix in `.chezmoiscripts/30-linux/` and test assertion in `.ci/`. Verification via isolated chezmoi template rendering and bash syntax checking.
- **Stop conditions:** Stop if `bash -n` fails on the rendered `selinux-policies.sh` script or if any CI test reports regression.
- **Tail ownership:** Local verification via `.ci/test-selinux-protected-configs.sh` and `.ci/check-skip-declarations.sh`. Pull request watch via `ce-babysit-pr`.

---

## Product Contract

*(Product Contract preservation: Product Contract unchanged)*

### Summary

Fix a critical syntax error in the SELinux policy installer template where a missing `fi` causes `chezmoi apply` to fail with exit status 2 on Fedora hosts, enforce syntax validation in the test suite, and ensure all modular system scripts satisfy Issue #304's decentralized provisioning requirements.

### Problem Frame

During `chezmoi apply` on Fedora, `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl` opens a conditional check `if ! command -v semodule >/dev/null 2>&1; then` but omits the closing `fi` after rendering the skip declaration. As a consequence, the rendered bash script has an unmatched `if` statement that triggers `bash: syntax error: unexpected end of file`, aborting chezmoi execution. Furthermore, `.ci/test-selinux-protected-configs.sh` rendered the template and inspected string contents but omitted a `bash -n` syntax validation pass, allowing the syntax defect to evade unit testing.

### Key Technical Decisions

- **KTD1: Explicit `fi` delimiter for semodule check.** Add `fi` immediately following the `skip.sh.tmpl` skip_here declaration for `semodule-absent`, preserving the skip declaration contract and isolating the probe from subsequent file hash calculation and installation logic.
- **KTD2: Rendered script syntax assertion in test suite.** Add `bash -n "$rendered"` to `.ci/test-selinux-protected-configs.sh` to ensure any future template render changes in `run_after_selinux-policies.sh.tmpl` are validated as executable bash.
- **KTD3: Verification of modular subsystem provisioning.** Validate that all subsystem scripts under `.chezmoiscripts/30-linux/` (`10-desktop`, `12-sudoers`, `14-sysctl`, `16-udev`, `18-hardware`, `20-bluetooth`, `22-host`, `24-keyd`) adhere to granular fingerprinting via `fingerprint.tmpl`, structured `.chezmoidata/system.yaml` manifests, and localized service reload triggers.

### Requirements

- R1. `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl` must render syntactically valid bash on Fedora and other supported OS targets.
- R2. The `semodule-absent` skip path must properly terminate with `exit 0` inside the closed `if` block, allowing execution to continue to `SRC_DIR` when `semodule` is present.
- R3. `.ci/test-selinux-protected-configs.sh` must assert that the rendered `selinux-policies.sh` passes `bash -n`.
- R4. All subsystem provisioners in `.chezmoiscripts/30-linux/` must pass skip declaration validation via `.ci/check-skip-declarations.sh`.

---

## Planning Contract

### Implementation Units

- **U1: Fix missing `fi` in `run_after_selinux-policies.sh.tmpl`**
  - **Files:** `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl`
  - **Approach:** Add `fi` after line 32 (the `semodule-absent` skip block) before `SRC_DIR="{{ $sourceDir }}/system/linux/selinux"`.
  - **Verification:** Render template via `chezmoi --source "$PWD" execute-template < .chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl` and run `bash -n`.

- **U2: Add syntax verification to `test-selinux-protected-configs.sh`**
  - **Files:** `.ci/test-selinux-protected-configs.sh`
  - **Approach:** Insert `bash -n "$rendered" || fail "rendered script failed bash syntax check"` into the test script.
  - **Verification:** Execute `.ci/test-selinux-protected-configs.sh` and verify all assertions pass.

- **U3: Full system test and skip declaration verification**
  - **Files:** `.ci/check-skip-declarations.sh`, `.ci/test-capability-cache.sh`
  - **Approach:** Run the test suites to ensure zero regressions across modular system scripts and skip declarations.
  - **Verification:** `.ci/check-skip-declarations.sh` and `.ci/test-selinux-protected-configs.sh` exit 0.

---

## Verification Contract

- **V1: Syntax check of rendered template:** `chezmoi --source "$PWD" execute-template < .chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl | bash -n` exits 0.
- **V2: Test suite execution:** `.ci/test-selinux-protected-configs.sh` exits 0 with message `test-selinux-protected-configs: all assertions passed.`
- **V3: Skip declaration verification:** `.ci/check-skip-declarations.sh` exits 0 with `rendered declaration surface matches the matrix`.

---

## Definition of Done

- [x] Plan written and implementation-ready.
- [ ] Syntax error in `.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl` resolved.
- [ ] Regression test in `.ci/test-selinux-protected-configs.sh` added and passing.
- [ ] Full CI skip declaration check passes without errors.
