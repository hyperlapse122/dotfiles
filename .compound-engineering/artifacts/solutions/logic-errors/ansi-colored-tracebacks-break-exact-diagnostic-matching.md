---
title: "ANSI colors break exact traceback matching in mutation evidence"
date: "2026-10-25"
last_updated: "2026-10-25"
category: logic-errors
module: "CI mutation evidence"
problem_type: test_failure
component: testing_framework
severity: medium
symptoms:
  - "A real owner assertion failed at the intended lifecycle guard, but the mutation job reported it uncaught"
  - "The expected traceback text appeared correct when rendered in the terminal"
root_cause: logic_error
resolution_type: test_fix
tags: ["mutation-testing", "ansi", "python", "ci", "diagnostic-matching"]
---

# ANSI colors break exact traceback matching in mutation evidence

## Problem

A temporary Linux mutation job rejected a valid printing regression result. The owner had refused unnecessary queue recreation, and its restored control passed, but the evidence matcher could not find the expected traceback.

The fix is verified in CI in [unmerged PR #342](https://github.com/hyperlapse122/nix-config/pull/342); merge remains pending. The temporary proof infrastructure is removed after capture, so this failure would otherwise be easy to repeat in a later campaign.

## Root cause

The raw Python traceback inserted ANSI CSI sequences between `AssertionError`, its colon, and the diagnostic tuple. A terminal rendered the expected sentence, while a regular expression over the raw bytes saw different text. Replacing the requirement with any nonzero exit would have accepted unrelated failures.

## Solution

Keep the raw transcript and its checksum. Normalize a separate view for diagnostic matching and excerpts:

```python
plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw_text)
```

For streamed logs, retain raw overlap between reads so a split escape sequence can be joined before normalization. Continue requiring the specific owner diagnostic, a nonzero mutant result, and a passing restored control. Store the readable excerpt beside the raw transcript hash and run identity.

The [proof run](https://github.com/hyperlapse122/nix-config/actions/runs/40121639574) retains the printing failure and full transcripts in its mutation artifacts. [PR #342](https://github.com/hyperlapse122/nix-config/pull/342) records the per-case diagnostics, baseline and restored outcomes, raw-log checksums, tested merge revision, and job/artifact links. All 40 mutation cases passed their intended-failure and restored-control requirements. Review artifacts were removed from the repository at the user's request.

## Prevention

Before relying on a diagnostic matcher, test a real colored failure, escape sequences crossing read boundaries, an unrelated negative log, and preservation of the original transcript checksum. Diagnostic normalization must not relax the assertion being proved.
