# Harness Plugins and AI Agent Configuration

This guide explains how dotfiles installs and manages the [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) plugin for Claude Code, Codex, pi, Grok, and Antigravity, controls update ownership, performs repairs and rollbacks, and wires shared user-scope agent instructions.
It also covers the shared korean-skills writing skills that every managed harness discovers, and the settings that stop Claude Code and Codex from loading skills, plugins, and connectors from the signed-in account.

## Shared Compound Engineering Payload

Managed harnesses use one repository-pinned Compound Engineering archive through their native user-scope integrations.

The archive is prepared before native plugin reconciliation through the shared [asset cache](../maintenance/chezmoi-source.md#external-asset-preparation).
Unchanged archive and extracted-file metadata reuse the completed preparation; native plugin registration and repair still run according to each harness's existing lifecycle.
Use `mise run assets:verify` for full asset integrity verification and repair, or `mise run assets:refresh` to force fresh downloads as well.
These tasks explicitly apply this worktree's personal configuration; close the affected harnesses first.

### Architecture

1. **Declarations (`home/.chezmoidata/harness-plugins.json`):** Tracks upstream repository, tag prefixes, and marketplace metadata. Alternate-host symlinks are excluded to ensure smooth installation on Windows without elevated privileges.
2. **Lockfile (`home/.chezmoidata/harness-plugin-lock.json`):** Tracks verified release tags and exact commit SHAs.
3. **Shared extraction:** Chezmoi extracts the archive into `~/.local/share/dotfiles/harness-plugins/compound-engineering`. Each managed harness registers or installs that directory through its native mechanism during explicit apply.

## Compound Engineering Plugin for Codex

Explicit apply installs Codex's native CE plugin from the shared repository-pinned archive. The native marketplace manifest is `.agents/plugins/marketplace.json`; Codex loads skills through `.codex-plugin/plugin.json`.

On each apply, the Codex hook runs the managed executable with `CODEX_HOME` set to the destination home's `.codex` directory:

```sh
codex plugin marketplace add /absolute/path/to/.local/share/dotfiles/harness-plugins/compound-engineering
codex plugin add compound-engineering@compound-engineering-plugin
```

`plugin add` installs and enables the plugin; Codex has no separate `plugin enable` command in the pinned version. Reapplication repairs the native CE cache and activation even when the pin is unchanged. The local marketplace follows the shared CE lock, not an independent latest release.

The private `~/.codex/config.toml` modify template owns only these keys:

- the CE marketplace source and CE activation
- `[plugins._default] enabled = false`
- the `enabled` key of every other `[plugins."<id>"]` entry, set by the rules in [Account Source Isolation](#codex)
- `features.apps = false`
- `check_for_update_on_startup = false`

Other settings, model choices, the other keys of plugin entries, sibling `[features]` flags, and credentials are preserved. A `features` value or plugin entry that is not a table fails apply without replacing the file. Close Codex and T3 Code before applying, then start a fresh session.

### Sign-in and Invocation

Apply does not sign in. Run `codex login` yourself, or provision credentials through a Codex-supported mechanism. Do not add an API key or `auth.json` to tracked plaintext configuration.

After signing in, start Codex and select a CE skill through `/skills`, such as `compound-engineering:ce-plan`. Authentication, model access, and billing remain with Codex; dotfiles does not copy credentials into T3 Code.

The managed scope is the default `~/.codex`. Custom `CODEX_HOME` locations remain unmanaged.

## Compound Engineering Plugin for Claude Code

Explicit apply registers, installs, and enables CE at Claude user scope from the shared local directory. Claude uses the same CE release and commit pin as Codex; the initial pin is `compound-engineering-v3.35.1` at `42f9745ea0a4b70f8dde059aa8cf7f974d2991f1`.

The after hook runs the absolute managed Claude executable with `HOME` bound to the destination home; Windows also sets `USERPROFILE`. It clears `CLAUDE_CONFIG_DIR` so native global state remains in `~/.claude.json`, alongside the default `.claude` directory. Setting that variable even to the default directory would relocate the global file. It performs the native lifecycle:

```sh
claude plugin marketplace add /absolute/path/to/.local/share/dotfiles/harness-plugins/compound-engineering --scope user --json
claude plugin install compound-engineering@compound-engineering-plugin --scope user --json
claude plugin enable compound-engineering@compound-engineering-plugin --scope user --json
```

The pinned CLI returns exit code 1 when the plugin is already enabled. The hook accepts only its structured `already_in_goal_state` result with `alreadyInGoalState=true` as that no-op; genuine errors fail apply. Native marketplace registration repairs a stale source path, and the relative local plugin source loads in place. Reapplication follows the shared archive pin without deleting caches or editing native registry files directly.

The private settings merge owns the CE directory marketplace entry and activation flag, alongside the [Claude preferences](personal-applications.md#claude-code-version-and-preferences) and the [account source settings](#claude-code). Only CE's marketplace has `autoUpdate=false`; unrelated marketplace policies and plugins are preserved. Malformed settings or incompatible owned containers fail instead of replacing the file.

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
It uses the shared `harness-plugin-lock.json` tag and commit.
The package's root `plugin.json` and `skills/` provide the native integration.

Registration lives in Antigravity's native `~/.gemini/config` state. Apply does not rewrite the registry or unrelated CLI settings and plugins. An apply-always hook restores a missing or disabled managed plugin; malformed native state fails rather than being replaced.
Bootstrap does not install or enable plugins. Close Antigravity and T3 sessions before explicitly applying.

Native installation, enablement, package validation, and skill discovery are verified without credentials.
Authenticated CE invocation is verified on the local PC as requested in [issue #52](https://github.com/hyperlapse122/dotfiles/issues/52). Hosted CI remains credential-free; discovery alone is not evidence of model-backed invocation. See the local evidence below.

## Repair and Rollback

Reapply the current worktree with affected harnesses closed to restore the shared payload and run each native plugin reconciliation hook. Use `mise run assets:verify` when full cached-asset integrity verification is needed.

### Version Rollback

To roll back Compound Engineering to an earlier version:
1. Revert `home/.chezmoidata/harness-plugin-lock.json` to the target commit in Git.
2. Run `chezmoi apply` or `mise run apply`.
3. Dotfiles reconciles the shared directory and refreshes each harness through its native integration. Claude loads its local plugin in place; the other harnesses repair their native installation or activation as described above.

## Refreshing Plugin Pins

To query GitHub for the latest stable release and update the lockfile:

```sh
mise exec -- python scripts/update-harness-plugin-lock.py
```

### Automated Updates

A GitHub Actions workflow (**Update harness plugin pins**) runs daily at 06:43 UTC and commits changed release tags and commit SHAs to `main` after generation without running CI validation.
Problems discovered after publication are handled separately.

The same script and workflow refresh the korean-skills pin. See [Pin and Refresh](#pin-and-refresh) for the checks that apply only to skill packs.

## Shared User-Scope Skills

Explicit apply installs the three skills from [DaleSeo/korean-skills](https://github.com/DaleSeo/korean-skills), `grammar-checker`, `humanizer`, and `style-guide`, as plain user-scope skill directories. No plugin is registered, so each harness lists them under their bare names, such as `humanizer` rather than `korean-skills:humanizer`. The [writing-skills rule](#shared-user-scope-agent-instructions) in the shared instructions tells agents when to run them.

### Skill Roots

Each harness loads the skills from one of three shared roots:

| Root | Harnesses |
|---|---|
| `~/.agents/skills/<skill>` | Codex, pi, Grok |
| `~/.claude/skills/<skill>` | Claude Code |
| `~/.gemini/config/skills/<skill>` | Antigravity CLI and app |

`home/.chezmoitemplates/external-assets/harness-skills.toml.tmpl` declares one archive root per skill in each location. A location is rendered only when at least one of its harnesses has a pinned target for the current OS and architecture. All roots use the same pinned archive URL, so the [asset preparation](../maintenance/chezmoi-source.md#external-asset-preparation) downloads it once, and an `include` filter extracts only that skill's subtree.

Each skill directory is exact. Apply replaces a same-named directory at a managed path and removes files inside it that the pinned archive does not contain. Other skills in the same parent directory are left alone. Installation runs only during explicit apply; worktree preparation does not place any skill.

### Pin and Refresh

`home/.chezmoidata/harness-skills.json` declares the pack under `harnessSkills`: the repository, the `v` tag prefix, the reviewed top-level SKILL.md frontmatter keys (`frontmatterKeys`), the three skill names, and each skill's expected `allowed-tools` value. The pin lives in `home/.chezmoidata/harness-plugin-lock.json` under `harnessSkillLocks`, next to the CE pin. The initial pin is `v1.0.0` at `fe6432e95f6675f7e411eacb2e1c36f1de54f962`. Apply fails when the pin lacks a full 40-character commit.

`scripts/update-harness-plugin-lock.py` resolves the latest stable `v<MAJOR>.<MINOR>.<PATCH>` release the same way it resolves CE releases. Before accepting a new skill pin, it checks the release at the resolved commit and rejects it when:

- upstream adds or removes a skill; the error names each added and removed skill
- a SKILL.md frontmatter has a top-level key outside `frontmatterKeys`, such as `hooks` or `shell`, or repeats a key
- a skill's `allowed-tools` value differs from the declared value; the error names the skill and shows both values
- a file under a declared skill is not a plain file or directory (a symlink, an executable, or a submodule), or a declared skill nests another `SKILL.md`
- the repository tree listing comes back truncated

When a rejected pack already has a reviewed pin, the refresh keeps that pin, still writes the CE pin, and exits with status `3`. The daily workflow then publishes the CE pin and fails its run in a separate `report-skill-drift` job, so the change stays visible until someone reviews it. A pack with no reviewed pin yet fails the whole refresh and writes nothing. After reviewing the upstream change, update `harness-skills.json` to match and run the refresh again.

Like CE refreshes, an accepted korean-skills refresh publishes to `main` after generation without running CI validation. Problems discovered after publication are handled separately. Changed instruction text inside an accepted SKILL.md is not reviewed by a person; the checks above cover the capability fields and file types.

### Exactly-Once Discovery

Each harness must list each skill once, so each root holds one copy and each harness loads one root. The choice of roots and the managed settings cover the cases where a harness sees more than one location:

- Codex reads both `~/.agents/skills` and `~/.codex/skills`, lists a skill from both, and reports `~/.codex/skills` as deprecated. The skills therefore go only to `~/.agents/skills`.
- Gemini CLI also reads `~/.gemini/skills`, so the Antigravity copies go to `~/.gemini/config/skills` instead.
- Grok's managed configuration turns off Claude skill compatibility, so Grok shows the `~/.claude/skills` copies as `disabled` entries and loads only the `~/.agents/skills` copies.

Apply does not manage same-named copies in other roots. A copy such as `~/.codex/skills/humanizer`, written by Codex's own skill installer, makes Codex list that skill twice. Remove the extra copy by hand.

### Allowed-Tools Pre-Approval

Each upstream skill declares `allowed-tools: Read Write Edit Grep Glob AskUserQuestion`. In a Claude Code session that uses the default permission mode, the first korean-skills call in a turn pre-approves those tools, so later Write and Edit calls in the same turn run without a prompt. This is an accepted risk: the repository does not edit korean-skills content, the refresh checks above reject a widened field or any other capability frontmatter such as `hooks`, and T3 sessions under the [managed T3 preferences](t3-code.md#personal-preferences) already run with full-access permissions.

## Shared User-Scope Agent Instructions

Every managed AI harness in this repository wires its native instruction file to a shared template:
- **Shared Source:** `home/.chezmoitemplates/agent-instructions`
- **Native Claude Target:** `~/.claude/CLAUDE.md` (generated via `home/private_dot_claude/private_empty_CLAUDE.md.tmpl` with `harness = claude`)
- **Native Codex Target:** `~/.codex/AGENTS.md` (generated via `home/private_dot_codex/private_empty_AGENTS.md.tmpl`)
- **Native Antigravity Target:** `~/.gemini/GEMINI.md` (generated via `home/private_dot_gemini/private_empty_GEMINI.md.tmpl` with `harness: antigravity`)

Applying dotfiles replaces those native instruction files with their harness-specific render of the shared repository template.

The common region holds one rule, a **Writing skills** block that every harness renders with identical text in CLI and T3 launches:

- **In scope:** the message that delivers completed work, an answer, or a summary to the user; handoffs; documents, commit messages, PR descriptions, issues, and other persistent artifacts; and user-facing strings in code, such as string resources and UI or error messages.
- **Out of scope:** progress notes, questions to the user, reports a subagent returns to its caller, code and config, code comments and docstrings, verbatim quotes, and text the user asked to post as written.
- **Korean**, including Korean text with English technical terms: run the korean-skills `humanizer` skill, then `grammar-checker`. Also run `style-guide` when writing a multi-section document or editing an existing document.
- **English:** run `ce-noslop`. **Any other language:** run none of these skills.

The block tells agents to apply the skills silently: deliver only the corrected text, without the skills' analysis or change reports, and do not pause for confirmation inside a skill. It adds to project instructions, so a repository rule that names another writing skill applies as well. The `context = t3` branch supplies only the separately selected T3 additions described in [T3 Code](t3-code.md#instructions-shared-with-the-terminal).

Codex uses a nonempty `~/.codex/AGENTS.override.md` before `AGENTS.md`. Apply preserves that override; remove or update it manually if it should no longer suppress the managed instructions. Project instructions and native configuration precedence still apply.

Disabling Claude automatic memory does not disable its managed `CLAUDE.md` instructions.

For the technical procedure to onboard a new AI harness, see [Chezmoi Source Maintenance](../maintenance/chezmoi-source.md#shared-user-scope-harness-onboarding).

## Account Source Isolation

Claude Code and Codex load only skills, plugins, and MCP servers that come from this repository, the harness itself, local registration, or T3. Sources supplied by the signed-in claude.ai or ChatGPT account are turned off in user-scope settings, so the isolation applies to every launch that reads those settings, including CLI and T3 launches. Without it, Claude Code listed the account's `anthropic-skills:ce-noslop` next to `compound-engineering:ce-noslop`, and what an agent could load depended on the signed-in account.

These keep working: harness-bundled skills and plugins with their local MCP servers, locally registered MCP servers, project MCP configuration, and the MCP server T3 adds to each launch.

### Claude Code

The private `~/.claude/settings.json` merge owns three account-source keys:

| Key | Value | Effect |
|---|---|---|
| `syncClaudeAiSkills` | `false` | Stops syncing claude.ai account skills |
| `syncClaudeAiPlugins` | `false` | Stops syncing claude.ai account plugins |
| `disableClaudeAiConnectors` | `true` | Stops loading claude.ai MCP connectors |

Claude Code moves content it already synced to `.trash` instead of deleting it. The pinned Claude Code `2.1.318` supports all three keys; `syncClaudeAiPlugins` needs `2.1.273` or later. T3 Code 0.1.7 launches Claude through the Agent SDK with the default setting sources, which include user settings, so T3 launches inherit these keys. The per-launch `t3-code` server that T3 registers is not a claude.ai connector and stays available; see [T3 Code](t3-code.md#managed-settings).

Users lose the account skills, such as `anthropic-skills:pdf`, `docx`, `pptx`, and `xlsx`, and the claude.ai connectors, such as Figma, GitLab, Microsoft 365, and T3 Connect. Built-in skills, `compound-engineering:*` skills, and the korean-skills in `~/.claude/skills` remain.

### Codex

The `~/.codex/config.toml` merge sets `[plugins._default] enabled = false`. Remote plugins synced from the ChatGPT account have no config entry, so this default turns them off. Remote sync never writes `config.toml`, so the setting holds across later syncs.

An explicit plugin entry overrides that default, so every apply also decides each existing `[plugins."<id>"]` entry by the marketplace after the last `@` in its ID:

| Entry | Result |
|---|---|
| `compound-engineering@compound-engineering-plugin` | `enabled = true` |
| A local marketplace without an `enabled` key: one configured under `[marketplaces]`, `openai-bundled`, `openai-primary-runtime`, or the personal marketplace in the home directory | `enabled = true`, other keys kept |
| A local marketplace with an explicit `enabled` key | Kept as is |
| Any other marketplace, including `openai-curated-remote`, `created-by-me-remote`, the `workspace-*` marketplaces, and names Codex adds later | `enabled = false`, other keys kept |

The personal marketplace is the first of `~/.agents/plugins/marketplace.json`, `~/.agents/plugins/api_marketplace.json`, `~/.claude-plugin/marketplace.json`, and `~/.cursor-plugin/marketplace.json` that exists, the same order Codex uses; its `name` field counts as local. A malformed personal manifest fails the apply. A repository's own `.agents/plugins/marketplace.json` is not visible to this user-scope merge, so register a repository marketplace with `codex plugin marketplace add <path>` to keep its plugins enabled.

A bundled marketplace that a later Codex release adds stays off until it is added to the template's local list. A bundled plugin entry that Codex writes later without an `enabled` key stays off until the next apply.

`features.apps = false` removes the ChatGPT-hosted `codex_apps` connector server. Locally configured `[mcp_servers]`, plugin MCP servers, and the per-thread `t3-code` servers that T3 adds stay.

Users lose remote plugins from the ChatGPT account, such as GitHub, GitLab, Outlook, Teams, and SharePoint. The bundled `spreadsheets@openai-primary-runtime` plugin and its local skills keep loading, but its `connected_documents` connector reaches the account through `codex_apps` and is removed with it; the owner chose this so that only locally declared sources load. Bundled tools such as browser and computer use keep working.

### Signed-In Verification

The native smokes run without an account, so they show that local sources survive, not that account sources are blocked. On 2026-11-07 the owner's signed-in Windows x64 accounts were probed with the same settings passed per run, without changing the home directory:

- **Codex 0.166.0 app-server** (`skills/list`), with `-c plugins._default.enabled=false -c features.apps=false`: enabled skills went from 83 to 50. All 33 skills from seven `openai-curated-remote` plugins disappeared (1password, onenote, openai-templates, pages, plugin-management, sites, and work-pets). The 37 CE skills, the bundled and primary-runtime plugin skills, and the `.system` skills remained. The CLI prompt also dropped the account's plugin recommendations and its `request_plugin_install` tool.
- **Claude Code 2.1.318** session init, with the three keys passed through `--settings`: all 19 `anthropic-skills:*` skills, all 13 claude.ai connectors (including both T3 Connect connectors), and the synced GitHub plugin disappeared. The 37 CE skills and Claude Code's built-in plugins remained, and the synced files were not moved.

### Limits

- Connectors that the Claude desktop app delivers itself, and Codex desktop builds newer than the pinned CLI, are outside what these user-scope settings control.
- Organization-required claude.ai plugins still load; Claude Code does not let user settings turn them off.
- A custom `CODEX_HOME`, a `CLAUDE_CONFIG_DIR` outside the default `~/.claude`, or a T3 provider `homePath` selects an unmanaged home that these settings do not reach.

## Verification

To run isolated plugin integration tests:

```sh
mise exec -- python tests/smoke_harness_plugins.py
mise exec -- python tests/smoke_antigravity.py
```

The shared-payload smoke verifies pinned CE and shared-skill acquisition, exact skill roots, reapplication, corrupted-payload repair, unrelated-file preservation, and fresh-home omp absence. Shared plugin unit tests cover release rollback. Native harness discovery and invocation are checked by the harness-specific smokes below. The default Antigravity smoke proves native global-instruction ingestion through a localhost capture-only endpoint, runs the native preservation/malformed-state checks with its locked CLI, and verifies that apply leaves T3's native provider ID unclaimed. These default checks use disposable homes without real credentials or model completion; authenticated completion is a separate check.

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

Each of these smokes, plus `tests/smoke_pi.py` and `tests/smoke_t3_instructions.py`, also installs the shared skills in its disposable home and checks that the harness lists `grammar-checker`, `humanizer`, and `style-guide` exactly once. Grok's count ignores entries marked `disabled`. On Windows, Codex resolves `~/.agents/skills` from the OS profile and ignores `HOME`, so its smoke counts the skills only on Linux and macOS and checks the copied directories on Windows. The Codex smoke also confirms that CE skills still load under the `[plugins._default]` allowlist. The T3 instruction smoke confirms that a T3 Claude launch under the account-source settings still sends the `mcp__t3-code__*` tools, the CE and Korean skills, and the writing block. On 2026-11-07 all of these passed locally on Windows x64. None of them signs in to an account, so none proves that account sources are blocked; see [Signed-In Verification](#signed-in-verification).
