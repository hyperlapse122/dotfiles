---
title: Universal MCP Manifest Synthesizer - Plan
type: feat
date: 2026-09-16
topic: universal-mcp-manifest-synthesizer
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** Eliminate duplicate template rendering and formatting drift for Model Context Protocol (MCP) servers across managed agent harnesses, providing a single compiled TypeScript synthesizer and syntax validator for all declared MCP manifests.
- **Means:** Add an `mcp` subcommand to `packages/settings-reconcile` that compiles the neutral inventory from `.chezmoidata/agents.yaml` into harness-specific formats (Claude Code JSON, Codex TOML, and oh-my-pi JSON) emitted to stdout, with internal regex validation for `op://` secret references.
- **Product Authority:** `github.com/hyperlapse122/dotfiles`
- **Open Blockers:** None

---

## Product Contract

### Summary

The Universal MCP Manifest Synthesizer introduces an `mcp` subcommand to `packages/settings-reconcile`. It reads the declarative, transport-neutral MCP server inventory from `.chezmoidata/agents.yaml` (`agents.mcp.servers`) and compiles it into exact, harness-specific configurations for Claude Code (`~/.mcp.json`), Codex (`~/.codex/config.toml`), and oh-my-pi (`~/.omp/agent/mcp.json`). Emitting formatted output to stdout preserves Chezmoi's target lifecycle and existing template-assisted secret injection, while lightweight native regex validation enforces canonical `op://` secret reference syntax in CI and pre-apply checks with zero external SDK dependencies.

### Problem Frame

Currently, MCP server declarations live in `.chezmoidata/agents.yaml`, but the logic to filter, format, and translate those declarations into harness-specific configuration is duplicated across multiple disparate locations:
1. `private_readonly_dot_mcp.json.tmpl` evaluates Go templates to produce Claude's universal `~/.mcp.json`.
2. `dot_omp/private_agent/mcp.json.tmpl` evaluates Go templates to produce oh-my-pi's `~/.omp/agent/mcp.json`.
3. `run_after_config-codex-settings.sh.tmpl` maps MCP servers into nested TOML tables (`mcp_servers.<name>`) before passing them to `settings-reconcile settings`.

This duplication represents a classic duplicate-knowledge defect as defined in `STRATEGY.md`. Subtle differences between harnesses (such as Codex using `http_headers` rather than `headers`, omitting the `type` property, and requiring strict table key sorting) are maintained manually in Go templates. Furthermore, no build-time or CI check validates that `op://` secret reference URIs in `agents.yaml` conform to valid 1Password syntax before apply, allowing malformed references to fail silently or halt template evaluation unexpectedly.

### Key Decisions

- KTD1. Pipeline-Friendly Stdout Manifest Emitter `(session-settled: user-directed — chosen over direct multi-file assertion engine: outputs formatted JSON/TOML to stdout per harness, preserving Chezmoi's managed target lifecycle and template-driven workflows)`. Governs R1, R2, R3, R4, R9.
- KTD2. Template-Assisted Compiler with Chezmoi Secret Injection `(session-settled: user-directed — chosen over runtime secret resolution: Chezmoi retains ownership of live onepasswordRead and test isolation stubs, avoiding live vault access during builds/CI)`. Governs R5, R6.
- KTD3. Lightweight Native Regex Reference Validation `(session-settled: user-directed — chosen over @1password/sdk: validates op:// reference syntax using internal regular expressions without introducing heavy external SDK dependencies, keeping settings-reconcile minimal and fast)`. Governs R5, R7.
- KTD4. Canonical Neutral Inventory as Single Source of Truth `(session-settled: user-approved — chosen over separate per-harness manifest definitions: compiles .chezmoidata/agents.yaml agents.mcp.servers directly, eliminating duplicate Go template logic)`. Governs R1, R8.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This feature enhances the declarative agent configuration infrastructure centered around `packages/settings-reconcile`:
- `packages/settings-reconcile` — Houses the new `mcp` subcommand alongside existing `settings`, `contracts`, and `trust` subcommands.
- `.chezmoidata/agents.yaml` — Serves as the declarative source of truth for all MCP servers and their secret references.
- `private_readonly_dot_mcp.json.tmpl` — Delegates JSON generation for `~/.mcp.json` to `settings-reconcile mcp --harness=claude`.
- `dot_omp/private_agent/mcp.json.tmpl` — Delegates JSON generation for `~/.omp/agent/mcp.json` to `settings-reconcile mcp --harness=omp`.
- `.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl` — Consumes TOML table output from `settings-reconcile mcp --harness=codex` to assert Codex settings.
- `.ci/` — Incorporates a static validation step (`settings-reconcile mcp --validate`) into existing CI test gates.

