---
title: Fix SELinux Bun Hardlink Label Leak by Narrowing Protected Agent Configs - Plan
type: fix
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix SELinux Bun Hardlink Label Leak by Narrowing Protected Agent Configs - Plan

## Goal Capsule

- **Objective**: Package managers (such as Bun) running in unconfined user sessions can freely hardlink and mutate cached package files without hitting `claude_config_t` SELinux AVC denials, while keeping all skill manifests, MCP server configurations, and plugin definitions strictly protected against unauthorized writes.
- **Means**: Shrink the `claude_config_t` and `gemini_config_t` file context specifications in `system/linux/selinux/dotfiles_protected_agent_configs.cil` and the `restorecon` targets in `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` to only the exact configuration and manifest files/subtrees, and delete the now-redundant `system/linux/selinux/dotfiles_tokscale_gemini_access.cil` module. (KTD1, KTD2, KTD3)
- **Authority Hierarchy**: Product Contract R-IDs govern protection boundary and behavior; Planning Contract KTDs govern CIL syntax and script mechanics; Implementation Units execute the changes.
- **Stop Conditions**: Any failure in `secilc` compilation, failure in `.ci/test-selinux-protected-configs.sh`, or failure in templated script rendering.
- **Execution Profile**: Code changes across SELinux policy, apply script, CI tests, and solution documentation.

## Product Contract

### Problem Frame

When `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` executes `restorecon -RFv "$HOME/.claude"`, it recursively traverses `~/.claude/plugins/cache/`. Claude Code installs plugins with Bun, which creates hardlinks from `~/.claude/plugins/cache/...` into the machine-wide global cache at `~/.bun/install/cache/`. Because SELinux labels belong to inodes rather than directory paths, relabeling `~/.claude` stamps `claude_config_t` on shared package cache inodes. Subsequent package installations (e.g. `mise install` or `bun install`) running under `unconfined_t` fail with `EACCES` / AVC denials when trying to link or write to those inodes.

### Requirements

#### Protection Boundary Narrowing
- R1. `claude_config_t` file contexts MUST cover only `~/.claude.json*`, `~/.mcp.json`, `~/.claude/settings.json`, `~/.claude/skills` (symlink), `~/.claude/plugins/installed_plugins.json`, `~/.claude/plugins/known_marketplaces.json`, and `~/.claude/plugins/marketplaces/**`.
- R2. `claude_config_t` MUST NOT claim whole-directory `~/.claude/**` (specifically excluding `plugins/cache`, `plugins/data`, `sessions`, `projects`, `history.jsonl`, `daemon*`, `backups`, etc.).
- R3. `gemini_config_t` file contexts MUST cover only `~/.gemini/config/**` and `~/.gemini/skills` (symlink), and MUST NOT claim whole-directory `~/.gemini/**` (specifically excluding `~/.gemini/antigravity-cli/**` and conversation sqlite databases).
- R4. Neutral canonical paths `~/.agents/skills/**`, `~/.agents/plugins/**`, `~/.codex/config.toml`, and `~/.codex/skills/**` MUST remain protected under `protected_agent_config_t` (chezmoi-only writer).

#### Relabeling Mechanics & Module Cleanup
- R5. `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` MUST pass only the narrow explicit paths to `restorecon` and MUST NOT pass recursive roots `$HOME/.claude` or `$HOME/.gemini`.
- R6. `system/linux/selinux/dotfiles_tokscale_gemini_access.cil` MUST be removed since `~/.gemini/antigravity-cli` defaults to `user_home_t`, allowing `unconfined_t` processes like `tokscale` to read/write SQLite WAL sidecars without widening write access to MCP configurations.
- R7. Stale process detection in the apply script MUST check `claude` and `agy` processes without checking `tokscale`.

#### Verification & Documentation
- R8. `.ci/test-selinux-protected-configs.sh` MUST verify that the policy compiles cleanly with `secilc`, that all narrow file contexts exist, that whole-directory regexes and recursive harness roots are rejected, and that the unconfined write boundary holds.
- R9. Documentation in `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md` and `AGENTS.md` MUST accurately describe the narrowed boundary, hardlink prevention, and tokscale exception retirement.

## Planning Contract

### Key Technical Decisions

