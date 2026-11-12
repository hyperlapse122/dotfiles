---
title: Full-CI Label Without Cancelled Runs - Plan
type: fix
date: 2026-11-12
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Full-CI Label Without Cancelled Runs - Plan

## Goal Capsule

- **Objective:** When a pull request gets the `full-ci` label, at creation or later, its head carries no cancelled CI run, so a PR watcher such as `ce-babysit-pr` can call it ready once every run on the head is green.
- **Means:** Label events get their own one-off concurrency group and a gate set that runs only the closure jobs for `full-ci` and nothing for any other label (KTD1, KTD2).
- **Authority:** This plan's Requirements, then KTDs, then units. `AGENTS.md` testing and CI-readiness rules apply throughout.
- **Execution profile:** One PR. Touches `.github/workflows/check.yml`, `tests/check-workflow-docs-skip.sh`, `flake.nix`, and `AGENTS.md`.
- **Stop conditions:** Stop if GitHub rejects the concurrency expression at run time, or if a run with every job skipped ends with a conclusion other than `success` or `skipped`.
- **Finish and ship:** `ce-work` implements. The PR needs a green run of the `full-ci` path itself, as `AGENTS.md` requires for workflow changes.

---

## Product Contract

### Summary

Change the PR workflow so that adding a label never cancels a run. A `full-ci` label event starts a separate run that builds only the closure jobs. Any other label event runs no jobs. A new push still cancels the previous run on the branch, as it does today.

### Problem Frame

`check.yml` runs on `pull_request` types `opened`, `synchronize`, `reopened`, and `labeled`, under one workflow-level concurrency group per ref with `cancel-in-progress: true`. Adding `full-ci` fires a `labeled` run that cancels the run already going on the same head. The cancelled run stays attached to that SHA. PRs #158 and #157 and commit `098e8dc` each show one cancelled and one successful run on the same head; `098e8dc` was a PR created with the label, where `opened` and `labeled` arrived in the same second. `ce-babysit-pr` reads every run on the head, so it never reports the PR ready even though CI is green.

Commit `38e954d` made unrelated-label events rerun the closure jobs, because those events cancelled the full run and had to replace it. Once label events stop cancelling, that rerun has no purpose.

### Key Decisions