### Requirements

#### Manifest Synthesis & Formatting

- R1. The `settings-reconcile mcp` command shall compile declared servers from `.chezmoidata/agents.yaml` (`agents.mcp.servers`) into target-specific formats specified by the `--harness` flag (`claude`, `codex`, `omp`).
- R2. For the `claude` and `omp` harnesses, output shall be valid JSON formatted under a root `mcpServers` object, including `command`, `args`, `env`, and `headers` fields where declared.
- R3. For the `codex` harness, output shall be valid TOML formatted as `mcp_servers.<name>` tables, omitting the `type` field, translating `headers` to `http_headers`, and retaining `command`, `args`, and `env` for stdio transports.
- R4. All emitted keys, table names, and header properties shall be deterministically sorted alphabetically to ensure byte-identical stability across repeated runs.

#### Secret Reference Validation

- R5. The compiler shall validate that all strings beginning with `op://` in `headers` or `env` conform to the canonical 1Password Secret Reference URI format (`op://<vault>/<item>[/<section>]/<field>`), rejecting malformed references with a clear error on stderr and exit code 1.
- R6. The compiler shall preserve valid `op://` reference strings verbatim in generated manifests, allowing Chezmoi's `resolve-op-refs-json.tmpl` or `onepasswordRead` to perform live secret injection during apply.
- R7. The command shall support a standalone `--validate` flag that parses declared servers and verifies all `op://` references without generating manifest output, designed for CI and preflight checks.

#### CLI Interface & Filtering

- R8. The compiler shall filter servers based on declared eligibility criteria: `os` (linux, darwin), `container` (keep, skip), and `harnessSkip` (excluding named harnesses).
- R9. The command shall accept inventory input via an `--inventory <path>` argument or standard input (stdin), outputting formatted configuration directly to stdout.
- R10. Errors shall be reported on stderr with a clean `settings-reconcile: error: ...` message and exit code 1, exiting with code 0 on successful compilation and validation.

### Key Flows

- F1. Codex Apply Pipeline Integration
  - **Trigger:** `run_after_config-codex-settings.sh.tmpl` executes during `chezmoi apply`.
  - **Actors:** Chezmoi template engine, `settings-reconcile mcp`, `settings-reconcile settings`.
  - **Steps:** Chezmoi reads `.chezmoidata/agents.yaml`, pipes the inventory through `settings-reconcile mcp --harness=codex`, and merges the generated `mcp_servers` tables into the declared settings payload passed to `settings-reconcile settings`.
  - **Outcome:** Codex configuration in `~/.codex/config.toml` is asserted with 100% schema compliance and verified secret references.
  - **Covers:** R1, R3, R4, R6, R8, R9.

- F2. Offline CI Linting & Validation
  - **Trigger:** GitHub Actions CI executes repository verification gates.
  - **Actors:** CI runner, `settings-reconcile mcp --validate`.
  - **Steps:** The test runner executes `settings-reconcile mcp --validate --inventory .chezmoidata/agents.yaml`. The CLI parses all server definitions and validates all `op://` references using internal regular expressions.
  - **Outcome:** CI verifies that all declared secret references and transport settings are syntactically valid with zero network requests and no live vault credentials.
  - **Covers:** R5, R7, R8, R9, R10.

