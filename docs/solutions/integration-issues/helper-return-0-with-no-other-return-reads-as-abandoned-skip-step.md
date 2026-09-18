---
title: A Helper Whose Only Explicit Return Is return 0 Reads as an Abandoned Skip Step
date: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "check-skip-declarations.sh reports \"undeclared conditional success exit (return 0) — declare it through skip.sh.tmpl\" on a line that has nothing to do with the package-installer failure policy or any skip site"
  - "the flagged return 0 is inside an ordinary helper function's guard clause (an early return, or a compute_* function's absent-dependency branch), not a top-level script exit"
  - "removing the early return and rewriting the guard as an if/else, or folding it into the caller's own if condition, makes the finding disappear with no matrix change"
root_cause: missing_validation
resolution_type: code_fix
severity: low
tags:
  - chezmoi
  - skip-framework
  - skip-declaration
  - ci-gate
  - static-analysis
  - bash
---

# A Helper Whose Only Explicit Return Is `return 0` Reads as an Abandoned Skip Step

## Problem

`.ci/check-skip-declarations.sh` does not scope its undeclared-exit check to top-level, script-abandoning exits. It scans every rendered `run_onchange_`/`run_once_` script for `return`/`exit` tokens (`TERM_ANY`, `.ci/check-skip-declarations.sh:355`) and, for each `return`, asks whether the *enclosing function* ever also returns a nonzero literal or a computed status anywhere in its body (`verdict_functions`, `.ci/check-skip-declarations.sh:703-717`). A function that does is a "verdict function" — its return value is something the caller branches on, so a bare `return 0` inside it is legitimate. A function whose *only* explicit `return` is `return 0` is classified as "abandoning a step," and that exit must go through the `skip.sh.tmpl` declaration contract even though the function is an ordinary helper with no relationship to the skip framework.

## Symptoms

- Converting `run_onchange_before_30-tailscale.sh.tmpl`'s `install_tailscale` to the record-and-continue failure policy, an early-return guard clause (`if rpm -q tailscale; then clear_record; return 0; fi`) was flagged as an undeclared exit, even though the function's actual skip-step declaration a few lines later was correctly formed.
- Adding a `flatpak`-binary-absent guard to `compute_missing_flatpaks` as `if ! command -v flatpak; then missing_flatpaks=("${flatpaks[@]}"); return 0; fi` produced the same finding, on a helper that has never touched `skip.sh.tmpl`.
- Both findings disappeared with no matrix edit once the function was rewritten to have no bare early return at all.

## What Didn't Work

- **Assuming the finding was about the nearby `skip_step` declaration.** In both cases the actual declaration a few lines below was correctly registered; the flagged line was a *different*, unrelated `return 0` in the same function.
- **Declaring the guard-clause return through `skip.sh.tmpl` to silence the finding.** That would misrepresent an ordinary helper-function early return as a chezmoi skip site, adding a fake owner row for behavior the skip framework has no stake in.

## Solution

Give the function a second, real return path, or remove the bare return entirely — the check only cares whether the function's return value is a checked verdict; either fix works.

For `install_tailscale`, the two checks (already-installed guard, post-attempt verdict) were combined into a single condition rather than left as an early return:

```bash
# Flagged: return 0 is the only explicit return in the function
if ! rpm -q tailscale >/dev/null 2>&1; then
  # ... install attempt ...
fi
if ! rpm -q tailscale >/dev/null 2>&1; then
  if report_tailscale_missing; then
    # skip.sh.tmpl skip_step ...
  fi
fi
clear_tailscale_skip_record

# Clean: no bare early return, single compound verdict condition
if ! rpm -q tailscale >/dev/null 2>&1; then
  # ... install attempt ...
fi
if ! rpm -q tailscale >/dev/null 2>&1 && report_tailscale_missing; then
  # skip.sh.tmpl skip_step ...
fi
clear_tailscale_skip_record
```

For `compute_missing_flatpaks`, the early return became an `if`/`else`:

```bash
# Flagged
if ! command -v flatpak >/dev/null 2>&1; then
  missing_flatpaks=("${flatpaks[@]}")
  return 0
fi
# ... flatpak list based computation ...

# Clean
if command -v flatpak >/dev/null 2>&1; then
  # ... flatpak list based computation ...
else
  missing_flatpaks=("${flatpaks[@]}")
fi
```

Landed on branch `bugfix/remaining-installer-failure-policy` converting `run_onchange_before_30-tailscale.sh.tmpl` and `run_onchange_before_40-flatpaks.sh.tmpl` (issue #541).

## Why This Works

`verdict_functions` (`.ci/check-skip-declarations.sh:703-717`) collects, per enclosing function, every `(status, code)` pair its explicit `return` statements produce, then exempts a function only when at least one of those pairs is a computed expression or a nonzero literal — proof the caller reads the value as a verdict. A function with exactly one explicit `return`, and it is `return 0`, never produces such a pair, so it is treated the same as a script's own abandoned-step exit and routed into the declaration requirement. The check has no notion of "this function is unrelated to skip.sh.tmpl" — it only has "does this function's return carry meaning," and a lone `return 0` is indistinguishable, to a static scan, from a step quietly bailing out.

## Prevention

- **A helper's only early exit should not be a bare `return 0`.** Either give the function a real second return value the caller checks, or restructure the guard into the function's normal control flow (an `if`/`else`, or folding the guard into the caller's own compound condition) so there is no standalone `return 0` to flag.
- **When `check-skip-declarations.sh` flags a `return 0` that is not near any `skip.sh.tmpl` call, look at the whole enclosing function, not the flagged line.** The finding is about the function's return-value shape, not about the specific statement.
- **Do not declare an unrelated helper's return through `skip.sh.tmpl` to silence the checker.** That adds a matrix row for something that is not a skip decision at all, and misleads the next reader of the matrix.

## Related

- `docs/solutions/integration-issues/skip-partial-form-without-sentinel-escapes-the-checker.md` — the other blind spot in the same checker: a call form invisible to the `SENTINEL` lens rather than a false positive from the `TERM_ANY` lens this doc covers.
- `docs/plans/2026-09-18-2157-fix-remaining-installer-failure-policy-plan.md` — the plan whose implementation surfaced this.
- `.ci/check-skip-declarations.sh` — `TERM_ANY` (line 355) and `verdict_functions` (lines 703-717).
