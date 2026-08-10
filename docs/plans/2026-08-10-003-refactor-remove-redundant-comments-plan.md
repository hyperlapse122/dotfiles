---
title: Redundant Comment Cleanup - Plan
type: refactor
date: 2026-08-10
topic: redundant-comment-cleanup
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Redundant Comment Cleanup - Plan

## Goal Capsule

- **Objective:** Remove obvious, stale, and commented-out code comments from every tracked text artifact without changing program, template, configuration, or documentation semantics.
- **Product authority:** The user request defines removal and retention rules. Root `AGENTS.md` defines chezmoi source ownership, generated-data limits, apply-lifecycle side effects, and isolated verification.
- **Execution profile:** Build a reconciled tracked-text inventory, audit all tracked text files in two source families, then verify syntax, rendered templates, and the affected project test suites.
- **Stop conditions:** Stop on a candidate whose purpose cannot be distinguished from a safety, ownership, lifecycle, compatibility, or non-obvious behavior constraint. Keep that comment rather than infer intent. Do not apply chezmoi to live `$HOME`.
- **Tail ownership:** This LFG run owns cleanup, local verification, review, commit, PR, and CI observation.

---

## Product Contract

### Summary

The repository retains comments that carry a non-obvious constraint or satisfy the user's explicit exceptions. It removes commented-out code, edit-history narration, and explanations that only repeat the adjacent symbol or statement. A kept end-of-line comment moves to a preceding comment line when that move preserves the source format and meaning.

### Problem Frame

The tracked source contains historic, explanatory, and commented-out fragments across shell templates, tests, TypeScript, Rust, configuration, and workflow files. Redundant comments make the maintained intent harder to find. Removing comments without semantic review would risk deleting chezmoi rendering, lifecycle, security, and test-rationale constraints.

### Requirements

**Repository coverage**

- R1. Inspect every tracked UTF-8 text file for code-comment syntax that is valid for its format, including source, templates, scripts, tests, CI, configuration, and documentation markup. Do not edit encrypted, generated, binary, or third-party artifacts.
- R2. Remove every commented-out code fragment and comments that describe a prior edit such as adding, removing, or changing something.

**Selection and placement**

- R3. Remove a comment when it only restates the immediately adjacent identifier, branch, method, or literal behavior.
- R4. Keep TODO comments, empty-block explanations, formatter or linter directives, and comments that state a non-obvious security, ownership, rendering, lifecycle, compatibility, safety, or test-boundary constraint.
- R5. Move a kept end-of-line comment to the preceding line only when it describes the following statement and the move preserves valid syntax and template rendering.

**Safety and audit evidence**

- R6. Preserve executable, rendered, configuration, and documentation semantics. Do not reformat unrelated code or alter generated lock data.
- R7. Verify each edited language and chezmoi rendering surface with the repository's existing checks or an isolated render that exercises the changed contract.
- R8. Produce a NUL-safe `git ls-files` inventory outside the repository and reconcile every path as audited, binary, encrypted, generated, third-party, or excluded with its reason before declaring completion.
- R9. For each changed `run_onchange_*` script or raw-source fingerprint input, record its next-apply rerun and possible side effects in the PR context. This known source-fingerprint effect is not a semantic code change and must not be exercised against live `$HOME`.

### Scope Boundaries

- Documentation headings, YAML keys, shebangs, template delimiters, URLs, and string literals are not comments and are out of scope.
- A comment that documents an exception, invariant, or operational risk remains even if it is long.
- The work does not introduce a new checker or rework the existing omp comment-rule system.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use semantic review, not bulk deletion.** A repository-wide comment pattern match identifies candidates only. Each removal must meet R2 or R3, while R4 protects load-bearing explanations that syntax cannot classify.
- KTD2. **Use a reconciled tracked-text inventory as the complete audit population.** A NUL-safe `git ls-files` inventory records every tracked path and its audit status. Generated locks, encrypted state, binaries, and external caches remain untouched under R1, R6, and R8.
- KTD3. **Preserve format-local comment syntax.** Shell, Go-template, YAML, TOML, TypeScript, Rust, Markdown, and workflow comments are edited only with valid native syntax. Inline comment relocation follows R5 and never crosses a template action, scalar boundary, or multiline expression.
- KTD4. **Prove non-behavioral cleanup with existing gates.** No test fixture changes are expected. Run the `packages/` Vite+ workspace gates, Rust tests, comment-rule test, isolated chezmoi renders for changed templates, and diff hygiene instead of adding tests for comment text.
- KTD5. **Treat chezmoi fingerprints as an operational side effect.** Removing a rendered `run_onchange_*` comment or changing a raw fingerprint source causes a one-time rerun on the next apply. Inventory that consequence under R9, do not deploy it during this run, and retain the comment when the rerun contract itself is the non-obvious information it carries.

### Sequencing

U1 and U2 can inspect independently. U3 runs after all candidate edits and selects checks from the actual changed file families.

---

## Implementation Units

### U1. Audit scripts, templates, and declarative sources

