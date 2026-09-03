---
title: Fix SELinux Early Policy Installation and AVC Denials Across Pasta, Locate, AOE - Plan
type: fix
date: 2026-09-03
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix SELinux Early Policy Installation and AVC Denials Across Pasta, Locate, AOE - Plan

## Goal Capsule

- **Objective**: Ensure SELinux policies compile and activate at the earliest point in the apply lifecycle (phase `00-tools`, `run_onchange_before_00-selinux-policies.sh.tmpl`), and eliminate recurring AVC denials across `pasta`, `locate` (`updatedb`), `aoe`, and `settings.json` file transitions.
- **Means**:
  1. Relocate `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` to `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl` so `semodule -X 400 -i` updates kernel policy before any package installation or setup script runs. Relabel system chezmoi entrypoints (`/usr/bin/chezmoi`, `/usr/local/bin/chezmoi`).
  2. Update `system/linux/selinux/dotfiles_protected_agent_configs.cil` with `dontaudit pasta_t dri_device_t (chr_file (read write))`, `locate_t` read/search rules on `protected_agent_config_type`, `aoe_t` domain with entrypoint `aoe_exec_t` granting management access to `claude_config_t`, and `typetransition` for `settings.json` and `settings.json.lock`.
  3. Ensure `run_after_config-claude-settings.sh.tmpl` preserves the `claude_config_t` label when rewriting `settings.json`.
  4. Update `.ci/skip-declaration-site-matrix.yaml` and `.ci/test-selinux-protected-configs.sh` to validate the new script path, `secilc` compilation with new types, and the strict write matrix.
  5. Update `AGENTS.md` and `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md`.
- **Authority Hierarchy**: Issue #374 governs problem scope and remedies; Product Contract R-IDs govern policy and lifecycle requirements; Planning Contract KTDs govern CIL and script mechanics; Implementation Units execute the changes.
- **Stop Conditions**: Failure of `secilc` compilation, failure of `.ci/test-selinux-protected-configs.sh`, failure of `.ci/check-skip-declarations.sh`, or failure of `.ci/test-claude-settings-reconcile.sh`.
- **Execution Profile**: Code changes across SELinux CIL policy, chezmoi lifecycle scripts, CI verification tests, and documentation.

## Product Contract

### Problem Frame

1. **Late Policy Installation**: The SELinux policy installer previously lived at `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl`. Chezmoi executes `run_onchange_before_` across numerical phases before `run_onchange_after_`. Consequently, package installations in `20-base` and `30-components` run under the kernel's **old** policy, causing RPM scriptlets or tools to hit AVC denials and fail silently before the new policy is loaded.
2. **Pasta DRI Denial**: Podman executes `pasta` for rootless networking, which inherits an unneeded open file descriptor to `/dev/dri/renderD128` (`dri_device_t`), causing setroubleshoot desktop notification storms.
3. **Locate Denial**: `plocate-updatedb` / `updatedb` (`locate_t`) indexes `$HOME` but is denied read/search on `protected_agent_config_type` because protected types omit `file_type`.
4. **AOE Lock Denial**: `aoe` (`unconfined_t`) is a sanctioned co-writer of `~/.claude/settings.json` (hooks), but `unconfined_t` lacks write permissions on `claude_config_t` and is denied when locking `settings.json.lock` or writing hooks.
5. **Settings.json Label Loss**: In `run_after_config-claude-settings.sh.tmpl`, staging replacement files in `$HOME/.claude/` (now `user_home_t`) and moving them via `mv -f` leaves `settings.json` with `user_home_t`. Processes running without `chezmoi_t` (e.g. `agy_t`) fail `restorecon` with `denied { relabelto }`.

### Requirements

#### Early Policy Installation & Lifecycle Ordering
- R1. SELinux policy installation MUST execute in `00-tools` as `run_onchange_before_00-selinux-policies.sh.tmpl` before any package manager (`dnf`), compiler, or setup scripts run.
- R2. System chezmoi entrypoints (`/usr/bin/chezmoi`, `/usr/local/bin/chezmoi`) MUST be relabelled to `chezmoi_exec_t` during policy installation so chezmoi transitions into `chezmoi_t`.
- R3. `.ci/skip-declaration-site-matrix.yaml` MUST track the relocated script path `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl`.

