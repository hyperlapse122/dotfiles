# Fedora Setup and Readiness

Use native Fedora KDE Plasma Desktop on amd64 (`x86_64`), the dnf-based edition, at release 45 or later. Fedora 45 is the validated release. An older release is unsupported. A newer release is supported, and the readiness report marks it as not yet validated until the owner validates it and raises `VALIDATED_RELEASE` in `scripts/linux-platform.py`. Fedora Kinoite and other atomic desktops, other Fedora editions and spins, arm64 hosts and Ubuntu are unsupported. The host check requires `ID=fedora`, `VARIANT_ID=kde`, no ostree boot and RPM architecture `x86_64`; a Fedora installation that added Plasma to another edition keeps that edition's `VARIANT_ID` and is rejected. The repository never upgrades the installed OS and does not look up the latest Fedora release over the network.

The functional baseline is the current managed macOS environment plus local minikube. Windows-only capabilities, Windows SDKs, Xcode and Apple SDKs are excluded. Installed packages do not establish working desktop, hardware, account or workload behavior. No native Fedora KDE GUI, hardware, authentication, build or minikube acceptance has run on the macOS implementation host. Keep the Windows machine recoverable until the owner completes the checks below and accepts the recorded limitations.

## Back Up Windows Before Erasing Anything

The owner performs OS installation and account approvals. Save projects, uncommitted work, local databases, VM data, application documents, browser profiles/bookmarks and account recovery codes to verified external storage. Export Windows-specific settings needed for reference. Preserve BitLocker recovery material and installation/recovery media. Inventory software and organization access before erasing the disk.

Back up GPG public keys, required secret-key backups or hardware-key recovery material, ownertrust records, SSH keys and their passphrases using the existing secure process. Hardware-key stubs alone are not a private-key backup. Confirm access to 1Password, its recovery material and required second factors from another device. Test restoring representative files and unlocking the required identities. Keep these backups outside the repository; never include credentials in migration evidence.

## Verify and Install the OS

