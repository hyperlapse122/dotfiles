# Updates and recovery

## Routine configuration applies

```sh
sudo nixos-rebuild switch --flake .#<host>
```

Replace `<host>` with the machine's directory name under `hosts/`, here and in the commands below. This command does not format disks. Once the local age identity is ready, it does not depend on the YubiKey, desktop keyring, or 1Password login state. Rebuilds work without the card, but actual Git signing does not.

Update inputs with `nix flake update`. Review the `flake.lock` diff and pass `nix flake check`, the VM tests (`nix build --no-link .#vmChecks.all`), and the builds of every `nixosConfigurations`, `homeConfigurations`, and `systemConfigs` output (see `../AGENTS.md`) before applying. Afterward, use each CLI to check whether its remote token is valid. Successful deployment of authentication files does not guarantee that the server accepts the tokens. Periodic updates are also automated via the `Update dependencies` GitHub Actions workflow (`.github/workflows/update-dependencies.yml`), which tests and lands updates directly on `main` or opens an automated reconciliation pull request.

## Failed authentication applies

```sh
systemctl status sops-install-secrets.service --no-pager
sudo journalctl -u sops-install-secrets.service -b --no-pager
```

Check logs for secrets before sharing them. If the local identity is missing or corrupt, repeat [secret recovery](../secrets/README.md) with `./scripts/recover-age-identity` and run the same rebuild command. From the installation media or inside `nixos-enter` the hostname is the image's, not a configuration name, so the helper cannot detect the host and `--host <host>` is required there. The same command also restores manually deleted CLI configuration files. The next successful apply overwrites local changes to managed gh/glab files.

A failed NixOS switch does not transactionally roll back all system changes. If token publication updated only some files, fix the problem and run the same command again. Do not ignore the error or treat provisioning as complete.

## Roll back a boot generation

Select a supported previous NixOS generation from the boot menu. Production outputs hide the menu: hold Space at power-on until it appears. Press Esc during the boot splash to see the boot log. If the system can boot, use the following command to roll back.

```sh
sudo nixos-rebuild switch --rollback
```

The initial boot generation limit is 5.

Weekly cleanup keeps the 10 newest generations regardless of age, so every entry the menu offers still resolves even after months without a rebuild. That retention floor is what makes the menu trustworthy, not the generation limit: the menu is rewritten only by a rebuild, while collection runs on a timer. Raising `configurationLimit` above the retention count in `modules/nixos/system/nix-cleanup.nix` would break that guarantee, and the `nix-cleanup` check fails when it does.

## An authentication stack that refuses

If a rebuild leaves the lock screen or `sudo` refusing a correct password, do not start with `sudo nixos-rebuild switch --rollback`: that command needs the `sudo` that is refusing. Select a previous generation at the boot menu instead, holding Space at power-on to open it.

No root password is declared. When no previous generation boots, use the installation media and `nixos-enter`, below.

Booting an older generation escapes the stack but does not undo anything else in it.

## Repair from the installation media

If the system cannot boot, use the installation media to mount the existing filesystems with the declared layout below. Do not rerun disko's formatting mode. With network access, clone the repository again into `/tmp/nix-config` under the target root. Without network access, copy it from external media to the same path.

```sh
sudo mount -o subvol=/root,compress=zstd,noatime /dev/disk/by-partlabel/disk-main-root /mnt
sudo install -d /mnt/home /mnt/nix /mnt/var/log /mnt/boot /mnt/tmp
sudo mount -o subvol=/home,compress=zstd,noatime /dev/disk/by-partlabel/disk-main-root /mnt/home
sudo mount -o subvol=/nix,compress=zstd,noatime /dev/disk/by-partlabel/disk-main-root /mnt/nix
sudo mount -o subvol=/log,compress=zstd,noatime /dev/disk/by-partlabel/disk-main-root /mnt/var/log
sudo mount /dev/disk/by-partlabel/disk-main-ESP /mnt/boot
if sudo test -d /mnt/tmp/nix-config/.git; then
  sudo git -C /mnt/tmp/nix-config pull --ff-only
else
  sudo git clone https://github.com/hyperlapse122/nix-config.git /mnt/tmp/nix-config
fi
sudo nixos-enter --root /mnt -c \
  'cd /tmp/nix-config && nixos-rebuild boot --flake .#<host>'
```

`nixos-enter` creates the required `/dev`, `/sys`, and `/proc` bind mounts itself.

## Lost or replaced YubiKey

Three cards carry the same key, so losing one costs a card, not the key. Rebuilds are unaffected either way, and signing continues on any remaining card. Nothing in this repository changes: the fingerprint, `keys/signing.asc`, and every existing ciphertext stay as they are.

Provision the replacement from the offline backup, never from another card. YubiKey private keys cannot be extracted, so there is no card-to-card path. Restore the backup into a tmpfs `GNUPGHOME`, set the card's key attributes to ed25519 and cv25519, move the subkeys onto it, and give it its own User and Admin PINs. Because every card holds the same encryption subkey, the replacement decrypts existing ciphertext, every `secrets/bootstrap/<host>/age-key.asc` and the external media backups included. Nothing has to be re-encrypted for it.

Clear the lost card's Secret Service entry, and register the replacement under its own serial. Automatic PIN entry is per card and is never a rebuild requirement.

Losing the offline backup is the different failure. The cards still in hand are then the last cards, because no further card can ever be provisioned. Treat that as a key loss in slow motion: while a working card remains, generate a replacement key, re-encrypt the bootstrap ciphertext and the external media backups for it, update the fingerprint in this repository and the verification keys on the relevant services, and revoke the old key.

