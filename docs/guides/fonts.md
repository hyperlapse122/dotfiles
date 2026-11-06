# User Fonts

Explicit chezmoi application installs the repository's pinned desktop fonts for the current user.
Worktree preparation with `mise install` does not install fonts or change font registrations.

## Collection

The lock selects 194 font files from nine official GitHub Release archives:

| Collection | Installed forms |
|---|---|
| Jetendard | All 16 static TTF weights and styles, with JetBrains Mono Nerd Font Mono Latin and Pretendard Korean glyphs |
| JetBrains Mono | Static TTF weights and styles, including NL faces without ligatures |
| Pretendard | Static TTF weights and the canonical variable TTF |
| Pretendard JP, Std, and GOV | Static TTF weights and the canonical variable TTF for each family |
| D2Coding | Regular and bold TTFs, with and without ligatures |
| JetBrains Mono Nerd Font | Nerd Font, Nerd Font Mono, and Nerd Font Propo, including supplied NL faces |
| D2Coding Nerd Font | All three Nerd Font width forms; upstream names these faces D2KodingLigature |

Webfonts, OTF copies of the selected static TTFs, TTC collections, and JetBrains Mono variable fonts are excluded.
The selected font count can change with later releases; the lock records the exact files for each version.
Installation makes the fonts available to applications.
Managed application settings select `Jetendard` for Ghostty and T3 Code coding surfaces, and `Pretendard Variable` for T3 Code's main interface and ordinary conversation text.
The variable family's selectable name is `Pretendard Variable`, not `Pretendard` or the filename `PretendardVariable.ttf`.
Sizes, line spacing, themes, and separate T3 composer preferences remain local.
See [Ghostty](terminal.md#managed-configuration-and-native-boundaries) and [T3 Code](t3-code.md#personal-preferences) for ownership and platform scope.
Terminal-rendered Claude Code, Codex, omp, and Antigravity tools inherit their host's font; dotfiles does not add independent font settings to those CLIs or manage Windows Terminal.

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

Each apply checks staged and installed file metadata, repairs missing files or Windows registry entries, and leaves unchanged files in place.
Changed metadata triggers checksum verification; unchanged files reuse the prior successful verification.
Changes that preserve file size and modification time may remain undetected until full verification is requested.
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
For a full integrity check and repair, run this explicit application from the current worktree:

```sh
mise run assets:verify
```

If the downloaded archive itself is corrupted, force a new download and application with `mise run assets:refresh`.
Both tasks apply this worktree's personal configuration, including native font and plugin reconciliation.
The outer chezmoi `--refresh-externals` flag does not refresh assets managed by the preparation script.

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
