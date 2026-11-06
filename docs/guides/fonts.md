# User Fonts

Explicit chezmoi application installs the repository's pinned desktop fonts for the current user.
Worktree preparation with `mise install` does not install fonts or change font registrations.

## Collection

The initial lock selects 178 font files from eight official GitHub Release archives:

| Collection | Installed forms |
|---|---|
| JetBrains Mono | Static TTF weights and styles, including NL faces without ligatures |
| Pretendard | Static TTF weights and the canonical variable TTF |
| Pretendard JP, Std, and GOV | Static TTF weights and the canonical variable TTF for each family |
| D2Coding | Regular and bold TTFs, with and without ligatures |
| JetBrains Mono Nerd Font | Nerd Font, Nerd Font Mono, and Nerd Font Propo, including supplied NL faces |
| D2Coding Nerd Font | All three Nerd Font width forms; upstream names these faces D2KodingLigature |

Webfonts, OTF copies of the selected static TTFs, TTC collections, and JetBrains Mono variable fonts are excluded.
The selected font count can change with later releases; the lock records the exact files for each version.
Installation makes the fonts available to applications without changing an application's selected font.

## Install or Reconcile

From the intended repository worktree:

```sh
mise run apply
```

Or bind chezmoi directly to that worktree:

```sh
chezmoi --source . apply
```

The installers use native shell utilities or Windows PowerShell; applying fonts does not require Python.
Linux requires fontconfig, including `fc-cache`; install that prerequisite through the distribution's normal package manager before applying.
The installer reports a missing prerequisite without installing OS packages or requesting elevation.

| OS | User font location | Discovery |
|---|---|---|
| Windows | `%LOCALAPPDATA%/Microsoft/Windows/Fonts` | HKCU font registration, session resource loading, and a font-change notification |
| Linux | `${XDG_DATA_HOME:-$HOME/.local/share}/fonts/dotfiles` | fontconfig cache refresh |
| macOS | `~/Library/Fonts` | Native user-font discovery |

macOS follows the repository's native Apple Silicon support baseline in the [macOS setup guide](../setup/macos.md).
The baseline is maintained independently of font installation; [issue #65](https://github.com/hyperlapse122/dotfiles/issues/65) records the separate macOS 26 update.

Each apply verifies the staged files before changing installed fonts, repairs missing files or Windows registry entries, and leaves unchanged files in place.
Managed filenames start with `dotfiles-<package>-`.
The installers remove obsolete files recorded in `~/.local/share/dotfiles/installed-fonts.txt` on POSIX or `installed-fonts.json` on Windows.
They preserve unrelated fonts, including manually installed copies of the same family; such copies can still produce duplicate-family choices in applications.

## Release Updates

`home/.chezmoidata/fonts.json` declares repositories and desktop archive selections.
The generated `home/.chezmoidata/font-lock.json` records exact release tags, URLs, archive SHA-256 values, and the selected members' SHA-256 values.
When GitHub supplies no archive digest, the refresh downloads the archive and calculates one.
Installation follows the committed lock and does not resolve the latest release during apply.

Refresh pins from a prepared development worktree:

```sh
mise exec -- python scripts/update-font-lock.py
```

The dedicated `update-font-lock.yml` workflow supports scheduled and manual refreshes.
It validates the candidate lock before publishing changed pins.
Font refreshes do not change the executable application lock.

Apply the resulting repository changes explicitly to install an updated collection.
For a corrupted cached download, refresh externals from the current worktree:

```sh
chezmoi --source . apply --refresh-externals
```

## Windows Loaded-File Recovery

Windows can retain a loaded font file in another process or session after its resource registration has been removed.
The installer reports a failed replacement or deletion instead of recording a successful reconciliation.
For obsolete fonts, it removes owned HKCU registrations before attempting file deletion so those files are not loaded again at the next sign-in.

Close applications using the affected font and reapply.
If the file remains locked, sign out or restart, then reapply from a fresh terminal.
The repository does not stop font-cache services or restart the machine automatically.

## Verification

See [Development, Testing, and CI](../maintenance/development-and-testing.md#user-fonts) for focused tests and the native discovery smoke.
The smoke uses unique temporary ownership names and reports any Windows-held temporary files left after its registrations have been removed.
