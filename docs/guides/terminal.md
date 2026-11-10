# Terminal Emulators and Shells

Explicit personal configuration installs Ghostty, selects it through the platform's native default-terminal mechanism, and uses the account's zsh login shell.
On Windows, explicit application installs WezTerm and configures it to open PowerShell 7 with Jetendard.
Windows system default-terminal delegation remains unchanged.

## Windows WezTerm

Run `mise run apply` from the worktree to install `wez.wezterm` through the existing WinGet application owner and apply its configuration.
An existing installation is retained without a forced upgrade.
Worktree preparation with `mise install` does not install WezTerm or register Explorer menus.

The repository manages `~/.wezterm.lua`, replacing that file's existing contents with two preferences: the Jetendard font and `pwsh.exe` as the default program.
PowerShell loads its normal profile; the existing repository profile integration remains responsible for mise.
Font size, colors, padding, cursor, and key bindings use WezTerm defaults.
Linux and macOS continue to use Ghostty.

Application also reconciles **Open WezTerm Here** for a selected directory and a directory's background menu under `HKCU\Software\Classes`.
On Windows 11, use **Show more options** if the classic verb is absent from the first menu.
The command opens a local PowerShell session in the selected directory, including directories with spaces or non-ASCII names.
Repeated application repairs these entries and retains unrelated verbs and values.
It uses the installer's verb name so a machine-wide installation does not create a second differently named menu entry.

