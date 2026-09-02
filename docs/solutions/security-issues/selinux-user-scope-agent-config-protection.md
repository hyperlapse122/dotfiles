---
title: SELinux CIL Type Enforcement for Protecting User-Scope Agent and MCP Configs
date: 2026-08-31
last_updated: 2026-09-02
category: security-issues
module: selinux
problem_type: security_issue
component: security_policy
symptoms:
  - "Unmanaged tools or agent CLI processes modifying ~/.codex/config.toml, ~/.claude.json, or ~/.mcp.json directly in user home directory"
  - "Standard POSIX 0444 permissions bypassed because file owner can unlink or recreate files"
  - "SELinux label stripping when setting files are atomically moved from /tmp"
  - "A protected type that carries the file_type attribute is writable by every unconfined process, so the module labels files and denies nothing"
  - "Agent session started before the policy was installed keeps unconfined_t and loses write access to its own transcript and session state"
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
  - mcp
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

Deploy a declarative SELinux Common Intermediate Language (CIL) module that establishes a dedicated type `protected_agent_config_t`, a management domain `chezmoi_t`, and an entrypoint `chezmoi_exec_t`. Configure domain transitions so only chezmoi can write or relabel protected files, directories, and symlinks, while all unconfined user processes retain read, search, map, and execute access.

### 1. Declarative CIL Policy (`system/linux/selinux/dotfiles_protected_agent_configs.cil`)

```cil
; Types and Roles
(type protected_agent_config_t)
(roletype object_r protected_agent_config_t)
(typeattributeset file_type (protected_agent_config_t))

(type chezmoi_t)
(roletype unconfined_r chezmoi_t)

(type chezmoi_exec_t)
(roletype object_r chezmoi_exec_t)
(typeattributeset file_type (chezmoi_exec_t))
(typeattributeset exec_type (chezmoi_exec_t))

; Domain Transition: unconfined_t -> chezmoi_exec_t -> chezmoi_t
(typetransition unconfined_t chezmoi_exec_t process chezmoi_t)
(allow unconfined_t chezmoi_exec_t (file (read getattr execute open map)))
(allow unconfined_t chezmoi_t (process (transition)))
(allow chezmoi_t chezmoi_exec_t (file (entrypoint read getattr execute open map)))

; Process inheritance and lifecycle
(allow chezmoi_t unconfined_t (process (sigchld signull sigkill signal)))
(allow chezmoi_t unconfined_t (fd (use)))
(allow chezmoi_t user_devpts_t (chr_file (read write ioctl getattr append open)))
(allow chezmoi_t self (process (execmem fork sigchld signull sigkill sigstop signal getsched setsched getsession getpgid setpgid setrlimit)))
(allow chezmoi_t file_type (file (relabelto relabelfrom)))
(allow chezmoi_t file_type (dir (relabelto relabelfrom)))

(typeattributeset domain (chezmoi_t))
(typeattributeset application_domain_type (chezmoi_t))
(typeattributeset unconfined_domain_type (chezmoi_t))

; Permissions on protected configs
; chezmoi_t has full management permissions on protected configs
(allow chezmoi_t protected_agent_config_t (file (create read write getattr setattr unlink rename open append lock map relabelto relabelfrom)))
(allow chezmoi_t protected_agent_config_t (dir (create read write getattr setattr unlink rename open search add_name remove_name reparent rmdir lock relabelto relabelfrom)))
(allow chezmoi_t protected_agent_config_t (lnk_file (create read getattr setattr unlink rename relabelto relabelfrom)))

; unconfined_t has read, execute, and traversal access to protected configs
(allow unconfined_t protected_agent_config_t (file (read getattr open map execute)))
(allow unconfined_t protected_agent_config_t (dir (read getattr open search)))
(allow unconfined_t protected_agent_config_t (lnk_file (read getattr)))

; File context specifications
(filecon "HOME_DIR/\.codex/config\.toml" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.claude\.json.*" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.mcp\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.claude/settings\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.claude/skills" symlink (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.gemini/antigravity-cli/mcp\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.gemini/config/mcp_config\.json" file (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.gemini/skills" symlink (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.agents/skills(/.*)?" any (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.agents/plugins(/.*)?" any (unconfined_u object_r protected_agent_config_t ((s0)(s0))))
(filecon "HOME_DIR/\.codex/skills(/.*)?" any (unconfined_u object_r protected_agent_config_t ((s0)(s0))))

; chezmoi executables
(filecon "/usr/bin/chezmoi" file (system_u object_r chezmoi_exec_t ((s0)(s0))))
(filecon "/usr/local/bin/chezmoi" file (system_u object_r chezmoi_exec_t ((s0)(s0))))
(filecon "HOME_DIR/\.local/bin/chezmoi" file (unconfined_u object_r chezmoi_exec_t ((s0)(s0))))
```

