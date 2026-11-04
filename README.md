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
chezmoi update
chezmoi update --init
```

The first command pulls the registered repository and applies its home source state.
The second also regenerates and reloads chezmoi configuration from its template before applying.
`--init` here does not clone an uninitialized source.
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
The source manages global Git settings, GPG pinentry selection, native GPG secret encryption, and native system-CA trust settings; tool installation and key provisioning are prerequisites.

To preview future changes without applying them, run from the repository root:

```sh
mise exec -- chezmoi --source . diff
```


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
| macOS / Intel Homebrew | `/usr/local/bin/gpg` | `/usr/local/bin/pinentry-mac` |
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

Only active `pinentry-program` entries in `gpg-agent.conf` are replaced.
Comments, unrelated agent settings, keys, and trust databases remain unmanaged.
Application reloads the agent so the selected pinentry takes effect; Windows scripts launch Windows PowerShell with `-NoProfile`, independent of the user's shell setup.
Repeated application restores managed values after local edits.
Because the check and reload run on every explicit application, `chezmoi diff` includes those scripts even when configuration files are unchanged; use `chezmoi diff --exclude=scripts` to inspect file drift only.

To verify on a configured device, create a temporary repository, make a commit with the existing key, complete PIN entry if prompted, and inspect it with `git verify-commit HEAD`.
Configuration rendering on another OS does not prove its native PIN dialog or hardware integration.

omp settings migration and release/checksum update automation are separate work and are not included here.

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

`home/.secrets/api-tokens.yaml.asc` contains two encrypted dummy tokens under `example.serviceA` and `example.serviceB`.
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

Preserve the `example` mapping when trying the example below; real application-specific token migration is not included.
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

- **Windows:** apply writes only the named value under `HKCU\Environment`.
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
Secret regressions use real GPG and chezmoi with temporary software keys to check effective ciphertext recipients, named-token consumption, destination preservation on decryption failure, repeat application, and preparation without decryption.
GPG and chezmoi must be available for those tests; they do not exercise the owner's private key or prove native Linux/macOS behavior.
Native-CA regressions exercise real Bash startup behavior and Windows registry-provider writes against disposable state; Windows tests never execute the CA apply hook against the owner's actual environment.
Native Linux/macOS graphical-login behavior requires those platforms; rendering or parsing their configuration is not GUI activation proof.
Git and mise must already be installed before running the regression suite.
These tests do not install packages on the host; a real first-time WinGet installation requires a disposable Windows environment.
