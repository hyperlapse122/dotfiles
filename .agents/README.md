# .agents/

Repo-local agent skills used while maintaining this dotfiles tree.

This directory is different from [`home/.agents/`](../home/.agents/): `.agents/` is tracked source in this repo, while `home/.agents/` is linked to `~/.agents` and managed at runtime by OpenCode / oh-my-openagent.

## Layout

```plain
.agents/
+-- skills/
    +-- archinstall-host/
        +-- SKILL.md
        +-- references/
```

## Current Skills

| Skill | Purpose |
|---|---|
| `archinstall-host` | Required workflow for creating, validating, and documenting a new `archinstall/<hostname>/` profile. It covers hardware inspection, archinstall schema regeneration, DMI metadata, and QEMU validation with UEFI Secure Boot, LUKS, and TPM2. |

## Conventions

- Keep repo-local skills here when they describe how to operate this repository.
- Keep user-installed or runtime-managed skills under `home/.agents/`, not here.
- Update [`../AGENTS.md`](../AGENTS.md) and the owning README when adding, removing, or changing a repo-local skill workflow.
