# agents/

Cross-tool agent rules, **shared slash commands / prompts, and the runtime skill tree** shared by multiple AI coding assistants (OpenCode, Codex, Claude Code, etc.).

The source files in this directory are symlinked into each tool's global paths so every assistant on this machine reads the same rules, exposes the same commands, and loads the same skills.

## Contents

| File / dir | Purpose |
|---|---|
| `SHARED_AGENTS.md` | Tool-agnostic agent rules — the **lean always-loaded core**: guardrails (secrets, destructive ops, git config), the branch-prefix gate, one-line commit / CI/CD / Figma / scripting / package-manager rules, and a **routing index** pointing at the on-demand skills below. Detailed playbooks live in `skills/`, not here. |
| `commands/` | Tool-agnostic slash commands / prompts. One `<name>.md` per command — exposed as `/<name>` in both OpenCode (`~/.config/opencode/commands/<name>.md`) and Codex (`~/.codex/prompts/<name>.md`). |
| `skills/` | Runtime skill tree (one package per subdir). A **mix of CLI-managed and hand-authored** skills — you may add or edit a skill by hand, but check the source first (see below). CLI-managed: `find-skills`, `playwright-cli` (`npx skills`), `glab` (`glab skills install`). Hand-authored rule-skills extracted from the core: `git-workflow`, `pr-mr`, `gitlab-issues`, `ci-cd-monitoring`, `js-package-managers` (see **Core rules + extracted skills** below). Linked into `~/.agents/skills` (OpenCode) and `~/.claude/skills` (Claude Code); CLI-managed skills are also synced to Codex and the other agents in `.skill-lock.json`'s `lastSelectedAgents` when `npx skills` runs. |
| `.skill-lock.json` | `skills` CLI (`npx skills`) lockfile tracking installed skill versions and the agents to distribute to (`lastSelectedAgents`: `codex`, `cursor`, `opencode`, …). **CLI-owned — don't hand-edit.** Linked into `~/.agents/.skill-lock.json`. The `glab` skill is **not** listed here — it is installed separately via `glab skills install`. |
| `AGENTS.md` | Agent-facing rules for editing files in **this** directory. |
| `README.md` | This file. |

## Linkage

[`../install.conf.yaml`](../install.conf.yaml) defines explicit symlinks for the shared rules file, the shared commands directory, and the runtime skill tree:

| Source in repo | Tool | Symlink target |
|---|---|---|
| `agents/SHARED_AGENTS.md` | OpenCode | `~/.config/opencode/AGENTS.md` |
| `agents/SHARED_AGENTS.md` | Codex | `~/.codex/AGENTS.md` |
| `agents/SHARED_AGENTS.md` | Claude Code | `~/.claude/CLAUDE.md` |
| `agents/commands/` | OpenCode | `~/.config/opencode/commands` |
| `agents/commands/` | Codex | `~/.codex/prompts` |
| `agents/skills/` | OpenCode | `~/.agents/skills` |
| `agents/skills/` | Claude Code | `~/.claude/skills` |
| `agents/.skill-lock.json` | OpenCode | `~/.agents/.skill-lock.json` |

Each target points at a single source. Edit `SHARED_AGENTS.md` or any file under `commands/` once; every linked tool sees the change immediately (symlinks resolve live; no re-run of dotbot needed unless the link itself is missing).

