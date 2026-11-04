---
title: Git and GPG Settings - Plan
type: feat
date: 2026-11-04
topic: git-gpg-settings
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Git and GPG Settings - Plan

## Goal Capsule

- **Objective:** The repository owner can reproduce the current Git identity and GPG commit-signing environment across Windows, Linux, and macOS, with `main` as the default for newly initialized repositories.
- **Means:** Chezmoi templates share common settings and branch on OS-specific GPG and pinentry differences.
- **Product authority:** The user's confirmed Git/GPG scope in this conversation and [STRATEGY.md](../../../STRATEGY.md). omp migration and external-dependency automation are not active scope.
- **Open blockers:** None. Existing tool installation and signing-key readiness are prerequisites, not deliverables.

## Product Contract

### Summary

Manage the owner's current global Git settings and GPG pinentry selection through chezmoi, adding `main` as the initial branch default.
Share common values across Windows, Linux, and macOS while adapting executable selection to each OS.

### Problem Frame

The owner's working Git identity and GPG signing settings currently live on one Windows device.
Recreating them on another device requires remembering both the shared values and the OS-specific executable choices.

### Key Decisions

- **Settings migration, not key provisioning.** Governs R4, R6, R7. Existing tools and signing keys avoid turning a configuration migration into installation or key-lifecycle management. (session-settled: user-approved — chosen over end-to-end GPG provisioning: the existing signing environment is the prerequisite and only pinentry configuration is migrated.)
- **Shared templates with OS-specific differences.** Governs R3, R5. A Windows installation path is not a portable setting; the identity and signing intent are shared. (session-settled: user-approved — chosen over copying Windows configuration unchanged to every OS: GPG and pinentry locations differ.)

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan covers Git/GPG settings only. The broader breakdown is the current understanding, not a committed roadmap.

- **omp installation and settings migration:** Can proceed independently of this plan; shares the separation between development-tool preparation and personal configuration application. The requested YAML-overlay behavior remains a candidate for that separate brainstorm.
- **External dependency pinning and automated updates:** Can proceed independently of this plan. The requested omp release, download URL, checksum declarations, and GitHub Actions updates belong there. The future omp installation work depends on the dependency policy chosen for it.

### Requirements

**Git behavior**

- R1. Applying the configuration sets the global Git identity to `Joosung Park` and `hyperlapse@jpi.co.kr`, using signing key fingerprint `621512777E6933FEB4458FDC4945855D4F283F05` and enabling automatic GPG commit signing.
- R2. Applying the configuration sets `init.defaultBranch` to `main` without renaming branches in existing repositories.
- R3. Common Git values are declared through shared chezmoi templates, with OS-specific GPG executable selection that does not carry a Windows path into Linux or macOS output.

**GPG and pinentry behavior**

- R4. Windows pinentry selection reproduces the current Gpg4win-provided PIN dialog rather than selecting Git for Windows' separate pinentry from PATH.
- R5. Linux and macOS pinentry selection uses an OS-appropriate installed executable while retaining the same GPG signing intent.
- R6. With the existing tools, signing key, and required hardware available, an ordinary Git commit prompts through the selected pinentry when a PIN is needed and produces a verifiable GPG signature.
- R7. GPG configuration management is limited to pinentry selection; it leaves unrelated agent settings, key material, public-key stores, and trust databases unchanged.

**Application lifecycle**

- R8. Personal settings change only through explicit chezmoi application, while `mise install` and worktree preparation remain read-only with respect to personal configuration.
- R9. Reapplying the configuration is idempotent and restores repository-managed values after local changes to those values.

### Key Flows

- F1. Configure an existing signing environment.
  - **Trigger:** The owner explicitly applies this checkout's chezmoi source.
  - **Prerequisites:** Git, GPG, pinentry, and the existing signing key are ready.
  - **Steps:** Apply the shared Git values and OS-specific executable selections; create a temporary repository and make a signed commit, completing PIN entry if requested.
  - **Outcome:** The new repository and commit satisfy R1–R6 without changes outside R7–R8.
- F2. Reconcile settings on an existing device.
  - **Trigger:** The owner reapplies the same source after editing a managed value locally.
  - **Outcome:** R9 restores the managed value without changing existing repository branch names under R2.

### Acceptance Examples

