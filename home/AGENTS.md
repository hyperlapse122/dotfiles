# home/ Agent Instructions

This directory mirrors files that dotbot links into `$HOME`. The path under `home/` is the target path under the user's home directory.

## Runtime Agent Skill Tree

`home/.agents/` is linked to `~/.agents` by [`../install.conf.yaml`](../install.conf.yaml). OpenCode and oh-my-openagent manage the lockfile and installed skill packages there at runtime.

Do not add `home/.agents/AGENTS.md`. Files under `~/.agents` can be injected into every agent run from this user account, so scoped guidance for this repo belongs in this parent file instead.

## Where To Look

| Task | Location | Notes |
|------|----------|-------|
| Understand active runtime skills | `home/.agents/skills/*/SKILL.md` | Read-only unless using the skill system. |
| Track installed runtime skill versions | `home/.agents/.skill-lock.json` | Managed artifact. |
| Change `~/.agents` symlink behavior | `../install.conf.yaml` | Links `home/.agents` to `~/.agents`. |
| Add/update runtime skills | OpenCode skill system | Do not hand-edit generated skill files. |
| Change cross-tool global agent rules | `../agents/SHARED_AGENTS.md` | Linked into `~/.config/opencode/AGENTS.md` and `~/.codex/AGENTS.md` from `../install.conf.yaml`. Do not place a literal `AGENTS.md` inside `home/.config/opencode/`. |

## Conventions

- Keep runtime skill package contents and `.skill-lock.json` managed by the skill manager.
- Do not hand-edit generated files under `home/.agents/skills/`.
- Keep `home/.agents/` high-level documentation outside that directory to avoid global injection.
- Project-level `AGENTS.md` files override global OpenCode rules when they conflict.
- Repo-authored tracked text must be English.

## Anti-Patterns

| Forbidden | Why |
|-----------|-----|
| Add `home/.agents/AGENTS.md` | It is linked into `~/.agents` and can be injected into every agent run. |
| Add `home/.config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` is already an explicit symlink to [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md); a sibling source would conflict. Edit the shared file. |
| Hand-edit `home/.agents/.skill-lock.json` | The skill manager owns version state. |
| Modify skill contents directly | Runtime updates can overwrite manual edits. |
| Add random files under `home/.agents/skills/` | The directory is reserved for skill packages. |
| Treat `home/.agents/` as immutable generated config | It is intentionally writable runtime state linked from this repo. |
