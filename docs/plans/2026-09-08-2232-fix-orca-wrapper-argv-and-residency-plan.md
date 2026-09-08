---
title: Orca Wrapper Argv Routing and Residency Clause - Plan
type: fix
date: 2026-09-08
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Orca Wrapper Argv Routing and Residency Clause - Plan

## Goal Capsule

- **Objective:** A user on a managed Linux host keeps a working GNOME screen reader — the accessibility autostart still speaks — while an agent on that host still reaches the Orca IDE CLI, and an unattended run can no longer close while a dispatched worker it cannot prove was reclaimed is still unaccounted for.
- **Means:** Route the `~/.local/bin/orca` wrapper by argv shape, restate the Linux `orca-ide` rule's reason, and split the residency clause's release receipt into proven and unproven branches (KTD1, KTD2, KTD3).
- **Authority hierarchy:** The three GitHub issues (#440, #441, #442) define scope. `.ci/` gates are the acceptance signal. Repository `AGENTS.md` and the shared instruction core govern how the change is made.
- **Stop conditions:** Stop and report if a `.ci/` gate cannot be made to pass without weakening its assertions, or if an Orca IDE CLI invocation this repository or Orca itself authors turns out to be flags-first, which the argv-shape rule sends to the screen reader.
- **Execution profile:** Small, gate-backed change across one shell script, one instruction template, two CI gates, and one records document. Every unit is verified by running its gate.
- **Tail ownership:** One branch, one PR closing all three issues.

---

## Product Contract

### Summary

Three changes ship together. The `orca` command wrapper stops forwarding every invocation to the Orca IDE CLI and instead routes by the shape of its arguments, so a screen-reader launch reaches `/usr/bin/orca`. The Linux `orca-ide` rule in the shared instruction core keeps its instruction but states a reason that is still true after the wrapper exists. The Orca dispatch residency clause stops treating a `retained` release receipt as unconditionally sufficient, and the observed `identity_unproven` behavior is drafted as a third upstream Orca report.

### Problem Frame

PR #439 deployed `~/.local/bin/orca` ahead of `/usr/bin` in PATH so a dispatched agent that runs the bare `orca` command Orca writes into its own worker preamble reaches the Orca IDE CLI instead of starting speech. The wrapper forwards unconditionally, so the shadow is not scoped to agent terminals: a `.desktop` entry with `Exec=orca`, a GNOME accessibility autostart, or an assistive-technology toggle resolves through PATH and reaches the wrapper too. A user who needs the screen reader loses it (#440, CWE-426).

The same PR left two smaller defects. The Linux executable rule justifies itself with "bare `orca` … is the GNOME screen reader", which the wrapper made false on exactly the hosts the rule governs; an agent that can observe a rule's reason to be false will discount the rule (#441). And the dispatch residency clause counts "a receipt that reclaimed no process" as satisfying the run's release obligation. Across the three runs that produced #439, `worker-release` returned `retained` / `identity_unproven` / `processAction: none` for 5 of 14 dispatches. That clause is permissive in precisely the direction that would hide a leaked worker (#442).

### Requirements

**Wrapper routing (#440)**

- R1. When the wrapper is invoked with no arguments, it runs the GNOME screen reader.
- R2. When the wrapper's first argument begins with `-`, it runs the GNOME screen reader.
- R3. When the wrapper's first argument is a bare word, it runs the Orca IDE CLI, resolved through the existing candidate order.
- R4. The wrapper forwards every argument unaltered, including arguments containing spaces.
- R5. When argv names the Orca IDE CLI and no Orca IDE CLI is found, the wrapper fails with a diagnostic naming the candidates it tried, and does not start the screen reader.
- R6. When argv names the screen reader and no screen reader is found, the wrapper fails with a diagnostic naming the path it tried.
- R7. The wrapper never resolves `orca` through PATH, so it cannot recurse into itself.

**Instruction core (#441, #442)**

- R8. The Linux executable rule still requires agents to name `orca-ide` and still takes precedence over skill defaults, and its stated reason names `/usr/bin/orca` and PATH-order dependence rather than the bare command name.
- R9. A release receipt that reports the worker released settles that dispatch on its own.
- R10. A release receipt that retains the worker, or reclaims no process, does not settle the dispatch on its own: the run must read the receipt's retention reason and make one Orca-side query of that dispatch's state.
- R11. When the query reports the dispatch still active, the run issues the guide's stop for that dispatch and queries once more.
- R12. A host process sweep over the agent CLI's process name stays a secondary signal, unchanged.
- R15. A retention Orca bound to a proven identity — a recorded user takeover, a reused or pre-existing terminal, a retention the run itself requested — is settled once the query reports the dispatch no longer active.
- R16. A retention Orca could not bind to a process is never settled by that query: the run records the dispatch id, the verbatim receipt, and the query's verbatim output as an unproven release with its other gaps, and proceeds. The clause never blocks a run.
- R17. The run may record an unproven release in place of the query only after the query itself failed, and then records the command it ran and that command's verbatim error.

**Records and gates**

- R13. The `identity_unproven` release behavior is drafted as a third proposed upstream Orca report alongside the two already in `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md`, and that file's statement of the #439 trade-off is corrected to match the wrapper's new behavior.
- R14. `.ci/test-orca-cli-shadow.sh` and `.ci/test-agent-instructions.sh` both pass and assert the new behavior. No existing assertion is weakened to accommodate the change; assertions that describe superseded behavior are replaced by assertions of the new behavior.

### Key Decisions

- **Accessibility wins ties in the wrapper.** An argv shape the wrapper cannot confidently attribute to the Orca IDE CLI goes to the screen reader. Governs R1, R2.
- **An unprovable release is recorded, never blocking.** #442 asks for a stricter clause that stays satisfiable; a clause that can stall an unattended run is not satisfiable. Governs R11, R16, R17.
- **The host-wide PATH shadow is kept, not replaced.** Rejected: dropping `~/.local/bin/orca` in favour of Orca's own `~/.config/orca/linux-orca-cli-shim/orca` plus the upstream `compatibilityCliCommand` fix already drafted as Defect 2. That shim sits after `/usr/bin` in PATH, so it never wins, and the upstream fix is not ours to land; the shadow stays until Orca stops emitting bare `orca`. Governs R3.

### Scope Boundaries

- Out of scope: changing how Orca itself spells the command in its worker preamble. That stays an upstream report.
- Out of scope: rewriting `docs/plans/2026-09-08-2137-fix-orca-dispatch-review-contract-plan.md`. It is a historical decision artifact; git holds the history.
- Out of scope: any change to the `orca-wrapper` command-manifest unit in `.chezmoidata/commands.yaml`. Its platform gating and command name are already correct.

### Sources

- `dot_local/share/chezmoi-command-sources/executable_orca` — current unconditional forward.
- `.ci/test-orca-cli-shadow.sh` — wrapper gate; drives every branch through documented overrides.
- `.ci/test-agent-instructions.sh:linux_rule` — `grep -Fx` needle pinning the sentence R8 changes.
- `.chezmoitemplates/agents-instructions.tmpl:24` (Linux rule) and `:35` (dispatch contract).
- `orca-ide --help` on this host: every top-level entry is a bare subcommand word (`orchestration`, `skills`, `worktree`, `open`, `status`, …).
- `orca --help` (GNOME Orca 4x): every option is a flag (`-h -v -r -s -l -p -i --speech-system --debug-file --debug`); the screen reader accepts no positional argument.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Route by argv shape, not by a subcommand allowlist.** The wrapper treats a first argument that does not begin with `-` as an Orca IDE CLI subcommand and everything else as a screen-reader launch. Rejected: a hardcoded list of Orca IDE subcommands — it goes stale whenever Orca adds a subcommand, and staleness fails in the hazardous direction, sending a real agent command to the screen reader. The rule's bound is one-sided: GNOME Orca accepts no positional argument, so a bare-word first argument is unambiguously an Orca IDE CLI subcommand and cannot become ambiguous later. The converse does not hold — `orca-ide --version` and `orca-ide --help` both succeed, so a flags-first Orca IDE CLI invocation is routed to the screen reader by design, under the accessibility-wins-ties decision. Governs R1, R2, R3.
- KTD2. **An Orca-IDE-shaped invocation with no Orca IDE CLI is an error, not a screen-reader fallback.** The incident #439 records is exactly `orca orchestration send …` reaching the screen reader. Preserving that fallback would preserve the incident. The screen-reader fallback survives only for screen-reader-shaped argv, where it is the correct target. This replaces the current gate assertion that a missing Orca IDE CLI falls through to the system `orca`. Governs R5.
- KTD3. **The residency clause splits the receipt by whether Orca could bind the retention to a process, and asks Orca, not the host.** `worker-show` answers for a retained dispatch, and the receipt names its own retention reason, so the split is decidable. A retention Orca bound to an identity is settled by an inactive-dispatch answer; a retention Orca could not bind is recorded as unproven no matter what that answer says, because a dispatch record Orca could not tie to a process carries no information about that process. Rejected: requiring a host-level process check, which #442 itself notes cannot separate this run's workers from another session's. Governs R9, R10, R11, R15, R16, R17.

  Evidence is this plan's own review run, not the never-done peer #442 describes. `worker-release` on a supervised `--worktree current` dispatch returned `{"state":"retained","processAction":"none"}` immediately after a succeeded `worker_done`. `worker-show` on that same dispatch answered `status: completed`, `stage: settled`, with `capability_revoked_at` set and the created agent terminal still listed under `residual_resources`. A second `worker-release` returned `retained` with `reason: user_takeover`. So the query answers, the receipt distinguishes a bindable retention from an unprovable one, and an inactive dispatch record can coexist with a live terminal.
- KTD4. **The instruction sentence and its two gate literals change in one edit.** `.ci/test-agent-instructions.sh` pins the Linux rule with `grep -Fx` against `linux_rule`, and separately fails when the literal `GNOME screen reader` appears in the darwin render. That phrase exists nowhere else in the template, so a rewording that drops it leaves the darwin-leak assertion passing while asserting nothing. Both literals move together. The new dispatch-contract clauses get their own added needles rather than replacing the surviving `…requested and receipted` needle. Governs R8, R14.

### Assumptions

- The wrapper shadows `orca` for every process on the host, not only for this repository's agents, so a flags-first Orca IDE CLI invocation authored elsewhere is routed to the screen reader with no diagnostic. This is accepted: the strings that motivated the wrapper — Orca's own queued-message pointer and injected worker preamble — are `orca orchestration …`, both subcommand-first, as are this repository's `orca skills get …`. `orca-ide` remains the spelling agents are instructed to use, so a flags-only need is served there.
- The chezmoi wrappers (`dot_claude/readonly_CLAUDE.md.tmpl` and peers) include `agents-instructions.tmpl` by `includeTemplate` and hold no copy of the changed sentences, so editing the template is the whole edit. Verified: each wrapper is a single `includeTemplate` line.

### Sequencing

U1 and U2 are independent. U3 depends on U1 (it records the wrapper's new argv-shape behavior) and on U2 (it records the tightened residency clause as Defect 3's local mitigation). Run U4 last as the whole-repo gate sweep.

---

## Implementation Units

### U1. Route the orca wrapper by argv shape

- **Goal:** The wrapper sends screen-reader-shaped invocations to `/usr/bin/orca` and subcommand-shaped invocations to the Orca IDE CLI.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7 (KTD1, KTD2).
- **Files:** `dot_local/share/chezmoi-command-sources/executable_orca`, `.ci/test-orca-cli-shadow.sh`.
- **Approach:** Classify argv first: screen-reader-shaped when `$# -eq 0` or `$1` starts with `-`, otherwise Orca-IDE-shaped. For the Orca IDE branch, keep the existing candidate order (`$ORCA_IDE_CLI`, `$HOME/.local/bin/orca-ide`, `${ORCA_PREFIX:-/opt/Orca}/resources/bin/orca-ide`) and the `-x` test; on no hit, fail 127 with the tried candidates. For the screen-reader branch, resolve `${ORCA_SYSTEM_ORCA:-/usr/bin/orca}` only; on no hit, fail 127 naming it. `exec` the resolved target with `"$@"` unchanged. Rewrite the file's header comment so it states the new routing rule and why it exists; drop the sentence describing the retired unconditional forward.
- **Test scenarios** (all in `.ci/test-orca-cli-shadow.sh`, using the existing stub/override harness):
  - `orchestration check --run run_x 'two words'` with the HOME candidate present runs the HOME stub, forwards exactly 5 arguments, and preserves `two words` as one argument.
  - With the HOME candidate hidden, the same argv runs the prefix stub; with `ORCA_IDE_CLI` set, it runs the explicit stub; with the HOME candidate `chmod 000`, it runs the prefix stub.
  - No arguments at all runs the system-orca stub.
  - `--version` runs the system-orca stub; `-r` runs the system-orca stub.
  - `orchestration check` with both Orca IDE candidates hidden exits non-zero, does **not** run the system-orca stub, and names both hidden candidate paths in stderr.
  - No arguments with `ORCA_SYSTEM_ORCA` pointing at an absent path exits non-zero and names that path.
  - With the wrapper's own directory first on PATH, `orchestration check` does not recurse (`timeout`-124 assertion, re-driven onto the Orca IDE branch).
  - With the wrapper's own directory first on PATH and `ORCA_SYSTEM_ORCA` pointing at the system stub, a no-argument invocation runs the stub and `timeout` does not report 124, so R7 is asserted on the screen-reader branch too.
  - The command manifest still declares `orca` for the `orca-wrapper` unit on linux, not on darwin, and the unit identity still matches the wrapper's sha256 (existing assertions, unchanged).
- **Verification:** `.ci/test-orca-cli-shadow.sh` prints `orca cli shadow gates passed`. `shellcheck dot_local/share/chezmoi-command-sources/executable_orca`.

### U2. Restate the Linux rule and tighten the residency clause

- **Goal:** The shared instruction core carries a true reason for the `orca-ide` rule and a residency clause that a `retained` receipt no longer satisfies on its own.
- **Requirements:** R8, R9, R10, R11, R12, R15, R16, R17 (KTD3, KTD4).
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`.
- **Approach:** Replace the single line inside the `{{ if eq .ctx.chezmoi.os "linux" }}` branch with one unwrapped sentence pair that keeps the MUST and the precedence clause and moves the reason onto `/usr/bin/orca` and PATH order. Copy that exact string into the gate's `linux_rule` variable, and in the same edit re-point the gate's darwin-leak sentinel — currently the literal `GNOME screen reader` — at a distinctive phrase the rewritten sentence actually contains, so that assertion cannot go vacuous. In the dispatch-contract paragraph, replace `counting a receipt that reclaimed no process as satisfying that` with the branch rule the requirements state: a receipt reporting the worker released settles the dispatch; a receipt that retains the worker or reclaims no process makes the run read the receipt's retention reason and query the dispatch's state once; a query reporting the dispatch still active makes the run stop that dispatch and query once more; a retention Orca bound to an identity is settled by an inactive answer, a retention Orca could not bind is recorded as an unproven release regardless of the answer, and a query the run could not make is recorded the same way only after that query itself failed. Keep the surviving needle text `MUST confirm that every dispatch it started is settled and that its release was requested and receipted` and the process-sweep sentence verbatim. Add positive needles for each new branch to the `NEEDLES` heredoc; the paragraph is one long line, so needles are the only granular assertion available.
- **Test scenarios** (all in `.ci/test-agent-instructions.sh`):
  - The Linux render of all three harness wrappers contains the new `linux_rule` as a whole line (`grep -Fx`).
  - The darwin render contains the non-Linux rule and does not contain the re-pointed Linux-only sentinel.
  - The Linux and darwin renders are identical outside their executable rule.
  - Each render contains one needle per new residency branch — query-once, stop-and-requery, bindable-retention-settles, unbindable-retention-recorded, observed-failure-before-recording — and still contains the surviving `…requested and receipted` and process-sweep needles.
  - The three harness renders still differ only in their `This harness is ` paragraph, and each harness-owned needle is present in its own render and absent from the others (existing assertions, unchanged).
- **Verification:** `.ci/test-agent-instructions.sh` prints `agent instruction gates passed`.

### U3. Record the identity_unproven defect and correct the trade-off note

- **Goal:** The upstream-report drafts cover the release-receipt defect, and the file's account of the #439 trade-off matches what the wrapper now does.
- **Requirements:** R13.
- **Files:** `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md`.
- **Approach:** Add "Defect 3 — a `retained` release receipt does not say whether anything is still resident" in the shape the two existing defects use. Observed: the verbatim `retained` / `identity_unproven` / `processAction: none` JSON, 5 of 14 dispatches across the three runs that produced #439, plus this plan's own review run, where a supervised `--worktree current` dispatch released as `retained` / `processAction: none` right after a succeeded `worker_done`, `worker-show` answered `status: completed` / `stage: settled` with `capability_revoked_at` set while still listing the created agent terminal under `residual_resources`, and a second release returned `retained` with `reason: user_takeover`. Local mitigation: the tightened residency clause from U2. Proposed report: ask that the receipt always name its retention reason and separate "nothing to reclaim" from "could not prove identity", and that a `--worktree current` dispatch be bindable by the worktree identity Orca already recorded in `start_options`. Then rewrite Defect 2's whole Local mitigation paragraph so every sentence describes the implemented wrapper: argv-shape routing rather than an unconditional forward, no claim that it delegates to the screen reader on a host with no Orca IDE, and the pointer to the originating plan kept as history.
- **Test expectation: none — documentation-only unit with no gate of its own.** Its correctness is reviewed, not executed.
- **Verification:** Every sentence in Defect 2's Local mitigation paragraph describes the wrapper's implemented routing, and Defect 3 states its observations with the verbatim receipts.

### U4. Repository gate sweep

- **Goal:** The branch leaves every affected gate green.
- **Requirements:** R14.
- **Files:** none (verification only).
- **Approach:** Run the two directly affected gates, then the render and manifest gates that read the same sources, so a template or wrapper edit cannot break a neighbour unseen.
- **Test expectation: none — verification unit.**
- **Verification:** `.ci/test-orca-cli-shadow.sh`, `.ci/test-agent-instructions.sh`, `.ci/test-command-manifest.sh`, `.ci/test-command-external-render.sh`, and `.ci/test-ci-wiring.sh` all pass. `shellcheck` clean on both edited shell files.

---

## Verification Contract

| Command | Applies to | Signal |
|---|---|---|
| `.ci/test-orca-cli-shadow.sh` | U1 | `orca cli shadow gates passed` |
| `.ci/test-agent-instructions.sh` | U2 | `agent instruction gates passed` |
| `.ci/test-command-manifest.sh` | U1 | exits 0 |
| `.ci/test-command-external-render.sh` | U1 | exits 0 |
| `.ci/test-ci-wiring.sh` | U1, U2 | exits 0 |
| `shellcheck dot_local/share/chezmoi-command-sources/executable_orca .ci/test-orca-cli-shadow.sh .ci/test-agent-instructions.sh` | U1, U2 | no findings |

GitHub Actions `ci.yml` runs both primary gates (lines 72 and 123); the branch is not done until that workflow is green.

## Definition of Done

- Every requirement R1–R17 holds.
- Every command in the Verification Contract passes locally, and the GitHub Actions run on the pushed branch is green.
- The wrapper's header comment describes the routing rule that is actually implemented.
- No gate assertion was deleted to make a gate pass; assertions of superseded behavior were replaced by assertions of the new behavior, and the new behavior is covered.
- No dead-end or experimental code remains in the diff.
- One PR closes #440, #441 and #442 with a `Closes #N` keyword on each.

### Per-unit done

| Unit | Done when |
|---|---|
| U1 | The wrapper routes by argv shape and `.ci/test-orca-cli-shadow.sh` asserts every branch in the Test Scenarios list. |
| U2 | The template carries both new clauses and `.ci/test-agent-instructions.sh` pins them. |
| U3 | Defect 3 is drafted and Defect 2's mitigation paragraph matches the wrapper's behavior. |
| U4 | Every Verification Contract command passes. |
