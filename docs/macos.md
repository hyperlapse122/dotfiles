# macOS hosts

This guide covers an Apple silicon Mac (`aarch64-darwin`) from an erased machine through everyday use. A macOS host gets the same shell, development tools, coding-agent configuration, Git signing, CLI authentication, GUI apps, fonts, and Ghostty settings as the NixOS desktop host, assembled as a `nix-darwin` system with Home Manager inside it. Intel Macs are not supported.

| Host | Machine |
| --- | --- |
| `MacBook-Pro-Mac17-9` | Apple silicon MacBook Pro (M5 Pro, model identifier `Mac17,9`) |

The repository owner runs this runbook on the Mac from a local GUI login session. A coding agent does not erase macOS, install Nix, run `darwin-rebuild`, or run `nr switch` on a host on its own initiative; it runs one of these steps only when the owner instructs it to in the current session, for the host and the steps named. The rule and what stays with the owner are stated in [fresh installation](install.md).

## Back up before erasing the Mac

Before erasing macOS or starting a clean installation, confirm and back up:

- **YubiKeys**: all three YubiKeys that carry the OpenPGP key, with their User and Admin PINs and the offline signing-key backup verified and stored separately from the Mac.
- **GPG public key and ownertrust**: `keys/signing.asc` (fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`) committed in the repository and a copy of your GPG ownertrust (`gpg --export-ownertrust`) if you rely on trust assignments outside the ultimate trust declared for `keys/signing.asc`.
- **File-based SSH keys**: any SSH private key on the Mac that is not already stored in `secrets/hosts/<host>/ssh.yaml` or 1Password.
- **1Password access**: the 1Password Emergency Kit (account password, Secret Key, and two-factor authentication on another device) so you can sign in on the fresh installation.
- **Disk data**: every local file, unpushed Git branch or worktree, Parallels virtual machine, container volume, and application state on the internal SSD that a macOS erase will destroy.

## Prerequisites

A Mac that has no directory under `hosts/` yet needs one first; [adding a host](adding-a-host.md#macos-hosts) creates the host directory, the bootstrap age material, the `secrets/tokens.yaml` recipient, and the per-host secret files (`ssh.yaml`, `apple-account.yaml`, and optional `tls-inspection-ca.yaml` and `wired-network.yaml`). For `MacBook-Pro-Mac17-9`, all of those files are already committed in this repository.

Before starting the setup on the Mac, have:

- the host directory and its encrypted secrets pushed to `main`;
- an administrator account on the Mac whose short username matches `my.user.name` in `hosts/<host>/default.nix` (`hyperlapse` on `MacBook-Pro-Mac17-9`), for `sudo`;
- the Apple Account credentials stored in `secrets/hosts/<host>/apple-account.yaml` for Xcode downloads, and a signed-in Mac App Store session for KakaoTalk and Flighty;
- one of the three YubiKeys and its User PIN, for the age identity recovery step;
- network and time for the first applies, which download Homebrew, every formula and cask, the Apple container kernel, Xcode (on the production switch, not during bootstrap), KakaoTalk, Flighty, and the Android SDK;
- no real directory at `~/Library/Android/sdk`, where Android Studio installs its SDK by default. Home Manager links the pinned SDK there and stops the apply when it finds a real directory in the way. Move an existing one aside with `mv ~/Library/Android/sdk ~/Library/Android/sdk.before-nix-config`.

## What the configuration manages

The flake builds two outputs for each macOS host, `darwinConfigurations.<host>` and `darwinConfigurations.<host>-bootstrap`. Each is a `nix-darwin` system with Home Manager inside it, so one activation applies both layers. The bootstrap output holds no secrets.

- **Nix.** `nix-darwin` owns `/etc/nix/nix.conf` and keeps `auto-optimise-store` off, because store optimisation corrupts the store on macOS (NixOS/nix#7273).
- **Host marker.** `/etc/nix-config-host` records the host name (`host=<host>`) and whether the `bootstrap` or `production` output is applied (`variant=bootstrap` or `variant=production`). `nr` reads the host from it, so the computer name macOS shows in System Settings does not matter.
- **Homebrew.** `nix-homebrew` installs Homebrew on the first apply, or migrates one already at `/opt/homebrew` in place. `modules/darwin/homebrew.nix` installs the `aria2` and `container` formulae, and `modules/shared/darwin-apps.nix` supplies the casks: Ghostty, 1Password, Google Chrome, Claude Desktop, ChatGPT, Discord, Obsidian, VLC, WebTorrent, MacZip, and the other GUI apps, plus Parallels Desktop (which has no NixOS counterpart) and the Tailscale app (which NixOS runs as a system service instead). Cleanup is `"none"`, so an app you installed by hand or through Microsoft Intune stays installed. Each apply installs missing formulae and casks and upgrades outdated ones. Installing Parallels Desktop or Tailscale may ask for your administrator password. Parallels Desktop's license and Tailscale's tailnet login stay manual in their apps.
- **Retired casks.** Because Homebrew cleanup is `"none"`, dropping a cask from `modules/shared/darwin-apps.nix` leaves it installed on existing Macs. `modules/darwin/retired-casks.nix` runs after the Mac App Store step and uninstalls each retired cask when present — today `grok-bot` and `orca` — via `brew uninstall --cask --force` as the primary user, then untaps `stablyai/orca`. It never passes `--zap`, so user data under `~/Library`, `~/.grok`, and `~/.orca` stays untouched, and it never fails the apply.
- **Xcode.** Production activation (`!config.my.bootstrap`) runs the flake-pinned `xcodes` 2.1.0 after Homebrew (`modules/darwin/xcode.nix`). Bootstrap skips Xcode entirely so the bootstrap switch needs neither the age identity nor the Apple Account secret. On a production switch, `macos-xcode` selects the newest Apple Silicon release across stable and prerelease channels from xcodereleases.com, checks the required macOS version, looks for an `/Applications/Xcode*.app` whose version and build match it, or installs it there with `xcodes` (which names the app after the release, such as `Xcode-27.3.0-Beta.app`), verifies the app's signature, completes `xcodebuild -license accept` and `-runFirstLaunch`, verifies `xcrun clang` and the macOS SDK, and selects that app's `Contents/Developer` with `xcode-select`. The install prompts on the terminal, so run a production switch from a terminal window, not from a shell without a TTY. It decrypts the store copy of `secrets/hosts/<host>/apple-account.yaml` (`my.xcode.appleAccountFile`) in memory using `~/.config/nix-config/age/key.txt` (owned by the primary user, mode `0600`) and passes `XCODES_USERNAME` and `XCODES_PASSWORD` only in the `xcodes` child environment. Interactive 2FA prompts may appear on first sign-in. A failed Xcode install or upgrade fails the production switch and keeps the previous developer directory selection.
- **KakaoTalk and Flighty.** The two managed Mac App Store apps (`modules/darwin/app-store.nix`). Activation installs or upgrades each with `mas` after the Xcode step when the App Store is signed in, and skips them with a warning when it is not.
- **Android SDK.** `packages/android-sdk.nix` builds the pinned Android SDK for Apple silicon with `arm64-v8a` system images and links it at `~/Library/Android/sdk`, with `ANDROID_HOME` and `ANDROID_SDK_ROOT` pointing there.
- **Mobile devices.** The iOS Simulators and Android Virtual Devices listed in `my.mobileDevices`; see [Mobile devices](#mobile-devices).
- **Nix apps.** VSCodium and the T3 Code desktop app (`0.1.8`) come from Nix. Home Manager copies their bundles into `~/Applications/Home Manager Apps`.
- **Containers.** Apple's `container` CLI (`modules/darwin/container.nix`), with no Podman machine and no automatic minikube cluster; see [Containers](#containers).
- **Fonts.** The shared font list (`modules/shared/font-packages.nix` and `packages/overlay-fonts.nix`, including Pretendard, Jetendard, D2Coding, Monoplex KR, Noto CJK, and Twemoji) is installed system-wide.
- **Dock and system defaults.** `modules/darwin/defaults.nix` enables automatic light/dark appearance (`AppleInterfaceStyleSwitchesAutomatically = true`). `modules/darwin/dock.nix` sets tile size `32`, hides recent applications (`show-recents = false`), pins `~/Downloads` on the right side of the Dock, and replaces `persistent-apps` on each apply. The Dock starts with the system-owned Finder, Apps, Google Chrome, and App Store. Its personal apps include Messages, KakaoTalk, Telegram Desktop, FaceTime, and Phone in that order. The host's `my.dock.hostApps` follow the personal apps and precede Ghostty; T3 Code follows Ghostty when `my.t3.desktop.enable` is on, followed by ChatGPT and Claude. The module defines the complete ordered list.
- **User environment.** zsh (Prezto modules and completions), Ghostty (`Jetendard`), Git with YubiKey OpenPGP signing via `gpg-git` and `dotfiles-pinentry`, `.NET` 8 and 10, Rust (`rustup`), C++/CMake/Ninja/`vcpkg`, Bun, `mise`, `gh`, `glab`, `tokscale`, T3 Code `0.1.8`, and the managed coding agents (Claude Code, Codex, Pi `1.5.0`, Grok Build `1.0.77`, and the Antigravity CLI `agy` with the rebuilt Antigravity ACP runtime; see [App notes](#app-notes)).

ChatGPT is available from `/Applications` on production and bootstrap outputs; open it and sign in manually.

## First setup on the Mac

Run these steps on the Mac, in order, from a local GUI login session, never over SSH.

1. **Erase and reinstall macOS (when starting from an erased Mac).** In System Settings > General > Transfer or Reset > Erase All Content and Settings (or from macOS Recovery), erase the Mac, reinstall the current macOS release, and complete Setup Assistant creating the local administrator account named in `hosts/<host>/default.nix` (`hyperlapse` on `MacBook-Pro-Mac17-9`).

2. **Confirm that FileVault is on.** The user age identity (`~/.config/nix-config/age/key.txt`), the host SSH private key (`~/.ssh/id_ed25519_nix_config`), and the published CLI tokens (`~/.local/state/cli-auth/`) sit in your home directory, and FileVault is what encrypts them at rest:

   ```sh
   fdesetup status
   ```

   It must report `FileVault is On.` Turn it on in System Settings > Privacy & Security > FileVault before continuing.

3. **Install Nix** with the upstream multi-user installer. Skip this step if Nix is already installed:

   ```sh
   sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
   ```

   Open a new terminal window afterward so `nix` is on `PATH`.

4. **Move aside the `/etc` files the installer wrote.** `nix-darwin` takes over `/etc/nix/nix.conf`, `/etc/bashrc`, and `/etc/zshrc`, and its activation refuses to overwrite a file it did not create:

   ```sh
   for file in /etc/nix/nix.conf /etc/bashrc /etc/zshrc; do
     sudo mv "$file" "$file.before-nix-darwin"
   done
   ```

   Because `/etc/bashrc` and `/etc/zshrc` are what put `nix` on `PATH` before `nix-darwin` activates, run steps 5 through 8 in this same terminal window (or load Nix in a new shell with `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`).

5. **Clone the repository** to `~/src/github.com/hyperlapse122/dotfiles`, matching the configured `ghq.root` (`~/src`). The first time `/usr/bin/git` runs on a fresh Mac, macOS prompts to install the Xcode Command Line Tools; accept and wait for the installation to finish, then run the clone:

   ```sh
   git clone https://github.com/hyperlapse122/dotfiles.git ~/src/github.com/hyperlapse122/dotfiles
   cd ~/src/github.com/hyperlapse122/dotfiles
   ```

6. **Resolve the host directory name** for this Mac (`MacBook-Pro-Mac17-9`):

   ```sh
   host=$(ls hosts | grep -x ".*$(sysctl -n hw.model | tr , -).*")
   echo "$host"
   ```

   It must print `MacBook-Pro-Mac17-9` (or the single host directory matching `hw.model`). When it prints none, see [adding a host](adding-a-host.md#macos-hosts).

7. **Sign in to the Mac App Store.** Open the App Store app and sign in with your Apple Account so the apply can install KakaoTalk and Flighty via `mas`. (Xcode does not use `mas`; it installs on the production switch in step 12 using `secrets/hosts/<host>/apple-account.yaml`.) Without the App Store sign-in, the apply still succeeds, prints a warning for KakaoTalk and Flighty, and installs them on a later apply once you sign in.

8. **Apply the bootstrap output** (`MacBook-Pro-Mac17-9-bootstrap`). `nr` is not installed yet, and `nix.conf` was moved aside in step 4, so invoke `darwin-rebuild` through `nix run` with flakes enabled on the command line:

   ```sh
   sudo nix --extra-experimental-features 'nix-command flakes' \
     run github:nix-darwin/nix-darwin/master#darwin-rebuild -- \
     switch --flake ".#$host-bootstrap"
   ```

   This bootstrap switch installs Homebrew, the formulae (`aria2`, `container`) and casks, KakaoTalk, and Flighty, prepares the Apple `container` runtime and its recommended kernel, creates the declared Android Virtual Device, writes `/etc/nix-config-host` (`host=MacBook-Pro-Mac17-9`, `variant=bootstrap`), and puts `gpg`, `dotfiles-pinentry`, `install-user-age-identity`, and `nr` on `PATH`. It skips Xcode and all sops secrets. Open a new terminal window (such as Ghostty) afterward so the managed shell and `PATH` are active.

9. **Grant the terminal App Management permission** in System Settings > Privacy & Security > App Management. From the second apply onward, Home Manager updates the app bundles in `~/Applications/Home Manager Apps`, and its `copyApps` step aborts activation if the terminal cannot modify them.

10. **Create the secret directories and exclude them from Time Machine.** `tmutil addexclusion` requires each path to exist first:

    ```sh
    for dir in ~/.config/nix-config/age ~/.local/state/cli-auth ~/.config/gh ~/.config/glab-cli; do
      mkdir -p "$dir"
      chmod 0700 "$dir"
      tmutil addexclusion "$dir"
    done
    ```

11. **Recover the user age identity with a YubiKey inserted.** GPG accesses the YubiKey through macOS's native smart-card stack (`scdaemon.conf` sets `disable-ccid` and `pcsc-shared`):

    ```sh
    cd ~/src/github.com/hyperlapse122/dotfiles
    host=$(sed -n 's/^host=//p' /etc/nix-config-host)
    ./scripts/recover-age-identity --user --host "$host"
    ```

    `recover-age-identity --user --host "$host"` decrypts `secrets/bootstrap/<host>/age-key.asc` with `gpg` and pipes the identity into `install-user-age-identity --recipient "$(cat secrets/bootstrap/<host>/recipient.txt)"`, which verifies that the key derives the expected `age1...` recipient before atomically writing `~/.config/nix-config/age/key.txt` (owned by your user, mode `0600`, inside `~/.config/nix-config/age` with mode `0700`; see `../secrets/README.md`).

12. **Apply the final production output** (`MacBook-Pro-Mac17-9`). Because the current generation is `bootstrap`, `nr` requires `--host "$host"` to confirm the move to production:

    ```sh
    nr switch --host "$host"
    ```

    The production switch:
    - decrypts `secrets/hosts/<host>/tls-inspection-ca.yaml` into `/etc/ssl/nix-config/` and ensures macOS admin SSL trust when `my.tlsInspectionCa.enable` is on (approve the macOS authorization dialog if prompted);
    - installs and selects Xcode through `xcodes` using the Apple Account decrypted in memory from `secrets/hosts/<host>/apple-account.yaml` (complete any interactive Apple Account 2FA or `sudo` prompt if asked);
    - stages and publishes the CLI tokens (`~/.local/state/cli-auth/`), `gh` and `glab` configuration, Pi's Synthetic API key (`~/.pi/agent/auth.json`), and the host SSH key (`~/.ssh/id_ed25519_nix_config`) from `secrets/tokens.yaml` and `secrets/hosts/<host>/ssh.yaml`;
    - records `variant=production` in `/etc/nix-config-host`.

13. **Exclude the host SSH private key from Time Machine by path.** Because `host-secrets` replaces `~/.ssh/id_ed25519_nix_config` atomically on every apply, a sticky file exclusion would be lost on the next switch; use a fixed-path exclusion (`-p`) with `sudo`:

    ```sh
    sudo tmutil addexclusion -p ~/.ssh/id_ed25519_nix_config
    ```

14. **Verify or register the host SSH public key** on GitHub and any server the Mac accesses; see [SSH key](#ssh-key) below.

## Everyday use

Pull, then apply from the clone. Routine applies use `~/.config/nix-config/age/key.txt` and need no YubiKey:

```sh
cd ~/src/github.com/hyperlapse122/dotfiles
git pull
nr switch
```

`nr switch` builds the `nix-darwin` system as your user, registers it as the system profile (`/nix/var/nix/profiles/system`), and activates it through `sudo`. Activation clears its environment and runs from `/`, so no activation step reads the checkout; encrypted files such as `secrets/hosts/<host>/apple-account.yaml` reach it as store paths. Run it from a local terminal with App Management permission. From outside the checkout, pass `--flake-dir <path>`.

| Command | Effect |
| --- | --- |
| `nr switch` | Build and activate `darwinConfigurations.<host>.system` for the host in `/etc/nix-config-host`. |
| `nr switch --host <host>` | Name the host explicitly. Required for the first move from `bootstrap` to `production`. |
| `nr switch --bootstrap` | Build and activate `darwinConfigurations.<host>-bootstrap.system`. |
| `nr switch --flake-dir <path>` | Build from the checkout at `<path>` instead of the current working directory. |
| `nr build` | Build the system closure without activating it and without `sudo`. |
| `nr boot`, `nr test` | Refused: a Mac has no bootloader generation. |

The age identity is checked before anything changes. Before building, `nr` stops when `~/.config/nix-config/age/key.txt` is missing. During activation, `tls-inspection-ca`, `macos-xcode`, and `host-secrets stage` each verify that `~/.config/nix-config/age/key.txt` is a regular file owned by your user with mode `0600` and can decrypt the required ciphertext before replacing any file or link.

### Rolling back

Every `nr switch` registers a generation in `/nix/var/nix/profiles/system`. To roll back to the previous generation:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --rollback
sudo /nix/var/nix/profiles/system/activate
```

Fix the checkout before running `nr switch` again.

## Secrets and authentication

The user age identity lives at `~/.config/nix-config/age/key.txt`, protected at rest by FileVault. It decrypts:

- `secrets/tokens.yaml` (shared across both hosts);
- `secrets/hosts/<host>/ssh.yaml` (this Mac's SSH private key);
- `secrets/hosts/<host>/apple-account.yaml` (this Mac's Apple Account `username` and `password` for `xcodes`);
- `secrets/hosts/<host>/tls-inspection-ca.yaml` (when `my.tlsInspectionCa.enable = true`);
- `secrets/hosts/<host>/wired-network.yaml` (when `my.wiredNetwork.enable = true`).

A macOS host is never a recipient of `secrets/wifi.yaml`, `secrets/tailscale.yaml`, or `secrets/printers.yaml`; the `user-identity-secrets` check enforces that boundary. The Mac joins the tailnet through the Tailscale app's interactive login rather than a pre-authentication key.

Production activation publishes:

- `gh` and `glab` configuration under `~/.config/gh` and `~/.config/glab-cli`;
- CLI and registry tokens under `~/.local/state/cli-auth/` (`github_token`, `gitlab_token`, `jpi_token`, `tokscale_token`, `synthetic_api_key`, `exa_api_key`, `openrouter_api_key`);
- the `synthetic` provider key in `~/.pi/agent/auth.json`;
- the host SSH private key at `~/.ssh/id_ed25519_nix_config`.

### YubiKey PIN

Git uses `gpg-git` to run `gpg --batch --card-status` before signing so a sleeping card wakes cleanly. It waits at most ten seconds, discards card metadata, and passes verification calls straight to `gpg`.

Three YubiKeys carry the same signing key, each under its own PIN. The packaged `dotfiles-pinentry` frontend (`packages/pinentry-keyring.nix`) stores OpenPGP user PINs in the macOS Keychain under service `dotfiles.pinentry.openpgp` and account `yubikey:<serial>:user` on the first qualifying prompt and delegates dialogs to `pinentry_mac`. Remove a saved PIN with `dotfiles-pinentry forget <card-id>`; serial numbers may be decimal digits or a quoted grouped serial such as `"12 345 678"`. GnuPG's own agent cache remains disabled (`default-cache-ttl 0`, `max-cache-ttl 0`), and `pinentry_mac`'s built-in "Save in Keychain" checkbox starts unticked (`UseKeychain = false`).

### SSH key

A Mac uses its own Ed25519 SSH key at `~/.ssh/id_ed25519_nix_config`, declared in `~/.ssh/config` (`IdentityFile ~/.ssh/id_ed25519_nix_config`). Its public half is committed at `secrets/hosts/<host>/ssh.pub` and can also be printed after a production apply:

```sh
ssh-keygen -y -f ~/.ssh/id_ed25519_nix_config
```

Register it as an authentication key on GitHub (Settings > SSH and GPG keys) and in `~/.ssh/authorized_keys` on any server the Mac must reach. Git commit and tag signing always uses the YubiKey OpenPGP key.

### Apple account for Xcode

`modules/darwin/xcode.nix` passes the store copy of `secrets/hosts/<host>/apple-account.yaml` (`my.xcode.appleAccountFile`) to `macos-xcode`; a production output without that file fails evaluation. The encrypted YAML holds two string keys, `username` and `password`, encrypted to `<host>`'s age recipient alone. See [adding a host](adding-a-host.md#create-the-apple-account-secret) for creating or rotating that file without writing plaintext into the checkout.

### TLS inspection CA

On a Mac where an endpoint protection product intercepts TLS and re-signs certificates with its own root CA, macOS apps trust that CA through the System keychain while Nix tools read their own CA bundle and fail with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`. Enabling `my.tlsInspectionCa.enable = true;` in `hosts/<host>/default.nix` fixes that for the host:

1. Add a `.sops.yaml` creation rule for `^secrets/hosts/<host>/tls-inspection-ca\.yaml$` listing only that host's age recipient.
2. Pipe the CA's PEM certificate into `sops` as the `certificate` key without writing plaintext into the checkout:

   ```sh
   openssl x509 -in <downloaded CA> -outform PEM \
     | yq -n '.certificate = load_str("/dev/stdin")' \
     | sops --encrypt --filename-override secrets/hosts/<host>/tls-inspection-ca.yaml \
         --input-type yaml --output-type yaml /dev/stdin \
     > secrets/hosts/<host>/tls-inspection-ca.yaml
   ```

3. Set `my.tlsInspectionCa.enable = true;` in `hosts/<host>/default.nix` and apply.

Every production apply then writes `/etc/ssl/nix-config/ca-certificates.crt` (this generation's Nix root bundle followed by the inspection CA) and restarts `nix-daemon` when the bundle changes. Shells, `nix-daemon`, and GUI apps launched from Finder or the Dock receive `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, and `GIT_SSL_CAINFO` pointing at `/etc/ssl/nix-config/ca-certificates.crt`, alongside `NODE_USE_SYSTEM_CA=1` in the shell environment; relaunch running apps after a change so they pick up the updated variables. When macOS admin trust settings do not yet trust the CA for SSL, `postActivation` runs `security add-trusted-cert`, which prompts for authorization.

## Network recovery

On a Mac where switching networks can leave traffic wedged until Wi-Fi is cycled, `my.networkRecovery.enable = true` runs the `org.nixos.network-recovery` launch daemon every 5 seconds (`modules/darwin/network-recovery.nix`). When the network changes or the Mac wakes, it checks HTTP to `captive.apple.com`, DNS resolution, and a direct TCP connection. While there is no default route, or within 10 seconds of joining a network, it waits. When checks fail after that, it tries these steps in order and stops as soon as connectivity returns:

1. Flush the macOS DNS cache.
2. Reconnect Tailscale (`down` then `up`) as the console user when Tailscale was connected.
3. Cycle the network service carrying the default route (such as Wi-Fi or iPhone USB tethering) off and back on, unless the default route is a tunnel.

A captive portal or policy page is logged without triggering repairs. The log is `/var/log/network-recovery.log`, rotated by `newsyslog`. Hosts with `my.networkRecovery.enable` also set `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=60000` in shell and GUI environments on production outputs so stalled streams fail within a minute after a network switch.

## Wired network

A Mac whose wired adapter needs a static address on one network declares it with `my.wiredNetwork.enable = true` (`modules/darwin/wired-network.nix`). The values live in `secrets/hosts/<host>/wired-network.yaml`, encrypted to the host's recipient alone, with the keys `mac`, `ipv4_address`, `ipv4_subnet_mask`, `ipv4_router`, and `dns_servers` (see `../secrets/README.md`).

NixOS hosts use the same trait and file schema with a different mechanism and stricter rules; see [Wired network](install.md#wired-network).

At the end of each production apply, `macos-wired-network` decrypts that file in memory with `~/.config/nix-config/age/key.txt`, finds the hardware port with the declared MAC address, and brings that port's network service to the declared state:

- a manual IPv4 configuration with the declared address, subnet mask, and router;
- exactly the declared DNS servers, in order;
- IPv6 turned off.

It writes only the groups that differ and prints one line per rewritten group, such as `macos-wired-network: set DNS on Thunderbolt Ethernet Slot 0`. A change made in System Settings is reverted on the next production apply. Other network services, such as Wi-Fi and Tailscale, are never touched.

When the adapter is unplugged, macOS lists no port with that MAC address, and the step does nothing and prints nothing. When the identity or the file cannot be read, or a `networksetup` write fails, the step prints one warning and the apply continues; it never prints a declared value. Bootstrap applies skip the step entirely. Turning the trait off, or removing the file, leaves the adapter with its last applied settings rather than resetting it to DHCP.

To create or change the file, add a `.sops.yaml` creation rule for `^secrets/hosts/<host>/wired-network\.yaml$` listing only that host's recipient, then pipe the YAML into `sops` without writing plaintext into the checkout:

```sh
printf '%s\n' 'mac: <MAC>' 'ipv4_address: <address>' 'ipv4_subnet_mask: <mask>' \
    'ipv4_router: <router>' 'dns_servers:' '  - <DNS 1>' '  - <DNS 2>' \
  | sops --encrypt --filename-override secrets/hosts/<host>/wired-network.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/hosts/<host>/wired-network.yaml
```

## Containers

macOS hosts use Apple's `container` CLI (`modules/darwin/container.nix`), installed via Homebrew's `container` formula. No Podman machine is configured, and no automatic `minikube` cluster runs at login.

During activation, `macos-container.sh` checks `container system status`:

- If the runtime API is already running, activation leaves the running API and its kernel untouched.
- If the API is stopped, activation runs `container system start --disable-kernel-install`, sets the recommended default kernel (`container system kernel set --recommended`) when none is configured yet, and registers the Homebrew login service (`brew services start container`). A failed kernel step records `~/.local/state/dotfiles/apple-container-kernel-pending` so the next apply retries it, and exits non-zero so the apply fails visibly.

`kubectl`, `kubernetes-helm`, and `minikube` remain installed as client binaries on `PATH`, without an automatic cluster. Because Apple `container` does not expose a Docker-compatible socket or `docker` CLI alias, tools that require the Docker Engine API (such as Testcontainers) need an explicit alternative agreed with the owner. Existing Podman machines or credential files on disk are not deleted. Use `container registry login` for registry credentials stored in the macOS Keychain; `docker-credential-sops` remains on `PATH` for tools that speak the Docker credential helper protocol directly.

Remove temporary containers, images, volumes, networks, and build caches as soon as a task finishes; the `container` system service and default kernel are host infrastructure and stay running.

## App notes

- VSCodium's user directory is `~/Library/Application Support/VSCodium/User`. Its `keybindings.json` is a read-only store link; add keybindings in `home/h82/dev/vscodium.nix`.
- The T3 Code desktop app is the flake's pinned release (`0.1.8`, `T3 Code (Beta).app`). A launchd agent sets `T3CODE_DISABLE_AUTO_UPDATE=1` at login so the app does not self-update off the pin.
- Every package in the NixOS user environment must have a corresponding decision in `modules/shared/darwin-apps.nix` (Homebrew cask, Nix package, or explicit exclusion reason); the `darwin-config` check enforces this.
- T3 Code finds the Android SDK at `~/Library/Android/sdk` when launched from Finder or the Dock.
- T3 Code's `antigravity` instance runs the Antigravity ACP runtime that `packages/antigravity-acp.nix` rebuilds, through the `agy_acp_server.par` wrapper in the user profile. The rebuild invalidates Google's signature, so the build signs the runtime ad hoc without the hardened-runtime flag and starts it once during its install check. The re-signed runtime cannot read Keychain items the Google-signed one wrote, so the wrapper sets `AGY_ACP_FORCE_FILE_STORAGE=1` and the runtime keeps its sign-in in a file. Sign in to Antigravity once through T3 Code; activation links `~/.gemini/antigravity-acp/acp_token.json` to the token T3 Code stores for the instance, and keeps a regular file already at that path. Only CI's build has run this runtime on macOS, so confirm a signed-in session on the Mac itself.

### Mobile devices

`my.mobileDevices` in `home/h82/dev/mobile-devices.nix` declares the iOS Simulators and Android Virtual Devices (AVDs) that activation ensures exist. By default it declares one `pixel_10_pro` AVD on the newest pinned Android API level (`packages/android-sdk-repo.json`). iOS Simulators and runtimes are left to Xcode unless you add an `"ios"` entry to `my.mobileDevices`. Existing simulators and AVDs are never deleted or modified by activation. Remove unused devices or runtimes by hand:

```sh
xcrun simctl list devices
xcrun simctl delete <udid>
xcrun simctl runtime list
xcrun simctl runtime delete <identifier>
avdmanager list avd -c
avdmanager delete avd -n <name>
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| The first apply stops on unexpected files in `/etc` | A file the Nix installer wrote is still in place. Move `/etc/nix/nix.conf`, `/etc/bashrc`, and `/etc/zshrc` aside as step 4 shows, then apply again. |
| `nix: command not found` in a new terminal during setup | `/etc/bashrc` and `/etc/zshrc` were moved aside before `nix-darwin` replaced them. Run `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`. |
| `nr: running the bootstrap generation; …` | A bare `nr switch` refuses to move a bootstrap generation to production. Recover the age identity, then run `nr switch --host "$host"`, or reapply bootstrap with `nr switch --bootstrap`. |
| `nr: no age identity at …` | `~/.config/nix-config/age/key.txt` is missing. Run `./scripts/recover-age-identity --user --host "$host"` from the checkout with a YubiKey connected. |
| `… is not owned by …`, `… must have mode 0600`, or `cannot decrypt …` during activation | `~/.config/nix-config/age/key.txt` has the wrong owner or mode or does not match this host's recipient. Re-run `./scripts/recover-age-identity --user --host "$host"`. |
| `nr: not inside a git repository; …` | `nr` was run outside the checkout. `cd ~/src/github.com/hyperlapse122/dotfiles` or pass `--flake-dir <path>`. |
| The second apply aborts in `copyApps` | The terminal lacks App Management permission in System Settings > Privacy & Security > App Management, or the apply ran over SSH. See step 9. |
| The apply stops with `Existing file '…/Library/Android/sdk' would be clobbered` | Move the existing directory aside with `mv ~/Library/Android/sdk ~/Library/Android/sdk.before-nix-config` and apply again. |
| Xcode provisioning fails | Check that the checkout contains `secrets/hosts/<host>/apple-account.yaml`, verify `~/.config/nix-config/age/key.txt` ownership and mode `0600`, confirm network access and interactive 2FA approval, and run `nr switch` again. |
| `kakaotalk: App Store install failed; …` or `flighty: App Store install failed; …` | Sign in to the Mac App Store app and run `nr switch` again. |

## Verification

`darwin-config` and `darwin-provisioning` run on both Linux and Apple silicon macOS. They evaluate declarations and exercise provisioning with fake tools. Run them locally from the checkout:

```sh
nix build --no-link --print-build-logs \
  .#checks.aarch64-darwin.darwin-config \
  .#checks.aarch64-darwin.darwin-provisioning
```

Run `nix flake check` on the Mac to build all declared macOS checks, including `darwin-outputs`, which builds the fixture systems. CI also builds every production and bootstrap `darwinConfigurations` closure on its `macos-26` runner when triggered (`main` push, manual dispatch, or `full-ci` label).

These checks do not activate a Mac. Confirm hardware and GUI behavior on the Mac itself after applying and report live Mac checks separately from repository checks.

## Losing or retiring the Mac

Because `~/.config/nix-config/age/key.txt` and `~/.ssh/id_ed25519_nix_config` sit on the Mac's disk, treat every secret the Mac could decrypt as exposed if the Mac is lost or compromised. Follow [compromise or decommission of a host](recovery.md#compromise-or-decommission-of-a-host) to revoke its SSH key, remove its recipient, re-key and rotate `secrets/tokens.yaml`, and rotate the Apple Account password.
