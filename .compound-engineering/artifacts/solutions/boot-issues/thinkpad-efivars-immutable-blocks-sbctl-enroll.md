---
title: ThinkPad efivarfs immutable attribute blocks sbctl key enrollment
date: "2026-09-21"
category: boot-issues
module: Secure Boot key enrollment
problem_type: hardware_firmware_issue
component: secure-boot
severity: high
symptoms:
  - "sbctl enroll-keys fails with 'File is immutable' or Operation not permitted error"
  - "EFI variables cannot be modified even when running as root in Setup Mode"
root_cause: kernel_driver_behavior
resolution_type: operational_procedure
tags: ["secure-boot", "sbctl", "thinkpad", "efivarfs", "chattr"]
---

# ThinkPad efivarfs immutable attribute blocks sbctl key enrollment

The ThinkPad X1 Carbon Gen 11 that hit this was removed in e857618. The cause, efivarfs marking the Secure Boot variables immutable, is kernel behavior that can recur on another host.

## Problem

When enrolling custom Secure Boot keys using `sudo sbctl enroll-keys --microsoft` on ThinkPad X1 Carbon Gen 11 (with UEFI in Setup Mode), `sbctl` fails with an error stating that the target EFI variable file is immutable (`File is immutable`).

## Symptoms

- Firmware is properly switched to Setup Mode in UEFI BIOS.
- `sbctl status` reports Setup Mode enabled.
- Running `sudo sbctl enroll-keys --microsoft` fails when writing `KEK` or `db` variables with:

  ```text
  Failed to enroll keys: ...: File is immutable
  ```

## Root Cause

The Linux `efivarfs` kernel filesystem sets the immutable ext2/ext4 attribute bit (`+i`) on critical UEFI variables (such as `PK`, `KEK`, `db`, and `dbx`) to prevent accidental deletion or modification by userspace tools. Even in root execution context and with UEFI firmware in Setup Mode, write syscalls fail if the Linux filesystem-level immutable flag is active on the pseudo-files under `/sys/firmware/efi/efivars/`.

## Solution

1. Install `e2fsprogs` in system packages (`modules/nixos/system/base.nix`) so `chattr` and `lsattr` are available on the installed system:

   ```nix
   environment.systemPackages = [ pkgs.e2fsprogs ... ];
   ```

2. Clear the immutable attribute on the EFI variable files prior to running `sbctl enroll-keys`:

   ```sh
   sudo chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true
   ```

3. Re-run `sbctl enroll-keys --microsoft`. The keys will be written successfully to the UEFI NVRAM.

## Why this works

`chattr -i` issues the `FS_IOC_SETFLAGS` ioctl to remove the `FS_IMMUTABLE_FL` attribute on the pseudo-file in `efivarfs`. Once cleared, userspace tools (such as `sbctl`) can open the variable with `O_WRONLY`/`O_RDWR` and write the enrolled certificate payloads.

## Prevention

No repository doc carries the `chattr -i` step now: commit f45d1e9 dropped it from `docs/install.md`. A host that hits "File is immutable" from `sbctl enroll-keys` should get the step added to its note under "Per-host notes" in `docs/install.md`.
