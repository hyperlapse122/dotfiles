# Ghostty and the Login Shell

Explicit personal configuration installs Ghostty, selects it through the platform's native default-terminal mechanism, and uses the account's zsh login shell.
Windows terminal settings are outside this configuration.

## Supported Devices

| Platform | Installation | Native default selection |
|---|---|---|
| Ubuntu Desktop 24.04, GNOME, amd64/arm64 | Pinned community Debian package | System-wide `x-terminal-emulator` alternative |
| Ubuntu Desktop 26.04, GNOME, amd64/arm64 | Official Ubuntu APT package | User `ubuntu-xdg-terminals.list` preference |
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
Only package installation and Ubuntu 24.04 alternatives operations use narrow `sudo` commands.

Complete any package-manager or `chsh` authentication prompt.
macOS uses the selected Command Line Tools Swift runtime for its native association helper and may request OS approval in a desktop session.
Declined approval, a missing desktop session, or an approval that does not finish within two minutes is reported as pending.
A missing required tool or failed configuration command is an error.

Pending user actions do not stop subsequent GitHub/GitLab authentication hooks: apply reports the pending action and returns zero for this stage.
Use the separate status command below to distinguish pending configuration from readiness.

## Managed Configuration and Native Boundaries

Application replaces Ghostty's primary configuration with the repository's default-only content.
It writes `config.ghostty` under `${XDG_CONFIG_HOME:-$HOME/.config}/ghostty` and, on macOS, `~/Library/Application Support/com.mitchellh.ghostty`.
An existing legacy `config` in either location is reset to the same content, so its later load cannot restore a shell command or included configuration.
This intentionally replaces personal Ghostty themes, key bindings, and command overrides; save any customization you want to retain before application.
The repository adds no appearance overrides, zsh framework, or shell plugins.

Ghostty discovers the default shell from the system rather than a managed `command = zsh` override.
Existing Bash/zsh PATH integration remains in place and honors exported `ZDOTDIR`.
Unchanged PATH hooks retain their existing change-driven behavior; terminal reconciliation runs on every explicit apply.

Ubuntu 24.04's alternatives choice affects the machine, including other users of `x-terminal-emulator`.
Only a package-owned Ghostty executable already registered by its package is selected; a retained private build remains pending and is never registered system-wide.
Ubuntu 26.04 places the installed Ghostty desktop entry first in the effective XDG configuration directory's `ubuntu-xdg-terminals.list`, preserving other entries.
The APT package uses `com.mitchellh.ghostty.desktop`; a retained `/snap/bin/ghostty` installation uses `ghostty_ghostty.desktop`.
Native launchers using those mechanisms should select Ghostty, including the corresponding GNOME terminal shortcut.
Ubuntu 24.04's GNOME-terminal-specific Nautilus extension is not replaced.

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

Status returns `0` for ready, `2` for pending user/session/configuration actions, and `1` for an error.
It checks the account shell, managed Ghostty files, native default selection, and available session-shell evidence without changing them.
Ubuntu also checks the systemd user-manager environment; unavailable manager evidence remains pending.
Status does not prove that a GUI window actually opened or that a file-manager request kept its selected directory.

## Ubuntu 24.04 Package Maintenance

`home/.chezmoidata/ghostty.yaml` records the community `mkasberg/ghostty-ubuntu` release URLs and SHA-256 values for both architectures.
The current pin is `1.3.1-0-ppa2`.
This standalone package is not signed by the Ubuntu archive and does not acquire future Ghostty updates through ordinary `apt upgrade`.
The repository verifies its reviewed digest before privileged installation; APT resolves dependencies through the configured Ubuntu repositories.
No persistent third-party PPA or remote installer script is added.

To update the pin, review the community release's supported Ubuntu version, download both architecture assets, verify their hashes, and inspect their package metadata and maintainer scripts before changing the declaration.
Keep Ubuntu 24.04 runtime compatibility: a newer Ghostty build can require newer GTK libraries than this release supplies.
Updating the declaration affects missing installations; ordinary reapplication deliberately retains an existing installation.

To intentionally install the repository-pinned version on an existing Ubuntu 24.04 device, run the following from the repository root after reviewing the declaration:

```sh
(
  set -eu
  ghostty_host=$(. /etc/os-release; printf '%s:%s' "$ID" "$VERSION_ID")
  [ "$ghostty_host" = ubuntu:24.04 ] || { printf '%s\n' 'Requires Ubuntu 24.04.' >&2; exit 1; }
  ghostty_url=$(mise exec -- chezmoi --config "$PWD/.chezmoi-bootstrap.toml" --source "$PWD" \
    execute-template '{{ (index .ghostty.ubuntu2404 .chezmoi.arch).url }}')
  ghostty_sha256=$(mise exec -- chezmoi --config "$PWD/.chezmoi-bootstrap.toml" --source "$PWD" \
    execute-template '{{ (index .ghostty.ubuntu2404 .chezmoi.arch).sha256 }}')
  ghostty_stage=$(mktemp -d)
  trap 'rm -rf -- "$ghostty_stage"' EXIT HUP INT TERM
  ghostty_package="$ghostty_stage/ghostty.deb"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$ghostty_package" "$ghostty_url"
  printf '%s  %s\n' "$ghostty_sha256" "$ghostty_package" | sha256sum --check -
  sudo apt-get install -y "$ghostty_package"
)
```

Ubuntu 26.04 and macOS retain their normal explicit APT/Homebrew update paths.
This repository's apply operation does not request those upgrades.

## Desktop Acceptance Checklist

After applying and renewing the session:

1. Run status and resolve every pending action or error.
2. On Ubuntu GNOME, use the native terminal shortcut and confirm Ghostty opens; on macOS, open a suitable Unix executable through its native association and confirm the selected app.
3. In a newly launched Ghostty shell, check `printf '%s\n' "$SHELL"`, `ps -p $$ -o comm=`, and discovery of the repository-managed commands.
4. Where a native file-manager terminal action uses the managed dispatcher, select a known folder and check `pwd` in the new terminal.
5. Repeat the directory check with Ghostty already running, because preference selection alone does not prove existing-instance working-directory forwarding.
6. Apply again and confirm the intended defaults remain selected without duplicate shell startup entries or application upgrades.

Hosted native CI verifies actual installation and native interfaces separately from isolated unit fixtures.
It cannot establish physical desktop shortcuts, interactive approval, or the working directory of an opened GUI window; retain those observations separately.
