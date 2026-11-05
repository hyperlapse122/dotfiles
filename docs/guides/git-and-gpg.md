# Git and GPG Configuration

This guide explains how this repository configures global Git identity, automatic commit signing, GPG pinentry dialogs, directory safety guards, and repository cloning with `ghq`.

## Overview

The repository manages global Git configuration (`~/.gitconfig`) and GPG agent pinentry settings (`gpg-agent.conf`) declaratively.

- **Author Identity:** Joosung Park (`hyperlapse@jpi.co.kr`)
- **Default Branch:** `main` (for newly initialized repositories)
- **Commit Signing:** Enabled by default using OpenPGP key `621512777E6933FEB4458FDC4945855D4F283F05`
- **Repository Root:** `~/src` (managed via `ghq.root`)

> **Important:** The entire global `~/.gitconfig` is repository-managed. Edit the source template in `home/dot_gitconfig.tmpl` rather than manually editing the generated file, as manual changes will be overwritten on the next apply.

## Prerequisites

Before applying dotfiles, verify that Git, GnuPG (including `gpgconf`), and a compatible pinentry program are installed.

Your signing key (and physical hardware token/YubiKey, if applicable) must already be configured on the host. This repository does not create, import, or distribute private keys or modify trust databases.

### Platform Executable Defaults

Platform paths are declared in `home/.chezmoidata/gpg.yaml`:

| Platform | GPG Executable | Pinentry Executable |
|---|---|---|
| Windows / Gpg4win | `C:/Program Files/GnuPG/bin/gpg.exe` | `C:/Program Files/Gpg4win/bin/pinentry.exe` |
| Linux | `/usr/bin/gpg` | `/usr/bin/pinentry` |
| macOS (Apple Silicon) | `/opt/homebrew/bin/gpg` | `/opt/homebrew/bin/pinentry-mac` |

`gpgconf` must reside in the same directory as the selected `gpg` executable.

### Custom Executable Overrides

If GnuPG or pinentry is installed in a non-standard location, set absolute paths in your persistent chezmoi TOML configuration (`~/.config/chezmoi/chezmoi.toml` on POSIX or `%USERPROFILE%/.config/chezmoi/chezmoi.toml` on Windows):

```toml
[data]
gpgProgram = "D:/Tools/GnuPG/bin/gpg.exe"
pinentryProgram = "D:/Tools/Gpg4win/bin/pinentry.exe"
```

## GPG Home Directory Safety

The expected GPG home directory is:
- **Windows:** `%USERPROFILE%\AppData\Roaming\gnupg`
- **Linux & macOS:** `~/.gnupg`

### Safety Guards

Before writing personal files, an explicit apply checks the effective GPG home reported by `gpgconf --list-dirs homedir`:
- If the effective location differs (e.g. Due to custom `GNUPGHOME` or registry overrides), the apply stops immediately.
- Symlinked GPG home directories or parent directory reparse points are rejected. On Windows, an existing path alias is accepted only if its volume serial and 128-bit file ID match the target directory.
- GnuPG reads `GNUPGHOME` via the Windows ANSI API; paths containing characters outside the system code page must use ASCII aliases.

> **Warning:** Do not bypass this check by forcing `--homedir` in personal scripts. GPG configuration must align with the OS-standard directory structure.

## GPG Agent Configuration and Reloading

The template modifies `gpg-agent.conf`, replacing only active `pinentry-program` lines. Comments, cache TTL settings, and extra agent options remain untouched.

Application triggers a reload of `gpg-agent` only when the underlying template or effective executable paths change. An unchanged apply checks GPG home safety but skips agent reload.

To inspect template drift without executing apply scripts, run:

```sh
chezmoi diff --exclude=scripts
```

## Verifying Commit Signing

To verify that signing and pinentry integration work end-to-end:

```sh
# 1. Create a temporary test repository
mkdir -p /tmp/git-sign-test && cd /tmp/git-sign-test
git init
git commit --allow-empty -m "test: verify signing"

# 2. Complete PIN or touch prompt when requested
# 3. Verify signature
git verify-commit HEAD
```

Clean up the test directory when finished.

## Repository Clones with ghq

Applying personal settings installs [ghq](https://github.com/x-motemen/ghq) to `~/.local/bin/ghq` and configures `ghq.root = ~/src` in `~/.gitconfig`.

### Usage

Clone repositories using standard ghq commands from any directory:

```sh
ghq get https://github.com/hyperlapse122/dotfiles.git
```

This clones the repository to:
```
~/src/github.com/hyperlapse122/dotfiles
```

This path matches the Windows bootstrap destination layout. If the clone already exists, `ghq get` leaves it untouched unless `-u` (update) is supplied.

To check your current ghq root:

```sh
ghq root
```

> **Note:** If an environment variable `GHQ_ROOT` is set in your shell, it overrides the `gitconfig` setting. Unset `GHQ_ROOT` to use `~/src`.
