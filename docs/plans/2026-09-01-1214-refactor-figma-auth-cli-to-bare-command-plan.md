---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
title: "Refactor figma-auth CLI to Zero-Argument Bare Command"
created_at: 2026-09-01T12:14:00+09:00
---

## Goal Capsule

- **Objective:** Enable running `figma-auth` directly with zero arguments to perform Figma MCP OAuth authorization for `omp` and store the credential row in `~/.omp/agent/agent.db`, rejecting any passed positional arguments as usage errors.
- **Means:** Simplify `packages/figma-auth/src/cli.ts` to require `args.length === 0`, invoke `OmpStorage` by default, emit `Usage: figma-auth\n` on unexpected arguments, and update documentation. (KTD1)
- **Product authority:** This plan defines the CLI interface, argument validation, and documentation updates for `packages/figma-auth`.
- **Open blockers:** None.
- **Execution profile:** Small 2-unit refactor in TypeScript and Markdown; verified via `bun test` and repository linting.

---

## Product Contract

### Summary

Refactor `figma-auth` to execute the Figma MCP OAuth flow for `omp` when invoked with no arguments (`figma-auth`). Remove all legacy multi-harness target parsing and reject any passed arguments with a concise usage error and exit code 2. Update repository documentation and instructions to reference `figma-auth` without subcommands.

### Problem Frame

`figma-auth` previously supported multiple agent harnesses (`opencode`, `pi`, `antigravity`, `kimi`, `omp`). Since this repository exclusively uses `omp` as its managed agent harness, all other storage adapters have been removed, leaving `omp` as the sole surviving target. However, the CLI still requires passing the redundant `omp` positional argument (`figma-auth omp`). Invoking `figma-auth` with zero arguments currently fails with `Usage: figma-auth <omp>`. Removing the subcommand requirement streamlines developer experience and aligns the CLI with its single-harness reality.

### Key Decisions

- **Strict zero-argument execution.** (session-settled: user-directed — chosen over backward-compatible argument tolerance: strict zero-arg figma-auth CLI with any arguments rejected as usage error) Governs R1, R2, R3.
- **Clean success output.** (session-settled: user-directed — chosen over preserving 'for omp' suffix: emit 'Figma MCP credentials saved.\n' without redundant target mention) Governs R3.
- **Preserve existing SQLite schema and OAuth core.** The OAuth authentication flow with PKCE and dynamic client registration, as well as `OmpStorage` SQLite schema writing to `~/.omp/agent/agent.db`, remain unchanged. Governs R4.

### Requirements

**CLI Execution and Argument Handling**
- R1. Running `figma-auth` with zero arguments (`args.length === 0`) must initiate the Figma MCP OAuth flow for `omp` and commit credentials via `OmpStorage`.
- R2. Running `figma-auth` with any arguments (including legacy `omp`, flags, or unknown positional arguments) must write `Usage: figma-auth\n` to stderr and exit with status code 2 without starting the OAuth flow.
- R3. On successful authentication, the CLI must write `Figma MCP credentials saved.\n` to stdout and exit with status code 0.

**Core Flow and Documentation**
- R4. The underlying OAuth flow, PKCE exchange, dynamic client registration, and `~/.omp/agent/agent.db` storage transactions must remain functional and unchanged.
- R5. Repository documentation and agent instructions (`AGENTS.md`, `README.md`, `packages/README.md`) must update command examples from `figma-auth omp` to `figma-auth`.

### Scope Boundaries

- **In scope:** `packages/figma-auth/src/cli.ts`, `packages/figma-auth/test/cli.test.ts`, and repository documentation referencing `figma-auth omp`.
- **Out of scope:** Modifying `packages/figma-auth/src/oauth.ts`, `packages/figma-auth/src/storage/omp.ts`, or adding new flags and options.

### Acceptance Examples

- AE1. Covers R1, R3. When a user runs `figma-auth` with no arguments, the OAuth flow starts, `OmpStorage` commits the session, stdout prints `Figma MCP credentials saved.\n`, and the process exits with 0.
- AE2. Covers R2. When a user runs `figma-auth omp`, `figma-auth --help`, or `figma-auth unknown`, stderr prints `Usage: figma-auth\n`, no OAuth flow or storage write occurs, and the process exits with 2.
- AE3. Covers R1, R4. When the OAuth flow encounters an error or is aborted, stderr prints the error diagnostic, stdout prints nothing, and the process exits with 1.
- AE4. Covers R5. Search across documentation confirms all occurrences of `figma-auth omp` are replaced by `figma-auth`.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — Streamlined zero-argument CLI interface.** Remove `TARGETS`, `AuthTarget`, and `parseTarget` from `src/cli.ts`. In `runCli(args, options)`, assert `args.length === 0`. If `args.length > 0`, write `USAGE = "Usage: figma-auth\n"` to stderr and return 2.
- **KTD2 — Single-target adapter binding.** `CliOptions.run` signature simplifies to `(signal: AbortSignal) => Promise<void>`, defaulting to `runOAuthFlow({ adapter: new OmpStorage(), signal })`.
- **KTD3 — Updated documentation contract.** Synchronize all operator commands and instructions across `AGENTS.md`, `README.md`, and `packages/README.md` to `figma-auth`.

