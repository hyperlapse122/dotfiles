---
title: "feat: wrap codex exec with tokscale"
date: 2026-07-25
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# feat: wrap codex exec with tokscale

## Goal Capsule

- **Objective:** Capture token usage for headless Codex runs by routing `codex exec` through Tokscale while preserving direct Codex behavior for every other invocation.
- **Authority:** The user request and Tokscale's documented headless-mode command shape govern behavior; repository shell and chezmoi conventions govern placement and verification.
- **Execution profile:** A bounded managed-wrapper and installer change with isolated behavior tests; do not apply the source state to the live home directory.
- **Stop conditions:** Stop if the wrapper cannot reach the external Codex executable without recursion or if it changes arguments, output, or exit status.
- **Tail ownership:** Commit, push, PR creation, CI, and review handling are owned by the invoking LFG pipeline.

---

## Product Contract

### Summary

Codex users should automatically receive Tokscale headless capture when they run `codex exec`, without changing how any other Codex command behaves.

### Problem Frame

Tokscale only captures Codex headless output automatically when Codex is launched as `tokscale headless codex exec ...`. Requiring callers to remember that prefix loses usage attribution, while replacing the external `codex` executable with another executable named `codex` risks recursion when Tokscale launches Codex internally.

### Requirements

- R1. A Codex invocation whose first argument is exactly `exec` must run through `tokscale headless codex exec` with all remaining arguments unchanged.
- R2. A Codex invocation with no arguments or with any first argument other than exactly `exec` must invoke the external Codex command directly with all arguments unchanged.
- R3. The wrapper must preserve the selected command's stdout, stderr, signals, and exit status without fallback or post-processing.
- R4. The implementation must avoid recursion when Tokscale launches the external Codex executable.
- R5. Verification must be isolated from the deployed home directory and must not run a real Codex or Tokscale session.

### Scope Boundaries

- **In scope:** A managed public Codex executable wrapper, preservation of the existing standalone release selection, and an isolated regression test covering dispatch, argument fidelity, recursion avoidance, and exit-status fidelity.
- **Out of scope:** Wrapping non-`exec` subcommands, changing Tokscale configuration or installation, changing the upstream Codex package, Windows support, and applying the chezmoi source state to the live home directory.

### Key Decision

- **Only `codex exec` is captured** (user-directed; Governs R1, R2). This is chosen over wrapping every Codex command because the user explicitly excluded other commands and Tokscale documents headless capture for Codex exec output.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use a managed public executable wrapper and keep the real standalone binary at its versioned current-release path.** The installer must stop overwriting `~/.local/bin/codex` with a symlink, while continuing to maintain `~/.codex/packages/standalone/releases/current/bin/codex`. This covers interactive and automated callers rather than only zsh functions.
- KTD2. **Dispatch solely on the first positional argument.** Compare the first argument to the exact token `exec`; do not scan later arguments or interpret flags, so `codex --help`, `codex resume`, and option-led invocations remain direct.
- KTD3. **Prepend the real Codex directory to PATH only for the Tokscale branch.** Tokscale's current Rust implementation passes the lowercase source name `codex` to `std::process::Command::new`, which performs PATH lookup. Putting `~/.codex/packages/standalone/releases/current/bin` first therefore prevents recursion without changing the caller's persistent environment. Treat this upstream lookup behavior as an integration contract covered by the regression test.
- KTD4. **Test rendered scripts with stub executables in isolated HOME and PATH roots.** The test records which command and arguments were selected and what Codex Tokscale resolves, without executing either real tool.

### Assumptions

- The wrapper is POSIX-only, matching the existing non-Windows standalone Codex linker.
- Tokscale's documented `tokscale headless codex exec ...` interface remains the authoritative capture contract.

### Sources and Research

- Tokscale headless mode documents automatic Codex capture through `tokscale headless codex exec ...` and limits headless capture support to Codex CLI: https://github.com/junhoyeo/tokscale#headless-mode
- Tokscale's current `crates/tokscale-cli/src/main.rs` calls `run_capture_command(&source_lower, ...)`, which constructs `std::process::Command::new(command)` for the `codex` source, confirming PATH-based child resolution: https://github.com/junhoyeo/tokscale/blob/main/crates/tokscale-cli/src/main.rs
- `.chezmoiscripts/00-tools/run_onchange_after_codex.sh.tmpl` already owns the versioned Codex release, current pointer, executable link, and pruning.
- `dot_local/bin/private_executable_tokscale.tmpl` owns Tokscale runtime invocation; `dot_config/mise/config.toml` already provisions Tokscale.
- No matching open GitHub issue or repository learning in `docs/solutions/` was found.

