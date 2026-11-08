# T3 Code Desktop and Harness Integration

This guide describes how dotfiles installs the [T3 Code](https://github.com/pingdotgg/t3code) desktop application, provisions bundled command-line launchers, and configures native Claude Code, Codex, pi, and Grok providers, while preserving native Antigravity settings.

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
| Appearance | Main interface and ordinary conversation font: Pretendard Variable; code blocks, diffs, file previews, and terminal font: Jetendard |
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
Pi’s `default` model is disabled in the T3 model picker through `providerModelPreferences.pi.hiddenModels`.
Apply adds the declared hidden models while preserving existing hidden choices, model ordering, and other providers’ preferences.
Other settings and nested children remain local, including project overrides, idle compaction, branch prefixes and instructions, `followChangeRequestTemplates`, other SnapShots options, and appearance preferences beyond the three managed font families.
The client map owns `fontFamilySans = "Pretendard Variable"`, `fontFamilyCode = "Jetendard"`, and `fontFamilyTerminal = "Jetendard"`.
Both coding preferences are set so the terminal uses Jetendard in either unified or separate-font mode; the local mode flag is preserved.
Sizes, line spacing, themes, and `fontFamilyComposer` remain local; the prompt input uses T3's native inheritance unless a separate composer preference overrides it.
The existing [user-font collection](fonts.md) supplies both families through explicit application.
Existing provider ownership remains as described below; credentials, keybindings, and desktop window state are not captured here.
Malformed JSON or incompatible managed parent objects cause application to fail without replacing the affected file.

## Provider Configuration

### Instructions shared with the terminal

The native user instruction files select their harness branch from `home/.chezmoitemplates/agent-instructions`. T3 uses those same files and account homes, so the common baseline, including its [writing-skills rule](harness-plugins.md#shared-user-scope-agent-instructions), reaches T3 launches. The template's `context = t3` branch holds T3-only additions. Select a harness inside that branch when an addition should apply to one provider. The thin adapters render private files under `~/.t3/userdata/instructions/`, containing only the T3 addition. Close T3 and run `mise run apply` to reconcile launch settings after editing.

The addition tells Codex, Claude, and pi to prefer T3's `delegate_task` and related task tools over native subagent tools, including for same-provider children and agents dispatched internally by skills such as CE research and review. Each delegated child is a separate T3 thread; creating a top-level thread is not a delegation substitute. T3's capability discovery and task lifecycle rules still apply.

Where both routes are permitted, the preference replaces T3's default guidance to use native tools for same-provider children. Higher-priority host instructions and explicit tool requirements remain binding, so this prompt addition cannot guarantee overriding the opposite rule when it has higher priority. If T3 delegation is unavailable or unsupported, the agent may use a native subagent only when the governing instructions permit it and must report the limitation. Direct CLI launches receive none of this addition. Request capture verifies that the preference reaches the model; it does not prove that a model follows it.

`scripts/t3-instructions.py` composes additions with existing native options:

- Codex receives inline `-c developer_instructions=...`, preserving the effective config or launch override. A nonempty `T3CODE_CODEX_LAUNCH_ARGS` is folded into those launch arguments, and an empty provider-scoped environment override prevents the inherited variable from hiding the addition. Native `AGENTS.md`, repository instructions, and T3's own per-turn application context remain separate. Custom Codex account homes remain selected. Developer instructions are snapshotted during apply; close T3 and reapply after editing their native configuration. Codex 0.166.0 rejects `--profile` for `app-server`, including T3 launches; separate CLI profiles are unsupported on this path.
- Claude receives an absolute `--append-system-prompt-file` pointing to its private addition. Existing effective append-file and inline append content is preserved together in an additional inline option because native duplicate flags use the last value. An existing absolute append file is read at apply time; reapply after changing it. Relative existing append files depend on each turn's working directory and cannot be composed at apply time. Application reports this unsupported case before changing launch settings; make that existing path absolute or leave the T3 addition empty. Native `CLAUDE.md` and repository discovery continue normally.
- pi receives an additional `--append-system-prompt` file option. Its native repeated options accumulate, preserving existing file or inline additions and the managed provider policy extension.

The private `~/.t3/userdata/dotfiles-launch-state.json` records original launch options for idempotent reapplication and restoration when an addition becomes empty. Subsequent edits to unrelated arguments and environment entries survive. It contains existing instruction text and environment metadata, so retain its owner-only permissions. The composer leaves native harness instruction/config files, the machine-wide environment, account directories, and terminal launch settings unchanged.

The T3 Code 0.1.7 Grok driver does not support `launchArgs`; a T3-only native prompt addition is unsupported there. Its native user-scope baseline still loads. Do not replace this limitation with another account home or untrusted application context. The supported mechanisms were checked against Codex 0.166.0, Claude Code 2.1.318, and pi 1.5.0; native driver changes require repeating request/context verification.

`tests/smoke_t3_instructions.py` captures real native provider requests against a controlled local model transport in disposable homes. The transport returns generic fixture text to drive lifecycle transitions; it does not establish authenticated Codex or Claude model completion. For Codex, Claude, and pi, the test checks delivery of the actual repository delegation preference, baseline and repository inclusion, branch exclusion, native CE invocation, existing options, multiline quoting, concurrent/later CLI isolation, fresh T3 turns, Plan and mode changes, native conversation resume, completed native compaction, and postcompaction context. The pi fixture lowers its documented recent-token retention so short fixture conversations actually compact. Run it on the platform being validated, with an installed T3 desktop or `--install-desktop` on a disposable GitHub-hosted runner.

Dotfiles reconciles T3 Code's settings file (`~/.t3/userdata/settings.json`) on every explicit apply.

### Managed Settings

The modify template (`modify_private_settings.json`):
- Removes the retired `omp` entry from `providerInstances`, including an existing entry in the destination file. Repeated apply keeps it absent.
- Leaves the existing omp executable and `~/.omp` configuration, credentials, plugins, and session data on disk; they are no longer managed or pinned. Other provider IDs are preserved.
- Leaves T3's native `antigravity` provider unchanged, including enablement, authentication, custom executable paths, model choices, and environment variables.
- Removes the former repository-managed CLI adapter entry only when its driver is `acpRegistry` and its command matches the old absolute managed adapter path. A custom ACP provider occupying `antigravity` fails apply without changing the file; move it to another ID first.
- Removes the retired third-party adapter payload and launchers on explicit apply. Unrelated files in its directory remain intact.

The same template manages a single `codex` provider entry:
- Uses T3's native `codex` driver with `setupMode = "existing"`, not its separate managed-installation mode.
- Enables the provider and sets `binaryPath` to the fully expanded absolute destination-home `.local/bin/codex` path (`codex.exe` on Windows).
- Lets T3 append the `app-server` subcommand.
- Preserves unowned Codex options, additional provider instances, and presentation settings.

Run `codex login` manually before authenticated use, then start a fresh T3 Code session. T3 uses Codex's own login; dotfiles does not copy credentials. Native-driver compatibility is verified against T3 Code 0.1.7. Existing desktop installations are retained, so update an older incompatible T3 version through its normal updater.

The template also manages a single `claudeAgent` provider entry:

- Uses T3's native `claudeAgent` driver and enables both the provider and its configuration.
- Sets `binaryPath` to the fully expanded destination `.local/bin/claude` path (`claude.exe` on Windows).
- Uses Claude's native default user context. It does not add `homePath`: forcing that field to `.claude` would set `CLAUDE_CONFIG_DIR` and move the normally separate `~/.claude.json`, bypassing terminal login/MCP/trust metadata. Reapply clears only the previous repository-added absolute default; a different custom scope stays user-owned and unmanaged.
- Preserves unowned options, model choices, presentation, and unrelated providers. A custom path on this managed instance is restored to the managed destination on reapply.

Claude uses its native SDK protocol; no ACP argument is added. Run `claude auth login` manually before authenticated use. Native compatibility is verified against T3 Code 0.1.7; a retained older desktop may need its normal update first.

T3's Claude and Codex launches read the same user settings as the terminal, so the [account source isolation](harness-plugins.md#account-source-isolation) applies to them as well. claude.ai connectors, including T3 Connect, no longer load in T3's Claude sessions. The `t3-code` MCP server that T3 registers for each launch is not an account source and stays available to both Claude and Codex.

> **Operational Warning:** **Close T3 Code before running `chezmoi apply` or `mise run apply`.** T3 Code writes to its settings files while running and does not share a cooperative file lock with chezmoi.

### Security and State Boundaries

- Manages the default `~/.t3` directory (custom `T3CODE_HOME` relocations are unmanaged).
- Model credentials, API keys, and sessions remain in each harness's own configuration or environment; dotfiles does not copy them into T3 settings.
- Automatic background services and remote listener ports are not opened.
### Native Antigravity setup

In T3 Settings > Providers, enable the native Antigravity provider, install its official runtime, and choose its native sign-in method. T3 manages this runtime separately from the `agy` CLI. A custom native executable requires the compatible `localharness_external` sibling; the former third-party CLI adapter cannot substitute for it.

Dotfiles does not select an Antigravity account, provision credentials, or overwrite native provider settings. Existing native providers with other instance IDs are preserved. It does not automatically merge or delete similarly named user-created providers.

The `agy` CLI remains repository-managed for terminal use and native CE plugin installation. Its settings and authentication are separate from the T3 native runtime. Installing the CLI does not install T3's official ACP runtime.

## Testing and Smoke Verification

With T3 Code already installed, run isolated checks without applying to your personal home:

```sh
mise exec -- python tests/smoke_t3_code.py
mise exec -- python tests/smoke_antigravity.py
```

The `smoke_t3_code.py` check applies the template to a temporary home, resolves the bundled launcher, and verifies removal of a retired omp provider. It starts fresh local T3 servers with the managed binary directory absent from `PATH`. The native Codex driver must complete app-server initialization, and the native Claude driver must complete SDK initialization and discover the pinned CE slash command. Both accounts remain unauthenticated; the smoke uses no personal credentials and does not claim model completion. Windows x64 has passed locally against T3 Code 0.1.7; other eligible targets rely on their native CI results.

The Antigravity smoke verifies the locked CLI and native instruction content through a localhost-only request capture that rejects model execution. It checks native CE discovery, plugin preservation and repair, and repeated apply without claiming T3's native provider ID. It does not prove T3 native runtime authentication or model completion. Authenticated CLI CE invocation remains tracked in [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52).
