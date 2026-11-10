---
title: tailscale up refuses re-authentication when it omits a stored non-default pref
date: "2026-10-01"
category: integration-issues
module: NixOS Tailscale service
problem_type: integration_issue
component: systemd
severity: medium
symptoms:
  - "tailscaled-autoconnect fails with \"changing settings via 'tailscale up' requires mentioning all non-default flags\""
  - "Re-authentication after key expiry, or after a tray Disconnect and a reboot, never completes"
  - "A NixOS VM test without a control server cannot reproduce the refusal"
root_cause: config_error
resolution_type: code_fix
retire_when: "tailscale up stops rejecting an omitted stored non-default pref (checkForAccidentalSettingReverts in cmd/tailscale/cli/up.go), or nixpkgs tailscaled-autoconnect stops running tailscale up with extraUpFlags"
tags: ["tailscale", "tailscaled-autoconnect", "extraupflags", "extrasetflags", "operator", "systray", "reauth", "nixos-vm-test"]
---

# tailscale up refuses re-authentication when it omits a stored non-default pref

Paths under `cmd/`, `client/`, and `ipn/` are in the tailscale 1.102.4 source, and `nixos/modules/services/networking/tailscale.nix` is in the locked nixpkgs; neither lives in this repository.

## Problem

Adding `--operator=<user>` to a node so the user's `tailscale systray` can change prefs without sudo can break unattended re-authentication. The nixpkgs `tailscaled-autoconnect` unit re-registers the node with `tailscale up --auth-key ... <extraUpFlags>`, and `tailscale up` refuses any command that carries flags but leaves out a stored non-default pref. The operator, and any exit node the user picks from the tray, become such prefs.

## Symptoms

- After a reboot that finds the node in `NeedsLogin`, `NeedsMachineAuth`, or `Stopped`, `tailscaled-autoconnect` runs `tailscale up` and it exits with:

  ```text
  Error: changing settings via 'tailscale up' requires mentioning all
  non-default flags. To proceed, either re-run your command with --reset or
  use the command below to explicitly mention the current value of
  all non-default settings:

      tailscale up ...
  ```

  (text from `cmd/tailscale/cli/up.go:978-982` in the tailscale 1.102.4 source). The node stays unauthenticated.
- Nothing fails on a fresh install or in a NixOS VM test without a control server, so the bug only shows up on a node that has already registered.
- The trigger can be an action the user takes later in the tray, not a config change. Picking an exit node in the tray stores `ExitNodeID`, and the next re-authentication fails.

## What Didn't Work

- **Setting the operator only through `services.tailscale.extraSetFlags`.** `tailscaled-set` runs `tailscale set <extraSetFlags>` each time tailscaled starts (nixpkgs `nixos/modules/services/networking/tailscale.nix:237-248`), so the operator is stored on every node, including ones registered before the flag existed. Review rejected this. Once the operator is stored, autoconnect's `tailscale up` (line 218), which does not name it, trips the accidental-revert check.
- **Putting the operator in both `extraUpFlags` and `extraSetFlags` without `--reset`.** The first version of this change on the branch did this. It covers the operator but not prefs the operator then changes on its own. `tailscale systray` sends `EditPrefs` with `ExitNodeID` when the user picks an exit node (`client/systray/systray.go:482-489`), with no sudo needed because the user is the operator. `exit-node` maps to `ExitNodeIP`/`ExitNodeID` in the up checker (`up.go:907`, `up.go:1173`), so the stored exit node counts as a missing non-default flag. Review traced two ways to hit this: the tray's Disconnect sets `WantRunning: false` (`systray.go:457-465`), which per this session's analysis leaves the backend `Stopped` across a reboot, or the node key expires. Either way autoconnect runs `up` and the command is refused.
- **Reproducing the failure in the VM test.** The check returns early when `curPrefs.ControlURL == ""` (`up.go:1010-1014`), and per this session's observation a VM test without a control server does not set one, so `tests/tailscale-provisioning.nix` cannot show the refusal. A bare `tailscale up` with no flags on a logged-in node is also exempt (`up.go:1021-1028`). That case does not apply here, because autoconnect always passes `--auth-key`.

