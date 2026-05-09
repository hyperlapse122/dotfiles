# agents/ Agent Instructions

Files in this directory are **cross-tool agent rule files** linked into multiple AI assistants' global `AGENTS.md` paths. Editing any linked file here changes the global rules for every linked tool, on every machine running this dotfiles checkout.

> **Style**: Use [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords (**MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**) for directives. Match the tone and structure of `SHARED_AGENTS.md`.

## Linkage

`../install.conf.yaml` defines explicit symlinks for `SHARED_AGENTS.md`:

| Source | Linked to | Loaded by |
|---|---|---|
| `agents/SHARED_AGENTS.md` | `~/.config/opencode/AGENTS.md` | OpenCode (global) |
| `agents/SHARED_AGENTS.md` | `~/.codex/AGENTS.md` | Codex (global) |

The symlinks resolve live. Edits to `SHARED_AGENTS.md` take effect for every linked tool the next time that tool reads its AGENTS.md — no dotbot re-run needed unless the symlink itself is missing.

This file (`agents/AGENTS.md`) is **NOT** linked into any tool's global path. It is loaded only when an agent is editing files in this subdirectory of the repo.

## Where Things Go

| Task | Location |
|---|---|
| Add/change cross-tool agent rule | `SHARED_AGENTS.md` |
| Add a tool-specific rule file (only OpenCode, only Codex, ...) | New file in this directory + new explicit `link:` in `../install.conf.yaml` |
| Add support for a new AI tool | New `link:` entry in `../install.conf.yaml`, then update `README.md` linkage table |
| Add a project-specific rule | The owning repo's `AGENTS.md`, NOT here |

## Conventions

- **MUST** keep `SHARED_AGENTS.md` tool-agnostic. If a rule applies only to OpenCode (or only to Codex), put it in a separate file and link it individually.
- **MUST** add a matching row to `README.md`'s **Linkage** table whenever a new file in this directory is linked from `../install.conf.yaml`. Linkage and documentation drift in lockstep.
- **MUST** keep this file, `README.md`, and `SHARED_AGENTS.md` mutually consistent. Per the repo's root `AGENTS.md`, agent workflow rule changes update every relevant `AGENTS.md` in the same commit.
- **MUST NOT** put machine-specific paths, secrets, or per-host details in any file here. These files are loaded as global agent context on every machine that runs `install.sh` / `install.ps1`.
- **MUST NOT** put project-specific rules here. `SHARED_AGENTS.md` itself defers to project-level `AGENTS.md` when they conflict — keep that boundary clean.
- **MUST NOT** edit `~/.config/opencode/AGENTS.md` or `~/.codex/AGENTS.md` directly. Those are symlinks; edit the source `SHARED_AGENTS.md` here.
- **SHOULD** use RFC 2119 keywords for directives, matching the existing style of `SHARED_AGENTS.md`.
- **MUST** write all tracked text in English (consistent with the rest of the repo).

## Anti-Patterns

| Forbidden | Why |
|---|---|
| Machine-specific paths or secrets in `SHARED_AGENTS.md` | Loaded globally on every machine that links it. |
| Project-specific rules in `SHARED_AGENTS.md` | They belong in the owning repo's project-level `AGENTS.md`, which already overrides shared rules on conflict. |
| New file in this directory without a new `link:` in `../install.conf.yaml` | Untracked file with no consumer — clutter. |
| New `link:` in `../install.conf.yaml` without updating `README.md`'s **Linkage** table | Documentation drift. |
| Hand-editing `~/.config/opencode/AGENTS.md` or `~/.codex/AGENTS.md` | Those are symlinks; the change either fails or silently mutates `SHARED_AGENTS.md` through the link, depending on tool. Edit the source here. |
| Adding `home/.config/opencode/AGENTS.md` to make global OpenCode rules | `~/.config/opencode/AGENTS.md` is already an explicit symlink to `agents/SHARED_AGENTS.md`. A second source would conflict. Edit the shared file. |

See [`README.md`](./README.md) for the human-facing description and [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
