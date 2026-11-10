---
title: Claude Code's dangerous-rm prompt survives bypass mode while any PermissionRequest hook remains
date: "2026-10-28"
category: integration-issues
module: Claude Code permissions (bypass mode, T3 Code full access)
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "T3 Code in full access still stops a Claude Code session with \"Dangerous rm operation not ruled out — the shell may read this command differently than it was parsed\" and an Approve/Decline card"
  - "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS is set, yet the prompt keeps appearing and nothing in T3 Code says why"
root_cause: config_error
resolution_type: config_change
tags: ["claude-code", "bypass-permissions", "dangerous-rm", "permission-request-hook", "t3code", "orca", "environment-tier", "safety-check"]
retire_when: "Claude Code drops `waivableInBypass` from `dangerousRemoval` or renames CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS; check a newer binary's strings for both names"
---

# Claude Code's dangerous-rm prompt survives bypass mode while any PermissionRequest hook remains

## Problem

Bypass permissions mode, which T3 Code's full access selects, does not skip every Claude Code approval. A few safety checks are bypass-immune. One of them, the dangerous-rm check, can be waived by an environment variable, but Claude Code ignores that variable whenever a `PermissionRequest` hook or a Bash, Edit, or Read ask or deny rule exists. Hooks the retired Orca app left in `~/.claude/settings.json` included such a hook, so the waiver could not work until they were removed.

## Symptoms

- A command Claude Code cannot fully parse, here a zsh array in a format-and-lint command, raises an approval card in T3 Code full access: "Dangerous rm operation not ruled out — the shell may read this command differently than it was parsed". The check's own reason ends "This requires explicit approval."
- T3 Code's card says full access "skips approvals, but the agent still stops for a few safety checks of its own that no setting can skip", which is only partly true for this check.

## What Didn't Work

- Looking for a settings.json key or a `permissions.allow` rule. The check is bypass-immune; the waiver is an environment variable, not a setting.
- Declaring a guard against hooks in this repository's declared Claude settings. The tier is written through the `agent-settings` merger's `set` and `setPaths` fields, which accept only scalars (`scripts/agent-settings:201`, `scripts/agent-settings:263`), so it cannot hold a hook array or a permission list in the first place. A check for one would be decorative.
- Trusting the startup warning. Claude Code reports "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS has no effect in this session" when the waiver is void, on stderr and, under stream-json, as a `system` frame with subtype `notification`. T3 Code spawns `claude` with stderr ignored and has no handler for that subtype, so in T3 the only signal is the prompt coming back.

## Solution

Read from the Claude Code 2.1.312 bundle (`packages/claude-code-manifest.json`):

- The safety-check table marks `dangerousRemoval` `bypassImmune: true, waivableInBypass: true`. It is the only waivable entry. `unfinishedCheck`, `outsideReadsBlocked`, `restrictedMode`, and `isolatePeerMachines` are bypass-immune and not waivable at all, so no configuration removes every prompt.
- `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS` is read as a boolean (`1`, `true`, `yes`, or `on`). It waives `dangerousRemoval` only when the mode is `bypassPermissions` and a waiver flag stays set for the session. That flag is cleared by:
  - a `PermissionRequest` hook in settings, plugin settings, registered hooks, or the session's hook registry, or a configured permission-prompt tool;
  - a deny or ask rule that matches Bash, Edit, or Read, except a whole-tool rule from the `toolsNarrowing` or `command` sources;
  - `blockReadsOutsideWorkingDirectories` set to true.
- The skip also requires `CLAUDE_CODE_CHILD_SESSION` to be false, no settings change still in flight, every managed-settings source loaded without errors, no hook ask floor, and hook registration settled.
- `CLAUDE_CODE_CHILD_SESSION` is injected into the environment of Bash tool commands, hook commands, and the status-line command, never into the `claude` process itself. Checking a shell's environment misleads here: a Bash tool child shows `CLAUDE_CODE_CHILD_SESSION=1` while its parent `claude` process, read from `/proc/<pid>/environ`, does not carry it.

The fix in this repository:

- `home/h82/agents/claude.nix:27` declares the variable in Claude Code's environment tier. On Linux the T3 Code desktop's `claude` process inherits that tier, as it already did for `DISABLE_AUTOUPDATER`.
- `home/h82/agents/claude.nix:119` adds a macOS login agent that publishes it with `launchctl setenv`, because Finder and Dock launches never read `hm-session-vars.sh`.
- `home/h82/agents/retire-orca.nix` runs `scripts/retire-orca`. It removes every Claude and Codex hook whose command matches `ORCA_AGENT_HOOK` or `/.orca/agent-hooks/` (`scripts/retire-orca:38`) one hook at a time, deletes Antigravity's `orca-status` entry, drops Orca's Claude status line and Codex's trust entries for a deleted hooks file, and deletes Orca's state directories.

## Why This Works

Orca had installed a hook group on all 13 Claude Code events present in this session's `~/.claude/settings.json`, `PermissionRequest` among them, so the waiver flag stayed cleared and the variable did nothing. With those hooks gone and the variable declared, the two gates this change controls hold. The rest hold on a default setup: no Bash, Edit, or Read ask or deny rule, no managed settings, and a main session rather than a child process.

## Prevention

- When the dangerous-rm prompt returns in a main T3 Code session, inspect the live `~/.claude/settings.json` and enabled plugins for a `PermissionRequest` hook and for Bash, Edit, or Read ask or deny rules before suspecting the variable. A plugin hook counts: the official marketplace's `claude-security` plugin registers one in its hooks file (under `~/.claude/plugins/marketplaces/claude-plugins-official/`, outside this repository), so enabling it voids the waiver.
- Run `claude` in a terminal once after such a change: the startup warning can name the void waiver there even though T3 Code hides it.
- When a Claude Code bump lands, confirm the bundle still contains `waivableInBypass` and the variable name before assuming the waiver still applies.

## Related

- [Claude Code ignores global-config keys declared in settings.json](claude-code-global-config-keys-ignored-in-settings-json.md): the other case where a Claude Code setting has to live in the tier Claude Code actually reads.
