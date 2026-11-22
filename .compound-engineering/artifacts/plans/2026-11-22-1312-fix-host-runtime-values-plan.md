---
title: Derive host-specific runtime values from configuration
date: 2026-11-22
type: fix
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
---

# Derive host-specific runtime values from configuration

## Goal Capsule

**Objective.** An operator can configure an account and its home in one place and have services use both, even when the home directory bears no relation to the account name.

**Product authority.** The repository owner confirmed the scope and acceptance criteria for [issue #252](https://github.com/hyperlapse122/dotfiles/issues/252).

**Open blockers.** None.

## Product Contract

### Summary

Use host declarations wherever runtime configuration duplicates a deployment-specific value. Start with account names, service identities, home directories and paths under them.

### Requirements

- R1. Audit system modules, Home Manager wiring, scripts and generated service definitions across production and bootstrap outputs on both NixOS and macOS.
- R2. Keep deployment-specific values in host declarations. Runtime consumers must use the declared account, home and applicable host traits wherever those declarations own the value.
- R3. Wherever enabled, credential publication and OpenCode credential import must run as the declared user and use that user's declared home, including for paths that services need mounted before startup.
- R4. Record each intentional literal found during the audit and why it stays fixed, including protocol constants, fixture identities and examples where applicable.

### Acceptance Examples

- AE1. Covers R2 and R3. Configure a fixture with account `alice` and home `/srv/workspace`. An affected check must show through the rendered service configuration or by exercising the runtime path that each enabled operation runs as `alice` and uses `/srv/workspace`. The fixture requires no edits to runtime modules or scripts.

### Scope Boundaries

Account renames and home directory migrations on existing machines are outside this change.

## Planning Contract

Use the existing `my.user.name` and `my.user.home` options throughout the system and Home Manager. Treat the two values independently. On Darwin, the declaration describes an existing account. Its name and home must match Directory Services so Home Manager activation runs with the expected HOME.

## Implementation Units

### U1. Bind accounts and desktop consumers to host declarations

Move the production NixOS account values into its host declaration. Update the account in `modules/nixos/system/base.nix`, the Home Manager binding in `lib/nixos-host.nix`, and the desktop and avatar modules under `modules/nixos/desktop/`. Check service names and paths derived from the account. Preserve bootstrap feature gates. Update host-dependent checks to select the configured user.

### U2. Run credential consumers in the declared account

In `modules/nixos/system/secrets.nix`, use the account for both runuser commands and SOPS ownership. Use the declared home for publication and mount ordering. Run OpenCode with the target user's HOME and check its state as that user. Keep the current secret modes and successful-decryption ordering. Review the corresponding macOS activation paths and record intentional constants from the audit.

### U3. Exercise an independent username and home

Use the existing fake credentials and rotation scenario in `tests/auth-provisioning.nix` with the AE1 account. Update isolated module fixtures to supply the host options they consume. Keep the real production and bootstrap outputs in their existing platform checks.

## Verification Contract

Re-evaluate the production and bootstrap NixOS assemblies with only the AE1 user options overridden. Check the system account's passwd home and the Home Manager activation service for that user. In the VM, inspect the effective SOPS unit's mount dependencies for both the fixture home and age identity. The auth-provisioning VM must publish writable credentials under the fixture home and return the imported OpenCode key when queried as that user. Run the affected declared checks on the supported builder and use CI for the Linux VM.

## Definition of Done

The fixture passes AE1, each platform's production and bootstrap outputs build, and the audit accounts for the intentional literals under R4. Ship U1 through U3 together in the PR that closes issue #252.

## Audit of retained literals

| Literal or location | Reason |
| --- | --- |
| Account and home in each production host declaration | These select the deployed account. Both production and bootstrap read the same declaration. |
| `home/h82` in imports, package sources and catalog-update scripts | This is a tracked repository directory. Its name does not select a login account. |
| `hyperlapse122` and `hyperlapse` in `modules/shared/cli-accounts.nix` | GitHub, GitLab, JPI and Docker use remote account names that can differ from the local login. |
| `Joosung Park` and `iam@h82.dev` | The account description and Git author metadata identify a person independently of the login. |
| `/run/secrets/cli-auth`, `/var/lib/sops-nix/key.txt` and `State:/Users/ConsoleUser` | The first two locate runtime secrets and the system age identity. The third is a macOS System Configuration key. |
| VM fixture identities, fixture UIDs and example accounts in the installation guide | These identify test actors or illustrate a host declaration. |
