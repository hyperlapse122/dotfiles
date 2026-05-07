# ArchWiki page index per scenario

Quick lookup of canonical ArchWiki pages the agent should consult when filling in `user_configuration.json` for a new host. Cross-reference with [`archinstall-schema.md`](archinstall-schema.md) for the JSON shape each decision lands in.

---

## Always-relevant baseline pages

| Page | URL | When to consult |
|---|---|---|
| Installation guide | <https://wiki.archlinux.org/title/Installation_guide> | Sanity-check generic install steps |
| archinstall | <https://wiki.archlinux.org/title/Archinstall> | Skim for the current archinstall version's notes |
| General recommendations | <https://wiki.archlinux.org/title/General_recommendations> | Post-install checklist |
| Laptop | <https://wiki.archlinux.org/title/Laptop> | Index of laptop-specific articles |

---

## Laptop / desktop model pages

ArchWiki has per-model pages for many laptops. Search pattern:

```
https://wiki.archlinux.org/title/Special:Search?search=<vendor>+<model>+<gen>
```

Examples (URL-encoded):

| Model | URL |
|---|---|
| Lenovo ThinkPad T14/T14s (Intel) Gen 2 | <https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14/T14s_(Intel)_Gen_2> |
| Lenovo ThinkPad X1 Carbon (Gen 11) | <https://wiki.archlinux.org/title/Lenovo_ThinkPad_X1_Carbon_(Gen_11)> |
| Framework Laptop 13 (AMD Ryzen AI 300) | <https://wiki.archlinux.org/title/Framework_Laptop_13_(AMD_Ryzen_AI_300_Series)> |
| ASUS Zenbook UX5606 | <https://wiki.archlinux.org/title/ASUS_Zenbook_UX5606> (search; page may not exist) |
| Dell XPS 13 (9320) | <https://wiki.archlinux.org/title/Dell_XPS_13_(9320)> |
| System76 Lemur Pro | <https://wiki.archlinux.org/title/System76_Lemur_Pro> |

What to extract from a model page:

- **Hardware ID table** (USB/PCI vendor:product → component, "Working?")
- **Suspend** caveats (S0ix vs S3, broken kernel versions)
- **Audio** quirks (Sound Open Firmware → `sof-firmware`)
- **Graphics** quirks (specific kernel options, Xe vs i915)
- **Mobile broadband** (FCC unlock instructions for Quectel modems)
- **Fingerprint reader** support level (`fprintd` compatibility, libfprint version)
- **Function keys** (any need for keyd/xkb tweaks)
- **fwupd** support (firmware updates via LVFS testing remote)
- **Dock / Thunderbolt** specifics

---

## CPU microcode

| Page | URL | When |
|---|---|---|
| CPU microcode update | <https://wiki.archlinux.org/title/Microcode> | Confirm `intel-ucode` vs `amd-ucode` requirement; mkinitcpio early-microcode CPIO |
| Intel | <https://wiki.archlinux.org/title/Intel> | General Intel-specific notes |
| AMD | <https://wiki.archlinux.org/title/AMD> | General AMD-specific notes |

Detect: `lscpu | grep 'Vendor ID'` → `GenuineIntel` / `AuthenticAMD`.

---

## GPU drivers

| Vendor | Page | Notes |
|---|---|---|
| Intel | <https://wiki.archlinux.org/title/Intel_graphics> | i915 vs xe driver, modesetting tear-free |
| AMD | <https://wiki.archlinux.org/title/AMDGPU> | amdgpu, radeon, vulkan-radeon |
| AMD AI/Pro | <https://wiki.archlinux.org/title/AMD_ROCm> | Compute / AI workloads |
| NVIDIA | <https://wiki.archlinux.org/title/NVIDIA> | open-kernel vs nouveau; KMS, suspend |
| NVIDIA Optimus | <https://wiki.archlinux.org/title/NVIDIA_Optimus> | Hybrid laptops |
| Nouveau | <https://wiki.archlinux.org/title/Nouveau> | Open NVIDIA driver |

