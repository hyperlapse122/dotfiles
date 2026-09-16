---
title: Deterministic Garden Worktree Trust Seeding - Plan
type: refactor
date: 2026-09-16
topic: deterministic-garden-worktree-trust
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** Eliminate recursive filesystem crawling and disk I/O during routine Chezmoi applies and worktree creation, asserting project trust across managed agent harnesses in under 50ms with zero Python runtime dependency.
- **Means:** Port trust reconciliation into `packages/settings-reconcile` as `settings-reconcile trust`, discovering checkouts in O(1) time from `dot_config/garden/garden.yaml` and single-level `~/.local/share/worktrees/*` directory scans, while providing a backward-compatible `agent-trust-reconcile` CLI alias.
- **Product Authority:** `github.com/hyperlapse122/dotfiles`
- **Open Blockers:** None

---

## Product Contract

Product Contract preservation: Product Contract unchanged.

### Summary

Deterministic Garden Worktree Trust Seeding replaces the unconstrained recursive `os.walk` in `agent-trust-reconcile` with a native TypeScript subcommand in `packages/settings-reconcile`. Instead of walking thousands of directories across `~/src` on every apply, the tool reads `dot_config/garden/garden.yaml` in O(1) time to identify registered repository checkouts, pairs it with a flat, single-depth enumeration of `~/.local/share/worktrees/*`, and additively asserts trust into `~/.claude.json` and `~/.codex/config.toml` in under 50ms. Existing callsites (`run_after_trust-agent-worktrees.sh.tmpl`, the `orca-ide` CLI wrapper, and automated CI test suites) remain 100% backward-compatible via a lightweight `agent-trust-reconcile` CLI alias.

### Problem Frame

Currently, `.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl` executes `agent-trust-reconcile --all` on every single apply. The legacy Python implementation crawls `~/src` recursively searching for `.git` directories. With large monorepos, deeply nested directories, and dependency build trees (`node_modules`, `target`, `.venv`), this recursive walk performs thousands of redundant `getdents` and `stat` syscalls, introducing 3–5 seconds of disk thrashing on every apply.

Furthermore, `agent-trust-reconcile` is an orphaned Python script in `dot_local/share/chezmoi-command-sources/` that shells out to `settings-reconcile` anyway to modify TOML. Consolidating trust management into `settings-reconcile` removes the Python runtime overhead, unifies all agent configuration assertions in a single compiled TypeScript engine, and leverages the fact that `garden.yaml` already authoritatively declares checkout locations under `~/src`.

### Key Decisions

- KTD1. Native `settings-reconcile trust` Subcommand `(session-settled: user-approved — chosen over Python script refactor: unifies all agent configuration logic under packages/settings-reconcile, eliminates Python startup overhead, and operates in pure compiled TypeScript)`. Governs R1, R2, R3.
- KTD2. Garden-Authoritative Discovery for `~/src` `(session-settled: user-directed — chosen over recursive filesystem crawling: reads dot_config/garden/garden.yaml in O(1) time for ~/src checkouts, avoiding disk traversal over large codebases)`. Governs R4, R5.
- KTD3. Single-Depth Flat Worktree Scan `(session-settled: user-approved — chosen over git worktree list subshells: enumerates immediate directory entries in ~/.local/share/worktrees/* in a single readdir pass without spawning external git processes)`. Governs R4, R5.
- KTD4. 100% Backward-Compatible CLI Alias `(session-settled: user-approved — chosen over breaking script renames: maintains ~/.local/bin/agent-trust-reconcile as an alias or symlink to settings-reconcile trust so orca-ide worktree interception and existing test fixtures function without disruption)`. Governs R6, R7.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This refactor upgrades the trust seeding mechanism introduced in the initial workspace trust deployment (`docs/plans/2026-09-12-2022-feat-trust-agent-worktrees-plan.md`) and directly builds upon the multi-harness declarative settings engine (`packages/settings-reconcile`). Surrounding areas:

- `packages/settings-reconcile` — Provides the native TypeScript parsing and atomic assertion foundation for Codex (`config.toml`) and Claude Code (`~/.claude.json`).
- `dot_local/share/chezmoi-command-sources/executable_orca-ide` — Continues intercepting `worktree create` and invoking `agent-trust-reconcile <path>`, seamlessly routed to `settings-reconcile trust <path>`.
- `.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl` — Executes `agent-trust-reconcile --all` after garden reconciliation on every apply, benefiting from the sub-50ms execution speed.

### Requirements

