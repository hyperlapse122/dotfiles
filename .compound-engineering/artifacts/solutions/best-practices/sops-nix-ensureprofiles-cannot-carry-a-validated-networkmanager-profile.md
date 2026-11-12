---
title: "sops-nix plus ensureProfiles cannot carry a validated NetworkManager profile"
date: 2026-11-12
category: best-practices
module: "NixOS wired network (modules/nixos/wired-network.nix)"
problem_type: best_practice
component: systemd
severity: high
applies_when:
  - "A NixOS module renders sops-encrypted values into a NetworkManager profile, or any config another service reads at boot"
  - "An encrypted value is a list or nested structure rather than a single string"
  - "A malformed or undecryptable secret must not cost the host its network or block other secrets"
  - "Someone proposes moving modules/nixos/wired-network.nix onto the modules/nixos/wifi.nix pattern for consistency"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - authentication
tags: ["sops-nix", "networkmanager", "ensureProfiles", "fail-open", "systemd-ordering"]
---

# sops-nix plus ensureProfiles cannot carry a validated NetworkManager profile

## Context

`modules/nixos/wifi.nix` renders Wi-Fi credentials into NetworkManager the standard way: `sops.secrets` for each value, `sops.templates` to write an environment file of `sops.placeholder` substitutions, and `networking.networkmanager.ensureProfiles.environmentFiles` to fill `$VAR` references in a profile. Issue #131 needed the same thing for a static wired address (MAC, IPv4 address, subnet mask, router, and a list of DNS servers), so copying the Wi-Fi module was the obvious first plan. Research while planning that work showed it fails three of the feature's requirements.

## Guidance

Do not route a structured or must-be-valid NetworkManager profile through sops-nix and `ensureProfiles`. Render it with a dedicated oneshot unit instead, which is what `modules/nixos/wired-network.nix` does:

- **Decrypt outside the sops-nix manifest.** The unit runs `nixos-wired-network`, which calls `sops --decrypt` itself with the host age identity (`config.my.cliAuth.ageKeyFile`). It never lists the file under `sops.secrets`.
- **Validate before writing anything.** `scripts/wired_network_common.py` parses each field with `ipaddress`, and `scripts/nixos-wired-network.py` adds the keyfile-specific rules (IPv4-only DNS, prefix 1 to 30, router inside the address's network). The IPv4 fields pass through `ipaddress` and the MAC through a strict pattern before rendering, so only normalized values reach the keyfile and an input value cannot inject a line.
- **Fail open.** Any problem logs one `<4>` warning that names the field but no value, writes nothing, and exits 0, so NetworkManager falls back to DHCP and a switch never fails on it.
- **Order before NetworkManager.** `before = [ "NetworkManager.service" ]` (`modules/nixos/wired-network.nix:45`) puts the keyfile in `/run/NetworkManager/system-connections/` before NetworkManager's first scan. A profile added after the wired device has activated is not applied until that device reconnects.

## Why This Matters

Each of the three mechanisms in the Wi-Fi pattern breaks a requirement:

1. **sops-nix secrets must be strings.** `sops-install-secrets` rejects a key whose value is a list with `the value of key '…' is not a string` (sops-nix `pkgs/sops-install-secrets/main.go:343`), and the sops-nix manifest runs that check when it builds, so a `dns_servers` list fails the build. Splitting the list into scalar keys would break the file schema the macOS `my.wiredNetwork` feature already uses.
2. **`ensureProfiles` validates nothing.** It renders each profile with `envsubst -i <profile> > <path>` (nixpkgs `nixos/modules/services/networking/networkmanager.nix:676`). Per this session's test of the packaged `envsubst`, an unset variable becomes an empty string and the command exits 0. A missing or mistyped secret therefore produces a profile with an empty `address1=` or `mac-address=`, which NetworkManager may load and then fail to activate. That is a lost link, not a DHCP fallback.
3. **`sops-install-secrets` is all or nothing.** Per this session's reading of `installSecrets`, it decrypts every manifest secret first and returns on the first error before installing any of them. One undecryptable wired file would stop the Tailscale auth key, the CLI tokens, and the Wi-Fi secrets from installing on that boot.

A refactor that moves the wired module onto the Wi-Fi pattern for consistency would bring back all three failures, and the build error from item 1 would be the only visible one.

## When to Apply

- Any encrypted value that NetworkManager, or another service starting at boot, must read, when a bad value has to leave the host reachable.
- Any secret whose natural shape is a list or map.
- Not needed for plain string credentials whose failure is acceptable, such as the Wi-Fi SSID and PSK pairs, where a broken profile only means that network is unavailable.

## Examples

The checks that hold this design in place:

- `tests/nixos-wired-network-config.nix` reads each configuration's materialised unit file. It requires `Before=NetworkManager.service`, an `ExecStart` running the packaged tool on the encrypted file, `nmcli` on the unit's `PATH` (the tool skips the reload on a switch when `nmcli` is missing), and no unit on bootstrap outputs.
- `tests/wired-network-provisioning.nix` boots VMs with a valid, a malformed, and an undecryptable file, plus one with no identity. It checks that the malformed and undecryptable cases come up on DHCP and accept SSH, and that `sops-install-secrets` still installs an unrelated fixture secret beside an undecryptable wired file.

Two traps in that VM test:

- **Shared fixture MACs.** QEMU gives each test NIC the MAC `52:54:00:12:<vlan>:<machine>` (nixpkgs `nixos/lib/qemu-common.nix`, `qemuNicMac`), so two NICs of the same node on one VLAN share a MAC, and a fixture MAC that no QEMU NIC carries never matches. Each NIC goes on its own VLAN, and the wired fixture is generated with the declared NIC's QEMU MAC.
- **A race that hides the ordering.** Removing `Before=NetworkManager.service` did not fail the test at first, because rendering took about 0.1 s in this session's runs and won the race anyway. The `valid` node adds a test-only `ExecStartPre` delay, so a missing ordering now shows up as DHCP on that node.