Detect: `lspci -nnk | grep -A3 -E 'VGA|3D|Display'`.

---

## Audio

| Page | URL | When |
|---|---|---|
| Audio | <https://wiki.archlinux.org/title/Advanced_Linux_Sound_Architecture> | ALSA basics |
| PipeWire | <https://wiki.archlinux.org/title/PipeWire> | Recommended modern stack |
| PulseAudio | <https://wiki.archlinux.org/title/PulseAudio> | Legacy |
| Sound Open Firmware | <https://wiki.archlinux.org/title/Sound_Open_Firmware> | **REQUIRED for Tiger Lake / Alder Lake / Meteor Lake / T14 Gen 2 audio**: install `sof-firmware` |

Detect: `lsmod | grep snd_sof` → SOF in use → `sof-firmware` is mandatory.

---

## Network

| Page | URL | When |
|---|---|---|
| NetworkManager | <https://wiki.archlinux.org/title/NetworkManager> | Default desktop/laptop choice |
| iwd | <https://wiki.archlinux.org/title/Iwd> | Lightweight Wi-Fi-only |
| systemd-networkd | <https://wiki.archlinux.org/title/Systemd-networkd> | Servers, embedded |
| Network configuration | <https://wiki.archlinux.org/title/Network_configuration> | General reference |
| Wireless network configuration | <https://wiki.archlinux.org/title/Wireless_network_configuration> | Wi-Fi specifics |
| ThinkPad mobile Internet | <https://wiki.archlinux.org/title/ThinkPad_mobile_Internet> | Quectel WWAN FCC unlock |

---

## Bluetooth

| Page | URL |
|---|---|
| Bluetooth | <https://wiki.archlinux.org/title/Bluetooth> |
| Bluetooth headset | <https://wiki.archlinux.org/title/Bluetooth_headset> |

Packages for archinstall: `bluez`, `bluez-utils`, plus `app_config.bluetooth_config.enabled = true`.

---

## Power management (laptops)

| Page | URL | Notes |
|---|---|---|
| Power management | <https://wiki.archlinux.org/title/Power_management> | Index |
| TLP | <https://wiki.archlinux.org/title/TLP> | Profile-based, more granular |
| power-profiles-daemon | <https://wiki.archlinux.org/title/Power_profiles_daemon> | Simpler; integrates with KDE/GNOME |
| tuned | <https://wiki.archlinux.org/title/Tuned> | RHEL-style profiles |

**Pick exactly one** of TLP / power-profiles-daemon / tuned — they conflict.

archinstall knob: `app_config.power_management_config.power_management = "power-profiles-daemon"` (or `"tuned"`).

---

## Secure Boot + LUKS + TPM2

| Page | URL | When |
|---|---|---|
| Secure Boot (UEFI) | <https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot> | Canonical sbctl workflow; pacman hook |
| dm-crypt / Encrypting an entire system | <https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system> | LUKS root install patterns |
| dm-crypt / System configuration | <https://wiki.archlinux.org/title/Dm-crypt/System_configuration> | crypttab, mkinitcpio HOOKS |
| systemd-cryptenroll | <https://wiki.archlinux.org/title/Systemd-cryptenroll> | TPM2 LUKS unlock |
| Trusted Platform Module | <https://wiki.archlinux.org/title/Trusted_Platform_Module> | PCR policies, sealing |
| Unified kernel image | <https://wiki.archlinux.org/title/Unified_kernel_image> | UKI generation via mkinitcpio / ukify |
| Mkinitcpio | <https://wiki.archlinux.org/title/Mkinitcpio> | HOOKS: `systemd sd-vconsole sd-encrypt` |

See [`secureboot-tpm-luks.md`](secureboot-tpm-luks.md) for the integrated workflow.

---

## Bootloaders

