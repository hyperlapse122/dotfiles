---
title: Remove the NVIDIA Stack by Hand on a Pascal Hybrid Host Declared Integrated-Only
date: 2026-09-05
last_updated: 2026-09-05
category: integration-issues
module: nvidia
problem_type: workflow_pattern
component: package_provisioning
symptoms:
  - "install-nvidia-fedora.sh reports that this hybrid host's GPU architecture is declared integrated-only and prints this file's path"
  - "/proc/driver/nvidia/gpus/*/power reports Runtime D3 status: Not supported on a Pascal laptop GPU"
  - "the discrete GPU's power/runtime_status stays active and runtime_suspended_time stays 0 on battery"
  - "akmod-nvidia-580xx rebuilds and signs a module on every kernel update for a GPU nothing uses"
root_cause: design_limitation
resolution_type: manual_procedure
severity: medium
tags:
  - nvidia
  - pascal
  - hybrid-graphics
  - power-management
  - fedora
---

# Remove the NVIDIA Stack by Hand on a Pascal Hybrid Host Declared Integrated-Only

## Problem

A hybrid laptop whose discrete GPU architecture is listed in `nvidia.integratedOnlyArchitectures` (`.chezmoidata/nvidia.yaml`) resolves the `integratedOnly` fact to true. From that apply on, dotfiles installs nothing for NVIDIA, retires the two hybrid modprobe drop-ins, installs a driver blacklist, and installs a udev rule that leaves the discrete GPU driverless under PCI runtime power management so its root port enters D3cold.

Dotfiles never removes packages. A host that already carried the stack when the policy landed keeps it until the operator removes it by hand. This is a decision, not a gap: the repository stops installing and documents the reversal here rather than owning a removal path.

## Procedure

Run these on the affected host after `chezmoi apply` has reported the integrated-only skip. The 580xx branch is the one a Pascal host installed.

1. Remove the packages and their dependents.

   ```sh
   sudo dnf remove \
     akmod-nvidia-580xx 'kmod-nvidia-580xx*' \
     xorg-x11-drv-nvidia-580xx 'xorg-x11-drv-nvidia-580xx-*' \
     nvidia-settings-580xx nvidia-persistenced nvidia-modprobe \
     'nvidia-container-toolkit*' 'libnvidia-container*'
   ```

   Leave `akmods` installed if another out-of-tree module uses it; remove it too if nothing else does.

2. Remove the container toolkit CDI spec the installer generated.

   ```sh
   sudo rm -f /etc/cdi/nvidia.yaml
   ```

3. Clear the repository exclusion settings the installer wrote.

   ```sh
   sudo dnf config-manager setopt 'rpmfusion-nonfree*.excludepkgs='
   sudo dnf config-manager setopt 'cuda-fedora*.excludepkgs='
   ```

4. Withdraw the akmods signing certificate from the MOK list. The next boot shows the MokManager screen; choose delete and enter the passphrase the enrollment used.

   ```sh
   sudo mokutil --delete /etc/pki/akmods/certs/public_key.der
   ```

5. Restore the early-boot nouveau guard. The `%preun` scriptlet of `xorg-x11-drv-nvidia-580xx` runs `grubby --remove-args` for these arguments on last uninstall, and dracut's host-only DRM module puts nouveau into the initramfs for the present GPU. Re-add the arguments and rebuild the initramfs so the blacklist dotfiles installed at `/etc/modprobe.d/nvidia-integrated-only.conf` reaches early boot.

   ```sh
   sudo grubby --update-kernel=ALL --args='rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core'
   sudo dracut -f
   ```

6. Reboot.

Do not edit `/etc/modprobe.d/nvidia-integrated-only.conf` or `/etc/udev/rules.d/80-nvidia-integrated-only.rules` by hand. Dotfiles owns both and reinstalls them when their source changes.

## How to check a host

After the reboot, all of these hold on an integrated-only host. Substitute the discrete GPU's PCI address; on the ThinkPad P14s Gen 1 it is `0000:2d:00.0` under root port `0000:00:1d.0`.

```sh
lsmod | grep -E '^(nvidia|nouveau)'                       # prints nothing
ls -l /sys/bus/pci/devices/0000:2d:00.0/driver             # No such file or directory
cat /sys/bus/pci/devices/0000:2d:00.0/power/runtime_status  # suspended
cat /sys/bus/pci/devices/0000:00:1d.0/power/runtime_status  # suspended
cat /sys/bus/pci/devices/0000:2d:00.0/power_state           # D3cold
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep energy-rate
```

The idle discharge rate on battery must sit below the value recorded with the driver loaded. On the P14s Gen 1 that baseline was about 17.8 W at an idle desktop.

Suspend and resume once more and repeat the `runtime_status` reads. Both must return to `suspended` without operator action.

## Reversal

Remove the architecture from `integratedOnlyArchitectures`, apply, and reinstall the branch packages the installer names. The MOK certificate has to be enrolled again on the next boot; the installer handles that.
