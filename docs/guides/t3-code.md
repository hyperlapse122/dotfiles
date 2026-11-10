# T3 Code Desktop and Harness Integration

This guide describes how dotfiles installs the [T3 Code](https://github.com/pingdotgg/t3code) desktop application, provisions bundled command-line launchers, and configures native Claude Code, Codex, pi, and Grok providers, while preserving native Antigravity settings.

## Platform Support and Installation

T3 Code is supported on:

- **Windows (x64 and ARM64):** Installed via WinGet (`T3Tools.T3Code`, declared in `home/.chezmoidata/windows.yaml`).
- **macOS (Apple Silicon):** Installed via Homebrew cask (`t3-code`) if no existing app is detected.
- **Ubuntu Studio 26.04 LTS (amd64, from 26.04.1+ media):** Staged via a checksum-verified `.deb` external and installed via APT after the shared Studio host check.

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
The managed Claude provider (`claudeAgent`) uses `Compact idle threads = Before the cache expires (beta)` (`config.idleCompaction = "beforeCacheExpires"`).
Explicit application restores this choice after local edits while preserving other Claude settings and additional provider instances.
Other settings and nested children remain local, including project overrides, global idle-compaction defaults, branch prefixes and instructions, `followChangeRequestTemplates`, other SnapShots options, and appearance preferences beyond the three managed font families.
The client map owns `fontFamilySans = "Pretendard Variable"`, `fontFamilyCode = "Jetendard"`, and `fontFamilyTerminal = "Jetendard"`.
Both coding preferences are set so the terminal uses Jetendard in either unified or separate-font mode; the local mode flag is preserved.
Sizes, line spacing, themes, and `fontFamilyComposer` remain local; the prompt input uses T3's native inheritance unless a separate composer preference overrides it.
The existing [user-font collection](fonts.md) supplies both families through explicit application.
Existing provider ownership remains as described below; credentials, keybindings, and desktop window state are not captured here.
Malformed JSON or incompatible managed parent objects cause application to fail without replacing the affected file.

## Provider Configuration

### Instructions shared with the terminal

The native user instruction files select their harness branch from `home/.chezmoitemplates/agent-instructions`. T3 uses those same files and account homes, so the common baseline, including its [writing-skills rule](harness-plugins.md#shared-user-scope-agent-instructions), reaches T3 launches. The template's `context = t3` branch holds T3-only additions. Select a harness inside that branch when an addition should apply to one provider. The thin adapters render private files under `~/.t3/userdata/instructions/`, containing only the T3 addition. Close T3 and run `mise run apply` to reconcile launch settings after editing.

The addition tells Codex, Claude, and pi to use T3's `delegate_task` and related task tools for delegated work, including same-provider children and agents dispatched by CE skills. It explicitly replaces CE's acpx, provider CLI, and launcher-script routes for cross-model review, implementation, and reasoning elevation. Calling a peer a shell-out rather than a subagent does not exempt it. Each delegated child is a separate T3 thread; creating a top-level thread is not a delegation substitute.

CE still decides whether to delegate, which provider/model/effort to select, and how to validate results or recover from failure. Use T3 capability discovery to resolve that target and map its supported settings to `target.options`, without silently inheriting a different model or effort. A retry or replacement delegation also uses T3; CE's permitted inline fallback and skip behavior remain available. The addition introduces no separate failure policy or approval step. Children receive self-contained briefs with the needed context, workspace and artifact paths, restrictions, output contract, and routing policy; further delegation requires authorization in the assigned task.

T3 task tools replace CE's process runners, polling, cancellation, and transport receipts. The parent must retain substantive scope, integration, and verification checks rather than inventing legacy controller receipts or treating a completed T3 task as a valid CE result. If those checks cannot be satisfied, CE's existing unavailable-route handling applies before incompatible transport machinery starts. A wait timeout leaves the child's state unresolved; follow T3's lifecycle and CE's recovery prerequisites before replacing work.

Higher-priority host instructions remain binding, so this prompt addition cannot guarantee overriding a conflicting host rule. Direct CLI launches receive none of the addition. Request capture verifies delivery; it does not prove that a model follows the policy, nor that every CE transport contract can be satisfied by T3.

T3's task API does not provide CE's transport-enforced read-only review mode. A read-only brief and an unchanged checkout after execution do not supply that guarantee. When the invoked CE workflow requires enforced read-only access, the existing unavailable-route handling applies; this addition does not authorize weakening that requirement. Worktree isolation is not a substitute for reviewing uncommitted changes, because a T3 worktree child starts from the parent commit.

`scripts/t3-instructions.py` composes additions with existing native options:

- Codex receives inline `-c developer_instructions=...`, preserving the effective config or launch override. A nonempty `T3CODE_CODEX_LAUNCH_ARGS` is folded into those launch arguments, and an empty provider-scoped environment override prevents the inherited variable from hiding the addition. Native `AGENTS.md`, repository instructions, and T3's own per-turn application context remain separate. Custom Codex account homes remain selected. Developer instructions are snapshotted during apply; close T3 and reapply after editing their native configuration. Codex 0.166.0 rejects `--profile` for `app-server`, including T3 launches; separate CLI profiles are unsupported on this path.
- Claude receives an absolute `--append-system-prompt-file` pointing to its private addition. Existing effective append-file and inline append content is preserved together in an additional inline option because native duplicate flags use the last value. An existing absolute append file is read at apply time; reapply after changing it. Relative existing append files depend on each turn's working directory and cannot be composed at apply time. Application reports this unsupported case before changing launch settings; make that existing path absolute or leave the T3 addition empty. Native `CLAUDE.md` and repository discovery continue normally.
- pi receives an additional `--append-system-prompt` file option. Its native repeated options accumulate, preserving existing file or inline additions and the managed provider policy extension.

The private `~/.t3/userdata/dotfiles-launch-state.json` records original instruction launch options and managed control contributions for idempotent reapplication. Clearing an addition restores its instruction options while keeping native subagent controls active. Subsequent edits to unrelated arguments and environment entries survive. It contains existing instruction text and environment metadata, so retain its owner-only permissions. The composer leaves native harness instruction/config files, the machine-wide environment, account directories, and terminal launch settings unchanged.

The T3 Code 0.1.7 Grok driver does not support `launchArgs`; a T3-only native prompt addition is unsupported there. Its native user-scope baseline still loads. Do not replace this limitation with another account home or untrusted application context. The supported mechanisms were checked against Codex 0.166.0, Claude Code 2.1.318, and pi 1.5.0; native driver changes require repeating request/context verification.

### T3-only native subagent controls

Explicit apply suppresses native subagent spawning for the managed Codex, Claude Code, and Grok providers while retaining the existing prompt instructions and T3 task tools.
The controls belong to provider launches, not shared native configuration, so terminal CLI sessions keep their original tool availability.
Pi receives no new control, and Antigravity remains unchanged.

- Codex receives `--disable multi_agent`, `--disable multi_agent_v2`, and `--disable multi_agent_v2_dynamic_tools` after effective launch-argument selection. Native `--disable` wins even when existing arguments contain `--enable`; a later `-c features.multi_agent=false` alone does not override that enable flag in Codex 0.167.0.
- Claude receives one `--disallowedTools` value combining its existing deny rules with `Agent`. T3 collapses repeated instances of the same launch option, so the composer merges both native aliases and their values before passing them to the adapter. The bare tool denial covers the legacy Task alias without blocking the separately named T3 MCP tools.
- Grok receives provider-scoped `GROK_SUBAGENTS=0`. This uses its documented stdio environment mechanism, independent of the unsupported T3 prompt-addition path. Reapplication replaces conflicting values and Windows case variants while preserving unrelated environment entries.

Codex and Claude suppression remains active when their prompt addition is empty or missing.
Their private launch-state records track only the managed argument contributions so later unrelated edits survive reconciliation.
Close T3 before applying, then relaunch it; a saved setting does not change an already-running native process or cancel existing children.
These controls remove native spawning tools, not arbitrary shell execution.

On macOS ARM64, disposable T3 Code 0.1.7 requests with Codex 0.167.0 and Claude Code 2.1.319 omit native spawn tools and retain named T3 delegation/capability tools across fresh turns, mode changes, same-conversation resume, and completed compaction.
Concurrent and later direct CLI requests retain native spawning tools and the same instruction baseline.
Grok 1.0.77's actual T3 request omits `spawn_subagent` and retains MCP discovery/call tools; direct requests before and after T3 retain spawning.
The Grok transport deliberately rejects inference after capture, so this verifies tool availability rather than model completion.
Successful child-task execution under the new controls, pre-control conversation migration, Grok resume/compaction and concurrent CLI use, and native behavior on Windows/Linux remain unverified.

`tests/smoke_t3_instructions.py` captures real native provider requests against a controlled local model transport in disposable homes. The transport returns generic fixture text to drive lifecycle transitions; it does not establish authenticated Codex or Claude model completion. For Codex, Claude, and pi, the test checks delivery of the actual repository delegation policy, baseline and repository inclusion, branch exclusion, native CE invocation, existing options, multiline quoting, concurrent/later CLI isolation, fresh T3 turns, Plan and mode changes, native conversation resume, completed native compaction, and postcompaction context. The pi fixture lowers its documented recent-token retention so short fixture conversations actually compact. Run it on the platform being validated, with an installed T3 desktop or `--install-desktop` on a disposable GitHub-hosted runner.

For a bounded behavioral check, pass the rendered T3 addition as an explicit instruction to a disposable T3 child. Give it a small read-only CE peer-review brief and authorize the one delegation that brief needs. Repeat with Codex hosting Claude and Claude hosting Codex, using the selected CE model and effort through T3's supported options. Check the child task activity and returned review artifact, not just its final claim that it delegated. Test a same-provider scout with a named dossier path separately, and confirm that an inline-only task creates no child. Passing the candidate policy in a task tests routing under that instruction; it does not replace native launch-delivery verification.

Before the candidate is applied, probe children also receive the previously applied addition through their native launch instructions. Record that version and treat results as evidence under the combined instructions, not the candidate alone. For read-only probes, compare HEAD, tracked file contents, index contents, and untracked files before and after execution; an unchanged `git status` alone can miss edits to an already modified file. These checks detect changes but do not enforce read-only access.

For recovery coverage, use an unavailable target or a controlled scenario instead of deliberately exhausting quota. Confirm that CE's existing recovery decision produces no direct CLI/native-subagent escape. A scenario response is evidence of interpretation, not an observed provider failure. Record requested model/effort separately from serving identity, and report successful execution, permitted fallback, host constraints, and unavailable checks separately. Implementation and elevation probes also need their substantive result checks; a preflight fallback is not proof of successful transport equivalence.

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
