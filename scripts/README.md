# scripts/

Helpers shared by `install.sh` and `install.ps1`.

## Current scripts

| Script | Platform | Called by | Purpose |
|---|---|---|---|
| `auth-gh.sh` / `auth-gh.ps1` | macOS+Linux / Windows | Manual | Starts GitHub CLI web login for `github.com`, preferring system `gh` and falling back to `mise exec gh@latest -- gh` |
| `auth-glab.sh` / `auth-glab.ps1` | macOS+Linux / Windows | Manual | Starts GitLab CLI web login for `git.jpi.app` and `gitlab.com`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `setup-glab.sh` / `setup-glab.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Configures the `git.jpi.app` GitLab OAuth client ID for `glab`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `import-gpg-keys.sh` / `import-gpg-keys.ps1` | macOS+Linux / Windows | Manual | Reads the private GPG key from 1Password via `op read` and imports it with `gpg --batch --import` |
| `inject-1password-secrets.sh` / `inject-1password-secrets.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Finds every `*.1password` template in the repo, renders it with `op inject`, and writes it under `~/.secrets/<file-name-without-.1password>`; no-ops when no templates exist; secret files are mode `0600` on Unix, and secret directories are owner-only/traversable (`0700`) so the files remain readable by the owner |
| `install-fonts.sh` / `install-fonts.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Installs desktop fonts user-wide from GitHub Releases. Skips already-installed fonts unless `--force` / `-Force`. Add fonts via the registry block at the top of each script |
| `install-linux-system-config.sh` | Linux only | `install.linux.yaml` `shell:` step | Recursively discovers files in `system/linux/etc/` and runs `sudo install -D -m 644` to their absolute paths. The `etc/sudoers.d/*` subtree is special-cased: installed at mode `0440` and only on virtual machines (gated on `systemd-detect-virt --vm`); contents are syntax-checked with `visudo -c -f` before install |
| `install-packages.sh` | Linux only (Fedora-oriented) | Manual | Enables the keyd COPR, installs fcitx5/keyd/.NET/ripgrep/solaar packages with `dnf`, installs selected dotnet global tools, and enables `keyd` |
| `config-kde.sh` | Linux only (KDE Plasma 6) | `install.linux.yaml` `shell:` step (also runnable manually) | Configures KDE Plasma 6 user-side settings in five independent steps. **fonts** — sets display fonts in `~/.config/kdeglobals` via `kwriteconfig6`: sans-serif (`font`, `menuFont`, `toolBarFont`, `smallestReadableFont`, `[WM] activeFont`) → Pretendard, monospace (`fixed`) → JetBrainsMono Nerd Font. Errors if a requested font isn't installed (run `install-fonts.sh` first). **touchpad** — configures touchpads listed in `TOUCHPAD_TARGET_NAMES` (currently just `SynPS/2 Synaptics TouchPad`) via KWin's `org.kde.KWin.InputDeviceManager` DBus interface: `naturalScroll = true`, `clickMethodClickfinger = true` (two-finger tap = right-click, three-finger tap = middle-click), `clickMethodAreas = false`. Other touchpads (e.g. external USB trackpads) are left alone. Requires an active Plasma session — skips cleanly when KWin doesn't own `org.kde.KWin` on the session bus. **panel** — sets `groupingStrategy = 0` (`TasksModel::GroupDisabled`, "Do not group") on every panel-level `org.kde.plasma.icontasks` / `org.kde.plasma.taskmanager` applet in `~/.config/plasma-org.kde.plasma.desktop-appletsrc`, so each window gets its own taskbar entry instead of collapsing N windows of the same app into one. **kickoff** — sets `favoritesDisplay = 1` and `applicationsDisplay = 1` (`1` = list, `0` = grid per `plasma-desktop/applets/kickoff/main.xml`) on every panel-level `org.kde.plasma.kickoff` applet in the same file, so both the favorites pane ("Show favorites") and the all-apps pane ("Show other applications") render as flat scrollable lists instead of grids. **virtualkeyboard** — sets `[Wayland] InputMethod` in `~/.config/kwinrc` to `/usr/share/applications/fcitx5-wayland-launcher.desktop`, selecting "Fcitx 5 Wayland Launcher" as the KWin virtual keyboard / input-method launcher (matches System Settings → Keyboard → Virtual Keyboard). The kcfg schema (`/usr/share/config.kcfg/kwin.kcfg`) declares this entry as `type="Path"`, so the script passes `--type path` and KConfig writes the canonical `InputMethod[$e]=...` form. Soft-skips when `fcitx5-wayland-launcher.desktop` is missing (install `fcitx5` first via `install-packages.sh`). Each step is independently guarded; missing prereqs skip that step alone, and the whole script exits 0 on non-KDE systems (no `plasmashell`). Restart `plasmashell` or re-login to fully apply font/panel/kickoff changes; restart KWin (`kwin_wayland --replace`) or re-login to apply the virtual keyboard change; touchpad changes apply live via DBus |

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

Exception: helpers that are inherently single-platform (e.g. `install-linux-system-config.sh` writes to `/etc/`, `install-packages.sh` calls `dnf`) MAY skip parity — document the reason in a header comment in the script itself.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
