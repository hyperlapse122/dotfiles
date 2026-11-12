# Updates and recovery

## Routine configuration applies

On the NixOS host (`MS-7D91`), run `nr switch` from the repository checkout (or `sudo nixos-rebuild switch --flake .#<host>`):

```sh
nr switch
```

On the macOS host (`MacBook-Pro-Mac17-9`), run `nr switch` from the repository checkout (`~/src/github.com/hyperlapse122/dotfiles`); see [macOS hosts](macos.md#everyday-use).

Replace `<host>` with the machine's directory name under `hosts/` (`MS-7D91` or `MacBook-Pro-Mac17-9`) in the commands below. `nr switch` does not format disks. Once the local age identity is installed (`/var/lib/sops-nix/key.txt` on NixOS, `~/.config/nix-config/age/key.txt` on macOS), routine switches do not depend on the YubiKey, the desktop keyring, or 1Password login state. Rebuilds work without the card, while Git signing still requires a card.

Update flake inputs with `nix flake update`. Review the `flake.lock` diff and pass `nix flake check`, the VM tests (`nix build --no-link .#vmChecks.all`), and the builds of every `nixosConfigurations` and `darwinConfigurations` output (see `../AGENTS.md`) before applying. Afterward, use each CLI (`gh`, `glab`) to confirm that its remote token is still accepted by the server. Periodic updates also run automatically through the `Update dependencies` GitHub Actions workflow (`.github/workflows/update-dependencies.yml`), which verifies and pushes updates to `main` or opens a reconciliation pull request.

## Failed authentication applies

On NixOS:

```sh
systemctl status sops-install-secrets.service --no-pager
sudo journalctl -u sops-install-secrets.service -b --no-pager
```

Check logs for secrets before sharing them. If the local age identity is missing or corrupt, repeat [secret recovery](../secrets/README.md) with `./scripts/recover-age-identity` (or `./scripts/recover-age-identity --user --host <host>` on macOS) and run the switch again. From the NixOS installation media or inside `nixos-enter`, the hostname is the installer image's rather than `<host>`, so pass `--host <host>` explicitly. Running the switch again also restores manually deleted `gh` and `glab` configuration files. On a NixOS host with `my.wiredNetwork.enable`, an identity restored after boot also needs `sudo systemctl restart nixos-wired-network` (or a reboot), because the wired profile is rendered once per boot; see [Wired network](install.md#wired-network).

A failed NixOS switch does not transactionally roll back all system changes. If token publication updated only some files, fix the cause and run the switch again. Do not ignore the error or treat provisioning as complete.

## Roll back a boot generation

On NixOS, select a working previous generation from the boot menu. Production outputs hide the menu behind the Plymouth boot splash: hold Space at power-on until the menu appears, or press Esc during the splash to inspect the boot log. If the system can boot to a shell, roll back with:

```sh
sudo nixos-rebuild switch --rollback
```

The boot loader generation limit is 5 (`modules/nixos/system/boot.nix`).

Weekly cleanup (`modules/nixos/system/nix-cleanup.nix`) keeps the 10 newest generations regardless of age, so every entry offered by the boot menu still resolves even after months without a rebuild. Raising `configurationLimit` above the retention floor in `modules/nixos/system/nix-cleanup.nix` would break that guarantee, and the `nix-cleanup` check fails when it does.

For rolling back a macOS generation, see [macOS hosts](macos.md#rolling-back).

## An authentication stack that refuses

If a NixOS rebuild leaves the lock screen or `sudo` refusing a correct password, do not start with `sudo nixos-rebuild switch --rollback`: that command requires the `sudo` that is refusing. Select a previous generation at the boot menu instead by holding Space at power-on.

There is no second way in. No root password is declared, and Lanzaboote signs the kernel command line, so `init=/bin/sh` cannot be injected at the boot menu. When no previous generation boots, use the installation media and `nixos-enter` below.

## TPM unlock failure

Changes to firmware settings or the Secure Boot policy change PCR 7 and stop automatic LUKS unlocking on `MS-7D91`. Boot with the LUKS recovery passphrase and confirm that the firmware or Secure Boot change was intentional. Once the machine is booted in its intended Secure Boot state, replace the TPM2 key slot:

```sh
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-luks \
  --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7:sha256 --tpm2-with-pin=no
```

Use `--wipe-slot=tpm2` only for TPM slots; never delete the recovery passphrase slot. Reboot to verify both automatic TPM unlock and passphrase unlock, then update the external LUKS header backup below.

## Back up LUKS and Secure Boot recovery material

Immediately after installing `MS-7D91` and after updating TPM slots, connect external media and verify that it is mounted. Replace `backup_mount` below with the external media's mount point, never a path on the target disk. `backup_dir` stores each host's backup in a directory named by `uname -n`. Both archives are encrypted to the OpenPGP key in `keys/signing.asc` (`621512777E6933FEB4458FDC4945855D4F283F05`), and temporary plaintext stays in `/run/user/$(id -u)`:

```sh
set -euo pipefail
umask 077
backup_mount=/run/media/h82/EXTERNAL_BACKUP
backup_dir="$backup_mount/$(uname -n)"
if ! findmnt --mountpoint "$backup_mount" >/dev/null; then
  printf '%s\n' 'external backup mount is missing; refusing to write under /run' >&2
  exit 1
fi
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$backup_dir"
backup_tmp=$(mktemp -d /run/user/"$(id -u)"/nix-backup.XXXXXX)
cleanup() {
  sudo rm -f -- "$backup_tmp/luks-header.img" "$backup_tmp/sbctl.tar" "$backup_tmp/header-check" "$backup_tmp/bundle-check"
  rmdir "$backup_tmp" 2>/dev/null || true
}
trap cleanup EXIT
sudo cryptsetup luksHeaderBackup /dev/disk/by-partlabel/disk-main-luks \
  --header-backup-file "$backup_tmp/luks-header.img"
sudo tar --xattrs --acls --numeric-owner -C /var/lib \
  -cpf "$backup_tmp/sbctl.tar" sbctl
sudo chown -R "$(id -u):$(id -g)" "$backup_tmp"
gpg --armor --encrypt \
  --recipient 621512777E6933FEB4458FDC4945855D4F283F05 \
  --output "$backup_dir/luks-header.img.asc" "$backup_tmp/luks-header.img"
gpg --armor --encrypt \
  --recipient 621512777E6933FEB4458FDC4945855D4F283F05 \
  --output "$backup_dir/sbctl.tar.asc" "$backup_tmp/sbctl.tar"
test -s "$backup_dir/luks-header.img.asc" \
  && test -s "$backup_dir/sbctl.tar.asc"
gpg --decrypt --output "$backup_tmp/header-check" "$backup_dir/luks-header.img.asc"
gpg --decrypt --output "$backup_tmp/bundle-check" "$backup_dir/sbctl.tar.asc"
cmp "$backup_tmp/luks-header.img" "$backup_tmp/header-check"
cmp "$backup_tmp/sbctl.tar" "$backup_tmp/bundle-check"
cleanup
trap - EXIT
```

The LUKS header backup contains the key slots active when the backup was taken. Keep `luks-header.img.asc` and `sbctl.tar.asc` on external media off the target disk.

## Repair from the installation media

If `MS-7D91` cannot boot, boot the NixOS installation USB and open and mount the existing LUKS2 and Btrfs filesystems with the declared layout below. Do not rerun `disko` in formatting mode. With network access, clone `https://github.com/hyperlapse122/dotfiles.git` into `/mnt/tmp/dotfiles` (or update an existing clone there):

```sh
sudo cryptsetup open /dev/disk/by-partlabel/disk-main-luks cryptroot
sudo mount -o subvol=/root,compress=zstd,noatime /dev/mapper/cryptroot /mnt
sudo install -d /mnt/home /mnt/nix /mnt/var/log /mnt/boot /mnt/tmp
sudo mount -o subvol=/home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
sudo mount -o subvol=/nix,compress=zstd,noatime /dev/mapper/cryptroot /mnt/nix
sudo mount -o subvol=/log,compress=zstd,noatime /dev/mapper/cryptroot /mnt/var/log
sudo mount /dev/disk/by-partlabel/disk-main-ESP /mnt/boot
if sudo test -d /mnt/tmp/dotfiles/.git; then
  sudo git -C /mnt/tmp/dotfiles pull --ff-only
else
  sudo git clone https://github.com/hyperlapse122/dotfiles.git /mnt/tmp/dotfiles
fi
```

`nixos-enter` sets up the `/dev`, `/sys`, and `/proc` bind mounts automatically. If `/mnt/var/lib/sbctl` is intact, rebuild the boot entries directly:

```sh
sudo nixos-enter --root /mnt -c \
  'cd /tmp/dotfiles && nixos-rebuild boot --flake .#<host>'
```

If `/var/lib/sbctl` was lost or corrupted, restore it first as shown below.

## Lost Secure Boot signing keys

Connect the encrypted external backup, restore `/var/lib/sbctl`, and verify root-only ownership and permissions. From a running NixOS installation:

```sh
set -o pipefail
gpg --decrypt /path/to/sbctl.tar.asc | \
  sudo tar --xattrs --acls --numeric-owner -xpf - -C /var/lib
sudo chown -R root:root /var/lib/sbctl
sudo chmod -R go-rwx /var/lib/sbctl
sudo nixos-rebuild boot --flake .#<host>
```

From the installation USB, complete the mount steps in [Repair from the installation media](#repair-from-the-installation-media), then decrypt the backup from `nix develop` as the live environment's normal user before running `nixos-enter`:

```sh
nix develop path:/mnt/tmp/dotfiles
gpg --import /mnt/tmp/dotfiles/keys/signing.asc
gpg --card-status
set -o pipefail
gpg --decrypt /path/to/sbctl.tar.asc | \
  sudo tar --xattrs --acls --numeric-owner -xpf - -C /mnt/var/lib
sudo chown -R root:root /mnt/var/lib/sbctl
sudo chmod -R go-rwx /mnt/var/lib/sbctl
sudo nixos-enter --root /mnt -c \
  'cd /tmp/dotfiles && nixos-rebuild boot --flake .#<host>'
```

Without a backup of `/var/lib/sbctl`, create a fresh bundle (`sudo sbctl create-keys`), repeat UEFI Secure Boot key enrollment, and re-enroll TPM2 under the new PCR 7 value.

## Lost or replaced YubiKey

Three YubiKeys carry the same OpenPGP key, so losing one card does not lose the signing or encryption key. Rebuilds are unaffected, and Git signing and bootstrap recovery continue on either remaining card. Nothing in this repository changes: the fingerprint (`621512777E6933FEB4458FDC4945855D4F283F05`), `keys/signing.asc`, and every existing ciphertext remain valid.

Provision a replacement card from the offline signing-key backup, never from another card (private keys cannot be extracted from a YubiKey). Restore the backup into a tmpfs `GNUPGHOME`, configure `ed25519` and `cv25519` key attributes on the new card, move the subkeys onto it with `keytocard`, and set its own User and Admin PINs. Because all three cards hold the same encryption subkey, the replacement card decrypts every existing `secrets/bootstrap/<host>/age-key.asc` and external backup without re-encryption.

Clear the lost card's stored PIN from the OS keyring on each host with `dotfiles-pinentry forget <lost-card-serial>`. The replacement card stores its own PIN under `yubikey:<new-serial>:user` on its first qualifying prompt.

Losing the offline signing-key backup is a different failure: the remaining cards are then the last copies of the key. While a working card remains, generate a new OpenPGP key, re-encrypt every `secrets/bootstrap/<host>/age-key.asc` and external backup to it, update `keys/signing.asc` and the fingerprint in `modules/shared/host.nix`, update GitHub/GitLab verification keys, and revoke the old key.

## Restore or rotate a desktop SSH key

On `MS-7D91`, loss of the passphrase-protected working key (`~/.ssh/id_ed25519_nix_config`) or its KWallet passphrase entry is recoverable from `secrets/hosts/MS-7D91/ssh.yaml` while keeping `secrets/hosts/MS-7D91/ssh.pub` unchanged. After reinstalling or unlocking `kdewallet` in a local SDDM Plasma session, run as `h82`:

```sh
systemctl --no-ask-password start desktop-ssh-provision.service
systemctl --user status desktop-ssh-agent.service
```

`desktop-ssh-provision.service` decrypts `secrets/hosts/<host>/ssh.yaml` via systemd credentials, generates a fresh random passphrase in `kdewallet` (folder `nix-config SSH`, entry keyed by the public fingerprint) when needed, and writes `~/.ssh/id_ed25519_nix_config` (`0600`) with the same public key so remote `authorized_keys` and GitHub registrations keep working. Selected 1Password SSH keys remain available as fallback through `~/.1password/agent.sock`.

To rotate a desktop SSH key intentionally:

```sh
umask 077
export DESKTOP_SSH_OUTPUT=$(mktemp -d /run/user/"$(id -u)"/desktop-ssh-rotation.XXXXXX)
```

Run the [desktop SSH source creation recipe](adding-a-host.md#create-the-desktop-ssh-key-source) with `<host>` set to `MS-7D91`. Register `$DESKTOP_SSH_OUTPUT/ssh.pub` on GitHub and remote servers, then copy the new pair into the repository:

```sh
cp "$DESKTOP_SSH_OUTPUT/ssh.yaml" secrets/hosts/<host>/ssh.yaml
cp "$DESKTOP_SSH_OUTPUT/ssh.pub" secrets/hosts/<host>/ssh.pub
rm -rf -- "$DESKTOP_SSH_OUTPUT"
unset DESKTOP_SSH_OUTPUT
```

Stage both files, pass the checks, apply production (`nr switch`), run `systemctl --no-ask-password start desktop-ssh-provision.service`, and verify SSH authentication before revoking the old key on remote services.

## Compromise or decommission of a host

The repository's `.sops.yaml` splits secret recipients across the two hosts as follows:

- `secrets/tokens.yaml`: encrypted to both `MS-7D91` and `MacBook-Pro-Mac17-9`.
- `secrets/wifi.yaml`, `secrets/tailscale.yaml`, `secrets/printers.yaml`: encrypted to `MS-7D91` only (`user-identity-secrets` forbids any `darwin` host recipient on these rules).
- `secrets/hosts/MS-7D91/ssh.yaml` and `secrets/hosts/MS-7D91/wired-network.yaml`: encrypted to `MS-7D91` only.
- `secrets/hosts/MacBook-Pro-Mac17-9/ssh.yaml`, `secrets/hosts/MacBook-Pro-Mac17-9/apple-account.yaml`, `secrets/hosts/MacBook-Pro-Mac17-9/tls-inspection-ca.yaml`, `secrets/hosts/MacBook-Pro-Mac17-9/wired-network.yaml`: encrypted to `MacBook-Pro-Mac17-9` only.

Follow these steps in order when a host is lost, compromised, or retired. Treat every file whose `.sops.yaml` rule lists that host's recipient as exposed:

1. Revoke the host's SSH public key (`secrets/hosts/<host>/ssh.pub`) on GitHub, GitLab, and every server's `authorized_keys`. If `MacBook-Pro-Mac17-9` is compromised, also rotate the Apple Account password stored in `secrets/hosts/MacBook-Pro-Mac17-9/apple-account.yaml`.
2. Remove the host's recipient from every shared `.sops.yaml` rule that lists it (`secrets/tokens.yaml` for a macOS host; `secrets/tokens.yaml`, `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` for a NixOS host). From the repository root with a YubiKey connected, re-encrypt each affected shared file to the remaining recipients and rotate its SOPS data key before writing new secret values:

   ```sh
   nix develop
   export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
   sops updatekeys -y secrets/tokens.yaml
   sops rotate -i secrets/tokens.yaml
   ```

   When rotating after a NixOS host compromise, also run `sops updatekeys -y` and `sops rotate -i` on `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` before clearing `SOPS_AGE_KEY_CMD`.
3. Reissue every exposed token at its provider (and, for a NixOS host, rotate the Wi-Fi passphrases, Tailscale pre-authentication key, and printer credentials), save each new value to a mode `0600` file outside the checkout, pipe it into `sops set --value-stdin`, and remove the temporary file:

   ```sh
   python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read().strip()))' < <token-file> \
     | sops set --value-stdin secrets/tokens.yaml '["<key>"]'
   rm <token-file>
   unset SOPS_AGE_KEY_CMD
   ```

   Keep steps 2 and 3 in this exact order: `sops set` encrypts to the recipients currently on the file, and `sops updatekeys` alone keeps the previous data key until `sops rotate -i` replaces it.
4. Delete `secrets/hosts/<host>/`, `secrets/bootstrap/<host>/`, `hosts/<host>/`, and the per-host creation rules under `^secrets/hosts/<host>/` in `.sops.yaml`.

`wired-network.yaml` holds no credential, so compromise or decommission rotates nothing for it; the file only reveals the shape of an internal network. A NixOS host restored from a generation that predates the wired network feature comes up on DHCP; applying the current production output restores the static address.

### Historical note on the retired VM identity

When this repository restored bare-metal `MS-7D91` and retired the former VMware guest host, a fresh age identity was generated for `MS-7D91` (`secrets/bootstrap/MS-7D91/{age-key.asc,recipient.txt}`), the retired guest recipient was removed from `.sops.yaml`, and `secrets/tokens.yaml`, `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` were re-keyed and had their data keys rotated (`sops updatekeys` and `sops rotate -i`), while the GitHub, JPI GitLab, and Synthetic tokens were updated. However, the retired VM age identity could decrypt the pre-rotation ciphertext preserved in Git history. If a leak of that retired VM identity is ever suspected, re-keying alone does not protect unchanged values from historical commits: rotate the Wi-Fi PSKs in `secrets/wifi.yaml`, the Tailscale key in `secrets/tailscale.yaml`, the printer configuration in `secrets/printers.yaml`, and any token in `secrets/tokens.yaml` that was not already reissued at its provider.

## Replace tokens or a host age identity

To rotate a single token in `secrets/tokens.yaml` without changing recipients, use the `SOPS_AGE_KEY_CMD` and `sops set --value-stdin` pipeline in `../secrets/README.md` and apply the configuration. If a host's local age identity (`/var/lib/sops-nix/key.txt` or `~/.config/nix-config/age/key.txt`) was exposed, remove `secrets/bootstrap/<host>/`, generate a new bootstrap identity with `./scripts/prepare-age-identity`, update `.sops.yaml`, run `sops updatekeys -y` and `sops rotate -i` on every file that host can read, recover the new identity on the host with `./scripts/recover-age-identity`, and rotate the underlying secret values at their providers because the old ciphertext remains in Git history.

## Restore an iPhone or iPad from an IPSW file

NixOS hosts ship `idevicerestore`, `irecovery`, and `libimobiledevice` and run `usbmuxd` (`modules/nixos/hardware/iphone-restore.nix`). A udev rule grants the logged-in seat user access to Apple devices in DFU and recovery mode without `sudo`. Put the device in DFU mode, connect it over USB, and confirm detection:

```sh
irecovery -q
```

Restore from a local IPSW file:

```sh
idevicerestore -e <file>.ipsw
```

`-e` erases the device; omit `-e` for an update that preserves user data. Do not pass `-l` when you intend to use a local file (`-l` downloads the latest signed firmware instead). `--ipsw-info <file>.ipsw` inspects the archive without touching the device. Apple's signing server must still sign the build during the restore, so the host needs network access. When the device reboots into recovery/restore mode, `idevicerestore` talks to it through `usbmuxd`; check `systemctl status usbmuxd` if the restore stalls there.