#### AVC Denials Resolution
- R4. `dotfiles_protected_agent_configs.cil` MUST declare `(dontaudit pasta_t dri_device_t (chr_file (read write)))` to suppress inherited DRI descriptor noise.
- R5. `dotfiles_protected_agent_configs.cil` MUST allow `locate_t` read, search, and getattr access to directories, files, and symlinks of `protected_agent_config_type`.
- R6. `dotfiles_protected_agent_configs.cil` MUST define `aoe_t` domain and entrypoint `aoe_exec_t`, with domain transition from `unconfined_domain_type`, granting `aoe_t` management permissions on `claude_config_t` while retaining strict exclusion from `gemini_config_t` and `protected_agent_config_t`.
- R7. `dotfiles_protected_agent_configs.cil` MUST declare named `typetransition` rules for `settings.json` and `settings.json.lock` from `user_home_t` to `claude_config_t` for `dotfiles_agent_domain`.
- R8. `dotfiles_protected_agent_configs.cil` MUST declare file context specifications for `~/.claude/settings.json.lock` and `aoe` executables (`~/.local/lib/commands/store/aoe/[^/]+/aoe` and `~/.local/bin/aoe`).

#### Settings Preservation & Relabel Durability
- R9. `run_after_config-claude-settings.sh.tmpl` MUST preserve the inode and `claude_config_t` SELinux context of `~/.claude/settings.json` when asserting configuration leaves.

#### Verification & Documentation
- R10. `.ci/test-selinux-protected-configs.sh` MUST assert the relocated script path, `secilc` compilation with `aoe_t`, `pasta_t`, `dri_device_t`, `locate_t`, and test that `aoe_t` can write `claude_config_t` but cannot write `gemini_config_t` or `protected_agent_config_t`.
- R11. `AGENTS.md` and `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md` MUST be updated to document the early policy lifecycle and `aoe_t` co-writer role.

## Planning Contract

### Key Technical Decisions

- KTD1. **Phase 00 `run_onchange_before_00-selinux-policies.sh.tmpl`** (session-settled: user-directed — chosen over creating a new `00-selinux` phase or keeping in `30-linux`). Moving to `00-tools` ensures alphanumeric priority over all `run_onchange_before_` scripts across the repository. Governs R1, R2, R3.
- KTD2. **Dedicated `aoe_t` domain with entrypoint `aoe_exec_t`** (session-settled: user-directed — chosen over weakening unconfined access to `claude_config_t`). `aoe_t` joins `dotfiles_agent_domain` and has management rules for `claude_config_t`, leaving `gemini_config_t` and `protected_agent_config_t` inaccessible. Governs R6, R8.
- KTD3. **`dontaudit` for `pasta_t` on `dri_device_t`** (session-settled: user-directed — chosen over granting read/write access: pasta does not need GPU hardware). Governs R4.
- KTD4. **`locate_t` read/search on `protected_agent_config_type`** (session-settled: user-directed — chosen over adding `file_type`: keeps unconfined write exclusion intact). Governs R5.
- KTD5. **Named file transitions for `settings.json` and in-place content update** (session-settled: user-directed — chosen over relying on unconfined restorecon). Adding `(typetransition dotfiles_agent_domain user_home_t file "settings.json" claude_config_t)` ensures newly created files receive `claude_config_t`, while overwriting existing files in-place preserves existing inode context. Governs R7, R9.

## Implementation Units

### U1. Relocate SELinux Policy Script to Phase 00
- **Files**:
  - `git mv .chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl .chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl`
  - `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl`
  - `.ci/skip-declaration-site-matrix.yaml`
- **Details**:
  - Move the script to `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl`.
  - Add root restorecon for `/usr/bin/chezmoi` and `/usr/local/bin/chezmoi` using `"${SUDO[@]}"`.
  - Add `"$HOME/.claude/settings.json.lock"`, `"$HOME/.local/bin/aoe"`, and `"$HOME/.local/lib/commands/store/aoe"` to user `restorecon` targets.
  - Add `*:aoe_t:*` to healthy domain filter and `aoe` to `pgrep` in stale process checks.
  - Update `.ci/skip-declaration-site-matrix.yaml` line 318 with the new path.
