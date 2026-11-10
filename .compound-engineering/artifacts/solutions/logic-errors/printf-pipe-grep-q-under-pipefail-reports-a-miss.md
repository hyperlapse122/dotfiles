---
title: "`printf … | grep -q` under pipefail reports a miss when grep matches early"
date: 2026-10-05
category: logic-errors
module: "Shell check scripts (tests/check-workflow-docs-skip.sh)"
problem_type: logic_error
component: testing_framework
severity: medium
symptoms:
  - "ci-workflow-docs-skip failed intermittently with \"printf: write error: Broken pipe\" followed by \"job 'markdown-lint' does not declare 'needs: changes'\""
  - "The asserted text was present in check.yml, and the next run against byte-identical files passed"
  - "A failed check in the dependency updater's verification made the whole updater run fail (run 37110317629)"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - development_workflow
tags:
  - pipefail
  - sigpipe
  - epipe
  - grep
  - here-string
  - flaky-check
  - check-workflow-docs-skip
  - flake-checks
---

# `printf … | grep -q` under pipefail reports a miss when grep matches early

## Problem

A shell check running under `set -o pipefail` tested multi-line text with `printf '%s\n' "$block" | grep -q PATTERN`. When the match was on an early line, the condition could come out false even though the pattern was present, so the check failed intermittently on a correct tree.

## Symptoms

- `ci-workflow-docs-skip` failed in the dependency-updater run 37110317629 with `printf: write error: Broken pipe`, then `job 'markdown-lint' does not declare 'needs: changes'`.
- The tree it checked (`cccdd13`) had `needs: changes` on the `markdown-lint` job, and `.github/workflows/check.yml` and the script were byte-identical through the next scheduled run, which passed.

## What Didn't Work

- Reading the failure as a real workflow regression. The asserted job did carry `needs: changes`; only the assertion's plumbing failed.
- Re-running to see it pass. The race depends on scheduling, so a green rerun proved nothing either way.

## Solution

Feed the text to `grep` with a here-string instead of a pipe, so no writer process exists to fail (the comment above `set -euo pipefail` in `tests/check-workflow-docs-skip.sh` records the reason; the here-string assertions follow the `needs_pattern` and `job_block` helpers):

```bash
# Before: a match on line 1 can still fail the condition
if ! printf '%s\n' "$block" | grep -qE "$pat"; then fail; fi

# After
if ! grep -qE "$pat" <<<"$block"; then fail; fi
```

Dropping `-q` (`grep PAT >/dev/null`), so grep reads all input, also avoids the race, but the here-string is simpler and starts no extra process.

## Why This Works

`grep -q` exits as soon as it finds a match. Bash's `printf '%s\n' "$block"` writes one line per `write()` (confirmed with `strace` this session), so when grep has already exited, the next write hits a closed pipe and fails with `EPIPE` (or the process takes `SIGPIPE`). `printf` then returns non-zero, and `pipefail` makes the pipeline's status that failure, so `if printf … | grep -q` reads as "no match". Whether printf still has lines left to write when grep exits depends on scheduling, which is why the failure is intermittent and why a match on the first line is the most exposed case.

A here-string has no writer process: bash hands grep the whole text on its stdin, so grep's own status is the only status.

Forced reproduction from this session: a 200,000-line block under `trap '' PIPE` failed the pipe form 20 of 20 times with the same two messages CI printed, and the here-string form 0 of 20. 400 parallel runs of the fixed script against the real `check.yml` with SIGPIPE ignored had no failures.

## Prevention

- In any script that sets `pipefail`, do not pipe a producer into a reader that can stop early (`grep -q`, `head`, `awk '…; exit'`) when the producer's status matters. Use a here-string, or a file the reader opens itself.
- When a check fails with `Broken pipe` next to an assertion message, suspect the assertion's plumbing before the asserted content.
- Another `pipefail` test still uses the pipe form: `tests/claude.nix`. They have not failed; convert one if a trace shows its piped input spans several writes.
- Reproduce a suspected race with a large input under `trap '' PIPE` before and after the fix, as above, rather than trusting a single green run.

## Related Issues

- `.compound-engineering/artifacts/solutions/logic-errors/pipe-to-tee-exit-status-reports-success-in-github-actions-step.md`: the opposite pipeline-status trap, where `$?` after `| tee` hides a failure instead of inventing one.
- `.compound-engineering/artifacts/solutions/best-practices/compound-condition-clause-assertions-miss-connective-mutations.md`: the same script's mutation rounds, which still pass after the here-string change.
- Issue #77 introduced `tests/check-workflow-docs-skip.sh`.
