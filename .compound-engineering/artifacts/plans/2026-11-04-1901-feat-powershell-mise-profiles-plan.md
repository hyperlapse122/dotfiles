---
title: PowerShell mise Profiles - Plan
type: feat
date: 2026-11-04
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# PowerShell mise Profiles - Plan

## Goal Capsule

- **Objective:** New local PowerShell sessions on Windows, macOS, and Linux activate mise without manual setup in each session.
- **Means:** Repository-owned CurrentUserAllHosts profiles, installed through explicit chezmoi application (KTD1–KTD3).
- **Authority:** The Product Contract governs behavior; the Planning Contract governs implementation within it; units do not override either.
- **Execution profile:** One PR, with U1 before U2. This document authorizes planning only; implementation and shipping require a subsequent instruction.
- **Stop conditions:** Stop before writing outside a verified profile target or if implementation cannot cover a required runtime. Do not silently drop Windows PowerShell 5.1 or an OS.
- **Completion owner:** The implementer finishes verification and documentation; shipping follows the user's selected workflow.

## Product Contract

### Summary

Apply the same mise startup configuration to PowerShell on all three supported operating systems and to Windows PowerShell 5.1 on Windows.
The repository owns the entire selected profile, rather than a block within existing local content.

### Problem Frame

The requested outcome is automatic mise activation whenever the user starts a local PowerShell session.
Windows PowerShell and modern PowerShell use different user profiles, and the effective locations can vary by platform and user configuration.

### Requirements

**Startup coverage**

- R1. Profile-loading local PowerShell 7+ sessions on Windows, macOS, and Linux execute `(&mise activate pwsh) | Out-String | Invoke-Expression` at startup.
- R2. Profile-loading local Windows PowerShell 5.1 sessions execute the same command at startup.
- R3. Use each runtime's CurrentUserAllHosts profile so the setting is shared by its local hosts without editing host-specific or all-users profiles.

**Repository ownership and application**

- R4. Explicit application creates a missing selected profile and completely replaces an existing one with repository content; local customizations in that file are intentionally discarded.
- R5. Repeated application produces the same profile content and restores repository content after local edits.
- R6. Initialization remains read-only for personal configuration; profile writes occur only during explicit chezmoi application.

### Key Decisions

- **Whole-file ownership instead of preservation.** The repository takes precedence over local profile customizations. Governs R4, R5. (session-settled: user-directed — chosen over managed-block merging: the user explicitly requires repository content to replace existing profiles.)

### Scope Boundaries

- Do not alter host-specific profiles, other shells, persistent execution policy, remote-session behavior, or starts using `-NoProfile`.
- mise must already be installed and available on the startup PATH; installing it or adding new PATH discovery/fallback logic is outside this change.
- Do not suppress mise's Windows PowerShell 5.1 warning or emulate PowerShell 7 directory-change hooks; those are upstream runtime differences.
- Do not add profile backups, merging, or recovery modes: R4 deliberately selects replacement.

## Planning Contract

### Key Technical Decisions

- KTD1. **Use runtime-reported profile targets.** Run each applicable shell without loading profiles and use its `$PROFILE.CurrentUserAllHosts`, not a hardcoded Documents path. Windows folder redirection and Unix configuration roots can place these files outside chezmoi's destination tree. This makes an apply-time script appropriate under the repository rule reserving scripts for work not representable as portable managed files. Implements R1–R4.
- KTD2. **Keep one profile payload and one writer.** Add a shared profile partial containing the requested activation line and a shared PowerShell writer partial that creates the parent and replaces the complete target. Use .NET file APIs compatible with 5.1, explicit UTF-8 output, and unchanged-content comparison to avoid needless rewrites. Do not execute activation during apply. Implements R4, R5.
- KTD3. **Use ordinary, OS-conditional apply hooks.** Add Windows `.cmd` and Unix `.sh` wrappers using the existing padded `run_after_` convention. Windows invokes its system Windows PowerShell 5.1 plus the mise-declared modern PowerShell; macOS/Linux invoke only the modern runtime. Use `mise exec` to locate the declared modern runtime without depending on activation already being configured. All writer processes start with `-NoProfile`, and wrapper failures propagate as apply failures. Implements R1, R2, R6.
- KTD4. **Keep runtime limits visible.** Document that Windows execution policy can prevent profile loading and that host-specific profiles load later and can override startup state. Windows PowerShell 5.1 updates the mise environment at the next prompt rather than immediately on directory changes. Neither limitation calls for an OS-policy change or warning suppression.

### Risks and Dependencies

The existing `mise.toml` declares PowerShell, and its postinstall bootstrap enumerates managed entries while excluding scripts.
The new apply hooks must preserve that boundary and use the current worktree source, not a global chezmoi source.

Profile targets are obtained from the real account during normal application; changing HOME alone is not a safe Windows test-isolation strategy because Windows can resolve Documents through the OS.
Tests must redirect the writer's profile target in a child process before invoking it, rather than writing to the developer's real profile.

## Implementation Units

### U1. Install repository-owned profiles for every supported runtime

**Goal:** Deliver the full startup configuration and replacement behavior.

**Requirements:** R1–R6.

**Dependencies:** None.

**Files:** Create `home/.chezmoitemplates/powershell-mise-profile`, `home/.chezmoitemplates/powershell-mise-profile-install`, `home/run_after_30-powershell-mise-profile.cmd.tmpl`, `home/run_after_30-powershell-mise-profile.sh.tmpl`, and `tests/test_powershell_profile.py`.

