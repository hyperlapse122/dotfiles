---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Plan: Silence Routine JSON Output in command-reconcile on Apply

## Goal Capsule

- **Objective:** Eliminate unwanted multi-line JSON output from `command-reconcile` during routine `chezmoi apply` executions while preserving structured JSON on demand and concise feedback on mutations/conflicts/errors.
- **Means:** Add an explicit `--json` flag to `packages/command-reconcile/src/cli.ts` for structured JSON output, make default execution silent on no-op / unchanged runs, and emit concise human-readable lines on activations, prunes, conflicts, and errors. (KTD1, KTD2)
- **Authority Hierarchy:** Product Contract (Issue #312) > Planning Contract > Implementation Units.
- **Stop Conditions:** All tests in `packages/command-reconcile` and integration tests in `.ci/` pass; default CLI invocation produces zero output when commands are unchanged; `--json` flag emits expected JSON structure; errors and conflicts write to `stderr` and return non-zero exit codes.
- **Execution Profile:** Direct TypeScript / CLI updates with unit and integration tests.
- **Tail Ownership:** `packages/command-reconcile/src/cli.ts`, `packages/command-reconcile/test/cli.test.ts`, `.ci/test-command-reconcile-apply.sh`.

## Product Contract

### Summary
`packages/command-reconcile/src/cli.ts` currently dumps full multi-line JSON objects to `stdout` on every run of `activate-unit` and `reconcile-all`. Because `run_after_90-activate-command-links.sh.tmpl` (phase 00) and `run_after_reconcile-commands.sh.tmpl` (phase 65) run on every `chezmoi apply`, this produces noisy output even when zero units change. This change defaults CLI execution to silent when unchanged, prints concise change/error summaries when mutations or issues occur, and provides a `--json` flag for machine-readable JSON output.

### Problem Frame
During every `chezmoi apply`, `command-reconcile` runs in phase 00 and phase 65. The unconditional `JSON.stringify(..., null, 2)` calls in `cli.ts` output dozens of lines of JSON describing unchanged units and empty arrays, cluttering apply scrollback and masking real diagnostic output.

### Requirements
- **R1:** The CLI MUST support a `--json` boolean flag for both `activate-unit` and `reconcile-all` subcommands.
- **R2:** When `--json` is provided, the CLI MUST output formatted JSON for `ActivationResult` or `ReconcileReport` to `stdout`, matching the previous JSON structure.
- **R3:** When `--json` is NOT provided (default):
  - `reconcile-all` MUST emit nothing to `stdout`/`stderr` when all units are unchanged and no units are pruned, failed, or in conflict.
  - `reconcile-all` MUST emit concise messages on `stdout` if units are activated (e.g. `command-reconcile: activated <id>`) or pruned (e.g. `command-reconcile: pruned <id>`).
  - `activate-unit` MUST emit nothing on `unchanged` or successful `activated` state (or concise message if needed, but silent on unchanged).
  - Any conflicts or failures MUST be reported concisely to `stderr` with non-zero exit codes.
- **R4:** Help / usage output (`--help`, `-h`) MUST document the `--json` flag.
- **R5:** Existing integration tests (`.ci/test-command-reconcile-apply.sh`, `.ci/test-command-reconcile-process.sh`) MUST remain functional and be updated where JSON assertions specifically test `--json`.

### Scope Boundaries
- **In Scope:**
  - Modifying `packages/command-reconcile/src/cli.ts` to parse `--json` and format default output.
  - Adding comprehensive unit tests for `cli.ts` in `packages/command-reconcile/test/cli.test.ts`.
  - Updating `.ci/test-command-reconcile-apply.sh` if necessary to verify both default silence and `--json` output.
- **Out of Scope:**
  - Modifying underlying reconciliation algorithms in `reconcile.ts`, `producer.ts`, `paths.ts`, or `state.ts`.
  - Modifying manifest schema or state contract `command-reconcile/v1`.

### Sources
- Issue #312: `https://github.com/hyperlapse122/dotfiles/issues/312`
- `packages/command-reconcile/src/cli.ts`
- `.chezmoiscripts/00-tools/run_after_90-activate-command-links.sh.tmpl`
- `.chezmoiscripts/65-commands/run_after_reconcile-commands.sh.tmpl`
- `.ci/test-command-reconcile-apply.sh`

## Planning Contract

### Key Technical Decisions
- **KTD1: Flag Parsing and CLI Contract.** Add `--json` to `cli.ts` argument loop. If present, set `jsonArg = true`. Default is `false`.
- **KTD2: Output Formatting Strategy.**
  - When `jsonArg === true`:
    - `activate-unit`: `process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);`
    - `reconcile-all`: `process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);`
  - When `jsonArg === false`:
    - `activate-unit`:
      - If `result.status === "failed"` or `result.status === "conflict"`: write error message to `process.stderr` (`command-reconcile: activate-unit failed: ${result.error ?? result.status}`).
      - If `result.status === "activated"`: write concise info to `process.stdout` (`command-reconcile: activated unit ${result.unitId}\n`) or stay silent on success. Per issue description: "For activate-unit: Emit nothing on unchanged / successful activations." -> emit nothing on success/unchanged.
      - Return `result.status === "failed" || result.status === "conflict" ? 1 : 0`.
    - `reconcile-all`:
      - If `report.activated.length > 0`: `process.stdout.write(`command-reconcile: activated ${report.activated.join(", ")}\n`);`
      - If `report.pruned.length > 0`: `process.stdout.write(`command-reconcile: pruned ${report.pruned.join(", ")}\n`);`
      - If `report.conflicts.length > 0`: for each conflict, write to `process.stderr` (`command-reconcile: conflict on ${c.id} at ${c.path}: ${c.reason}\n`).
      - If `report.failed.length > 0`: for each failure, write to `process.stderr` (`command-reconcile: error on ${f.id}: ${f.error}\n`).
      - If everything is unchanged/retained and no conflicts/errors: emit nothing.
      - Return `report.failed.length > 0 ? 1 : 0`.
- **KTD3: Clean separation of CLI I/O and Core Logic.** `cli.ts` handles all argument parsing and process streams (`stdout`, `stderr`). Core logic in `reconcile.ts` remains pure return types (`ActivationResult`, `ReconcileReport`).

### High-Level Technical Design

```
+-------------------------------------------------------------+
| CLI Invocation (command-reconcile activate-unit / reconcile) |
+-------------------------------------------------------------+
                               |
                               v
                     [Parse argv & --json]
                               |
                               v
                   [Execute withLease(...)]
                               |
        +----------------------+----------------------+
        |                                             |
   [--json=true]                                [--json=false]
        |                                             |
        v                                             v
  JSON.stringify                               [Check Results]
  to process.stdout                                   |
                               +----------------------+----------------------+
                               |                      |                      |
                         [Unchanged]             [Mutations]         [Conflicts/Errors]
                               |                      |                      |
                               v                      v                      v
                           (Silent)            Concise stdout         Concise stderr
                                              (activated/pruned)     (exit code 1 if failed)
```

## Implementation Units

### U1. Update `packages/command-reconcile/src/cli.ts`
- **Goal:** Implement `--json` flag and concise/silent default output in `cli.ts`.
- **Requirements:** R1, R2, R3, R4.
- **Files:** `packages/command-reconcile/src/cli.ts`.
- **Approach:**
  - Add `jsonArg` parsing in `main()`.
  - Update `printUsage()` to document `--json`.
  - Implement conditional reporting based on `jsonArg` for both `activate-unit` and `reconcile-all`.
  - Ensure stderr reporting on conflicts/errors and correct exit code handling.
- **Test Scenarios:**
  - `activate-unit` with `--json` outputs JSON matching `ActivationResult`.
  - `activate-unit` without `--json` outputs nothing on unchanged / success.
  - `reconcile-all` with `--json` outputs JSON matching `ReconcileReport`.
  - `reconcile-all` without `--json` outputs nothing when unchanged/retained.
  - `reconcile-all` without `--json` logs activated and pruned units concisely on stdout.
  - `reconcile-all` without `--json` logs conflicts and errors to stderr.
- **Verification:** `bun test packages/command-reconcile`.

### U2. Add Unit Tests for CLI Behavior
- **Goal:** Add comprehensive tests in `packages/command-reconcile/test/cli.test.ts` covering CLI arguments, silent mode, `--json` flag, error handling, and exit codes.
- **Requirements:** R1, R2, R3, R4.
- **Files:** `packages/command-reconcile/test/cli.test.ts`.
- **Approach:**
  - Test `main(argv)` with mocked `process.stdout.write` and `process.stderr.write` (or capturing streams) for various scenarios: help, missing args, `activate-unit` success/silent/json/error, and `reconcile-all` unchanged/activated/pruned/conflict/error/json.
- **Test Scenarios:**
  - `--help` writes usage and returns 1.
  - Missing `--manifest` writes error to stderr and returns 1.
  - `reconcile-all` unchanged emits nothing and returns 0.
  - `reconcile-all` with activations emits concise line.
  - `reconcile-all` with `--json` emits valid JSON.
  - `reconcile-all` with failure returns 1 and emits stderr.
- **Verification:** `bun test packages/command-reconcile`.

### U3. Update Integration Tests
- **Goal:** Verify and update `.ci/test-command-reconcile-apply.sh` to ensure it exercises both default silent execution and explicit `--json` flag.
- **Requirements:** R5.
- **Files:** `.ci/test-command-reconcile-apply.sh`.
- **Approach:**
  - Verify that the first run of `reconcile-all` outputs concise change summaries / conflicts.
  - Verify that a second run on an unchanged setup produces empty stdout.
  - Add a check for `--json` output structure.
- **Test Scenarios:**
  - First run displays expected concise output.
  - Second unchanged run produces zero output.
  - Run with `--json` produces structured JSON.
- **Verification:** Run `./.ci/test-command-reconcile-apply.sh` and `./.ci/test-command-reconcile-process.sh`.

## Verification Contract

- **V1:** Unit test suite: `bun test` in `packages/command-reconcile` (100% passing).
- **V2:** Apply integration test: `./.ci/test-command-reconcile-apply.sh` (100% passing).
- **V3:** Process integration test: `./.ci/test-command-reconcile-process.sh` (100% passing).
- **V4:** Build test: `./.ci/test-build-command-reconcile.sh` or compile check.
- **V5:** Git hygiene: `git diff --check`, `git status`.

## Definition of Done

- All requirements (R1–R5) implemented.
- `command-reconcile` outputs nothing during unchanged applies.
- `--json` outputs full structured JSON for both commands.
- All unit and integration test scripts succeed.
- Zero leftover debug code or formatting anomalies.
