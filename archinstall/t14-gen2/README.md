# t14-gen2 physical install

Host profile for a Lenovo ThinkPad T14 Gen 2 Intel machine.

This install is destructive once archinstall writes the selected disk. Read the
whole page first, then run commands from the Arch live ISO.

## What this profile installs

- Hostname: `t14-gen2`
- Locale/timezone: `ko_KR.UTF-8`, `Asia/Seoul`
- Kernel/boot: `linux-zen`, systemd-boot, UKI enabled
- Desktop: KDE Plasma + SDDM + PipeWire
- Network: NetworkManager
- Disk expectation: UEFI + LUKS full-disk encryption + Btrfs root
- Hardware packages: `intel-ucode`, Intel graphics/media stack,
  `sof-firmware`, Bluetooth, fingerprint/fwupd tooling, laptop power tools
- Mirror: Arch's geo mirror (`https://geo.mirror.pkgbuild.com/$repo/os/$arch`).
  Korean mirrors were preferred during setup, but multiple KR mirrors served
  mismatched `libnotify` package/signature pairs during validation.
- First boot: `t14-gen2-secureboot-tpm-enroll.service` signs boot artifacts
  with `sbctl` and enrolls TPM2 LUKS unlock bound to PCR 7 when firmware is in
  Setup Mode.

## Before booting the ISO

1. Back up everything on the target disk.
2. In firmware setup:
   - Boot mode: UEFI only.
   - TPM: enabled.
   - Secure Boot: put the machine in **Setup Mode** if you want the first-boot
     service to enroll your own keys automatically. If you leave Secure Boot
     enabled with existing vendor keys, the service will skip key creation and
     you can run it later after entering Setup Mode.
   - Storage mode: AHCI/NVMe, not legacy/RAID compatibility.
3. Prepare a current Arch ISO USB.
4. Decide the target disk name. On this laptop it is usually `/dev/nvme0n1`,
   but verify in the ISO with `lsblk`.

## Create real credentials

`user_credentials.json` is gitignored and the checked-out example credentials
are throwaway VM-only credentials. For a physical install, create a fresh local
file on the live ISO:

```sh
cd /root/dotfiles
cp archinstall/user_credentials.example.json archinstall/t14-gen2/user_credentials.json
mkpasswd -m yescrypt   # root_enc_password
mkpasswd -m yescrypt   # users[0].enc_password
```

Edit `archinstall/t14-gen2/user_credentials.json`:

- set `root_enc_password` to the first hash
- set `users[0].username` to `h82` unless you also edit `USERNAME=h82` inside
  `user_configuration.json`
- set `users[0].enc_password` to the second hash
- set `encryption_password` to a strong LUKS recovery passphrase

Keep that LUKS passphrase outside the laptop until TPM unlock is verified.

## Live ISO commands

Connect networking first (`iwctl` for Wi-Fi, or Ethernet), then:

```sh
timedatectl set-ntp true
pacman -Sy --noconfirm git jq
git clone https://github.com/hyperlapse122/dotfiles.git /root/dotfiles
cd /root/dotfiles
```

If you are installing from a local checkout instead of GitHub, copy it to
`/root/dotfiles` before continuing.

## Recommended physical flow: use the TUI for disk selection

The tracked `user_configuration.json` intentionally does **not** contain a real
physical `disk_config`; disk paths are too dangerous to hardcode in git. Let
archinstall fill the disk layout on the real machine, then save and run it.

```sh
cd /root/dotfiles
archinstall \
  --config archinstall/t14-gen2/user_configuration.json \
  --creds  archinstall/t14-gen2/user_credentials.json
```

In the TUI:

1. Open the disk layout section.
2. Select the real NVMe disk you verified with `lsblk`.
3. Choose a fresh GPT layout with an EFI system partition and encrypted Btrfs
   root.
4. Use the same LUKS passphrase from `user_credentials.json`.
5. Keep systemd-boot + UKI enabled.
6. Save and start installation.

archinstall will install packages, run `custom_commands`, clone this dotfiles
repo to `/home/h82/dotfiles`, and run `install.sh` before reboot.

## Fully silent flow after generating disk_config

If you want a replayable silent install for the exact physical disk, first run a
dry-run to generate a machine-local config:

```sh
archinstall --dry-run
cp /var/log/archinstall/user_configuration.json /root/t14-gen2-physical.json
jq -s '.[0] * {disk_config: .[1].disk_config}' \
  archinstall/t14-gen2/user_configuration.json \
  /root/t14-gen2-physical.json \
  > /root/t14-gen2-silent.json
```

Inspect `/root/t14-gen2-silent.json` and confirm the disk path is correct, then:

```sh
archinstall \
  --config /root/t14-gen2-silent.json \
  --creds  archinstall/t14-gen2/user_credentials.json \
  --silent
```

Do not commit `/root/t14-gen2-silent.json` unless you deliberately want that
exact disk layout tracked.

## First boot checks

After archinstall finishes, reboot and log in as `h82`.

Check the dotfiles bootstrap and first-boot service:

```sh
systemctl status t14-gen2-secureboot-tpm-enroll.service
journalctl -u t14-gen2-secureboot-tpm-enroll.service -b --no-pager
```

Check boot and TPM state:

```sh
bootctl status
sbctl status
systemd-cryptenroll --tpm2-device=list
findmnt -no SOURCE /
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep -i tpm2
```

If the service skipped key enrollment because firmware was not in Setup Mode,
enter firmware setup, clear or reset Secure Boot keys into Setup Mode, boot back
into Arch, then run:

```sh
sudo systemctl start t14-gen2-secureboot-tpm-enroll.service
```

Keep the original LUKS passphrase as a recovery path even after TPM unlock works.

## Re-run dotfiles after first boot

```sh
cd ~/dotfiles
git pull --ff-only
./install.sh
```

The bootstrap uses `uvx dotbot`; do not install dotbot globally.
