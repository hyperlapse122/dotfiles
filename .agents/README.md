# .agents/

Repo-local agent skills used while maintaining this dotfiles tree.

This directory is different from [`home/.agents/`](../home/.agents/): `.agents/` is tracked source in this repo, while `home/.agents/` is linked to `~/.agents` and managed at runtime by OpenCode / oh-my-openagent.

## Layout

```plain
.agents/
+-- skills/
    +-- (no skills currently tracked)
```

## Current Skills

None. The directory is reserved for future repo-local skills.

## Conventions

- Keep repo-local skills here when they describe how to operate this repository.
- Keep user-installed or runtime-managed skills under `home/.agents/`, not here.
- Update [`../AGENTS.md`](../AGENTS.md) and this README when adding, removing, or changing a repo-local skill workflow.
