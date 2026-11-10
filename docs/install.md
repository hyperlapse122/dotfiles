# Fresh installation

The NixOS hosts are the directories under `hosts/` without a `host.nix` file (today `MS-7D91`). In the commands below, replace `<host>` with the target machine's directory name (`MS-7D91`); `nix eval .#nixosConfigurations --apply builtins.attrNames` lists every NixOS output. A machine without a host directory needs [adding a host](adding-a-host.md) first. A Mac follows [macOS hosts](macos.md). Notes that apply to one machine only are under [per-host notes](#per-host-notes).

The repository owner runs every step in this runbook by hand on the target machine. No coding agent may run `disko`, `nixos-install`, `nixos-rebuild switch`, `nr switch`, `sbctl`, `systemd-cryptenroll`, or any other disk-formatting, firmware-enrollment, or host-switch command.

This procedure erases the existing operating system and all data on the target NVMe disk. Do not repeat it for routine configuration changes.

## Back up before erasing the disk

Before booting the installation media or running `disko`, confirm and back up:

- **YubiKeys**: all three YubiKeys that carry the OpenPGP key, with their User and Admin PINs and the offline signing-key backup verified and stored separately from the machine.
- **GPG public key and ownertrust**: `keys/signing.asc` (fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`) committed in the repository and a copy of your GPG ownertrust (`gpg --export-ownertrust`) if you rely on trust assignments outside the ultimate trust declared for `keys/signing.asc`.
- **File-based SSH keys**: any SSH private key on the machine that is not already recorded in `secrets/hosts/<host>/ssh.yaml` or 1Password.
- **1Password access**: the 1Password Emergency Kit (account password, Secret Key, and two-factor authentication on another device) so you can sign in on the fresh installation.
- **Disk data**: every file, unpushed Git branch or worktree, and local state on the disk that `disko` will destroy (for `MS-7D91`, `/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0WB26038A`). Back up or disconnect any other attached storage, such as the secondary HDD at `/dev/disk/by-id/ata-ST2000DM008-2UB102_ZK30PHAD-part1` (`/mnt/data`), if you want physical isolation while partitioning.

## Prepare before erasing the disk

1. Complete [bootstrap age preparation](adding-a-host.md#create-bootstrap-age-material) and secret encryption (`../secrets/README.md`) before wiping the machine. For `MS-7D91`, `secrets/bootstrap/MS-7D91/{age-key.asc,recipient.txt}` and `secrets/hosts/MS-7D91/{ssh.yaml,ssh.pub}` are already committed in this repository. Verify that a YubiKey can decrypt `secrets/bootstrap/<host>/age-key.asc`.
2. Push repository changes to `main` and confirm that the installation environment can clone `https://github.com/hyperlapse122/dotfiles.git` over HTTPS without SSH authentication. You can also keep a clone on separate media.
3. Choose a LUKS recovery passphrase. Do not store it in plaintext in the repository or on the target disk. If you will reuse an existing Secure Boot signing bundle, prepare an encrypted external backup of `/var/lib/sbctl`.
4. Prepare a NixOS x86_64 installation USB. If the firmware's current Secure Boot policy does not trust the installation media, temporarily disable Secure Boot in the firmware. Do not erase factory platform keys, `db`, or `dbx` yet.

If the YubiKey cards are the only way to decrypt `secrets/bootstrap/<host>/age-key.asc`, losing all of them prevents recovery of the host age identity. Keep the backup YubiKeys and the offline key backup safe before erasing the disk.

## Check the disk from the installation media

Boot the NixOS installation USB and run the following commands in a terminal. Verify network access, clone the repository, and inspect the attached disks against `hosts/<host>/disko.nix`:

```sh
git clone https://github.com/hyperlapse122/dotfiles.git
cd dotfiles
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
sudo dmidecode -s system-product-name
sudo dmidecode -s system-version
```

Confirm that the machine matches `<host>`, and that the `/dev/disk/by-id/` path declared as `device` in `hosts/<host>/disko.nix` matches the target NVMe drive in the `lsblk` and `/dev/disk/by-id/` output. For `MS-7D91`, `hosts/MS-7D91/disko.nix` declares `/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0WB26038A`. If the physical disk on the machine has a different `/dev/disk/by-id/` symlink, stop and update `hosts/<host>/disko.nix` before continuing.

Do not select the target disk by a kernel enumeration name such as `/dev/nvme0n1`.

## Initialize the disk and install the bootstrap configuration

The `disko` command below **erases the entire target disk** named in `hosts/<host>/disko.nix`. Run it only after confirming the `/dev/disk/by-id/` path above:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run .#disko -- \
  --mode disko hosts/<host>/disko.nix
sudo nixos-install --flake .#<host>-bootstrap --no-root-passwd
sudo nixos-enter --root /mnt -c 'passwd h82'
```

Enter the LUKS passphrase when `disko` prompts for it, and set the login password for `h82` in the `nixos-enter` step. The layout in `hosts/<host>/disko.nix` creates a 2 GiB ESP (`/boot`, partition label `disk-main-ESP`) and a LUKS2 container (`cryptroot`, partition label `disk-main-luks`) holding a Btrfs filesystem with `/root` (`/`), `/home`, `/nix`, `/log` (`/var/log`), and `/swap` subvolumes. The `/swap` subvolume holds a 64 GiB swapfile; no hibernation resume offset is configured. Disks other than `device` in `hosts/<host>/disko.nix` are not partitioned or formatted by `disko`.

For the first reboot, keep Secure Boot disabled in firmware (`<host>-bootstrap` uses `systemd-boot` rather than Lanzaboote) and unlock `cryptroot` with the LUKS passphrase. Log in to Plasma as `h82` and verify `sudo -v`. The bootstrap output needs neither decrypted sops secrets nor `/var/lib/sbctl`.

## Prepare local decryption and signing keys

On the installed bootstrap system, clone the repository to `~/src/github.com/hyperlapse122/dotfiles` (the `ghq` root `~/src`) over HTTPS and recover the host's age identity with a YubiKey inserted. See `../secrets/README.md` for the pipeline the helper runs:

```sh
git clone https://github.com/hyperlapse122/dotfiles.git ~/src/github.com/hyperlapse122/dotfiles
cd ~/src/github.com/hyperlapse122/dotfiles
./scripts/recover-age-identity
```

On the installed NixOS host, `recover-age-identity` resolves `<host>` from `uname -n`, which `mkHost` sets to the host directory name (`MS-7D91`), decrypts `secrets/bootstrap/<host>/age-key.asc` as `h82` through `gpg`, and pipes the plaintext across `sudo` to `/run/current-system/sw/bin/restore-age-identity`, which verifies `secrets/bootstrap/<host>/recipient.txt` and atomically writes `/var/lib/sops-nix/key.txt` (`root:root`, mode `0600`). Pass `--host <host>` if you run the helper from an environment whose hostname does not match.

`gpg-agent` uses `dotfiles-pinentry` (`packages/pinentry-keyring.nix`) with `pinentry-qt` as its fallback dialog. Three YubiKeys carry the same OpenPGP key under separate PINs; on the first qualifying prompt for a card, `dotfiles-pinentry` stores that card's User PIN in the Secret Service keyring (`kdewallet`) under service `dotfiles.pinentry.openpgp` and account `yubikey:<serial>:user`, so later Git signing and card decryption do not prompt again while the wallet is unlocked. To clear a stored PIN for a card serial, run `dotfiles-pinentry forget <card-id>`. In 1Password > Settings > Developer, also enable the SSH agent and "Integrate with 1Password CLI" once.

Create the Secure Boot signing keys under `/var/lib/sbctl` (or restore an existing `/var/lib/sbctl` backup with `root:root` ownership and `go-rwx` permissions; see [lost Secure Boot signing keys](recovery.md#lost-secure-boot-signing-keys)), then switch from the bootstrap generation to the production `<host>` output and verify that every boot binary is signed:

```sh
sudo sbctl create-keys
nr switch --host <host>
sudo sbctl verify
```

`nr` refuses a bare `nr switch` while running the bootstrap generation so a bootstrap host cannot move to production accidentally; pass `--host <host>` on this first switch (or run `sudo nixos-rebuild switch --flake .#<host>`), and use `nr switch` on routine rebuilds afterward. The production switch activates `sops-install-secrets.service`, publishes the `gh` and `glab` configuration and runtime token files under `/run/secrets/cli-auth/`, provisions the KWallet-backed desktop SSH key (`~/.ssh/id_ed25519_nix_config`) from `secrets/hosts/<host>/ssh.yaml` through `desktop-ssh-provision.service`, replaces `systemd-boot` with Lanzaboote, and signs the EFI binaries under `/boot` with `/var/lib/sbctl`. Check the EFI executables managed by Lanzaboote in the `sudo sbctl verify` output.

## Enroll Secure Boot keys

Reboot into firmware setup and switch Secure Boot to Setup Mode (in MSI Click BIOS, set Secure Boot mode to Custom and clear or reset the keys to enter Setup Mode without deleting `dbx`). Boot back into NixOS and enroll the `/var/lib/sbctl` keys alongside Microsoft's vendor certificates (required for option ROMs such as the NVIDIA card):

```sh
sudo sbctl status
sudo sbctl enroll-keys --microsoft
```

Reboot into firmware setup, enable Secure Boot, and boot NixOS. Confirm that Secure Boot is active and enforcing user mode:

```sh
bootctl status --no-pager
sudo sbctl status
```

Do not proceed to TPM2 enrollment until `bootctl status` and `sudo sbctl status` both report Secure Boot enabled with the enrolled keys.

## TPM2 automatic unlocking

The device in the commands below is the **LUKS2 partition** (`/dev/disk/by-partlabel/disk-main-luks`), not the whole NVMe disk. Verify the partition label and existing key slots first:

```sh
lsblk -o NAME,PATH,FSTYPE,PARTLABEL,MOUNTPOINTS
sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks
```

Enroll a TPM2 key slot bound to PCR 7 (SHA-256) in the final Secure Boot state. Do not remove the recovery passphrase slot:

```sh
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-luks \
  --tpm2-device=auto --tpm2-pcrs=7:sha256 --tpm2-with-pin=no
```

Reboot to confirm that `cryptroot` unlocks automatically without prompting for the LUKS passphrase, and verify that the recovery passphrase still unlocks the disk if needed. On the production output (`!config.my.bootstrap`), Plymouth draws the boot splash and hides the boot menu unless Space is held at power-on (press Esc during boot to toggle the text log). PCR 7 binds automatic unlock to the Secure Boot policy and authority chain; retaining Microsoft's certificates means other boot binaries signed by those certificates satisfy PCR 7 as well.

Immediately after enrollment, back up the LUKS header and `/var/lib/sbctl` to external media using the procedure in [Back up LUKS and Secure Boot recovery material](recovery.md#back-up-luks-and-secure-boot-recovery-material). Confirm hardware behavior separately from repository checks.

## Per-host notes

### MS-7D91

MSI MS-7D91 desktop workstation (Intel i7-13700F, NVIDIA GeForce RTX 3060, KDE Plasma 6 on Wayland).

- `sudo dmidecode -s system-product-name` reports `MS-7D91`.
- `hosts/MS-7D91/disko.nix` targets `/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0WB26038A`. Check the actual symlink under `/dev/disk/by-id/` on the machine before running `disko`.
- The secondary 2 TB SATA HDD (`/dev/disk/by-id/ata-ST2000DM008-2UB102_ZK30PHAD-part1`) is not touched by `disko`; `hosts/MS-7D91/default.nix` mounts it read-write at `/mnt/data` as `exfat` with `nofail` and owner `h82` (`uid=1000`, `gid=100`).
- `hosts/MS-7D91/hardware.nix` enables Intel CPU microcode, the proprietary NVIDIA driver (`hardware.nvidia.open = false`, `modesetting.enable = true`), `nvidia-container-toolkit`, and loads `nvidia`, `nvidia_modeset`, and `nvidia_drm` in the initrd on the production output so the Plymouth boot splash has KMS early.
- `hosts/MS-7D91/default.nix` enables `my.nuphyGem80.enable` (udev access for the NuPhy Gem80 keyboard), `my.t3.cli.enable`, `my.t3.desktop.enable`, `my.printing.queues = [ "office" ]`, `my.tailscale.advertiseRoutes = !config.my.bootstrap`, and `my.intune.enable = !config.my.bootstrap`.
- After the production switch, enroll the machine in Microsoft Intune by following [Microsoft Intune on NixOS](intune.md). Enrollment is interactive and is not part of the switch.
- In MSI Click BIOS, enter Secure Boot Setup Mode through the firmware's Secure Boot settings before running `sudo sbctl enroll-keys --microsoft`.