---

## Implementation Units

### U1. Add selective Codex dispatch

- **Goal:** Route only `codex exec` through Tokscale from every POSIX PATH invocation.
- **Requirements:** R1, R2, R3, R4; KTD1, KTD2, KTD3, KTD4.
- **Dependencies:** None.
- **Files:** `dot_local/bin/executable_codex`, `.chezmoiscripts/00-tools/run_onchange_after_codex.sh.tmpl`, `.ci/test-codex-tokscale-wrapper.sh`, `.github/workflows/ci.yml`.
- **Approach:**
  1. Add a POSIX public wrapper at `dot_local/bin/executable_codex`.
  2. When the first argument is exactly `exec`, prepend the current-release Codex directory to PATH and delegate to Tokscale as `headless codex` plus the original argument vector.
  3. Otherwise execute the current-release Codex binary directly with the original argument vector.
  4. Update the onchange installer to keep current-release linking and pruning but leave the public wrapper owned by chezmoi.
  5. Add and wire an isolated regression test with fake real-Codex and Tokscale executables that records dispatch, child resolution, and controlled exit codes.
- **Execution note:** Start with the isolated dispatch assertions, then add the function and confirm the full argument vector and exit code remain unchanged.
- **Patterns to follow:** `.chezmoiscripts/00-tools/run_onchange_after_codex.sh.tmpl` owns current-release selection and pruning. Test scripts under `.ci/` use strict shell mode and task-scoped scratch storage.
- **Test scenarios:**
  - Running `codex exec --json "review code"` selects the Tokscale stub with arguments `headless codex exec --json "review code"` in the original order.
  - Running `codex`, `codex resume abc`, `codex --help`, and `codex execx` selects the Codex stub directly and preserves each original argument vector.
  - A nonzero status from the selected Tokscale stub is returned unchanged by `codex exec`.
  - A nonzero status from the selected Codex stub is returned unchanged by a non-`exec` invocation.
  - The Tokscale-compatible PATH lookup and launch of `codex exec` resolves the current-release Codex stub rather than recursively entering the public wrapper.
- **Verification:** The isolated test passes without accessing the user's live zsh configuration, Codex state, Tokscale state, or home-directory destination.

### U2. Run source-state quality gates

- **Goal:** Prove the managed source remains renderable and repository invariants remain intact.
- **Requirements:** R5.
- **Dependencies:** U1.
- **Files:** `dot_local/bin/executable_codex`, `.chezmoiscripts/00-tools/run_onchange_after_codex.sh.tmpl`, `.ci/test-codex-tokscale-wrapper.sh`, `.github/workflows/ci.yml`, `CLAUDE.md`.
- **Approach:** Render the changed wrapper and onchange template through chezmoi with an isolated destination and stubbed secret tooling, run the wrapper regression test, run shell lint, and inspect only the requested diff.
- **Test scenarios:** Test expectation: none -- this unit performs repository-level validation rather than adding behavior.
- **Verification:** The changed wrapper and onchange template render, the isolated regression test and applicable lint pass, `git diff --check` passes, `CLAUDE.md` remains exactly `@AGENTS.md`, and no live apply occurs.

---

## Verification Contract

| Gate | Applies to | Done signal |
|---|---|---|
| Isolated wrapper regression | U1 | Exact dispatch, arguments, recursion avoidance, and both exit-status paths pass |
| Chezmoi render with `--source "$PWD"` and isolated destination | U1, U2 | The managed wrapper and onchange template render without touching live `$HOME` |
| Shell lint | U1 | Changed shell sources have no applicable lint findings |
| `git diff --check` | U1, U2 | No whitespace errors |
| Scoped diff and status review | U1, U2 | Only requested source, test, plan, and pipeline-owned artifacts are changed |
| `CLAUDE.md` mirror check | U2 | File content is exactly `@AGENTS.md` plus newline |

---

## Definition of Done

- `codex exec ...` in interactive zsh delegates to `tokscale headless codex exec ...`.
- Every other Codex invocation delegates directly to the external Codex executable.
- Arguments, output channels, signals, and exit status are transparent.
- Tokscale's child Codex launch cannot recurse through the public wrapper.
- Isolated behavioral and chezmoi rendering checks pass without a live apply.
- The requested changes are committed, pushed, reviewed, and carried by a green pull request.
