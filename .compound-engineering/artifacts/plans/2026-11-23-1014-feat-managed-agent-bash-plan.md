---
title: "feat: Use Bash in managed agent sessions"
type: feat
date: 2026-11-23
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Use Bash in managed agent sessions

## Goal Capsule

**Objective.** An agent can run a Bash command on its first attempt without retrying it in another shell or making the operator undo partial work.

**Means.** Select Nix Bash for managed shell tools and OpenCode's terminal (KTD1–KTD2).

**Delivery.** One PR. The three settings can land independently in the same change. The implementing contributor owns verification against R1–R3. Host activation stays with the owner.

## Product Contract

### Summary

Make Bash the default for Claude Code, Pi, and OpenCode on the managed macOS and NixOS hosts. This includes native CLI sessions and the local providers launched by T3 Code.

### Problem Frame

Agents write commands using Bash syntax that zsh can interpret differently. When an earlier command has already changed files, rerunning the sequence can cost more than the failed command itself.

### Requirements

- R1. In a fresh session of each included harness, a shell-tool call with no interpreter override runs under Bash from the first command. A task can still invoke zsh explicitly.
- R2. OpenCode also opens its built-in interactive terminal in Bash.
- R3. Keep the account login shell and ordinary terminal sessions on their existing settings. Codex is outside the change.

### Key Decisions

- Use Bash for both OpenCode surfaces (session-settled: user-directed — chosen over separate tool and terminal settings: both should use Bash). Governs R2.
- Exclude Codex (session-settled: user-directed — chosen over per-call instructions or maintaining a patched build: neither is part of this change). Governs R3.

## Planning Contract

### Key Technical Decisions

- KTD1. Declare the absolute Nix Bash executable, `${pkgs.bash}/bin/bash`, at the user-settings tier for each included harness. This supplies the same Bash on CLI and GUI launches and leaves normal project overrides available. The managed T3 providers use the native account homes; their setting sources and launch paths are documented in `home/h82/t3code.nix` and `docs/agent-routing.md`.
- KTD2. Assign just the owned setting through each harness's existing merge path. OpenCode's tool reads `shell`. Its GUI opens a persistent PTY that reads the process environment, so the packaged OpenCode launcher must also set `SHELL` for its children (R2). Pi's `shellPath` also applies to its in-session `!` and `!!` commands. [OpenCode tool](https://github.com/anomalyco/opencode/blob/v2.3.2/packages/core/src/tool/plugin/shell.ts#L407-L420) · [OpenCode terminal](https://github.com/anomalyco/opencode/blob/v2.3.2/packages/core/src/persistent-pty/index.ts#L255-L256) · [Pi shell selection](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/docs/shell-aliases.md)

## Implementation Units

### U1. Set Claude Code's Bash tool interpreter

**Files.** `home/h82/agents/claude.nix`, `tests/claude.nix`.

Add the `env.CLAUDE_CODE_SHELL` leaf to `settingsPaths` following the existing `env.DISABLE_AUTOUPDATER` entry. Claude reads this variable from its user settings regardless of how the session starts. The path must point to a working Bash executable or Claude falls back to shell detection. [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)

**Test scenario (R1, R3).** Merge into a fixture with an unrelated `env` entry. Check that the new leaf resolves to Nix Bash and the sibling survives. Use the first-command probe below for execution.

### U2. Declare Pi's Bash path during settings activation

**Files.** `home/h82/agents/pi.nix`, `scripts/pi-state`, `tests/pi-settings.py`, `tests/pi.nix`.

Pass the store path from `piSettings` to the existing settings-writing branch of `pi-state`. Assign `shellPath` in the same read/modify/write as the other owned settings. Keep the argument optional for existing callers and leave the auth-only invocation alone. Pi already prefers Bash, but on macOS it looks for `/bin/bash` first, and on Linux it can fall back to `sh`. [Pi resolver](https://github.com/earendil-works/pi/blob/v1.6.0/packages/coding-agent/src/utils/shell.ts)

**Test scenario (R1, R3).** Start the existing activation fixture with an older `shellPath`. After its normal activation sequence, expect the declared Bash path and the fixture's unrelated settings.

### U3. Select Bash for OpenCode commands and terminals

**Files.** `home/h82/agents/opencode.nix`, `packages/opencode.nix`, `tests/opencode.nix`.

Add `set.shell` beside `set.update` in the declaration for `~/.config/opencode/opencode.json`. Wrap the release executable with the same Bash path in its process environment. Preserve the upstream Bun executable byte for byte. The local T3 instance launches the same packaged OpenCode with its user configuration. Its existing `OPENCODE_CONFIG_CONTENT` entry supplies T3 instructions and needs no shell setting. [OpenCode selector](https://github.com/anomalyco/opencode/blob/v2.3.2/packages/core/src/shell/select.ts) · [T3 local provider](https://github.com/pingdotgg/t3code/blob/v0.1.9/docs/user/providers-opencode.md)

**Test scenario (R1–R3).** Exercise the existing merge fixture with an old shell value and a user-owned provider entry. Expect the Bash path and the preserved provider. In a fresh OpenCode terminal the first-command probe must also report Bash.

## Verification Contract

Run the project's `agent-check` on the implementation diff. Use the existing Claude, Pi, and OpenCode checks for the merge scenarios above.

For runtime acceptance, start with zsh as the parent shell and no project-level override. In each harness, send `printf '%s\n' "${BASH_VERSION:-missing}"` as the **first shell-tool command**, once through its native CLI and once through its managed local T3 provider. Omit any explicit interpreter or `bash -c` prefix. Expect a Bash version in every case. For T3 OpenCode, use a fresh local server that has loaded the settings. Repeat the probe in OpenCode's built-in terminal for R2. The inherited `$SHELL` value alone cannot identify the interpreter.

## Definition of Done

The three declared settings reach their CLI and local T3 sessions, the first-command probe reports Bash, and OpenCode's built-in terminal opens in Bash. The diff stays within R3.