### Acceptance Examples

- AE1. Generating Codex TOML Table
  - **Given:** A declared server `context7` with `url: "https://mcp.context7.com/mcp"` and `headers: { CONTEXT7_API_KEY: "op://vault/Context7/API Key" }`.
  - **When:** Running `settings-reconcile mcp --harness=codex --inventory .chezmoidata/agents.yaml`.
  - **Then:** Standard output contains `[mcp_servers.context7]` with `url = "https://mcp.context7.com/mcp"` and `http_headers = { CONTEXT7_API_KEY = "op://vault/Context7/API Key" }`, with no `type` field.
  - **Covers:** R1, R3, R4, R6.

- AE2. Rejecting Malformed Secret Reference
  - **Given:** An MCP server in `agents.yaml` with header `TOKEN: "op://invalid-format-missing-parts"`.
  - **When:** Running `settings-reconcile mcp --validate --inventory .chezmoidata/agents.yaml`.
  - **Then:** Process exits with status code 1 and writes `settings-reconcile: error: server 'foo': invalid 1Password secret reference 'op://invalid-format-missing-parts'` to stderr.
  - **Covers:** R5, R7, R10.

- AE3. Harness Exclusion Filtering
  - **Given:** An MCP server declared with `harnessSkip: ["codex"]`.
  - **When:** Running `settings-reconcile mcp --harness=codex --inventory .chezmoidata/agents.yaml`.
  - **Then:** The server is omitted from the generated output.
  - **Covers:** R1, R8.

### Scope Boundaries

- **In-scope:**
  - New `mcp` subcommand in `packages/settings-reconcile`.
  - Harness formatting for Claude Code (`~/.mcp.json`), Codex (`~/.codex/config.toml`), and oh-my-pi (`~/.omp/agent/mcp.json`).
  - Native regex syntax validation for canonical `op://` reference URIs.
  - Eligibility filtering for host OS, container environments, and harness skip lists.
  - Integration into existing template render sites and CI validation suites.
  - Unit tests in `packages/settings-reconcile/tests/`.

