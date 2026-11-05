# T3 Code Desktop and Harness Integration

This guide describes how dotfiles installs the [T3 Code](https://github.com/pingdotgg/t3code) desktop application, provisions bundled command-line launchers, and configures Codex and oh-my-pi (omp) as providers.

## Platform Support and Installation

T3 Code is supported on:
- **Windows (x64 and ARM64):** Installed via WinGet (`T3Tools.T3Code`, declared in `home/.chezmoidata/windows.yaml`).
- **macOS (Apple Silicon):** Installed via Homebrew cask (`t3-code`) if no existing app is detected.
- **Ubuntu (x64 and ARM64):** Staged via a checksum-verified `.deb` external and installed via `apt`.

> **Note:** Intel Mac support is not maintained.

Existing desktop installations are retained; use the app's internal updater for subsequent releases. Dotfiles does not continuously reinstall the app if manually uninstalled.

## Command-Line Launchers

Applying personal settings installs desktop-dependent launchers into `~/.local/bin`:
- `t3` (and `t3.cmd` on Windows) wraps the desktop application's bundled CLI without requiring manual symlinks or GUI startup.
- `t3 app` opens the current working directory inside the running T3 Code desktop editor.

### Verification

After PATH integration and terminal restart:

```sh
t3 --version
```

If another `t3` command precedes `~/.local/bin` on PATH, resolve the conflicting path in your environment.

## Provider Configuration

Dotfiles reconciles T3 Code's settings file (`~/.t3/userdata/settings.json`) on every explicit apply.

### Managed Settings

The modify template (`modify_private_settings.json`):
- Creates or updates the provider entry for `omp`.
- Configures command invocation with the fully expanded absolute path to the destination home's `.local/bin/omp` (`omp.exe` on Windows), with the `acp` argument.
- Reconciles both `enabled` and `config.enabled` flags to `true`.
- Preserves all other custom providers, appearance options, and unowned configuration.
- Derives initial display name and color from omp metadata without overwriting user changes.

The same template manages a single `codex` provider entry:
- Uses T3's native `codex` driver with `setupMode = "existing"`, not its separate managed-installation mode.
- Enables the provider and sets `binaryPath` to the fully expanded absolute destination-home `.local/bin/codex` path (`codex.exe` on Windows).
- Lets T3 append the `app-server` subcommand; it does not reuse omp's ACP arguments.
- Preserves unowned Codex options, additional provider instances, and presentation settings.

Run `codex login` manually before authenticated use, then start a fresh T3 Code session. T3 uses Codex's own login; dotfiles does not copy credentials. Native-driver compatibility is verified against T3 Code 0.1.7. Existing desktop installations are retained, so update an older incompatible T3 version through its normal updater.

> **Operational Warning:** **Close T3 Code before running `chezmoi apply` or `mise run apply`.** T3 Code writes to `settings.json` while running and does not share a cooperative file lock with chezmoi.

### Security and State Boundaries

- Manages the default `~/.t3` directory (custom `T3CODE_HOME` relocations are unmanaged).
- Model credentials, API keys, and sessions remain in the respective harness's configuration (`~/.codex/` or `~/.omp/`) and are never copied into T3 settings.
- Automatic background services and remote listener ports are not opened.

## Testing and Smoke Verification

To test T3 Code CLI discovery, omp ACP initialization, and T3-driven Codex startup in an isolated environment:

```sh
mise exec -- python tests/smoke_t3_code.py
```

This applies the template to a temporary home, resolves the bundled launcher, and checks omp's ACP handshake. It also starts a fresh local T3 server, removes the managed binary directory from `PATH`, and requires T3's native Codex driver to complete app-server initialization. The Codex account remains unauthenticated in this smoke; no model completion or personal credential use is claimed.
