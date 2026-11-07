# Harness Plugins and AI Agent Configuration

This guide explains how dotfiles installs and manages the [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) plugin for Claude Code, Codex, pi, Grok, oh-my-pi (omp), and Antigravity, controls update ownership, performs repairs and rollbacks, and wires shared user-scope agent instructions.

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

## Compound Engineering Plugin for Pi

Explicit apply runs the pinned native `pi install` command against the shared local CE extraction. Pi reads that directory's native `package.json`, `.pi/extensions/compound-engineering.ts`, and `skills/`; no second skill tree is copied. Reapplication repairs disabled CE resource filters while preserving unrelated native packages, extensions, settings, and credentials. Pi rewrites local package sources relative to `~/.pi/agent`; reconciliation recognizes both those paths and absolute declarations.

The thin `~/.pi/agent/AGENTS.md` adapter selects `harness=pi` from the shared instruction template. Start a fresh session after apply and invoke `/skill:ce-plan` or another native CE skill. The native smoke checks skill discovery exactly once and captures explicit CE expansion together with common/Pi instructions. The loopback endpoint rejects execution, so this evidence does not claim authenticated model completion.

The mandatory `~/.pi/agent/dotfiles-policy.ts` extension replaces foreign provider models with empty catalogs and replaces Synthetic's catalog with the committed model lock. It repeats enforcement after preserved extensions' startup hooks and native reload. Foreign explicit selections and unavailable saved selections fail; new sessions use the first sorted locked ID when their previous default was removed. The `enabledModels` setting also narrows the picker, but the effective registry provides enforcement.

The managed shell launchers check policy and catalog presence before model discovery and add the native policy path explicitly. Exact `--version` and `--help` requests report public metadata without requiring private configuration. T3's native Pi driver uses normal RPC initialization, which rejects policy-load errors before requests. Running the distribution binary with `--no-extensions`, bypassing managed files, or loading hostile arbitrary code is outside this configuration contract.

## Compound Engineering Plugin for Grok

Explicit apply registers the shared pinned extraction as a native local marketplace and installs/enables its `.grok-plugin/plugin.json` package. Grok discovers the package's `skills/` directory directly. Reapplication repairs owned registration, enablement, and Windows local-copy caches while preserving unrelated native plugins. The thin `~/.grok/AGENTS.md` adapter selects `harness=grok`; compatibility scanning of Claude/Cursor instructions and skills is disabled to prevent foreign content and duplicate CE discovery. See [Grok Build](grok.md) for authentication and native-copy repair details.

## Compound Engineering Plugin for Antigravity

On eligible Windows, glibc Linux, and Apple Silicon targets, explicit apply uses the pinned `agy` CLI to validate, install, enable, and list the local CE package through native plugin commands.
It uses the same `harness-plugin-lock.json` tag and commit as omp, not a separate release.
The package's root `plugin.json` and `skills/` provide the native integration; no copied omp registry or compatibility alias is needed.

Registration lives in Antigravity's native `~/.gemini/config` state. Apply does not rewrite the registry or unrelated CLI settings and plugins. An apply-always hook restores a missing or disabled managed plugin; malformed native state fails rather than being replaced.
Bootstrap does not install or enable plugins. Close Antigravity and T3 sessions before explicitly applying.

Native installation, enablement, package validation, and skill discovery are verified without credentials.
Authenticated CE invocation is verified on the local PC as requested in [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52). Hosted CI remains credential-free; discovery alone is not evidence of model-backed invocation. See the local evidence below.

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

The omp smoke verifies local marketplace cutover, update policy, skill discovery, and preservation of unrelated plugins. The default Antigravity smoke proves native global-instruction ingestion through a localhost capture-only endpoint, runs the native preservation/malformed-state checks with its locked CLI, and verifies that apply leaves T3's native provider ID unclaimed. These default checks use disposable homes without real credentials or model completion; authenticated completion is a separate check.

For an optional local disposable-home Gemini API-key verification, provision `GEMINI_API_KEY` through the environment without printing its value, then run:

```sh
mise exec -- python tests/smoke_antigravity.py --authenticated
```

This opt-in path keeps the disposable home, selects the CLI's Gemini provider, and executes native `/ce-noslop` against the official Gemini endpoint. It requires a completed native `read_file` event for the selected pinned skill, with its full line/byte counts, before the final successful response. An echo without that read fails verification. Antigravity loads skill content through the agent's progressive file-read flow; its first model request contains the skill index, not an eagerly expanded body. It fails before preparation when the key is absent. It does not copy personal account state, use personal keyring credentials as a fixture, or automate sign-in. A custom/capture endpoint cannot supply authenticated evidence. The ordinary CI smoke remains credential-free. See [official authentication requirements](https://antigravity.google/docs/install#using-a-gemini-api-key).

On 2026-11-07, the owner-authorized native macOS ARM64 `agy 1.5.2` completed both a plain authenticated probe (`AGY_AUTHENTICATED_OK`) and `/ce-noslop` with CE 3.35.1. The latter streaming trace records a completed native read of the selected skill (45 lines, 4048 bytes), followed by `SUCCESS` and `The dotfiles verification returned AGY_CE_NATIVE_OK.`. These live probes used the already configured native account and `/tmp` as the working directory; they did not use a disposable account home. They supplement the isolated instruction/plugin smoke and do not establish authenticated disposable-home execution on Windows or Linux. The owner selected local-PC-only authenticated verification for [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52); authenticated Windows/Linux or disposable-home execution is outside that scope. A fresh local run on 2026-11-07 again passed the existing full-skill-read and exact-response verifier using native authentication in a disposable working directory. Do not add paid model calls or inference credentials to Actions for this verification. T3's separately installed native runtime is outside this CLI proof.

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

For Grok's isolated native integration, run `python tests/smoke_grok.py` with the repository tools on PATH. This verifies the native local marketplace, pinned installation and enablement, shared instructions, foreign-content exclusion, unrelated-plugin preservation, and explicit expansion of the complete CE skill body. Add `--t3` for the fresh native ACP driver check. See [Grok Build](grok.md) for native-copy repair and authentication boundaries.