### High-Level Technical Design

```mermaid
flowchart TD
    Start["figma-auth entry (args)"] --> CheckArgs{"args.length === 0?"}
    CheckArgs -->|No (any arg passed)| PrintUsage["Write 'Usage: figma-auth' to stderr & exit 2"]
    CheckArgs -->|Yes| RunOAuth["runOAuthFlow(OmpStorage)"]
    RunOAuth -->|Success| PrintSuccess["Write 'Figma MCP credentials saved.' to stdout & exit 0"]
    RunOAuth -->|Failure| PrintError["Write diagnostic to stderr & exit 1"]
```

### Assumptions

- `packages/figma-auth/src/index.ts` passes `process.argv.slice(2)` directly to `runCli`.
- The build script `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl` and staging matrix remain valid without changes since the binary name and output path `figma-auth` are unchanged.

---

## Implementation Units

### U1. Simplify figma-auth CLI argument handling and tests

- **Goal:** Refactor `packages/figma-auth/src/cli.ts` to require 0 arguments and update `packages/figma-auth/test/cli.test.ts`.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** None
- **Files:**
  - `packages/figma-auth/src/cli.ts`
  - `packages/figma-auth/test/cli.test.ts`
- **Approach:**
  - Update `USAGE` to `Usage: figma-auth\n`.
  - Remove `TARGETS`, `AuthTarget`, `parseTarget`.
  - Change `CliOptions.run` signature to `(signal: AbortSignal) => Promise<void>`.
  - In `runCli`, check `if (args.length !== 0) { stderr.write(USAGE); return 2; }`.
  - On success, write `Figma MCP credentials saved.\n` to stdout and return 0.
  - In `test/cli.test.ts`, assert that passing any argument (including `["omp"]`, `["--help"]`, `["unknown"]`) returns 2 with `Usage: figma-auth\n`.
  - Assert that calling `runCli([])` returns 0 and prints `Figma MCP credentials saved.\n`.
- **Test Scenarios:**
  - Covers R1, R3 / AE1: `runCli([])` successfully executes `run` and outputs `Figma MCP credentials saved.\n`.
  - Covers R2 / AE2: `runCli(["omp"])`, `runCli(["--help"])`, `runCli(["foo", "bar"])` all write `Usage: figma-auth\n` to stderr and return 2 without calling `run`.
  - Covers R4 / AE3: `runCli([])` handles thrown error during `run`, writes error message to stderr, and returns 1.
- **Verification:** `mise -C packages/figma-auth exec -- vp test` passes.

### U2. Update repository documentation and instructions

- **Goal:** Update all documentation references from `figma-auth omp` to `figma-auth`.
- **Requirements:** R5
- **Dependencies:** U1
- **Files:**
  - `AGENTS.md`
  - `README.md`
  - `packages/README.md`
- **Approach:**
  - In `AGENTS.md`: Update `figma-auth omp` to `figma-auth`.
  - In `README.md`: Update `figma-auth omp` occurrences to `figma-auth`.
  - In `packages/README.md`: Update `figma-auth omp` occurrences to `figma-auth`.
- **Test Scenarios:**
  - Covers R5 / AE4: Grep for `figma-auth omp` across the entire repository to ensure zero matches remain.
- **Verification:** `git diff --check` is clean; grep returns zero occurrences of `figma-auth omp`.

---

## Verification Contract

| Check | Scope | Command / Criteria |
|---|---|---|
| Unit & Integration Tests | `packages/figma-auth` | `mise -C packages/figma-auth exec -- vp test` |
| Package Build & Typecheck | `packages/figma-auth` | `mise -C packages/figma-auth exec -- vp run build && mise -C packages/figma-auth exec -- vp run typecheck` |
| Documentation Accuracy | Workspace | Grep confirms zero `figma-auth omp` occurrences across docs and source |
| Diff Hygiene | Workspace | `git diff --check` passes cleanly |

---

## Definition of Done

- U1 is complete: `packages/figma-auth/src/cli.ts` only accepts zero arguments and `packages/figma-auth/test/cli.test.ts` passes with full coverage.
- U2 is complete: `AGENTS.md`, `README.md`, and `packages/README.md` are updated to reference `figma-auth`.
- All checks in the Verification Contract pass cleanly.
- No dead code, obsolete comments, or unmanaged test files remain.
