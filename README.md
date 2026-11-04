# dotfiles

Personal environment configuration for Windows, Linux, and macOS.
Worktree preparation and applying personal settings are separate operations.
See [STRATEGY.md](STRATEGY.md) for the repository's scope.

## Bootstrap a new Windows PC

Start in Windows PowerShell 5.1 or newer on Windows 10 1809 or newer, including Windows 11.
Git, mise, and PowerShell 7 do not need to be installed first.
Internet access and permission to approve installer prompts are required.
WinGet is supplied by Windows App Installer; if it is missing, install or update [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) first.
The script requests WinGet registration when App Installer is present but its command is not registered yet.

Download the entry point from this repository and inspect it before running it:

```powershell
$bootstrap = Join-Path $env:TEMP 'dotfiles-bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/bootstrap.ps1' -OutFile $bootstrap
notepad $bootstrap
```

After reviewing it, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

The execution-policy option applies only to that child process; it does not change a persistent Windows policy.
Do not bypass organizational policy if it blocks the script.
Approve WinGet source/package agreements and any UAC prompts for the missing prerequisites.
The script installs missing Git, mise, and native Windows chezmoi (`twpayne.chezmoi`) through WinGet, clones this repository to `$HOME\src\github.com\hyperlapse122\dotfiles` (`~/src/github.com/hyperlapse122/dotfiles`, matching the ghq layout), and invokes the existing mise preparation workflow.
It checks preparation explicitly because mise can report a failed postinstall hook as a warning.
It does not apply personal settings, register a global chezmoi source, or modify shell profiles.

To select another checkout location, pass `-Destination`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap -Destination 'C:\src\github.com\hyperlapse122\dotfiles'
```

An existing destination must be this repository's Git root with origin `https://github.com/hyperlapse122/dotfiles.git`.
Reruns reuse that checkout without pulling, resetting, switching branches, or discarding local files.
An unrelated directory is rejected rather than replaced.
Failures return a nonzero exit status and identify the failing step; resolve the reported problem and rerun the same command.

