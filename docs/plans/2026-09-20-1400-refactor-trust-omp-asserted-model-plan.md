---
title: "refactor(orchestration): trust omp's asserted model instead of verifying it per dispatch"
type: refactor
date: 2026-09-20
issue: 588
origin: https://github.com/hyperlapse122/dotfiles/issues/588
---

# refactor(orchestration): trust omp's asserted model instead of verifying it per dispatch

## Summary

When dispatching an `omp` worker in Orca orchestration, the lead currently performs an unnecessary check by reading the worker's status line via `worker-read` and matching the model name against `gemini-3.8-flash`, recording the pass as degraded on mismatch. The model is already rendered from `agents.roster` in `home/.chezmoidata/agents.yaml`, asserted into `~/.omp/agent/config.yml` by `run_after_config-omp-settings.sh.tmpl`, and pinned by `worker-start --agent omp`'s default arguments. This refactor removes the per-dispatch model check and its degraded branch from `home/.chezmoitemplates/orchestration-coordinator.tmpl` while preserving the post-launch `worker-read` used for unsubmitted paste recovery, aligns `AGENTS.md`, and updates the roster and instruction test suites.

## Problem Frame

In `home/.chezmoitemplates/orchestration-coordinator.tmpl:53`, the coordinator instructions state:

> The `worker-start` receipt does not report effective models for omp, so the lead checks the model name on the worker's own status line through `worker-read` against `{{ $ompImpl.model }}`; the thinking level is trusted from the default arguments the reconciler asserted. A missing or mismatched model records the pass as degraded.

This verification is redundant and inconsistent:
1. `agents.roster` is the single source of truth for the model and effort level.
2. The reconciler (`run_after_config-omp-settings.sh.tmpl`) asserts `~/.omp/agent/config.yml` on every apply, and Orca's default arguments for `omp` pin the model and thinking level.
3. The prompt already trusts the thinking level from those asserted default arguments without checking it; verifying the model name on the status line is an inconsistent exception.
4. Performing a string match against the status line per dispatch introduces unnecessary complexity, round trips, and false-positive degraded passes when status-line rendering formatting changes.

The first `worker-read` cannot be completely removed because it serves as the recovery detection mechanism for unsubmitted `[Paste #N +M lines]` blocks in the omp composer. The target of removal is strictly the model string comparison and the degraded status branch.

## Requirements

- R1. In `home/.chezmoitemplates/orchestration-coordinator.tmpl`, replace the status-line model check against `{{ $ompImpl.model }}` and the degraded branch (`missing or mismatched model records the pass as degraded`) with explicit trust of both the model and thinking level from the reconciler's asserted default arguments.
- R2. In `home/.chezmoitemplates/orchestration-coordinator.tmpl`, preserve the initial post-launch `worker-read` (`worker-read --dispatch <id> --source terminal`) for composer paste-block recovery, removing only the subordinate clause referencing model verification.
- R3. In `home/.chezmoitemplates/orchestration-coordinator.tmpl`, update the launch miss classification sentence from "A launch that yields no live seat with the confirmed model is not a failure of the Unit:" to "A launch that yields no live seat is not a failure of the Unit:".
- R4. In `AGENTS.md`, remove the clause `, and the lead checks the effective model through `worker-read` against the status line` from the omp dispatch description.
- R5. In `.ci/test-agent-roster.sh`, update the coordinator assertions to verify that both model and thinking level are trusted from reconciler default arguments, remove the positive degraded-pass assertion, and add negative assertions against the retired check phrases.
- R6. In `.ci/test-agent-instructions.sh`, update `CLAUDE_COORDINATOR_NEEDLES` to remove the status-line model check and degraded-pass needles, update the trusted-arguments needle to cover model and thinking level, and add negative assertions in the coordinator payload checks.
- R7. All CI tests (`.ci/test-agent-instructions.sh`, `.ci/test-agent-roster.sh`) pass cleanly.

## Key Technical Decisions

- KTD1. **Trust both model and thinking level from asserted reconciler defaults.** In `orchestration-coordinator.tmpl`, replace:
  `The \`worker-start\` receipt does not report effective models for omp, so the lead checks the model name on the worker's own status line through \`worker-read\` against \`{{ $ompImpl.model }}\`; the thinking level is trusted from the default arguments the reconciler asserted. A missing or mismatched model records the pass as degraded.`
  with:
  `The \`worker-start\` receipt does not report effective models for omp, so the model and thinking level are trusted from the default arguments the reconciler asserted.`
  This treats model selection and thinking level with identical trust guarantees rooted in apply-time configuration.
- KTD2. **Retain the post-launch seat read for paste recovery.** Line 53's sentence:
  `After \`worker-start\` returns \`ready\`, the lead reads the seat once with \`worker-read --dispatch <id> --source terminal\`, which is the same read that checks the model.`
  is streamlined to:
  `After \`worker-start\` returns \`ready\`, the lead reads the seat once with \`worker-read --dispatch <id> --source terminal\`.`
  This preserves the exact command required by issue #585 paste recovery and test `#585: coordinator does not read the omp seat terminal after launch`.
- KTD3. **Adjust launch-miss phrasing to remove "confirmed model".** The launch miss classification:
  `A launch that yields no live seat with the confirmed model is not a failure of the Unit:`
  becomes:
  `A launch that yields no live seat is not a failure of the Unit:`
  Since the model is no longer "confirmed" via status line, a launch miss is strictly an unstarted turn or dead seat after the second read.
