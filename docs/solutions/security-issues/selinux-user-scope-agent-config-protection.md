---
title: SELinux CIL Type Enforcement for Protecting User-Scope Agent and MCP Configs
date: 2026-08-31
category: security-issues
module: selinux
problem_type: security_issue
component: security_policy
symptoms:
  - "Unmanaged tools or agent CLI processes modifying ~/.codex/config.toml, ~/.claude.json, or ~/.mcp.json directly in user home directory"
  - "Standard POSIX 0444 permissions bypassed because file owner can unlink or recreate files"
root_cause: missing_permission
resolution_type: config_change
severity: medium
tags:
  - selinux
  - cil
  - chezmoi
  - agent-configs
  - type-enforcement
  - fedora
---

# SELinux CIL Type Enforcement for Protecting User-Scope Agent and MCP Configs

## Problem

AI agent CLIs, IDE extensions, and background tools running in user session domains (`unconfined_t`) can accidentally mutate, inject, or delete user-scoped agent configurations and skill manifests in `$HOME` without going through version-controlled dotfiles management. Standard POSIX read-only permissions (`0444`) do not prevent the file owner from unlinking or recreating files, and Linux file immutability (`chattr +i`) requires root elevation for every routine dotfile edit.

## Symptoms

- Direct writes or unlinks to `~/.codex/config.toml`, `~/.claude.json*`, `~/.mcp.json`, and `~/.codex/skills/` succeed under unconfined user processes.
- Accidental changes by agent CLI tools bypass the repository's dotfiles-first workflow.

## What Didn't Work

- **POSIX `chmod 0444`**: File owner retains write permission on parent directory (`$HOME`), allowing atomic delete-and-replace (`unlink + create`) operations.
- **Linux file immutability (`chattr +i`)**: Requires `CAP_LINUX_IMMUTABLE` (root elevation via `sudo`), creating high friction during normal user-level `chezmoi apply` runs.
- **Directory-wide confinement**: Locking the entire `~/.codex/` directory breaks unconfined runtime files such as sqlite databases (`goals_1.sqlite`, `logs_2.sqlite`, `state_5.sqlite`), IPC sockets, and logs.

## Solution

Deploy a declarative SELinux Common Intermediate Language (CIL) module that establishes a dedicated type `protected_agent_config_t`, a management domain `chezmoi_t`, and an entrypoint `chezmoi_exec_t`. Configure domain transitions so only chezmoi can write to protected files, while all other unconfined user processes retain read-only access.

### 1. Declarative CIL Policy (`system/linux/selinux/dotfiles_protected_agent_configs.cil`)

```cil
; Types and Roles
(type protected_agent_config_t)
(roletype object_r protected_agent_config_t)

(type chezmoi_t)
(roletype unconfined_r chezmoi_t)

(type chezmoi_exec_t)
(roletype object_r chezmoi_exec_t)
(typeattribute chezmoi_exec_t (file_type exec_type))

; Domain Transition
(typetransition unconfined_t chezmoi_exec_t process chezmoi_t)
(allow unconfined_t chezmoi_exec_t (file (read getattr execute open map)))
(allow unconfined_t chezmoi_t (process (transition)))
(allow chezmoi_t chezmoi_exec_t (file (entrypoint read getattr execute open map)))

; Process inheritance and unconfined base capabilities
(allow chezmoi_t unconfined_t (process (sigchld signull sigkill sigterm signal)))
(allow chezmoi_t unconfined_t (fd (use)))
(allow chezmoi_t user_devpts_t (chr_file (read write ioctl getattr append open)))
(typeattributeset unconfined_domain_type (chezmoi_t))

; Permissions on protected files
(allow chezmoi_t protected_agent_config_t (file (create read write getattr setattr unlink rename open append lock map)))
(allow chezmoi_t protected_agent_config_t (dir (create read write getattr setattr unlink rename open search add_name remove_name reparent rmdir lock)))
(allow unconfined_t protected_agent_config_t (file (read getattr open map)))
(allow unconfined_t protected_agent_config_t (dir (read getattr open search)))

; File context specifications
(filecon "/home/[^/]+/\.codex/config\.toml" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "/home/[^/]+/\.claude\.json.*" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "/home/[^/]+/\.mcp\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "/home/[^/]+/\.claude/settings\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "/home/[^/]+/\.codex/skills(/.*)?" any (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "/usr/bin/chezmoi" file (system_u object_r chezmoi_exec_t ((s0)(s0))))
(filecon "/usr/local/bin/chezmoi" file (system_u object_r chezmoi_exec_t ((s0)(s0))))
(filecon "/home/[^/]+/\.local/bin/chezmoi" file (unconfined_u object_r chezmoi_exec_t ((s0)(s0))))
```

### 2. Apply-time Lifecycle Script (`.chezmoiscripts/30-linux/run_after_selinux-policies.sh.tmpl`)

Install the policy module with `sudo semodule -X 400 -i` and relabel files with `restorecon -RFv`, caching the CIL source hash in `~/.local/state/chezmoi/selinux-policies.stamp` to prevent redundant compilations on idempotent applies.

## Why This Works

SELinux Type Enforcement operates independently of POSIX file ownership (`UID`/`GID`). Even though the files are owned by the user, the kernel denies `write`, `setattr`, `unlink`, and `rename` syscalls from processes running in the `unconfined_t` domain against objects labeled `protected_agent_config_t`. When `chezmoi` is executed, the kernel transitions the process into `chezmoi_t`, which holds explicit management rules for `protected_agent_config_t`.

## Prevention

- Always declare targeted `filecon` regexes for configuration files rather than broad directory paths to avoid breaking runtime database/cache writes.
- Label all potential entrypoint binaries (`/usr/bin/chezmoi`, `~/.local/bin/chezmoi`) with `chezmoi_exec_t` so domain transitions fire regardless of PATH resolution.
- Verify policy changes using `.ci/test-selinux-protected-configs.sh` and test skip handling with `.ci/check-skip-declarations.sh`.

## Related Issues

- Plan: `docs/plans/2026-08-31-1258-feat-selinux-protected-agent-configs-plan.md`