After completion, open a new PowerShell window so it inherits the installers' PATH updates.
Register the permanent checkout explicitly, using your custom destination if you supplied one:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\src\github.com\hyperlapse122\dotfiles\configure-chezmoi.ps1"
```

The registration script defaults to its own checkout; `-Source 'C:\src\github.com\hyperlapse122\dotfiles'` selects another permanent checkout.
It rejects temporary linked worktrees and configurations pointing to another source.
It creates TOML configuration or preserves unrelated values in same-source TOML; other existing formats require explicit migration and are left untouched.
Registration does not apply managed home files.

After registration, use the native Windows installation from any unrelated directory:

```powershell
chezmoi apply
```

To pull changes and refresh the generated configuration before applying:

```powershell
chezmoi update --apply=false
chezmoi init
chezmoi apply
```

The separate apply invokes the Windows WSL2 prerequisite hook.
Plain `chezmoi update` applies internally without running `hooks.apply.pre`; do not use it for protected application.
An existing configuration must be initialized before its first guarded apply; `apply --init` cannot protect the invocation that first adds the hook.
Chezmoi's default pull uses autostash and rebase; existing custom update settings remain unchanged.
These commands update dotfiles, not the installed chezmoi binary; use WinGet to maintain that installation.

The Windows installation is for everyday use; the mise-managed copy is for repository development and tests.
In a fresh shell outside a mise project, `Get-Command chezmoi` should identify the Windows installation.
Inside an intentionally mise-activated shell, mise can take precedence; use a fresh non-activated shell for everyday commands.
Registration itself selects the native executable even when a mise copy appears first in PATH.
It refreshes PATH from the Windows registry for its own process so it can find a newly installed native executable without restarting the parent terminal; persistent PATH values are unchanged.
No settings are applied automatically, and GUI applications, Git/GPG personal configuration, secrets, and organizational sign-in remain outside bootstrap.

## Prepare a worktree

Git and mise must already be installed.
Authorize the repository configuration with `mise trust` before its first use.
Then initialize the worktree with:

```sh
mise install
```

This installs the locked development tools, including a separate chezmoi copy, and runs the `bootstrap` task through the project-level `postinstall` hook.
Git keeps `mise.lock` in LF format on every platform, matching mise's output even when `core.autocrlf` is enabled.
The task lists managed chezmoi entries with scripts excluded; it does not apply files or execute chezmoi scripts.
It uses the repository's hook-free `.chezmoi-bootstrap.toml` so existing personal chezmoi hooks cannot run during preparation.
The hook also runs when all tools are already installed, so use the same command for an existing worktree.
Shell activation is not required.
On x64 Linux, chezmoi uses its static musl build to avoid requiring a glibc compatibility layer on musl hosts.

Additional preparation belongs in the `postinstall` path, not in a separate setup command.
Mise reports hook failures as warnings and may still exit successfully: a warning means preparation did not complete.
To inspect a failed preparation check with normal task failure reporting, run:

```sh
mise run bootstrap
```

## Apply personal settings

Run this only when you intend to change the actual user home directory and managed per-user environment settings:

```sh
mise run apply
```

Repository preparation and apply tasks resolve the current worktree's source, including when called from a subdirectory.
They do not initialize or redirect the global chezmoi source.
The source manages global Git settings, GPG pinentry selection, native GPG secret encryption, native system-CA trust settings, and Windows host applications.
Git/GPG installation and key provisioning remain prerequisites.
The source also installs pinned personal CLI applications and applies their PATH integration; see the application workflow below.

Before the first Windows apply, or after pulling configuration-template changes, regenerate chezmoi configuration from the intended checkout:

```sh
mise exec -- chezmoi --source . init
```

Initialization does not apply personal settings.
It preserves unrelated configuration and configures `.ps1` execution with `-NoProfile`, noninteractive operation, and a process-local execution-policy override.
Chezmoi uses the built-in Windows PowerShell executable by absolute path, so initialization inside mise cannot pin a development-only interpreter.
For an everyday global source, run this from the permanent checkout, not a temporary worktree.

On Windows, `hooks.apply.pre` checks WSL2 prerequisites before managed files or apply scripts change the environment.
It also runs for unchanged applies and `apply --dry-run`, including applies unrelated to Kubernetes.
The check is read-only: it does not install WSL, enable Windows features, change the default distribution/version, or reboot.
WSL2 must already be prepared; resolve the reported prerequisite outside this workflow and rerun apply.
No Linux distribution or prior Rancher Desktop installation is required.
Bootstrap, registration, and `mise install` remain usable without WSL2; Linux and macOS do not receive this gate.
Existing apply-pre hooks run after a successful check, with their failures still stopping apply.

To preview future changes without applying them, run from the repository root:

```sh
mise exec -- chezmoi --source . diff
```

Previewing externals can download and cache their pinned contents, but does not install them or run PATH actions.

### Windows host applications

On Windows, explicit application provisions Google Chrome, 1Password, 1Password CLI, system PowerShell, and Rancher Desktop through WinGet when the installation action is eligible.
Use `mise run apply` from an initialized worktree, or the separate source-update and apply sequence above for a permanent checkout.
Bootstrap and source registration do not install these applications.

The package list lives in `home/.chezmoidata/windows.yaml`:

- Google Chrome: `Google.Chrome`
- 1Password: `AgileBits.1Password`
- 1Password CLI: `AgileBits.1Password.CLI`
- PowerShell: `Microsoft.PowerShell`
- Rancher Desktop: `SUSE.RancherDesktop`

Install or update Windows App Installer if WinGet is unavailable.
Approve WinGet agreements and any UAC prompts when requested; package scope and installer behavior use WinGet's defaults.
The app script runs after the GPG-home check, so the Git/GPG prerequisites below still apply.
It renders empty on Linux and macOS, and previews do not execute it.

The action uses WinGet's `--no-upgrade`: recognized existing installations are retained, including older versions.
After success it runs again only when the script or consumed application data changes; an unchanged apply does not restore a manually uninstalled package.
This does not disable applications' own update mechanisms.
Installation failures stop apply with the package ID and exit code; resolve the reported problem and rerun to complete the remaining installations.
Account sign-in, CLI/app integration, browser extensions, default-browser selection, and application preferences remain manual.
After installing the CLI, open a fresh shell and check `op --version`.
After installing PowerShell, open a fresh shell and check `pwsh --version`.
The system installation is for everyday use outside mise; mise still manages the repository's development runtime.

### Windows Kubernetes environment

Rancher Desktop provides the reusable local Kubernetes cluster and bundled command-line tools.
The installer skips package dependencies for Rancher Desktop so WinGet cannot install or update its WSL dependency.
After installation, apply enables only the built-in Kubernetes setting through `rdctl`; it leaves the container engine, Kubernetes version, and unrelated preferences unchanged.
The application may open its GUI, but first-run modal dialogs are suppressed.
Apply waits up to five minutes for the Kubernetes API and a Ready node; a startup error or readiness timeout fails apply without resetting the cluster.

Open a fresh PowerShell window after installation so the installer's PATH change is available, then check the explicit local context:

```powershell
kubectl --context rancher-desktop cluster-info
kubectl --context rancher-desktop get nodes
```

Bundled kubectl may download its compatible client on first use, so network access or an existing cache is required.
Use this context explicitly when other clusters are configured.
Rancher Desktop also bundles Helm, but this repository does not separately install or configure it.
kind is not installed.
Application repositories own their charts, deployment, tests, and cleanup.

The cluster survives normal repeated applies.
For a clean cluster, use Rancher Desktop **Troubleshooting → Reset Kubernetes** manually.
This deletes all workloads and cluster configuration; deleting container images is optional.
Do not use **Factory Reset** for ordinary test cleanup: it also removes Rancher Desktop settings.
No reset is automated by this repository.

GitHub CLI authentication and Docker Hub (`docker.io`) token authentication through the Windows keyring are tracked separately in [issue #21](https://github.com/hyperlapse122/dotfiles/issues/21).
This setup does not acquire tokens, configure registry credentials, or create Kubernetes image-pull secrets.

### Repository clones with ghq

Explicitly applying personal settings installs the pinned [ghq](https://github.com/x-motemen/ghq) binary under `~/.local/bin` and sets `ghq.root` to `~/src` in the managed global Git configuration.
After refreshing the terminal environment as described under Personal CLI applications, run from any directory:

```sh
ghq root
ghq get https://github.com/hyperlapse122/dotfiles.git
```

The clone is placed at `~/src/github.com/hyperlapse122/dotfiles`, matching the Windows bootstrap checkout layout.
If that clone already exists, `ghq get` leaves it unchanged unless `-u` is supplied.
Existing clones elsewhere are not moved, and bootstrap does not apply the Git setting.
An existing `GHQ_ROOT` environment variable overrides `ghq.root`; unset it to use `~/src`.

### Git signing and GPG pinentry

The managed global Git configuration uses `Joosung Park`, `hyperlapse@jpi.co.kr`, signing key `621512777E6933FEB4458FDC4945855D4F283F05`, and automatic OpenPGP commit signing.
New repositories created with `git init` start on `main`; existing branch names and repository-local configuration are unchanged.
The entire global `.gitconfig` is repository-managed, so put shared changes in the source rather than editing the generated file.

Install Git, GPG (including `gpgconf`), and the platform's pinentry before applying.
The existing signing key and any required YubiKey must already be ready on the device; this repository does not generate or import keys, distribute public keys, or change trust.

| Platform | GPG executable | Pinentry executable |
| --- | --- | --- |
| Windows / Gpg4win | `C:/Program Files/GnuPG/bin/gpg.exe` | `C:/Program Files/Gpg4win/bin/pinentry.exe` |
| Linux | `/usr/bin/gpg` | `/usr/bin/pinentry` |
| macOS / Apple Silicon Homebrew | `/opt/homebrew/bin/gpg` | `/opt/homebrew/bin/pinentry-mac` |

Common values and platform defaults are split by tool under `home/.chezmoidata/`: `git.yaml` contains the Git identity and `gpg.yaml` contains the OS-specific executable defaults.
For nonstandard installations, set absolute paths in the current chezmoi TOML configuration:

```toml
[data]
gpgProgram = "D:/Tools/GnuPG/bin/gpg.exe"
pinentryProgram = "D:/Tools/Gpg4win/bin/pinentry.exe"
```

`gpgconf` must be next to the selected GPG executable.
The managed GPG home is `%USERPROFILE%/AppData/Roaming/gnupg` on Windows and `~/.gnupg` on Linux/macOS.
Before writing personal files, application checks the selected installation's effective GPG home and stops if it differs, including custom `GNUPGHOME` or Windows registry/portable-installation choices.
Reconcile that location before applying; custom GPG-home relocation is not managed here.
Linked GPG-home directories are rejected rather than replaced, including Windows reparse points in the managed parent directories.
On Windows, an existing GPG path alias is accepted only when its volume and 128-bit file ID match the managed directory.
GnuPG reads `GNUPGHOME` through the ANSI environment API; use an ASCII-representable alias if that override contains characters outside the system code page.
Do not force `--homedir` to the expected location to bypass this safety check.

Only active `pinentry-program` entries in `gpg-agent.conf` are replaced.
Comments, unrelated agent settings, keys, and trust databases remain unmanaged.
Application reloads the agent after relevant source templates or the current platform's effective GPG/pinentry settings change.
An unchanged apply skips reload but still checks the current GPG home before writing personal files.
Managed file values still reconcile after local edits, but destination drift alone does not schedule reload.
Windows scripts execute directly in PowerShell using the generated profile-free interpreter configuration.
The always-run guard still appears in `chezmoi diff`; use `chezmoi diff --exclude=scripts` to inspect file drift only.

To verify on a configured device, create a temporary repository, make a commit with the existing key, complete PIN entry if prompted, and inspect it with `git verify-commit HEAD`.
Configuration rendering on another OS does not prove its native PIN dialog or hardware integration.

### Encrypted API tokens

Secrets use chezmoi's built-in GPG encryption, not SOPS.
The sole recipient is the public key with primary fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`.
GPG selects an encryption-capable subkey and obtains private-key access; the repository does not inspect or require particular storage hardware.
The public key and working GPG/pinentry environment must already exist on each device.

