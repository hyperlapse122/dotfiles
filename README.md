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

Run this only when you intend to change the actual user home directory:

```sh
mise run apply
```

Repository preparation and apply tasks resolve the current worktree's source, including when called from a subdirectory.
They do not initialize or redirect the global chezmoi source.
The source contains a chezmoi configuration template but no concrete personal dotfiles payload yet.

To preview future changes without applying them, run from the repository root:

```sh
mise exec -- chezmoi --source . diff
```

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
Git and mise must already be installed before running the regression suite.
These tests do not install packages on the host; a real first-time WinGet installation requires a disposable Windows environment.
