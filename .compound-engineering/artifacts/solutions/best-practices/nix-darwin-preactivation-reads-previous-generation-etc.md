---
title: "nix-darwin preActivation reads the previous generation's /etc"
date: 2026-10-27
category: best-practices
module: "nix-darwin system activation (modules/darwin/tls-inspection-ca.nix)"
problem_type: best_practice
component: activation
severity: medium
applies_when:
  - "A nix-darwin system.activationScripts.preActivation step reads a file under /etc that nix-darwin manages"
  - "An activation step must make a value reach GUI apps through launchd and keep it after a reboot"
  - "nix-daemon must pick up new content at a file path its plist names, while the path itself stays the same"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - tooling
tags:
  - nix-darwin
  - activation
  - etc
  - launchd
  - nix-daemon
---

## Context

The TLS inspection CA work (`modules/darwin/tls-inspection-ca.nix`) builds a CA bundle in `preActivation`: the Nix roots followed by a decrypted CA. `preActivation` was chosen so that a failed decryption aborts the apply before anything points at the bundle. The first plan used the live `/etc/ssl/certs/ca-certificates.crt` as the base. Plan review caught that this base belongs to the previous generation, and the same work turned up two more nix-darwin activation traps.

## Guidance

**A `preActivation` step that needs this generation's /etc content must read the store path, not /etc.** The nix-darwin activate script runs `preActivation` before the `/etc` step (`modules/system/activation-scripts.nix:114` and `:125` in nix-darwin `bb0b90d`), and the `/etc` step is what repoints `/etc/static` at the new generation (`modules/system/etc.nix:98`). Until then every managed `/etc` path still resolves to the previous generation. Take the incoming file from its option instead:

```nix
# Wrong: in preActivation this is still the previous generation's bundle.
--base /etc/ssl/certs/ca-certificates.crt
# Right: the store path this generation's /etc will link to.
--base ${config.environment.etc."ssl/certs/ca-certificates.crt".source}
```

**`launchd.user.envVariables` does not survive a reboot.** nix-darwin renders it as `launchctl setenv` calls that run only during activation (`modules/system/launchd.nix:14`). After a reboot the variables are gone until the next apply. A value GUI apps must see after login needs a `launchd.user.agents.<name>` entry with `RunAtLoad = true` that runs the `launchctl setenv` calls itself. Activation loads a new or changed agent, so `RunAtLoad` also covers the apply.

**nix-daemon is not restarted when only the content at a stable path changes.** nix-darwin copies `environment.variables.NIX_SSL_CERT_FILE` into the daemon's plist with `mkDefault` (`modules/services/nix-daemon.nix:63`). launchd reloads the daemon only when the plist changes, so new bundle content at the same path needs an explicit `launchctl kickstart -k system/org.nixos.nix-daemon`. `scripts/tls-inspection-ca` restarts the daemon only when the bundle changed and the daemon is loaded. A kickstart during an apply drops other clients' in-flight daemon connections. During this work it dropped a concurrent `nix eval` with "Connection refused".

## Why This Matters

The /etc trap fails quietly. The step succeeds, and the output carries the old content, one apply late. A Nix CA bundle update would reach the combined bundle only on the next apply, and no check that reads the built system notices. The other two traps also pass every build check and show up only on a live Mac: after a reboot, or when a tool keeps failing until the daemon restarts.

## When to Apply

- Writing or reviewing any `preActivation` (or `extraActivation`) text that reads a nix-darwin-managed `/etc` file.
- Choosing between `launchd.user.envVariables` and a user launch agent for GUI environment.
- Pointing a daemon at a fixed path whose content activation rewrites.

## Examples

- `modules/darwin/tls-inspection-ca.nix` passes `config.environment.etc."ssl/certs/ca-certificates.crt".source` as the bundle base. `tests/darwin-config.nix` asserts that this store path, not the `/etc` path, reaches the bundle step. `tests/darwin-outputs.nix` runs the materialized step and compares its output with that base.
- The same module sets the six CA variables through the `tls-inspection-ca-environment` user agent with `RunAtLoad = true`, not `launchd.user.envVariables`.

## Related

- [Home Manager activation does not re-run when the generation is unchanged](home-manager-activation-does-not-run-on-every-rebuild.md): the Home Manager side of "when does activation run".
- [A check that greps an activation step's arguments passes when the step only echoes them](activation-step-grep-check-passes-an-echo-only-step.md): why the output check runs the bundle step instead of grepping it.
