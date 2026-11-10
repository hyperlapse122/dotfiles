---
title: Restrictive service umask blocks SOPS user secrets
date: "2026-09-21"
category: integration-issues
module: NixOS CLI authentication
problem_type: integration_issue
component: authentication
severity: medium
symptoms:
  - "SOPS decryption succeeds but the user-owned CLI publisher cannot read its secrets"
  - "Correct secret file ownership and mode do not restore access"
root_cause: config_error
resolution_type: config_change
tags: ["sops-nix", "systemd", "umask", "secret-permissions"]
---

# Restrictive service umask blocks SOPS user secrets

## Problem

Adding `UMask=0077` to `sops-install-secrets` prevented the unprivileged CLI configuration publisher from reading decrypted tokens.

## Symptoms

The authentication VM failed before creating the gh configuration even though decryption succeeded and the secret files had owner `h82` and mode `0400`.

## What didn't work

The service-wide umask was intended to keep secrets private. It also restricted directories owned by the upstream installer. Inspecting only the final file ownership and mode missed the missing directory traversal permission.

## Solution

Remove the service-wide umask override. Keep explicit permissions at each owned boundary:

- The local age identity is root-owned `0600` in a `0700` directory.
- SOPS token files are owned by `h82` with mode `0400`.
- The publisher creates user-owned regular CLI configuration files with mode `0600`.

`modules/nixos/system/secrets.nix`, `scripts/restore-age-identity`, and `scripts/publish-cli-auth` implement these boundaries. Do not add a recursive chmod of the runtime SOPS tree as a workaround; SOPS owns and rotates that tree.

## Why this works

The sops-nix installer creates generation directories and nested secret directories with `0751`. The process umask turns those modes into `0700`. The installer changes their owner/group but does not restore the masked traversal bits. A user-owned `0400` file remains inaccessible when its parent directories only permit root to traverse them.

The relevant operations are `os.Mkdir` and `os.MkdirAll` in [the sops-nix installer at the revision this was diagnosed on (7214124…)](https://github.com/Mic92/sops-nix/blob/7214124c20c1542c90deb54af50e2f53ae02711f/pkgs/sops-install-secrets/main.go#L431). This concerns that installer's multi-user directory layout; it is not a general objection to private umasks.

## Prevention

When hardening an upstream service that creates files for other users, inspect its directory creation modes and exercise a real unprivileged consumer. The authentication VM failed with the override and passed after its removal:

```sh
nix build --no-link .#vmChecks.auth-provisioning
```

`tests/auth-provisioning.nix` covers real decryption, user publication, repeated switches, missing/corrupt local keys, and recovery through the packaged installer. Its switch support is explicitly enabled and VM GRUB updates are disabled, so missing commands or unrelated bootloader errors cannot masquerade as expected authentication failures. Physical YubiKey and boot checks remain separate.
