# AGENTS.md

**Generated:** 2026-01-03 | **Commit:** c3b8b67 | **Branch:** main

## OVERVIEW

Personal dotfiles using Dotbot for cross-platform (Linux/macOS/Windows) symlink management. Split-privilege architecture: user configs (`install`) + root configs (`install-root`).

## STRUCTURE

```
dotfiles/
├── bootstrap.sh          # Fresh machine entry (clones repo, sources install.sh)
├── install.sh            # Main installer (mise, prezto, brew, dotbot)
├── install                # Dotbot shim → install.conf.yaml (user-level)
├── install-root           # Dotbot shim → install-root.conf.yaml (sudo, /etc/)
├── install.conf.yaml      # Primary Dotbot config (symlinks to ~/)
├── install-root.conf.yaml # System configs (/etc/keyd, /etc/libinput)
├── install-windows.conf.yaml # Windows-specific paths
├── dotconfig/             # → ~/.config/ (granular glob symlinks)
├── dotlocal/              # → ~/.local/
├── dotssh/                # → ~/.ssh/
├── zsh/                   # → ~/ (shell configs)
├── gnupg/                 # → ~/.gnupg/ (Linux)
├── gnupg-macos/           # macOS GPG variant
├── gnupg-windows/         # Windows GPG variant
├── git/                   # posix.gitconfig / windows.gitconfig
├── vscode/                # VS Code settings + extensions
├── brew/                  # Brewfile (macOS)
├── archinstall/           # Arch Linux full-system bootstrap
├── macos/                 # macOS defaults configuration
├── keyd/                  # Keyboard remapping (Linux /etc/)
├── libinput/              # Input quirks (Linux /etc/)
├── dotbot/                # VENDORED - do not modify (see below)
└── mise.toml              # Runtime versions (node, python)
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add new dotfile | `dotconfig/`, then re-run `./install.sh` | Auto-globbed to ~/.config/ |
| Add symlink mapping | `install.conf.yaml` | Use `relink: true, create: true, force: true` |
| System-level config | `install-root.conf.yaml` + `keyd/` or `etc/` | Requires `sudo` |
| macOS setup | `macos/configure.sh` + `brew/Brewfile` | Runs via `install.sh` on Darwin |
| Windows setup | `install-windows.conf.yaml` + `Install.ps1` | Different path mappings |
| Fresh Arch install | `archinstall/` | Full provisioning scripts |
| VS Code extensions | `vscode/extensions.txt` | `vscode/install.sh` to sync |

## CONVENTIONS

### Naming
- `dot*` prefix = destination has leading `.` (`dotconfig/` → `~/.config/`)
- `.d` directories use **numeric prefixes** for load order (`50-input.conf`, `80-pinentry.conf`)

### Dotbot Configs
- ALL link entries MUST use: `relink: true`, `create: true`, `force: true` (idempotency)
- Platform guards: `if: '[ \`uname\` = Linux ]'` or `if: '[ \`uname\` = Darwin ]'`
- Glob patterns: `path: dotconfig/**/*` (individual symlinks, not directory links)
- NO trailing slashes on directory paths

### Shell Scripts
- Shebang: `#!/usr/bin/env zsh`
- Error handling: `set -xeuo pipefail`
- Platform detection: `os=$(uname); [[ "$os" == "Darwin" ]]`
- Script directory: `DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- Internal vars: underscore prefix (`_OS`, `_PWD`)

### Formatting
- YAML/JSON: 2-space indent, LF, UTF-8, final newline
- Biome for JS/JSON (root): `biome format --write`
- Python (dotbot/): 4-space indent, Ruff (`hatch fmt`)

## ANTI-PATTERNS

| Forbidden | Why |
|-----------|-----|
| Edit `dotbot/` or `dotbot/lib/` | Vendored dependency - treat as third-party |
| `as any`, `@ts-ignore` | Type safety |
| Non-idempotent YAML entries | Install must be re-runnable |
| Trailing slash in link paths | Dotbot behavior differs |
| `print()` in Python | Use project messenger/logging |
| Recursive clean on `~` | Performance disaster |

## VENDORED: dotbot/

Treat as **read-only third-party code**. Currently at upstream commit `04698061`.

If extending Dotbot, create a plugin file elsewhere and register in `install.conf.yaml`:
```yaml
- plugins:
    - path/to/my_plugin.py
```

Dev commands (from `dotbot/` dir):
```bash
hatch test                    # Run tests
hatch test tests/test_link.py # Single file
hatch fmt                     # Ruff format/lint
hatch run types:check         # Mypy strict
```

## COMMANDS

```bash
# Fresh machine
./bootstrap.sh

# Re-run after changes
./install.sh

# Manual dotbot (user)
mise exec -- sh ./install

# Manual dotbot (system)
mise exec -- sudo sh ./install-root

# macOS only
brew bundle --file=brew/Brewfile

# Arch post-install
curl https://dotfiles.h82.dev/archinstall/initialize.sh | bash      # root
curl https://dotfiles.h82.dev/archinstall/initialize-user.sh | bash # user
```

## PLATFORM MATRIX

| Feature | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Entry | `install.sh` | `install.sh` | `Install.ps1` |
| Config | `install.conf.yaml` | `install.conf.yaml` | `install-windows.conf.yaml` |
| Git | `git/posix.gitconfig` | `git/posix.gitconfig` | `git/windows.gitconfig` |
| GPG | `gnupg/` | `gnupg-macos/.gnupg/` | `gnupg-windows/` |
| Pkg mgr | `pacman`/`yay` | `brew` | `winget` |
| Shell | `zsh`+prezto | `zsh`+prezto | `pwsh` |

## NOTES

- CI deploys repo to GitHub Pages (`dotfiles.h82.dev`) for `archinstall/` remote access
- `mise` manages runtimes AND executes dotbot (`mise exec -- sh ./install`)
- Prezto cloned to `~/.zprezto` on first run (not in repo)
- `.yarn/releases/` contains Yarn Berry - not application config
