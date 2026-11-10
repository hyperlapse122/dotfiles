---
title: "system-manager's activate exits 0 after a partial activation; assert the materialized state"
date: 2026-10-01
category: best-practices
module: "non-NixOS system layer (scripts/nr-linux, modules/system-manager/*, tests/non-nixos-vm.nix)"
problem_type: best_practice
component: activation
severity: medium
applies_when:
  - "A script, check, or doc treats the exit status of system-manager's `activate` (or `nr switch` on a non-NixOS host) as evidence that the system layer applied"
  - "A step that can only fail in the home layer runs after the system layer, so an error surfaces after the system layer is already live"
tags:
  - system-manager
  - non-nixos
  - activation
  - exit-status
  - nr-linux
  - checks
retire_when: "numtide/system-manager makes `activate` return an error when etc files or services activate only partially; check the upstream activate.rs and release notes, then re-read crates/system-manager-engine/src/activate.rs in the locked rev"
---

# system-manager's `activate` exits 0 after a partial activation; assert the materialized state

## Context

On a non-NixOS Linux host, the system layer is applied by numtide
system-manager (the `system-manager` input in `flake.lock`). `scripts/nr-linux` runs three commands
in order (`scripts/nr-linux:183-185`):

```sh
sudo -- "$system_out/bin/register-profile"
sudo -- "$system_out/bin/activate"
"$home_out/activate"
```

It is tempting to read a zero exit from the middle command as "the system layer
is live". The engine does not promise that. The exit status of `activate`
reports whether the engine itself survived, not whether every `/etc` file and
unit reached its intended state.

## Guidance

The `crates/` paths below are in the upstream system-manager source at the
locked revision (`nix flake archive --json` prints its store path), not in this
repository. What `activate()` in `crates/system-manager-engine/src/activate.rs`
actually does:

- A failed pre-activation assertion bails before anything changes
  (`activate.rs:137-139`: `anyhow::bail!("Failure in pre-activation assertions.")`).
- When `etc_files::activate` returns `ActivationError::WithPartialResult`, the
  engine logs `Error during activation`, writes the partial state file, and
  returns `Ok(())` (`activate.rs:190-199`).
- When `services::activate` returns a partial result, it logs the same message,
  keeps the partial service state, writes the state file, and continues
  (`activate.rs:173-182`).
- After the etc files activate, the only per-component failure that propagates
  is the tmp-files result, and only after the state file is written
  (`activate.rs:184-186`). Partial etc-file and service failures do not.

So the process exits 0 when some `/etc` files or units failed. The failure
shows up only as a log line.

Registration has already happened by then. `register()` installs the new nix
profile generation and creates the GC root (`register.rs:27-33`), and both
`nr-linux` (`scripts/nr-linux:183`) and upstream's own `switch`
(`crates/system-manager/src/main.rs:413-420`, `invoke_engine_register` then
`invoke_engine_activate`) register before activating. Only upstream's
standalone `activate` subcommand skips registration. On the register-then-activate
paths, a failed or partial activation therefore leaves the new generation
registered as the current profile.

Rules that follow:

1. Never use `activate`'s exit status as success evidence in a script, check,
   or doc. A zero exit proves only that the engine finished.
2. Assert the materialized state instead: the unit is active, the socket has
   the expected mode and owner, the `/etc` file has the expected content.
3. Do not assume a failed switch left the previous generation current. The new
   one is registered even when activation was partial.

## Why This Matters

A check that only runs `nr switch` and looks at its exit status passes when a
module is broken: an `/etc` file that fails to link, or a unit that fails to
start, produces a log line and exit 0. The next person reads a green result as
"the system layer applied".

The same ordering shapes error handling across layers. The home layer runs last
(`scripts/nr-linux:185`), so an error only the home layer detects, such as a
foreign age identity, surfaces after the system layer is already applied and
registered. This is accepted residual risk: the system layer is idempotent and
safe to leave in place, and the bootstrap variant exists to bring a host up
before any identity does.

## When to Apply

- Writing or reviewing a check under `tests/` that exercises `nr switch` or
  `systemConfigs.<host>` on a non-NixOS host.
- Adding a module under `modules/system-manager/` and deciding how to prove it
  applied.
- Documenting what a successful `nr switch` means in `docs/`.

## Examples

`tests/non-nixos-vm.nix` asserts state, not exit codes. After the bootstrap
switch it waits for the unit and stats the socket
(`tests/non-nixos-vm.nix:151-155`, abridged from its Nix-interpolated form):

```python
vm.succeed(nr_switch_bootstrap)
vm.wait_for_unit("pcscd.socket")
socket = vm.succeed("stat -c '%a %U %G' /run/pcscd/pcscd.comm").split()
assert socket == ["660", "root", user], f"pcscd socket is {socket}"
```

It then checks the content of the file the system layer writes
(`tests/non-nixos-vm.nix:159-160`):

```python
vm.succeed("grep -qx 'variant=bootstrap' /etc/nix-config-host")
vm.succeed("grep -qx 'host=<name>' /etc/nix-config-host")
```

Two settings in `modules/system-manager/default.nix` are the kind of thing a
partial activation would otherwise hide. They are asserted in the built output
rather than trusted to the exit status (the `build-users-group = nixbld` assertion in `tests/non-nixos-outputs.nix`
greps the materialized `nix.conf`):

- `nix.enable = true` makes system-manager take over `/etc/nix/nix.conf`, but
  the upstream module drops the installer's `build-users-group`, so the module
  sets `nix.settings.build-users-group = "nixbld"` to keep builds running as the
  unprivileged build users (`modules/system-manager/default.nix:34-38`).
- `services.userborn.enable = false` because the distribution owns the user
  database and system-manager must never write `/etc/passwd`, `/etc/group`, or
  `/etc/shadow` (`modules/system-manager/default.nix:21-23`).

## See also

- [A check that reads an option value passes when the option is disabled or renamed](nix-check-reads-option-value-not-materialized-output.md) — the same principle on the check side: assert the materialized output, not a declared value or a status code.