From the selected checkout, explicitly initialize or regenerate chezmoi's configuration before using encryption:

```sh
mise exec -- chezmoi --source . init
```

This does not apply managed home files or decrypt secrets.
It preserves unrelated TOML configuration but replaces encryption settings, recipient lists, symmetric mode, and GPG arguments with repository policy.
The executable follows the existing `gpgProgram` override and platform selection.
Reinitialize after changing those source settings; `apply` alone does not regenerate chezmoi configuration.

Chezmoi's GPG calls use `--no-options` so personal `gpg.conf` options cannot add recipients, including hidden recipients or recipient groups.
This also means other personal `gpg.conf` options do not apply to this workflow.
GPG still uses its existing key stores and agent; `gpg-agent.conf` and pinentry remain separate.
No symmetric-passphrase fallback or additional recovery recipient is configured.

`home/.secrets/api-tokens.yaml.asc` preserves the example mappings and stores the managed GitHub PAT under `github.token`.
The `.secrets` directory is source-only and ignored as a destination.
No dummy application configuration is installed automatically.
Edit and re-encrypt it with:

```sh
mise exec -- chezmoi --source . edit-encrypted home/.secrets/api-tokens.yaml.asc
```

Chezmoi 2.74's `edit-encrypted` requires the encrypted file to be under the current user home.
The standard checkout under `~/src/github.com/hyperlapse122/dotfiles` meets that requirement; changing `--destination` does not change this editing constraint.
For an outside-home checkout, edit a local plaintext copy outside the repository and use the encryption command below to replace the encrypted source.