- KTD1. **Narrow filecon specifications** (session-settled: user-directed — chosen over excluding specific cache directories: exclusion lists are brittle and miss future cache paths). Governs R1, R2, R3, R4.
  - Claude: `\.claude\.json.*` (file), `\.mcp\.json` (file), `\.claude/settings\.json` (file), `\.claude/skills` (symlink), `\.claude/plugins/installed_plugins\.json` (file), `\.claude/plugins/known_marketplaces\.json` (file), `\.claude/plugins/marketplaces(/.*)?` (any).
  - Gemini: `\.gemini/config(/.*)?` (any), `\.gemini/skills` (symlink).
- KTD2. **Retire `dotfiles_tokscale_gemini_access.cil`** (session-settled: user-directed — chosen over keeping a dedicated tokscale type: unconfined_t natively accesses user_home_t, closing the excess MCP write privilege). Governs R6, R7.
- KTD3. **Discrete `restorecon` paths in apply script**. Governs R5.
  - Replace `$HOME/.claude` and `$HOME/.gemini` in `restorecon -RFv` with the exact narrow paths.
- KTD4. **Strict negative assertions in CI tests**. Governs R8.
  - Assert that `dotfiles_protected_agent_configs.cil` does not contain `\.claude(/.*)?` or `\.gemini(/.*)?`.
  - Assert that rendered apply script does not pass `"$HOME/.claude"` or `"$HOME/.gemini"`.

## Implementation Units

### U1. Narrow CIL File Contexts & Remove Tokscale Module
- **Goal**: Update `system/linux/selinux/dotfiles_protected_agent_configs.cil` with narrow `filecon` specifications and delete `system/linux/selinux/dotfiles_tokscale_gemini_access.cil`.
- **Requirements**: R1, R2, R3, R4, R6.
- **Files**:
  - `system/linux/selinux/dotfiles_protected_agent_configs.cil`
  - `system/linux/selinux/dotfiles_tokscale_gemini_access.cil` (delete)
- **Approach**:
  - Replace whole-tree filecon lines with the specific narrow entries.
  - Update comments in `dotfiles_protected_agent_configs.cil` to document the narrowed surface.
  - Delete `dotfiles_tokscale_gemini_access.cil`.
- **Verification**: `secilc -N -o /tmp/test_policy -f /tmp/test_fc <stub> system/linux/selinux/dotfiles_protected_agent_configs.cil`.

### U2. Update Apply-Time Relabel Script
- **Goal**: Update `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` to relabel only narrow paths and remove tokscale from stale process checks.
- **Requirements**: R5, R7.
- **Files**:
  - `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl`
- **Approach**:
  - Update the `restorecon` arguments list with the narrow files and directories.
  - Update stale domain check from `pgrep -x -u "$(id -u)" 'claude|agy|tokscale'` to `pgrep -x -u "$(id -u)" 'claude|agy'`.
  - Update warning messages to mention `claude/agy`.
- **Verification**: Render template with chezmoi test fixtures and check syntax with `bash -n`.

### U3. Update CI Test Assertions
- **Goal**: Update `.ci/test-selinux-protected-configs.sh` to validate the narrowed boundaries and negative regression checks.
- **Requirements**: R8.
- **Files**:
  - `.ci/test-selinux-protected-configs.sh`
- **Approach**:
  - Remove `tokscale_cil` path and checks.
  - Add checks for all new narrow `filecon` tokens and `file_contexts` entries.
  - Add negative regex assertions against whole-harness `filecon` and `restorecon` roots.
  - Update `policy_check.py` expected matrix to remove `tokscale_t`.
- **Verification**: Execute `./.ci/test-selinux-protected-configs.sh`.

### U4. Update Documentation & AGENTS.md
- **Goal**: Update solution document and repository AGENTS.md to match the narrowed SELinux surface and tokscale unconfined status.
- **Requirements**: R9.
- **Files**:
  - `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md`
  - `AGENTS.md`
- **Approach**:
  - Document the hardlink leakage mechanism, the narrowed paths, and the removal of the tokscale CIL module.
  - Update AGENTS.md SELinux section to match.
- **Verification**: Review markdown links and check for consistency.

## Verification Contract

1. `.ci/test-selinux-protected-configs.sh` passes completely with `secilc` compilation and `setools` boundary checks.
2. Rendered template from `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` passes `bash -n` and contains only narrow paths.
3. No lingering references to `dotfiles_tokscale_gemini_access.cil` in active code.
4. `git diff --check` passes cleanly.

## Definition of Done

- All 4 units (U1 to U4) implemented and verified.
- CI SELinux test script passes with zero errors.
- Clean working directory ready for review, commit, and push.