| Bootloader | Page | Notes |
|---|---|---|
| systemd-boot | <https://wiki.archlinux.org/title/Systemd-boot> | Best for sbctl + UKI; UX5606 + t14-gen2 default |
| GRUB | <https://wiki.archlinux.org/title/GRUB> | Heavyweight; multi-OS friendly |
| EFISTUB | <https://wiki.archlinux.org/title/EFISTUB> | Boot kernel directly |
| rEFInd | <https://wiki.archlinux.org/title/REFInd> | Pretty boot menu |
| Limine | <https://wiki.archlinux.org/title/Limine> | Newer minimal |

---

## Firmware / fwupd

| Page | URL | When |
|---|---|---|
| fwupd | <https://wiki.archlinux.org/title/Fwupd> | UEFI BIOS, NVMe, fingerprint, dock firmware updates |
| LVFS | external: <https://fwupd.org/> | Browse what's actually shipped per device |

For devices that need the testing remote (T14 Gen 2 fingerprint reader is one): `fwupdmgr enable-remote lvfs-testing`.

---

## Display server

| Page | URL |
|---|---|
| Wayland | <https://wiki.archlinux.org/title/Wayland> |
| Xorg | <https://wiki.archlinux.org/title/Xorg> |
| Display manager | <https://wiki.archlinux.org/title/Display_manager> |

---

## Filesystems

| FS | Page | Notes |
|---|---|---|
| btrfs | <https://wiki.archlinux.org/title/Btrfs> | Subvolumes, snapshots; UX5606 uses this |
| ext4 | <https://wiki.archlinux.org/title/Ext4> | Boring + reliable |
| xfs | <https://wiki.archlinux.org/title/XFS> | High-perf for large files |
| f2fs | <https://wiki.archlinux.org/title/F2FS> | Mobile / SSD-tuned |
| Snapper | <https://wiki.archlinux.org/title/Snapper> | btrfs snapshot manager (archinstall integrates) |
| Timeshift | <https://wiki.archlinux.org/title/Timeshift> | btrfs/rsync snapshots (archinstall alt) |

---

## Input

| Page | URL | When |
|---|---|---|
| Libinput | <https://wiki.archlinux.org/title/Libinput> | Touchpad/mouse tweaks |
| Xorg keyboard configuration | <https://wiki.archlinux.org/title/Xorg/Keyboard_configuration> | X11 layout, options |
| keyd | <https://wiki.archlinux.org/title/Keyd> | Per-key remapping daemon (UX5606 + h82 use this) |
| fprintd | <https://wiki.archlinux.org/title/Fprint> | Fingerprint authentication |

---

## Quick reference: hardware → wiki page

| Detected by | Wiki page to fetch |
|---|---|
| `dmidecode -s system-product-name` matches a known laptop model | `Lenovo_ThinkPad_<model>_(Intel/AMD)_Gen_<n>` etc. |
| `lspci VGA Intel` | `Intel_graphics` |
| `lspci VGA AMD` | `AMDGPU` |
| `lspci VGA NVIDIA` | `NVIDIA` |
| `lsmod \| grep snd_sof` | `Sound_Open_Firmware` |
| `lspci Network 802.11 Intel` | (drivers in `linux-firmware-intel`); model-page Wi-Fi section |
| `lspci Bluetooth` (or `lsmod \| grep btusb`) | `Bluetooth` |
| `lsusb \| grep -iE 'fingerprint\|synaptics.*06cb'` | `Fprint` |
| `lsusb \| grep -i quectel` | `ThinkPad_mobile_Internet` |
| `/sys/class/tpm/tpm0` exists | `Trusted_Platform_Module` + `Systemd-cryptenroll` |
| `bootctl status` shows `Secure Boot: enabled` | `Unified_Extensible_Firmware_Interface/Secure_Boot` |

---

## Citation discipline

When summarizing a wiki page back to the user, **always link to the section anchor**, not just the page:

```
[Sound Open Firmware → Installation](https://wiki.archlinux.org/title/Sound_Open_Firmware#Installation)
```

Anchors come from the page's heading IDs (replace spaces with `_`). This keeps recommendations auditable.
