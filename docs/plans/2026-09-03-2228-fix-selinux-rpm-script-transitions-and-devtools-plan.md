---
title: SELinux RPM Scriptlet Transitions and Policy Tooling - Plan
type: fix
date: 2026-09-03
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# SELinux RPM Scriptlet Transitions and Policy Tooling - Plan

## Goal Capsule

- **Objective:** Fix package manager execution in SELinux-confined agent domains (avoiding denied scriptlet executions such as akmods/NVIDIA kernel module builds) and ensure SELinux policy query tools are installed and verified on Fedora hosts.
- **Means:** 
  1. Declare `python3-setools` and `setools-console` in `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl` and add package existence assertions and comment fixes in `.ci/test-selinux-protected-configs.sh` ([#370](https://github.com/hyperlapse122/dotfiles/issues/370)).
  2. Grant `dotfiles_agent_domain` transition, process inheritance, and fd use permissions to `rpm_script_t` in `system/linux/selinux/dotfiles_protected_agent_configs.cil`, update the base-policy test stub and assertions in `.ci/test-selinux-protected-configs.sh`, and update documentation ([#372](https://github.com/hyperlapse122/dotfiles/issues/372)).
- **Authority:** GitHub issues [#370](https://github.com/hyperlapse122/dotfiles/issues/370) and [#372](https://github.com/hyperlapse122/dotfiles/issues/372).
- **Execution profile:** Source-state only. No manual PAM edits, no weakening of protected type isolation.
- **Stop conditions:** Stop and report if protected types gain any base attribute or if offline tests fail.
- **Tail ownership:** `ce-work` executes implementation and local verification; `lfg` handles simplification, review, commit, push, PR, babysit, and merge.

---

## Product Contract

### Summary

Confined agent domains (`chezmoi_t`, `claude_t`, `agy_t` under `dotfiles_agent_domain`) execute package managers (`dnf`, `rpm`) during provisioning and active agent sessions. When rpm executes package scriptlets (`%pre`, `%post`, etc., such as `akmod-nvidia` building kernel modules), rpm transitions the scriptlet process to `rpm_script_t`. In standard Fedora policy, `unconfined_t` is granted `process { transition }` to all domains, but `dotfiles_agent_domain` does not hold this unconfined transition. Consequently, rpm scriptlet execution fails with AVC denials, preventing kernel module builds while rpm exits cleanly.

Additionally, diagnosing policy issues and running offline compiled-policy queries on Fedora workstations requires `sesearch`, `seinfo`, and `setools`, which are missing unless `python3-setools` and `setools-console` are declared in the host devtools package set.

This plan lands both fixes with complete offline test coverage and no leakage of permissions to protected agent configs.

### Problem Frame

1. **RPM Scriptlet Execution Failure (#372):** When `dnf install` runs in `chezmoi_t` (or from an agent session in `claude_t`/`agy_t`), rpm attempts to run scriptlets under `rpm_script_t`. `dotfiles_agent_domain` lacks the process transition and fd use rules to/from `rpm_script_t`, causing silent or ignored scriptlet execution failures.
2. **Missing SELinux Inspection Tools (#370):** Managed Fedora workstations lack `sesearch`, `seinfo`, and the `setools` python library because `python3-setools` (and `setools-console` which provides the CLI binaries on Fedora) is not listed in `dev_packages`. Furthermore, `.ci/test-selinux-protected-configs.sh` contains a stale comment stating that CI runners lack setools, when in fact CI installs it and the managed host was the missing environment.

### Requirements

- **R1.** `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl` declares `python3-setools` and `setools-console` in `dev_packages` under CLI utilities.
- **R2.** `.ci/test-selinux-protected-configs.sh` asserts that `python3-setools` is present in `run_onchange_before_80-devtools.sh.tmpl`.
- **R3.** `.ci/test-selinux-protected-configs.sh` stale comment at line 362 is updated to reflect that setools is supported on both CI and managed hosts.
- **R4.** `system/linux/selinux/dotfiles_protected_agent_configs.cil` grants `dotfiles_agent_domain` process transition, `siginh`, `rlimitinh`, `noatsecure`, and `fd (use)` to `rpm_script_t`, and grants `rpm_script_t` `fd (use)` and `process (sigchld)` to `dotfiles_agent_domain`.
- **R5.** `rpm_script_t` is referenced, not defined as a new type, in `dotfiles_protected_agent_configs.cil`.
- **R6.** `.ci/test-selinux-protected-configs.sh` adds `(type rpm_script_t)` and process permissions (`rlimitinh`, `noatsecure`) to its offline `base_stub.cil` so that `secilc` compiles cleanly without errors.
- **R7.** `.ci/test-selinux-protected-configs.sh` asserts the presence of the new `rpm_script_t` transition rules in `dotfiles_protected_agent_configs.cil`.
- **R8.** `rpm_script_t` is asserted to have no mutating access to `protected_agent_config_t`, `claude_config_t`, or `gemini_config_t`.
- **R9.** Existing protected config assertions remain green and no protected types gain any base attributes.

### Success Criteria

- `.ci/test-selinux-protected-configs.sh` passes completely with compiled-policy verification.
- Both GitHub issues #370 and #372 are cleanly resolved.

---

## Technical Design

### KTD1: SELinux CIL Policy Additions for RPM Scriptlets

In `system/linux/selinux/dotfiles_protected_agent_configs.cil`, under Process inheritance and lifecycle:
```lisp
; RPM SCRIPTLETS. dnf runs from an apply script, so it runs in chezmoi_t, and
; rpm transitions each scriptlet into rpm_script_t. The base policy's
; type_transition fires for this domain through unconfined_domain_type, but the
; paired allow does not cover it, so the scriptlet exec is denied and the
; package installs with its %post never run.
(allow dotfiles_agent_domain rpm_script_t (process (transition siginh rlimitinh noatsecure)))
(allow dotfiles_agent_domain rpm_script_t (fd (use)))
(allow rpm_script_t dotfiles_agent_domain (fd (use)))
(allow rpm_script_t dotfiles_agent_domain (process (sigchld)))
```

### KTD2: Devtools Package Declarations

In `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`:
Add `python3-setools` and `setools-console` alphabetically to CLI utilities and system monitoring.

### KTD3: Test Suite Extension

In `.ci/test-selinux-protected-configs.sh`:
1. Add check:
   `grep -qF -- "python3-setools" "$repo_root/.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl" || fail "devtools missing python3-setools package"`
2. In `base_stub`:
   Add `(type rpm_script_t)`
   Update `(class process (...))` to include `rlimitinh noatsecure`
3. Add token assertions for `dotfiles_protected_agent_configs.cil`:
   - `(allow dotfiles_agent_domain rpm_script_t (process (transition siginh rlimitinh noatsecure)))`
   - `(allow dotfiles_agent_domain rpm_script_t (fd (use)))`
   - `(allow rpm_script_t dotfiles_agent_domain (fd (use)))`
   - `(allow rpm_script_t dotfiles_agent_domain (process (sigchld)))`
4. In python compiled policy check:
   Verify `('rpm_script_t', 'protected_agent_config_t'): False`, `('rpm_script_t', 'claude_config_t'): False`, `('rpm_script_t', 'gemini_config_t'): False`.
5. Update comment at line 362.

---

## Implementation Units

### U1: Declare python3-setools and setools-console in Devtools (#370)
- **Target:** `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`
- **Action:** Add `python3-setools` and `setools-console` to `dev_packages`.
- **Verification:** `grep -qF python3-setools` and `grep -qF setools-console`.

### U2: Grant dotfiles_agent_domain -> rpm_script_t Transition Rules (#372)
- **Target:** `system/linux/selinux/dotfiles_protected_agent_configs.cil`
- **Action:** Add the 4 allow rules for `rpm_script_t` transitions and fd use.
- **Verification:** Inspect CIL syntax and structure.

### U3: Update Test Suite and Base Policy Stub (#370, #372)
- **Target:** `.ci/test-selinux-protected-configs.sh`
- **Action:** Add `python3-setools` package check, declare `(type rpm_script_t)` and process permissions in `base_stub`, add token checks, add compiled policy non-mutation assertions for `rpm_script_t`, and fix the stale comment.
- **Verification:** Run `./.ci/test-selinux-protected-configs.sh`.

---

## Verification Plan

- Run `./.ci/test-selinux-protected-configs.sh` to prove:
  1. `python3-setools` package check passes.
  2. `secilc` compiles `base_stub` and `dotfiles_protected_agent_configs.cil` cleanly without errors.
  3. CIL token assertions pass.
  4. Compiled policy query confirms `rpm_script_t` cannot write any protected types.
  5. The file_type non-regression assertions pass.
- Run `git diff` to verify clean changes.