### 2. Apply-time Lifecycle Script (`.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl`)

Install the policy module with `sudo semodule -X 400 -i` and relabel files with `restorecon -RFv` across all declared configuration files, skill directories, and symlinks.

## Correction (2026-09-02): the first revision enforced nothing

The module quoted above declares `(typeattributeset file_type (protected_agent_config_t))`. That single line made the whole thing inert. Fedora's targeted policy ships

```
allow files_unconfined_type file_type:file { ... write create unlink rename setattr append ... };
```

and `unconfined_t` holds `files_unconfined_type` (39 attributes, verified with `setools.SELinuxPolicy()` on the running policy). An SELinux allow rule can only ADD access, never subtract it, so the moment a type joins `file_type` every unconfined user process may write it — and the `(allow unconfined_t protected_agent_config_t (file (read ...)))` rule beside it is redundant, not restrictive. The files were labelled and nothing was denied.

**A protected type must carry no base-policy attribute at all.** With no attributes, no base rule can name it, so the module's own rules are the complete access set for it. The `*_exec_t` entrypoints are the exception and stay `file_type`: they are ordinary binaries every launcher must read and execute.

### The one capability `file_type` did confer: `filesystem associate`

Removing the attribute broke labelling until the loss was replaced. `restorecon` failed with

```
avc: denied { associate } for pid=… comm="restorecon" name="SKILL.md"
  scontext=unconfined_u:object_r:gemini_config_t:s0
  tcontext=system_u:object_r:fs_t:s0 tclass=filesystem permissive=0
```

`associate` is the kernel's check that a file LABEL may live on a filesystem LABEL: scontext is the file's type, tcontext is the filesystem's. It is not a domain access grant, and no amount of `allow chezmoi_t …` fixes it — without it the label cannot be written at all, so every new type silently stays `user_home_t`.

Enumerating the running policy for rules whose SOURCE is literally `file_type` returns five, and only five:

```
allow file_type { fs_t tmp_t tmpfs_t hugetlbfs_t noxattrfs }:filesystem associate;
```

So the complete replacement is those five rules restated for the protected types:

```cil
(allow protected_agent_config_type fs_t (filesystem (associate)))
(allow protected_agent_config_type tmp_t (filesystem (associate)))
(allow protected_agent_config_type tmpfs_t (filesystem (associate)))
(allow protected_agent_config_type hugetlbfs_t (filesystem (associate)))
(allow protected_agent_config_type noxattrfs (filesystem (associate)))
```

### The second surprise: a policy change strands running sessions

Immediately after a successful apply, the running Claude Code session reported `Transcript writes are failing (permission denied — EACCES)` and the audit log filled with

```
avc: denied { append } for pid=3110988 comm="Bun Pool 0" name="<session>.jsonl"
  scontext=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
  tcontext=unconfined_u:object_r:claude_config_t:s0 tclass=file permissive=0
```

The source context is the tell: `unconfined_t`, not `claude_t`. SELinux assigns a process its domain at `exec`, and `semodule -i` never moves a process that is already running. That session had exec'd the (then unlabelled) binary before the module existed, so it kept `unconfined_t` while `restorecon` relabelled its files out from under it. `security_compute_create()` confirmed a `claude` started afterwards resolves to `claude_t`, which the policy does allow to write those paths.