To create or replace the encrypted source from a plaintext file kept outside the repository:

```sh
mise exec -- chezmoi --source . encrypt --output home/.secrets/api-tokens.yaml.asc /absolute/path/outside-repo/api-tokens.yaml
```

Preserve unrelated mappings when editing the encrypted document; the GitHub importer below merges its token without removing them.
Do not put decrypted tokens in `.chezmoidata`, tracked templates, or persistent chezmoi configuration.
The shared `secrets` partial decrypts only when a consumer calls it.
For example, a managed JSON template can select one token:

```gotemplate
{{- $secrets := includeTemplate "secrets" . | fromYaml -}}
{"apiToken": {{ $secrets.example.serviceB | toJson }}}
```

After adding an intended consumer template to the source, apply it explicitly with `mise run apply`.
GPG may request a PIN or passphrase through its normal environment.
Missing private-key access is an error, not an empty-value or dummy-value fallback.
Worktree preparation and bootstrap do not call the secrets partial or require decryption.

Encryption protects committed source, not a running device.
Generated application files contain plaintext; `diff`, `cat`, and template previews can expose it.
Native GPG encryption/decryption and encrypted-file editing use temporary plaintext files, and editors may leave backups or recovery files.
Use a trusted local editor and terminal, protect destination access, and never commit or log real decrypted values.
Losing access to the private key makes existing ciphertext unavailable; key recovery and rotation are not managed here.

### GitHub CLI and Git authentication

`gh` remains declared in both `mise.toml` and generated `mise.lock` for development.
Chezmoi separately installs the personal executable from `home/.chezmoidata/personal-apps.json` and its generated release lock.
Git uses that stable `~/.local/bin/gh` path, not a versioned mise path or the checkout's location.

After `mise install` and the explicit encryption initialization above, import a UTF-8 token file:

```sh
mise exec -- python scripts/github-auth.py import --token-file /path/to/github-token.txt
```

`--source` selects another repository root; `--config` selects its existing initialized chezmoi configuration.
The importer keeps the document in memory, stages only ciphertext, verifies the published encrypted document, and then deletes the input.
Failures before publication retain the input and previous ciphertext; a later input-deletion failure leaves the verified ciphertext available and reports incomplete cleanup.
Deletion is ordinary filesystem deletion, not secure erasure.
Do not pass a token value as a command argument or environment setting.

Explicit `mise run apply` installs the personal executable and reconciles authentication for `github.com` and Git HTTPS access to `gist.github.com`.
The authentication hooks run on every apply so rotation or external keyring deletion is repaired.
They use the validated chezmoi GPG policy with streaming GPG stdin/stdout, avoiding the temporary plaintext files used by chezmoi's built-in GPG commands.
Rendered scripts contain only paths and commands, never decrypted tokens.
Preparation, initialization, and `chezmoi apply --exclude=scripts` do not decrypt or register credentials.

Credentials use Windows Credential Manager, macOS Keychain, or the existing Linux Secret Service login/default collection.
The mise-managed keyring tool is installed through uv; the explicit native backend never selects a file store or a fallback backend.
Linux needs a working user-session Secret Service, and native unlock/access prompts remain user actions.
Unavailable, locked, or denied storage is an error: the hook never calls `gh auth login`, whose plaintext fallback would violate this policy.
Only the managed account's token fields and active selection are reconciled; unrelated hosts and accounts are preserved.
Gist receives a native credential alias without being newly registered as a separate GitHub API host.