#### Native Subcommand & Parsing
- R1. `packages/settings-reconcile` must provide a `trust` subcommand: `settings-reconcile trust [paths...] [--all] [--verbose]`.
- R2. `settings-reconcile trust` must additively assert trust in `~/.claude.json` (`projects.<path>.hasTrustDialogAccepted = true`) using atomic file replacement with `0600` permissions, preserving all unrelated keys and projects.
- R3. `settings-reconcile trust` must additively assert trust in `~/.codex/config.toml` (`[projects."<path>"] trust_level = "trusted"`) using the internal TOML reconciliation engine, preserving all unrelated tables, comments, and project entries.

#### Discovery Strategy
- R4. In `--all` mode (or when no explicit paths are supplied), `settings-reconcile trust` must parse `~/.config/garden/garden.yaml` (overridable via `GARDEN_CONFIG_FILE`) to discover declared repository checkout paths under `~/src` in O(1) time without recursive filesystem traversal.
- R5. In `--all` mode, `settings-reconcile trust` must perform a flat, single-depth scan of `~/.local/share/worktrees` (overridable via `WORKTREES_DIR`), identifying immediate child directories containing a `.git` file or directory.
- R6. Explicit paths passed as CLI arguments (`settings-reconcile trust <path>`) must be normalized, validated, and trusted directly without requiring a garden entry or filesystem scan.

#### Backward Compatibility & Verification
- R7. An `agent-trust-reconcile` executable link or wrapper in `~/.local/bin` must forward directly to `settings-reconcile trust`, preserving compatibility for `orca-ide worktree create` and existing shell scripts.
- R8. `.ci/test-agent-trust-reconcile.sh` must verify `settings-reconcile trust` directly, maintaining all existing trust preservation, permission (`0600`), and idempotency assertions.

### Key Flows

- F1. Apply-time global trust reconciliation (`chezmoi apply`)
  - **Trigger:** `run_after_trust-agent-worktrees.sh.tmpl` executes during phase 90.
  - **Actors:** Chezmoi runner, `settings-reconcile trust`.
  - **Steps:** `settings-reconcile trust --all` parses `garden.yaml`, lists immediate `worktrees/*`, compares with `~/.claude.json` and `~/.codex/config.toml`, writes atomic updates only if new checkouts exist, and completes in <50ms.
  - **Covered by:** R1, R2, R3, R4, R5.
- F2. Worktree creation interception (`orca-ide worktree create`)
  - **Trigger:** Developer or automation runs `orca-ide worktree create --name <slug>`.
  - **Actors:** `orca-ide` wrapper script, `agent-trust-reconcile` alias.
  - **Steps:** Wrapper intercepts successful creation, extracts worktree path, invokes `agent-trust-reconcile <path>`, which calls `settings-reconcile trust <path>` to immediately seed trust for the new worktree without scanning the filesystem.
  - **Covered by:** R6, R7.
- F3. Ad-hoc explicit path trust
  - **Trigger:** Developer passes custom path `agent-trust-reconcile ~/custom/repo`.
  - **Actors:** Developer, `settings-reconcile trust`.
  - **Steps:** Path is resolved and added directly to Claude Code and Codex trust configurations.
  - **Covered by:** R6.

### Acceptance Examples

- AE1. Steady-state apply execution time
  - **Given:** A workstation with 50+ checkouts in `~/src` and 5 active worktrees in `~/.local/share/worktrees`.
  - **When:** `settings-reconcile trust --all` runs.
  - **Then:** Execution completes in under 50ms with zero recursive directory traversal.
- AE2. Configuration preservation & permissions
  - **Given:** An existing `~/.claude.json` with user tokens and `~/.codex/config.toml` with custom MCP servers and plugins.
  - **When:** `settings-reconcile trust <path>` executes.
  - **Then:** New project trust entries are added with `0600` permissions while comments, formatting, and unrelated configuration keys survive.

### Scope Boundaries

- **In scope:** `packages/settings-reconcile` trust command implementation, `garden.yaml` parser, flat worktree scanner, `commands.yaml` unit updates for `agent-trust-reconcile`, and `.ci/test-agent-trust-reconcile.sh` validation.
- **Out of scope:** Modifying oh-my-pi trust policies (omp already unconditionally trusts all workspaces), modifying Orca IDE binary internals, daemonized background trust monitoring.

### Outstanding Questions

None (all architectural decisions settled during brainstorming dialogue).

---

## Planning Contract

### High-Level Technical Design

The refactor introduces a native `trust` subcommand to the `@h82/settings-reconcile` package, retiring the standalone Python script while keeping its public CLI contract.