- **Out-of-scope:**
  - External `@1password/sdk` npm dependency (explicitly scoped out to avoid bundle weight).
  - Runtime network access to 1Password vaults during compilation (live resolution remains owned by Chezmoi).
  - Direct in-place file mutation (stdout emission preserves Chezmoi's target tracking).
  - Ad-hoc MCP servers added outside `.chezmoidata/agents.yaml`.

### Success Criteria

- SC1. Complete de-duplication of MCP formatting logic across `private_readonly_dot_mcp.json.tmpl`, `dot_omp/private_agent/mcp.json.tmpl`, and `run_after_config-codex-settings.sh.tmpl`.
- SC2. Sub-50 millisecond execution latency for full inventory compilation and validation.
- SC3. Zero external dependencies added to `packages/settings-reconcile/package.json`.
- SC4. Clean, automated validation in CI that catches syntax errors in declared secret references before apply.

---

## Planning Contract

### Technical Design

The implementation adds a standalone module `packages/settings-reconcile/src/mcp.ts` and connects it to the CLI in `packages/settings-reconcile/src/cli.ts`.

1. **Secret Reference Validation Grammar:**
   Canonical 1Password URI format is defined as:
   `^op:\/\/[a-zA-Z0-9_\.\-\/ ]+\/[a-zA-Z0-9_\.\-\/ ]+(\/[a-zA-Z0-9_\.\-\/ ]+)?\/[a-zA-Z0-9_\.\-\/ ]+$`
   Specifically:
   `op://<vault>/<item>/<field>` or `op://<vault>/<item>/<section>/<field>`.
   Any string starting with `op://` that does not match this grammar causes `validateSecretReference` to throw an error identifying the exact offending server and field name.

2. **Harness Formatting Rules:**
   - **Claude Code (`claude`):**
     Output format: JSON (`{ "mcpServers": { ... } }`).
     Stdio servers: `{ "command": "...", "args": [...], "env": { ... } }`.
     HTTP/SSE servers: `{ "url": "...", "headers": { ... }, "type": "http" }`.
   - **Codex (`codex`):**
     Output format: TOML table map (`[mcp_servers.<name>]`).
     Stdio servers: `command = "..."`, `args = [...]`, `env = { ... }`.
     HTTP/SSE servers: `url = "..."`, `http_headers = { ... }`. Note: Codex strictly omits `type`, translates `headers` to `http_headers`, and requires sorted keys.
   - **oh-my-pi (`omp`):**
     Output format: JSON (`{ "mcpServers": { ... } }`).
     Stdio servers: `{ "command": "...", "args": [...], "env": { ... } }`.
     HTTP/SSE servers: `{ "url": "...", "headers": { ... } }`. Note: omp accepts standard HTTP headers without the `type: "http"` discriminator.

3. **Eligibility Filtering:**
   Given the host facts (`os`: `linux` | `darwin`, `container`: boolean):
   - Server declares `os: [linux, darwin]`: if current OS is not in list, skip.
   - Server declares `container: "skip"`: if `container` is true, skip.
   - Server declares `harnessSkip: ["codex", ...]`: if target harness is in `harnessSkip`, skip.

4. **CLI Subcommand Wiring:**
   `settings-reconcile mcp [--harness=<claude|codex|omp>] [--inventory=<path>] [--validate] [--os=<linux|darwin>] [--container=<true|false>]`
   - If `--validate` is passed: parses and validates all `op://` references across all declared servers; exits 0 if clean, exits 1 on invalid reference.
   - If `--harness` is passed: compiles and prints the formatted manifest to stdout.
   - Defaults `--inventory` to reading from stdin when no path is supplied.

### Key Technical Decisions

- KTD1. Single-File Pure TypeScript Core `(session-settled: user-directed — chosen over external SDK dependencies: implement regex validation and manifest formatting in packages/settings-reconcile/src/mcp.ts, keeping bundle size small and avoiding Node/Bun native bindings)`. Governs R1, R5, R8.
- KTD2. Deterministic Lexical Serialization `(session-settled: user-approved — chosen over arbitrary object key insertion: sort all server names, environment keys, and header properties alphabetically before stringify, ensuring bit-identical output)`. Governs R4.
- KTD3. Pipeline-Oriented Stdin/Stdout Architecture `(session-settled: user-directed — chosen over direct filesystem writes: emits to stdout, allowing seamless piping in both Chezmoi template evaluation and external script pipelines)`. Governs R1, R9.

---

## Implementation Units

### U1. MCP Synthesizer Core Module & Reference Validator

- **Goal:** Implement `packages/settings-reconcile/src/mcp.ts` providing types, 1Password secret URI regex validation, server eligibility filtering, and harness-specific formatting functions.
- **Files:** `packages/settings-reconcile/src/mcp.ts`
- **Patterns:** Pure functional manifest compilation. Utilize `smol-toml` for TOML serialization (already a dependency) and native `JSON.stringify(..., null, 2)` for JSON output.
- **Test Scenarios:**
  - Validates correct `op://<vault>/<item>/<field>` and `op://<vault>/<item>/<section>/<field>` URIs.
  - Rejects malformed `op://` strings (e.g. missing vault/item, empty segments, bare `op://`).
  - Correctly applies `os`, `container`, and `harnessSkip` exclusions.
  - Formats Claude Code JSON with `mcpServers` root and `type: "http"`.
  - Formats Codex TOML with `mcp_servers.<name>` tables, mapping `headers` to `http_headers` and omitting `type`.
  - Formats omp JSON with `mcpServers` root.
- **Verification:** `bun test test/mcp.test.ts`

### U2. CLI Subcommand Wiring & Argument Parsing

- **Goal:** Extend `packages/settings-reconcile/src/cli.ts` with the `mcp` subcommand supporting `--harness`, `--inventory`, `--validate`, `--os`, and `--container` flags, with stdin fallback and clean stderr error reporting.
- **Files:** `packages/settings-reconcile/src/cli.ts`
- **Patterns:** Standard argv parsing consistent with existing `settings` and `trust` subcommands; error handling catching thrown errors and formatting them as `settings-reconcile: error: ...` on stderr with exit code 1.
- **Test Scenarios:**
  - `settings-reconcile mcp --harness=codex --inventory=<path>` outputs valid TOML to stdout.
  - `settings-reconcile mcp --harness=claude --inventory=<path>` outputs valid JSON to stdout.
  - `settings-reconcile mcp --harness=omp --inventory=<path>` outputs valid JSON to stdout.
  - `settings-reconcile mcp --validate --inventory=<path>` exits 0 on valid inventory and 1 on invalid inventory.
  - Reading inventory from stdin when `--inventory` is omitted.
  - Fails with usage on unknown harness or missing arguments.
- **Verification:** `bun test test/mcp.test.ts`

### U3. Comprehensive Test Suite in packages/settings-reconcile

- **Goal:** Create `packages/settings-reconcile/test/mcp.test.ts` covering all manifest synthesis scenarios, validation rules, error cases, and CLI invocations.
- **Files:** `packages/settings-reconcile/test/mcp.test.ts`
- **Patterns:** `vite-plus/test` (`describe`, `it`, `expect`) matching `reconcile.test.ts` and `trust.test.ts`.
- **Test Scenarios:**
  - Synthesis matches expected outputs for mock inventories across all three harnesses.
  - Stdio vs HTTP transport properties correctly preserved and translated.
  - Eligibility filtering tested for OS (linux/darwin), container (keep/skip), and harnessSkip.
  - Regex validation checks various valid and invalid secret references.
  - Deterministic alphabetical key sorting verified.
- **Verification:** `bun test test/`

### U4. Integration with Chezmoi Settings & CI Verification

- **Goal:** Integrate `settings-reconcile mcp` into the agent settings apply pipeline (`run_after_config-codex-settings.sh.tmpl`), and add an automated CI validation gate in `.ci/test-command-manifest.sh` or a dedicated test script.
- **Files:**
  - `.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl`
  - `.ci/test-omp-mcp-render.sh`
- **Patterns:** Pipeline integration replacing verbose Go template dictionary mapping with a call to `settings-reconcile mcp --harness=codex`.
- **Test Scenarios:**
  - Run `.ci/test-codex-settings-reconcile.sh` to confirm rendered script executes cleanly against the new synthesizer.
  - Verify CI passes all build and test gates.
- **Verification:** `bun test test/ && .ci/test-omp-mcp-render.sh`

---

## Verification Contract

Automated tests and verification checks:

1. **Unit Test Suite:**
   ```bash
   cd packages/settings-reconcile && bun test test/mcp.test.ts
   ```
   Must pass 100% of test assertions covering all three harness formats, eligibility filters, and secret validation cases.

2. **Package-Wide Verification:**
   ```bash
   cd packages && bun run -r typecheck && bun run -r test
   ```
   Must pass type checking and all existing workspace test suites with zero errors.

3. **CI Gate & Render Verification:**
   ```bash
   .ci/test-omp-mcp-render.sh
   ```
   Must confirm omp MCP manifest rendering remains consistent and valid.

---

## Definition of Done

- [ ] `packages/settings-reconcile/src/mcp.ts` implemented with reference validation, eligibility filtering, and harness formatters.
- [ ] `packages/settings-reconcile/src/cli.ts` updated with `mcp` subcommand supporting `--harness`, `--inventory`, and `--validate`.
- [ ] Comprehensive test suite `packages/settings-reconcile/test/mcp.test.ts` added and passing via `bun test`.
- [ ] Integration verified with existing settings scripts and template renderers.
- [ ] No external dependencies added to `packages/settings-reconcile/package.json`.
- [ ] `git diff --check` reports zero whitespace or syntax errors.
