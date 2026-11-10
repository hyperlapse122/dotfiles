# macOS hosts

This guide covers a Mac from first setup to everyday use. A macOS host is an Apple silicon Mac (`aarch64-darwin`). It gets the same shell, development tools, coding-agent configuration, Git signing, and CLI authentication as a non-NixOS Linux host, and the GUI apps, fonts, and Ghostty settings of a NixOS host. Intel Macs are not supported.

| Host | Machine |
| --- | --- |
| `MacBook-Pro-Mac17-9` | Apple silicon MacBook Pro (model identifier `Mac17,9`) |

A Mac that has no directory under `hosts/` yet needs one first; [adding a host](adding-a-host.md#macos-hosts) creates the directory, the bootstrap age material, the `tokens.yaml` recipient, and the host SSH key. Run those steps on a machine that already has the checkout and a YubiKey, then push, so the Mac can clone the result.

Before the first setup, have:

- the host directory and its secrets pushed to `main`;
- an administrator account on the Mac, for `sudo`;
- an Apple Account for the Mac App Store, which Xcode, KakaoTalk, and Flighty come from;
- one of the three YubiKeys and its PIN, for the identity recovery in step 10;
- network and time for the first apply, which downloads Homebrew, every cask, the Podman machine image, Xcode, KakaoTalk, Flighty, an iOS Simulator runtime, and the Android SDK;
- no directory at `~/Library/Android/sdk`, where Android Studio installs its SDK by default. Home Manager links the SDK there and stops the apply when it finds a real directory in the way. Move an existing one aside with `mv ~/Library/Android/sdk ~/Library/Android/sdk.before-nix-config`.

## What the configuration manages

The flake builds two outputs for each macOS host, `darwinConfigurations.<host>` and `darwinConfigurations.<host>-bootstrap`. Each is a nix-darwin system with Home Manager inside it, so one activation applies both layers. The bootstrap output holds no secrets.

- **Nix.** nix-darwin owns `/etc/nix/nix.conf` and keeps `auto-optimise-store` off, because store optimisation corrupts the store on macOS (NixOS/nix#7273).
- **Host marker.** `/etc/nix-config-host` records the host name and whether the bootstrap or production output is applied. `nr` reads the host from it, so the name macOS shows for the machine does not matter.
- **Homebrew.** nix-homebrew installs Homebrew on the first apply, or migrates one already at `/opt/homebrew` in place. The casks come from `modules/shared/darwin-apps.nix`: Ghostty, 1Password, Google Chrome, Claude Desktop, ChatGPT, and the other GUI apps, plus Parallels Desktop, which has no NixOS counterpart, and the Tailscale app, which NixOS hosts run as a system service instead. Cleanup is `"none"`, so an app you installed by hand stays installed. Each apply installs missing casks and upgrades outdated ones. Installing Parallels Desktop runs a privileged setup step, so the apply that installs it may ask for your administrator password. Its license is not managed here: enter your key, such as an education key, in Parallels Desktop after that apply. Tailscale installs from a package, so its first apply may also ask for the password. Nothing registers the Mac on the tailnet: open Tailscale, allow its system extension in System Settings → Privacy & Security when macOS asks, and log in in the app. Launch at login, exit nodes, and accepting subnet routes are settings in the app, not in this repository.
- **Retired casks.** Homebrew cleanup is `"none"`, so dropping a cask from `modules/shared/darwin-apps.nix` leaves it installed. `modules/darwin/retired-casks.nix` is a root step after the Mac App Store app step that uninstalls each retired cask when it is installed, today `grok-bot`. It runs `brew uninstall --cask --force` as the primary user, because Homebrew refuses to run as root, with brew's prefix on a `PATH` that `sudo --preserve-env=PATH` keeps, the way nix-darwin calls `brew bundle`. It never passes `--zap`, so a cask's `~/Library` data stays. Only a `brew list` failure with no error output, or with `Error: Cask '<token>' is not installed.`, counts as the cask being absent; any other failure prints brew's error and the command to run. It prints one line per outcome and never fails the apply. Grok Bot's app data in `~/Library` and `~/.grok` stay in place; delete them manually and revoke the xAI grant if desired.
- **Xcode.** Xcode is one of the three Mac App Store apps the configuration manages. `modules/darwin/xcode.nix` installs it with `mas` after the casks, or upgrades it when the App Store has a newer version, so the App Store decides the version. When `xcode-select` points at the Command Line Tools or nowhere, the step points it at Xcode. The step also accepts the license and runs first-launch setup when either is pending. It needs the App Store signed in; see step 6.
- **KakaoTalk and Flighty.** The other two Mac App Store apps. `modules/darwin/app-store.nix` installs each with `mas` after Xcode, KakaoTalk first, or upgrades it when the App Store has a newer version. A copy already installed from the App Store is kept and upgraded in place. Signing in to KakaoTalk or Flighty itself is done in the app. Like Xcode, both need the App Store signed in. To add another App Store app, add its name, App Store id, and message prefix to the list in that file; the name must match the app's bundle in `/Applications`.
- **Android SDK.** A Mac gets the same pinned Android SDK as a Linux x86_64 host, from `packages/android-sdk.nix`, built for Apple silicon with `arm64-v8a` system images. It sits at `~/Library/Android/sdk`, a read-only link into the Nix store. `ANDROID_HOME` and `ANDROID_SDK_ROOT` point there. An SDK Android Studio already installed at that path must be moved aside before the first apply; see the prerequisites above.
- **Mobile devices.** The iOS Simulators and Android Virtual Devices listed in `my.mobileDevices`; see [Mobile devices](#mobile-devices).
- **Nix apps.** VSCodium and the T3 Code desktop app come from Nix. Home Manager copies their bundles into `~/Applications/Home Manager Apps`.
- **Containers.** One Podman machine, with minikube inside it on production outputs; see [Containers](#containers).
- **Fonts.** The NixOS font list is installed system-wide.
- **System defaults.** `modules/darwin/defaults.nix` is where Dock, Finder, trackpad, and keyboard defaults go. It sets none yet.
- **User environment.** zsh, Git, the development tools, Claude Code and the other agents, configured as on a non-NixOS Linux host.

ChatGPT is available from Applications on production and bootstrap outputs. Open it and sign in manually. No ChatGPT login agent is declared: inspected Linux and macOS Electron bundles gate `isBackgroundLaunch` to Windows and call `showInactive`, so neither platform has a verified windowless launch mode.

## First setup on the Mac

Run these steps on the Mac, in order, from a local login session, not over SSH.

1. Confirm that FileVault is on. The age identity and the published tokens are plaintext files in your home directory, and FileVault is what encrypts them at rest:

   ```sh
   fdesetup status
   ```

   It must report `FileVault is On.` Turn it on in System Settings > Privacy & Security > FileVault before you continue.

2. Install Nix with the upstream multi-user installer, the same one a non-NixOS Linux host uses. Skip this step if Nix is already installed this way:

   ```sh
   sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
   ```

   Open a new terminal afterwards, so `nix` is on `PATH`.

3. Move aside the files the installer wrote or edited in `/etc`. nix-darwin takes over `/etc/nix/nix.conf`, `/etc/bashrc`, and `/etc/zshrc`, and its activation stops rather than replace a file it did not write:

   ```sh
   for file in /etc/nix/nix.conf /etc/bashrc /etc/zshrc; do
     sudo mv "$file" "$file.before-nix-darwin"
   done
   ```

   The installer's lines in `/etc/bashrc` and `/etc/zshrc` are what put `nix` on `PATH`, so run steps 4 to 7 in the terminal that is already open. A terminal opened before step 7 finishes has no `nix`; load it there with `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`.

4. Clone the repository to `~/src/github.com/hyperlapse122/nix-config`, the path `ghq` uses with the configured root `~/src`. `ghq` is not installed until the bootstrap apply, so clone with `git`. The first time it runs, macOS's `git` may ask to install the Command Line Tools; accept.

   ```sh
   git clone https://github.com/hyperlapse122/nix-config.git ~/src/github.com/hyperlapse122/nix-config
   cd ~/src/github.com/hyperlapse122/nix-config
   ```

5. Find the host directory for this Mac. A Mac's host name contains its model identifier with the comma replaced by a hyphen, such as `Mac17-9` in `MacBook-Pro-Mac17-9`, so look it up from `sysctl`:

   ```sh
   host=$(ls hosts | grep -x ".*$(sysctl -n hw.model | tr , -).*")
   echo "$host"
   ```

   It must print exactly one name. When it prints none, the Mac has no host directory yet; see [adding a host](adding-a-host.md#macos-hosts). When it prints more than one, set `host` to the right one by hand.

6. Open the App Store app and sign in with your Apple Account. The apply downloads Xcode, KakaoTalk, and Flighty with the App Store account signed in to your login session, so it cannot install them until you sign in. On a Mac where you already installed any of them from the App Store, apply keeps that copy and upgrades it in place.

   Without the sign-in, the apply still succeeds. It prints a line for each app asking you to sign in to the App Store, skips Xcode, KakaoTalk, Flighty, and the iOS Simulators, and sets up everything else, the Android SDK and Android Virtual Devices included. Sign in later and apply again to add them.

7. Apply the bootstrap output. `nr` is not installed yet, so run nix-darwin's `darwin-rebuild` from its flake. With `nix.conf` moved aside, flakes are not enabled yet, so the command enables them for this one run:

   ```sh
   sudo nix --extra-experimental-features 'nix-command flakes' \
     run github:nix-darwin/nix-darwin/master#darwin-rebuild -- \
     switch --flake ".#$host-bootstrap"
   ```

   This apply also installs Homebrew, the casks, Xcode, KakaoTalk, and Flighty, creates the Podman machine, and creates the declared Android Virtual Device, so it takes a while and needs network. It writes `/etc/nix-config-host`, which records the host from now on, and installs GPG, the card tools, `install-user-age-identity`, and `nr`. Open a new terminal afterwards, so they are on `PATH`.

8. Give the terminal you apply from the App Management permission, in System Settings > Privacy & Security > App Management. From the second apply on, Home Manager updates the app bundles it copied into `~/Applications/Home Manager Apps`, and its `copyApps` check aborts the activation when the terminal cannot modify them. Apply from a local GUI session, not over SSH: over SSH, the same check aborts unless remote users have Full Disk Access.

9. Create the directories that will hold plaintext secrets, with mode 0700, and exclude each from Time Machine. `tmutil addexclusion` needs the path to exist, so create them first:

   ```sh
   for dir in ~/.config/nix-config/age ~/.local/state/cli-auth ~/.config/gh ~/.config/glab-cli; do
     mkdir -p "$dir"
     chmod 0700 "$dir"
     tmutil addexclusion "$dir"
   done
   ```

10. With a YubiKey inserted, recover the host's age identity. It is the same helper and installer a non-NixOS Linux host uses; GPG reaches the card through macOS's own smart card support, with no pcscd. The new terminal does not have `host` from step 5, so read it from the marker the bootstrap apply wrote:

    ```sh
    cd ~/src/github.com/hyperlapse122/nix-config
    host=$(sed -n 's/^host=//p' /etc/nix-config-host)
    ./scripts/recover-age-identity --user --host "$host"
    ```

    It verifies the derived public recipient before atomically installing `~/.config/nix-config/age/key.txt` (mode `0600` in a `0700` directory; see `../secrets/README.md`).

11. Apply the production output, in the same terminal. `nr` refuses to move a bootstrap generation to production unless you name the host:

    ```sh
    nr switch --host "$host"
    ```

    It publishes the gh and glab configuration, the tokens, and the host's SSH key.

12. Exclude the host's SSH key from Time Machine by path. `host-secrets` replaces that file on every apply, and an ordinary exclusion is attached to the file, so it would be lost with the first replacement. A path exclusion (`-p`) needs `sudo`:

    ```sh
    sudo tmutil addexclusion -p ~/.ssh/id_ed25519_nix_config
    ```

13. Register the host's SSH public key with GitHub and every server the host must reach; see [SSH key](#ssh-key) below.

## Everyday use

Pull, then apply from the clone. Routine applies need no YubiKey:

```sh
cd ~/src/github.com/hyperlapse122/nix-config
git pull
nr switch
```

`nr switch` builds the nix-darwin system as your user, registers it as the system profile, and activates it through `sudo`. Run it from the terminal that holds the App Management permission. `nr` builds the flake of the Git checkout it runs in; from anywhere else, name the checkout with `--flake-dir`.

| Command | Effect |
| --- | --- |
| `nr switch` | Build and activate the production output for the host in `/etc/nix-config-host`. |
| `nr switch --host <host>` | Name the host explicitly. Required for the first move from bootstrap to production. |
| `nr switch --bootstrap` | Apply the secret-free bootstrap output again. |
| `nr switch --flake-dir <path>` | Build from the checkout at `<path>` instead of the current one. |
| `nr build` | Build the system without activating it and without `sudo`. |
| `nr boot`, `nr test` | Refused: a Mac has no boot generation. |

The age identity is checked twice, and either check stops the apply before anything is published. Before building, `nr` stops when `~/.config/nix-config/age/key.txt` is missing. During activation, before Home Manager changes a single link, `host-secrets` stops when the identity is not owned by you, does not have mode 0600, or cannot decrypt every secret. Both name the file and the recovery command, and neither prints a secret.

### Rolling back

Every `nr switch` adds a generation to the system profile, `/nix/var/nix/profiles/system`. To return to the previous one, point the profile back at it and activate it, as `nr` does for a new generation:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --rollback
sudo /nix/var/nix/profiles/system/activate
```

The next `nr switch` from the checkout builds a new generation again, so fix the checkout before applying once more.

## Secrets and authentication

The age identity lives at `~/.config/nix-config/age/key.txt`, protected by FileVault. It decrypts only `secrets/tokens.yaml` and the host's own `secrets/hosts/<host>/ssh.yaml` and, with the TLS inspection CA trait, `secrets/hosts/<host>/tls-inspection-ca.yaml`; a Mac is never a recipient of the Wi-Fi or Tailscale secrets. The Mac joins the tailnet through the Tailscale app's own login instead of an auth key.

Production activation publishes:

- the gh and glab configuration, under `~/.config/gh` and `~/.config/glab-cli`;
- the registry and CLI tokens, under `~/.local/state/cli-auth/`;
- the host SSH key, at `~/.ssh/id_ed25519_nix_config`.

### YubiKey PIN

Git uses `gpg-git` to read the card with `gpg --batch --card-status` before selecting its signing key. This refresh addresses the reported case where a card read restores a missing signing key after idle. It waits at most ten seconds, discards card metadata, and leaves the signing input untouched. If the refresh fails, GPG still runs and reports its own result. The adapter never retries a signature or a PIN, and verification passes directly to GPG. The cause of the intermittent card-discovery failure remains unconfirmed; this is a preventive recovery step.

Three YubiKeys carry the same signing key, each under its own PIN. The PIN prompt is the native `pinentry_mac` dialog (`scripts/pinentry-card-darwin`), which keys items by `n/gnupg-card-pin-<serial>` and offers a "Save in Keychain" checkbox that starts unticked (`UseKeychain = false`). Ticking it saves that card's PIN in the login Keychain (`service = "GnuPG"`, `account = "gnupg-card-pin-<serial>"`), and a rejected PIN deletes that card's item automatically. Remove a saved PIN manually with `security delete-generic-password -s GnuPG -a gnupg-card-pin-<serial>`.

### SSH key

A Mac has no 1Password SSH agent configured. It uses its own SSH key, and `~/.ssh/config` names it with `IdentityFile ~/.ssh/id_ed25519_nix_config`. Registering the public key stays manual. After the first production apply, print it:

```sh
ssh-keygen -y -f ~/.ssh/id_ed25519_nix_config
```

Add it to GitHub under Settings > SSH and GPG keys, and to `~/.ssh/authorized_keys` on every server the host must reach. Register it as an authentication key only; Git signing still uses the YubiKey.

### TLS inspection CA

A Mac whose network traffic an endpoint protection product inspects re-signs TLS with that product's CA. macOS apps trust it through the System keychain, but tools from Nix read their own CA bundle and fail with errors such as `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`. The `my.tlsInspectionCa.enable` trait fixes that for one host:

1. Add a `.sops.yaml` rule for `secrets/hosts/<host>/tls-inspection-ca.yaml` with only that host's recipient.
2. Pipe the CA's PEM certificate into `sops`, never through a file in the checkout, as the `certificate` key:

   ```sh
   openssl x509 -in <downloaded CA> -outform PEM \
     | yq -n '.certificate = load_str("/dev/stdin")' \
     | sops --encrypt --filename-override secrets/hosts/<host>/tls-inspection-ca.yaml \
         --input-type yaml --output-type yaml /dev/stdin \
     > secrets/hosts/<host>/tls-inspection-ca.yaml
   ```

3. Set `my.tlsInspectionCa.enable = true;` in `hosts/<host>/default.nix` and apply.

Every production apply then writes `/etc/ssl/nix-config/ca-certificates.crt`, this generation's Nix roots followed by the CA, and restarts nix-daemon when the bundle changed. Shells, nix-daemon, and apps launched from Finder or the Dock see `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, and `GIT_SSL_CAINFO` pointing at it; relaunch a running app to pick them up. When macOS itself does not trust the CA as an SSL root in its admin trust settings, the apply adds that trust, which shows the authorization dialog; declining it prints a warning and the next apply asks again. To replace the CA, re-encrypt the file the same way. Keep the certificate's subject and fingerprint out of commits, since the repository is public.

## Network recovery

On a Mac where switching networks can leave it offline until Wi-Fi is turned off and on, the `my.networkRecovery.enable` trait repairs that without you. A root launch daemon, `org.nixos.network-recovery`, runs every 5 seconds. When the network changes, or the Mac wakes, it checks plain HTTP to `captive.apple.com`, name resolution, and a direct TCP connection. While the Mac has no default route, as when Wi-Fi is still joining or is turned off, it does nothing. When a check fails on a network the Mac joined less than 10 seconds ago, it waits, since a new network often needs a few seconds for DHCP and DNS. After that, it tries these steps in order and stops at the first one after which the checks pass:

1. Flush the DNS cache.
2. Bring Tailscale down and up again, only when it was connected and someone is logged in at the console. It runs the app's CLI as that user with no flags, so your Tailscale settings stay.
3. Turn the network service that carries the default route off and on: Wi-Fi, or another service such as iPhone USB tethering. It skips this step when the default route goes through a tunnel, such as a Tailscale exit node, or when no single service matches.

A captive portal or a policy page answers the HTTP check with its own page; the daemon logs that and repairs nothing. When every step fails, the daemon stops trying on that network and only checks until the network changes again. It never restarts an app, and it never touches Endpoint Protector or Defender.

Each daemon run has a 25-second budget. When it runs out, the next run continues the unfinished ladder. A failed off/on or down/up pair leaves a restore record: physical services are restored first, and a pending Tailscale reconnect does not block the physical repair it may need.

The log is `/var/log/network-recovery.log`, rotated by `newsyslog`. Each line names the episode by a short hash, never by a network name or address, so you can attach it to an issue as it is. Newly launched Claude Code sessions on such a host get `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=60000` through both shell exports and the macOS GUI environment. Relaunch T3 Code after applying to pick it up. A stream that stalls during a switch can then time out after a minute; retry once connectivity returns. Codex keeps its default 300-second stream timeout. To turn the feature off, remove the trait from `hosts/<host>/default.nix` and apply; this also removes the managed GUI timeout, while preserving a different value you set yourself.

## Containers

A Mac runs containers in one Podman machine, `podman-machine-default`: a rootful Fedora CoreOS VM on the libkrun provider with 4 CPUs and an 8 GiB memory cap. Every apply, bootstrap included, creates it when it is missing, and a launch agent starts it at login and whenever it stops. No app needs launching and no account signs in.

- **Memory.** 8 GiB is a cap, not a reservation. The VM holds host memory only while the guest uses it, and libkrun hands pages the guest frees back to macOS. macOS reclaims them lazily, so Activity Monitor can keep showing the old size until memory gets tight. Changing the cap or the CPUs in `home/h82/dev/containers.nix` reaches the existing machine on the next apply: the apply stops the machine, changes it, and the launch agent starts it again.
- **minikube.** On a production output, a second launch agent waits until the machine answers, then starts the `minikube` cluster on the Podman driver with containerd, 4 GiB, and 2 CPUs. A failed start is retried every minute; its log is `~/Library/Logs/minikube.log`. A bootstrap output starts no cluster. A cluster that stops mid-session, for example after the machine restarts, comes back at the next login or with `minikube start`.
- **docker.** `docker` is a link to `podman`, as on NixOS, and `DOCKER_HOST` names the machine's API socket under the per-user temporary directory, for shells and for apps launched from Finder or the Dock. Testcontainers works with no other setting.
- **Registry credentials.** `~/.config/containers/auth.json` maps `ghcr.io`, `registry.gitlab.com`, and `registry.jpi.app` to `docker-credential-sops`, so `podman pull` and `docker pull` fetch private images with no login (`secrets/README.md` lists the required `read:packages` and `read_registry` token scopes). `docker.io` pulls stay anonymous. A Docker API client that pulls a private image without sending credentials itself makes the VM look for the helper, which only the Mac has, so that pull fails.
- **Other machines.** The configuration manages only `podman-machine-default`, and every apply deletes any other Podman machine. Create containers, not machines.

### Moving off OrbStack

A Mac set up before this change still has OrbStack installed: the apply no longer lists the cask, and Homebrew cleanup is `"none"`, so nothing removes it. When you no longer need its containers and images, remove it with its data:

```sh
brew uninstall --zap orbstack
```

`~/.docker/config.json` stays behind and is harmless: `docker` is Podman now, which reads `auth.json` instead.

## App notes

- VSCodium's user directory is `~/Library/Application Support/VSCodium/User`. Its keybindings file is a read-only store link; add a keybinding to `home/h82/dev/vscodium.nix` instead.
- The T3 Code desktop app is the flake's pinned nightly, `T3 Code (Nightly).app`. A launch agent sets `T3CODE_DISABLE_AUTO_UPDATE=1` at login, so the app does not update itself off the pin.
- An app added to the NixOS user environment needs a macOS decision in `modules/shared/darwin-apps.nix`: a cask, a Nix package, or a reason to leave it out. The `darwin-config` check fails without one.
- T3 Code finds the Android SDK at `~/Library/Android/sdk` even when started from the Dock or Finder, where `ANDROID_HOME` is not set. The `emulator` in that tree sets `ANDROID_HOME` and `ANDROID_SDK_ROOT` itself before it starts the store emulator, so an AVD boots from T3 Code's Device panel.

### Mobile devices

The option `my.mobileDevices`, in `home/h82/dev/mobile-devices.nix`, lists the iOS Simulators and Android Virtual Devices (AVDs) a Mac gets. The default list contains only one `pixel_10_pro` AVD. iOS simulators and runtimes are left to Xcode unless you explicitly add an iOS entry. Previously created simulators, including `iPhone 18 Pro (iOS 27.0)`, remain; seeing them after an apply is expected. Each entry has three fields:

- `platform`: `"ios"` or `"android"`.
- `model`: for iOS, a device type name from `xcrun simctl list devicetypes`, such as `iPhone 18 Pro`; for Android, a device id from `avdmanager list device -c`, such as `pixel_10_pro`.
- `version`: optional. For iOS, an iOS version such as `"27.0"`; left out, it is the newest installed iOS Simulator runtime that supports the model, which is usually the newest SDK's; a runtime that supports only some models, such as Xcode 27.1's iOS 27.1 runtime, which supports only the iPhone Duo, is passed over for the others. When no installed runtime supports the model, the device is skipped with a message: install an older iOS Simulator runtime in Xcode's Components settings, or set `version`, and apply again. For Android, a pinned API key from `packages/android-sdk-repo.json`, such as `"36"` or `"37.0"`; left out, it is the newest pinned API level.

Every apply, bootstrap included, runs `mobile-devices` as your user and creates each listed device that does not exist yet. The name carries the version: an iOS Simulator is named `<model> (iOS <version>)`, such as `iPhone 18 Pro (iOS 27.0)`, with the runtime's major and minor version when the entry gives none, and an AVD `<model>_API_<api>`, such as `pixel_10_pro_API_37.0`. A device with that name is left as it is. With an explicit iOS entry targeting the newest SDK, the apply downloads that SDK's runtime first if it is missing. It downloads no other iOS version, so an entry pinned to an older iOS version whose runtime is not installed is skipped with a message. A device that cannot be created is reported and the apply continues.

To add a device, add an entry to the option's `default` list in `home/h82/dev/mobile-devices.nix` and apply. These two entries add an iPad on the newest iOS and a Pixel on API 36:

```nix
{
  platform = "ios";
  model = "iPad Pro 13-inch (M5)";
}
{
  platform = "android";
  model = "pixel_10_pro";
  version = "36";
}
```

The apply never deletes, erases, or renames a device. A device you remove from the list, or one you created by hand, stays. For explicit unversioned iOS entries, an App Store upgrade of Xcode can cause the next apply to create the listed devices on a newer compatible runtime; existing devices and runtimes stay. Likewise, an unversioned Android entry gets a new AVD when the SDK pin gains a newer API level. Each iOS runtime takes about 8 GB. Remove what you no longer need by hand:

```sh
xcrun simctl list devices            # names and UDIDs
xcrun simctl delete <udid>
xcrun simctl runtime list            # installed runtimes and their identifiers
xcrun simctl runtime delete <identifier>
avdmanager list avd -c               # AVD names
avdmanager delete avd -n <name>
```

AVDs live in `~/.android/avd` and name their system image by its SDK path. When the pin drops an API level, the AVDs for that level no longer boot; delete them.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| The first apply stops on unexpected files in `/etc` | A file the installer wrote is still in place. Move it aside as step 3 does, then apply again. |
| `nix: command not found` in a new terminal during setup | `/etc/bashrc` and `/etc/zshrc` are moved aside and nix-darwin has not replaced them yet. Run `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`. |
| `nr: running the bootstrap generation; …` | A bare `nr switch` will not move a bootstrap generation to production. Recover the identity, then run the `nr switch --host` command the message names, or reapply with `nr switch --bootstrap`. |
| `nr: no age identity at …` | The identity is not recovered yet. Run the `recover-age-identity` command the message names, from the clone. |
| `… is not owned by …`, `… must have mode 0600`, or `cannot decrypt …` during activation | The identity file has the wrong owner or mode, or it is not this host's. Recover it again with the same command. |
| `nr: not inside a git repository; …` | `nr` was run outside the clone. `cd` into it, or pass `--flake-dir <path>`. |
| `docker` or `podman` reports that the connection is refused, while `podman machine list` shows the machine running | gvproxy, the machine's network helper, died. Run `podman machine stop`; the launch agent starts the machine again within a minute. |
| The Mac stays offline after a network switch even with the network recovery trait | Read the last lines of `/var/log/network-recovery.log`. An exhausted episode means every step failed on that network; turn Wi-Fi off and on by hand. A captive or policy result means the network answered with its own page; sign in to the portal. |
| The first apply stops in `podmanMachines` | `podman machine init` could not download the machine image. Apply again once the network is back. |
| The second apply aborts in `copyApps` | The terminal lacks the App Management permission, or the apply runs over SSH. See step 8. |
| The apply stops with `Existing file '…/Library/Android/sdk' would be clobbered` | An SDK, usually Android Studio's, is a real directory at `~/Library/Android/sdk`, where Home Manager links the pinned SDK. Run `mv ~/Library/Android/sdk ~/Library/Android/sdk.before-nix-config` and apply again. Point Android Studio at the linked SDK, or delete the old one once nothing uses it. |
| `mobile-devices` prints `simctl could not list device types, so the iOS Simulators were skipped` after `CoreSimulator detected version change` | An Xcode upgrade left the old CoreSimulatorService loaded. The helper tries the listing twice, because the first call replaces the service; when both fail, run `xcrun simctl list devicetypes` once and apply again. |
| The apply prints `xcode: App Store install failed; sign in to the App Store …`, and `mobile-devices` reports that the iOS Simulators were skipped | The App Store is not signed in, so the apply skipped Xcode and the iOS Simulators and set up everything else. Open the App Store, sign in with your Apple Account, and apply again. `xcode: App Store upgrade failed; …` has the same fix; the installed Xcode stays at its version until then. |
| The apply prints `kakaotalk: App Store install failed; sign in to the App Store …` or `flighty: App Store install failed; …` | The App Store is not signed in, so the apply skipped that app. Sign in to the App Store and apply again. |
| The apply prints `kakaotalk: App Store upgrade failed; …` or `flighty: App Store upgrade failed; …` | Either the App Store is not signed in, or the app in `/Applications` was installed from a download rather than the App Store, which `mas` cannot upgrade. Sign in to the App Store, or delete the app so the next apply installs it from the App Store. |
| The apply prints `kakaotalk: cannot resolve the ids of …` or `flighty: cannot resolve the ids of …` | `system.primaryUser`, which comes from `my.user.name` in the host's `default.nix`, does not name an account on this Mac. Fix the account name and apply again. |

## Verification

The repository checks for macOS evaluate the fixture host on Linux and build it on CI's `macos-15` runner; none of them activates a Mac. An activation that exits 0 is not proof that every step applied, so confirm the state each step names on the Mac after first setup and report hardware results separately from repository checks.

## Losing or retiring the Mac

The age identity and SSH key are plaintext on the Mac's disk, so treat everything it could decrypt as exposed. Revoke its SSH key, remove its recipient, and rotate the tokens as [compromise or decommission of a host](recovery.md#compromise-or-decommission-of-a-host) describes.