## Restore or rotate a desktop SSH key

On a production NixOS desktop, loss of the encrypted working key or its KWallet entry is recoverable from `secrets/hosts/<host>/ssh.yaml`. Keep its matching `ssh.pub` unchanged. After reinstalling, recover the age identity with `./scripts/recover-age-identity` (see `../secrets/README.md`), apply production, and log in locally through SDDM (`kdewallet` unlocks automatically when its password matches the login password). Unlock `kdewallet` if needed, then run as the configured user (`~/.ssh` mode `0700`, `~/.ssh/id_ed25519_nix_config` mode `0600`, primary socket `/run/user/<uid>/desktop-ssh/agent.sock`):

```sh
systemctl --no-ask-password start desktop-ssh-provision.service
systemctl --user status desktop-ssh-agent.service
```

The service recreates a protected key with the same public identity, so existing remote registrations continue to work. A missing wallet entry gets a new random passphrase; a valid existing pair is preserved. A failed wallet write/readback or key publication preserves the previous working pair. A stopped or failed primary agent can be restarted with `systemctl --user restart desktop-ssh-agent.service` from the active graphical session. A locked wallet requires a manual unlock before an uncached primary key can be used; selected 1Password keys remain available as fallback.

For intentional rotation, first record the old public fingerprint and every destination where it is registered. From the development shell, select a private directory for the replacement ciphertext and public metadata:

```sh
umask 077
export DESKTOP_SSH_OUTPUT=$(mktemp -d /run/user/"$(id -u)"/desktop-ssh-rotation.XXXXXX)
```

Run the complete [desktop source creation recipe](adding-a-host.md#create-the-desktop-ssh-key-source) with this variable set and `<host>` replaced. Its overwrite checks now cover the empty staging directory, and the existing repository pair stays untouched. The recipe removes its temporary plaintext before returning. Register `$DESKTOP_SSH_OUTPUT/ssh.pub` on the destinations, then deliberately replace both repository files:

```sh
cp "$DESKTOP_SSH_OUTPUT/ssh.yaml" secrets/hosts/<host>/ssh.yaml
cp "$DESKTOP_SSH_OUTPUT/ssh.pub" secrets/hosts/<host>/ssh.pub
rm -rf -- "$DESKTOP_SSH_OUTPUT"
unset DESKTOP_SSH_OUTPUT
```

Review and stage both changes, run the checks, and apply production on the target. Provision the replacement through the fixed service above and verify access with 1Password stopped before revoking the old key on every destination. The new fingerprint selects a separate wallet entry; remove the old entry only after migration succeeds.

For a lost, compromised, or retired desktop, revoke its public SSH key remotely even if the working copy was passphrase-protected. Root holding the host's age identity can decrypt the recovery source, and a compromised user session may read an unlocked wallet or use a loaded key. Per-host recipients prevent ordinary hosts from decrypting each other's sources, but the existing recovery cards can recover all host age identities. Git history retains old ciphertext: removing a recipient or deleting a source does not revoke an already exposed key. Follow [compromise or decommission of a host](#compromise-or-decommission-of-a-host) below to re-key every shared file (`sops updatekeys -y` followed by `sops rotate -i`) before writing rotated tokens.

Git signing remains on the existing OpenPGP/YubiKey identity throughout restoration and rotation. Non-NixOS hosts retain their [host SSH setup](adding-a-host.md#first-setup-on-the-machine) and the decommission procedure below.

## Compromise or decommission of a host

Follow these steps in order when a non-NixOS host, a macOS host, or a NixOS host is lost, compromised, or retired. Treat everything that host could decrypt as exposed.

1. Revoke its SSH public key on GitHub and remove it from every server's `authorized_keys`.
2. Remove the host's recipient from the `.sops.yaml` rule of every shared file that lists it (`secrets/tokens.yaml` for non-NixOS and macOS hosts; `secrets/tokens.yaml`, `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` for NixOS hosts). From the repository root with a YubiKey connected, re-encrypt each affected file to the remaining recipients and rotate its data key before writing any new secret:

   ```sh
   nix develop
   export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
   sops updatekeys -y secrets/tokens.yaml
   sops rotate -i secrets/tokens.yaml
   ```

   For a NixOS host, repeat `sops updatekeys -y` and `sops rotate -i` on `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` before clearing `SOPS_AGE_KEY_CMD`.
3. Rotate every exposed token at its provider (plus Wi-Fi PSKs, Tailscale key, and printer credentials for a NixOS host), save each new value to a mode `0600` file outside the checkout, pipe it in as JSON, and delete the temporary file:

   ```sh
   python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read().strip()))' < <token-file> \
     | sops set --value-stdin secrets/tokens.yaml '["<key>"]'
   rm <token-file>
   unset SOPS_AGE_KEY_CMD
   ```

   Keep steps 2 and 3 in this exact order: `sops set` encrypts to the recipients recorded in the file rather than `.sops.yaml`, and `sops updatekeys` alone retains the old data key from Git history until `sops rotate -i` replaces it.
4. Delete `secrets/hosts/<host>/`, `secrets/bootstrap/<host>/`, `hosts/<host>/`, and the `secrets/hosts/<host>/ssh.yaml` rule in `.sops.yaml`.

## Replace tokens or the age identity

To change tokens, edit the SOPS-encrypted token file and rebuild. If the local age identity was exposed, generate a new identity and re-encrypt all ciphertext for the new recipient. Update the bootstrap ciphertext and local identity together. Historical ciphertext remains in the repository, so revoke and reissue potentially exposed service tokens through their providers.