- KTD4. **Add negative test assertions for retired phrases.** Ensure neither the coordinator template nor rendered instruction payloads regress by adding explicit `! grep -F` assertions in `.ci/test-agent-roster.sh` and `.ci/test-agent-instructions.sh` for `missing or mismatched model records the pass as degraded` and `checks the model name on the worker's own status line`.

---

## Implementation Units

### U1. Update orchestration coordinator template

**Goal:** Trust the model from default arguments and remove model-matching degraded branches in `home/.chezmoitemplates/orchestration-coordinator.tmpl`.
**Requirements:** R1, R2, R3
**Dependencies:** None
**Files:**
- `home/.chezmoitemplates/orchestration-coordinator.tmpl`
**Approach:**
1. In line 53, replace:
   `The \`worker-start\` receipt does not report effective models for omp, so the lead checks the model name on the worker's own status line through \`worker-read\` against \`{{ $ompImpl.model }}\`; the thinking level is trusted from the default arguments the reconciler asserted. A missing or mismatched model records the pass as degraded.`
   with:
   `The \`worker-start\` receipt does not report effective models for omp, so the model and thinking level are trusted from the default arguments the reconciler asserted.`
2. In line 53, change:
   `reads the seat once with \`worker-read --dispatch <id> --source terminal\`, which is the same read that checks the model.`
   to:
   `reads the seat once with \`worker-read --dispatch <id> --source terminal\`.`
3. In line 53, change:
   `A launch that yields no live seat with the confirmed model is not a failure of the Unit:`
   to:
   `A launch that yields no live seat is not a failure of the Unit:`
**Test scenarios:**
- Rendered coordinator payload contains `the model and thinking level are trusted from the default arguments the reconciler asserted.`
- Rendered coordinator payload contains `worker-read --dispatch <id> --source terminal`
- Rendered coordinator payload does NOT contain `checks the model name on the worker's own status line`
- Rendered coordinator payload does NOT contain `missing or mismatched model records the pass as degraded`
**Verification:**
- Rendering `home/.chezmoitemplates/orchestration-coordinator.tmpl` succeeds with no syntax errors.

### U2. Update repository agent instructions

**Goal:** Align `AGENTS.md` with the trusted-model policy by removing the status line check clause.
**Requirements:** R4
**Dependencies:** None
**Files:**
- `AGENTS.md`
**Approach:**
1. In `AGENTS.md` line 102, locate:
   `An omp dispatch starts in one command (\`worker-start --agent omp\`) with the roster model pinned by default arguments, and the lead checks the effective model through \`worker-read\` against the status line; that terminal serves that single dispatch and is released in the turn its dispatch settles, so \`modelRoles\` never decides which Gemini seat a dispatch receives.`
2. Replace with:
   `An omp dispatch starts in one command (\`worker-start --agent omp\`) with the roster model pinned by default arguments; that terminal serves that single dispatch and is released in the turn its dispatch settles, so \`modelRoles\` never decides which Gemini seat a dispatch receives.`
**Test scenarios:**
- `AGENTS.md` does not contain `checks the effective model through \`worker-read\` against the status line`.
- `AGENTS.md` preserves the single-dispatch terminal lifecycle and `modelRoles` explanation.
**Verification:**
- `git diff AGENTS.md` shows only the removal of the status line check clause.

### U3. Update CI test suites and add regression guards

**Goal:** Update `.ci/test-agent-roster.sh` and `.ci/test-agent-instructions.sh` to assert trusted model configuration and guard against retired phrases.
**Requirements:** R5, R6, R7
**Dependencies:** U1, U2
**Files:**
- `.ci/test-agent-roster.sh`
- `.ci/test-agent-instructions.sh`
**Approach:**
1. In `.ci/test-agent-roster.sh`:
   - Line 345: Update fail message from `AE4: coordinator does not describe status-line model check through worker-read` to `AE4: coordinator does not describe post-launch read through worker-read`.
   - Lines 354-355: Replace `grep -F 'missing or mismatched model records the pass as degraded'` with:
     ```bash
     grep -F 'the model and thinking level are trusted from the default arguments the reconciler asserted' "$coordinator_body" >/dev/null ||
       fail 'coordinator does not trust model and thinking level from reconciler default arguments'
     ! grep -F 'missing or mismatched model records the pass as degraded' "$coordinator_body" >/dev/null ||
       fail 'coordinator still carries retired missing/mismatched model rule'
     ! grep -F "checks the model name on the worker's own status line" "$coordinator_body" >/dev/null ||
       fail 'coordinator still carries retired status-line model check'
     ```
2. In `.ci/test-agent-instructions.sh`:
   - In `CLAUDE_COORDINATOR_NEEDLES`:
     - Remove `checks the model name on the worker's own status line through \`worker-read\``
     - Remove `missing or mismatched model records the pass as degraded.`
     - Replace `the thinking level is trusted from the default arguments the reconciler asserted.` with `the model and thinking level are trusted from the default arguments the reconciler asserted.`
   - In the coordinator payload loop (around line 670), add negative checks:
     ```bash
     if grep -F 'missing or mismatched model records the pass as degraded' "$payload" >/dev/null \
       || grep -F "checks the model name on the worker's own status line" "$payload" >/dev/null; then
       fail "$(basename "$payload") contains retired omp status-line model check rule"
     fi
     ```
**Test scenarios:**
- Run `.ci/test-agent-instructions.sh` and confirm success.
- Run `.ci/test-agent-roster.sh` and confirm success.
**Verification:**
- Both CI scripts exit 0 with clean outputs.
