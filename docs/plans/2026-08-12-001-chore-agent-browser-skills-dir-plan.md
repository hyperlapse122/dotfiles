---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "chore: configure agent-browser skills directory"
date: 2026-08-12
type: chore
depth: lightweight
---

# chore: Configure agent-browser skills directory

## Goal Capsule

- **Objective:** Make the managed `agent-browser` CLI find the skills installed by this chezmoi source state.
- **Authority:** The user request defines the outcome. Repository instructions define source ownership and Linux-only environment deployment. Existing agent-browser external and skill paths define the directory layout.
- **Execution profile:** One declarative user-environment change. No deployed home-directory edits and no browser session launch.
- **Stop conditions:** Stop if the environment value would point at a child skill directory, if the rendered assignment is not valid `environment.d` syntax, or if the CLI cannot resolve the managed skill path with the assignment applied.
- **Tail ownership:** The caller owns commit, push, pull request, and CI handling after implementation and review.

## Product Contract

### Summary

Set `AGENT_BROWSER_SKILLS_DIR` in the managed Linux user environment so `agent-browser skills` can discover the repository-managed skill tree.

### Problem Frame

The repository installs the standalone `agent-browser` binary at `~/.local/bin/agent-browser` and installs its discovery skill at `~/.agents/skills/agent-browser`. The binary currently reports `Skills directory not found` because a bare release binary cannot infer the separate chezmoi-managed skill tree. The CLI override must point to the parent directory that contains individual skill directories.

### Requirements

- R1. Add one `AGENT_BROWSER_SKILLS_DIR` assignment to the existing development environment source at `dot_config/environment.d/60-development.conf`.
- R2. Set the value to `${HOME}/.agents/skills`, the parent directory of the managed `agent-browser` skill and other user-scoped skills.
- R3. Preserve Linux-only deployment through the existing `dot_config/.chezmoiignore` gate. Do not add a Windows, macOS, shell-specific, or runtime script variant.
- R4. Keep the change credential-free and declarative. Do not install a second CLI, copy bundled skill files, or edit deployed `$HOME` paths.
- R5. With the assignment applied to a subprocess launched after the user environment is refreshed, `agent-browser skills path agent-browser` resolves to `${HOME}/.agents/skills/agent-browser`, and the CLI can read that managed discovery stub.

### Scope Boundaries

**In scope:** The environment assignment in `dot_config/environment.d/60-development.conf` and render/smoke verification of its value and CLI discovery behavior.

**Out of scope:** Changing the agent-browser external binary, changing `.chezmoidata/agents.yaml`, repackaging the CLI's bundled runtime skill data, browser installation, Chrome provisioning, live user-manager reload, already-running shell refresh, or deploying the change to the live home directory.

### Dependencies

- `.chezmoiexternals/ai-agents.toml` installs the standalone binary at `.local/bin/agent-browser`.
- `.chezmoiexternals/ai-agents.toml` installs external skills below `.agents/skills/<name>`.
- `dot_config/.chezmoiignore` keeps `dot_config/environment.d` on Linux and excludes it on non-Linux hosts.

## Planning Contract

### Key Technical Decisions

- KTD1. **Use the existing environment file.** Add the variable to `dot_config/environment.d/60-development.conf` because that file already owns developer-tool environment variables, and `environment.d` is the repository's user-service environment surface. A new file or shell startup export would create a second configuration path.
- KTD2. **Point at the skills parent.** Use `${HOME}/.agents/skills`, not `${HOME}/.agents/skills/agent-browser`, because agent-browser scans the configured directory's immediate child directories for `SKILL.md` files. The chezmoi external target is the `agent-browser` child directory.
- KTD3. **Use environment expansion.** Write `${HOME}/.agents/skills` instead of a user-specific absolute path. `systemd-environment-d-generator` supports `${VAR}` expansion, and this preserves portability across users and hosts.
- KTD4. **Do not add bundled skill data.** This request configures discovery of the managed discovery stub. The standalone release binary and the npm package have different packaging surfaces; changing that packaging would be a separate dependency and release-lock design.