This is not a policy defect and must not be "fixed" with an `audit2allow` module — the setroubleshoot suggestion to allow `unconfined_t` write access to `claude_config_t` would undo the entire split. The fix is to restart the session.

A restart confirmed it on the live host. The old session's processes stayed in the wrong domain while the new one entered the right one:

```
3110957  claude  unconfined_u:unconfined_r:unconfined_t:...   # started 13:29, before the apply
3224110  claude  unconfined_u:unconfined_r:claude_t:...       # started 14:15, after it
```

The restarted session then wrote to `~/.claude` successfully, and the file it created carried `claude_config_t` — the label the policy intends and the write the split is built to allow.

Restarting the terminal session turned out not to be sufficient, and the reason is worth recording. Claude Code runs a **daemon parented to systemd** (`claude daemon run --origin transient`, PPid 1) that outlives any single terminal, plus `bg-pty-host` children under it. After the restart the audit log kept filling from the same `pid=3110988` — a session forked under the pre-policy daemon, still on `pts/25`:

```
3110957  claude daemon run --origin transient      PPid=1 (systemd)   unconfined_t
3110973   └─ claude bg-pty-host .../f849eb82.sock                     unconfined_t
3110988       └─ claude --session-id f849eb82…     pts/25             unconfined_t
```

Every one of them exec'd before the module existed. A *new* exec of the binary does transition correctly even when the stale daemon is the one doing the exec, because `unconfined_t` is in `unconfined_domain_type` and the type transition fires on any exec of `claude_exec_t` — so the damage is bounded to the processes already running. But those must be killed explicitly; closing their terminal does not reach the systemd-parented daemon.

The stale processes therefore survive the restart of a *different* terminal, so the apply script does not just print the instruction: it enumerates the offenders. It reads `/proc/<pid>/attr/current` for every `claude`/`agy` process the user owns and lists the pid, command, and start time of each one that is not already in `claude_t`, `agy_t`, or `chezmoi_t`. A generic notice leaves an operator with several terminals open guessing which one to restart; the pid list does not. CI asserts both the sentence and the enumeration, so a later edit cannot quietly collapse it back into a static message.

Prefer running `chezmoi apply` from a plain shell rather than from inside an agent session whose transcript the same apply is about to lock out.

### Diagnostics

`ls -Zd` the target. A path that kept `user_home_t` after an apply that reported no error is an `associate` denial, not a `filecon` typo — the module installed, `restorecon` ran, and the kernel refused the label.

## Why This Works

SELinux Type Enforcement operates independently of POSIX file ownership (`UID`/`GID`). Even though the files are owned by the user, the kernel denies `write`, `setattr`, `unlink`, and `rename` syscalls from processes running in the `unconfined_t` domain against objects that carry a type no rule grants them — which, for an attribute-free type, means every domain except the ones this module names. When `chezmoi`, `claude`, or `agy` is executed, the kernel transitions the process into `chezmoi_t`, `claude_t`, or `agy_t`, each of which holds explicit management rules for the types it owns.

The three domains keep `files_unconfined_type` themselves, so they retain ordinary access to project trees, `/tmp`, and caches; that grant is scoped to `file_type` objects, which the protected types are not, so the config boundary holds.

By granting `(file (read getattr open map ioctl lock execute execute_no_trans watch watch_reads))` to `unconfined_domain_type`, user tools and agents can freely read configuration files, resolve symlinks, watch them, and execute skill scripts in `~/.agents/skills/` without permission denials.

## Current shape: three types, one writer rule each

| Type | Paths | Writers |
|---|---|---|
| `protected_agent_config_t` | `~/.codex/config.toml`, `~/.codex/skills/**`, `~/.agents/skills/**`, `~/.agents/plugins/**` | `chezmoi_t` |
| `claude_config_t` | `~/.claude.json*`, `~/.mcp.json`, `~/.claude/settings.json`, `~/.claude/skills`, `~/.claude/plugins/installed_plugins.json`, `~/.claude/plugins/known_marketplaces.json`, `~/.claude/plugins/marketplaces/**` | `chezmoi_t`, `claude_t` |
| `gemini_config_t` | `~/.gemini/config/**`, `~/.gemini/skills` | `chezmoi_t`, `agy_t` |

