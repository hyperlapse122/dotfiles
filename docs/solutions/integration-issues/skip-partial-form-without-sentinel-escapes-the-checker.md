---
title: A skip.sh.tmpl Form That Emits No Sentinel Is Invisible to check-skip-declarations
date: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "a new skip.sh.tmpl call form passes CI on its first run without any change to check-skip-declarations.sh, which reads as the checker accepting it"
  - "a typo in a call form's script or site argument produces a state-record path nothing ever writes, and no CI check fails"
  - "a converged host keeps reporting itself unconverged through dotfiles-skips because its success path removed the wrong record"
root_cause: missing_validation
resolution_type: code_fix
severity: medium
tags:
  - chezmoi
  - skip-framework
  - skip-declaration
  - ci-gate
  - static-analysis
  - silent-pass
---

# A skip.sh.tmpl Form That Emits No Sentinel Is Invisible to check-skip-declarations

## Problem

`.ci/check-skip-declarations.sh` is the gate that makes the skip contract decidable: it renders every `run_once_` / `run_onchange_` script and reconciles what it finds against `.ci/skip-declaration-site-matrix.yaml`. It is easy to read that as "the checker validates `skip.sh.tmpl` call sites". It does not. It validates two specific things it can see in rendered shell, and a call form that emits neither is not checked at all — it is not rejected, it is not accepted, it is simply absent from the checker's world.

Adding `clear_record` as a fifth form made that concrete. The form emits one line and nothing else, so it sailed through CI untouched while carrying a `script` and `site` pair that nothing verified.

## Symptoms

- A new form is added and `.ci/check-skip-declarations.sh` passes with identical totals on the first run, with no checker change. That is the correct outcome and also the warning sign.
- `clear_record` is called with a `site` that no declaration writes. The rendered script removes a record that never exists, the real record survives the success path, and `dotfiles-skips` reports a converged host as blocked forever. Every suite stays green.
- The render-time gates in `home/.chezmoitemplates/skip.sh.tmpl:163-195` do not catch it either: they validate the form name, the identity charset and the direction/probe combination, none of which a wrong-but-well-formed `site` violates.

## What Didn't Work

- **Assuming the render-time `fail` guards were enough.** They check that each argument is *well formed*, never that the pair *names something real*. `install-devtools-ubuntu__dev-packages-not-instaled` passes the `^[A-Za-z0-9][A-Za-z0-9._-]*$` gate perfectly.
- **Assuming the site matrix covers it.** The matrix is keyed on declarations. A form that declares nothing has no row, so there is nothing for the existing reconciliation to compare against.
- **Leaving it to the behavioural suite.** `.ci/test-package-installer-verdict.sh` asserts `no_record` on the converged path, which does catch a mismatched pair — but only for the six sites its scenarios happen to drive. The seventh site added later has no such assertion until someone writes one, and nothing makes them.

## Solution

Give the sentinel-less form its own reconciliation pass, because it cannot ride on the existing one.

`.ci/check-skip-declarations.sh:361` matches the exact line the partial emits:

```python
RM_SKIPS = re.compile(r'^rm -f "\$\{XDG_STATE_HOME:-\$HOME/\.local/state\}/chezmoi/skips/([^"]+)" 2>/dev/null \|\| true$')
```

and the pass at `.ci/check-skip-declarations.sh:1079-1101` (loop at line 1082) recovers `<script>` and `<site>` from every such rendered line **outside a declared branch**, then requires the pair to name an owner and an instance the matrix knows. Three exclusions are deliberate:

| Excluded | Why |
|---|---|
| removal lines inside a declared branch | `done_here`, `not_applicable` and `harmless` emit the same `rm -f`, but each sits under a sentinel that the existing reconciliation already validates. Checking them twice would double-report one defect. |
| a path containing `$` | `home/.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl:212` builds its record name from a shell variable. A value resolved at runtime cannot be reconciled against a static matrix. |
| always-run scripts | the checker's existing lifecycle filter already excludes them, which is why `home/.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` and its two literal removals (lines 78, 83) never reach the pass. |

The proof is a negative fixture, not the production tree: `.ci/test-skip-declaration-gates.sh` renders a fixture whose `clear_record` names `fx-main/unknown-site` and asserts the checker fails with that pair in the message. Without it the pass is a claim rather than a guard — the production call sites are all correct, so a broken pass would look exactly like a working one.

Landed on branch `refactor/installer-skip-record-dedup` in commits `564bb4c0` (the form) and `aa73e5ee` (the reconciliation).

## Why This Works

The checker observes rendered shell through exactly two lenses, both visible in its own source:

- `SENTINEL` at `.ci/check-skip-declarations.sh:353` finds `# skip-declaration-v1 …` comment lines. Everything about owners, instances, predicates and continuations hangs off a sentinel match.
- `TERM_ANY` at `.ci/check-skip-declarations.sh:355` finds `exit` and `return` statements, which is how an undeclared conditional success exit is caught.

`clear_record` emits `rm -f …`. That is not a comment and not a terminator, so it raises no event in either lens, and every downstream structure — the owner map, the instance set, the predicate digests — is built from events. This is not an oversight in the checker; it is what let the form be added without touching it. The same property that made the form cheap to adopt is the property that left it unvalidated, and only a pass built on a third lens closes that.

## Prevention

- **When a `skip.sh.tmpl` form emits no sentinel and no terminator, it needs its own reconciliation pass.** The checker's silence on a new form means it is unchecked, never that it is approved. Ask which lens would see the new line before concluding CI covers it.
- **Prove a new CI pass with a fixture that fails.** A guard whose production inputs are all valid is indistinguishable from a guard that does nothing. `.ci/test-skip-declaration-gates.sh` exists for exactly this and already has the `variant` / `expect_finding` shape to copy.
- **Distinguish well-formed from real.** The partial's charset gates exist to make a value safe to interpolate into generated shell, which is a different question from whether the value names anything. Both checks are needed and neither implies the other.
- **A silent-pass guard earns the adversarial lens regardless of diff size.** This blind spot was raised independently by five reviewers of a change that had already passed its own test suite, because the change *was* a verification mechanism. Review a gate for whether it can go green while the thing it guards is red.

## Related

- `docs/solutions/integration-issues/chezmoi-run-onchange-entrystate-bucket.md` — the other half of the skip framework's recovery story: which state bucket actually re-runs an onchange script.
- `docs/plans/2026-09-18-0104-refactor-installer-skip-record-dedup-plan.md` — the plan that added the form, and whose Risks section recorded this blind spot before the reconciliation pass closed it.
- `home/.chezmoitemplates/skip.sh.tmpl` — the declaration contract and its five call forms; the header comment states which of them declare nothing.
- `.ci/skip-declaration-site-matrix.yaml` — the CI-only oracle the reconciliation compares against.
