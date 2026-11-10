# Adding a host

A host is a directory under `hosts/`. `flake.nix` reads `hosts/` through `lib/hosts.nix` and builds two outputs for each entry: `<host>` for production and `<host>-bootstrap` for initial installation (`nixosConfigurations` for NixOS hosts and `darwinConfigurations` for macOS hosts). Today the repository declares `MS-7D91` (NixOS) and `MacBook-Pro-Mac17-9` (macOS). Adding a machine does not require editing `flake.nix`, `modules/`, `home/`, or `tests/`; it needs a host directory, bootstrap age material, per-host encrypted secrets, and `.sops.yaml` recipient updates.

Replace `<host>` in every command below with the new directory name.

The sections up to [Install](#install) cover a NixOS host. A Mac follows [macOS hosts](#macos-hosts).

## Choose the name

The directory name is the host name. On NixOS, `mkHost` in `lib/nixos-host.nix` sets `networking.hostName` from it, so the host files never set `networking.hostName` themselves.

Use the machine's distinctive model identifier, such as the DMI product name (`MS-7D91`) or the full model designation (`MacBook-Pro-Mac17-9`). The name must not appear as a substring anywhere in `flake.nix`, `lib/`, `modules/`, `home/`, `tests/`, `scripts/`, `packages/`, or `.github/workflows/`. The `host-name-guard` check (`tests/host-name-guard.nix`) scans those paths for every host directory name and fails on any hit. A generic word such as `desktop` or `laptop` would collide with ordinary code and comments, which is why the rule requires a model identifier. Shared code refers to machines by trait, `my.kind`, or `my.bootstrap`, never by host name.

## Create the NixOS host directory

A directory under `hosts/` without a `host.nix` file (or with `kind = "nixos"`) is a NixOS host. Create `hosts/<host>/` with three files:

- `hardware.nix`: kernel modules, firmware, CPU microcode, and graphics drivers. The production Plymouth boot splash requires the GPU's KMS driver in the initrd: add it (for example `i915`, `amdgpu`, or `nvidia` / `nvidia_modeset` / `nvidia_drm`) to `boot.initrd.kernelModules` under `lib.mkIf (!config.my.bootstrap)`; the `boot-splash` check (`tests/boot-splash.nix`) fails otherwise. Start from `nixos-generate-config --no-filesystems --show-hardware-config` run on the target from the installation media, then keep only what the machine needs.
- `disko.nix`: the disk layout. Copy `hosts/MS-7D91/disko.nix` to keep the shared layout (a 2 GiB ESP with partlabel `disk-main-ESP`, then a LUKS2 `cryptroot` container with partlabel `disk-main-luks` holding Btrfs subvolumes for `/root` (`/`), `/home`, `/nix`, `/log` (`/var/log`), and `/swap` with a 64 GiB swapfile), and change only `device` to the target disk's `/dev/disk/by-id/` path.
- `default.nix`: imports `./hardware.nix` and `./disko.nix` and declares the host's traits and any machine-specific mounts or options.

```nix
{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
}
```

Do not import `modules/nixos/profile.nix` in `default.nix`. `mkHost` imports it automatically for every NixOS host, and the profile imports every NixOS module under `modules/nixos/`. It also sets the shared defaults with `lib.mkDefault`: rootless Podman, `my.cliAuth` (plus `enableTokscaleToken`, `enableSyntheticApiKey`, `enableExaApiKey`, and `enableOpenRouterApiKey` on production outputs), Tailscale, and Proton VPN (off on bootstrap outputs). A host can override any of them.

### Traits and per-host options

Traits and shared host options live in `modules/shared/host.nix`:

| Option | Effect |
| --- | --- |
| `my.intune.enable` | Installs the Microsoft Intune app, the identity broker, and Microsoft Edge, shows the Intune executables an Ubuntu OS identity, and enforces a password quality policy (`modules/nixos/services/intune.nix`, NixOS; see [Microsoft Intune on NixOS](intune.md)). |
| `my.nuphyGem80.enable` | Installs the hidraw udev rule granting the local seat access to the NuPhy Gem80 keyboard (NixOS). |
| `my.sennheiserBtd.enable` | Installs the hidraw udev rule granting the local seat access to the Sennheiser BTD 600 dongle (NixOS). |
| `my.sshServer.enable` | Enables an OpenSSH server accepting only `my.user.name`, authenticated by the OpenPGP card's authentication subkey from `keys/signing.asc` (NixOS). |
| `my.t3.cli.enable` | Installs the headless T3 Code server, `t3` (`packages/t3code-cli.nix`), on NixOS or macOS. |
| `my.t3.desktop.enable` | Installs the T3 Code desktop app (`packages/t3code.nix`) on NixOS or macOS. |
| `my.wifiman.enable` | Installs UniFi WiFiman Desktop (`packages/wifiman-desktop.nix`) and its root daemon (`modules/nixos/services/wifiman.nix`) on NixOS (on by default; macOS always installs the `wifiman` cask). |
| `my.printing.queues` | List of CUPS queue labels decrypted from `secrets/printers.yaml` (NixOS, empty by default). |
| `my.tlsInspectionCa.enable` | Decrypts `secrets/hosts/<host>/tls-inspection-ca.yaml` into `/etc/ssl/nix-config/` and configures system and tool CA trust (macOS). |
| `my.networkRecovery.enable` | Runs the `org.nixos.network-recovery` launch daemon and sets `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=60000` (macOS). |
| `my.dock.hostApps` | List of `.app` paths inserted into the macOS Dock between ChatGPT and Discord (`modules/darwin/dock.nix`). |

Other NixOS options keep their own meaning: `my.tailscale.advertiseRoutes` makes the host the tailnet's subnet router, and `my.cliAuth.enableDockerToken` decrypts `docker_token` from `secrets/tokens.yaml` (see `../secrets/README.md`).

## Create bootstrap age material

Each host has its own age identity, encrypted to the OpenPGP card (`keys/signing.asc`). Run the preparation helper from the development shell on an existing machine with a YubiKey inserted:

```sh
nix develop
./scripts/prepare-age-identity \
  --host <host> \
  --recipient 621512777E6933FEB4458FDC4945855D4F283F05
```

It generates the age identity in a private runtime directory (`$PREPARE_AGE_RUNTIME_DIR` or `/run/user/$(id -u)`), verifies a GPG round-trip decryption with the card, writes `secrets/bootstrap/<host>/age-key.asc` and `secrets/bootstrap/<host>/recipient.txt`, removes all temporary plaintext, and refuses to overwrite an existing directory. Do not write either file by hand.

## Add the recipient to `.sops.yaml` and re-encrypt

`.sops.yaml` has one creation rule per encrypted file, listing the comma-separated age recipients that may decrypt it:

- Every host (`nixos` or `darwin`) is added to the `secrets/tokens\.yaml$` rule.
- Only NixOS hosts are added to `secrets/wifi\.yaml$` and `secrets/tailscale\.yaml$` (and to `secrets/printers\.yaml$` when the NixOS host declares `my.printing.queues`). Adding a `darwin` host recipient to `wifi.yaml` or `tailscale.yaml` fails `user-identity-secrets`.

After updating `.sops.yaml`, re-encrypt each affected shared file from the repository root with a YubiKey connected:

```sh
nix develop
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
sops updatekeys -y secrets/tokens.yaml
sops updatekeys -y secrets/wifi.yaml
sops updatekeys -y secrets/tailscale.yaml
unset SOPS_AGE_KEY_CMD
```

If the new NixOS host also declares `my.printing.queues`, add its recipient to `secrets/printers\.yaml$` and run `sops updatekeys -y secrets/printers.yaml` as well.

## Create the desktop SSH key source

Every host has a unique Ed25519 SSH authentication key under `secrets/hosts/<host>/{ssh.yaml,ssh.pub}`. Add a creation rule for `secrets/hosts/<host>/ssh.yaml` to `.sops.yaml`, listing only `<host>`'s recipient:

```yaml
  - path_regex: ^secrets/hosts/<host>/ssh\.yaml$
    age: <the value from secrets/bootstrap/<host>/recipient.txt>
```

Generate the key pair in a private runtime directory and encrypt `ssh.yaml` before copying anything into the checkout. Run this in a subshell from `nix develop` with shell tracing disabled (`replace <host>` first; on macOS, use `mktemp -d "${TMPDIR:-/tmp}/desktop-ssh-source.XXXXXX"` if `/run/user/$(id -u)` does not exist):

```sh
nix develop
(
  set -eu
  umask 077
  desktop_ssh_output=${DESKTOP_SSH_OUTPUT:-secrets/hosts/<host>}
  test ! -e "$desktop_ssh_output/ssh.yaml"
  test ! -L "$desktop_ssh_output/ssh.yaml"
  test ! -e "$desktop_ssh_output/ssh.pub"
  test ! -L "$desktop_ssh_output/ssh.pub"
  desktop_ssh_tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/desktop-ssh-source.XXXXXX")
  trap 'rm -rf -- "$desktop_ssh_tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  ssh-keygen -q -t ed25519 -N '' -C '<host> nix-config' -f "$desktop_ssh_tmp/id_ed25519"
  { printf 'ssh_private_key: |\n'; sed 's/^/  /' "$desktop_ssh_tmp/id_ed25519"; } > "$desktop_ssh_tmp/ssh.yaml"
  sops --encrypt --filename-override secrets/hosts/<host>/ssh.yaml \
    --input-type yaml --output-type yaml \
    "$desktop_ssh_tmp/ssh.yaml" > "$desktop_ssh_tmp/encrypted.yaml"
  mkdir -p "$desktop_ssh_output"
  cp "$desktop_ssh_tmp/encrypted.yaml" "$desktop_ssh_output/ssh.yaml"
  cp "$desktop_ssh_tmp/id_ed25519.pub" "$desktop_ssh_output/ssh.pub"
  ssh-keygen -lf "$desktop_ssh_output/ssh.pub"
  grep 'recipient:' "$desktop_ssh_output/ssh.yaml"
)
```

Verify that `grep 'recipient:'` prints only `<host>`'s recipient. On NixOS desktops, `desktop-ssh-provision.service` protects the working copy at `~/.ssh/id_ed25519_nix_config` with a random KWallet passphrase (see [desktop SSH recovery](recovery.md#restore-or-rotate-a-desktop-ssh-key)). On macOS, `host-secrets` installs the key at `~/.ssh/id_ed25519_nix_config` (`0600`), protected by FileVault. Register `secrets/hosts/<host>/ssh.pub` on GitHub and any server the host must reach.

## Stage the new files

A Nix flake sees only paths tracked by Git. Stage the new host and secret files before evaluating or checking the flake:

```sh
git add hosts/<host> secrets/bootstrap/<host> secrets/hosts/<host> .sops.yaml
```

Confirm that the flake lists both `<host>` and `<host>-bootstrap`:

```sh
nix eval .#nixosConfigurations --apply builtins.attrNames
```

## Run the checks and builds

```sh
nix fmt -- --ci
nix flake check
nix build --no-link .#vmChecks.all
nix build --no-link .#nixosConfigurations.<host>.config.system.build.toplevel
nix build --no-link .#nixosConfigurations.<host>-bootstrap.config.system.build.toplevel
```

These checks guard host onboarding:

- `bootstrap-recipients` (`tests/bootstrap-recipients.nix`) pairs `hosts/` with `secrets/bootstrap/` and verifies that every recorded recipient appears in `.sops.yaml`.
- `sops-recipients` (`tests/sops-recipients.nix`) verifies that every encrypted YAML file's recipient metadata matches its `.sops.yaml` creation rule.
- `boot-layout-invariants` (`tests/boot-layout-invariants.nix`) checks each NixOS host's `disko.nix` for the ESP (`disk-main-ESP`), LUKS2 container (`cryptroot`, `disk-main-luks`), Btrfs subvolumes, and swapfile that `modules/nixos/system/boot.nix` expects.
- `boot-splash` (`tests/boot-splash.nix`) checks that production NixOS outputs include a KMS driver in `boot.initrd.kernelModules`.
- `host-name-guard` (`tests/host-name-guard.nix`) fails when any host directory name appears in shared code.
- `desktop-ssh` (`tests/desktop-ssh.nix`) verifies `secrets/hosts/<host>/{ssh.yaml,ssh.pub}` and the `desktop-ssh` services on NixOS hosts.

## Install

Follow [fresh installation](install.md) with `<host>`. Add a subsection under its per-host notes for machine-specific hardware facts and report hardware verification separately from build results.

## macOS hosts

A macOS host is an Apple silicon Mac (`aarch64-darwin`). Intel Macs are not supported: `lib/darwin-host.nix` fails evaluation when `host.nix` declares any other system.

The flake builds two outputs for each macOS host, `darwinConfigurations.<host>` and `darwinConfigurations.<host>-bootstrap`. Each is a `nix-darwin` system with Home Manager inside it. Every macOS host imports `modules/darwin/profile.nix`, which configures:

- `/etc/nix/nix.conf` with the shared Nix settings and `auto-optimise-store = false` (`modules/darwin/nix.nix`).
- `/etc/nix-config-host` recording `host=<host>` and `variant=bootstrap|production` (`modules/darwin/host-marker.nix`).
- Homebrew via `nix-homebrew`, the `aria2` and `container` formulae, and the casks from `modules/shared/darwin-apps.nix` with cleanup `"none"` (`modules/darwin/homebrew.nix`), plus retirement of `grok-bot` and `orca` (`modules/darwin/retired-casks.nix`).
- Xcode provisioning via `xcodes` on production switches (`!config.my.bootstrap`), reading `secrets/hosts/<host>/apple-account.yaml` from the applying checkout (`modules/darwin/xcode.nix`).
- KakaoTalk and Flighty via `mas` (`modules/darwin/app-store.nix`).
- Apple's `container` runtime setup (`modules/darwin/container.nix`).
- The macOS Dock (`modules/darwin/dock.nix`) and automatic appearance (`modules/darwin/defaults.nix`).
- Optional TLS inspection CA trust (`modules/darwin/tls-inspection-ca.nix`) and network recovery daemon (`modules/darwin/network-recovery.nix`).
- System-wide fonts from `modules/shared/font-packages.nix` (`modules/darwin/fonts.nix`).

### Name the macOS host

Follow [Choose the name](#choose-the-name), and include the Mac's `hw.model` identifier with the comma replaced by a hyphen (for example `Mac17-9` in `MacBook-Pro-Mac17-9`) so the lookup step in [macOS hosts](macos.md#first-setup-on-the-mac) finds it.

### Create the macOS `host.nix` and `default.nix`

Create `hosts/<host>/` with two files. `host.nix` marks the directory as a macOS host:

```nix
{
  kind = "darwin";
  system = "aarch64-darwin";
}
```

`default.nix` sets the primary user account, home directory under `/Users`, and host traits:

```nix
{ ... }:
{
  my.user.name = "<account>";
  my.user.home = "/Users/<account>";
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
}
```

### Create the macOS host's secrets

Run these steps on a machine that already has the checkout and a YubiKey:

1. **Create the bootstrap age material** under `secrets/bootstrap/<host>/{age-key.asc,recipient.txt}` using `./scripts/prepare-age-identity` as shown in [Create bootstrap age material](#create-bootstrap-age-material). (On macOS without `/run/user/$(id -u)`, set `PREPARE_AGE_RUNTIME_DIR=$(mktemp -d)` for that run and remove the directory afterward.)
2. **Add the recipient to `secrets/tokens.yaml` only.** Append the `age1...` string from `secrets/bootstrap/<host>/recipient.txt` to the `secrets/tokens\.yaml$` creation rule in `.sops.yaml` and run `sops updatekeys -y secrets/tokens.yaml`. Do not add a macOS host to `wifi.yaml`, `tailscale.yaml`, or `printers.yaml`.
3. **Create the host SSH key files** `secrets/hosts/<host>/{ssh.yaml,ssh.pub}` and the `^secrets/hosts/<host>/ssh\.yaml$` rule in `.sops.yaml` as shown in [Create the desktop SSH key source](#create-the-desktop-ssh-key-source).
4. **Create the Apple Account secret** `secrets/hosts/<host>/apple-account.yaml` for `xcodes`. Add its creation rule to `.sops.yaml` with only `<host>`'s recipient:

   ```yaml
     - path_regex: ^secrets/hosts/<host>/apple-account\.yaml$
       age: <the value from secrets/bootstrap/<host>/recipient.txt>
   ```

   Encrypt the `username` and `password` mapping from a mode `0600` file outside the checkout without writing plaintext into the repository:

   ```sh
   sops --encrypt --filename-override secrets/hosts/<host>/apple-account.yaml \
     --input-type yaml --output-type yaml <outside-apple-account-file> \
     > secrets/hosts/<host>/apple-account.yaml
   rm <outside-apple-account-file>
   ```

5. **Optional TLS inspection CA.** If the Mac enables `my.tlsInspectionCa.enable = true`, add `^secrets/hosts/<host>/tls-inspection-ca\.yaml$` to `.sops.yaml` and create `secrets/hosts/<host>/tls-inspection-ca.yaml` as shown in [macOS hosts](macos.md#tls-inspection-ca).

### Stage and check the macOS host

```sh
git add hosts/<host> secrets/bootstrap/<host> secrets/hosts/<host> .sops.yaml secrets/tokens.yaml
nix eval .#darwinConfigurations --apply builtins.attrNames
nix fmt -- --ci
nix flake check
```

On a macOS builder, also build both system closures:

```sh
nix build --no-link .#darwinConfigurations.<host>.system
nix build --no-link .#darwinConfigurations.<host>-bootstrap.system
```

These checks guard a macOS host:

- `bootstrap-recipients` (`tests/bootstrap-recipients.nix`) checks `secrets/bootstrap/<host>/` and `.sops.yaml`.
- `user-identity-secrets` (`tests/user-identity-secrets.nix`) checks that `secrets/hosts/<host>/ssh.yaml` exists and lists only `<host>`'s recipient, that `<host>`'s recipient is on `secrets/tokens.yaml`, and that it is absent from `secrets/wifi.yaml` and `secrets/tailscale.yaml`.
- `sops-recipients` (`tests/sops-recipients.nix`) checks that every encrypted file under `secrets/hosts/<host>/` (including `apple-account.yaml` and `tls-inspection-ca.yaml`) matches its `.sops.yaml` rule.
- `host-name-guard` (`tests/host-name-guard.nix`) checks that `<host>` does not appear in shared code.

### First setup on the Mac

Follow [macOS hosts](macos.md#first-setup-on-the-mac) on the Mac itself.