- **Verification**: `chezmoi execute-template < .chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl | bash -n` exits 0; `.ci/check-skip-declarations.sh` passes.

### U2. Update SELinux Policy Module (`dotfiles_protected_agent_configs.cil`)
- **Files**:
  - `system/linux/selinux/dotfiles_protected_agent_configs.cil`
- **Details**:
  - Add `(type aoe_t)`, `(type aoe_exec_t)`, `(roletype unconfined_r aoe_t)`, `(roletype object_r aoe_exec_t)`.
  - Include `aoe_t` in `dotfiles_agent_domain` and `aoe_exec_t` in `dotfiles_agent_exec`.
  - Add `(typetransition unconfined_domain_type aoe_exec_t process aoe_t)` and `(allow aoe_t aoe_exec_t (file (entrypoint read getattr execute open map)))`.
  - Add management rules for `aoe_t` on `claude_config_t` (file, dir, lnk_file).
  - Add `(typetransition chezmoi_t gconf_home_t file "aoe" aoe_exec_t)`.
  - Add filecon for `aoe`: `HOME_DIR/\.local/lib/commands/store/aoe/[^/]+/aoe` and `HOME_DIR/\.local/bin/aoe`.
  - Add filecon for `HOME_DIR/\.claude/settings\.json\.lock`.
  - Add `(dontaudit pasta_t dri_device_t (chr_file (read write)))`.
  - Add `locate_t` allowances on `protected_agent_config_type` for `dir (open read getattr search)`, `file (open read getattr)`, `lnk_file (read getattr)`.
  - Add `(typetransition dotfiles_agent_domain user_home_t file "settings.json" claude_config_t)`.
  - Add `(typetransition dotfiles_agent_domain user_home_t file "settings.json.lock" claude_config_t)`.
- **Verification**: `secilc` compiles the policy against base stub cleanly.

### U3. In-Place Settings Assertion in `run_after_config-claude-settings.sh.tmpl`
- **Files**:
  - `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl`
- **Details**:
  - When asserting `$SETTINGS`, if `$SETTINGS` exists, update in-place (`cat "$tmp" > "$SETTINGS" && rm -f "$tmp"`) to preserve existing inode and `claude_config_t` SELinux label.
  - If `$SETTINGS` does not exist, write `$SETTINGS` which inherits `claude_config_t` via typetransition.
- **Verification**: `.ci/test-claude-settings-reconcile.sh` passes.

### U4. Update CI Verification Suite
- **Files**:
  - `.ci/test-selinux-protected-configs.sh`
- **Details**:
  - Update script template path to `.chezmoiscripts/00-tools/run_onchange_before_00-selinux-policies.sh.tmpl`.
  - Add `pasta_t`, `dri_device_t`, `locate_t`, `aoe_t`, `aoe_exec_t` to `base_stub.cil`.
  - Add token assertions for `aoe_t`, `aoe_exec_t`, `dontaudit pasta_t`, `locate_t`, and `typetransition ... "settings.json"`.
  - Assert `forbidden_writer 'aoe_t' 'gemini_config_t'` and `forbidden_writer 'aoe_t' 'protected_agent_config_t'`.
  - Update `policy_check.py` write matrix to expect `('aoe_t', 'claude_config_t'): True`, `('aoe_t', 'gemini_config_t'): False`, `('aoe_t', 'protected_agent_config_t'): False`.
- **Verification**: `./.ci/test-selinux-protected-configs.sh` passes cleanly.

### U5. Update Documentation & AGENTS.md
- **Files**:
  - `AGENTS.md`
  - `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md`
- **Details**:
  - Document early policy compilation in `00-tools`.
  - Document `aoe_t` domain role as co-writer of `claude_config_t`.
  - Document resolutions for `pasta_t`, `locate_t`, and `settings.json` file transitions.
- **Verification**: Markdown links and terminology consistency.

## Verification & Test Matrix

| Check | Target | Expected Outcome |
|---|---|---|
| `./.ci/test-selinux-protected-configs.sh` | Policy compilation & write boundary | All assertions pass, mutant rejected |
| `./.ci/check-skip-declarations.sh` | Skip declaration site matrix | Matches relocated script |
| `bash -n` | Rendered template | Valid bash syntax |
| `.ci/test-claude-settings-reconcile.sh` | Claude settings reconciler | All assertions pass |
