# agents/

Cross-tool agent rules **and shared slash commands / prompts** shared by multiple AI coding assistants (OpenCode, Codex, etc.).

The source files in this directory are symlinked into each tool's global paths so every assistant on this machine reads the same rules and exposes the same commands.

## Contents

| File / dir | Purpose |
|---|---|
| `SHARED_AGENTS.md` | Tool-agnostic agent rules — branch naming, conventional commits, PR/MR contracts, CI/CD monitoring, Figma policy, scripting runtime, JavaScript package-manager hardening, etc. |
| `commands/` | Tool-agnostic slash commands / prompts. One `<name>.md` per command — exposed as `/<name>` in both OpenCode (`~/.config/opencode/commands/<name>.md`) and Codex (`~/.codex/prompts/<name>.md`). |
| `AGENTS.md` | Agent-facing rules for editing files in **this** directory. |
| `README.md` | This file. |

## Linkage

[`../install.conf.yaml`](../install.conf.yaml) defines explicit symlinks for both the shared rules file and the shared commands directory:

| Source in repo | Tool | Symlink target |
|---|---|---|
| `agents/SHARED_AGENTS.md` | OpenCode | `~/.config/opencode/AGENTS.md` |
| `agents/SHARED_AGENTS.md` | Codex | `~/.codex/AGENTS.md` |
| `agents/commands/` | OpenCode | `~/.config/opencode/commands` |
| `agents/commands/` | Codex | `~/.codex/prompts` |

Each target points at a single source. Edit `SHARED_AGENTS.md` or any file under `commands/` once; every linked tool sees the change immediately (symlinks resolve live; no re-run of dotbot needed unless the link itself is missing).

> **Note.** The OpenCode glob link for `home/.config/opencode/` is intentionally narrowed to `*.{json,jsonc}` so a stray `commands/` subdir under `home/` cannot collide with the explicit `~/.config/opencode/commands → agents/commands` link. Put new slash commands in `agents/commands/`, never under `home/.config/opencode/commands/`.

## When To Edit Here vs. Project-Level AGENTS.md

| Scope | Goes in |
|---|---|
| Rule applies in **every** repo on this machine | `SHARED_AGENTS.md` |
| Slash command / prompt usable from **every** repo on this machine | `commands/<name>.md` |
| Rule or command is **specific to one repo** | That repo's project-level `AGENTS.md` or `.opencode/commands/` |
| Tool-specific override (only OpenCode, only Codex, ...) | A separate file in this directory, linked individually from `../install.conf.yaml` |

`SHARED_AGENTS.md` itself states: project-level `AGENTS.md` files **override** these rules when they conflict. Project-level commands likewise shadow shared ones with the same name.

## Adding A New Command

1. Drop `commands/<name>.md` into this directory. The file body is tool-agnostic markdown; OpenCode-style frontmatter (`name`, `description`) is allowed and ignored by Codex.
2. That's it — `commands/` is already linked into OpenCode and Codex, so no `install.conf.yaml` change and no dotbot re-run are needed.
3. The command is exposed as `/<name>` in both OpenCode (`~/.config/opencode/commands/<name>.md`) and Codex (`~/.codex/prompts/<name>.md`).

## Adding A New Tool

1. Add new explicit `link:` entries in [`../install.conf.yaml`](../install.conf.yaml) pointing the new tool's AGENTS.md path at `agents/SHARED_AGENTS.md` and its command/prompt directory at `agents/commands` (or, if the rules/commands diverge, at new tool-specific files in this directory).
2. Re-run `./install.sh` / `.\install.ps1` to materialize the symlinks.
3. Document the new mappings in the **Linkage** table above.

## Don't Put Here

- Project-specific rules or commands — those belong in the owning repo's `AGENTS.md` or `.opencode/commands/`.
- Secrets, API keys, machine-specific paths — everything here is loaded as global agent context (or exposed as a global command) on every machine that links it.
- Generated content — these files are hand-authored; nothing should regenerate them.
- Tool-specific divergent copies of the same command — keep one tool-agnostic file in `commands/` and branch inline if needed.

See [`AGENTS.md`](./AGENTS.md) for editing conventions and [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
