# agents/ Agent Instructions

Files in this directory are **cross-tool agent rule files and shared slash commands** linked into multiple AI assistants' global paths. Editing any linked file here changes the global rules or commands for every linked tool, on every machine running this dotfiles checkout.

> **Style**: Use [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords (**MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**) for directives. Match the tone and structure of `SHARED_AGENTS.md`.

## Linkage

`../install.conf.yaml` defines explicit symlinks for both the shared rules file and the shared commands directory:

| Source | Linked to | Loaded by |
|---|---|---|
| `agents/SHARED_AGENTS.md` | `~/.config/opencode/AGENTS.md` | OpenCode (global rules) |
| `agents/SHARED_AGENTS.md` | `~/.codex/AGENTS.md` | Codex (global rules) |
| `agents/commands/` | `~/.config/opencode/commands` | OpenCode (slash commands) |
| `agents/commands/` | `~/.codex/prompts` | Codex (prompts) |

The symlinks resolve live. Edits to `SHARED_AGENTS.md` or any file under `commands/` take effect for every linked tool the next time that tool reads them — no dotbot re-run needed unless the symlink itself is missing.

This file (`agents/AGENTS.md`) is **NOT** linked into any tool's global path. It is loaded only when an agent is editing files in this subdirectory of the repo.

## Where Things Go

| Task | Location |
|---|---|
| Add/change cross-tool agent rule | `SHARED_AGENTS.md` |
| Add/change a shared slash command or prompt | New `<name>.md` file in `commands/` (no wiring needed — the directory is already linked) |
| Add a tool-specific rule file (only OpenCode, only Codex, ...) | New file in this directory + new explicit `link:` in `../install.conf.yaml` |
| Add support for a new AI tool | New `link:` entries in `../install.conf.yaml` (rules and/or commands), then update `README.md` linkage table |
| Add a project-specific rule | The owning repo's `AGENTS.md`, NOT here |

## Commands

Files in `commands/` are tool-agnostic markdown — each file is one slash command in OpenCode and one prompt in Codex. They are exposed at:

- OpenCode: `/<name>` (loaded from `~/.config/opencode/commands/<name>.md`)
- Codex: `/<name>` (loaded from `~/.codex/prompts/<name>.md`)

OpenCode-style frontmatter (`name`, `description`) is allowed and ignored by Codex. Keep command bodies tool-agnostic so the same file serves both surfaces; gate any tool-specific guidance inline rather than shipping divergent copies.

## Conventions

- **MUST** keep `SHARED_AGENTS.md` and files under `commands/` tool-agnostic. If guidance applies only to OpenCode (or only to Codex), put it in a separate file and link it individually.
- **MUST** add a matching row to `README.md`'s **Linkage** table whenever a new file or directory in this tree is linked from `../install.conf.yaml`. Linkage and documentation drift in lockstep.
- **MUST** keep this file, `README.md`, and `SHARED_AGENTS.md` mutually consistent. Per the repo's root `AGENTS.md`, agent workflow rule changes update every relevant `AGENTS.md` in the same commit.
- **MUST NOT** put machine-specific paths, secrets, or per-host details in any file here. These files are loaded as global agent context on every machine that runs `install.sh` / `install.ps1`.
- **MUST NOT** put project-specific rules or commands here. `SHARED_AGENTS.md` itself defers to project-level `AGENTS.md` when they conflict — keep that boundary clean.
- **MUST NOT** edit `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/commands/*`, or `~/.codex/prompts/*` directly. Those are symlinks; edit the source files in `agents/` here.
- **SHOULD** use RFC 2119 keywords for directives, matching the existing style of `SHARED_AGENTS.md`.
- **MUST** write all tracked text in English (consistent with the rest of the repo).

## Anti-Patterns

| Forbidden | Why |
|---|---|
| Machine-specific paths or secrets in `SHARED_AGENTS.md` or `commands/*` | Loaded globally on every machine that links them. |
| Project-specific rules or commands in this directory | They belong in the owning repo's project-level `AGENTS.md` or `.opencode/commands/`, which already override shared rules/commands on conflict. |
| New rule file in this directory without a new `link:` in `../install.conf.yaml` | Untracked file with no consumer — clutter. Commands are the exception: `commands/` is already linked as a whole, so new files there need no extra wiring. |
| New `link:` in `../install.conf.yaml` without updating `README.md`'s **Linkage** table | Documentation drift. |
| Hand-editing `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/commands/*`, or `~/.codex/prompts/*` | Those are symlinks into `agents/`; the change either fails or silently mutates the source through the link, depending on tool. Edit the source here. |
| Adding `home/.config/opencode/AGENTS.md` to make global OpenCode rules | `~/.config/opencode/AGENTS.md` is already an explicit symlink to `agents/SHARED_AGENTS.md`. A second source would conflict. Edit the shared file. |
| Adding `home/.config/opencode/commands/` | `~/.config/opencode/commands` is already an explicit symlink to `agents/commands`. A sibling source would conflict. Put new commands in `agents/commands/`. |
| Tool-specific divergent copy of the same command (e.g. one file for OpenCode, one for Codex) | Both surfaces share `commands/`. Keep one tool-agnostic file; branch inline if needed. |

See [`README.md`](./README.md) for the human-facing description and [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
