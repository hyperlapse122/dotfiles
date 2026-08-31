---
title: "chore: Remove Claude and Codex VS Codium extensions and OpenCode configurations"
date: 2026-08-31
topic: remove-vscodium-agent-extensions
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Technical Plan: Remove Claude and Codex VS Codium Extensions and OpenCode Configurations

## Goal Capsule

- **Objective:** Remove residual Claude Code (`anthropic.claude-code`) and ChatGPT/Codex (`openai.chatgpt`) extension recommendations from `.vscode/extensions.json`, and remove obsolete `claudeCode.*` configuration keys and OpenCode schema domain (`https://opencode.ai`) from the shared VSCodium settings template `.chezmoitemplates/vscodium-settings.json.tmpl`.
- **Means:** Edit `.vscode/extensions.json` to purge `anthropic.claude-code` and `openai.chatgpt` from `recommendations`; edit `.chezmoitemplates/vscodium-settings.json.tmpl` to delete lines for `claudeCode.allowDangerouslySkipPermissions`, `claudeCode.preferredLocation`, `claudeCode.disableLoginPrompt`, `claudeCode.useTerminal`, `claudeCode.hideOnboarding`, and `"https://opencode.ai": true`, adjusting commas so the rendered JSON remains valid.
- **Authority hierarchy:** User instructions govern the removal of Claude, Codex, and OpenCode configurations in VS Codium; repository `AGENTS.md` governs source-only edits and isolated template verification.
- **Stop conditions:** Stop if removing keys causes JSON parse errors when rendering VSCodium user settings for Linux or macOS targets, or if any CI test fails.
- **Execution profile:** Surgical configuration cleanup; verified via template execution with stub data, JSON syntax validation (`jq`), and repository CI tests.
- **Tail ownership:** The LFG pipeline owns implementation, code simplification, code review, git commit, push, PR creation, and CI monitoring.

---

## Product Contract

### Summary

Earlier cleanup (commit `ec3ee32`) removed `anthropic.claude-code` and `openai.chatgpt` from `.chezmoidata/vscodium.yaml`. However, corresponding entries were left behind in:
1. `.vscode/extensions.json` (listing `anthropic.claude-code` and `openai.chatgpt` in `recommendations`).
2. `.chezmoitemplates/vscodium-settings.json.tmpl` (configuring `claudeCode.*` options and allowing schema downloads from `https://opencode.ai`).

This task completes the removal by purging these obsolete references so that VS Codium settings and repository extension recommendations reflect the current agentless editor configuration.

### Requirements

- **R1.** `.vscode/extensions.json` must only recommend active project extensions (`biomejs.biome`, `tamasfe.even-better-toml`, `void-zero.vite-plus-extension-pack`) matching `.chezmoidata/vscodium.yaml`, with `anthropic.claude-code` and `openai.chatgpt` removed.
- **R2.** `.chezmoitemplates/vscodium-settings.json.tmpl` must remove all `claudeCode.*` settings (`claudeCode.allowDangerouslySkipPermissions`, `claudeCode.preferredLocation`, `claudeCode.disableLoginPrompt`, `claudeCode.useTerminal`, `claudeCode.hideOnboarding`).
- **R3.** `.chezmoitemplates/vscodium-settings.json.tmpl` must remove `"https://opencode.ai": true` from `json.schemaDownload.trustedDomains`.
- **R4.** The rendered `settings.json` on both Linux (`dot_config/VSCodium/User/settings.json.tmpl`) and macOS (`Library/Application Support/VSCodium/User/settings.json.tmpl`) must parse as valid JSON.
- **R5.** All changes must pass CI validation and formatting checks (`git diff --check`).

### Scope Boundaries

**In scope:**
- Modifying `.vscode/extensions.json`.
- Modifying `.chezmoitemplates/vscodium-settings.json.tmpl`.
- Verifying template rendering and JSON validity for Linux and macOS targets.

**Out of scope:**
- Modifying `.chezmoidata/vscodium.yaml` (already clean).
- Modifying unrelated OpenCode references in archived plans or disabled provider guards.
- Running live `chezmoi apply` to modify `$HOME`.

---

## Technical Design

### Affected Files and Changes

1. **`.vscode/extensions.json`**
   - Remove `"anthropic.claude-code"` and `"openai.chatgpt"`.
   - Ensure trailing formatting is clean JSON.

2. **`.chezmoitemplates/vscodium-settings.json.tmpl`**
   - Remove lines 45-46:
     ```json
     	"claudeCode.allowDangerouslySkipPermissions": true,
     	"claudeCode.preferredLocation": "panel",
     ```
   - Remove line 130:
     ```json
     		"https://opencode.ai": true,
     ```
   - Remove lines 175-177:
     ```json
     	"claudeCode.disableLoginPrompt": true,
     	"claudeCode.useTerminal": true,
     	"claudeCode.hideOnboarding": true
     ```
   - Update line 174 from:
     ```json
     	"workbench.welcomePage.walkthroughs.openOnInstall": false,
     ```
     to:
     ```json
     	"workbench.welcomePage.walkthroughs.openOnInstall": false
     ```
     (removing the trailing comma so the closing brace is valid JSON).

---

## Verification Plan

### Test Scenarios

1. **JSON Syntax Verification for `.vscode/extensions.json`:**
   ```sh
   jq . .vscode/extensions.json
   ```
   Must succeed with exit 0 and show only the 3 expected extensions.

2. **Template Rendering and JSON Syntax Verification for VSCodium Settings:**
   ```sh
   scratch="$HOME/.cache/agent-scratch/vscodium-verify"
   mkdir -p "$scratch/target"
   : > "$scratch/empty.toml"
   chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < dot_config/VSCodium/User/settings.json.tmpl | jq .
   chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < "Library/Application Support/VSCodium/User/settings.json.tmpl" | jq .
   ```
   Both must render valid JSON with no errors.

3. **Residue Sweep:**
   ```sh
   grep -En 'claudeCode|anthropic\.claude-code|openai\.chatgpt|opencode\.ai' .vscode/ .chezmoitemplates/vscodium-settings.json.tmpl
   ```
   Must return zero matches.

4. **CI Script Checks:**
   ```sh
   git diff --check
   ```
   Must return 0 errors.

---

## Execution Checklist

- [ ] Update `.vscode/extensions.json`
- [ ] Update `.chezmoitemplates/vscodium-settings.json.tmpl`
- [ ] Verify template rendering and JSON parsing with `jq`
- [ ] Verify git diff and whitespace compliance