**Approach:**

1. Implement the shared payload and writer under KTD1 and KTD2, with the latter receiving the current runtime's profile target through the normal PowerShell profile variable.
2. Embed the writer in platform wrappers under KTD3, following the repository's existing encoded PowerShell transport where needed for quoting and encoding.
3. Keep template rendering side-effect-free. Do not evaluate shell-discovery commands while chezmoi enumerates the source.
4. Keep test destinations wholly disposable, including spaces and non-ASCII characters.

**Patterns to follow:** `home/run_after_10-reload-gpg-agent.cmd.tmpl` for profile-free Windows invocation, `home/run_after_10-personal-app-path.sh.tmpl` for Unix apply hooks, and `tests/test_native_ca_windows.py` for child-process isolation around a shared production partial.

**Execution note:** This is configuration delivery; prove the rendered profile with real PowerShell and real mise before adding coverage for uncertain replacement boundaries.

**Test scenarios:**

1. With a missing nested profile target, execute the writer and then load that file in a real applicable shell; mise's activation state is observable in the same session.
2. Seed an existing profile with a visible custom side effect, apply the writer, and load the resulting file; mise activates and the old custom side effect does not run. Repeat after a local edit to prove R4 and R5.
3. Reapply to an already installed profile and confirm equivalent behavior with no duplicate hook installation. Verify the file is not rewritten when its content is unchanged.
4. On Windows, exercise the writer with both Windows PowerShell 5.1 and modern PowerShell using separate temporary profile targets; neither target nor sibling host-specific sentinel files are modified by the other runtime's write.
5. A real file-write denial or an unavailable required runtime makes explicit application fail rather than report success; run denial checks only where the platform supports a deterministic isolated fixture.

`tests/test_powershell_profile.py` covers replacement, repeat application, and execution of rendered content through real runtimes; a redirected test profile does not prove automatic profile-path discovery at process startup.
Use throwaway smoke probes, not permanent source-text or forwarding tests, for launcher selection and OS-only wrapper rendering.

**Verification:** All available required runtimes consume the generated file and report active mise state. Read-only profile-path discovery agrees with the runtime target. No personal profile is changed by verification.

### U2. Document replacement and verify startup boundaries

**Goal:** Make application and runtime limits explicit without expanding the feature.

**Requirements:** R1–R6; KTD4.

**Dependencies:** U1.

**Files:** Update `README.md` and `home/README.md`; extend `tests/test_bootstrap.py` only if its existing behavioral fixture needs new profile sentinels.

**Approach:**

1. Document explicit apply, full-file replacement, runtime-specific destinations, prerequisites, and the limits in KTD4.
2. Explain that script exclusion also excludes this installation, because the targets are runtime-resolved apply effects rather than entries in `chezmoi managed`.
3. Check initialization with pre-existing disposable profile sentinels and confirm they remain unchanged.

**Test scenarios:**

1. Initialization with profile sentinels does not change them or execute the activation payload, while explicit isolated application installs it.
2. On a disposable OS account or runner, a normal new shell loads its own installed profile and reports active mise state; a `-NoProfile` control does not obtain activation from that file. Cover modern PowerShell on all three OSes and both runtimes on Windows.

**Verification:** Runtime startup evidence is distinguished from manually loading a test file. Record unavailable platforms as unverified, rather than claiming three-OS proof from one host.

## Verification Contract

- Run the targeted Python unittest module `tests/test_powershell_profile.py` through the mise-managed Python with real chezmoi, mise, and PowerShell available; Windows additionally exercises its system 5.1 runtime.
- Run the existing bootstrap regressions in `tests/test_bootstrap.py` and, on Windows, `tests/test_windows_bootstrap.py` to protect R6.
- Use a disposable mise project with an environment setting that differs from its parent process to prove activation changes the shell environment; `mise doctor` can provide supporting evidence. Do not substitute a stub mise command or a generated-text assertion for activation proof.
- Exercise actual normal startup in disposable OS accounts/runners where available, and distinguish that coverage from the isolated writer/content tests described in U1.
- Run the repository's existing Python unittest discovery once after changes settle. Report unavailable-runtime skips and startup-smoke limits explicitly.
- Do not change the developer's personal profiles, Windows Known Folders, registry settings, or persistent execution policy to obtain test coverage. A process-only policy override in an isolated verification child is acceptable if reported.

## Definition of Done

- U1 satisfies the required runtime matrix and full-file replacement contract, with passing replacement and real-activation evidence.
- U2 documents the overwrite boundary and runtime limitations, and initialization remains read-only.
- Every required platform/runtime has either observed startup evidence or an explicitly reported verification gap; no gap is described as a pass.
- Temporary smoke assets and abandoned implementations are removed; no production files outside this feature are changed.

## Sources

- `mise.toml`: declared PowerShell tool, worktree-bound apply task, hook-free bootstrap enumeration.
- `home/README.md`: declarative-file preference, apply-only scripts, padded ordering, and OS-conditional templates.
- `tests/test_native_ca_windows.py`: real PowerShell execution with disposable destinations and shared partial rendering.
- [PowerShell profiles](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles?view=powershell-7.5): profile scopes, startup ordering, folder redirection, and execution-policy limits.
- [Windows PowerShell 5.1 profiles](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles?view=powershell-5.1): separate WindowsPowerShell destination.
- [mise shell setup](https://mise.jdx.dev/shell-setup.html): requested activation command, startup PATH prerequisite, and Windows PowerShell 5.1 limitations.
