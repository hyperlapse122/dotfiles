# Ubuntu Studio Setup and Readiness

Use native Ubuntu Studio 26.04 LTS on amd64, installed from 26.04.1 or a later 26.04 point release. Other Ubuntu flavors, earlier LTS lines, ARM hosts and headless sessions are unsupported workstation targets. The next Studio LTS replaces this baseline only after validation; the repository never upgrades the installed OS automatically.

The functional baseline is the current managed macOS environment plus local minikube. Windows-only capabilities, Windows SDKs, Xcode and Apple SDKs are excluded. Installed packages do not establish working desktop, hardware, account or workload behavior. No native Studio GUI, hardware, authentication, build or minikube acceptance has run on the macOS implementation host. Keep the Windows machine recoverable until the owner completes the checks below and accepts the recorded limitations.

## Back Up Windows Before Erasing Anything

The owner performs OS installation and account approvals. Save projects, uncommitted work, local databases, VM data, application documents, browser profiles/bookmarks and account recovery codes to verified external storage. Export Windows-specific settings needed for reference. Preserve BitLocker recovery material and installation/recovery media. Inventory software and organization access before erasing the disk.

Back up GPG public keys, required secret-key backups or hardware-key recovery material, ownertrust records, SSH keys and their passphrases using the existing secure process. Hardware-key stubs alone are not a private-key backup. Confirm access to 1Password, its recovery material and required second factors from another device. Test restoring representative files and unlocking the required identities. Keep these backups outside the repository; never include credentials in migration evidence.

## Verify and Install the OS

