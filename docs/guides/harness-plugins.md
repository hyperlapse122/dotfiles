# Harness Plugins and AI Agent Configuration

This guide explains how dotfiles installs and manages the [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) plugin for Claude Code, Codex, oh-my-pi (omp), and Antigravity, controls update ownership, performs repairs and rollbacks, and wires shared user-scope agent instructions.

## Compound Engineering Plugin for omp

Dotfiles installs Compound Engineering at user scope for the standard omp environment across Windows, Linux, and macOS.

The archive is prepared before native plugin reconciliation through the shared [asset cache](../maintenance/chezmoi-source.md#external-asset-preparation).
Unchanged archive and extracted-file metadata reuse the completed preparation; native plugin registration and repair still run according to each harness's existing lifecycle.
Use `mise run assets:verify` for full asset integrity verification and repair, or `mise run assets:refresh` to force fresh downloads as well.
These tasks explicitly apply this worktree's personal configuration; close the affected harnesses first.

### Architecture

1. **Declarations (`home/.chezmoidata/harness-plugins.json`):** Tracks upstream repository, tag prefixes, and marketplace metadata. Alternate-host symlinks are excluded to ensure smooth installation on Windows without elevated privileges.
2. **Lockfile (`home/.chezmoidata/harness-plugin-lock.json`):** Tracks verified release tags and exact commit SHAs.
3. **Local Marketplace:** Chezmoi extracts the archive into `~/.local/share/dotfiles/harness-plugins/compound-engineering`, registers it as a local marketplace, and runs `omp plugin install --scope user --force` and `omp plugin enable`.

> **Operational Rule:** **Always apply with omp closed.** Starting a new omp session after apply loads the updated skills.

## Compound Engineering Plugin for Codex

Explicit apply installs Codex's native CE plugin from the same repository-pinned archive used by omp. The native marketplace manifest is `.agents/plugins/marketplace.json`; Codex loads skills through `.codex-plugin/plugin.json`.

On each apply, the Codex hook runs the managed executable with `CODEX_HOME` set to the destination home's `.codex` directory:

```sh
codex plugin marketplace add /absolute/path/to/.local/share/dotfiles/harness-plugins/compound-engineering
codex plugin add compound-engineering@compound-engineering-plugin
```

`plugin add` installs and enables the plugin; Codex has no separate `plugin enable` command in the pinned version. Reapplication repairs the native CE cache and activation even when the pin is unchanged. The local marketplace follows the shared CE lock, not an independent latest release.

The private `~/.codex/config.toml` modify template owns only the CE marketplace source, CE activation, and `check_for_update_on_startup = false`. Other settings, model choices, plugins, and credentials are preserved. Close Codex and T3 Code before applying, then start a fresh session.

### Sign-in and Invocation

Apply does not sign in. Run `codex login` yourself, or provision credentials through a Codex-supported mechanism. Do not add an API key or `auth.json` to tracked plaintext configuration.

After signing in, start Codex and select a CE skill through `/skills`, such as `compound-engineering:ce-plan`. Authentication, model access, and billing remain with Codex; dotfiles does not copy credentials into T3 Code.

The managed scope is the default `~/.codex`. Custom `CODEX_HOME` locations remain unmanaged.

## Compound Engineering Plugin for Claude Code

Explicit apply registers, installs, and enables CE at Claude user scope from the shared local directory. Claude uses the same CE release and commit pin as Codex and omp; the initial pin is `compound-engineering-v3.35.1` at `42f9745ea0a4b70f8dde059aa8cf7f974d2991f1`.

The after hook runs the absolute managed Claude executable with `HOME` bound to the destination home; Windows also sets `USERPROFILE`. It clears `CLAUDE_CONFIG_DIR` so native global state remains in `~/.claude.json`, alongside the default `.claude` directory. Setting that variable even to the default directory would relocate the global file. It performs the native lifecycle:

```sh
claude plugin marketplace add /absolute/path/to/.local/share/dotfiles/harness-plugins/compound-engineering --scope user --json
claude plugin install compound-engineering@compound-engineering-plugin --scope user --json
claude plugin enable compound-engineering@compound-engineering-plugin --scope user --json
```

The pinned CLI returns exit code 1 when the plugin is already enabled. The hook accepts only its structured `already_in_goal_state` result with `alreadyInGoalState=true` as that no-op; genuine errors fail apply. Native marketplace registration repairs a stale source path, and the relative local plugin source loads in place. Reapplication follows the shared archive pin without deleting caches or editing native registry files directly.

The private settings merge owns the CE directory marketplace entry and activation flag, alongside the [Claude preferences](personal-applications.md#claude-code-version-and-preferences). Only CE's marketplace has `autoUpdate=false`; unrelated marketplace policies and plugins are preserved. Malformed settings or incompatible owned containers fail instead of replacing the file.

Close Claude Code and T3 Code before apply, then start a fresh session. Complete `claude auth login` manually and invoke a skill such as `/compound-engineering:ce-plan`. Authentication and billing remain with Claude; dotfiles stores no plaintext secrets.

## Compound Engineering Plugin for Antigravity

On eligible Windows, glibc Linux, and Apple Silicon targets, explicit apply uses the pinned `agy` CLI to validate, install, enable, and list the local CE package through native plugin commands.
It uses the same `harness-plugin-lock.json` tag and commit as omp, not a separate release.
The package's root `plugin.json` and `skills/` provide the native integration; no copied omp registry or compatibility alias is needed.

Registration lives in Antigravity's native `~/.gemini/config` state. Apply does not rewrite the registry or unrelated CLI settings and plugins. An apply-always hook restores a missing or disabled managed plugin; malformed native state fails rather than being replaced.
Bootstrap does not install or enable plugins. Close Antigravity and T3 sessions before explicitly applying.

Native installation, enablement, package validation, and skill discovery are verified without credentials.
Authenticated CE skill invocation remains deferred to [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52); discovery is not evidence of model-backed invocation.

## Disabling Marketplace Auto-Updates

The repository configures omp's mutable configuration (`~/.omp/agent/config.yml` or `config.yaml`):

```yaml
marketplace:
  autoUpdate: "off"
```

> **Important:** This disables background automatic updates for **all** omp marketplace plugins, not only Compound Engineering. This guarantees that your tool versions remain predictable and locked to repository commits.

The template preserves all other settings, custom profiles, and model credentials. If legacy `settings.json` or `agent.db` files exist, apply stops to let omp perform native first-run migration before writing YAML.

## Repair and Rollback

### Manual Cache Repair

If plugin cache files become corrupted or skills are accidentally disabled, run these commands with omp closed:

```sh
omp plugin marketplace update compound-engineering-plugin
omp plugin install --scope user --force compound-engineering@compound-engineering-plugin
omp plugin enable --scope user compound-engineering@compound-engineering-plugin
```

### Version Rollback

To roll back Compound Engineering to an earlier version:
1. Revert `home/.chezmoidata/harness-plugin-lock.json` to the target commit in Git.
2. Run `chezmoi apply` or `mise run apply`.
3. Dotfiles reconciles the shared directory and refreshes each harness through its native integration. Claude loads its local plugin in place; omp force-reinstalls its pinned plugin.

## Refreshing Plugin Pins

To query GitHub for the latest stable release and update the lockfile:

```sh
mise exec -- python scripts/update-harness-plugin-lock.py
```

### Automated Updates

A GitHub Actions workflow (**Update harness plugin pins**) runs daily at 06:43 UTC, validating release tags and commit SHAs against the native test matrix before committing to `main`.

## Shared User-Scope Agent Instructions

Every managed AI harness in this repository wires its native instruction file to a shared template:
- **Shared Source:** `home/.chezmoitemplates/agent-instructions`
- **Native omp Target:** `~/.omp/agent/AGENTS.md` (generated via `home/private_dot_omp/private_agent/private_empty_AGENTS.md.tmpl`)
- **Native Claude Target:** `~/.claude/CLAUDE.md` (generated via `home/private_dot_claude/private_empty_CLAUDE.md.tmpl` with `harness = claude`)
- **Native Codex Target:** `~/.codex/AGENTS.md` (generated via `home/private_dot_codex/private_empty_AGENTS.md.tmpl`)
- **Native Antigravity Target:** `~/.gemini/GEMINI.md` (generated via `home/private_dot_gemini/private_empty_GEMINI.md.tmpl` with `harness: antigravity`)

Applying dotfiles replaces those native instruction files with their harness-specific render of the shared repository template. The source is initially empty of policies, preserving owner-only empty files until rules are authored.

> **Scope Note:** In omp, `~/.omp/agent/AGENTS.md` applies to the main interactive session and advisors. Task subagents do not inherit files named `AGENTS.md`.

Codex uses a nonempty `~/.codex/AGENTS.override.md` before `AGENTS.md`. Apply preserves that override; remove or update it manually if it should no longer suppress the managed instructions. Project instructions and native configuration precedence still apply.

Disabling Claude automatic memory does not disable its managed `CLAUDE.md` instructions.

For the technical procedure to onboard a new AI harness, see [Chezmoi Source Maintenance](../maintenance/chezmoi-source.md#shared-user-scope-harness-onboarding).

## Verification

To run isolated plugin integration tests:

```sh
mise exec -- python tests/smoke_harness_plugins.py
mise exec -- python tests/smoke_antigravity.py
```

The omp smoke verifies local marketplace cutover, update policy, skill discovery, and preservation of unrelated plugins. The Antigravity smoke additionally proves native global-instruction ingestion through a localhost capture-only endpoint, runs the native preservation/malformed-state checks with its locked CLI, and starts a fresh T3 ACP session. These checks use disposable homes without real credentials or model completion; Antigravity's authenticated CE invocation remains outside this change.

For Codex's isolated native integration:

```sh
mise exec -- python tests/smoke_codex.py
```

This checks native instruction discovery, the pinned marketplace/cache, reapplication, unrelated state preservation, and explicit CE skill expansion into Codex's outgoing model request. A localhost capture endpoint deliberately rejects that request; the smoke uses no real credentials and does not claim authenticated model completion.

For Claude's isolated native integration:

```sh
mise exec -- python tests/smoke_claude.py
```

This verifies native CE discovery, stale-source and enabled-state repair, preservation, common and Claude-specific instructions, the Korean response preference, and explicit expansion of the pinned skill body. It characterizes an automatic-memory fixture while enabled, then confirms the managed disabled state excludes it without deleting the file. The localhost endpoint deliberately rejects model requests with HTTP 400 using inert credentials. This proves request expansion, not authenticated model completion. Windows x64 has been exercised locally; other eligible targets are checked by the native CI lane, and a missing required result remains unverified.