## Solution

`modules/nixos/services/tailscale.nix` puts the operator in one shared flag list and adds `--reset` to the up flags only:

```nix
nodeFlags = [
  "--ssh"
  "--accept-routes"
  "--operator=${config.my.user.name}"
];
...
services.tailscale = {
  extraUpFlags = nodeFlags ++ [ "--reset" ];
  extraSetFlags = nodeFlags;
};
```

(`nodeFlags` at `modules/nixos/services/tailscale.nix:15-19`, then `extraUpFlags` and `extraSetFlags`). `tailscale set` does not register a `--reset` flag (`cmd/tailscale/cli/set.go` defines `--operator` at line 113 but no `reset`), so it gets `nodeFlags` alone.

Before: `extraUpFlags = nodeFlags;`. After: `extraUpFlags = nodeFlags ++ [ "--reset" ];`.

## Why This Works

`updatePrefs` runs `applyImplicitPrefs` and `checkForAccidentalSettingReverts` only when `--reset` is absent (`up.go:428-436`). With `--reset`, `tailscale up` sets every pref it does not name back to its default instead of refusing (flag help text, `up.go:143`). Autoconnect's re-registration then always succeeds, and it reapplies the declared `--ssh`, `--accept-routes`, and operator because they are in the same command.

The cost is that re-authentication through autoconnect clears what the user changed in the tray, such as an exit node. The node comes back online with the declared prefs and the user picks the exit node again. Prefs that other units manage come back on their own: `tailscaled-set` is ordered after `tailscaled-autoconnect` (nixpkgs `tailscale.nix:238-241`) and reapplies `nodeFlags`, and `tailscale-advertise-routes` runs after autoconnect and reapplies `--advertise-routes` (`modules/nixos/services/tailscale.nix:138-152`).

The operator also stays in `extraSetFlags` because autoconnect only runs `up` in the `NeedsLogin|NeedsMachineAuth|Stopped` branch (nixpkgs `tailscale.nix:216-218`). A node that is already `Running` never gets the up flags, so `tailscaled-set` is the only path that gives an existing registration the operator.

## Prevention

- When a node gets a pref that a non-root user or a GUI can change later (operator, exit node, LAN access, shields-up), check every unattended `tailscale up` that can run after it. Either name every pref it might find stored, or pass `--reset` and accept that it clears user changes.
- Do not count a passing VM test as evidence for `tailscale up` argument handling. The up checker skips nodes with no `ControlURL` (`up.go:1011`), so an up/set mismatch only shows on a node registered with a real control server.
- `tests/desktop-autostart.nix` checks the materialized unit scripts, not the option values. For each production configuration that enables Tailscale, it reads the `ExecStart` script of `tailscaled-autoconnect.service` and `tailscaled-set.service`, keeps only the line that runs `tailscale up` or `tailscale set`, and requires `--operator=<my.user.name>` and `--reset` on the up line and the operator on the set line (`tests/desktop-autostart.nix:214-254`). A missing unit fails the check outright (`:225-226`). Per this session's mutation runs, removing `--reset`, setting the operator only through `extraSetFlags`, and disabling `tailscaled-set` each fail the check in the builder.
- `tests/tailscale-provisioning.nix` checks the declared up flags as a set (the `client_up_flags` and `router_up_flags` assertions). At runtime it clears `RouteAll`, `RunSSH`, and the operator with `tailscale set --accept-routes=false --ssh=false --operator=`, starts `tailscaled-set.service`, and requires all three back (the runtime clear-and-restore block after the up-flag assertions). Two traps from writing that test:
  - `OperatorUser` is tagged `json:",omitempty"` (`ipn/prefs.go:250`). Once cleared, it is missing from `tailscale debug prefs`, and `jq -r .OperatorUser` prints `null`. Query `.OperatorUser // empty` so a cleared operator compares equal to `""` (`operator_query` in `tests/tailscale-provisioning.nix`).
  - Per this session's observation, `tailscale set --operator=<user>` succeeds even when that user has no account on the node; tailscaled only logs about an unknown user. The VM test therefore needs no real login account for `my.user.name`.
