# agents/

Cross-tool agent rules shared by multiple AI coding assistants (OpenCode, Codex, etc.).

The single source file in this directory is symlinked into each tool's global `AGENTS.md` path so every assistant on this machine reads the same rules.

## Contents

| File | Purpose |
|---|---|
| `SHARED_AGENTS.md` | Tool-agnostic agent rules — branch naming, conventional commits, PR/MR contracts, Figma policy, scripting runtime, JavaScript package-manager hardening, etc. |
| `AGENTS.md` | Agent-facing rules for editing files in **this** directory. |
| `README.md` | This file. |

## Linkage

[`../install.conf.yaml`](../install.conf.yaml) defines explicit symlinks for `SHARED_AGENTS.md`:

| Source in repo | Tool | Symlink target |
|---|---|---|
| `agents/SHARED_AGENTS.md` | OpenCode | `~/.config/opencode/AGENTS.md` |
| `agents/SHARED_AGENTS.md` | Codex | `~/.codex/AGENTS.md` |

Both targets point to the same file. Edit `SHARED_AGENTS.md` once; every linked tool sees the change immediately (symlinks resolve live; no re-run of dotbot needed unless the link itself is missing).

## When To Edit Here vs. Project-Level AGENTS.md

| Scope | Goes in |
|---|---|
| Rule applies in **every** repo on this machine | `SHARED_AGENTS.md` |
| Rule is **specific to one repo** | That repo's project-level `AGENTS.md` |
| Tool-specific override (only OpenCode, only Codex, ...) | A separate file in this directory, linked individually from `../install.conf.yaml` |

`SHARED_AGENTS.md` itself states: project-level `AGENTS.md` files **override** these rules when they conflict.

## Adding A New Tool

1. Add a new explicit `link:` entry in [`../install.conf.yaml`](../install.conf.yaml) pointing the new tool's AGENTS.md path at `agents/SHARED_AGENTS.md` (or, if the rules diverge, at a new tool-specific file in this directory).
2. Re-run `./install.sh` / `.\install.ps1` to materialize the symlink.
3. Document the new mapping in the **Linkage** table above.

## Don't Put Here

- Project-specific rules — those belong in the owning repo's `AGENTS.md`.
- Secrets, API keys, machine-specific paths — `SHARED_AGENTS.md` is loaded as global agent context on every machine that links it.
- Generated content — these files are hand-authored; nothing should regenerate them.

See [`AGENTS.md`](./AGENTS.md) for editing conventions and [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