A harness needs its own domain because it rewrites its own configuration during ordinary use — the enabled-plugin set, marketplace registries, settings — so a chezmoi-only writer would break the tool the label protects. Non-config runtime state (`plugins/cache`, `plugins/data`, `sessions`, `projects`, `history.jsonl`, `daemon*`, `backups`, and `~/.gemini/antigravity-cli/**`) falls back to `user_home_t`. `~/.claude/skills` and `~/.gemini/skills` take their harness's type but resolve into `~/.agents/skills`, so the canonical skills root stays chezmoi-only through the symlink.

Domain transitions are granted from `unconfined_domain_type` rather than from one named source: these binaries are launched from a login shell, a chezmoi script, another agent, and IDE helpers, and a launcher with no transition rule is denied the exec outright rather than merely running unconfined. Entrypoints are labelled on the real files in the versioned command store (`~/.local/lib/commands/store/<tool>/<version>/<tool>`), because `~/.local/bin/<tool>` is a symlink and an exec label on a symlink never applies.

## The fourth surprise: `restorecon` on whole harness homes leaks labels via hardlinks into shared package caches (2026-09-02)

When `.chezmoiscripts/30-linux/run_onchange_after_selinux-policies.sh.tmpl` ran `restorecon -RFv "$HOME/.claude"`, it relabelled **inodes**, not paths. Claude Code installs plugins using Bun, and Bun populates `node_modules` with **hardlinks** into the shared global cache at `~/.bun/install/cache/`. Because hardlinked files share the same inode, the recursive relabel stamped `claude_config_t` onto thousands of inodes in `~/.bun/install/cache/` and unrelated project trees.

Subsequent `bun install` or `mise install` invocations running in `unconfined_t` failed with `EACCES` when attempting to link or write to those cached package files:

```
type=AVC msg=audit(...): avc: denied { link } for pid=... comm="bun.native"
  name="package.json" dev="dm-0" ino=246909
  scontext=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
  tcontext=unconfined_u:object_r:claude_config_t:s0 tclass=file permissive=0
```

### The Fix

1. **Shrink the protected surface to exact config and manifest boundaries**:
   - `claude_config_t`: `~/.claude.json*`, `~/.mcp.json`, `~/.claude/settings.json`, `~/.claude/skills`, `~/.claude/plugins/installed_plugins.json`, `~/.claude/plugins/known_marketplaces.json`, `~/.claude/plugins/marketplaces/**`.
   - `gemini_config_t`: `~/.gemini/config/**`, `~/.gemini/skills`.
   - Non-config trees (`plugins/cache`, `plugins/data`, `sessions`, `projects`, `history.jsonl`, `daemon*`, `backups`, `~/.gemini/antigravity-cli/**`) default to `user_home_t`.
2. **Relabel only narrow paths**: Pass discrete paths to `restorecon` in the apply script; never pass `$HOME/.claude` or `$HOME/.gemini` recursively.
3. **Retire the tokscale exception module (`dotfiles_tokscale_gemini_access.cil`)**: With `~/.gemini/antigravity-cli` on `user_home_t`, `tokscale` runs as an ordinary `unconfined_t` utility and accesses Antigravity's conversation SQLite store without requiring write permissions on `gemini_config_t`, eliminating previous excess trust over `~/.gemini/config/mcp_config.json`.

## The fifth surprise: narrowing the policy repairs no inode, and only `chezmoi_t` can (2026-09-02)

Shrinking the `filecon` set removes the cause of the hardlink leak. It removes none of the damage. A SELinux label lives on the **inode**, so every file the old recursive `restorecon` stamped keeps `claude_config_t` after the new policy is installed, no matter which path it is reached through.