- AE1. New versus existing repositories. **Covers R2.** After application, `git init` in an otherwise unconfigured temporary location creates `main`; an existing repository's branch name remains unchanged.
- AE2. Windows signing. **Covers R1, R3, R4, R6.** Given the current Gpg4win installation and ready signing key, a temporary repository inherits the configured author and signing key, and its commit has a valid GPG signature; a required PIN prompt uses Gpg4win's pinentry.
- AE3. Cross-OS configuration. **Covers R3, R5, R6.** Given installed prerequisites on Linux or macOS, the applied settings select executables available on that OS, and a signed temporary commit verifies without a Windows-only path.
- AE4. Unrelated GPG state. **Covers R7.** Given existing non-pinentry agent settings and key/trust stores, applying the managed configuration leaves them unchanged.
- AE5. Preparation isolation and repeated apply. **Covers R8, R9.** Preparing a worktree does not alter personal settings; explicit application restores a locally changed managed value, and a subsequent unchanged application makes no further changes.

### Scope Boundaries

- No Git/GPG/pinentry installation, key generation or import, public-key distribution, trust migration, or YubiKey provisioning.
- No GPG-based SSH authentication, file-encryption workflow, or new signing policy such as tag auto-signing.
- No changes to repository-local Git configuration or existing branch names.
- omp and dependency automation remain separate work as described in How This Work Fits Together.

### Dependencies and Assumptions

- The user reports that GPG signing already works in the current environment; this brainstorm did not request a PIN or attempt a signing operation.
- Each target device supplies the existing signing key and required hardware before the signing acceptance scenario is run.
- Repository-owned settings take precedence on reapplication, following [STRATEGY.md](../../../STRATEGY.md).

### Outstanding Questions

- Planning resolved the partial-update mechanism through KTD2 and platform defaults through KTD1; native Linux/macOS and hardware-backed verification availability remain execution-time constraints.

### Sources and Research

- [mise.toml](../../../mise.toml), lines 12–21: preparation uses the hook-free bootstrap configuration with scripts excluded; explicit apply is separate.
- [home/README.md](../../../home/README.md), lines 9–22: source-state conventions, managed files before scripts, and idempotent OS-conditional scripts.
- Current-machine observation on 2026-11-04: `mise exec -- git config --global --show-origin --list` supplied the baseline values in R1 and the Windows GPG path `C:/Program Files/GnuPG/bin/gpg.exe`.
- Current-machine observation on 2026-11-04: `mise exec -- gpgconf --list-dirs` reported the GPG home under the user's roaming application-data directory; its directory listing contained no `gpg-agent.conf`.
- Current-machine observation on 2026-11-04: `mise exec -- gpgconf --list-components` reported pinentry under `C:/Program Files/Gpg4win/bin/pinentry.exe`, with equivalent `..` path segments in the raw output. This is the migration baseline for R4, not an inferred PATH selection.

## Planning Contract

**Product Contract preservation:** Product Contract unchanged in scope; added its problem frame and replaced planning-owned questions with their resolutions.

### Key Technical Decisions

- KTD1. **Declare shared values and platform defaults in chezmoi data.** Use `home/.chezmoidata.yaml` for identity and per-OS defaults, consumed by Git and GPG templates. Windows selects the observed GnuPG and Gpg4win installations, not Git's bundled copies; Linux defaults to `/usr/bin/gpg` and `/usr/bin/pinentry`; macOS uses Homebrew's architecture-appropriate GPG and `pinentry-mac`. Permit chezmoi config-data overrides for nonstandard installed paths. Governs R1, R3–R5.
- KTD2. **Use native modify templates for the agent configuration.** The documented `chezmoi:modify-template` marker exposes the existing file through `.chezmoi.stdin`; it needs neither a new runtime dependency nor a custom configuration editor. Replace active `pinentry-program` entries with one managed value, preserving comments and unrelated lines. Share the transformation through `home/.chezmoitemplates/`; the modify files must not have a `.tmpl` suffix. Governs R7, R9.
- KTD3. **Separate target locations with OS-conditional ignores.** Manage Windows' default home-relative `AppData/Roaming/gnupg/gpg-agent.conf` and Unix's `.gnupg/gpg-agent.conf`, enabling only the current OS target. Honor the existing repository source root and explicit apply boundary. Governs R5, R7, R8.
- KTD4. **Reload the agent after explicit application.** OS-conditional, idempotent `run_after_10` scripts invoke GPG's configuration reload so an already-running agent observes pinentry changes. They never run during hook-free worktree preparation. Governs R6, R8, R9.

### Assumptions and Execution Constraints