- **The `full-ci` label run starts at once in a separate group and runs only the closure jobs.** (session-settled: user-directed — chosen over one shared group where the label run queues behind the existing run: closure results arrive about 8 minutes sooner; accepted cost that after a push the previous head's label run is not cancelled and runs to completion, about 30 minutes.) Governs R1, R2, R5.

### Requirements

**Run cancellation**

- R1. A `labeled` run never cancels another run and is never cancelled by one.
- R2. A `synchronize` run still cancels the previous non-label run on the same ref, and `push` to `main` and `workflow_dispatch` keep their current grouping.

**Which jobs run**

- R3. A `labeled` run for `full-ci` runs `changes` and the closure jobs (`hosts`, `host-checks`, `vm-check-names`, `vm-checks`, `build`, `build-darwin`), and the closure jobs still skip on a docs-only PR.
- R4. A `labeled` run for any other label runs no jobs.
- R5. No `labeled` run runs a light job (`fmt`, `flake-check`, `check-shard-names`, `check-shards`, `markdown-lint`).
- R6. An `opened` run never runs closure jobs. `synchronize` and `reopened` runs include them when the PR carries `full-ci`. `push` and `workflow_dispatch` always include them.
- R7. Every gate fails closed with respect to the label: when `changes` is skipped or fails, a closure job still runs only under the event and label conditions in R3 and R6.

**Readiness evidence**

- R8. `AGENTS.md` describes the label run, and its readiness rule accepts closure evidence split across the `opened` or `synchronize` run and the `labeled` run on the same head.

### Acceptance Examples

- AE1. **Covers R1, R3, R6.** Given a PR created with `full-ci`, when `opened` and `labeled` arrive together, then the `opened` run runs only light jobs, the `labeled` run runs only closure jobs, and neither run is cancelled.
- AE2. **Covers R1, R4.** Given a PR with `full-ci` whose closure jobs are running, when someone adds the label `bug`, then a run with no jobs starts and finishes, and the closure run continues.
- AE3. **Covers R2.** Given a labeled PR, when a new commit is pushed, then the previous `synchronize` run is cancelled, the new `synchronize` run includes closure jobs, and the previous head's `labeled` run keeps running.
- AE4. **Covers R7.** Given a `labeled` run for `bug` where `changes` is skipped, then no closure job runs, even though `needs.changes.result` is not `success`.

### Scope Boundaries

- Cancelling the previous head's label run after a push is out of scope, per the Key Decision. Job-level concurrency could do it, but it would group matrix siblings together and could cancel the current head's run when the label is removed and re-added, which brings back the bug.
- Consecutive pushes to `main` cancelling each other's runs is unchanged.
- A PR created through a path that adds the label without a `labeled` event would get no closure jobs. `gh pr create --label` and the GitHub UI both fire `labeled`, and `AGENTS.md` already says skipped closure jobs do not satisfy readiness, so this is considered and not built.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Label runs use a one-off concurrency group.** The group appends `-labeled-<run_id>` when `github.event.action == 'labeled'` and stays `<workflow>-<ref>` otherwise, with `cancel-in-progress: true` kept. A unique group means a label run can never cancel or be cancelled, which covers both `full-ci` re-adds and unrelated labels without a second group per label name. It instantiates the Key Decision (R1, R2, R5).
- KTD2. **Gates are allow-lists keyed on event and label, not on `changes`.** Closure jobs run when the event is `push` or `workflow_dispatch`, or when the PR action is `labeled` with label `full-ci`, or when the action is `synchronize` or `reopened` and the PR carries `full-ci`. The docs-only skip stays as a separate conjunct. Light jobs, `markdown-lint`, and `fmt` add a "not `labeled`" conjunct. The current gates pass whenever `needs.changes.result != 'success'`, so a skipped `changes` would otherwise let an unrelated label rerun everything (R3–R7).
- KTD3. **`changes` runs only on `full-ci` label runs among label events.** On other label runs it skips, so the run has no jobs at all (R4). If a run with zero jobs turns out to end in a failing conclusion, the Goal Capsule stop condition applies: report it instead of changing the gates. Letting `changes` run on every label event would fix it, but it contradicts R4, AE2, and U2's mutant list, so it needs the requester's approval first.
- KTD4. **The policy test checks behavior, not gate strings.** The current mutations only fail `policy()`, which compares each `if` to an exact string, so any edit fails and no mutation proves behavior (`.compound-engineering/artifacts/solutions/best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md`). Move the truth table and a concurrency-group evaluation into one behavior function, and run each mutant through it.
- KTD5. **Lint the workflow with `actionlint` inside the existing check.** An invalid expression in `concurrency` only fails when GitHub runs the workflow. `actionlint -shellcheck= -pyflakes=` passes on today's `check.yml`, and the `update-dependencies-reconcile` check already uses it the same way.

### High-Level Technical Design

Which jobs each event runs after the change (non-docs-only PR):

| Event | Concurrency group | Light jobs | `changes` | Closure jobs |
| --- | --- | --- | --- | --- |
| `opened` | `<wf>-<ref>` | yes | yes | no |
| `synchronize` | `<wf>-<ref>`, cancels | yes | yes | if labeled `full-ci` |
| `reopened` | `<wf>-<ref>` | yes | yes | if labeled `full-ci` |
| `labeled` `full-ci` | `<wf>-<ref>-labeled-<run_id>` | no | yes | yes |
| `labeled` other | `<wf>-<ref>-labeled-<run_id>` | no | no | no |
| `push` `main`, `workflow_dispatch` | `<wf>-<ref>` | yes | no | yes |

### Assumptions

- A run whose jobs are all skipped reports a non-failing conclusion. U2's post-merge evidence confirms it.
- GitHub keeps evaluating workflow-level `concurrency` with the `github` context, including `github.event.action` and `github.run_id`.

---

## Implementation Units

### U1. Workflow gates and concurrency

- **Goal:** `check.yml` implements R1–R7.
- **Requirements:** R1–R7, KTD1, KTD2, KTD3.
- **Dependencies:** none.
- **Files:** `.github/workflows/check.yml`.
- **Approach:**
  1. Replace the workflow-level `concurrency.group` with the KTD1 expression.
  2. Rewrite the six closure gates to the KTD2 allow-list, keeping the docs-only conjunct.
  3. Add the "not `labeled`" conjunct to `flake-check`, `check-shard-names`, `check-shards`, and `markdown-lint`, and give `fmt` an `if` with the same condition.
  4. Narrow `changes` per KTD3.
  5. Keep the comment above `markdown-lint` accurate.
- **Patterns to follow:** existing quoted `if:` strings with `!cancelled()` prefixes.
- **Test expectation:** covered by U2; this unit has no test file of its own.
- **Verification:** `actionlint` passes and U2's truth table holds against the file.

### U2. Behavior-level policy test

- **Goal:** `ci-workflow-docs-skip` fails for any gate or group change that breaks R1–R7.
- **Requirements:** R1–R7, KTD4, KTD5.
- **Dependencies:** U1.
- **Files:** `tests/check-workflow-docs-skip.sh`, `flake.nix` (add `actionlint` to the check's inputs and run it on `check.yml`).
- **Approach:**
  1. Extend `evaluate()` with `action` and `label.name` inputs, passing an empty action for `push` and `workflow_dispatch`.
  2. Add a small evaluator for the concurrency group that handles `format()`, `&&`, and `||`.
  3. Collect the truth table and group checks into one behavior function and run it on the real workflow.
  4. Drop the exact-string `if` comparisons from `policy()`, keeping its structural checks (triggers, `needs`, matrix wiring, script contents). Judge every mutant by the behavior function alone, and report it as surviving when that function accepts it.
  5. Replace the assertion that an unrelated label with `full-ci` present runs closure jobs; it now must not.
- **Patterns to follow:** the existing mutation loop and the `actionlint` call in the `update-dependencies-reconcile` check in `flake.nix`.
- **Test scenarios:**
  - Covers AE1. `opened` with `full-ci` on a non-docs PR: light jobs and `changes` true, closure jobs false.
  - `labeled` with label `full-ci`: closure jobs and `changes` true, light jobs and `fmt` false.
  - Covers AE2. `labeled` with label `bug` while the PR carries `full-ci`: every job false, `changes` included.
  - Covers AE4. `labeled` with label `bug` and `changes` result `skipped`: closure jobs false.
  - `synchronize` and `reopened` with `full-ci`: all jobs true. Without the label: closure jobs false.
  - `push` and `workflow_dispatch` with every `changes` result: light and closure jobs true.
  - Docs-only PR, `labeled` `full-ci`: closure jobs false, `markdown-lint` false.
  - Group: two `labeled` runs on one ref get different groups, `labeled` and `synchronize` differ, two `synchronize` runs share one, and `push` on `main` matches today's group.
  - `cancel-in-progress` is `true`.
  - Mutants that must fail: group without the `run_id` suffix, group without the action condition, `cancel-in-progress: false`, closure gate that admits `opened`, closure gate that drops the label-name check (the `38e954d` shape), light gate without the label conjunct, `fmt` without its `if`, `changes` running on every label.
- **Verification:** the check passes on U1's workflow, and reverting U1's file to `main` makes it fail.

### U3. Readiness rules in AGENTS.md

- **Goal:** `AGENTS.md` matches the new CI behavior (R8).
- **Requirements:** R8.
- **Dependencies:** U1.
- **Files:** `AGENTS.md`.
- **Approach:**
  1. In the CI paragraph, say that adding `full-ci` starts a separate run with only the closure jobs, and that `opened` runs never include them.
  2. In the readiness rule, require each closure job to succeed in some run on the head when `full-ci` is set; a skipped copy of the same job in another run does not count against it.
  3. In the PR-watching paragraph, list label runs among the runs that must be terminal.
- **Test expectation:** none -- documentation; the `agent-instructions` check reads `AGENTS.md` and must still pass.
- **Verification:** the three paragraphs agree with the High-Level Technical Design table.

---

## Verification Contract

| Gate | Command | Applies to |
| --- | --- | --- |
| Format | `nix fmt -- --ci` | U2 (`flake.nix`) |
| Workflow policy | `nix build --no-link .#checks.x86_64-linux.ci-workflow-docs-skip` | U1, U2 |
| Instruction inputs | `nix build --no-link .#checks.x86_64-linux.agent-instructions` | U3 |
| Markdown | `markdownlint-cli2` on changed Markdown | U3, plan |
| Whitespace | `git diff --check` | all |
| Live behavior | On the PR, with `full-ci` added: no cancelled run on the head, the label run shows only closure jobs, every run green | U1 |
| Empty label run | Add an unrelated label to the PR and record the run's conclusion | KTD3 |

## Definition of Done

- R1–R8 hold, and U2's mutants all fail.
- The PR's head has no cancelled run after `full-ci` is added, and the full CI evidence `AGENTS.md` requires is green.
- The unrelated-label run's conclusion is recorded in the PR body.
- No abandoned-attempt code or commented-out gates remain in the diff.