> **Note — Codex.** Codex scans skills from several scopes, including the **USER** scope `$HOME/.agents/skills`, and [**follows symlinked skill folders**](https://developers.openai.com/codex/skills#where-to-save-skills). Because `~/.agents/skills` is the existing whole-dir symlink to `agents/skills/` (the same one OpenCode reads), Codex discovers **every** skill in this tree automatically — hand-authored and CLI-managed alike — with no per-skill links and no `~/.codex/skills` wiring. (`npx skills` may separately copy CLI-managed skills into `~/.codex/skills`; that path is redundant for discovery and does not affect the hand-authored rule-skills.)

> **Note — editing skills.** You MAY add or edit a skill under `skills/` by hand (create `skills/<name>/SKILL.md`), but **check the source first**: a skill tracked in `.skill-lock.json` (installed via `npx skills`) or the `glab` skill (`glab skills install`) is CLI-managed and a hand edit is overwritten on the next CLI run — prefer the CLI for those. Skills not tracked by any CLI are hand-authored and safe to edit. `.skill-lock.json` itself is CLI-owned — don't hand-edit it. See [`AGENTS.md`](./AGENTS.md).

> **Note — authoring on implicit requests.** When the user **implicitly** asks for functionality that doesn't yet exist — "I wish there were a skill for X", "can you always do Y this way", or any repeated workflow worth capturing — hand-author a new skill directly (`skills/<name>/SKILL.md`); don't wait for an explicit "install a skill" instruction. First confirm no CLI-managed skill already covers it (check `.skill-lock.json` and the `glab` skill); if none does, create the hand-authored skill. It is visible to all three tools the moment the file exists — no `install.conf.yaml` change or dotbot re-run needed.

> **Note.** The OpenCode glob link for `home/.config/opencode/` is intentionally narrowed to `*.{json,jsonc}` so a stray `commands/` subdir under `home/` cannot collide with the explicit `~/.config/opencode/commands → agents/commands` link. Put new slash commands in `agents/commands/`, never under `home/.config/opencode/commands/`.

## Core rules + extracted skills

`SHARED_AGENTS.md` is split by **loading condition**, not by size:

- **Core (`SHARED_AGENTS.md`, always loaded, ≤120 lines)** — every rule that must hold on
  *every* task, or that gates an early action: all guardrails (secrets, destructive/bypass
  ops, never-touch git config), the branch-prefix gate, one-line Conventional-Commits /
  CI/CD / Figma / tmux / Playwright-host / scripting / package-manager rules, and the
  **Routing Index** mapping each operation to the skill to load before doing it.
- **Skills (`skills/<name>/`, loaded on demand)** — the exhaustive playbooks behind those
  one-liners. Each is a directory with a `SKILL.md` (frontmatter + procedure + must-know
  traps) and a `references/` subtree (long tables, templates, command transcripts pulled
  only when needed):

  | Skill | Fires when you… |
  |---|---|
  | `git-workflow` | name/rename a branch, write a commit, or resolve a rebase |
  | `pr-mr` | create or manage a PR/MR (**core forces this load before any create call**) |
  | `gitlab-issues` | read/create issues, tasks, work items, labels, uploads, descriptions |
  | `ci-cd-monitoring` | monitor or fix a CI/CD pipeline |
  | `js-package-managers` | edit deps, override lifecycle scripts, or handle the cooldown gate |

These five are **hand-authored** (not in `.skill-lock.json`, not `glab`-installed), so a
hand edit here is safe and is **not** overwritten by any CLI.

### Per-agent discovery of the extracted skills

| Agent | Reads | Sees the extracted skills? |
|---|---|---|
| OpenCode | `~/.agents/skills` ← `agents/skills/` | ✅ automatically via the existing symlink |
| Claude Code | `~/.claude/skills` ← `agents/skills/` | ✅ automatically via the existing symlink |
| Codex | `~/.agents/skills` (USER scope) ← `agents/skills/` | ✅ automatically — Codex scans the USER-scope `~/.agents/skills` and follows the symlink to `agents/skills/`, so it sees the same tree OpenCode does |

Guardrails are **never** placed in a skill — a guardrail that loads only when a description
happens to match could fail open exactly when it is needed. All guardrails stay in the
always-loaded core.

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
- Hand-edits to `.skill-lock.json`, or to a `skills/` package that the `skills` CLI / `glab skills install` manages — those get overwritten on the next CLI run. Hand-authored skills (not tracked by any CLI) are fine to add and edit; check the source first.
- Tool-specific divergent copies of the same command — keep one tool-agnostic file in `commands/` and branch inline if needed.

See [`AGENTS.md`](./AGENTS.md) for editing conventions and [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