The managed Git config resets earlier helper chains only for the two HTTPS hosts and then invokes the personal gh helper.
SSH remotes and other hosts are unchanged.
Later repository-specific helper settings and ordinary `GH_TOKEN`/`GITHUB_TOKEN` overrides retain their normal precedence; verification excludes those overrides.
Check account access with `gh auth status --active --hostname github.com`, without `--show-token`.
Never send `gh auth token` or `git credential fill` output to terminal logs or CI artifacts.


### Native system CA trust

The DPI/enterprise CA must already be trusted by the operating system.
Explicit apply persists `NODE_USE_SYSTEM_CA=1` without disabling TLS certificate or hostname verification.
It does not install certificates, export a CA bundle, or modify machine-wide environment settings.

| Target | Native coverage and prerequisites | Managed behavior |
| --- | --- | --- |
| Node.js | Environment-variable support starts at 22.19.0 in the 22.x line and 24.6.0 in the 24.x line; check support for other releases | Enable system roots in addition to bundled roots |
| Bun | 1.2.23 or newer | Enable system roots in addition to bundled roots |
| Standalone omp | Depends on its embedded Bun, not a separately installed runtime | Inherit the same opt-in; explicit request-level CA settings remain a boundary |
| Python standard-library TLS | Windows loads its documented CA/ROOT stores; Linux follows the build's OpenSSL system paths; macOS OpenSSL paths do not automatically imply Keychain trust | Leave suitable native defaults unchanged |
| pip | pip 24.2+ with Python 3.10+ uses system certificates alongside certifi | Leave the native default unchanged; older combinations are not upgraded here |
| Requests | Upstream defaults to certifi rather than OS trust | No automatic native integration; CA-file support is deferred |
| Java JSSE | Native providers exist, but store selection can omit other trust domains or Java's existing roots | No JVM-wide truststore override; application/distribution-specific integration is not guaranteed |
| Git HTTPS | Git for Windows with Schannel switching support, introduced in 2.14.0; other platforms depend on their linked libcurl | Select Schannel on Windows and prevent a CA-file setting from replacing Windows trust |
| curl | Windows Schannel already uses Windows trust; macOS needs a compatible native/SecTrust build; Linux can use an existing OS-maintained OpenSSL CA bundle | Leave suitable native defaults unchanged; do not add an unconditional shared curlrc option |
| Go-based tools | Windows/macOS normally use platform trust; Linux uses system CA files/directories | Leave native defaults unchanged; inspect version-dependent filesystem overrides |

The Windows Git settings keep TLS and revocation verification enabled.
They do not configure an unrelated GUI client's embedded Git or libcurl.
An existing OS-maintained Linux CA bundle counts as system trust; a separately generated or distributed file is outside this change.

#### Activate the user environment

- **Windows:** the change-driven action writes only the named value under `HKCU\Environment`.
  After success, an unchanged apply does not repair an externally changed value.
  Sign out and sign back in for the reliable CLI/GUI refresh baseline.
  A new tab in an old terminal or IDE can still inherit its parent's old environment.
- **Linux:** apply installs `~/.config/environment.d/60-native-system-ca.conf`.
  For an already-running systemd user manager, run `systemctl --user daemon-reload`, then restart the relevant applications or graphical session.
  This covers user-manager services and desktop launchers that consume that manager's environment, not every display manager or desktop.
- **macOS:** apply installs `~/Library/LaunchAgents/com.hyperlapse.native-system-ca.plist` for the next Aqua login.
  After logging in, `launchctl getenv NODE_USE_SYSTEM_CA` should print `1` before launching the application being checked.
  Login-restored applications can start before the setter; fully quit and reopen affected applications and stale launchers after it completes.
  The agent does not guarantee ordering before every other login application.

Unix shell startup files receive a small marked export block.
Unrelated contents are preserved, and incomplete or conflicting owned delimiters stop modification rather than deleting an uncertain range.
The source always manages `.profile`, `.bashrc`, and `.zshenv` on Unix; existing `.bash_profile` and `.bash_login` are modified without creating new ones that would shadow the user's current Bash login file.
Nonstandard `ZDOTDIR`, custom rc-file options, nondefault Linux XDG/session paths, and startup code that later overrides the variable need separate configuration.
No shell hook can update a process that is already running.

#### Check effective trust, not just the variable

Restart the application through the intended CLI or GUI launch path and exercise its affected HTTPS operation outside this checkout.
For example, `omp update --check` checks the public update endpoint without installing an update.
A standalone executable's own request is stronger evidence than a probe using a different installed runtime.
The public update check does not establish every model-provider or custom transport's behavior.