Obtain the latest **26.04 point release** amd64 desktop ISO from the [official Studio release directory](https://cdimages.ubuntu.com/ubuntustudio/releases/26.04/release/), reached through the [Studio download page](https://ubuntustudio.org/download/). At initial validation the filename is `ubuntustudio-26.04.1-desktop-amd64.iso`. Download `SHA256SUMS` and `SHA256SUMS.gpg` from the same directory. Do not substitute the generic Ubuntu Desktop image or follow a newer LTS automatically.

Follow [Ubuntu's image verification procedure](https://documentation.ubuntu.com/security/software-integrity/image-verification/) on the existing trusted computer. Authenticate the Ubuntu image-signing public key against Ubuntu's published fingerprint before using it. Verify the detached signature, then the exact ISO checksum; a matching checksum without authenticated signing-key evidence is insufficient. In the download directory on a trusted Unix shell:

```sh
gpg --verify SHA256SUMS.gpg SHA256SUMS
sha256sum ubuntustudio-26.04.1-desktop-amd64.iso
```

Require a valid signature from the authenticated Ubuntu image-signing key and compare the resulting digest with that filename's entry in the signed manifest. On Windows, `Get-FileHash -Algorithm SHA256` provides the checksum; signature verification still requires GPG. Record release, filename, signing fingerprint and digest, with no private material. For later 26.04 point releases, use that exact filename and its matching signed manifest. `/etc/os-release` records the release line, not reliable proof of the installation-media point release.

Write verified installation media and boot it manually. Confirm the selected disk and backups before the owner approves partition changes. Test networking, GPU/display outputs, audio input/output, keyboard layout, Bluetooth, camera, storage and suspend/resume in the live session. Resolve required proprietary drivers and Secure Boot/MOK approval using Ubuntu's supported process. After installation, apply OS security updates manually, reboot, log into native KDE Plasma and repeat peripheral tests. Record the driver and session choices; WSL, a container or a headless CI runner cannot supply this acceptance.

## Acquire an Inspected Checkout

System `python3`, a normal login account and sudo access are required. If Git is absent, download the repository source archive for a reviewed immutable commit from GitHub using the browser, extract it outside personal configuration directories, and inspect the archive contents. Record that commit. Do not run a standalone downloaded bootstrap file: the Studio entry points require the inspected source tree. Provision from that tree:

```sh
sh ./provision-ubuntu-studio.sh "$PWD"
```

This validates host flavor/release/architecture and installs only first-use prerequisites: missing CA certificates, curl, Git, archive tools and mise through the signed repository configured by Ubuntu's `extrepo` mechanism. It does not prepare a checkout, register a source, apply personal files or start a runtime. Restore a missing system Python through the OS before provisioning. If mise is already installed it is retained; ensure it is available on PATH in a fresh shell.

Prepare the permanent standalone checkout separately:

```sh
sh ./bootstrap-ubuntu-studio.sh "$HOME/src/github.com/hyperlapse122/dotfiles"
cd "$HOME/src/github.com/hyperlapse122/dotfiles"
```

Bootstrap checks the existing checkout's origin, trusts its mise configuration, installs locked development tools and runs the hook-free source verification task. No private-key access is required. If working from a reviewed branch rather than main, select that revision in the permanent checkout before preparing it with `mise trust`, `mise install` and `mise run bootstrap`. Verify the origin and intended revision before trusting code.

For another worktree, use `mise trust` and `mise install` in that worktree. Preparation must leave personal configuration unchanged and must not decrypt, authenticate or install host applications. Project preparation remains bound to the hook-free `.chezmoi-bootstrap.toml`.

## Register, Establish Key Access, and Apply Explicitly

From the permanent Linux checkout, inspect any existing chezmoi configuration and confirm that its source and working tree refer to this checkout. Resolve a conflicting source deliberately before continuing. Initialize registration without applying destination files:

```sh
mise exec -- chezmoi --source "$PWD" init
```

This writes the personal chezmoi configuration and selects the current working tree. It is an explicit registration step, separate from `mise install`. Do not use `init --apply`. A later plain `chezmoi apply` uses the registered checkout; `mise run apply` uses the current worktree source.

Connect the existing GPG hardware key or securely restore the intended private-key access. Verify fingerprints against the trusted backup and repository recipient. Restore ownertrust only for keys whose ownership has been verified; do not assign global trust. Confirm the intended GPG home and native Qt pinentry using the [Git/GPG guide](../guides/git-and-gpg.md). A public recipient import does not establish decryption access. Do not export secrets into command arguments, logs or tracked files.

If GPG or Qt pinentry is missing, install these Ubuntu prerequisites explicitly before attempting a decrypting preview or application:

```sh
sudo apt-get update
sudo apt-get install -y gnupg gpg-agent pinentry-qt
```

This is an owner-approved host action, separate from worktree preparation. The application package declaration also maintains these tools. Resolve private-key access before proceeding; a missing key fails closed. In particular, review an existing `~/.ssh/id_ed25519` before the managed encrypted identity can replace it.

Once key access is available, inspect pending changes privately and apply:

```sh
mise exec -- chezmoi --source "$PWD" diff
mise run apply
```

Diffs can contain decrypted values; do not publish or capture them. Application installs the declared native apps and rootless Docker packages from signed sources, managed CLIs, harness integrations, shell, fonts and configuration. Package provisioning suppresses service starts and restores temporary package policy/masks. It does not start a runtime or cluster, enable runtime startup at login, or enable user linger. Existing unrelated services and resources remain owned by their active tasks.

Complete native sudo, login-shell and key prompts. If application fails, resolve that stage and rerun; do not bypass credential storage checks or decrypt into a temporary tracked file. Reapply after success to check convergence and preservation of unrelated settings. Log out of every desktop session, log back in and reopen Ghostty.

## Capability Inventory Against macOS

The inventory is based on `home/.chezmoidata/macos.yaml`, `personal-apps.json`, the shared harness/skill declarations, shell/font/security sources and `macos-dock.json`. A Dock reference does not mean this repository installs the referenced app. Record each row as accepted, excluded or unresolved in the owner's native acceptance record; do not silently omit unavailable work.

| macOS-managed capability | Ubuntu Studio mapping and required evidence |
|---|---|
| Homebrew host provisioning; aria2 | Signed APT host application provisioning; `aria2c` download in a normal shell. Homebrew itself is not required. |
| Apple `container` | Native rootless Docker, Buildx and Compose; explicit isolated image build/run and minikube proof below. Apple virtualization APIs are OS-specific. |
| Chrome, 1Password GUI/CLI, Ghostty | Native Linux packages; launch, browser integration, vault unlock and terminal checks below. |
| Claude and ChatGPT desktop | Official signed Linux packages; open and authenticate each app. Linux computer use is unavailable for both; Claude dictation is unavailable. These remain vendor limitations. |
| T3 desktop and launcher | Native T3 application/launcher; open a project, connect the configured providers and complete a small authorized task. |
| Bun, Node, Claude Code, Codex, Antigravity CLI, ghq, gh, glab, pi, Grok | Shared personal application declarations and user PATH; verify each outside this checkout and complete authenticated work where needed. |
| Native harness instructions, CE and shared writing skills | Claude, Codex, Antigravity, pi and Grok must each discover their own baseline, native pinned CE and each shared skill exactly once; invoke CE while authenticated. T3 adds its selected launch instructions without duplicating baseline state. |
| macOS registry helper | `docker-credential-secretservice` using the existing Linux Secret Service; verify enrolled accounts without exposing values. |
| zsh, Prezto and completions | Shared managed zsh files and pinned Prezto/completion assets; fresh login shell, command completion and no duplicated initialization. |
| JetBrains Mono, Pretendard, D2Coding and Jetendard/Nerd Font assets | Shared user fonts; verify fontconfig and native Latin/Korean rendering in Ghostty and desktop apps. |
| Git identity/signing, GPG, SSH and account credentials | Qt pinentry, existing keys, signed commit in a disposable repository, authorized Git fetch/API operations, selected SSH identity and secure credential storage. |
| Native .NET 8/10, Rust, C/C++, CMake, Ninja, Python, PowerShell and vcpkg | GNU Linux amd64 tools through explicit `linux-build`; compile, run and check native executable architecture outside the repository. Xcode, Apple SDKs and Windows SDKs are excluded. |
| Optional enterprise CA and Node system trust | Manually approved Linux trust plus `NODE_USE_SYSTEM_CA=1`; verify TLS from a new desktop session when required. No certificate or organization enrollment is supplied. |
| macOS Dock selection and launch workflow | KDE launcher, Default Applications and task manager provide native launch workflows. The repository does not reproduce the Dock layout. Use the reference mappings below. |

.NET 8 [reaches end of support on November 10, 2026](https://devblogs.microsoft.com/dotnet/dotnet-8-9-end-of-support/). It remains installed for the requested compatibility workload; installation does not extend security support. Move daily projects to supported .NET 10 and record any remaining .NET 8 dependency before workstation acceptance.

See [Claude's Linux limitations](https://support.claude.com/en/articles/10065433-install-claude-desktop) and [ChatGPT's Linux preview limitations](https://learn.chatgpt.com/docs/linux/linux-app). Recheck vendor support before relying on a feature; package installation does not establish macOS feature parity.

### Dock-Only References

| Existing Dock references | Native Linux/browser option or explicit limitation |
|---|---|
| App Store | KDE Discover and APT for Linux applications; Apple purchases/apps do not transfer as native Linux apps. |
| Mail, Calendar, Reminders, Notes | Existing account's browser services, including iCloud web where supported; verify each required workflow. Apple-only desktop integrations remain unavailable. No account is enrolled automatically. |
| Messages, FaceTime, Phone | No managed native equivalent for Apple messaging/calling continuity. Record the limitation and retain an appropriate Apple device if needed. |
| Photos, Music | Existing web services and Linux media applications can cover files/playback; verify library export, formats and rights separately. Apple library sync and service parity are not claimed. |
| iPhone Mirroring | No managed Linux equivalent; explicit unresolved Apple continuity limitation. |
| Microsoft Outlook, Teams, Word, Excel, PowerPoint | Organization-approved Microsoft 365 browser applications; verify tenant sign-in, document fidelity, meetings, camera/audio and required features. Desktop-only add-ins, macros or offline workflows may remain unavailable. Organization provisions access; the repository installs no organization app or tenant enrollment. |
| Chrome, Ghostty, T3, ChatGPT, Claude | Already installed through their application owners; verify KDE launchers and account behavior. Dock references do not install a second copy. |

## Native Acceptance

Keep a private record of host/revision, date, exact commands, exit statuses, sanitized observations and unresolved limitations. Never attach decrypted diffs, tokens, wallet contents or full authentication output. An unmet prerequisite blocks acceptance; an unperformed native check remains pending. Mark optional capabilities not applicable only with the reason.

### Desktop, Terminal and Hardware

Repeat the hardware tests after driver updates and reboot. In KDE System Settings, verify Ghostty under Default Applications. Follow the [terminal checklist](../guides/terminal.md#desktop-acceptance-checklist), including Ctrl+Alt+T, Dolphin's Open Terminal Here, a temporary `Terminal=true` desktop launcher and working-directory forwarding with Ghostty already running. Confirm the effective login shell is zsh, Prezto loads once, completions work, managed tools are on PATH, and the four font families render Latin and Korean. Remove only the temporary launcher/directory created for this check.

Launch Chrome, 1Password, Claude, ChatGPT and T3 from the desktop. Complete account approval manually, test browser/vault integration, and record any unavailable feature from the inventory. Package and desktop-entry presence cannot replace these observations.

### Credentials and Trust

Follow the [Linux credential acceptance procedure](../guides/secrets-and-authentication.md#ubuntu-studio-native-credential-acceptance). Confirm the actual Secret Service owner and default alias before testing storage. KWallet and gnome-keyring must not be treated as interchangeable merely because one is installed. Use the already configured provider; do not start a second daemon or migrate wallets automatically. Complete a harmless synthetic roundtrip and remove only its test entries.

Verify signed Git commits in a disposable local repository, authorized GitHub/GitLab operations, SSH with the selected identity and enrolled registry access. Perform OAuth, PIN, password and wallet approvals interactively. Test optional CA trust from a fresh desktop session using the [system CA guide](../guides/system-ca.md). Keep credential values out of reports.

### Native Build Proof

From the prepared checkout, explicitly provision tools:

```sh
mise run linux-build
mise run linux-kubernetes
```

Neither task starts a runtime or cluster. Open a fresh Ghostty login shell, change to an empty directory outside the repository and confirm `command -v dotnet rustc cargo cc c++ cmake ninja python pwsh vcpkg minikube kubectl`. Check `dotnet --list-sdks` includes 8 and 10 and `rustc --version --verbose` reports `x86_64-unknown-linux-gnu`. Then invoke the actual checkout path, outside `mise exec` so project activation cannot hide broken user discovery:

```sh
python3 "$HOME/src/github.com/hyperlapse122/dotfiles/tests/smoke_linux_build_environment.py" \
  --home "$HOME" --report /tmp/dotfiles-linux-build.json
```

Require exit zero and `status: passed`: C++, Rust, .NET 8/10 and CMake/Ninja with a real vcpkg fmt dependency must compile and execute native x86-64 output. The smoke uses temporary projects and removes them. Inspect its report privately; it is separate from read-only readiness. If prerequisites fail, rerun explicit provisioning after repair, then repeat from a new external-directory shell.

### Explicit Container and Minikube Proof

Only run this when ready for actual development testing. Confirm the native non-root systemd user session, cgroup v2 and at least 65536 subordinate IDs for the account in both `/etc/subuid` and `/etc/subgid`. Repair missing allocations or driver/AppArmor support through the OS administrator; do not enable a login Docker service or linger. Do not run `docker info` during inspection: a socket may activate a daemon.

```sh
python3 "$HOME/src/github.com/hyperlapse122/dotfiles/tests/smoke_linux_minikube.py" \
  --report /tmp/dotfiles-linux-minikube.json
```

The smoke owns a transient rootless Docker service, unique socket/data/config directories, Buildx builder and isolated kubeconfig/minikube profile. It verifies image build/run, minikube 1.39.0 with kubectl 1.37.2 and Kubernetes 1.37.0, workload deployment, host HTTP access, and deletion. It never targets the user's default runtime endpoint or kubeconfig. Exit `0` means proof and cleanup passed; `1` means proof failed/interrupted; `2` means unavailable prerequisites; `3` means cleanup failed. Read both the proof status and cleanup section before accepting it.

A failed or unavailable proof does not establish readiness. For cleanup failure or forced interruption, retain the report privately. Identify its exact `endpoint`, `profile`, `unit`, remaining state paths and resource IDs, and confirm ownership before recovery. Reconstruct its isolated Docker/minikube environment from those paths; delete the owned profile and builder, enumerate and remove owned containers, images, custom networks and volumes on that endpoint, and verify zero remain. Stop only its transient service. Remove its remaining task state, using the same subordinate-ID mapping for rootless-owned layer files. Never globally prune, delete other task data or shut down a shared runtime. If ownership or deletion cannot be established, report the remaining resources and reason; do not claim cleanup or retry over abandoned resources.

Check host disk-space reclamation separately from object deletion. The smoke records free bytes before/after without disk compaction. No shared-runtime stop or disk reset is authorized by this procedure.

## Read-Only Readiness Report

The public inspection command, from the repository root, is:

```sh
python3 scripts/linux-readiness.py --json
```

Omit `--json` for text output. Exit `1` means unsupported host or missing required tools, packages or managed files. Exit `2` means no blocking prerequisite was found but native checks remain pending. Exit `0` requires every reported check to pass. Failures take precedence over pending checks.

The report reads package inventory and file/PATH presence. It never reads credential values, invokes harnesses, decrypts, authenticates, queries Docker, contacts Secret Service, starts a daemon, creates a cluster or writes personal state. Its JSON contains fixed diagnostic text, not captured command output or environment values. Session metadata is evidence of a graphical login, not desktop acceptance. Missing GUI/hardware/account/workload evidence stays pending even when every package is installed.

There is no acceptance flag or report-import shortcut. Native evidence is reviewed separately against every inventory row and checklist, so inspection alone continues to return pending after prerequisites pass. A prepared checkout, configured workstation and verified daily-work environment are three different milestones. Replace the Windows machine only after the owner accepts native evidence and every remaining limitation.

The separate [Ubuntu and Studio bootstrap consolidation follow-up](https://github.com/hyperlapse122/dotfiles/issues/120) will introduce a common `bootstrap-ubuntu.sh` entry point; that consolidation is outside this migration.
