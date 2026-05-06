# agents - OpenCode Skill Store

Runtime skill tree exposed at `~/.agents` by `home/modules/dev/agents.nix`. OpenCode and oh-my-openagent manage this directory at runtime.

## STRUCTURE

```plain
agents/
+-- AGENTS.md              # this scoped guide; hand-maintained
+-- .skill-lock.json       # managed lockfile; do not hand-edit
+-- skills/                # managed skill directories
    +-- find-skills/
    +-- glab/
    +-- playwright-cli/
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Understand active skills | `agents/skills/*/SKILL.md` | Read-only unless using the skill system. |
| Track installed versions | `agents/.skill-lock.json` | Managed artifact. |
| Change symlink behavior | `home/modules/dev/agents.nix` | Uses an out-of-store symlink so runtime writes work. |
| Add/update skills | OpenCode skill system | Do not hand-edit generated skill files. |

## CONVENTIONS

- This file is hand-maintained and must follow the repo-wide English-only rule.
- Skill directories and `.skill-lock.json` are managed artifacts. Their upstream language/content is allowed to differ from repo-authored docs.
- Keep the structure section high-level. The exact installed skill set can change at runtime.

## ANTI-PATTERNS

| Forbidden | Why |
|-----------|-----|
| Hand-edit `.skill-lock.json` | The skill manager owns version state. |
| Modify skill contents directly | Runtime updates can overwrite manual edits. |
| Add random files under `skills/` | The directory is reserved for skill packages. |
| Treat `agents/` as immutable Nix store content | It is intentionally writable through an out-of-store symlink. |
| Add non-English text to this file | Repo-authored tracked text must be English. |