### High-Level Technical Design

The existing Linux environment file will export the override. When a user service or a terminal launched through that service inherits the assignment, `agent-browser` will use the override directory instead of searching beside its executable. The CLI will discover `.agents/skills/agent-browser/SKILL.md` as a hidden discovery skill and resolve its path.
The systemd user manager applies changed environment generators after a daemon reload, and only subsequently started services inherit the new value. Existing shells are not retroactively changed.

### Assumptions

- The user's home directory is available as `HOME` when systemd parses user `environment.d` files.
- The managed skill external remains rooted at `.agents/skills/<name>`.
- The implementation verifies the rendered assignment and the CLI override in a subprocess. It does not claim to refresh an existing user manager or shell.

### Sequencing

1. Add the assignment beside the existing development-tool variables.
2. Render the file through chezmoi with a scratch destination and confirm the assignment is unchanged.
3. Run the installed CLI with the assignment in a subprocess and confirm the managed skill path resolves.
4. Run repository checks required for a source-state environment change.

### Sources and Research

- `dot_config/environment.d/60-development.conf` — existing development environment ownership.
- `dot_config/.chezmoiignore` — Linux-only deployment gate for `environment.d`.
- `.chezmoiexternals/ai-agents.toml` — binary target `.local/bin/agent-browser` and external skill target `.agents/skills/<name>`.
- `/vercel-labs/agent-browser` documentation and `cli/src/skills.rs` — `AGENT_BROWSER_SKILLS_DIR` override and direct-child skill discovery.

## Implementation Units

### U1. Configure agent-browser skill discovery

- **Goal:** Export the documented skills-directory override from the managed Linux user environment.
- **Requirements:** R1, R2, R3, R4, R5; KTD1–KTD3.
- **Dependencies:** None.
- **Files:** `dot_config/environment.d/60-development.conf` (modify).
- **Approach:** Add a short `agent-browser` comment and `AGENT_BROWSER_SKILLS_DIR=${HOME}/.agents/skills` assignment. Keep the existing file name and ordering. Do not add shell syntax or a second environment file.
- **Test scenarios:**
  - The source contains exactly one assignment with the parent skills directory value.
  - A scratch render keeps `${HOME}` as the environment expansion and produces valid `KEY=VALUE` syntax.
  - Running `agent-browser skills path agent-browser` with the explicit override value resolves to the installed skill directory.
  - Running `agent-browser skills get agent-browser` with the explicit override value reads the managed discovery stub without reporting `Skills directory not found`.
- **Verification:** Render the environment assignment separately, then pass its expected expanded value to the installed CLI in a subprocess. This isolates CLI discovery without deploying or mutating live `$HOME`.

## Verification Contract

| Check | Scope | Pass signal |
| --- | --- | --- |
| Render source file | Linux chezmoi source | `chezmoi execute-template` renders the file without template errors and preserves the assignment. |
| Static syntax | Rendered environment file | The assignment is a valid `KEY=VALUE` line with no shell command syntax. |
| CLI discovery | Current installed `agent-browser` binary plus managed skill tree | A subprocess with `AGENT_BROWSER_SKILLS_DIR="$HOME/.agents/skills"` returns `$HOME/.agents/skills/agent-browser` from `skills path` and exits successfully from `skills get agent-browser`. |
| Activation boundary | Rendered `environment.d` source | The assignment uses supported `KEY=VALUE` and `${HOME}` expansion syntax; live daemon reload and existing-shell refresh remain out of scope. |
| Repository hygiene | Changed source files | `git diff --check` passes; no deployed home file is modified. |

No unit test is added. This is a declarative environment change with a direct CLI smoke contract and no application code path.

## Definition of Done

- U1 is implemented in the existing source-owned environment file.
- The configured value resolves to the parent of the managed skill directory for the current user.
- The render and CLI discovery checks pass without deploying the source state.
- No unrelated files, credentials, generated targets, or runtime installers are changed.
- Abandoned experimental edits are removed from the final diff.
