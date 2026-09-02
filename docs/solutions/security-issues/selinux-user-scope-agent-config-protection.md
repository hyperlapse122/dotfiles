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
| `claude_config_t` | `~/.claude.json*`, `~/.mcp.json`, `~/.claude/**` | `chezmoi_t`, `claude_t` |
| `gemini_config_t` | `~/.gemini/**` | `chezmoi_t`, `agy_t` |

A harness needs its own domain because it rewrites its own tree during ordinary use — session transcripts, plugin cache, the enabled-plugin set, OAuth credentials — so a chezmoi-only writer would break the tool the label protects. `~/.claude/skills` and `~/.gemini/skills` take their harness's type but resolve into `~/.agents/skills`, so the canonical skills root stays chezmoi-only through the symlink.

Domain transitions are granted from `unconfined_domain_type` rather than from one named source: these binaries are launched from a login shell, a chezmoi script, another agent, and IDE helpers, and a launcher with no transition rule is denied the exec outright rather than merely running unconfined. Entrypoints are labelled on the real files in the versioned command store (`~/.local/lib/commands/store/<tool>/<version>/<tool>`), because `~/.local/bin/<tool>` is a symlink and an exec label on a symlink never applies.

## The tokscale exception (2026-09-02)

After the split landed, `tokscale` — a token-usage meter installed through mise — began failing against `~/.gemini`:

```
avc: denied { write } for pid=70851 comm="tokscale" name="conversations"
  scontext=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
  tcontext=unconfined_u:object_r:gemini_config_t:s0 tclass=dir permissive=0
avc: denied { write } for pid=70851 comm="tokscale" name="…db-wal" … tclass=file
```

It opens Antigravity's SQLite conversation store at `~/.gemini/antigravity-cli/conversations/<uuid>.db`. SQLite in WAL mode writes the `-wal` and `-shm` sidecars and needs the containing directory writable **even when the caller only reads rows**, so the denials are the cost of reading that database, not of changing Antigravity's configuration.

The fix is a second module, `system/linux/selinux/dotfiles_tokscale_gemini_access.cil`, not an edit to the base module: installing it is the entire record of the exception and removing it revokes the access. It declares `tokscale_t`, joins the base module's `dotfiles_agent_domain` and `dotfiles_agent_exec` attributes so it keeps the same unconfined privileges the other domains keep, and grants write on `gemini_config_t` alone. `claude_config_t` and `protected_agent_config_t` stay read-only to it.

Two details decided the shape:

**The entrypoint is not where you would look first.** `~/.local/bin/tokscale` is a symlink to a chezmoi-deployed bash wrapper, which execs `mise exec`, which runs node, which execs the real ELF under `~/.local/share/mise/installs/npm-tokscale/<version>/…/bin/tokscale`. The ELF is the process the audit log names. Both the wrapper and the ELF carry the entrypoint label, so the domain is entered wherever the chain starts; mise and node have no transition of their own and simply inherit it.

**The grant is wider than the need.** `gemini_config_t` covers all of `~/.gemini`, so tokscale can now also write `~/.gemini/config/mcp_config.json` — an MCP server definition, and therefore a code-execution surface. Narrowing it would take a separate type for the conversations subtree; until that exists, the trust placed in tokscale is the trust placed in that file. This is recorded in the module header rather than left implicit.

## The third surprise: a `filecon` alone does not survive an upgrade

Writing the tokscale module exposed the same latent defect in the original three domains. Both the command store and the mise tree key their directories by version:

```
~/.local/lib/commands/store/claude/2.1.258/claude
~/.local/share/mise/installs/npm-tokscale/4.15.0/…/bin/tokscale
```

The `filecon` specs match any version, but a `filecon` only takes effect when `restorecon` runs — and the apply script runs `restorecon` when the **policy** changes, not when the harness does. An upgrade writes the binary into a directory that has never been relabelled, where it inherits the parent's type. The transition would not fire, and `claude`, `agy` or `tokscale` would drop back to `unconfined_t` with its own configuration now denied to it: the original bug, reintroduced silently by a routine version bump.

Named file transitions close it at creation time instead:

```
(typetransition chezmoi_t gconf_home_t file "claude" claude_exec_t)
(typetransition chezmoi_t gconf_home_t file "agy" agy_exec_t)
(typetransition chezmoi_t gconf_home_t file "tokscale" tokscale_exec_t)
(typetransition chezmoi_t data_home_t file "tokscale" tokscale_exec_t)
```

Only `chezmoi_t` creates these files, and only under the home types that hold `~/.local/lib` and `~/.local/share`, so the rule cannot capture an unrelated file that merely shares the name. CI asserts each one: dropping a transition fails the suite.

## Prevention

- Restart every agent session after a policy change, and never take `audit2allow`'s advice for these denials: a `unconfined_t` → `claude_config_t` write grant silently removes the whole boundary. Check the denial's scontext first — `unconfined_t` on an agent's own file means a stale process, not a missing rule.
- Replace `filesystem associate` explicitly whenever a type is made attribute-free, and assert it: a missing `associate` looks exactly like a successful apply.
- Never add a protected config type to `file_type` (or any other base-policy attribute). That is the one edit that silently turns the module back into a no-op; `.ci/test-selinux-protected-configs.sh` rejects it, and where `secilc` and `python3-setools` are available it also compiles the module against a stub carrying the blanket `files_unconfined_type` grant and asserts each writer/non-writer pair directly.
- Declare a broad `filecon` for a directory a harness owns end to end (`HOME_DIR/\.claude(/.*)?`) and targeted regexes for the flat files and shared roots. A file created inside a labelled directory inherits that directory's type, so the recursive spec is also what keeps new harness state protected.
- Ensure the read set is granted to `unconfined_domain_type` so scripts inside protected directories remain executable, watchable, and mappable.
- For credential-bearing templates (`~/.mcp.json`), prefix template names with `private_` (`private_readonly_dot_mcp.json.tmpl`) so POSIX mode is `0600` alongside SELinux confinement.
- When reconciling live settings files via shell scripts, create staging files inside the target directory (`$SETTINGS_DIR/.settings.XXXXXX`) with mode `0600` and invoke `restorecon -F` after rename to prevent temporary filesystem label stripping.
- Verify policy compilation with `secilc` in `.ci/test-selinux-protected-configs.sh` and validate skip behavior in `.ci/check-skip-declarations.sh`.

## Related Issues

- Plan: `docs/plans/2026-08-31-1258-feat-selinux-protected-agent-configs-plan.md`
- Plan: `docs/plans/2026-09-02-1124-feat-manage-claude-antigravity-harnesses-selinux-protection-plan.md`