```text
                               +------------------------------------+
                               |  Invocation:                       |
                               |  settings-reconcile trust [--all]  |
                               +-----------------+------------------+
                                                 |
                         +-----------------------+-----------------------+
                         |                                               |
                Explicit Paths?                                       --all / No args?
                         |                                               |
             [normalize & resolve]                             +---------+---------+
                         |                                     |                   |
                         |                             Parse garden.yaml    Scan worktrees/*
                         |                             (O(1) manifest)     (single-depth dir)
                         |                                     |                   |
                         +-----------------------+-------------+-------------------+
                                                 |
                                     Target Checkouts List
                                                 |
                         +-----------------------+-----------------------+
                         |                                               |
              Reconcile Claude                                Reconcile Codex
             (~/.claude.json)                               (~/.codex/config.toml)
                         |                                               |
         Parse JSON -> Set Flag                         Parse TOML via smol-toml
      (hasTrustDialogAccepted=true)                   ([projects."<path>"].trust_level)
                         |                                               |
        Atomic Temp Write (0600)                        Atomic Temp Write (0600)
```

### Key Technical Decisions

- KTD1. Port into `@h82/settings-reconcile` instead of maintaining separate Python script: removes dual-runtime maintenance (Python vs TypeScript) and executes directly in the compiled Bun/Node runtime.
- KTD2. Read `~/.config/garden/garden.yaml` directly: avoids executing `garden ls` subshells, parsing text output in milliseconds.
- KTD3. Single-depth scan of `~/.local/share/worktrees`: worktrees in Orca are flat or 2-level directories (`<name>` or `<project>/<name>`); scanning immediate children and checking for `.git` takes <5ms.
- KTD4. Forwarding wrapper `agent-trust-reconcile`: replaces the 252-line Python script with a fast 15-line shell wrapper that invokes `settings-reconcile trust "$@"` to ensure 100% zero-regression backward compatibility.

### System-Wide Impact

- **Performance:** `run_after_trust-agent-worktrees.sh.tmpl` run time drops from ~3,500ms to <40ms during `chezmoi apply`.
- **Dependencies:** Removes Python runtime requirement for agent trust reconciliation.
- **File Safety:** Claude and Codex configuration files continue to be written atomically with `0600` permissions.

---

## Implementation Units

### U1. Implement Garden & Worktree Discovery in `packages/settings-reconcile`

- **Goal:** Implement fast, zero-crawl checkout discovery in TypeScript.
- **Requirements:** R4, R5, R6.
- **Files:**
  - `packages/settings-reconcile/src/discovery.ts` (create)
  - `packages/settings-reconcile/test/discovery.test.ts` (create)
- **Approach:**
  1. Create `discovery.ts` exporting `discoverCheckouts(options)`.
  2. Implement `parseGardenManifest(filePath, srcRoot)`: read `garden.yaml`, extract `garden.root` (default `~/src`), parse `trees` map, resolve absolute path for each tree.
  3. Implement `scanWorktrees(worktreesDir)`: read entries of `worktreesDir`, identify directories containing `.git` (file or dir), handle 1-level or 2-level nesting without full subtree recursion.
  4. Return unique, sorted absolute path strings.
- **Patterns to follow:** `packages/settings-reconcile/src/reconcile.ts` error handling and path resolution helpers.
- **Test scenarios:**
  - Happy path: parses mock `garden.yaml` and extracts declared paths matching `srcRoot/<path>`.
  - Happy path: scans mock `worktrees` directory containing single-depth worktrees with `.git` files.
  - Edge case: missing `garden.yaml` or missing worktree directory gracefully falls back to empty list without crashing.
  - Edge case: explicit paths pass through normalized without filesystem search.
- **Verification:** Unit tests in `packages/settings-reconcile/test/discovery.test.ts` pass with 100% assertion coverage.

### U2. Implement Multi-Harness Trust Assertion in `packages/settings-reconcile`

- **Goal:** Implement additive, atomic trust assertions for Claude Code and Codex in TypeScript.
- **Requirements:** R2, R3.
- **Files:**
  - `packages/settings-reconcile/src/trust.ts` (create)
  - `packages/settings-reconcile/test/trust.test.ts` (create)
- **Approach:**
  1. Create `reconcileClaudeTrust(claudeJsonPath, targetPaths)`: read JSON, ensure `projects` map exists, set `hasTrustDialogAccepted = true` for each path, write atomically with `0600` permissions only if modified.
  2. Create `reconcileCodexTrust(codexHome, codexConfigPath, targetPaths)`: use existing `reconcileSettings` overlay logic to assert `[projects."<path>"].trust_level = "trusted"` in `config.toml`.
  3. Ensure all writes preserve comments, unrelated tables/keys, and handle missing config files gracefully.
