# scripts/

Helpers shared by `install.sh` and `install.ps1`.

## Current scripts

| Script | Platform | Called by | Purpose |
|---|---|---|---|
| `auth-gh.sh` / `auth-gh.ps1` | macOS+Linux / Windows | Manual | Starts GitHub CLI web login for `github.com`, preferring system `gh` and falling back to `mise exec gh@latest -- gh` |
| `auth-glab.sh` / `auth-glab.ps1` | macOS+Linux / Windows | Manual | Starts GitLab CLI web login for `git.jpi.app` and `gitlab.com`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `setup-glab.sh` / `setup-glab.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Configures the `git.jpi.app` GitLab OAuth client ID for `glab`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `import-gpg-keys.sh` / `import-gpg-keys.ps1` | macOS+Linux / Windows | Manual | Reads the private GPG key from 1Password via `op read` and imports it with `gpg --batch --import` |
| `install-fonts.sh` / `install-fonts.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Installs desktop fonts user-wide from GitHub Releases. Skips already-installed fonts unless `--force` / `-Force`. Add fonts via the registry block at the top of each script |
| `install-linux-system-config.sh` | Linux only | `install.linux.yaml` `shell:` step | Recursively discovers files in `system/linux/etc/` and runs `sudo install -D -m 644` to their absolute paths |
| `install-packages.sh` | Linux only (Fedora-oriented) | Manual | Enables the keyd COPR, installs fcitx5/keyd/.NET/ripgrep/solaar packages with `dnf`, installs selected dotnet global tools, and enables `keyd` |
| `configure-kde-fonts.sh` | Linux only (KDE Plasma 6) | `install.linux.yaml` `shell:` step (also runnable manually) | Sets KDE display fonts in `~/.config/kdeglobals` via `kwriteconfig6`: sans-serif (`font`, `menuFont`, `toolBarFont`, `smallestReadableFont`, `[WM] activeFont`) → Pretendard, monospace (`fixed`) → JetBrainsMono Nerd Font. No-ops (exit 0) when `kwriteconfig6` or `plasmashell` is missing. Errors if a requested font isn't installed (run `install-fonts.sh` first). Restart `plasmashell` or re-login to fully apply |
| `configure-kde-touchpad.sh` | Linux only (KDE Plasma 6) | `install.linux.yaml` `shell:` step (also runnable manually) | Configures touchpads listed in `TARGET_NAMES` (currently just `SynPS/2 Synaptics TouchPad`) via KWin's `org.kde.KWin.InputDeviceManager` DBus interface: `naturalScroll = true`, `clickMethodClickfinger = true` (two-finger tap = right-click, three-finger tap = middle-click), `clickMethodAreas = false`. Requires an active Plasma session (KWin must own `org.kde.KWin` on the user session bus); no-ops (exit 0) when `busctl`/`plasmashell` are missing or no Plasma session is running, so this is safe to run during arch-chroot / on non-KDE systems. KWin persists changes to `~/.config/kcminputrc` automatically; settings also apply live |

## Adding a new font

Both `install-fonts.sh` and `install-fonts.ps1` keep their list of fonts in a single registry block at the top of the file. Append one entry **to both files** (the parity rule applies to data, not just code):

- **Bash** (pipe-delimited): `name|repo|asset_pattern|marker_glob|src_dirs`
- **PowerShell** (hashtable): `Name`, `Repo`, `AssetPattern`, `Marker`, `SourceDirs`

`asset_pattern` / `AssetPattern` is a glob handed to `gh release download --pattern`; it MUST match exactly one asset in the upstream repo's latest release.

`marker_glob` / `Marker` is a filename or glob (e.g. `D2Coding-Ver*.ttf`). Any file in the user font directory matching the pattern means "already installed" and the entry is skipped — pass `--force` / `-Force` to override. Pick a marker distinct from other entries' markers to avoid false positives.

`src_dirs` / `SourceDirs` lists directories *inside the unzipped archive* whose `.ttf`, `.otf`, and `.ttc` files should be installed. Use `.` (or `./`) for the archive root. Other files (e.g. `web/`, `webfonts/`, `LICENSE`) are ignored.

## Script parity rule

Every helper here ships in **both** forms:

| Surface | Extension | Targets |
|---|---|---|
| POSIX | `.sh` (`#!/usr/bin/env bash`) | macOS + Linux |
| PowerShell | `.ps1` | Windows |

Adding `foo.sh` without `foo.ps1` is a regression. If a helper is meaningless on one platform, the parity script SHOULD exit with a clear error, NOT silently no-op.

Exception: helpers that are inherently single-platform (e.g. wrappers around Linux-only `pacman`) MAY skip parity — document the reason in a header comment in the script itself.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
