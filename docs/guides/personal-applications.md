# Personal CLI Applications

This guide explains how dotfiles installs and manages personal command-line tools under `~/.local/bin`, activates PATH integration across operating systems, maintains immutable release pins, and configures PowerShell mise activation.

## Managed Applications

Chezmoi provisions prebuilt binaries independently of the repository's mise development toolchain:

| Command | Upstream Repository | Package Kind | Supported Platforms |
|---|---|---|---|
| `bun` | [oven-sh/bun](https://github.com/oven-sh/bun) | Archive member, with managed `bunx` launcher | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `claude` | [anthropics/claude-code](https://github.com/anthropics/claude-code) | Official native binary | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `codex` | [openai/codex](https://github.com/openai/codex) | Canonical CLI package | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `pi` | [earendil-works/pi](https://github.com/earendil-works/pi) | Complete native distribution | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `grok` | [Grok Build](https://docs.x.ai/build/overview) | Official native binary | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `gh` | [cli/cli](https://github.com/cli/cli) | Archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `ghq` | [x-motemen/ghq](https://github.com/x-motemen/ghq) | Archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |
| `agy` | [Google Antigravity](https://antigravity.google/) | Official CLI binary or archive member | Windows (x64/ARM64), Linux (x64/ARM64), macOS (ARM64) |

> **Platform Constraint:** Prebuilt binaries require GNU libc on Linux; Linux musl hosts are not supported. The Linux asset architectures below describe binary availability and compatibility tests. Supported Linux workstation setup is [Ubuntu Studio 26.04 LTS amd64](../setup/ubuntu-studio.md).

Commands are exposed through `~/.local/bin`, including the native Claude Code executable (`claude.exe` on Windows). The Antigravity CLI payload lives in `~/.local/share/dotfiles/antigravity/bin`; its POSIX or Windows `.ps1` launcher selects that absolute path. Run Windows launchers from PowerShell. Provisioning these applications does not require a preinstalled Bun or Python runtime.

Codex includes its native helper executables, `~/.local/codex-package.json`, `~/.local/codex-path`, and `~/.local/codex-resources`. Keep these together: copying only `codex` is not a complete installation. The Codex-specific resource directories are reconciled exactly; unrelated programs in `~/.local/bin` are preserved. Upstream currently names its Linux packages `unknown-linux-musl`; that artifact name does not expand this repository's supported host policy.

## Installation and Updates

To install or reconcile personal CLI applications to the pinned releases:

```sh
# Apply personal applications from the registered checkout
chezmoi apply

# Or check for remote updates and apply
chezmoi update
```

Downloads and extracted files are cached by the rendered asset declarations.
An unchanged application checks file metadata and reuses the prepared files; missing files are restored from the cache.
New URLs or checksum pins prepare a new cache generation.
Unchanged URLs have no automatic download expiry.

For full verification and repair, explicitly apply from the current worktree:

```sh
mise run assets:verify
```

Use `mise run assets:refresh` to additionally force fresh downloads.
Both tasks apply personal configuration, including font and plugin reconciliation.
The outer `--refresh-externals` flag no longer controls these script-managed assets.
Normal application can miss modifications that preserve file size and modification time; full verification restores the declared content.

> **Windows Note:** Close running Claude Code and Codex sessions, including T3 Code sessions using them, before updating their executables to avoid file-lock errors. Run the update from a standard terminal window.

### Antigravity version ownership

This manages the official `agy` CLI, not the separate Antigravity GUI application.
The launchers disable CLI self-update with `AGY_CLI_DISABLE_AUTO_UPDATE=true`.
T3's native Antigravity provider uses a separate official ACP runtime installed through T3 provider settings. Dotfiles leaves that provider's configuration and authentication unchanged.

The old third-party `antigravity-acp` payload and launchers are no longer installed. Explicit apply removes their known executable paths and the old managed provider entry, while preserving unrelated files and native T3 providers.

To roll back, restore the desired `home/.chezmoidata/personal-app-lock.json` revision and explicitly apply again with Antigravity and T3 sessions closed. See [native CE integration](harness-plugins.md) and [T3 configuration and security limits](t3-code.md).

### Bun version ownership

Bun uses the same immutable release pins and checksum-verified preparation as the other personal CLI applications.
The managed `bunx` launcher calls that installation's `bun x`; it does not install a second runtime.
On Windows, run `bunx` from PowerShell, which discovers `~/.local/bin/bunx.ps1`.
The launchers preserve arguments and the child exit status, including in Windows PowerShell 5.1.

Refresh Bun through the personal application pin workflow below.
Running `bun upgrade` directly bypasses the committed pin; use `mise run assets:verify` to restore the pinned bytes after such a change.
To roll back, restore only Bun's entry in `home/.chezmoidata/personal-app-lock.json` and explicitly apply again with Bun processes closed.
Existing Bun installations elsewhere and Bun's package caches are retained; resolve any competing PATH entry if the managed command is not selected.
This installation does not add shell completions, install global packages, or change project package managers.

### Retired omp installation

Dotfiles no longer declares or pins omp and does not install or reconcile it. Applying the current source preserves an existing `~/.local/bin/omp` (`omp.exe` on Windows), `~/.omp` configuration, credentials, plugins, and session data. Existing completion files also remain on disk. A fresh home receives none of these omp files.

The T3 settings modify template separately removes the `omp` provider entry during explicit apply; see [Managed Settings](t3-code.md#managed-settings).

## PATH Integration

Applying personal settings configures your shell environment to discover commands in `~/.local/bin`.

### Windows PATH Activation

On Windows, the apply script updates the user PATH environment variable in the registry (`HKCU\Environment`).
- Existing expandable variables (`%USERPROFILE%`, etc.) and variable kinds are preserved.
- After running apply, close and reopen your terminal host from the desktop or Start menu so new processes inherit the updated registry environment. (Opening a new tab in an existing terminal may retain stale environment state).

### Unix PATH Activation (Linux & macOS)

On Linux and macOS, apply creates `~/.config/dotfiles/path.sh` and appends a source block to your shell startup files:
- Configures `.bashrc` and the existing Bash login profile (`.bash_profile`, `.bash_login`, or `.profile`).
- Configures `.zprofile` and `.zshrc` in the [managed XDG Zsh directory](zsh.md) on eligible hosts; otherwise respects an exported `ZDOTDIR`.
- PATH integration runs only on change; an unchanged apply will not overwrite manual removals.

### Checking Command Discovery

Verify that the managed commands take precedence:

```sh
# Windows PowerShell
Get-Command codex -All

# POSIX Shells
command -v codex
```

If another copy precedes `~/.local/bin`, resolve the conflicting PATH entry in your shell configuration.

On Apple Silicon macOS, explicit application also publishes native build roots and mise-owned Python/PowerShell/CMake/Ninja links under `~/.local/share/dotfiles/build`.
The PATH fragment loads these roots so native commands remain available outside a mise task.
Development tool versions remain declared in `mise.toml`/`mise.lock`; they are not duplicated as Homebrew packages.
See the [macOS setup guide](../setup/macos.md) for explicit Homebrew prerequisite provisioning, per-project Zsh activation, native build verification and the complete readiness checklist.

---

## Release Pin Architecture

Personal application versions are strictly pinned and checksum-verified:

1. **Authored Declarations (`home/.chezmoidata/personal-apps.json`):** Defines repository names, command names, asset naming patterns, and archive extraction rules.
2. **Locked Pins (`home/.chezmoidata/personal-app-lock.json`):** Contains resolved versions, immutable artifact URLs, and verified SHA-256 digests, or the official SHA-512 digests for Antigravity CLI.
3. **Asset Templates (`home/.chezmoitemplates/external-assets/`):** Read the declarations and lock to configure the isolated native chezmoi preparation source.

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
  "syncClaudeAiSkills": false,
  "syncClaudeAiPlugins": false,
  "disableClaudeAiConnectors": true,
  "env": { "DISABLE_AUTOUPDATER": "1" }
}
```

Fresh sessions default to Korean responses and do not read or write automatic memory. They also load no skills, plugins, or MCP connectors from the claude.ai account; see [Account Source Isolation](harness-plugins.md#claude-code) for what remains available. Existing memory files, credentials, sessions, and unrelated settings remain intact. Reapply restores these preferences after local edits. Native Claude settings precedence still applies; project settings or session overrides can take precedence over user preferences.

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

## Node.js

The `node` personal app installs the complete official distribution, including npm
and npx, under `~/.local/share/dotfiles/node`. Unix shells add its `bin` directory
to PATH; Windows adds the distribution root to the user PATH. Open a new terminal
after explicitly applying the configuration. These commands work outside this
repository without mise activation.

The daily pin updater selects the highest stable version from the official
Node.js release index, including future stable majors, and verifies archives
against the release's `SHASUMS256.txt`. Prereleases are excluded. The initial pin
is 26.13.0. The managed `.npmrc` sets the global prefix to `~/.local` on Unix
and `~/.local/bin` on Windows, preserving unrelated npm settings. Global package
commands therefore use the existing user PATH directory. Reapplying replaces the
Node.js distribution without deleting separately installed global packages.
