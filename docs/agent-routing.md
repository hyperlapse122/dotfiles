# Agent routing

The shared user-scope template renders one `# Orchestration` paragraph for Claude Code, OpenCode, and omp (`~/.omp/agent/AGENTS.md`): when work splits into several independent units, prefer dispatching Compound Engineering skills or subagents, and do small or tightly coupled edits directly. Only the Claude Code render adds a sentence that the `Workflow` tool and Ultracode need the user's own opt-in (the `ultracode` keyword, `/effort ultracode`, or an explicit request for a workflow); the instruction is not that opt-in, and `ultracode` is not declared in Claude Code's settings. The harness and host variables remain available to future content. Project instructions, independent harness settings, and shared skills remain active; Claude Code's own settings still select Korean conversation.

Delegation uses the role, model, and reasoning effort selected by CE or the harness unless the user specifies them.

Shared guidance is exposed through domain entries: `web-lenses`, `engineering-lenses`, `design-lenses`, `mobile-lenses`, `writing-lenses`, `service-lenses`, `platform-lenses`, and `toolchain-lenses`. `project-skills` discovers version-matched guidance supplied by installed project dependencies. Open the entry for the work and follow its references; grouped guides do not each occupy a user-scope discovery entry.

Shared Home Manager configuration installs [acpx](../packages/acpx.nix) on both NixOS and macOS. The package honors user-level `~/.acpx/config.json` and skips project-local `.acpxrc.json` when resolving configuration.

## Checking shared skill discovery

On Linux, fresh homes with the same harness binaries listed all 17 shared entries before grouping and all nine afterwards, once each. The counts exclude built-in and plugin skills. These checks used a non-project working directory and sent no model prompt.

| Harness | How to read the session's skill list |
| --- | --- |
| Claude Code 2.1.330 | Inspect the stream-JSON initialization response with user settings enabled. Bare mode skips user skills. |
| OpenCode 2.3.2 | Start a loopback server with temporary local authentication. Read `/api/skill` for the working directory, passing `location[directory]`. Use a bounded wait for the expected entries. The API can return HTTP 200 with only built-in entries while it is still loading directory skills. |

omp reads shared skills from its native user root, `~/.omp/agent/skills`, and ignores the Claude Code and OpenCode roots unless its `enabledProviders` setting turns them on, so each entry appears once. The counts above were not measured for omp.

Home Manager checks cover the managed skill roots and instruction delivery. The counts above come from standalone processes.

## Project skills for shadcn and Figma

Project-owned skills remain in their project's scope. For an Intent-compatible dependency, use `project-skills` to find guidance visible in the working project; absent or incompatible guidance falls back to a compatible installed reference or version-matched official documentation. Do not install dependencies or create project skills or instructions as part of discovery.

The following historical checks used synthetic project-owned skills and do not imply that this repository manages skills in other checkouts.

Disposable Git projects on macOS and NixOS confirmed the following with synthetic `shadcn` and `implement-design` skills.

| Harness | Project discovery |
| --- | --- |
| Pi 1.5.2 | Found both from a nested directory with `--approve`. With `--no-approve`, Pi skipped them. |
| OpenCode 2.3.2 | Found both from a nested directory. |
| Claude Code 2.1.329 | Found both through `.claude/skills/` directory links at the project root. |

## CE review peers

The shared `CROSS_MODEL_PEERS` list includes `claude` and `opencode` where those harnesses are installed. CE uses this list when selecting a peer for cross-model review.
