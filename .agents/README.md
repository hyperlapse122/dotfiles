# .agents/

Repo-local agent skills used while maintaining this dotfiles tree.

This directory is different from [`home/.agents/`](../home/.agents/): `.agents/` is tracked source in this repo, while `home/.agents/` is linked to `~/.agents` and managed at runtime by OpenCode / oh-my-openagent.

## Layout

```plain
.agents/
+-- skills/
    +-- galaxy-buds-le-audio/
        +-- SKILL.md
```

## Current Skills

| Skill | Purpose |
|---|---|
| `galaxy-buds-le-audio` | Pair Samsung Galaxy Buds 4 Pro for Bluetooth LE Audio (BAP/LC3) in stereo on this Fedora/BlueZ host: prerequisites (the repo's `system/linux/etc/bluetooth/main.conf` `Experimental`/`KernelExperimental` + controller CIS support), the coordinated-set (CSIS) pairing both earbuds need, the live `bluetoothctl`/tmux procedure that beats RPA rotation, and troubleshooting (mono/one-ear, A2DP-instead-of-LE, RPA rotation, CIS failures). |

## Conventions

- Keep repo-local skills here when they describe how to operate this repository.
- Keep user-installed or runtime-managed skills under `home/.agents/`, not here.
- Update [`../AGENTS.md`](../AGENTS.md) and this README when adding, removing, or changing a repo-local skill workflow.
