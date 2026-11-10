---
name: dotfiles
last_updated: 2026-11-10
---

# dotfiles Strategy

## Purpose

Setting up or resetting NixOS and macOS machines requires repeatedly configuring the system, shell, Git, GPG, development toolchains, desktop applications, and coding agents, consuming substantial time before development and office work can begin.

## Positioning

Use this Nix flake repository as the single source of truth for environment configuration across the owner's two personal machines — `MS-7D91` (bare-metal NixOS desktop) and `MacBook-Pro-Mac17-9` (`nix-darwin` Apple silicon MacBook Pro) — with a two-stage `<host>-bootstrap` and `<host>` switch model that supports both clean installations from erased hardware and routine updates on existing machines. Share common user, development, and coding-agent configuration across both operating systems, while expressing OS- and hardware-specific behavior through NixOS and `nix-darwin` modules, host traits, and per-host declarations.

## Users

**Primary:** The repository owner alone, working across `MS-7D91` (NixOS) and `MacBook-Pro-Mac17-9` (macOS) — apply this flake to bring a freshly installed machine to full work readiness, and re-apply it (`nr switch`) on existing machines to roll out updates.

The work environment includes GUI applications as well as CLI tools and coding agents. Work applications on macOS rely on Microsoft Intune and Microsoft 365 SSO; none require separate license provisioning in this repository.

## Boundaries

- Repository-managed settings take precedence over local changes; repeated switches (`nr switch`) reconcile managed system, Home Manager, and declared application settings to the repository's desired state while preserving undeclared keys in mutable agent and app configuration files.
- Encrypt secrets with `sops` and per-host `age` identities, with each host's bootstrap age identity (`secrets/bootstrap/<host>/age-key.asc`) encrypted to the OpenPGP encryption subkey carried on the owner's three YubiKeys (`keys/signing.asc`). Scope `.sops.yaml` creation rules so each host decrypts only the secrets it needs (`secrets/tokens.yaml` for both hosts; `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` for `MS-7D91` only; `secrets/hosts/<host>/*` for `<host>` only). Never commit plaintext credentials or evaluate/build with plaintext secrets in the Nix store.
- Exclude interactive OAuth logins that cannot be declaratively provisioned and exclude installation or lifecycle management of applications provisioned by Microsoft Intune (such as Microsoft 365 applications, which the repository references only as Dock entries on `MacBook-Pro-Mac17-9`).
- Retiring a managed tool removes its installation and configuration from the repository without uninstalling binaries or deleting existing user data on disk, unless the owner explicitly asks for removal.

_Resist a change when:_ It weakens repository precedence to preserve local drift on declared keys, places plaintext secrets in the repository or Nix store, widens sops recipient access beyond the hosts that need a secret, or takes on excluded interactive OAuth or Intune application-management responsibilities.

## Key metrics

- **Time to work readiness** — Elapsed time from starting the bootstrap runbook on a freshly installed NixOS or macOS machine until development and office work can begin, measured through manual run records by OS, with failed runs recorded separately.
- **Manual configuration corrections** — Number of configuration items requiring manual correction after a switch, excluding intended owner actions such as LUKS/sudo/Keychain password entry, Secure Boot setup-mode selection, YubiKey PIN entry, and interactive OAuth/2FA approval, measured through manual records for each run.
- **Repeat-run success rate** — Proportion of switches (`nr switch`) on existing NixOS and macOS machines that apply updates while keeping the work environment functional, including no-change reruns, measured through switch results and work-readiness checks by OS.

None of these metrics are collected automatically; measurement uses manual run records.

## Tracks

### Two-stage NixOS and macOS bootstrap

Maintain `<host>-bootstrap` and `<host>` flake outputs and step-by-step runbooks (`docs/install.md` and `docs/macos.md`) that take `MS-7D91` and `MacBook-Pro-Mac17-9` from erased disks through age-identity recovery to full production state.

_Why it serves the approach:_ Allow a clean machine to boot and install its tools before any private key or token is present, then transition to the full production configuration with a single card-backed recovery step and switch.

### Declarative system, development, and coding-agent management

Declare system services, desktop/Dock settings, fonts, development toolchains, and coding-agent harnesses, plugins, skills, and launch instructions in shared and OS-specific Nix modules.

_Why it serves the approach:_ Keep both hosts aligned from one flake while handling NixOS and macOS platform differences (such as LUKS2/Lanzaboote/Podman on NixOS versus FileVault/`xcodes`/Homebrew/Apple `container` on macOS) explicitly.

### Safe repeated application and verification

Reconcile existing hosts to declared state through `nr switch` and guard configuration invariants, secret recipient boundaries, and package/plugin pins with automated flake checks (`nix flake check` and `vmChecks`).

_Why it serves the approach:_ Catch regressions in evaluation, activation scripts, and VM boot paths before they reach a physical host, while keeping routine switches fast and repeatable.
