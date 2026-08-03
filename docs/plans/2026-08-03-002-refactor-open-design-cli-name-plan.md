---
title: Rename Open Design CLI entry point
date: 2026-08-03
topic: open-design-cli-name
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Goal Capsule

Rename the managed Open Design CLI command from `od` to `open-design` without colliding with the existing graphical launcher, and keep MCP startup and desktop launch behavior unchanged.

## Problem Frame

`dot_local/bin/executable_od` deploys the guarded Open Design CLI as `~/.local/bin/od`. The requested name is `open-design`, but that target is already owned by `dot_local/bin/executable_open-design`, the graphical desktop launcher. A clean cutover must move the graphical launcher to a distinct target, update all managed references, and preserve both entry points' existing behavior.

## Requirements

- R1. The guarded CLI deploys as `~/.local/bin/open-design` and no longer deploys `~/.local/bin/od`.
- R2. The graphical launcher remains available under a distinct, explicit command name and its desktop entry invokes that name.
- R3. The Open Design MCP record invokes `open-design mcp` on eligible Linux non-container hosts.
- R4. Activation, environment, stdio, argument, signal, stderr, and exit behavior remain unchanged for the CLI.
- R5. Existing isolated Open Design tests and rendered MCP assertions cover the renamed paths and command.

## Scope Boundary

Included: source executable names, the desktop launcher's distinct target name, the desktop entry command, MCP data, ignore rules, activation/integration test references, and related test assertions.

Excluded: Open Design service/provisioning logic, upstream CLI internals, release versions, desktop behavior, and unrelated agent configuration.

## Existing Patterns

- `dot_local/bin/executable_od` is the guarded CLI wrapper.
- `dot_local/bin/executable_open-design` is the GUI launcher used by `dot_local/share/applications/open-design.desktop.tmpl`.
- `.ci/test-open-design-activation.sh` copies and exercises the CLI wrapper in an isolated home.
- `.ci/test-open-design-desktop.sh` verifies the GUI launcher and desktop `Exec` path.
- `.ci/test-open-design-mcp-render.sh` asserts rendered neutral MCP records.
- `.chezmoiignore` gates both Open Design command targets by host eligibility.

## Key Technical Decisions

1. **Use `open-design` for the guarded CLI and `open-design-desktop` for the GUI launcher.** Chosen over replacing the GUI target or retaining `od`: the requested CLI name must be available, while the existing desktop workflow must remain usable and source targets must remain unique.
2. **Perform a clean reference migration with no compatibility alias.** Chosen over keeping an `od` shim: the request is a rename, and the MCP record plus tests can migrate together without retaining obsolete surface area.

## Implementation Units

### U1 — Rename managed executable targets and references

- **Files:** `dot_local/bin/executable_od` -> `dot_local/bin/executable_open-design`; `dot_local/bin/executable_open-design` -> `dot_local/bin/executable_open-design-desktop`; `.chezmoiignore`; `.chezmoidata/agents.yaml`; `dot_local/share/applications/open-design.desktop.tmpl`.
- **Approach:** Move the CLI wrapper to the `open-design` target. Move the graphical wrapper to `open-design-desktop`. Change the desktop entry's `Exec` field to the new graphical target. Change the MCP command from `od` to `open-design`; update ignore entries so both target names remain gated and `od` is removed.
- **Test scenarios:**
  1. Source targets are unique and deploy to `~/.local/bin/open-design` and `~/.local/bin/open-design-desktop`.
  2. The desktop entry renders `Exec=%h/.local/bin/open-design-desktop`.
  3. No managed source or data reference retains the obsolete CLI target or command.

### U2 — Update isolated verification harnesses

- **Files:** `.ci/test-open-design-activation.sh`; `.ci/test-open-design-desktop.sh`; `.ci/test-open-design-integration.sh`; `.ci/test-open-design-mcp-render.sh`.
- **Approach:** Point shell syntax checks and wrapper defaults at the renamed source paths. Exercise the CLI under the `open-design` filename while preserving all activation and MCP stdio assertions. Update desktop test copy/launch paths and rendered `Exec` assertion. Update MCP render expectations to `command == "open-design"`.
- **Test scenarios:**
  1. The activation suite passes with the renamed CLI wrapper and still proves MCP startup and environment forwarding.
  2. The desktop suite passes with the renamed GUI launcher and exact desktop `Exec` value.
  3. The MCP render suite emits exactly one eligible Open Design record with `open-design` and `mcp`, and omits it on ineligible hosts.
  4. The full isolated integration script passes without live chezmoi apply, service startup, or real Open Design clone/build.

## Dependencies and Sequence

U1 must land before U2 because test defaults and source paths depend on the final names. No external dependency changes are required.

## Verification Contract

- `bash .ci/test-open-design-integration.sh` — exercises provisioning-independent shell, activation, desktop, MCP rendering, and unit checks in isolated scratch state.
- `chezmoi --config <scratch>/empty.toml --source "$PWD" execute-template < dot_local/share/applications/open-design.desktop.tmpl` — confirm the rendered desktop command uses `open-design-desktop`.
- `git diff --check` — no whitespace errors.
- `git status --short` and a scope-limited diff review — only the plan and requested rename/reference/test files are changed.

## Definition of Done

Both managed commands render under unique names, MCP invokes `open-design mcp`, the desktop entry still launches the GUI through `open-design-desktop`, the isolated Open Design integration suite passes, and no obsolete `od` command/target reference remains in managed source or tests.

## Risks and Mitigations

- **Target collision:** resolved by giving the GUI launcher the explicit `open-design-desktop` target before assigning `open-design` to the CLI.
- **Stale test or ignore reference:** mitigated by updating all known source/test references and running the integration suite plus a final repository search.
