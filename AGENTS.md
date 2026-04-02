# AGENTS.md

**Generated:** 2026-04-03 | **Commit:** 389a20b | **Branch:** main

## OVERVIEW

Personal cross-platform dotfiles managed with Dotbot and split into user-level (`install` / `install.conf.yaml`) and root-level (`install-root` / `install-root.conf.yaml`) installation paths.

## STRUCTURE

```text
dotfiles/
├── bootstrap.sh            # Fresh POSIX machine entry (clone + source install.sh)
├── install.sh              # Main Linux/macOS installer (mise, prezto, brew, dotbot)
├── Install.ps1             # Main Windows installer (dotbot + tool bootstrap)
├── install                 # Dotbot shim → install.conf.yaml (user-level)
├── install-root            # Dotbot shim → install-root.conf.yaml (sudo /etc)
├── install.conf.yaml       # Primary user-level Dotbot config (Linux/macOS)
├── install-windows.conf.yaml # Primary user-level Dotbot config (Windows)
├── install-root.conf.yaml  # System-level Dotbot config → /etc/*
├── home/                   # Dotfiles linked to ~ (e.g. .zshrc, .gitconfig)
├── dotconfig/              # → ~/.config/* (glob-linked)
├── dotlocal/               # → ~/.local/*
├── dotssh/                 # → ~/.ssh/* (shared)
├── dotssh-macos/           # → ~/.ssh/* (macOS-only, overlays dotssh/)
├── dotagents/              # → ~/.agents (AI agent skills, see dotagents/AGENTS.md)
├── dotnet/                 # dotnet install scripts (sh + ps1)
├── gitconfig.d/            # per-OS git config fragments
├── gnupg/                  # Linux GPG config
├── gnupg-macos/            # macOS GPG config
├── gnupg-windows/          # Windows GPG config
├── etc/                    # root-managed system files (keyd, libinput, udev, etc)
├── archinstall/            # Arch Linux 3-phase provisioning (root → user → reboot)
├── Library/                # macOS ~/Library overrides (LaunchAgents)
├── vscode/                 # VS Code extension sync scripts/list
├── brew/                   # Brewfile
├── dotbot/                 # VENDORED submodule (read-only)
├── .github/                # GitHub Actions (Pages deploy for remote provisioning)
└── mise.toml               # Base runtime versions
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add new shared dotfile | `dotconfig/`, then run installer | Auto-globbed into `~/.config/*` |
| Add home-level dotfile | `home/` | Linked to `~/.*` via `install*.conf.yaml` |
| Add agent config | `dotagents/`, then run installer | Linked to `~/.agents`; see `dotagents/AGENTS.md` |
| Add symlink mapping | `install.conf.yaml` / `install-windows.conf.yaml` | Keep link entries idempotent |
| Add system-level Linux config | `etc/` + `install-root.conf.yaml` | Requires `sudo` via `install-root` |
| macOS setup | `brew/Brewfile` + `Library/` | Brew triggered by `install.sh` on Darwin |
| Windows setup | `Install.ps1` + `install-windows.conf.yaml` | Uses Dotbot with Windows paths |
| Runtime/tool versions | `mise.toml` + `dotconfig/mise/config.toml` | Includes package CLI tools |
| VS Code extensions | `vscode/extensions.txt` | Sync via `vscode/install.sh` or `vscode/install.ps1` |
| Editor configs | `dotconfig/zed/`, `dotconfig/Code/User/` | Zed and VS Code settings (glob-linked) |

## CONVENTIONS

### Naming
- `dot*` prefix means destination has a leading dot (for example, `dotconfig/` → `~/.config/`).
- `.d` directories should use numeric prefixes for load order when relevant.

### Dotbot Configs
- User-level install configs should keep link entries idempotent (`relink: true`, `create: true`, `force: true`).
- Use OS guards in shared configs when a path is platform-specific.
- Prefer glob-based links for per-file mapping (for example, `path: dotconfig/**/*`).

### Shell Selection
- Windows command examples and automation should use `pwsh`.
- Linux/macOS command examples and automation should use `zsh` or `bash`.

### Shell Scripts
- POSIX scripts use `#!/usr/bin/env zsh` and `set -xeuo pipefail`.
- Resolve script directory before relative path usage (`DIR=...` pattern).

### Formatting
- YAML/JSON: 2-space indentation, UTF-8, final newline.
- JS/JSON formatting: `biome format --write`.
- Dotbot Python changes (if ever needed): format/lint with `hatch fmt`.

## ANTI-PATTERNS

| Forbidden | Why |
|-----------|-----|
| Edit `dotbot/` or `dotbot/lib/` | Vendored dependency; treat as third-party |
| Non-idempotent Dotbot link entries | Installers must be safely re-runnable |
| Unconditional OS-specific paths in shared configs | Breaks cross-platform installs |
| Recursive clean operations on `~` | High-risk and slow on real machines |

## VENDORED: dotbot/

Treat as read-only third-party code. Current submodule pointer: `830da25a`.

If you need Dotbot extensions, add a plugin outside `dotbot/` and register it in install config:
```yaml
- plugins:
    - path/to/my_plugin.py
```

Useful commands (run inside `dotbot/`):
```bash
hatch test
hatch test tests/test_link.py
hatch fmt
hatch run types:check
```

## COMMANDS

```bash
# Re-run install (Linux/macOS)
./install.sh

# Re-run install (Windows)
pwsh -ExecutionPolicy Bypass -File ./Install.ps1

# Manual Dotbot user config (Linux/macOS)
mise exec -- sh ./install

# Manual Dotbot system config (Linux/macOS)
mise exec -- sudo sh ./install-root

# macOS package sync
brew bundle --file=brew/Brewfile

# Arch post-install scripts
curl https://dotfiles.h82.dev/archinstall/initialize.sh | bash      # root
curl https://dotfiles.h82.dev/archinstall/initialize-user.sh | bash # user
curl https://dotfiles.h82.dev/archinstall/initialize-after-boot.sh | bash # root (after reboot to system)
```

## PLATFORM MATRIX

| Feature | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Entry point | `install.sh` | `install.sh` | `Install.ps1` |
| User Dotbot config | `install.conf.yaml` | `install.conf.yaml` | `install-windows.conf.yaml` |
| Root/system config | `install-root.conf.yaml` | `install-root.conf.yaml` | n/a |
| Git config fragment | `gitconfig.d/linux.gitconfig` | `gitconfig.d/macos.gitconfig` | `gitconfig.d/windows.gitconfig` |
| Agent config dirs | `dotagents` → `~/.agents` | `dotagents` → `~/.agents` | `dotagents` → `~/.agents` |
| GPG config | `gnupg/` | `gnupg-macos/` | `gnupg-windows/` |
| Preferred shell | `zsh` / `bash` | `zsh` / `bash` | `pwsh` |

## NOTES

- GitHub Actions deploys repository contents to GitHub Pages (`dotfiles.h82.dev`) for remote provisioning scripts.
- `mise` manages core runtimes and tool CLIs (including `@openai/codex` in `dotconfig/mise/config.toml`).
- Prezto is cloned on first install to `~/.zprezto` and is not vendored in this repository.
- System-level Linux files are centralized under `etc/` and installed through `install-root.conf.yaml`.
- `dotagents/skills/` contains AI agent skills managed by OpenCode's skill system. See `dotagents/AGENTS.md`.
