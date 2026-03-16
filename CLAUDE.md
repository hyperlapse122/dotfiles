# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal cross-platform dotfiles (Linux, macOS, Windows) managed with [Dotbot](https://github.com/anishathalye/dotbot). Files are symlinked from this repo into the home directory via Dotbot config files.

## Commands

```bash
# Full install (Linux/macOS) — installs brew packages, prezto, dotnet, mise runtimes, then runs Dotbot
./install.sh

# Full install (Windows)
pwsh -ExecutionPolicy Bypass -File ./Install.ps1

# Re-run Dotbot user-level symlinks only
mise exec -- sh ./install

# Re-run Dotbot system-level config (Linux, requires sudo)
mise exec -- sudo sh ./install-root

# macOS package sync
brew bundle --file=brew/Brewfile

# Lint/format JS/TS/JSON files
mise exec npm:@biomejs/biome -- biome check --write .
```

## Pre-commit Hook

Lefthook runs Biome on staged `*.{js,ts,cjs,mjs,jsx,tsx,json,jsonc}` files before commit. Biome config: 2-space indent, double quotes, recommended linter rules, JSON with comments/trailing commas allowed.

## Architecture

- **Dotbot** handles all symlinking. `install.conf.yaml` is the primary config; `install-root.conf.yaml` handles `/etc` files on Linux. `install-windows.conf.yaml` for Windows.
- **`dot*` directories** map to dotted destinations: `dotconfig/` → `~/.config/`, `dotssh/` → `~/.ssh/`, `dotclaude/` → `~/.claude/`, etc. Files are glob-linked.
- **`home/`** contains files linked directly to `~/` (e.g., `.zshrc`, `.gitconfig`).
- **`gitconfig.d/`** has per-OS git config fragments, conditionally linked.
- **`gnupg/`, `gnupg-macos/`, `gnupg-windows/`** — platform-specific GPG configs.
- **`dotbot/`** is a vendored submodule — treat as read-only third-party code.
- **`mise.toml`** and `dotconfig/mise/config.toml` manage runtime versions and tool CLIs.
- **`bootstrap.sh`** is the fresh-machine entry point (installs Homebrew on macOS, clones repo, runs `install.sh`).

## Key Conventions

- All Dotbot link entries must be **idempotent** (`relink: true`, `create: true`, `force: true`).
- Use **OS guards** (`if: "[ \`uname\` = Darwin ]"`) for platform-specific paths in shared configs.
- Shell scripts use `#!/usr/bin/env zsh` with `set -xeuo pipefail`.
- YAML/JSON: 2-space indentation, UTF-8, final newline.
- Never edit anything under `dotbot/` or `dotbot/lib/` — it's vendored.
- Commits should be small and focused. Describe why a change is needed.
