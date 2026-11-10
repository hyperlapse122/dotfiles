---
title: "A compound condition's clause-by-clause assertion misses connective mutations"
date: 2026-09-23
category: best-practices
module: "CI workflow gating (check.yml docs-only skip)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Writing or reviewing a check that asserts a multi-clause boolean condition (a GitHub Actions if:, a guard, a compound comparison) by testing for each clause's presence independently"
  - "The condition joins its clauses with || or && and getting that connective wrong would invert or collapse what the condition actually decides"
  - "A check has been mutation-tested by removing or altering individual clauses, but never by changing the operator joining them"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - decorative-assertions
  - boolean-logic
  - github-actions
  - shell-tests
---

# A compound condition's clause-by-clause assertion misses connective mutations

## Context

`tests/check-workflow-docs-skip.sh` guards `check.yml`'s docs-only CI skip: the gated jobs in `check.yml` (`flake-check`, `hosts`, `build`, `build-linux`, `build-darwin`, and the shard and VM-check jobs; `flake-check` and `build` at the time) must run on any non-`pull_request` event, or when the classifier job did not succeed, and skip only on a definitive `docs_only:true` — three clauses joined by `||` inside one `if:` string. The first version of `assert_gated` asserted this by checking, with three independent `grep -qF` calls, that each clause's text appeared somewhere in the `if:` line:

```sh
if ! printf '%s' "$if_line" | grep -qF "github.event_name != 'pull_request'"; then fail ...; fi
if ! printf '%s' "$if_line" | grep -qF "needs.changes.result != 'success'"; then fail ...; fi
if ! printf '%s' "$if_line" | grep -qF "needs.changes.outputs.docs_only != 'true'"; then fail ...; fi
```

It was mutation-tested against removing `needs:`, dropping the fail-open clause, and adding a stray `if:` to an unconditional sibling job — and caught all three. It was not tested against changing how the clauses are joined, and a later adversarial code-review pass found that gap: swapping the internal `||` for `&&` inverts the condition from "run except when definitively docs-only" to "run only when all three unlikely things hold at once" — false on every ordinary `pull_request` event, silently disabling both jobs — and every clause's literal text is still present in the mutated line, so all three `grep` checks still passed and the test printed all-ok.

## The practice

**When a check asserts a compound boolean condition, assert the whole expression as one fixed string, connectives included — not each clause independently.** Three passing substring checks prove three clauses are present; they say nothing about whether `||` and `&&` are the ones actually joining them. This is a level the two sibling mutation-testing learnings before it don't reach: [decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) is about an assertion that cannot fail at all, and [an unconditionally set option](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) is about an operand no mutation can change. Here every assertion can fail, and the operand does vary — the gap is that the assertions decompose a *conjunction of independent facts* out of a claim that is actually about *how those facts are combined*.

```sh
expected="!cancelled() && (github.event_name != 'pull_request' || needs.changes.result != 'success' || needs.changes.outputs.docs_only != 'true')"
if ! grep -qF -- "$expected" <<<"$if_line"; then
  fail "job '$job' if: does not match the expected fail-open condition exactly; got: $if_line"
fi
```

The line goes in through a here-string rather than `printf | grep -q` because `grep -q` exits at the first match and, under `pipefail`, the upstream `printf` can then report a failure that reads as a miss; see [the pipefail miss](../logic-errors/printf-pipe-grep-q-under-pipefail-reports-a-miss.md).

One fixed-string match spanning both `||` operators fails the instant either one becomes `&&`, because the mutated line no longer contains that exact substring anywhere.

## What was verified

Each round is `bash tests/check-workflow-docs-skip.sh .github/workflows/check.yml` against a temporary edit to `check.yml`, restored afterward.

| Round | Mutation | Three independent substring checks | One whole-expression match |
| --- | --- | --- | --- |
| Baseline | none | ok | ok |
| Swap `\|\|` for `&&` in `flake-check`'s `if:` | inverts the fail-open condition to practically-always-false | **ok — false pass** | fails: "does not match the expected fail-open condition exactly" |
| Restore | — | ok | ok |

In the middle row the mutation reached the code under test, the assertions ran, and the old version still printed all-ok for every one of them.

## How to apply

- Before trusting a check that asserts a condition with more than one clause, name the connective in plain words ("must skip only when all three hold," "must run when any one holds") and ask whether your assertions could still pass if that connective were the other one.
- Prefer one exact match (string equality, or a single fixed-string `grep -qF` spanning every clause and connective) over N independent per-clause checks whenever the condition's meaning depends on how the clauses combine.
- If the full expression is long enough that an exact match feels unwieldy, that is a signal to extract the condition to a named, independently testable unit (a script, a reusable expression) rather than to keep testing its clauses piecemeal.
- Run the connective-swap mutation (`||` <-> `&&`) explicitly as one of your standard rounds whenever the check under test has more than one clause — it is cheap and it is exactly the round a clause-by-clause assertion style cannot catch.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion's shell cannot fail at all; here every assertion can fail, but not for the reason that matters.
- [An assertion on an unconditionally set option compiles to a constant](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) — the operand cannot vary; here it varies per clause, just not in the dimension (the connective) that decides the outcome.
- [A nullable option reaches a shell comparison as an empty word](nullable-option-empty-operand-passes-a-shell-comparison.md) — the closest sibling in spirit: both pass a mutation-testing suite that only moves the tested value within the range a reviewer thinks to try, and both are found only by asking what the type or structure additionally admits.

## Out of scope

This check is plain bash/awk against a GitHub Actions YAML file, not a Nix derivation — the pattern generalizes to any test that decomposes a compound boolean condition, Nix-based or not. Whether GitHub Actions' own `if:` evaluator has bugs in its `||`/`&&` precedence is out of scope; the risk here is entirely in how the *test* verifies the *authored* condition.
