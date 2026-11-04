---
name: dotfiles
last_updated: 2026-11-04
---

# dotfiles Strategy

## Purpose

Setting up or resetting Windows, Linux, and macOS devices requires repeatedly configuring Git, GPG, and other tools, consuming substantial time before development and office work can begin.

## Positioning

Use the repository as the source of truth for environment configuration, with the same one-click-ish setup supporting both initial setup on new PCs and updates on existing PCs. Share common configuration, but provide OS-specific bootstrap and settings where needed, including Git's SSH/GPG binaries, pinentry, and OS-specific agent instructions.

## Users

**Primary:** The repository owner alone, using devices across multiple operating systems — run this repository to configure a new PC and immediately begin development and office work, then rerun it on existing PCs to apply updates.

The work environment includes GUI applications as well as CLI tools. Applications currently in use rely on Microsoft Intune and Microsoft 365 SSO; none require a separate license.

## Boundaries

- Repository-managed settings take precedence over local changes; repeated runs reconcile those settings to the repository's desired state.
- Encrypt secrets with the user's GPG public key as the sole recipient and commit them to this repository using chezmoi's built-in GPG encryption. Delegate private-key access to GPG without repository-level assumptions about key-storage hardware.
- Exclude OAuth logins that are difficult to automate and management of applications provisioned by Intune, such as Microsoft 365 applications.

_Resist a change when:_ It weakens repository precedence to preserve local changes, commits plaintext secrets, or takes on the excluded authentication or application-management responsibilities.

## Key metrics

- **Time to work readiness** — Elapsed time from starting bootstrap on a new PC until development and office work can actually begin, measured through manual run records by OS, with failed runs recorded separately.
- **Manual configuration corrections** — Number of configuration items requiring manual correction after a run, excluding intended user actions such as password entry and authentication approval, measured through manual records for each run.
- **Repeat-run success rate** — Proportion of runs on existing PCs that apply updates while keeping the work environment functional, including no-change reruns, measured through run results and work-readiness checks by OS.

None of these metrics are collected yet; measurement will use manual run records.

## Tracks

### OS-specific bootstrap

Maintain entry points that start and complete initial setup on Windows, Linux, and macOS.

_Why it serves the approach:_ Provide one-click-ish setup without hiding differences between operating systems.

### Declarative development and office environment management

Declare required tools and settings in the repository, distinguishing shared configuration from OS-specific differences.

_Why it serves the approach:_ Reduce the need to remember and manually configure Git, GPG, work applications, and other environment settings on each device.

### Safe repeated application and work-readiness verification

Reconcile existing PCs to repository-managed settings and verify that development and office environments remain functional after updates and repeated runs.

_Why it serves the approach:_ Use the same repository to maintain environments on existing PCs as well as configure new ones.