- **Goal:** Clean eligible comments from all tracked chezmoi scripts, shared templates, executable helpers, CI shell scripts, workflow files, and declarative configuration.
- **Requirements:** R1–R9.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/**`, `.chezmoitemplates/**`, `.ci/**`, `.github/**`, `dot_local/**`, `dot_config/**`, `.chezmoidata/**`, `.chezmoiexternals/**`, root configuration files, and any other tracked shell/template/configuration file selected by the complete audit.
- **Approach:** Create the NUL-safe tracked-path inventory before edits and reconcile each path under R8. Identify valid local comment forms, then remove only candidates satisfying R2 or R3. Preserve explanatory comments that make chezmoi triggers, host gates, safety checks, credentials, ownership, or test assertions understandable. For every changed `run_onchange_*` body or fingerprint input, record the script's next-apply action and operational risk under R9. Promote qualifying trailing comments above their statements.
- **Test scenarios:** A removed comment leaves its shell/template/configuration syntax valid. A retained directive, TODO, empty-block marker, non-obvious operational constraint, or lifecycle explanation remains valid and adjacent to its governed code. A changed onchange script is recorded as a rerun candidate without a live apply.
- **Verification:** Render every modified `.tmpl` through `chezmoi execute-template` with the repository scratch `op` stub. Run each changed `.ci` test and workflow/configuration validation already used by the repo.

### U2. Audit implementation, test, fixture, and documentation sources

- **Goal:** Clean eligible comments from all tracked package, crate, test, fixture, and documentation-markup sources.
- **Requirements:** R1–R8.
- **Dependencies:** None.
- **Files:** `packages/**`, `crates/**`, test and fixture trees, `docs/**`, and every other tracked text file not covered by U1.
- **Approach:** Reconcile every path in the inventory under R8. Review TypeScript, Rust, shell, Python, Markdown, and embedded formats according to KTD1 and KTD3. Do not modify string literals, examples, comments required to explain test intent, generated release data, or documentation prose that is not a comment.
- **Test scenarios:** Removed source comments do not change compilation or test behavior. Retained test-boundary comments still explain non-obvious assertion or fixture intent. Any moved trailing comment remains a valid comment in its new position.
- **Verification:** From `packages/`, run `vp run -r build`, `vp run -r typecheck`, `vp run -r test`, and `vp check` when TypeScript changes. Run `cargo test` for modified Rust sources and `.ci/test-omp-comment-rules.sh` when its rules, fixtures, or driver changes.

### U3. Validate complete cleanup

- **Goal:** Prove the final diff is comment-only cleanup and remains renderable and testable.
- **Requirements:** R6–R9.
- **Dependencies:** U1, U2.
- **Files:** All files changed by U1 and U2.
- **Approach:** Reconcile the complete tracked-path inventory and preserve its temporary evidence outside the repository. Classify the final diff by file family, run the applicable checks, inspect every retained comment in the diff context against R4, and list each next-apply onchange consequence for the PR. Do not add tests unless a changed comment alters observable parsing or rendering behavior.
- **Test scenarios:** Modified templates render in isolation. Modified package and crate tests pass. Formatting and whitespace checks reject accidental syntax or trailing-space damage. The inventory has no unclassified tracked path.
- **Verification:** `git diff --check`; applicable `packages/` Vite+ workspace gates; relevant `cargo test`; changed `.ci` checks; isolated `chezmoi execute-template` renders; and final PR CI.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| A concise-looking template comment encodes a rendering or apply-lifecycle invariant. | Keep comments that explain ownership, fingerprints, host gates, security, or failure handling unless removal is unambiguous. |
| A changed `run_onchange_*` source or fingerprint input reruns provisioning on the next apply. | Identify every affected script before editing, disclose its exact next-apply operation, and never run a live apply during this cleanup. |
| YAML, TOML, shell, or Go-template comments can change parsing when moved. | Use format-local syntax and render every changed template in isolation. |
| A broad scan can mistake documentation markup or string content for comments. | Reconcile every tracked path to its audit status and edit only parser-valid comment tokens in source context. |
| Comment-only edits hide accidental code changes in a large diff. | Review the final diff, run `git diff --check`, and use existing language-specific tests. |

---

## Verification Contract

| Gate | Applies to | Done signal |
| --- | --- | --- |
| Candidate review and inventory | U1, U2, U3 | Every tracked path has one R8 status. Every removed comment satisfies R2 or R3. Every retained candidate satisfies R4 or has non-obvious value. |
| Template rendering | U1 | Every changed `.tmpl` renders with the scratch `op` stub and `chezmoi --source "$PWD" execute-template`. |
| TypeScript workspace | U2 | From `packages/`, `vp run -r build`, `vp run -r typecheck`, `vp run -r test`, and `vp check` exit 0 when TypeScript changes. |
| Rust tests | U2 | `cargo test` exits 0 when Rust source changes. |
| Existing CI scripts | U1, U2 | Every changed `.ci` test script exits 0. |
| Diff hygiene | U3 | `git diff --check` exits 0 and the final diff contains no unintended behavior change. |
| Apply-side-effect disclosure | U1, U3 | The PR records each affected onchange script and confirms no live apply occurred. |
| PR CI | U3 | `render-dotfiles.yml` and `ci.yml` reach terminal success after push. |

---

## Definition of Done

- The R8 inventory reconciles every tracked path before cleanup is declared complete.
- Every tracked text source has been reviewed for the comment categories in R1.
- All comments meeting R2 or R3 are removed.
- All comments protected by R4 remain, and qualifying trailing comments are repositioned under R5.
- Any changed `run_onchange_*` or fingerprint input has its next-apply side effect disclosed under R9, and no live apply occurred.
- No generated, encrypted, binary, or third-party artifact changed.
- The verification contract passes for every changed file family.
- The final diff has no abandoned scripts, fixtures, or behavior changes.
