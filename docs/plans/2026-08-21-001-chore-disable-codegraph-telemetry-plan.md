---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "chore: disable codegraph telemetry"
date: 2026-08-21
type: chore
depth: lightweight
---

# chore: Disable codegraph telemetry

## Goal Capsule

- **Objective:** Add `CODEGRAPH_TELEMETRY=0` to the managed user development environment to opt out of anonymous usage tracking for the codegraph CLI and MCP server.
- **Authority:** User request to disable tracking for codegraph tool. Repository environment conventions established in `dot_config/environment.d/60-development.conf`.
- **Execution profile:** One declarative user-environment change. No deployed home-directory edits and no runtime binary modification.
- **Stop conditions:** Stop if the environment variable name or value deviates from codegraph's supported `CODEGRAPH_TELEMETRY=0` contract, or if `environment.d` syntax is invalid.
- **Tail ownership:** The caller owns commit, push, pull request, and CI handling after implementation and review.

## Product Contract

### Summary

Declare `CODEGRAPH_TELEMETRY=0` in `dot_config/environment.d/60-development.conf` so that all user processes, developer shells, and MCP server invocations of `codegraph` run with telemetry disabled.

### Problem Frame

The repository provisions `codegraph` as a managed external CLI and MCP server. By default, `codegraph` enables anonymous usage tracking unless opted out via config or environment variable. Adding `CODEGRAPH_TELEMETRY=0` to the user development environment declaratively disables telemetry across all sessions and agent MCP invocations.

### Requirements

- R1. Add a `CODEGRAPH_TELEMETRY=0` assignment under a `# codegraph` comment block to `dot_config/environment.d/60-development.conf`.
- R2. Keep the change declarative, credential-free, and consistent with sibling opt-outs in `dot_config/environment.d/60-development.conf` (e.g. `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `TURBO_TELEMETRY_DISABLED=1`).
- R3. Preserve Linux-only deployment through the existing `dot_config/.chezmoiignore` gate without adding platform-specific shell scripts.
- R4. Verify that `codegraph telemetry status` reports telemetry as disabled when `CODEGRAPH_TELEMETRY=0` is exported in the environment.

### Scope Boundaries

**In scope:** Adding the environment declaration to `dot_config/environment.d/60-development.conf` and validating syntax and CLI recognition.

**Out of scope:** Modifying `.chezmoidata/agents.yaml`, changing `.chezmoiexternals/ai-agents.toml`, editing deployed `$HOME` files, or running runtime service restarts.

### Dependencies

- `dot_config/environment.d/60-development.conf` — existing development environment file.
- `dot_config/.chezmoiignore` — Linux-only deployment gate for `environment.d`.
- `codegraph` CLI installed at `~/.local/bin/codegraph` supporting the `CODEGRAPH_TELEMETRY` environment variable.

## Planning Contract

### Key Technical Decisions

- KTD1. **Use `dot_config/environment.d/60-development.conf`.** This file is the single source of truth for developer-tool environment variables and telemetry opt-outs in user systemd sessions.
- KTD2. **Use value `0`.** Codegraph's CLI explicitly recognizes `CODEGRAPH_TELEMETRY=0` to disable telemetry (matching `Telemetry: disabled (CODEGRAPH_TELEMETRY environment variable)`).
- KTD3. **No MCP config changes needed.** Stdio MCP servers inherit the parent process's environment; setting it in `environment.d` covers user sessions, shells, and agent processes uniformly.

### High-Level Technical Design

Add the environment assignment `CODEGRAPH_TELEMETRY=0` to `dot_config/environment.d/60-development.conf`. When systemd loads environment generators on session startup, all spawned processes and user shells inherit `CODEGRAPH_TELEMETRY=0`.

### Assumptions

- `systemd-environment-d-generator` parses `KEY=VALUE` assignments from `~/.config/environment.d/*.conf`.
- Subprocesses spawned within the user session inherit the generated environment.

### Sequencing

1. Update `dot_config/environment.d/60-development.conf` with the `# codegraph` header and `CODEGRAPH_TELEMETRY=0` assignment.
2. Verify template rendering and syntax.
3. Smoke-test `codegraph telemetry status` with `CODEGRAPH_TELEMETRY=0`.

### Sources and Research

- `dot_config/environment.d/60-development.conf` — current tool environment declarations.
- `codegraph telemetry status` CLI output verifying `CODEGRAPH_TELEMETRY` behavior.

## Implementation Units

### U1. Add `CODEGRAPH_TELEMETRY=0` to `60-development.conf`

- **Goal:** Declare `CODEGRAPH_TELEMETRY=0` in the managed developer environment.
- **Requirements:** R1, R2, R3, R4; KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `dot_config/environment.d/60-development.conf` (modify).
- **Approach:** Add `# codegraph` comment and `CODEGRAPH_TELEMETRY=0` assignment to `dot_config/environment.d/60-development.conf`.
- **Test scenarios:**
  - `dot_config/environment.d/60-development.conf` contains `CODEGRAPH_TELEMETRY=0`.
  - Syntax is valid `KEY=VALUE` with no shell commands or spaces around `=`.
  - `CODEGRAPH_TELEMETRY=0 codegraph telemetry status` outputs `Telemetry: disabled (CODEGRAPH_TELEMETRY environment variable)`.
- **Verification:** Inspect file diff and test with CLI subprocess.

## Verification Contract

| Check | Scope | Pass signal |
| --- | --- | --- |
| Syntax verification | `dot_config/environment.d/60-development.conf` | Valid `KEY=VALUE` format without template errors or shell syntax. |
| CLI verification | `codegraph telemetry status` | Reports `Telemetry: disabled (CODEGRAPH_TELEMETRY environment variable)` when `CODEGRAPH_TELEMETRY=0` is set. |
| Repo hygiene | Git worktree | `git diff --check` passes cleanly; no secrets or deployed files modified. |

## Definition of Done

- `dot_config/environment.d/60-development.conf` contains `CODEGRAPH_TELEMETRY=0`.
- Plan and verification contract are fully satisfied.
- No unrelated files or secrets are touched.
