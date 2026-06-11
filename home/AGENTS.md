# home/ Agent Instructions

This directory is the chezmoi source root. chezmoi applies files from here into `$HOME` using `mise exec chezmoi@2.70.5 -- chezmoi apply`. The path encoding under `home/` determines the target path under the user's home directory.

> **Note.** The runtime skill tree no longer lives here. It moved to [`../agents/skills`](../agents/skills) (with [`../agents/.skill-lock.json`](../agents/.skill-lock.json)), linked into `~/.agents/skills` and `~/.claude/skills`. There is no `home/.agents/` anymore — see [`../agents/AGENTS.md`](../agents/AGENTS.md) for skill-tree rules.

## Where To Look

| Task | Location | Notes |
|------|----------|-------|
| Change cross-tool global agent rules | `../agents/SHARED_AGENTS.md` | Symlinked into `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, and `~/.claude/CLAUDE.md` by `scripts/bootstrap/link-repo-trees.sh`. Do not place a literal `AGENTS.md` inside `home/dot_config/opencode/`. |
| Add/change a shared slash command | `../agents/commands/` | Symlinked into `~/.config/opencode/commands` and `~/.codex/prompts` by `link-repo-trees.sh`. Do not place a `commands/` subdir inside `home/dot_config/opencode/`. |
| Add/update/remove a runtime skill | `../agents/skills/` | Hand-author a new skill, or run `npx skills` / `glab skills install`; check the source before editing an existing one. See [`../agents/AGENTS.md`](../agents/AGENTS.md). |
| Add an OpenCode JSON config file | `home/dot_config/opencode/*.{json,jsonc}` | Applied by chezmoi; top-level JSON config only. |

## Conventions

- Project-level `AGENTS.md` files override global agent rules when they conflict.
- Repo-authored tracked text must be English.

## Anti-Patterns

| Forbidden | Why |
|-----------|-----|
| Add `home/.config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` is already an explicit symlink to [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md); a sibling source would conflict. Edit the shared file. |
| Add `home/.config/opencode/commands/` | `~/.config/opencode/commands` is already an explicit symlink to [`../agents/commands`](../agents/commands); a sibling source would conflict. Put new commands in `agents/commands/`. |
| Recreate `home/.agents/` | The runtime skill tree moved to [`../agents/skills`](../agents/skills); do not reintroduce a `home/.agents/` source. |

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