Download the Fedora KDE Plasma Desktop live ISO for x86_64 from the [Fedora KDE download page](https://fedoraproject.org/kde/download), together with its `CHECKSUM` file. For Fedora 45 the checksum file is named `Fedora-KDE-Desktop-45-<compose>-x86_64-CHECKSUM`, where `<compose>` is the compose number of that image. Do not substitute Kinoite, another spin or another architecture.

Follow [Fedora's verification procedure](https://fedoraproject.org/security) on the existing trusted computer. Download the Fedora signing keys, verify the signature on the checksum file, then verify the ISO against it. A matching checksum without a valid signature on the checksum file is insufficient. In the download directory on a trusted Unix shell:

```sh
curl -O https://fedoraproject.org/fedora.gpg
gpgv --keyring ./fedora.gpg Fedora-KDE-Desktop-45-*-x86_64-CHECKSUM
sha256sum --ignore-missing -c Fedora-KDE-Desktop-45-*-x86_64-CHECKSUM
```

Require a good signature from a Fedora key and `OK` for the downloaded ISO. On Windows, `Get-FileHash -Algorithm SHA256` provides the digest to compare with the ISO's entry in the checksum file; signature verification still requires GPG. Record the release, the ISO and checksum filenames, the signing-key fingerprint that `gpgv` reports and the digest, with no private material. For a later Fedora release, use that release's files.

Write verified installation media and boot it manually. Confirm the selected disk and backups before the owner approves partition changes. Test networking, GPU/display outputs, audio input/output, keyboard layout, Bluetooth, camera, storage and suspend/resume in the live session. Resolve Secure Boot/MOK approval using Fedora's supported process. This repository does not install GPU drivers: NVIDIA driver provisioning is tracked in [issue #125](https://github.com/hyperlapse122/dotfiles/issues/125), and until then the owner installs GPU drivers by hand. After installation, apply OS updates manually with `sudo dnf upgrade --refresh`, reboot, log into the native Plasma session and repeat peripheral tests. Plasma 6.8 on Fedora 45 provides a Wayland session only. Record the driver and session choices; WSL, a container or a headless CI runner cannot supply this acceptance.

## Acquire an Inspected Checkout

System `python3`, a normal login account and sudo access are required. If Git is absent, download the repository source archive for a reviewed immutable commit from GitHub using the browser, extract it outside personal configuration directories, and inspect the archive contents. Record that commit. Do not run a standalone downloaded bootstrap file: the Fedora entry points require the inspected source tree. Provision from that tree:

```sh
sh ./provision-fedora.sh "$PWD"
```

This runs the host check and installs only first-use prerequisites that are missing: CA certificates, curl, Git, GnuPG and archive tools through dnf, and mise from the mise author's COPR repository `jdxcode/mise`, whose signing key is pinned by fingerprint. It does not prepare a checkout, register a source, apply personal files or start a runtime. Restore a missing system Python through the OS before provisioning. If mise is already installed it is retained. If you enabled the mise or Ghostty COPR yourself with `dnf copr enable`, remove that repository file before applying: application manages both repositories with pinned signing keys and stops on a file it did not write. Then ensure it is available on PATH in a fresh shell.

Prepare the permanent standalone checkout separately:

```sh
sh ./bootstrap-fedora.sh "$HOME/src/github.com/hyperlapse122/dotfiles"
cd "$HOME/src/github.com/hyperlapse122/dotfiles"
```

Bootstrap runs the host check, clones the repository when the destination is missing or empty, checks an existing checkout's origin, trusts its mise configuration, installs locked development tools and runs the hook-free source verification task. No private-key access is required. If working from a reviewed branch rather than main, select that revision in the permanent checkout before preparing it with `mise trust`, `mise install` and `mise run bootstrap`. Verify the origin and intended revision before trusting code.

For another worktree, use `mise trust` and `mise install` in that worktree. Preparation must leave personal configuration unchanged and must not decrypt, authenticate or install host applications. Project preparation remains bound to the hook-free `.chezmoi-bootstrap.toml`.

## Register, Establish Key Access, and Apply Explicitly

From the permanent Linux checkout, inspect any existing chezmoi configuration and confirm that its source and working tree refer to this checkout. Resolve a conflicting source deliberately before continuing. Initialize registration without applying destination files:

```sh
mise exec -- chezmoi --source "$PWD" init
```

This writes the personal chezmoi configuration and selects the current working tree. It is an explicit registration step, separate from `mise install`. Do not use `init --apply`. A later plain `chezmoi apply` uses the registered checkout; `mise run apply` uses the current worktree source.

Connect the existing GPG hardware key or securely restore the intended private-key access. Verify fingerprints against the trusted backup and repository recipient. Restore ownertrust only for keys whose ownership has been verified; do not assign global trust. Confirm the intended GPG home and the Qt pinentry using the [Git/GPG guide](../guides/git-and-gpg.md). A public recipient import does not establish decryption access. Do not export secrets into command arguments, logs or tracked files.

If GPG or the Qt pinentry is missing, install these Fedora prerequisites explicitly before attempting a decrypting preview or application:

```sh
sudo dnf install -y gnupg2 pinentry-qt
```

This is an owner-approved host action, separate from worktree preparation. The application package declaration also maintains these tools. Resolve private-key access before proceeding; a missing key fails closed. In particular, review an existing `~/.ssh/id_ed25519` before the managed encrypted identity can replace it.

Once key access is available, inspect pending changes privately and apply:

```sh
mise exec -- chezmoi --source "$PWD" diff
mise run apply
```

Diffs can contain decrypted values; do not publish or capture them. Application installs the missing Fedora packages declared in `home/.chezmoidata/linux.yaml`, the vendor applications from their signed repositories, Ghostty, rootless Podman with its Docker compatibility packages, managed CLIs, harness integrations, shell, fonts and configuration. Each third-party repository is written only after its downloaded signing key matches the pinned fingerprint, and a package installs only when dnf resolves it from its declared repository. Application stops before changing packages when a Docker engine package (`docker-ce`, `docker-ce-cli`, `moby-engine` or `docker`) is installed, or when an existing repository file conflicts with a declared one; resolve either by hand. Application does not start a runtime, the Podman socket or a cluster, enable startup at login, or enable user linger. Existing unrelated services and resources remain owned by their active tasks.

Complete native sudo, login-shell and key prompts. If application fails, resolve that stage and rerun; do not bypass credential storage checks or decrypt into a temporary tracked file. Reapply after success to check convergence and preservation of unrelated settings. Log out of every desktop session, log back in and reopen Ghostty.

On a Fedora release newer than the validated one, a vendor or COPR repository may not serve that release yet. Application then fails at that repository and names the package with no candidate. Wait for the vendor, or record the application as unavailable on that release.

## Capability Inventory Against macOS

The inventory is based on `home/.chezmoidata/macos.yaml`, `personal-apps.json`, the shared harness/skill declarations, shell/font/security sources and `macos-dock.json`. A Dock reference does not mean this repository installs the referenced app. Record each row as accepted, excluded or unresolved in the owner's native acceptance record; do not silently omit unavailable work.

| macOS-managed capability | Fedora KDE mapping and required evidence |
|---|---|
| Homebrew host provisioning; aria2 | dnf host package provisioning from Fedora and fingerprint-pinned vendor repositories; `aria2c` download in a normal shell. Homebrew itself is not required. |
| Apple `container` | Rootless Podman, with `podman-docker` for a `docker` command and `podman-compose` for compose; see [Containers](#containers) and the explicit minikube proof below. No Docker engine is installed. Apple virtualization APIs are OS-specific. |
| Chrome, 1Password GUI/CLI | Vendor RPM packages from the vendors' signed repositories; launch, browser integration and vault unlock checks below. |
| Ghostty | Package from the community COPR `scottames/ghostty`; see the [terminal guide](../guides/terminal.md#ghostty-package-source) for the exposure this source carries, and the terminal checks below. |
| ChatGPT desktop | OpenAI's signed RPM repository; open and authenticate the app. OpenAI's documentation lists Fedora 43 and 44, so support for Fedora 45 is unverified. Linux computer use is unavailable. |
| Claude desktop | Not installed on Fedora: Anthropic ships only an apt package. Tracked in [issue #124](https://github.com/hyperlapse122/dotfiles/issues/124). Use Claude in the browser or Claude Code until then. |
| T3 desktop and launcher | The vendor's digest-verified AppImage, extracted to `~/.local/share/dotfiles/t3-code` without sudo, with a desktop entry in `~/.local/share/applications`; open a project, connect the configured providers and complete a small authorized task. Whether the extracted app runs under Fedora's user-namespace sandbox is unverified. |
| Bun, Node, Claude Code, Codex, Antigravity CLI, ghq, gh, glab, pi, Grok | Shared personal application declarations and user PATH; verify each outside this checkout and complete authenticated work where needed. |
| Native harness instructions, CE and shared writing skills | Claude, Codex, Antigravity, pi and Grok must each discover their own baseline, native pinned CE and each shared skill exactly once; invoke CE while authenticated. T3 adds its selected launch instructions without duplicating baseline state. |
| macOS registry helper | `docker-credential-secretservice` using the existing Linux Secret Service, configured by `scripts/container-auth.py` for both the Docker client file and Podman's `containers/auth.json`; verify enrolled accounts without exposing values. |
| zsh, Prezto and completions | Shared managed zsh files and pinned Prezto/completion assets; fresh login shell, command completion and no duplicated initialization. |
| JetBrains Mono, Pretendard, D2Coding and Jetendard/Nerd Font assets | Shared user fonts; verify fontconfig and native Latin/Korean rendering in Ghostty and desktop apps. |
| Git identity/signing, GPG, SSH and account credentials | Qt pinentry, existing keys, signed commit in a disposable repository, authorized Git fetch/API operations, selected SSH identity and secure credential storage. |
| Native .NET 8/10, Rust, C/C++, CMake, Ninja, Python, PowerShell and vcpkg | GNU Linux amd64 tools through explicit `linux-build`; compile, run and check native executable architecture outside the repository. Xcode, Apple SDKs and Windows SDKs are excluded. |
| Optional enterprise CA and Node system trust | Manually approved Linux trust plus `NODE_USE_SYSTEM_CA=1`; verify TLS from a new desktop session when required. No certificate or organization enrollment is supplied. |
| macOS Dock selection and launch workflow | The Plasma application launcher, task manager and System Settings provide native launch workflows. The repository does not reproduce the Dock layout. Use the reference mappings below. |

.NET 8 [reaches end of support on November 10, 2026](https://devblogs.microsoft.com/dotnet/dotnet-8-9-end-of-support/). It remains installed for the requested compatibility workload; installation does not extend security support. Move daily projects to supported .NET 10 and record any remaining .NET 8 dependency before workstation acceptance.

See [Claude Desktop's supported Linux distributions](https://support.claude.com/en/articles/10065433-install-claude-desktop) and [ChatGPT's Linux preview limitations](https://learn.chatgpt.com/docs/linux/linux-app). Recheck vendor support before relying on a feature; package installation does not establish macOS feature parity.

### Containers

Podman runs containers under the owner's account with no system-wide service and no root-owned socket. `podman-docker` installs a `docker` command that runs Podman, and `podman-compose` provides compose. Buildx-only features are not guaranteed.

A project that talks to the Docker API needs Podman's Docker-compatible socket. It is the stock user unit `podman.socket`, and it stays disabled. Start it for one project session:

```sh
systemctl --user start podman.socket
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock
```

Stop it when the session ends:

```sh
systemctl --user stop podman.socket
```

The managed shell does not export `DOCKER_HOST`, and nothing starts the socket at login. Existing Docker images, volumes and credentials are not migrated into Podman.

### Dock-Only References

| Existing Dock references | Native Linux/browser option or explicit limitation |
|---|---|
| App Store | Discover and dnf for Linux applications; this repository does not manage Flatpak. Apple purchases/apps do not transfer as native Linux apps. |
| Mail, Calendar, Reminders, Notes | Existing account's browser services, including iCloud web where supported; verify each required workflow. Apple-only desktop integrations remain unavailable. No account is enrolled automatically. |
| Messages, FaceTime, Phone | No managed native equivalent for Apple messaging/calling continuity. Record the limitation and retain an appropriate Apple device if needed. |
| Photos, Music | Existing web services and Linux media applications can cover files/playback; verify library export, formats and rights separately. Apple library sync and service parity are not claimed. |
| iPhone Mirroring | No managed Linux equivalent; explicit unresolved Apple continuity limitation. |
| Microsoft Outlook, Teams, Word, Excel, PowerPoint | Organization-approved Microsoft 365 browser applications; verify tenant sign-in, document fidelity, meetings, camera/audio and required features. Desktop-only add-ins, macros or offline workflows may remain unavailable. Organization provisions access; the repository installs no organization app or tenant enrollment. |
| Chrome, Ghostty, T3, ChatGPT | Already installed through their application owners; verify Plasma launchers and account behavior. Dock references do not install a second copy. |
| Claude | No desktop app on Fedora; see the inventory row above. |

## Native Acceptance

Keep a private record of host/revision, date, exact commands, exit statuses, sanitized observations and unresolved limitations. Never attach decrypted diffs, tokens, wallet contents or full authentication output. An unmet prerequisite blocks acceptance; an unperformed native check remains pending. Mark optional capabilities not applicable only with the reason.

### Desktop, Terminal and Hardware

Repeat the hardware tests after driver updates and reboot. Follow the [terminal checklist](../guides/terminal.md#desktop-acceptance-checklist), including System Settings > Default Applications, Ctrl+Alt+T, Dolphin's Open Terminal Here action, a temporary `Terminal=true` desktop launcher and working-directory forwarding with Ghostty already running. Confirm the effective login shell is zsh, Prezto loads once, completions work, managed tools are on PATH, and the four font families render Latin and Korean. Remove only the temporary launcher/directory created for this check.

Launch Chrome, 1Password, ChatGPT and T3 from the desktop. Complete account approval manually, test browser/vault integration, and record any unavailable feature from the inventory, including whether ChatGPT installed on this Fedora release and whether the extracted T3 app started. Package and desktop-entry presence cannot replace these observations.

### Credentials and Trust

Follow the [Linux credential acceptance procedure](../guides/secrets-and-authentication.md#fedora-native-credential-acceptance). Confirm the actual Secret Service owner and default alias before testing storage. A Plasma session normally provides the Secret Service through KWallet (`ksecretd`), but an installed package alone does not prove it owns the service. Use the already configured provider; do not start a second daemon or migrate wallets automatically. Complete a harmless synthetic roundtrip and remove only its test entries.

Verify signed Git commits in a disposable local repository, authorized GitHub/GitLab operations, SSH with the selected identity and enrolled registry access. Perform OAuth, PIN, password and wallet approvals interactively. Test optional CA trust from a fresh desktop session using the [system CA guide](../guides/system-ca.md). Keep credential values out of reports.

### Native Build Proof

From the prepared checkout, explicitly provision tools:

```sh
mise run linux-build
mise run linux-kubernetes
```

Neither task starts a runtime or cluster. Open a fresh Ghostty login shell, change to an empty directory outside the repository and confirm `command -v dotnet rustc cargo cc c++ cmake ninja python pwsh vcpkg minikube kubectl`. Check `dotnet --list-sdks` includes 8 and 10, `cc -dumpmachine` reports Fedora's GCC target `x86_64-redhat-linux`, and `rustc --version --verbose` reports `x86_64-unknown-linux-gnu`. Then invoke the actual checkout path, outside `mise exec` so project activation cannot hide broken user discovery:

```sh
python3 "$HOME/src/github.com/hyperlapse122/dotfiles/tests/smoke_linux_build_environment.py" \
  --home "$HOME" --report /tmp/dotfiles-linux-build.json
```

Require exit zero and `status: passed`: C++, Rust, .NET 8/10 and CMake/Ninja with a real vcpkg fmt dependency must compile and execute native x86-64 output. The smoke uses temporary projects and removes them. Inspect its report privately; it is separate from read-only readiness. If prerequisites fail, rerun explicit provisioning after repair, then repeat from a new external-directory shell.

### Explicit Container and Minikube Proof

Only run this when ready for actual development testing. The proof runs minikube on rootless Podman, a driver minikube documents as experimental. It requires the native non-root systemd user session, cgroup v2, at least 65536 subordinate IDs for the account in both `/etc/subuid` and `/etc/subgid`, and the `cpu`, `memory` and `pids` cgroup controllers delegated to the user session. Missing `cpuset` or `io` delegation is reported as a warning only. Check the delegated controllers:

```sh
cat "/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
```

When a required controller is missing, the proof exits `2` and names it. The repository does not change system configuration for this. The owner-approved OS step is to create `/etc/systemd/system/user@.service.d/delegate.conf` with this content:

```ini
[Service]
Delegate=cpu cpuset io memory pids
```

Then run `sudo systemctl daemon-reload` and log in again. Repair missing subordinate-ID allocations through the OS administrator. Do not enable the Podman socket or user linger for the proof.

```sh
python3 "$HOME/src/github.com/hyperlapse122/dotfiles/tests/smoke_linux_minikube.py" \
  --report /tmp/dotfiles-linux-minikube.json
```

The smoke points Podman at storage, run-state and network configuration files in its own temporary directories, and uses an isolated kubeconfig and minikube profile. It verifies image build/run, minikube 1.39.0 with kubectl 1.37.2 and Kubernetes 1.37.0, workload deployment, host HTTP access, and deletion. It never uses the owner's default container storage or kubeconfig. Exit `0` means proof and cleanup passed; `1` means proof failed/interrupted; `2` means unavailable prerequisites; `3` means cleanup failed. Read both the proof status and the `cleanup` section before accepting it.

A failed or unavailable proof does not establish readiness. If the proof cannot pass on rootless Podman on the owner's host, record minikube as an unresolved limitation in the acceptance record. No Docker engine or other runtime is installed in its place.

For cleanup failure or forced interruption, retain the report privately. Identify its exact `profile`, `state`, `runtime_state`, `storage_conf`, `containers_conf` and `graphroot` paths and the `remaining_resources` inventory, and confirm ownership before recovery. Reconstruct the isolated environment from those paths: set `CONTAINERS_STORAGE_CONF` and `CONTAINERS_CONF` to the reported files, `MINIKUBE_HOME` to `minikube` under the state directory and `KUBECONFIG` to `kubeconfig` under it. In that environment delete the owned profile with `minikube delete -p`, then enumerate and remove the containers, images, networks other than Podman's built-in `podman` network, and volumes, and verify zero remain. Remove the storage root with `podman unshare rm -rf --` followed by the reported `graphroot`, because rootless layer files belong to subordinate IDs, then remove the remaining state and run-state directories. Never globally prune, reset Podman, delete other task data or touch the default storage. If ownership or deletion cannot be established, report the remaining resources and reason; do not claim cleanup or retry over abandoned resources.

Check host disk-space reclamation separately from object deletion. The smoke records free bytes before/after without disk compaction. No shared-runtime stop or disk reset is authorized by this procedure.

## Read-Only Readiness Report

The public inspection command, from the repository root, is:

```sh
python3 scripts/linux-readiness.py --json
```

Omit `--json` for text output. Exit `1` means unsupported host or missing required tools, packages or managed files. Exit `2` means no blocking prerequisite was found but native checks remain pending. Exit `0` requires every reported check to pass. Failures take precedence over pending checks. On a Fedora release newer than the validated one, the `Fedora release` check stays pending until the owner validates that release and raises the validated release.

The report reads the RPM package inventory and file/PATH presence. It never reads credential values, invokes harnesses, decrypts, authenticates, runs Podman or the `docker` command, contacts Secret Service, starts a daemon, creates a cluster or writes personal state. Its JSON contains fixed diagnostic text, not captured command output or environment values. Session metadata is evidence of a KDE Plasma graphical login, not desktop acceptance; a different desktop session on a supported host leaves the `KDE session` check pending. Missing GUI/hardware/account/workload evidence stays pending even when every package is installed.

There is no acceptance flag or report-import shortcut. Native evidence is reviewed separately against every inventory row and checklist, so inspection alone continues to return pending after prerequisites pass. A prepared checkout, configured workstation and verified daily-work environment are three different milestones. Replace the Windows machine only after the owner accepts native evidence and every remaining limitation.