The obvious repair does not work:

```
$ restorecon -RF ~/.bun/install/cache
restorecon: Could not set context for /home/h82/.bun/install/cache/...:  Permission denied
```

`restorecon` needs `relabelfrom` on the type it is LEAVING. The protected types deliberately carry no base attribute, so the only rule that grants `relabelfrom` on them is the module's own `allow chezmoi_t protected_agent_config_type ...`. No unconfined domain holds it, and `sudo` does not help because a login shell's `sudo` stays `unconfined_t`. `rm -rf` fails for the same reason: `unlink` is checked against the file's type, and the protected types grant it to `chezmoi_t` and to the owning harness only. A `rm -rf ~/.bun/install/cache` from a login shell therefore deletes the correctly labelled majority and leaves exactly the mislabelled files behind.

Measured on host MS-7D91 after the narrowing landed: 8,467 stranded files in `~/.bun/install/cache`, 974 in `~/.claude`, and 614 in project `node_modules` trees.

### The Fix

The apply script gained a reclaim sweep, because `chezmoi_t` is the only domain that can run it:

```sh
find "$HOME" -xdev \
  \( -context '*:protected_agent_config_t:*' \
  -o -context '*:claude_config_t:*' \
  -o -context '*:gemini_config_t:*' \) -print0 |
  xargs -0 -r -n 200 restorecon -Fiv
```

The sweep can only LOWER a label. It selects paths that ALREADY carry a protected type and asks `restorecon` for the policy default, so a path the module still claims is a no-op and every stale one drops back to `user_home_t`. It never walks a cache root looking for files to protect, which is what makes it safe where `restorecon -RF "$HOME/.claude"` was not. A full `$HOME` walk costs about 6 seconds, and the script runs only when the policy changes.

The caches themselves are refetchable, so dropping them is the faster route for a host that has one of them stranded — but only a domain with `unlink` on the protected type can do it. Inside a Claude Code session (`claude_t`) `rm -rf ~/.claude/plugins/cache ~/.bun/install/cache` succeeds; from a login shell it does not.

## Prevention

- **Never protect package manager caches**: Package caches (like `node_modules` in plugin directories) use hardlinks into machine-wide caches. Placing a cache under a protected SELinux type leaks that type onto shared inodes during `restorecon`.
- **Narrow `filecon` specifications**: Protect only exact configuration files, skill symlinks/roots, and plugin manifest/marketplace trees. Let runtime cache, log, and session directories fall back to `user_home_t`.
- **Pass only discrete paths to `restorecon`**: Never pass whole-home harness directories (`$HOME/.claude`, `$HOME/.gemini`) recursively to `restorecon`.
- **Ship the repair with the narrowing**: A `filecon` change never moves an existing label. Plan a reclaim sweep run by the one domain that holds `relabelfrom` on the protected types, because no login shell and no `sudo` can clear a stale protected label.
- **Never add a protected config type to `file_type`**: Doing so silently removes confinement because `unconfined_t` can write all `file_type` objects.
- **Maintain upgrade-durability named transitions**: When entrypoint binaries reside in versioned paths, named file transitions (`typetransition chezmoi_t gconf_home_t file "claude" claude_exec_t`) ensure newly installed binaries inherit the entrypoint type at creation time before `restorecon` runs.
- **Verify policy compilation and boundaries in CI**: `.ci/test-selinux-protected-configs.sh` asserts the absence of whole-tree `filecon` and `restorecon` entries, compiles CIL modules with `secilc`, and tests the write matrix with `setools`.

## Related Issues

- Plan: `docs/plans/2026-08-31-1258-feat-selinux-protected-agent-configs-plan.md`
- Plan: `docs/plans/2026-09-02-1124-feat-manage-claude-antigravity-harnesses-selinux-protection-plan.md`
- Plan: `docs/plans/2026-09-02-1637-fix-selinux-narrow-protected-agent-configs-plan.md`
- Issue: https://github.com/hyperlapse122/dotfiles/issues/338
