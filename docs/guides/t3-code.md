# T3 Code Desktop and Harness Integration

This guide describes how dotfiles installs the [T3 Code](https://github.com/pingdotgg/t3code) desktop application, provisions bundled command-line launchers, and configures native Claude Code and Codex plus oh-my-pi (omp) and Antigravity ACP providers.

## Platform Support and Installation

T3 Code is supported on:
- **Windows (x64 and ARM64):** Installed via WinGet (`T3Tools.T3Code`, declared in `home/.chezmoidata/windows.yaml`).
- **macOS (Apple Silicon):** Installed via Homebrew cask (`t3-code`) if no existing app is detected.
- **Ubuntu (x64 and ARM64):** Staged via a checksum-verified `.deb` external and installed via `apt`.

> **Note:** Intel Mac support is not maintained.

Existing desktop installations are retained; use the app's internal updater for subsequent releases. Dotfiles does not continuously reinstall the app if manually uninstalled.

## Command-Line Launchers

Applying personal settings installs desktop-dependent launchers into `~/.local/bin`:
- `t3` (and `t3.ps1` on Windows) wraps the desktop application's bundled CLI without requiring manual symlinks or GUI startup.
- `t3 app` opens the current working directory inside the running T3 Code desktop editor.

### Verification

After PATH integration and terminal restart:

```sh
t3 --version
```

If another `t3` command precedes `~/.local/bin` on PATH, resolve the conflicting path in your environment.

## Personal Preferences

`home/.chezmoidata/t3-code.json` declares preferences under `t3CodePreferences.server` and `t3CodePreferences.client`.
Private modify templates reconcile these maps into `~/.t3/userdata/settings.json` and `client-settings.json` on explicit apply.

| Settings page | Owned preferences |
| --- | --- |
| General | Thread notifications, in-app notifications, Working section |
| SnapShots | Enabled only |
| Threads | New-project base directory; default model and options; fallback model; permissions; workspace; resume and snooze after usage limits; all Auto-settle controls; text generation model |
| Source Control | Automatic pull; writing style and its custom instructions |
| Worktrees | Branch-renaming mode; cleanup on thread deletion; inactive cleanup period; unchanged-worktree cleanup |

The initial capture uses explicitly stored current values first and the installed T3 Code 0.1.7 defaults only for absent settings.
The resolved defaults are recorded in the data file: full-access permissions, a three-day Auto-settle period, settling merged threads, and empty custom writing instructions.
`capturedVersion` records the source version and is not applied as a preference.
Applying on another device does not import that device's preferences or recalculate these values from a newer T3 release.

Edit the declared server or client map to change a managed preference, then close T3 Code and run `mise run apply` from the checkout.
Repeated application restores declared values after GUI edits.
A value of `false`, zero, an empty string, or a supported `null` is explicit, not an instruction to use a default.
For example, `sidebarAutoSettleAfterDays = null` disables inactive-thread settling.

Model selections are replaced as complete values, including their options; omitted options remove stale options from the destination.
Cleanup and writing-style objects merge only their declared children.
Other settings and nested children remain local, including project overrides, idle compaction, branch prefixes and instructions, `followChangeRequestTemplates`, other SnapShots options, and appearance preferences.
Existing provider ownership remains as described below; credentials, keybindings, and desktop window state are not captured here.
Malformed JSON or incompatible managed parent objects cause application to fail without replacing the affected file.

## Provider Configuration

Dotfiles reconciles T3 Code's settings file (`~/.t3/userdata/settings.json`) on every explicit apply.

### Managed Settings

The modify template (`modify_private_settings.json`):
- Creates or updates keyed `omp` and `antigravity` entries using the local ACP registry driver.
- Runs omp through the fully expanded absolute destination `.local/bin/omp` path (`omp.exe` on Windows) with the `acp` argument.
- Runs Antigravity through its absolute native adapter payload in `~/.local/share/dotfiles/antigravity-acp/bin`, with no arguments. The terminal's `.ps1` launcher requires PowerShell; T3 invokes the native adapter directly.
- Owns three Antigravity provider `environment` entries: absolute managed `AGY_BIN`, `AGY_SKIP_DOWNLOAD=1`, and `AGY_CLI_DISABLE_AUTO_UPDATE=true`. Duplicate or drifted owned entries are replaced; other variables, including secret references, are retained.
- Reconciles both provider and config `enabled` flags to `true`, while preserving other providers, appearance choices, and unowned configuration.
- Derives initial omp display name and color without overwriting user changes.

The same template manages a single `codex` provider entry:
- Uses T3's native `codex` driver with `setupMode = "existing"`, not its separate managed-installation mode.
- Enables the provider and sets `binaryPath` to the fully expanded absolute destination-home `.local/bin/codex` path (`codex.exe` on Windows).
- Lets T3 append the `app-server` subcommand; it does not reuse omp's ACP arguments.
- Preserves unowned Codex options, additional provider instances, and presentation settings.

Run `codex login` manually before authenticated use, then start a fresh T3 Code session. T3 uses Codex's own login; dotfiles does not copy credentials. Native-driver compatibility is verified against T3 Code 0.1.7. Existing desktop installations are retained, so update an older incompatible T3 version through its normal updater.

The template also manages a single `claudeAgent` provider entry:

- Uses T3's native `claudeAgent` driver and enables both the provider and its configuration.
- Sets `binaryPath` to the fully expanded destination `.local/bin/claude` path (`claude.exe` on Windows).
- Uses Claude's native default user context. It does not add `homePath`: forcing that field to `.claude` would set `CLAUDE_CONFIG_DIR` and move the normally separate `~/.claude.json`, bypassing terminal login/MCP/trust metadata. Reapply clears only the previous repository-added absolute default; a different custom scope stays user-owned and unmanaged.
- Preserves unowned options, model choices, presentation, and unrelated providers. A custom path on this managed instance is restored to the managed destination on reapply.

Claude uses its native SDK protocol; no ACP argument is added. Run `claude auth login` manually before authenticated use. Native compatibility is verified against T3 Code 0.1.7; a retained older desktop may need its normal update first.

> **Operational Warning:** **Close T3 Code before running `chezmoi apply` or `mise run apply`.** T3 Code writes to its settings files while running and does not share a cooperative file lock with chezmoi.

### Security and State Boundaries

- Manages the default `~/.t3` directory (custom `T3CODE_HOME` relocations are unmanaged).
- Model credentials, API keys, and sessions remain in each harness's own configuration or environment; dotfiles does not copy them into T3 settings.
- Automatic background services and remote listener ports are not opened.
- The pinned [Antigravity ACP adapter](https://github.com/shubzkothekar/antigravity-acp) passes `--dangerously-skip-permissions` to CLI model requests. Treat model turns as permission-bypassing execution; this integration does not change the CLI's stored security settings.
- The adapter documents personal OAuth restrictions. Use its supported Gemini API-key or enterprise ADC route for model use; dotfiles does not provision credentials or start a model request.

### Antigravity credentials

For the [Gemini API-key route](https://antigravity.google/docs/install?tab=cli#using-a-gemini-api-key), both steps are required:

1. Merge `"modelProvider": "gemini"` into your user-owned `~/.gemini/antigravity-cli/settings.json`.
2. Provision `GEMINI_API_KEY` securely in the environment inherited by T3 and its adapter.

The key alone does not select this provider. Fully quit T3 and launch the desktop from that environment; exporting a key in a different shell does not change a running desktop process. Never put real keys in tracked files.

For [enterprise ADC](https://antigravity.google/docs/install?tab=cli#application-default-credentials-adc-1), configure credentials through the native Google Cloud procedure and launch T3 with `AGY_ADC_AUTH=true`. Switch away from Gemini API-key mode when choosing ADC. Dotfiles does not create credentials or change your CLI model/auth settings.

## Testing and Smoke Verification

With T3 Code already installed, run isolated checks without applying to your personal home:

```sh
mise exec -- python tests/smoke_t3_code.py
mise exec -- python tests/smoke_antigravity.py
```

The `smoke_t3_code.py` check applies the template to a temporary home, resolves the bundled launcher, and checks omp's ACP handshake. It starts fresh local T3 servers with the managed binary directory absent from `PATH`. The native Codex driver must complete app-server initialization, and the native Claude driver must complete SDK initialization and discover the pinned CE slash command. Both accounts remain unauthenticated; the smoke uses no personal credentials and does not claim model completion. Windows x64 has passed locally against T3 Code 0.1.7; other eligible targets rely on their native CI results.

The Antigravity smoke verifies native instruction content through a localhost-only request capture that deliberately rejects model execution. It runs native plugin preservation/malformed-state checks against the locked CLI, repairs adjacent-CLI and provider drift, and initializes a fresh T3 provider with managed `.local/bin` absent from PATH. No real credentials, personal OAuth/keyring access, or model completion are used. Authenticated CE skill invocation is deferred to [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52).

T3 can report an initial ready state while its ACP probe is still running. The Antigravity smoke waits for native session capabilities before accepting initialization; terminal errors and a bounded deadline still fail the check.