- The initial supported GPG home is the OS default within the user's home, matching the current device; a custom `GNUPGHOME` must be reconciled before personal application rather than silently configuring the wrong directory.
- Linux/macOS path defaults name installed prerequisites; this work does not install Homebrew or system packages.
- No fallback to unsigned commits, loopback PIN entry, exported private keys, or changed trust settings is acceptable.
- This ships as one PR, owned end-to-end by the autonomous delivery workflow. Stop for evidence invalidating a settled scope decision.

### Research

- [Chezmoi partial-file management](https://www.chezmoi.io/user-guide/manage-different-types-of-file/#manage-part-but-not-all-of-a-file) establishes KTD2, including the prohibition on `.tmpl` suffixes for modify templates.
- Existing Python unittest isolation in `tests/test_global_chezmoi.py` and `tests/test_bootstrap.py` supplies the environment, temporary-directory, and real-CLI test pattern.

## Implementation Units

### U1. Reproduce global Git behavior

- **Goal:** Implement R1–R3 and R9, supporting F1–F2.
- **Dependencies:** None.
- **Files:** `home/.chezmoidata.yaml`, `home/dot_gitconfig.tmpl`, `tests/test_git_gpg.py`.
- **Approach:** Declare shared identity/signing values once and render global Git configuration with OS-specific executable selection per KTD1.
- **Patterns:** Existing chezmoi source conventions and isolated real-CLI unittest fixtures.
- **Test scenarios:** Covers AE1: apply into a temporary home, initialize a new repository, and inspect its symbolic HEAD; preserve an existing non-main branch. Change a managed Git value and verify explicit reapplication restores it under AE5.
- **Verification:** Real Git reads the intended global values and new-repository behavior without changing the owner's global configuration.

### U2. Manage pinentry without replacing GPG state

- **Goal:** Implement R4–R9 and the GPG portion of F1–F2.
- **Dependencies:** U1's shared data.
- **Files:** `home/.chezmoitemplates/`, OS-specific GPG modify targets under `home/`, `home/.chezmoiignore`, OS-conditional `run_after_10` reload scripts, `tests/test_git_gpg.py`.
- **Approach:** Apply KTD2–KTD4; use conventional defaults with explicit path overrides and reject a mismatched custom GPG home before writing to the default location.
- **Execution note:** Smoke-check real chezmoi apply/diff behavior before expanding permanent tests.
- **Test scenarios:** Covers AE4: preserve unrelated settings and comments while replacing duplicate or locally changed pinentry entries, including CRLF input and a missing final newline. Covers AE5: repeated unchanged application produces no configuration drift. Render each OS branch and ensure Windows-only paths/targets are absent on Unix.
- **Verification:** The selected target contains one effective pinentry directive; other GPG state remains unchanged; reload scripts propagate command failures rather than reporting success.

### U3. Verify and document the application boundary

- **Goal:** Establish AE1–AE5 evidence and explain prerequisites and limits.
- **Dependencies:** U1, U2.
- **Files:** `tests/test_git_gpg.py`, affected isolated publisher fixtures in `tests/test_global_chezmoi.py` if new global signing defaults affect fixture commits, `README.md`, `home/README.md`.
- **Approach:** Exercise production templates with real chezmoi/Git in temporary homes. Keep publisher fixture commits explicitly unsigned so personal signing defaults cannot leak into test repository setup.
- **Test scenarios:** Verify preparation isolation using the existing suite. Where practical, use a disposable signing key to prove a signed commit and verification without touching the owner's keyring; record hardware/native-host limits separately.
- **Verification:** Run the repository unittest suite once after integration, then observe a direct temporary-home apply/Git smoke. Do not claim a YubiKey dialog or native Unix execution unless actually exercised.

## Verification Contract

- Run `mise exec -- python -m unittest discover -s tests` after all implementation slices settle.
- Exercise real chezmoi application and diff in an isolated home, inspect new and existing repository branches, and confirm duplicate pinentry replacement plus unrelated-line preservation.
- Render Windows, Linux, and macOS settings for architecture/path correctness; distinguish rendering from native-host execution.
- Exercise signing using an isolated disposable key when available, without resetting the owner's agent or changing its keyring.
- Report any unexercised native OS or hardware-backed prompt scenario explicitly.

## Definition of Done

- U1–U3 satisfy their cited requirements and acceptance examples with observed evidence or a named verification-environment limitation.
- Existing isolation tests remain valid and personal settings are never applied to the owner's home during development.
- README documentation describes the managed settings, tool/key prerequisites, platform defaults and overrides, and explicit application.
- Remove throwaway smoke scripts, disposable keyrings, and abandoned implementations; retain only behavior-bearing regression tests.
- Independent review findings are resolved or recorded durably before the branch is pushed and the PR is opened.