- **Patterns to follow:** `packages/settings-reconcile/src/reconcile.ts` atomicWrite and overlay mechanics.
- **Test scenarios:**
  - Happy path: adds trust to clean/missing `claude.json` and `config.toml` with `0600` file permissions.
  - Happy path: idempotency — re-running with already-trusted paths results in zero file mutations.
  - Edge case: preserves unrelated keys, custom MCP server declarations, and foreign projects.
- **Verification:** `bun test packages/settings-reconcile/test/trust.test.ts` passes cleanly.

### U3. Expose `trust` Subcommand in `packages/settings-reconcile/src/cli.ts`

- **Goal:** Wire discovery and trust reconciliation into the `settings-reconcile` CLI entrypoint.
- **Requirements:** R1, R6.
- **Files:**
  - `packages/settings-reconcile/src/cli.ts` (modify)
- **Approach:**
  1. Update `cli.ts` to accept `trust` subcommand: `settings-reconcile trust [paths...] [--all] [--verbose]`.
  2. Read environment overrides: `CLAUDE_CONFIG_FILE`, `CODEX_HOME`, `CODEX_CONFIG_FILE`, `GARDEN_CONFIG_FILE`, `SRC_DIR`, `WORKTREES_DIR`.
  3. Invoke discovery and trust reconciliation, returning exit code 0 on success.
- **Patterns to follow:** `packages/settings-reconcile/src/cli.ts` argument dispatch.
- **Test scenarios:**
  - Invoking `settings-reconcile trust --all` executes discovery and reconciliation.
  - Invoking `settings-reconcile trust /path/to/repo` targets explicit path directly.
- **Verification:** CLI invocations via `bun run src/cli.ts trust ...` succeed in integration tests.

### U4. Replace Legacy Python Script with Fast Forwarding Wrapper

- **Goal:** Replace `executable_agent-trust-reconcile` with a forwarding wrapper to maintain 100% backward compatibility for all existing callers.
- **Requirements:** R7.
- **Files:**
  - `dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile` (modify)
- **Approach:**
  1. Replace the 252-line Python script with a shell script wrapper.
  2. Resolve `settings-reconcile` from `$RECONCILER`, `~/.local/bin/settings-reconcile`, or `command -v settings-reconcile`.
  3. Exec `"$reconciler" trust "$@"` with original arguments.
- **Patterns to follow:** `dot_local/share/chezmoi-command-sources/executable_orca-ide` binary discovery pattern.
- **Test scenarios:**
  - Invoking `agent-trust-reconcile --all` forwards cleanly to `settings-reconcile trust --all`.
  - Invoking `agent-trust-reconcile <path>` forwards explicit arguments verbatim.
- **Verification:** Calling `dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile` executes `settings-reconcile trust`.

### U5. Update CI Test Suite & Regression Verification

- **Goal:** Update `.ci/test-agent-trust-reconcile.sh` to test `settings-reconcile trust` and the forwarder.
- **Requirements:** R8.
- **Files:**
  - `.ci/test-agent-trust-reconcile.sh` (modify)
- **Approach:**
  1. Update `.ci/test-agent-trust-reconcile.sh` to test both direct `settings-reconcile trust` invocations and the `agent-trust-reconcile` wrapper.
  2. Verify that mock repositories with `.git` and mock `garden.yaml` paths are correctly discovered and trusted.
  3. Verify permission checks (`0600`), idempotency, and `orca-ide worktree create` interception.
- **Test scenarios:**
  - All test cases in `.ci/test-agent-trust-reconcile.sh` pass cleanly in scratch environment.
- **Verification:** Running `.ci/test-agent-trust-reconcile.sh` succeeds with zero errors.

---

## Verification Contract

1. **Unit Test Suite:**
   - Run `vp test` inside `packages/settings-reconcile/` to verify discovery, trust reconciliation, and CLI handling.
2. **Integration Test Gate:**
   - Run `.ci/test-agent-trust-reconcile.sh` in throwaway scratch environment; verify all 6 assertion groups pass.
3. **Execution Time Proof:**
   - Benchmark `settings-reconcile trust --all` execution time; assert execution finishes in <50ms.

---

## Definition of Done

1. `packages/settings-reconcile` provides `settings-reconcile trust` with discovery and trust assertion logic.
2. `dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile` forwards to `settings-reconcile trust`.
3. All existing callsites (`run_after_trust-agent-worktrees.sh.tmpl`, `orca-ide` wrapper) function identically without modification.
4. `.ci/test-agent-trust-reconcile.sh` and package unit tests pass with green exit code.