WezTerm can load another configuration before `~/.wezterm.lua`, including a file selected with `--config-file` or `WEZTERM_CONFIG_FILE`, a portable configuration beside its executable, or an XDG/`~/.config/wezterm/wezterm.lua` file.
If the managed preferences do not appear, inspect those locations; application does not remove them.
See [WezTerm configuration discovery](https://wezterm.org/config/files.html).

This integration does not redirect arbitrary console launches or replace Windows Terminal.
The Windows default-terminal registry values select COM handoff implementations; setting a WezTerm executable path there cannot provide that interface.
See the [upstream default-terminal request](https://github.com/wezterm/wezterm/issues/7534).

To check a personal application, open WezTerm directly and through both Explorer menu locations.
Confirm `$PSVersionTable.PSEdition` is `Core`, `(Get-Location).Path` is the selected directory, `mise --version` works, and `wezterm ls-fonts --text 'ABC 한글'` resolves Jetendard.

## Supported Devices

| Platform | Installation | Native default selection |
|---|---|---|
| Ubuntu Desktop 26.04 LTS, GNOME, amd64 (26.04.1+ media) | Official Ubuntu APT package | User `ubuntu-xdg-terminals.list` preference |
| macOS 26+, native Apple Silicon | Homebrew Ghostty cask | Unix-executable application association |

Other Linux distributions, desktop environments, Intel Macs, and headless desktop acceptance are excluded.
A working existing Ghostty installation is retained without a forced upgrade.
Ubuntu installs missing system zsh through APT; macOS uses its existing system shell.
An executable zsh already registered in `/etc/shells` is retained, including a registered Homebrew zsh or equivalent `/bin` and `/usr/bin` paths.

## Apply

From the intended repository checkout, as the normal user:

```sh
mise run apply
```

The installation and terminal hooks run only during explicit application.
`mise install` prepares the worktree without installing Ghostty, changing the account shell, or changing terminal defaults.
Do not run the whole application through `sudo`: the terminal helper refuses root and requires the destination to be the applying account's actual home.
Only package installation uses narrow `sudo` commands.

Complete any package-manager or `chsh` authentication prompt.
macOS uses the selected Command Line Tools Swift runtime for its native association helper and may request OS approval in a desktop session.
Declined approval, a missing desktop session, or an approval that does not finish within two minutes is reported as pending.
A missing required tool or failed configuration command is an error.

Pending user actions do not stop subsequent GitHub/GitLab authentication hooks: apply reports the pending action and returns zero for this stage.
Use the separate status command below to distinguish pending configuration from readiness.

## Managed Configuration and Native Boundaries

Application replaces Ghostty's primary configuration with the repository's shared content, selecting `font-family = Jetendard`.
It writes `config.ghostty` under `${XDG_CONFIG_HOME:-$HOME/.config}/ghostty` and, on macOS, `~/Library/Application Support/com.mitchellh.ghostty`.
An existing legacy `config` in either location is reset to the same content, so its later load cannot restore a shell command or included configuration.
This intentionally replaces personal Ghostty themes, key bindings, and command overrides; save any customization you want to retain before application.
Other Ghostty appearance settings use its defaults. The repository manages pinned Prezto and completion assets for the shared zsh environment.

Ghostty discovers the default shell from the system rather than a managed `command = zsh` override.
Existing Bash/zsh PATH integration remains in place and honors exported `ZDOTDIR`.
Unchanged PATH hooks retain their existing change-driven behavior; terminal reconciliation runs on every explicit apply.

Ubuntu Desktop places the installed Ghostty desktop entry first in `ubuntu-xdg-terminals.list` under the effective XDG configuration directory and verifies the result with `xdg-terminal-exec --print-id`.
It first resolves an installed Ghostty desktop entry whose Exec executable matches the active Ghostty binary, honoring XDG desktop-entry precedence and hidden entries.
It keeps the other entries in that list in their existing order. The APT package uses `com.mitchellh.ghostty.desktop`; a retained Snap installation uses `ghostty_ghostty.desktop`. It does not change system alternatives or rewrite shortcut bindings.
Ctrl+Alt+T, the Files terminal action and `Terminal=true` launch behavior still require native acceptance; a recorded preference alone does not prove those launchers use it.

macOS changes only the `public.unix-executable` association through AppKit.
It validates the Ghostty bundle identifier and executable before selecting it.
This does not replace Finder as the folder opener, rewrite Terminal.app paths hardcoded by other applications, or change IDE-integrated terminals.

## Renew the Session and Check Status

After a login-shell change, log out of all desktop sessions, log in again, and fully quit and reopen Ghostty.
Opening a new tab alone may retain the old `SHELL` environment.
On Ubuntu, lingering user services or another logged-in session can keep the systemd user-manager environment alive; resolve remaining sessions or stale user-manager state before considering the desktop ready.
An absent `SHELL` value can use the account-shell fallback; a present value selecting a different executable remains pending.

Run the read-only status command from the repository root.
On Ubuntu:

```sh
ghostty_release=$(. /etc/os-release; printf '%s' "$VERSION_ID")
ghostty_arch=$(dpkg --print-architecture)
sh "$PWD/scripts/terminal-environment.sh" status linux "$ghostty_arch" "$ghostty_release" \
  "$HOME" "$PWD/scripts/ghostty-default-terminal.swift" \
  "$PWD/home/.chezmoitemplates/ghostty-config"
```

On supported macOS:

```sh
sh "$PWD/scripts/terminal-environment.sh" status darwin arm64 26 \
  "$HOME" "$PWD/scripts/ghostty-default-terminal.swift" \
  "$PWD/home/.chezmoitemplates/ghostty-config"
```

Status returns `0` when its checks pass, `2` for pending user/session/configuration actions, and `1` for an error. On Linux it always retains pending native GNOME acceptance, even when all inspected settings match.
It checks the account shell, managed Ghostty files, native default selection, and available session-shell evidence without changing them.
Ubuntu also checks the systemd user-manager environment; unavailable manager evidence remains pending.
Status does not prove that a GUI window actually opened or that a file-manager request kept its selected directory.

## Package Maintenance

Ubuntu Desktop uses the official Ubuntu Ghostty package and normal explicit APT updates.
macOS retains its explicit Homebrew update path.
The terminal installation helper retains an existing usable Ghostty installation without forcing an upgrade.
No community Debian package pin or standalone community installer remains managed.

## Desktop Acceptance Checklist

After applying and renewing the session:

1. Run status and resolve configuration errors or session actions. Linux native acceptance remains pending in status; record the following GUI observations separately.
2. On Ubuntu Desktop, press Ctrl+Alt+T and confirm Ghostty opens. On macOS, open a suitable Unix executable through its native association and confirm the selected app.
3. In a newly launched Ghostty shell, check `printf '%s\n' "$SHELL"`, `ps -p $$ -o comm=`, and discovery of the repository-managed commands.
4. On Ubuntu Desktop, select a test folder containing spaces and Korean characters in Files, choose the terminal action that targets Ghostty, and check `pwd` in Ghostty. If Files offers no action that opens Ghostty, record that as a limitation. Also create a temporary local desktop entry with `Type=Application`, `Terminal=true`, `Exec=/bin/sh -c "pwd; read -r answer"` and `Path=` selecting that test folder. Launch it from GNOME and observe that Ghostty opens in the selected directory, then press Enter to close the test shell. Remove only this test launcher and folder afterward. On other platforms, check directory forwarding where the native file-manager action supports the selected terminal.
5. Repeat the directory check with Ghostty already running, because preference selection alone does not prove existing-instance working-directory forwarding.
6. Apply again and confirm the intended defaults remain selected without duplicate shell startup entries. On macOS, each full apply also [updates eligible Homebrew packages](../setup/macos.md#preview-and-apply).

Hosted native CI verifies actual installation and native interfaces separately from isolated unit fixtures.
It cannot establish physical desktop shortcuts, interactive approval, or the working directory of an opened GUI window; retain those observations separately.
