# Personal CLI Applications

This guide explains how dotfiles installs and manages personal command-line tools under `~/.local/bin`, activates PATH integration across operating systems, maintains immutable release pins, and configures PowerShell mise activation.

## Managed Applications

Chezmoi provisions prebuilt binaries independently of the repository's mise development toolchain:

| Command | Upstream Repository | Package Kind | Supported Platforms |
|---|---|---|---|
| `claude` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | Official native binary | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `codex` | [openai/codex](https://github.com/openai/codex) | Canonical CLI package | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `omp` | [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi) | Raw binary | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `gh` | [cli/cli](https://github.com/cli/cli) | Archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `ghq` | [x-motemen/ghq](https://github.com/x-motemen/ghq) | Archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (x64/ARM64) |
| `agy` | [Google Antigravity](https://antigravity.google/) | Official CLI binary or archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `antigravity-acp` | [shubzkothekar/antigravity-acp](https://github.com/shubzkothekar/antigravity-acp) | Compiled adapter with managed launcher | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |

> **Platform Constraint:** Prebuilt binaries require GNU libc on Linux; Linux musl hosts are not supported.

Commands are exposed through `~/.local/bin`, including the native Claude Code executable (`claude.exe` on Windows). Antigravity CLI and ACP payloads live separately in `~/.local/share/dotfiles/antigravity/bin` and `~/.local/share/dotfiles/antigravity-acp/bin`; their POSIX launchers or Windows `.cmd` wrappers select those absolute paths. Device application does not require a Bun or Python runtime.

Codex includes its native helper executables, `~/.local/codex-package.json`, `~/.local/codex-path`, and `~/.local/codex-resources`. Keep these together: copying only `codex` is not a complete installation. The Codex-specific resource directories are reconciled exactly; unrelated programs in `~/.local/bin` are preserved. Upstream currently names its Linux packages `unknown-linux-musl`; that artifact name does not expand this repository's supported host policy.

## Installation and Updates

To install or reconcile personal CLI applications to the pinned releases:

```sh
# Apply personal applications from the registered checkout
chezmoi apply

# Or check for remote updates and apply
chezmoi update
```

If a cached archive download is corrupted, force chezmoi to re-download externals:

```sh
chezmoi apply --refresh-externals
```

> **Windows Note:** Close running Claude Code, Codex, and omp sessions, including T3 Code sessions using them, before updating their executables to avoid file-lock errors. Run the update from a standard terminal window.

### Antigravity version ownership

This manages the official `agy` CLI, not the separate Antigravity GUI application.
The launchers disable CLI self-update with `AGY_CLI_DISABLE_AUTO_UPDATE=true`.
The ACP launcher selects the locked CLI with `AGY_BIN` and prevents the adapter from downloading another copy with `AGY_SKIP_DOWNLOAD=1`.
Reapplying uses the committed lock; it does not resolve a newer release.

Explicit apply removes the reserved `agy` and `agy.exe` paths from `~/.local/share/dotfiles/antigravity-acp/bin`, where the adapter otherwise prefers them over `AGY_BIN`. Other files in that directory and unrelated application directories are preserved.

To roll back, restore the desired `home/.chezmoidata/personal-app-lock.json` revision and explicitly apply again with Antigravity and T3 sessions closed. See [native CE integration](harness-plugins.md) and [T3 configuration and security limits](t3-code.md).

## PATH Integration

Applying personal settings configures your shell environment to discover commands in `~/.local/bin`.

### Windows PATH Activation

On Windows, the apply script updates the user PATH environment variable in the registry (`HKCU\Environment`).
- Existing expandable variables (`%USERPROFILE%`, etc.) and variable kinds are preserved.
- After running apply, close and reopen your terminal host from the desktop or Start menu so new processes inherit the updated registry environment. (Opening a new tab in an existing terminal may retain stale environment state).

### Unix PATH Activation (Linux & macOS)

On Linux and macOS, apply creates `~/.config/dotfiles/path.sh` and appends a source block to your shell startup files:
- Configures `.bashrc` and the existing Bash login profile (`.bash_profile`, `.bash_login`, or `.profile`).
- Configures `.zshenv`, respecting an exported `ZDOTDIR` if set.
- PATH integration runs only on change; an unchanged apply will not overwrite manual removals.

### Checking Command Discovery

Verify that the managed commands take precedence:

```sh
# Windows PowerShell
Get-Command omp -All

# POSIX Shells
command -v omp
```

If another copy precedes `~/.local/bin`, resolve the conflicting PATH entry in your shell configuration.

---

## Release Pin Architecture

Personal application versions are strictly pinned and checksum-verified:

1. **Authored Declarations (`home/.chezmoidata/personal-apps.json`):** Defines repository names, command names, asset naming patterns, and archive extraction rules.
2. **Locked Pins (`home/.chezmoidata/personal-app-lock.json`):** Contains resolved versions, immutable artifact URLs, and verified SHA-256 digests, or the official SHA-512 digests for Antigravity CLI.
3. **Externals Template (`home/.chezmoiexternals/personal-apps.toml.tmpl`):** Reads the declarations and lock to configure chezmoi external archives.

### Refreshing Application Pins

To resolve the latest releases from each declared source and update the lockfile:

```sh
mise exec -- python scripts/update-personal-app-lock.py
```

The script queries GitHub using active `gh` authentication, GitLab through its public release API, Claude Code through its official release manifest, and Antigravity CLI through Google's official per-platform manifests. All eligible Antigravity CLI manifests must agree on a stable version. It replaces the lock only after every application's required assets and digests resolve successfully. Never edit URLs to point to `latest/download` directly.

To roll back a personal CLI application, restore its entry in `home/.chezmoidata/personal-app-lock.json` from the desired repository revision and explicitly apply again. For Codex, that one locked archive supplies the CLI and all package companions, so they roll back together.

### Claude Code Version and Preferences

Claude Code starts at the committed `2.1.318` pin. Its `source: "claude"` declaration reads the official `downloads.claude.ai/claude-code-releases` version metadata and manifest when refreshing pins. Apply downloads the versioned native binary and checks its committed SHA-256; it does not run the upstream auto-updating installer. The Linux targets use glibc binaries, and macOS coverage remains ARM64 only.

Explicit apply owns these values in private `~/.claude/settings.json`:

```json
{
  "language": "korean",
  "autoMemoryEnabled": false,
  "env": { "DISABLE_AUTOUPDATER": "1" }
}
```

Fresh sessions default to Korean responses and do not read or write automatic memory. Existing memory files, credentials, sessions, and unrelated settings remain intact. Reapply restores these preferences after local edits. Native Claude settings precedence still applies; project settings or session overrides can take precedence over user preferences.

Run `claude auth login` manually before authenticated use, or provision credentials through a supported Claude mechanism. Never commit a plaintext API key or credentials file. The default `~/.claude` is managed; a custom direct-session `CLAUDE_CONFIG_DIR` remains unmanaged. See [Harness Plugins](harness-plugins.md#compound-engineering-plugin-for-claude-code) for CE and shared instructions, and [T3 Code](t3-code.md#managed-settings) for the native provider.

To roll Claude back, restore its entry in `home/.chezmoidata/personal-app-lock.json`, close Claude and T3 Code, and explicitly apply again. A disposable Windows x64 apply check has verified a `2.1.318` to `2.1.317` executable rollback.

### Automated Updates

A GitHub Actions workflow (**Update personal application pins**) runs daily at 06:23 UTC:
1. Resolves candidate release pins using `secrets.GITHUB_TOKEN`.
2. Validates new binaries against the native test matrix.
3. Commits the updated `personal-app-lock.json` directly to `main` if all checks pass.

---

## PowerShell Mise Activation

Applying personal settings installs automatic `mise` activation into each PowerShell runtime's `CurrentUserAllHosts` profile:

```powershell
(&mise activate pwsh) | Out-String | Invoke-Expression
```

### Profile Replacement Policy

> **Warning:** Dotfiles completely replaces the selected profile file. Unmanaged local additions in that specific file are overwritten. Put persistent customizations in repository templates or host-specific profiles.

### Scope and Execution

- **Windows:** Updates both Windows PowerShell 5.1 (`Documents\WindowsPowerShell\profile.ps1`) and modern PowerShell 7 (`Documents\PowerShell\profile.ps1`).
- **macOS & Linux:** Updates modern PowerShell (`~/.config/powershell/profile.ps1`).
- Mise must already be available on your startup PATH.
- Sessions started with `-NoProfile` or execution policies that block scripts do not execute profile activation.
