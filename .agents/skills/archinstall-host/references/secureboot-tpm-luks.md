# Secure Boot + LUKS + TPM2 enrollment

The integrated workflow for getting:

1. **Secure Boot** with user-enrolled keys (sbctl), pacman hook for re-signing, signed systemd-boot + UKI.
2. **LUKS** full-disk encryption on root.
3. **TPM2** unlock bound to PCR 7 (Secure Boot state) so the laptop boots straight to login.
4. A **passphrase fallback** so a TPM event (firmware update, GPU swap, BIOS reset) doesn't brick the disk.

This reference is what `archinstall/UX5606/secureboot-tpm-enroll.sh` implements. Mirror its pattern for new hosts.

ArchWiki canonical:
- [Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [dm-crypt / System configuration](https://wiki.archlinux.org/title/Dm-crypt/System_configuration)
- [Unified kernel image](https://wiki.archlinux.org/title/Unified_kernel_image)

---

## Prerequisites (in `packages` at install time)

```
sbctl
cryptsetup
tpm2-tools
efibootmgr
mkinitcpio        # already in base; UKI support requires recent
```

Plus `bootloader_config = { "bootloader": "Systemd-boot", "uki": true, "removable": false }` in `user_configuration.json`.

---

## Step 0: pre-flight checks (the script's defensive guards)

The first-boot service should bail out gracefully under each of these:

```bash
# Booted via UEFI?
[[ -d /sys/firmware/efi/efivars ]] || exit 0

# sbctl installed?
command -v sbctl >/dev/null || exit 0

# Already done?
[[ -e /var/lib/<host>-install/secureboot-tpm.done ]] && exit 0
```

The systemd unit should also use `ConditionPathExists=!/var/lib/<host>-install/secureboot-tpm.done` so the unit itself becomes a no-op once provisioning is complete.

---

## Step 1: Firmware in Setup Mode

sbctl can ONLY enroll keys when the firmware is in Setup Mode (factory-default Platform Key absent or wiped). Detection:

```bash
sbctl status | grep -Eiq 'Setup Mode:[[:space:]]*(Enabled|✓)'
```

If Setup Mode is OFF, the script logs a hint and exits 0 (next reboot, user enters firmware UI, "Reset to Setup Mode" or "Clear Secure Boot Keys", reboots, the service runs again):

```
sudo systemctl start <host>-secureboot-tpm-enroll.service
```

In QEMU testing, the writable copy of `OVMF_VARS.4m.fd` (with NO pre-enrolled keys) starts in Setup Mode, so the service runs immediately.

---

## Step 2: Create + enroll keys

```bash
sbctl create-keys
sbctl enroll-keys -m
```

`-m` (`--microsoft`) adds the Microsoft KEK so signed Windows / Option ROM / OEM driver UEFI binaries still load (e.g. NVIDIA Option ROM, fwupd update capsules). Add `-f` to also enroll the OEM platform certs (some hardware refuses to boot without them — Lenovo's tendency to require this is well-documented).

Result: `/usr/share/secureboot/keys/{PK,KEK,db}/<key>.{auth,key,pem}` and the matching efivars are populated. Setup Mode is now OFF.

---

## Step 3: Sign every EFI binary

`sbctl verify` lists everything that needs signing:

```bash
sbctl verify
# typically:
# /efi/EFI/systemd/systemd-bootx64.efi  is not signed
# /efi/EFI/BOOT/BOOTX64.EFI             is not signed
# /efi/EFI/Linux/arch-linux-zen.efi     is not signed
```

Sign each (`-s` symlinks the unsigned path → signed copy in `/var/lib/sbctl/files`):

```bash
for path in $(sbctl verify | awk '/is not signed/ {print $2}'); do
  sbctl sign -s "$path"
done
```

UX5606's script also signs explicit known paths to be defensive in case `verify` is silent on something:

```bash
for path in \
  /efi/EFI/systemd/systemd-bootx64.efi \
  /boot/EFI/systemd/systemd-bootx64.efi \
  /efi/EFI/BOOT/BOOTX64.EFI \
  /boot/EFI/BOOT/BOOTX64.EFI \
  /efi/EFI/Linux/*.efi \
  /boot/EFI/Linux/*.efi; do
  [[ -e "$path" ]] && sbctl sign -s "$path"
done
```

---

## Step 4: Pacman hook for automatic re-signing

`sbctl` ships with a hook at `/usr/share/libalpm/hooks/zz-sbctl.hook` that re-signs everything tracked by `sbctl list-files` after kernel / systemd / bootloader updates. Verify it's there post-install:

```bash
ls -la /usr/share/libalpm/hooks/ | grep sbctl
# zz-sbctl.hook
```

No additional config needed. Confirm `sbctl list-files` shows what you expect.

---

## Step 5: Reboot, enable Secure Boot, verify

```bash
sbctl status
# Setup Mode:    Disabled
# Secure Boot:   Enabled
bootctl status
# Secure Boot: enabled (user)
```

If `Secure Boot: disabled (user)` shows up, the firmware UI may need to flip the master Secure Boot toggle on (it stays off after key enrollment on some firmware versions). Reboot, F2/F12, enable Secure Boot, save, reboot again.

---

## Step 6: TPM2 LUKS enrollment

Detect TPM 2.0 presence:

```bash
[[ -e /sys/class/tpm/tpm0 ]] || exit 0  # no TPM
systemd-analyze has-tpm2                # cleaner check
```

Find the LUKS device:

```bash
# UX5606's approach: walk findmnt for the root mapper, then look up the underlying device.
source="$(findmnt -no SOURCE /)"            # /dev/mapper/cryptroot
mapper="${source#/dev/mapper/}"             # cryptroot
luks_device="$(cryptsetup status "$mapper" \
  | awk -F: '/^[[:space:]]*device:/ { gsub(/^[[:space:]]+/, "", $2); print $2; exit }')"
# /dev/nvme0n1p2
```

Enroll TPM2 unlock bound to PCR 7 (Secure Boot state):

```bash
echo -n "$LUKS_PASSPHRASE" | systemd-cryptenroll "$luks_device" \
  --unlock-key-file=- \
  --tpm2-device=auto \
  --tpm2-pcrs=7
```

Verify:

```bash
systemd-cryptenroll --tpm2-device=list
cryptsetup luksDump "$luks_device" | grep -A2 'systemd-tpm2'
# Tokens:
#   0: systemd-tpm2
```

Add to `/etc/crypttab` so initramfs auto-unlocks on boot:

```
cryptroot   UUID=<luks-uuid>   none   tpm2-device=auto
```

UX5606's script writes this entry idempotently:

```bash
if ! grep -qF 'tpm2-device=auto' /etc/crypttab 2>/dev/null; then
  uuid="$(blkid -s UUID -o value "$luks_device")"
  printf '%s\tUUID=%s\tnone\ttpm2-device=auto\n' "$mapper" "$uuid" >> /etc/crypttab
fi
```

After reboot: no passphrase prompt — TPM2 unwraps the LUKS key, kernel mounts root.

---

## PCR selection guidance

What you bind TPM2 unlock to determines what triggers a re-prompt. Common choices:

| PCRs | Bound to | Triggers re-prompt | Recommendation |
|---|---|---|---|
| `7` | Secure Boot state (enrolled keys, db) | Disabling Secure Boot, key change | **Default for sbctl** |
| `0+7` | Firmware code + Secure Boot | BIOS/UEFI update, key change | Stricter; common with vendor firmware updates |
| `7+11` | Secure Boot + UKI measurement | Kernel/UKI update too | Use with `bootloader_config.uki = true` |
| `0+2+7` | Firmware + Option ROMs + Secure Boot | Hardware change, GPU/eGPU, BIOS update | High-paranoia |

Avoid `0` alone — multiple TPM-attestation papers show it's vulnerable to "Evil Maid" attacks where an attacker boots a different OS that produces the same PCR 0 value.

UX5606 uses `--tpm2-pcrs=7`. t14-gen2 should use the same.

---

## mkinitcpio HOOKS

For TPM2 unlock to work in initramfs, use the **systemd** hook stack, not the legacy busybox stack:

```
# /etc/mkinitcpio.conf
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
```

Order matters: `systemd` before `sd-encrypt`. `sd-vconsole` before `sd-encrypt` for non-US keymap on the LUKS prompt. Then regenerate:

```bash
mkinitcpio -P
```

If `bootloader_config.uki = true`, the UKI is regenerated as `/boot/EFI/Linux/arch-linux.efi` (or per kernel name). The UKI bundles initramfs + cmdline + microcode into one signed PE binary.

---

## /etc/crypttab vs /etc/crypttab.initramfs

- `/etc/crypttab` — read by systemd's normal `cryptsetup-generator` for late-userspace volumes (e.g. encrypted home, swap on a separate LUKS volume).
- `/etc/crypttab.initramfs` — copied into the initramfs by the `sd-encrypt` hook for **early-userspace** unlock (e.g. root LUKS).

For root LUKS with TPM2 unlock you need the entry in `/etc/crypttab.initramfs`, OR you can use the `rd.luks.*` kernel cmdline parameters (which the UKI bakes in).

Standard pattern:

```bash
# /etc/crypttab.initramfs (early)
cryptroot UUID=<luks-uuid> none tpm2-device=auto,discard

# /etc/crypttab (late, e.g. encrypted swap)
cryptswap UUID=<swap-luks-uuid> /etc/swap-keyfile swap,cipher=aes-xts-plain64,size=512
```

UX5606 only writes to `/etc/crypttab` (works because its initramfs is generated to include the systemd hook + sd-encrypt module). If your install uses an older mkinitcpio config, prefer `/etc/crypttab.initramfs`.

---

## Recovery passphrase / "before relying on TPM unlock"

`systemd-cryptenroll` adds the TPM2 token alongside (not replacing) the original LUKS keyslot. The original passphrase still works. KEEP IT — TPM events that change PCR 7 (firmware reset, key re-enrollment, motherboard swap) will lock you out of TPM unlock until you re-enroll, and you need the passphrase to do that.

Generate a recovery passphrase explicitly:

```bash
systemd-cryptenroll /dev/nvme0n1p2 --recovery-key
# prints a one-line recovery passphrase: "abcd-efgh-ijkl-mnop-qrst-uvwx-yzab-cdef"
# stash this somewhere offline (1Password, paper, etc.)
```

The recovery key is BIP-39-style, easier to read out loud than a hex blob.

---

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `sbctl enroll-keys: failed to enroll: device not in setup mode` | PK already enrolled (firmware not in Setup Mode) | Firmware UI → "Reset to Setup Mode" / "Clear All Secure Boot Variables" → reboot |
| Boot fails with "Security violation" / "Invalid signature" | A binary loaded by firmware is unsigned | Reboot to USB rescue, `arch-chroot`, `sbctl verify`, sign anything missing |
| `systemd-cryptenroll: TPM2 not found` | TPM disabled in firmware, or no `/sys/class/tpm/tpm0` | Firmware UI → "Security" → enable TPM/PTT/fTPM → reboot |
| TPM unlock prompts for passphrase after every boot | Firmware update changed PCR 7 | Re-enroll: `systemd-cryptenroll --wipe-slot=tpm2 ...` then re-add |
| `bootctl status: Secure Boot: disabled (user)` after enrollment | Master Secure Boot toggle still off in firmware | Firmware UI → enable Secure Boot → save → reboot |
| `cryptsetup status` shows mapper but `findmnt -no SOURCE /` is empty | Different rootfs naming (e.g. `/dev/dm-0` not `/dev/mapper/cryptroot`) | Walk via `dmsetup ls` and `cryptsetup status` instead |
| Pacman hook re-signs but UEFI still rejects | UKI was regenerated AFTER signing; sign the new UKI | `sbctl sign -s /boot/EFI/Linux/<new>.efi` |

---

## Modern alternative: bootctl --secure-boot-auto-enroll

Recent systemd-boot supports auto-enrolling keys on first boot when the firmware is in Setup Mode:

```bash
bootctl install --secure-boot-auto-enroll yes
```

This puts `loader.conf` keys in the ESP and lets systemd-boot itself enroll them. **Don't combine with sbctl** — pick one mechanism. UX5606 uses sbctl explicitly (more control over which Microsoft keys to enroll, easier to script via the pacman hook).

---

## Putting it all together: the per-host service skeleton

`archinstall/<hostname>/<hostname>-secureboot-tpm-enroll.service`:

```ini
[Unit]
Description=<HOSTNAME> Secure Boot signing and TPM2 LUKS enrollment
Documentation=https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot
Documentation=https://wiki.archlinux.org/title/Systemd-cryptenroll#Trusted_Platform_Module
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=!/var/lib/<hostname>-install/secureboot-tpm.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/<hostname>-secureboot-tpm-enroll

[Install]
WantedBy=multi-user.target
```

`archinstall/<hostname>/secureboot-tpm-enroll.sh`: copy [`archinstall/UX5606/secureboot-tpm-enroll.sh`](../../../archinstall/UX5606/secureboot-tpm-enroll.sh) and rename `STATE_DIR=/var/lib/ux5606-install` → `/var/lib/<hostname>-install`. Wire installation in `custom_commands` (UX5606's heredoc shows the pattern).