Inspect inherited `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, application-specific CA settings, and URL-specific Git settings if a connection still fails.
They are not deleted by this repository.
In particular, omp can supply explicit request-level CAs when `NODE_EXTRA_CA_CERTS` is present, and Go 1.27 can select filesystem roots on Windows/macOS when the SSL certificate override variables are set.
Do not fix that conflict by disabling verification or setting one global CA-file path for all tools.

CA-file integration and macOS/Linux CA files encrypted with chezmoi's native GPG support, committed as secrets, and installed during explicit apply are tracked separately in [issue #10](https://github.com/hyperlapse122/dotfiles/issues/10).
The follow-up still needs to distinguish local application files from OS trust-store registration.

## Personal CLI applications

Chezmoi manages personal application installation independently of mise's development environment.
The managed applications are [omp](https://github.com/can1357/oh-my-pi), [GitHub CLI](https://github.com/cli/cli), and [ghq](https://github.com/x-motemen/ghq), using official releases for Windows and GNU/Linux on x64 and ARM64, and for macOS on ARM64 (Apple Silicon).
ghq also supports macOS on x64.
Linux musl is not supported.
Installing the prebuilt executables needs no Bun or Python runtime; the separate authentication hooks require the mise-managed Python and keyring tools.

Explicit apply installs commands under `~/.local/bin` (`omp.exe`, `gh.exe`, and `ghq.exe` on Windows), verifies the committed SHA-256, and reconciles them to the repository's pins.
It does not ask upstream for the latest version.
Preparation with `mise install` does not install personal applications or run PATH actions.

On a registered permanent checkout, update with:

```sh
chezmoi update
```

Windows apply adds the installation directory to the user PATH without copying the combined process PATH into persistent settings.
Existing expandable entries and their registry value kind are preserved; only a separate comparison copy is expanded for duplicate detection.
Fully close and reopen the terminal host from the desktop or Start menu afterward; a new tab in an already-running terminal may retain its old environment.
Close running omp sessions before replacing `omp.exe`, and run the update from a separate ordinary terminal.

On macOS/Linux, apply preserves existing Bash and Zsh profiles and adds a source line for the managed PATH fragment.
It uses the first existing Bash login profile rather than creating a higher-precedence profile, and also covers interactive shells.
An exported `ZDOTDIR` is respected.
PATH integration runs on change: an unchanged apply does not restore manually removed user PATH entries or profile source lines.
The Unix action tracks the managed fragment source and effective destination/`ZDOTDIR`; application release-pin changes alone do not rerun PATH integration.
Custom startup files that exit early or reset PATH afterward may need adjustment; other shells are not configured by this integration.
If another installation wins command discovery, inspect `Get-Command omp -All` on Windows or `command -v omp` on POSIX and resolve that installation deliberately.
Apply does not uninstall unrelated software.

### Refresh application pins

Authored declarations live in `home/.chezmoidata/personal-apps.json`.
Generated tags, release-specific asset URLs, and SHA-256 values live in `home/.chezmoidata/personal-app-lock.json`.
Targets declare an asset pattern and installation kind: raw `file` for omp, or `archive-file` with format/member path for gh and ghq.
Archive targets may also declare `stripComponents`, used by ghq to remove the release ZIP's top-level directory.
Only `{version}` expansion is supported; generated pins resolve it from the selected release tag and record the archive metadata.
Checksums cover the downloaded archive, and chezmoi extracts only the executable.
To resolve the declarations through the mise-installed GitHub CLI:

```sh
mise exec -- python scripts/update-personal-app-lock.py
```

The updater invokes `gh api` using the current CLI authentication.
It publishes a complete pin set only after every required asset and GitHub SHA-256 digest resolves.
Missing assets, missing digests, and query failures leave the previous lock unchanged.
An unchanged result does not rewrite the file.
Do not edit generated pins by hand or replace release-specific URLs with `latest/download` links.

After this feature is merged, the **Update personal application pins** workflow checks daily at 06:23 UTC and supports manual dispatch.
Release resolution uses the automatically injected `secrets.GITHUB_TOKEN`, exposed to gh as `GH_TOKEN`.
No custom secret or personal access token is required.
The workflow validates the new pins and runs the Linux native smoke before committing only a changed lock directly to the default branch.
Resolution, native validation, and publication use separate jobs; only publication has `contents: write`, and it never executes the downloaded application.
Validation and publication consume the same immutable lock artifact from the same recorded default-branch base.
It does not create a PR, force-push, or apply changes to personal devices.
A conflicting default-branch update fails the normal push instead of overwriting it.
Hosted schedules are best effort; manual dispatch remains available.

To add another application, add its repository, command name, and supported asset-name mappings to the authored declarations, then regenerate the lock.
The current renderer supports standalone executable assets; archive-based distributions need an explicit extraction extension before being added.
Claude Code, gh, and glab are not installed by this change.
Development-tool declarations in `mise.toml` and `mise.lock` remain separate.

Chezmoi caches downloads, and the renderer includes the pinned digest in the cache identity so same-URL asset replacements are reconciled.
If a cached download is corrupt, rerun explicitly with `chezmoi apply --refresh-externals`; checksum failure leaves the existing executable untouched.

## PowerShell mise activation

Explicit application installs the same startup line in each runtime's current-user, all-hosts profile:

```powershell
(&mise activate pwsh) | Out-String | Invoke-Expression
```

Windows applies it to both Windows PowerShell 5.1 and modern PowerShell; macOS and Linux apply it to modern PowerShell.
Each runtime resolves its own `$PROFILE.CurrentUserAllHosts` path, including redirected Windows Documents folders and Unix configuration directories.
The apply scripts use the current checkout's mise-declared PowerShell, so it does not need to be discoverable before activation.
mise itself must already be available on the shell's startup PATH.

**The repository replaces the entire selected profile.**
Existing local customizations in that file are discarded, and applying again restores repository content after local edits.
Host-specific profiles and all-users profiles are not changed.
Host-specific profiles load later and can override this setup.

Open a new local PowerShell session after applying.
Sessions started with `-NoProfile`, remote sessions, and Windows execution policies that block profiles do not load this configuration.
Application does not change persistent execution policy.
Windows PowerShell 5.1 can show mise's directory-change warning and updates the environment at the next prompt; the repository does not suppress that warning.

Profile installation runs only through explicit apply scripts, not `mise install` or `mise run bootstrap`.
The runtime-resolved files are not entries in `chezmoi managed`; `chezmoi apply --exclude=scripts` also excludes their installation.

## Harness plugins

Explicit apply installs [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) for the standard user-global omp environment on the same declared targets as the omp executable.
Other harnesses are not installed or configured yet.

Plugin declarations live in `home/.chezmoidata/harness-plugins.json`; generated stable-release tags and full commit SHAs live in `home/.chezmoidata/harness-plugin-lock.json`.
Chezmoi extracts the SHA-addressed archive into `~/.local/share/dotfiles/harness-plugins/compound-engineering`, then registers that directory as omp's local CE marketplace, refreshes its catalog, force-installs CE at user scope, and enables it.
This replaces a preexisting remote CE marketplace registration without removing unrelated marketplaces or plugins.
The archive excludes alternate-host and site link aliases, so Windows installation does not require file-symlink privileges.
The underlying skill files and native omp metadata remain from the pinned commit.
No separately installed Bun or Python is needed for device application.

Apply only with omp closed, then start a new session to load the resulting skills.
The existing explicit `mise run apply` and registered-checkout `chezmoi update` flows apply these changes.
Preparation with `mise install` does not install plugins or change configuration; archive enumeration may populate chezmoi's download cache.

### Mutable omp settings

The repository uses `modify_` templates rather than storing a complete personal `config.yml`.
They set `marketplace.autoUpdate` to the string `"off"` while retaining unrelated property values.
**This disables startup automatic updates for all omp marketplace plugins, not only CE.**
An existing `~/.omp/agent/config.yml` takes precedence; otherwise an existing `config.yaml` is modified without creating a shadowing `.yml`.
When neither file exists, apply creates a minimal `.yml`.
If legacy `settings.json` or `agent.db` exists without YAML, apply stops before creating YAML; let omp complete its native first-start migration, close it, and apply again.
Malformed YAML fails without replacement.

Repeated apply restores the owned YAML property and managed source while retaining other property values and plugin settings.
Native registration, force installation, and enabling use `run_onchange_`: a successful action is skipped until its effective pin, selected executable asset, source identity, or consumed template changes.
Mutable runtime files are not fingerprint inputs. Manually disabled plugins or modified native cache content are not repaired by an unchanged apply.
For an immediate native cache repair without a source change, run these native commands with omp closed:

```sh
omp plugin marketplace update compound-engineering-plugin
omp plugin install --scope user --force compound-engineering@compound-engineering-plugin
omp plugin enable --scope user compound-engineering@compound-engineering-plugin
```

Parsing and serialization can remove comments and normalize formatting.
Do not apply while another process writes the same file: modify is an apply-time transformation, not continuous enforcement or a shared application lock.
This integration targets the standard default profile; independently configured profiles, relocated roots, project settings, and process overlays are not managed.
Reusable multi-format property declarations remain separate in [issue #17](https://github.com/hyperlapse122/dotfiles/issues/17).

### Refresh or restore plugin pins

```sh
mise exec -- python scripts/update-harness-plugin-lock.py
```

The updater accepts the repository's latest release only when it is a published stable CE release, resolves its exact tag through annotated tags to a commit, and leaves existing pins unchanged on incomplete resolution.
It does not search older releases when repository-level latest belongs to another component.
After merge, **Update harness plugin pins** checks daily at 06:43 UTC and supports manual dispatch.
Read-only resolution and native validation precede a separate write-authorized job that commits only the validated lock directly to the default branch.
Unchanged pins create no commit; a conflicting push fails without force.
The workflow does not apply to personal devices.

To restore an earlier CE revision, restore its committed plugin lock and explicitly apply it.
The dedicated source directory is reconciled exactly, removing files introduced by a newer pin; native force installation also supports version rollback.
The commit identifies extracted upstream content, not a checksum of GitHub's compressed archive bytes.
Do not commit omp's `omp-plugins.lock.json`: it contains runtime settings and can contain secrets.

Run the isolated native plugin check with:

```sh
mise exec -- python tests/smoke_harness_plugins.py
```

It uses a disposable home, not the owner's configuration, and checks actual skill URI discovery, the local marketplace cutover, automatic-update policy, unchanged-action skipping, template-triggered cache repair, and unrelated plugin preservation.
CI runs this check across the current native executable matrix.

## Source layout

The repository-root `.chezmoiroot` selects `./home` as chezmoi's source state.
Repository tooling and documentation outside that directory are not managed home files.
See [home/README.md](home/README.md) for source naming and script ordering.

Declare development tools in `mise.toml` and commit their generated lockfile.
Keep development-tool installation in mise; the Windows bootstrap installs the separate everyday chezmoi through WinGet.
Chezmoi owns personal configuration and the actions needed to apply it.

## Verify bootstrap isolation

After installing the tools, run:

```sh
mise exec -- python -m unittest discover -s tests
```

The bootstrap isolation test initializes twice with an isolated user home and an existing chezmoi config containing mutating hooks.
It checks that preparation does not execute those hooks or alter the existing personal setting and config.
On Windows, entry-point regressions also exercise Windows PowerShell, repeated preparation, Unicode checkout paths with OEM console encoding, destination/origin rejection, and native-command failure propagation.
Global-source regressions use real Git and chezmoi with isolated homes and a local remote to verify pull/apply, configuration regeneration, repeated registration, and conflict preservation.
Secret regressions use real GPG and chezmoi with temporary software keys in fixture-scoped keyrings to check effective ciphertext recipients, named-token consumption, destination preservation on decryption failure, repeat application, and preparation without decryption.
GPG and chezmoi must be available for those tests; they do not exercise the owner's private key or hardware PIN dialogs.
Native-CA regressions exercise real Bash startup behavior and Windows registry-provider writes against disposable state; Windows tests never execute the CA apply hook against the owner's actual environment.
Native Linux/macOS graphical-login behavior requires those platforms; rendering or parsing their configuration is not GUI activation proof.
PowerShell regressions replace disposable profiles and load them with real mise in each available runtime, including Windows PowerShell 5.1.
Automatic startup is exercised with isolated Unix configuration directories and on disposable GitHub-hosted Windows runners; local Windows tests do not write the owner's actual profiles.
Windows app regressions execute real chezmoi scripts against a disposable package inventory, covering unchanged-action skips, application-data changes, existing-version preservation, no-pwsh first application, and failure propagation without reaching the host's WinGet.
Script lifecycle regressions cover consumed-template and effective-data invalidation, unchanged reload skips, failed-action eligibility, and guards that still inspect changed host state.
Git and mise must already be installed before running the regression suite.
These tests do not install packages on the host; a real first-time WinGet installation requires a disposable Windows environment.
Windows unit CI extracts a SHA-512-verified native GnuPG CLI payload into its temporary workspace for the existing Git/GPG integration tests; it never executes the Windows installer.
Git's bundled MSYS GPG has different path semantics and is not the native Windows prerequisite.
This CI setup does not install GPG during worktree preparation or add it to the personal application catalog.

Personal-application regressions use loopback HTTP payloads and real chezmoi in temporary destinations to verify cache reconciliation, checksum failure preservation, and platform selection.
The ordinary suite never changes the owner's persistent PATH.
To download and run the actual committed personal CLI binaries in an isolated temporary destination:

```sh
mise exec -- python tests/smoke_personal_apps.py
```

This smoke excludes PATH scripts.
CI separately exercises native binaries and fresh-terminal PATH discovery on all five supported application targets.
Its `--path-integration` mode is restricted to disposable GitHub-hosted runners and restores the Windows user PATH afterward.

### CI runner policy

macOS uses the latest Xcode runner on ARM64 only; Intel Macs are not supported.
Ubuntu coverage follows the two newest LTS releases, each on x64 and ARM64, for both unit tests and native installation/PATH checks.
Windows runner selection remains fixed, with unit tests on x64 only.
Keep the explicit labels in `.github/workflows/test.yml` aligned with this policy as new images become available; `xcode-27` is currently a preview image.

| Runner | Native application target | Unit tests |
| --- | --- | --- |
| `ubuntu-24.04` | `linux-amd64` | Yes |
| `ubuntu-24.04-arm` | `linux-arm64` | Yes |
| `ubuntu-26.04` | `linux-amd64` | Yes |
| `ubuntu-26.04-arm` | `linux-arm64` | Yes |
| `xcode-27` | `darwin-arm64` | Yes |
| `windows-2025` | `windows-amd64` | Yes |
| `windows-11-arm` | `windows-arm64` | No |

The scheduled pin updater retains its separate Ubuntu x64 validation job; it is not the cross-platform support matrix.
