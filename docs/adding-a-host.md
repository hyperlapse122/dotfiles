# Adding a host

A host is a directory under `hosts/`. `flake.nix` reads that directory and builds two outputs for each entry: `<host>` for production and `<host>-bootstrap` for the first installation. Adding a machine does not touch `flake.nix`, `modules/`, `home/`, or `tests/`. It needs a host directory, bootstrap age material, a host SSH key source, and the new recipient in `.sops.yaml`.

Replace `<host>` in every command below with the new directory name.

The sections up to [Install](#install) describe a NixOS host. A machine that keeps another Linux distribution follows [Non-NixOS hosts](#non-nixos-hosts) instead, and a Mac follows [macOS hosts](#macos-hosts).

## Choose the name

The directory name is the host name. `mkHost` in `flake.nix` sets `networking.hostName` from it, so the host files never declare it.

Use the machine's distinctive model identifier, such as the DMI product name or the full model designation. The name must not appear as a substring anywhere in `flake.nix`, `modules/`, `home/`, `tests/`, `scripts/`, `packages/`, or `.github/workflows/`. The `host-name-guard` check scans those paths for every host directory name and fails on any hit. A generic word such as `desktop` or `laptop` would collide with ordinary code and comments, which is why the rule asks for a model identifier. Shared code refers to machines by trait, never by name.

## Create the host directory

Create `hosts/<host>/` with three files.

- `hardware.nix`: kernel modules, firmware, CPU microcode, and graphics drivers. The production boot splash needs the GPU's KMS driver in the initrd: add it (for example `i915`, or `vmwgfx` in a VMware guest) to `boot.initrd.kernelModules` under `lib.mkIf (!config.my.bootstrap)`; the `boot-splash` check fails otherwise. Start from `nixos-generate-config --no-filesystems --show-hardware-config` run on the target from the installation media, then keep only what the machine needs.
- `disko.nix`: the disk layout. Copy an existing host's `disko.nix` to keep the shared layout (a 2 GiB ESP, then a `root` partition holding Btrfs subvolumes for `/`, `/home`, `/nix`, `/var/log`, and `/swap`, unencrypted; protect the disk outside NixOS), and change only `device` to the target disk's `/dev/disk/by-id/` path.
- `default.nix`: imports the other two files and declares the host's traits.

```nix
{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  my.t3.desktop.enable = true;
}
```

Do not import `modules/nixos/profile.nix`. `mkHost` imports it for every host, and the profile imports every NixOS module under `modules/nixos/`. It also sets the shared defaults with `lib.mkDefault`: Podman, CLI authentication, the Tokscale token and the Pi API keys (Synthetic and Exa), Tailscale, and Proton VPN, the last three off on the bootstrap output. A host can override any of them.

### Traits

A trait is a `my.*.enable` option that defaults to `false`. Hardware-specific modules are imported on every host and stay inert until the host enables their trait. Set only the traits the machine's hardware calls for:

| Trait | Enables |
| --- | --- |
| `my.gpgAgentRelay.enable` | Serves gpg from a remote gpg-agent through a socket-activated TCP relay to `my.gpgAgentRelay.endpoint` (`host:port`), in place of a local agent and card reader. |
| `my.sshServer.enable` | An OpenSSH server that accepts only the user, authenticated by the OpenPGP card's authentication subkey. NixOS hosts only. |
| `my.t3.cli.enable` | The headless T3 Code server, `t3` (`packages/t3code-cli.nix`). It also works on a non-NixOS host. |
| `my.t3.desktop.enable` | The T3 Code desktop app (`packages/t3code.nix`). NixOS and macOS hosts only. |
| `my.wifiman.enable` | UniFi WiFiman Desktop (`packages/wifiman-desktop.nix`) and its root daemon (`modules/nixos/services/wifiman.nix`). On by default on every NixOS output, bootstrap included; set it to `false` to drop both. NixOS hosts only; a macOS host gets the `wifiman` cask regardless. |

Other per-host options keep their own meaning. `my.tailscale.advertiseRoutes` makes the host the tailnet's subnet router, which only one host should be, and `my.cliAuth.enableDockerToken` decrypts the Docker Hub token (see `secrets/README.md`). Keep anything that is not a trait, such as an extra mount, in the host's `default.nix`.

A check that covers a trait runs its positive branch on every production configuration that enables it, or, when none does, on each production configuration re-evaluated with the trait forced on, so removing the last host that enables a trait keeps the trait covered.

## Create bootstrap age material

Each host has its own age identity, encrypted to the OpenPGP card. Run the preparation helper from the development shell on an existing machine with a card inserted:

```sh
nix develop
./scripts/prepare-age-identity \
  --host <host> \
  --recipient 621512777E6933FEB4458FDC4945855D4F283F05
```

It generates the identity in a private runtime directory, verifies GPG round-trip decryption, writes `secrets/bootstrap/<host>/age-key.asc` and `secrets/bootstrap/<host>/recipient.txt`, removes the plaintext, and refuses to overwrite an existing host directory. Do not write either file by hand.

## Add the recipient to `.sops.yaml` and re-encrypt

`.sops.yaml` has one creation rule per encrypted file, and each rule lists the age recipients that may decrypt it. Append the value from `secrets/bootstrap/<host>/recipient.txt` to the `age:` list of every rule the new host needs, comma-separated. A production host needs `secrets/tokens.yaml`, `secrets/wifi.yaml`, and `secrets/tailscale.yaml`.

Adding a recipient does not change existing ciphertext. Re-encrypt each file to the new recipient list from the repository root, on any machine with the checkout and a YubiKey. The key command below decrypts every host's bootstrap identity with GPG; one card opens them all, so together they reach every file in `.sops.yaml` whichever host runs it, and no sudo is needed. The card may prompt for its PIN. The development shell provides `sops`:

```sh
nix develop
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
sops updatekeys -y secrets/tokens.yaml
sops updatekeys -y secrets/wifi.yaml
sops updatekeys -y secrets/tailscale.yaml
unset SOPS_AGE_KEY_CMD
```

## Create the desktop SSH key source

Each NixOS desktop needs a unique Ed25519 SSH authentication key. Add an exact creation rule for its recovery source to `.sops.yaml`, using only the recipient recorded for this host:

```yaml
  - path_regex: ^secrets/hosts/<host>/ssh\.yaml$
    age: <the value from secrets/bootstrap/<host>/recipient.txt>
```

Generate the passphrase-free recovery key in a private runtime directory and encrypt it before copying anything secret into the checkout. Run this in a subshell from the development shell, with shell tracing disabled. It refuses to overwrite an existing source or public key in the output directory and removes temporary plaintext on exit. Output defaults to `secrets/hosts/<host>`; `DESKTOP_SSH_OUTPUT` can select a separate directory for rotation. The SOPS rule always uses the canonical host path. Replace `<host>` before running it:

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
  desktop_ssh_tmp=$(mktemp -d /run/user/"$(id -u)"/desktop-ssh-source.XXXXXX)
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

The recipient output must contain exactly this host's recipient. `ssh.pub` is public metadata for the encrypted source; keep the two files together. Never evaluate or build with temporary plaintext in the checkout. The `desktop-ssh` check verifies encrypted fields, host-only recipients, valid public metadata, and distinct desktop public identities. Source/public correspondence is checked when the real source is provisioned on the target; builds do not decrypt it.

After installation, `desktop-ssh-provision.service` creates the passphrase-protected working key through KWallet (see [desktop SSH recovery](recovery.md#restore-or-rotate-a-desktop-ssh-key)). Register `ssh.pub` on the required destinations; creating the repository files does not register the key.

## Stage the new files

A flake sees only files that Git tracks. Until the new files are staged, `flake.nix` does not see `hosts/<host>`, and the checks do not see its bootstrap material:

```sh
git add hosts/<host> secrets/bootstrap/<host> secrets/hosts/<host> .sops.yaml
```

The re-encrypted `secrets/*.yaml` files are already tracked, so the flake sees their new contents without staging. Stage them with the rest before committing.

Confirm that the flake now lists both outputs for the new host, `<host>` and `<host>-bootstrap`:

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

Build every other output too before shipping, using the host-build loops in `../AGENTS.md`. CI builds every output `nixosConfigurations` lists, so the new host joins its build matrix without a workflow change.

These checks fail when a step above was missed:

- `bootstrap-recipients` (`tests/bootstrap-recipients.nix`) pairs `hosts/` with `secrets/bootstrap/`. It names the side that is missing when a host has no bootstrap material or bootstrap material has no host. It also fails when the recorded recipient does not appear in `.sops.yaml`. Run it alone with `nix build --no-link .#checks.x86_64-linux.bootstrap-recipients`.
- `boot-layout-invariants` (`tests/boot-layout-invariants.nix`) checks the new host's `disko.nix` for the ESP, btrfs, and swapfile layout, with no LUKS container, that `boot.nix` relies on. The `boot-layout` VM test boots only the first host's layout, so this check is what covers the new one.
- `host-name-guard` fails when the new name appears in one of the paths listed under [Choose the name](#choose-the-name). Rename the directory, or replace the reference in shared code with a trait.
- `desktop-ssh` (`tests/desktop-ssh.nix`) fails when a NixOS host lacks its encrypted SSH source or matching public metadata, lists another recipient, or duplicates another desktop's public identity, and checks the materialized production services, launchers, and configuration, and their absence from bootstrap and non-NixOS outputs.

## Install

Follow [fresh installation](install.md) with the new host's name. Add a subsection under its per-host notes for anything specific to the machine, such as a secondary disk or firmware quirk, and record machine-specific hardware checks separately from build results.

## Non-NixOS hosts

A non-NixOS host is a Linux machine that keeps its own distribution, on x86_64-linux or aarch64-linux. It gets the same shell, development tools, coding-agent configuration, Git signing, and CLI authentication as a NixOS host. It gets no desktop configuration. The distribution keeps everything the flake does not declare, including its user database and any vendor stack such as a JetPack NVIDIA driver.

The flake builds four outputs for each non-NixOS host:

- `homeConfigurations.<host>` and `homeConfigurations.<host>-bootstrap`: the user environment, applied by standalone Home Manager.
- `systemConfigs.<host>` and `systemConfigs.<host>-bootstrap`: the system layer, applied by system-manager. It runs pcscd with the ccid reader drivers, takes over `/etc/nix/nix.conf` (keeping the installer's copy as `nix.conf.system-manager-backup`), and writes `/etc/nix-config-host`. It never writes `/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/subuid`, `/etc/subgid`, or `/etc/shells`.

The bootstrap outputs hold no secrets. The production user environment also publishes the CLI tokens and the host's own SSH key.

### Name the non-NixOS host

The name rule is the same as for a NixOS host; see [Choose the name](#choose-the-name). `host-name-guard` also scans `lib/`, and it treats the fixture hosts under `tests/fixtures/hosts/` as taken names.

### Create `host.nix` and `default.nix`

Create `hosts/<host>/` with two files. `host.nix` marks the directory as a non-NixOS host and names its architecture. The flake reads it with a plain `import`, so it must be a bare attribute set:

```nix
{
  kind = "linux";
  system = "x86_64-linux"; # or "aarch64-linux"
}
```

`default.nix` sets the shared host options from `modules/shared/host.nix`. The account defaults to `h82` at `/home/h82`; set both when the machine uses another account:

```nix
{
  my.user.name = "<account>";
  my.user.home = "/home/<account>";
}
```

Only the options in `modules/shared/host.nix` exist here. NixOS options such as `my.cliAuth.enableDockerToken` fail evaluation. The traits (`my.*.enable`) are accepted. Only `my.t3.cli.enable` changes a non-NixOS host: it installs the headless `t3` server, so enable it only on a headless machine such as a server. `my.t3.desktop.enable` fails evaluation on a non-NixOS host, and every other trait reads NixOS system or desktop configuration and changes nothing.

### Create the non-NixOS bootstrap age material

Run the same helper as for a NixOS host, on a machine with a card inserted:

```sh
nix develop
./scripts/prepare-age-identity \
  --host <host> \
  --recipient 621512777E6933FEB4458FDC4945855D4F283F05
```

It writes `secrets/bootstrap/<host>/age-key.asc` and `secrets/bootstrap/<host>/recipient.txt`. The machine later recovers this identity into `~/.config/nix-config/age/key.txt`.

### Add the recipient to the `tokens.yaml` rule only

Append the value from `secrets/bootstrap/<host>/recipient.txt` to the `age:` list of the `secrets/tokens.yaml` rule in `.sops.yaml`. Do not add it to the `secrets/wifi.yaml` or `secrets/tailscale.yaml` rules. A non-NixOS host uses neither file, and its identity rests on the distribution's disk encryption.

Re-encrypt `tokens.yaml` from the repository root, on any machine with the checkout and a YubiKey, with the same GPG key command as [the NixOS re-encryption](#add-the-recipient-to-sopsyaml-and-re-encrypt):

```sh
nix develop
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
sops updatekeys -y secrets/tokens.yaml
unset SOPS_AGE_KEY_CMD
```

A non-NixOS production apply decrypts `github_token`, `gitlab_token`, `jpi_token`, `tokscale_token`, `synthetic_api_key`, `exa_api_key`, and `openrouter_api_key`. All seven must be present in `tokens.yaml`, or the apply stops. `docker_token` is never published on a non-NixOS host, so `docker.io` pulls stay anonymous.

### Create the host SSH key file

Each non-NixOS host has its own SSH key, stored in `secrets/hosts/<host>/ssh.yaml` and encrypted to that host's recipient alone. First add a rule for the file to `.sops.yaml`, listing only this host's recipient:

```yaml
  - path_regex: secrets/hosts/<host>/ssh\.yaml$
    age: <the value from secrets/bootstrap/<host>/recipient.txt>
```

Then generate the key in a private temporary directory, wrap it in the file's schema, and encrypt it. The schema is one key, `ssh_private_key`, whose value is the OpenSSH private key as a YAML block scalar. Do not pass the key as a command argument or print it:

```sh
nix develop
umask 077
secret_tmp=$(mktemp -d /run/user/"$(id -u)"/nix-secrets.XXXXXX)
ssh-keygen -q -t ed25519 -N '' -C '<host> nix-config' -f "$secret_tmp/id_ed25519"
{ printf 'ssh_private_key: |\n'; sed 's/^/  /' "$secret_tmp/id_ed25519"; } > "$secret_tmp/ssh.yaml"
mkdir -p secrets/hosts/<host>
sops --encrypt --filename-override secrets/hosts/<host>/ssh.yaml \
  --input-type yaml --output-type yaml \
  "$secret_tmp/ssh.yaml" > secrets/hosts/<host>/ssh.yaml
grep 'recipient:' secrets/hosts/<host>/ssh.yaml
rm -rf "$secret_tmp"
```

`--filename-override` makes `sops` pick the new rule, not a rule matching the temporary path. The `grep` line must print exactly one recipient, the host's own.

### Stage and check the non-NixOS host

Stage the new files, so the flake sees them:

```sh
git add hosts/<host> secrets/bootstrap/<host> secrets/hosts/<host> .sops.yaml secrets/tokens.yaml
```

Confirm that the flake lists `<host>` and `<host>-bootstrap` in both output sets, then run the checks and build the host's outputs:

```sh
nix eval .#homeConfigurations --apply builtins.attrNames
nix eval .#systemConfigs --apply builtins.attrNames
nix fmt -- --ci
nix flake check
nix build --no-link .#homeConfigurations.<host>.activationPackage
nix build --no-link .#homeConfigurations.<host>-bootstrap.activationPackage
nix build --no-link .#systemConfigs.<host>
nix build --no-link .#systemConfigs.<host>-bootstrap
```

An aarch64 host builds only on an aarch64 machine. CI builds every `homeConfigurations` and `systemConfigs` output on a runner of its own architecture, so an aarch64 host joins the arm build jobs without a workflow change.

Three checks fail when a step above was missed:

- `bootstrap-recipients` fails when the host has no bootstrap material, or when its recipient is missing from `.sops.yaml`.
- `linux-host-secrets` fails when `secrets/hosts/<host>/ssh.yaml` is missing or lists any recipient other than the host's own, when the recipient is missing from the `tokens.yaml` rule, or when it appears in the `wifi.yaml` or `tailscale.yaml` rule.
- `host-name-guard` fails when the new name appears in scanned code.

Commit and push, so the machine can clone the result.

### First setup on the machine

The steps below run on the target machine, in order. The Ubuntu and Debian commands are examples; system-manager supports those two distributions.

1. Install Nix as a multi-user installation. The system layer cannot install Nix, so this step stays manual:

   ```sh
   sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
   ```

   Open a new shell afterwards, so `nix` and `~/.nix-profile/bin` are on `PATH`.

2. Meet the distribution prerequisites. The apply helper checks each one before it applies anything and stops with the fix below when one is missing:

   - The account has subordinate uid and gid ranges. Ubuntu's `useradd` usually assigns them. Otherwise run `sudo usermod --add-subuids 100000-165535 <account>` and `sudo usermod --add-subgids 100000-165535 <account>`.
   - `newuidmap` and `newgidmap` are setuid: `sudo apt install uidmap`.
   - The account has a private group of the same name, which the flake's pcscd socket is restricted to. Ubuntu's `useradd` creates one. Otherwise run `sudo groupadd <account>` and `sudo usermod -aG <account> <account>`.
   - The distribution's pcscd is not installed, because it would conflict with the flake's: `sudo apt remove pcscd`.
   - `/etc/shells` lists the managed zsh: `echo $HOME/.nix-profile/bin/zsh | sudo tee -a /etc/shells`.

3. Decide how rootless Podman gets user namespaces. The flake does not install Podman on a non-NixOS host. It configures the registry search, `auth.json`, and the credential helper for the Podman you install. Ubuntu 24.04's AppArmor restricts unprivileged user namespaces for any binary without a profile that allows them, such as a `podman` installed with Nix. This is a distribution setting, and the choice is yours. One option lifts the restriction for the whole machine:

   ```sh
   echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/60-userns.conf
   sudo sysctl --system
   ```

   The narrower option is an AppArmor profile that grants `userns` to that `podman` binary only. Skip this step if you do not run containers.

4. Move aside any file that Home Manager will manage. Home Manager stops rather than overwrite a file it did not create. `~/.ssh/config` is the exception: activation installs it as a user-owned copy and moves a config you wrote to `~/.ssh/config.unmanaged` first.

5. Clone the repository and enable flakes for the first apply. The system layer enables them in `/etc/nix/nix.conf` from then on:

   ```sh
   git clone https://github.com/hyperlapse122/nix-config.git
   cd nix-config
   export NIX_CONFIG='experimental-features = nix-command flakes'
   ```

6. Apply the bootstrap output. `nr` is not installed yet, so run the helper from the clone:

   ```sh
   ./scripts/nr-linux switch --host <host> --bootstrap --flake-dir .
   ```

   It builds both layers as you, activates the system layer through `sudo`, then activates the user environment. This brings up GPG, the card tools, pcscd, and `install-user-age-identity`. The system layer records the host in `/etc/nix-config-host`, so later runs need no `--host`.

7. With a YubiKey inserted, recover the host's age identity:

   ```sh
   ./scripts/recover-age-identity --user --host <host>
   ```

   It verifies the derived public recipient before atomically installing `~/.config/nix-config/age/key.txt` (mode `0600` in a `0700` directory; see `../secrets/README.md`).

8. Apply the production output. It publishes the gh and glab configuration, the tokens, and the SSH key:

   ```sh
   nr switch
   ```

9. Register the host's SSH public key (`ssh-keygen -y -f ~/.ssh/id_ed25519_nix_config`) as an authentication key on GitHub and in `~/.ssh/authorized_keys` on every server the host must reach.

10. Switch the login shell to the managed zsh. `nr` prints this reminder after each apply until you do:

    ```sh
    chsh -s $HOME/.nix-profile/bin/zsh
    ```

Later applies run `nr switch` from the clone after `git pull`. They need no card. `nr switch --bootstrap` applies the bootstrap output again; it leaves the published secrets in place. `nr build` builds both layers without activating them. `nr boot` and `nr test` refuse, because a non-NixOS host has no boot generation.

## macOS hosts

A macOS host is an Apple silicon Mac (`aarch64-darwin`). It gets the same shell, development tools, coding-agent configuration, Git signing, and CLI authentication as a non-NixOS Linux host, and the GUI apps, fonts, and Ghostty settings of a NixOS host. Intel Macs are not supported: `lib/darwin-host.nix` stops evaluation with a message naming the host when `host.nix` sets any other system.

The flake builds two outputs for each macOS host, `darwinConfigurations.<host>` and `darwinConfigurations.<host>-bootstrap`. Each is a nix-darwin system with Home Manager inside it, so one activation applies both layers. The bootstrap output holds no secrets.

Every macOS host imports `modules/darwin/profile.nix`, which sets up the system layer:

- nix-darwin owns `/etc/nix/nix.conf` and writes the shared Nix settings into it, with `auto-optimise-store` forced off, because store optimisation corrupts the store on macOS (NixOS/nix#7273).
- `/etc/nix-config-host` records the host and the variant, as on a non-NixOS Linux host.
- nix-homebrew installs Homebrew on the first apply. A Homebrew already at `/opt/homebrew` is migrated in place (`autoMigrate`), keeping the formulae and casks it holds. nix-darwin's Homebrew module then installs the casks that `modules/shared/darwin-apps.nix` lists. Its cleanup mode is `"none"`, so an app you installed by hand stays installed. Each apply refreshes Homebrew's cask metadata, then installs missing casks and upgrades outdated ones. Homebrew itself stays at the version nix-homebrew pins.
- The NixOS font list, `modules/shared/font-packages.nix`, is installed system-wide.
- `modules/darwin/defaults.nix` is where macOS system defaults go: Dock, Finder, trackpad, appearance, and keyboard. It sets none yet.

`modules/shared/darwin-apps.nix` gives every NixOS-only package of the user environment a macOS decision: a Homebrew cask, a Nix package, or left out with a reason. The `darwin-config` check fails when a NixOS-only package has no decision, so an app added on NixOS needs an entry here. A cask the configuration retires leaves this file and joins the list in `modules/darwin/retired-casks.nix`, which uninstalls it on the next apply, because Homebrew cleanup is `"none"`. VSCodium and the T3 Code desktop app come from Nix rather than Homebrew; the T3 Code app is the flake's pinned nightly.

### Name the macOS host

The name rule is the same as for a NixOS host; see [Choose the name](#choose-the-name). The name macOS shows for the machine does not matter: `nr` reads the host from `/etc/nix-config-host`.

### Create the macOS `host.nix` and `default.nix`

Create `hosts/<host>/` with two files. `host.nix` marks the directory as a macOS host:

```nix
{
  kind = "darwin";
  system = "aarch64-darwin";
}
```

`default.nix` sets the account and the traits. A macOS home directory is under `/Users`:

```nix
{
  my.user.name = "<account>";
  my.user.home = "/Users/<account>";
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
}
```

As on a non-NixOS Linux host, only the options in `modules/shared/host.nix` exist, and NixOS options such as `my.cliAuth.enableDockerToken` fail evaluation. Only `my.t3.cli.enable` and `my.t3.desktop.enable` change a macOS host; the hardware traits change nothing there.

### Create the macOS host's secrets

A macOS host's secrets work as a non-NixOS Linux host's do. Run these three steps on a machine that already has the checkout and a card:

1. [Create the bootstrap age material](#create-the-non-nixos-bootstrap-age-material). `bootstrap-recipients` fails when `secrets/bootstrap/<host>/` is missing.
2. [Add the recipient to the `tokens.yaml` rule only](#add-the-recipient-to-the-tokensyaml-rule-only), and re-encrypt `tokens.yaml`. On a Mac, FileVault protects the identity in place of the distribution's disk encryption.
3. [Create the host SSH key file](#create-the-host-ssh-key-file). The production output does not evaluate without `secrets/hosts/<host>/ssh.yaml`.

### Stage and check the macOS host

Stage the new files, so the flake sees them, and confirm that the flake lists `<host>` and `<host>-bootstrap`:

```sh
git add hosts/<host> secrets/bootstrap/<host> secrets/hosts/<host> .sops.yaml secrets/tokens.yaml
nix eval .#darwinConfigurations --apply builtins.attrNames
nix fmt -- --ci
nix flake check
```

A macOS output builds only on a macOS builder. On a Mac, build both:

```sh
nix build --no-link .#darwinConfigurations.<host>.system
nix build --no-link .#darwinConfigurations.<host>-bootstrap.system
```

CI's `build-darwin` job builds every `darwinConfigurations` output on a `macos-15` runner, so a new macOS host joins it without a workflow change.

Three checks fail when a step above was missed:

- `bootstrap-recipients` fails when the host has no bootstrap material, or when its recipient is missing from `.sops.yaml`.
- `linux-host-secrets` covers every host with a `host.nix`, macOS hosts included. It fails when `secrets/hosts/<host>/ssh.yaml` is missing or lists another recipient, when the recipient is missing from the `tokens.yaml` rule, or when it appears in the `wifi.yaml` or `tailscale.yaml` rule.
- `host-name-guard` fails when the new name appears in scanned code.

Commit and push, so the Mac can clone the result.

### First setup on the Mac

[macOS hosts](macos.md#first-setup-on-the-mac) gives the steps to run on the Mac itself, from FileVault and the bootstrap apply through key recovery and the first production apply, and covers everyday use afterwards.
