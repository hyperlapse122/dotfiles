---
title: Orchestration Contract Bundle - Plan
type: feat
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/547
---

# Orchestration Contract Bundle - Plan

## Goal Capsule

- **Objective:** one pull request resolves issues #569, #558, #557, #550, and #547 as one orchestration-contract change. An Orca lead revises its own planning artifact inline, a judgment-row omp launch miss has a stated outcome, "seat" has one meaning, the omp launch paragraph says only what the CLI evidence supports, and an injected session can no longer start a harness subagent that Orca cannot see.
- **Means:** edit the coordinator payload template and move its needles (U1, U5); restore `guard` in `packages/orchestration-hook` as a real tool-call guard and put the skill re-entry instruction in the lead intro (U2); declare the guard for Claude Code and Codex and add the three regression cases (U3); block the omp `task` tool from the native extension (U4); align `AGENTS.md`, `CONCEPTS.md`, and the two package READMEs (U6).
- **Authority:** the issue acceptance criteria outrank any wording this plan proposes. `AGENTS.md` "Verification (never deploy live `$HOME`)" outranks any render shortcut. Every needle that `.ci/test-agent-instructions.sh` and `.ci/test-agent-roster.sh` assert today survives, except the needles this plan moves in the same unit as their sentence.
- **Execution profile:** instruction prose in one chezmoi template, TypeScript in two packages with no new dependency, two hook declaration templates, one trust template, and the gate scripts that pin them. The proof is the repository gates and the package test scripts, run locally.
- **Stop conditions:** stop and report if a pinned two-branch conditional string must change, if any needle outside the ones named here cannot survive, if the Codex `session_start` trust key or hash moves, or if the guard cannot be kept fail-open on every path.
- **Who finishes and ships:** this run implements, verifies, opens the pull request with `Closes #569, Closes #558, Closes #557, Closes #550, Closes #547`, and merges it once CI is green.

---

## Product Contract

### Summary

The coordinator payload gains five text changes. The lead revises the current workflow's plan or requirements document itself. A second omp launch miss on a judgment replacement records the pass as degraded and the review proceeds. The sizing sentence says "entry" where it means the roster entry. The omp launch paragraph names omp's `--model` and `--thinking` flags, says that `worker-start` delivers the prompt, and says why omp's non-interactive forms are not a dispatch path. The enforcement sentence of the lead-work paragraph is replaced to describe the guard.

The hook binary's `guard` subcommand stops being a no-op. In an Orca-managed session whose local payload files are staged, it denies the harness's own subagent tool and names the `orchestration` skill and the Orca dispatch path. It allows everything else and fails open. The lead intro carries the skill re-entry instruction on every SessionStart source, so the `compact` path and the `startup` path cannot diverge.

### Problem Frame

- **#569.** `home/.chezmoitemplates/orchestration-coordinator.tmpl` line 36 makes every repository deliverable a dispatch. A plan under `docs/plans/` is a deliverable after the elevation worker's first write, so each `ce-doc-review` fix, deepening synthesis, and handoff revision pays a worker launch for an edit of a few lines. The skills expect the orchestrator to edit the document in place.
- **#558.** Line 53 sends a second omp launch miss to "the row's unavailable column". For the judgment row, omp is that column, so the text names no outcome.
- **#557.** Line 53 defines a seat as the terminal of one Dispatch. Line 55 and `AGENTS.md` line 81 still use "seat" for a roster entry.
- **#550.** The omp launch costs a terminal launch, a model confirmation, and a `worker-start` call. The issue asks whether omp's CLI can remove steps.
- **#547.** After a compaction, an Orca lead calls the harness subagent tool directly. The payload is re-injected on `compact`, but the harness tool list is always present and wins. Nothing enforces the rule, and the payload says so: "No PreToolUse hook enforces any of this."

### Requirements

**Lead revisions (#569)**

- R1. The coordinator payload states that a revision of the current workflow's own plan or requirements document under `<docs_root>/plans/` or `<docs_root>/brainstorms/` is lead work, and that the lead makes that edit itself.
- R2. The elevation paragraph still sends the first plan authoring to the `authoring` worker, and a Unit the sizing cannot split still returns to that entry. Its text does not change.
- R3. The sentence that dispatches README, AGENTS, documentation prose, learnings, and glossary under the implementation row stays byte-identical.
- R4. `.ci/test-agent-instructions.sh` pins the new sentences, and every existing lead-work needle still passes.
- R5. `AGENTS.md` and `CONCEPTS.md` state the same boundary.

**Judgment-row launch miss (#558)**

- R6. For a judgment dispatch that an omp seat takes as a replacement reviewer, a second launch miss records that reviewer's pass as degraded, and the review proceeds on the remaining reviewer without waiting and without escalating.

**One meaning for "seat" (#557)**

- R7. In the coordinator payload, "seat" means the terminal of one Dispatch. The sizing sentence uses "entry" for the roster entry, and its needle moves with it.
- R8. The two pinned branch strings of the template conditional and the sentence "omp's own `modelRoles` then never decides which Gemini seat a dispatch uses." stay byte-identical.
- R9. `AGENTS.md` uses "entry" or "lead pin" where it means a roster entry or a lead pin.

**omp launch (#550)**

- R10. The plan records verbatim CLI evidence for three questions: non-interactive prompt input, a model and thinking-level pin by flag, and a custom launch command in `worker-start`.
- R11. The launch paragraph changes only as far as that evidence supports. The one-Dispatch-per-terminal rule, the release rule, and the model confirmation stay consistent with the launch path that results.

**Subagent guard and skill re-entry (#547)**

- R12. In an Orca-managed session whose local payload files are staged, a call to the harness's own subagent tool is denied. An Orca agent-teams session is the one exception and allows every call. The denial names the `orchestration` skill and the Orca dispatch path.
- R13. A session outside Orca is unchanged: the guard allows every call there.
- R14. The guard fails open. A missing binary, a malformed event, an unknown harness, an unreadable payload file, and a timeout all allow.
- R15. The payload a lead receives on the `compact` source carries the skill re-entry instruction, and its text is identical to the `startup` text.
- R16. The decision between a settings deny rule and a `PreToolUse` hook is recorded with its reason. Each harness has a recorded blocking target.
- R17. The sentence "No PreToolUse hook enforces any of this." is replaced by text that matches the new enforcement, and its needles move with it.
- R18. `.ci/test-orchestration-hook.sh` gains three regression cases: (a) the `compact` payload carries the re-entry instruction, (b) an injected session's subagent tool call is denied, (c) a session with no injection is not denied.

**Parity**

- R19. `AGENTS.md`, `CONCEPTS.md`, `packages/orchestration-hook/README.md`, and `packages/omp-orca/README.md` agree with every changed boundary. No new dependency is added.

### Key Decisions

- **Only revisions become lead work.** Governs R1, R2. The first write of an artifact keeps its recipient. This keeps the elevation worker's single-permitted-write check intact.
- **A `PreToolUse` hook, not a settings deny rule.** Governs R12, R13, R16. A `permissions.deny` rule in `settings.json` is static. It would apply to every session on the host, so it cannot leave a session outside Orca unchanged. A hook reads the session's own environment at run time. `AGENTS.md` line 70 also records that a Claude Code hook owned by this checkout ships in the plugin, because `hooks` is rejected in managed settings at render time.
- **#550 closes on a negative finding.** Governs R10, R11. omp supports a non-interactive prompt and a flag pin. Orca's supervised path cannot use the non-interactive form, so the ceremony keeps its steps. The pull request records that finding and rewrites the paragraph to the supported extent.

### Scope Boundaries

- The routing table, the brief-guidance table, the elevation paragraphs, the review-and-peer contract paragraph, and the Everyone payload keep their text.
- Gate helper names and gate comments that say "seat" (`agent_seat_pair`, "one-seat branch") are not payload text and stay as they are.
- The guard's blocked set is the Agent and Task family that #547 names. Other tools that start in-process agents, such as a workflow runner, stay bound by the Everyone payload text alone. Each name added beyond the KTD7 table needs an event captured from the real harness first. The KTD7 names are captured by U2 step 0 before the guard ships.
- No file under `docs/plans/` other than this plan changes. No learning changes. `home/.chezmoidata/releases.json` is not refreshed.
- The installed Orca guide and the omp CLI are external and unchanged.

### Acceptance Examples

- AE1. **Covers R1, R3.** Given a `ce-plan` run whose plan file the elevation worker wrote, when `ce-doc-review` returns three authorized fixes, then the lead edits that plan file itself. When the same run must change `README.md`, then the lead dispatches that edit under the implementation row.
- AE2. **Covers R6.** Given a judgment dispatch where `codex` is unavailable and the omp replacement launch misses twice, when the lead classifies the second miss, then it records the `codex` reviewer's pass as degraded, runs the `claude` reviewer at the authoring effort for that run, and does not escalate.
- AE3. **Covers R12, R14.** Given `ORCA_TERMINAL_HANDLE` set, a lead pane match, staged payload files, and a `PreToolUse` event with `tool_name` `Agent`, when `guard --harness claude` runs, then stdout is a deny document whose reason contains "`orchestration` skill". Given the same environment and `not json` on stdin, then stdout is `{}`.
- AE4. **Covers R13.** Given an empty environment and the same `Agent` event, when `guard --harness claude` runs, then stdout is `{}` and the exit code is 0.
- AE5. **Covers R15.** Given a healthy lead environment, when `hook --harness claude` receives `{"hook_event_name":"SessionStart","source":"compact"}` and then the same event with `"source":"startup"`, then both outputs are byte-identical and both contain "Before each dispatch, MUST open the `orchestration` skill".
- AE6. **Covers R12.** Given a stale cached declaration that still sends a `Bash` event to `guard`, when the guard runs in an injected session, then it allows, because `Bash` is not in the blocked set.

### Sources

- `home/.chezmoitemplates/orchestration-coordinator.tmpl` lines 36, 47, 49, 51, 53, 55. `home/.chezmoitemplates/orchestration-everyone.tmpl` line 28 names the subagent tools: "Agent, Task, `spawn_agent`, `subagent`, or an equivalent".
- `.ci/test-agent-instructions.sh` lines 564 to 630 (`COORDINATOR_NEEDLES`; lines 576, 577, 581, 582, 628), lines 639 to 678 (`CLAUDE_COORDINATOR_NEEDLES` and the negative loop). `.ci/test-agent-roster.sh` lines 302 to 338 pin the dispatch spelling and both branch strings.
- `packages/orchestration-hook/src/cli.ts` (the `runGuard` shim and its fail-open header), `src/envelope.ts` (`LEAD_INTRO`, `composeContext`), `src/role.ts`, `src/payload.ts`. `packages/omp-orca/src/index.ts`.
- `.ci/test-orchestration-hook.sh` lines 88 to 110 (`run_guard_shim`), 350 to 403 (shim cases, the "must not declare a PreToolUse hook" assertions, the one-record trust assertion), 455 to 473 (extension runner, which throws on any event other than `before_agent_start`). `.ci/test-codex-settings-reconcile.sh` lines 154 to 163 (`expected_trust_keys`).
- History. `docs/plans/2026-09-16-2329-feat-orca-lead-dispatch-only-model-roster-plan.md` KTD4 removed the launch gate, user-directed, because "document paths vary and the gate cannot classify them". Commit `f936bc24` deleted `gate.ts`. `git show f936bc24^:packages/orchestration-hook/src/cli.ts` holds the verified deny document (`guardDenyOutput`) and the 500 ms guard stdin deadline. `git show f936bc24^:packages/orchestration-hook/test/fixtures/pretooluse-claude.json` is a `PreToolUse` event captured from a live Claude Code session. `git show 79a31fa2^:.chezmoitemplates/claude-hook-declaration.tmpl`, `git show 79a31fa2^:.chezmoitemplates/codex-hook-declaration.tmpl`, and `git show 79a31fa2^:.chezmoitemplates/codex-hook-trust.tmpl` hold the declaration and trust shapes that ran before the removal.
- Learnings. `docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md`: a render is not an argv acceptance check. `docs/solutions/test-failures/self-written-stubs-certify-gnupg-formats-that-never-occur.md`: a self-written event fixture proves nothing about the real producer.
- Prior plans for conventions: `docs/plans/2026-09-18-0955-fix-forbid-omp-seat-reuse-plan.md`, `docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md`, `docs/plans/2026-09-18-0900-fix-coordinator-release-retention-takeover-plan.md`.

**CLI evidence for #550 and #547, verbatim**

| Source | Text relied on |
|---|---|
| `omp --help`, omp v18.2.5 | `--model=<value>  Model to use (fuzzy match: "opus", "gpt-5.2", or "openai/gpt-5.2")` |
| same | `--thinking=<value>  Set thinking level: off, minimal, low, medium, high, xhigh, max, auto` |
| same | `-p, --print  Non-interactive mode: process prompt and exit` and `MESSAGES   Messages to send (prefix files with @)` |
| omp v18.2.5 binary, `readPipedInput` | `if (process.stdin.isTTY === true) return;` then `Reading prompt from piped stdin (waiting for EOF; ctrl+c to abort)…` then `await Bun.stdin.text()`. A piped prompt makes the run non-interactive. |
| omp v18.2.5 binary, tool-call dispatch | `emitToolCall({ type: "tool_call", toolName: e.tool.name, toolCallId: …, input: … })` then `if (l?.block) return { block: true, reason: l.reason \|\| "Tool execution was blocked by an extension" }`. The subagent tool is `name: "task"`. |
| `orca-ide orchestration worker-start --help`, Orca 1.4.205 | `(--agent <agent> \| --terminal <handle>)`; `--agent <id>  Launch a known TUI agent in the first terminal`; `--model supports Claude, Codex, and Cursor opaque provider model ids; --effort requires --model. Neither can combine with --terminal.` The command has no custom-command flag. `orca-ide agent-context --json` names omp nowhere. |
| `orca-ide orchestration dispatch --help` | `--task <task_id> --to <handle>` are required, so a Dispatch prompt exists only for a terminal that already exists. |
| `orca-ide skills get orchestration --reference references/low-level-topology.md` | "`dispatch --inject` creates authoritative Task/Dispatch context but deliberately keeps an operator-created process unsupervised: it creates no supervised worker resource row." |
| Codex 0.155.0 binary | `Tool call blocked by PreToolUse hook: `, `PreToolUsePermissionDecisionWire`, and the `spawn_agent` tool name. |

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The revision rule is three short sentences after the elevation-worker sentence in line 36, and no pinned sentence changes.** Serves R1 to R4. The sentence "It authors no repository deliverable and MUST dispatch every repository deliverable…" is pinned at `.ci/test-agent-instructions.sh` line 576 and issue #569 requires the existing needles to pass, so the new text is a named exception that follows it.
- KTD2. **The judgment-row clause follows the existing launch-miss sentence and leaves that sentence in place.** Serves R6. The existing sentence stays correct for the mechanical and implementation rows. When `claude` is the remaining reviewer, line 51's effort rule already applies, and the clause says so.
- KTD3. **"Entry" replaces "seat" in one payload sentence and one `AGENTS.md` sentence; "lead pin" replaces "lead seat" in `AGENTS.md`.** Serves R7 to R9. A negative assertion keeps the retired wording out. Ten other "seat" uses in lines 53 and 55 already mean the terminal and stay.
- KTD4. **The omp launch keeps its steps; the paragraph gains four evidence-backed sentences.** Serves R10, R11. A non-interactive omp process runs one prompt and exits. Orca issues a Dispatch prompt only to an existing terminal, and `worker-start` has no custom-command flag. `dispatch --inject` leaves the process unsupervised, which breaks the same-turn release rule and the residency check. The confirmation stays because `--model` is a fuzzy match, so the requested id does not prove the effective model. The pinned needle "confirms the model from the terminal, and dispatches with `worker-start --task <task_id> --terminal <handle>`." stays byte-identical.
- KTD5. **`guard` becomes the tool-call guard again, under the same name.** Serves R12 to R14. Conflict, recorded: plan `2026-09-16-2329` KTD4 removed the launch gate by user direction, because a gate that cannot classify its input is noise. That reason does not reach this guard. It matches one exact tool name per harness and parses no shell grammar and no path. Issue #547 is the newer user direction. A stale cached declaration still sends `Bash` events to `guard`; `Bash` is not in the blocked set, so the shim's promise holds by construction (AE6).
- KTD6. **"Received the injection" is decided from the same local inputs `hook` uses.** Serves R12, R13. The guard denies only when `resolveRole` is `lead` or `worker` and the local halves that role's envelope needs are present: `everyone.md` for a worker; `everyone.md`, `coordinator.md`, and a non-empty orchestration `SKILL.md` for a lead. The guard does not repeat the guide fetch: the fetch costs up to eight seconds and proves nothing about a past delivery. Recording a delivery would need new persistent state in a package that holds none. A lead whose guide fetch failed receives no envelope but is still denied, by design: the Everyone rule already forbids a substitute subagent when Orca is unreachable, so the denial removes no permitted path, and its text is self-contained. The session that issue #547 keeps unchanged is a session outside Orca, which resolves to role `none`. The guard allows every call when `ORCA_AGENT_TEAMS_LEADER_PANE` is present, because in an Orca agent-teams session the `Agent` tool is the teammate spawn path and Orca supervises each teammate through its tmux pane.
- KTD7. **Blocked tool names are one constant per harness, matched exactly in the binary.** Serves R12, R16.

  | Harness | Blocking target | Blocked `tool_name` | Declared in |
  |---|---|---|---|
  | Claude Code | plugin `PreToolUse` hook, matcher `Agent\|Task` | `Agent`, `Task` | `home/.chezmoitemplates/claude-hook-declaration.tmpl` |
  | Codex | plugin `PreToolUse` hook, no matcher (the historical shape) | `spawn_agent` | `home/.chezmoitemplates/codex-hook-declaration.tmpl` |
  | omp | `tool_call` handler in the native extension | `task` | `packages/omp-orca/src/index.ts` |

  The matcher is only a cost filter. A matcher that also reaches `TaskCreate` costs one process and changes nothing, because the binary compares `tool_name` for equality.
- KTD8. **The deny document is the shape the removed gate verified.** Serves R12. `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` on stdout with exit 0, for all three harness values. Allow stays the current shim output: `{}` for `claude`, empty for `codex` and `omp`. The omp extension is this repository's own consumer and parses the same document.
- KTD9. **The re-entry instruction lives in `LEAD_INTRO`.** Serves R15. `LEAD_INTRO` is the first text of the lead envelope after the preamble, and every SessionStart source and the omp extension receive it. One constant means the `compact` and `startup` wording cannot diverge. The hook does not read the event's `source` field.
- KTD10. **The Codex trust template regains the `PreToolUse` label.** Serves R12. Trust keys are positional within their own event, so the `session_start:0:0` key and hash do not move. The expected record count moves from one to two in the gates that assert it.
- KTD11. **Each needle edit lands in the unit that moves its sentence.** Serves R4, R17. No commit leaves a gate red.

### Assumptions

- A1. Codex 0.155.0 reports the subagent tool to a `PreToolUse` hook with `tool_name` `spawn_agent`. The binary evidence shows the hook blocks generic tool calls and shows the tool name, but no event was captured from a live Codex session. If the name differs, the guard allows and the payload rule still binds; the fix is one string in the KTD7 constant. The U2 step 0 capture settles it before merge.
- A2. Closing #550 on a recorded negative finding is acceptable, because every item in that issue is a question or a conditional rewrite and the remaining lever is a supervised custom-command launch in Orca, which is not this repository. If the user wants the issue kept open, the pull request body uses `Refs #550` and nothing else changes.
- A3. Blocking a dispatched worker's subagent tool is intended. The Everyone payload rule binds every role, and every Orca-managed session receives it.

### Sequencing

U1 first. U2 next, then U3 and U4, which both need the U2 binary. U5 after U2, U3, and U4, because its sentence describes all three targets. U6 last.

---

## Implementation Units

| U-ID | Title | Files | Depends on |
|---|---|---|---|
| U1 | Payload text for #569, #558, #557, #550 | coordinator template, instruction gate | none |
| U2 | Guard and lead intro in the hook binary | `packages/orchestration-hook/` | none |
| U3 | Declare the guard and add the regression cases | two declaration templates, trust template, three gates | U2 |
| U4 | Block `task` from the omp extension | `packages/omp-orca/`, hook gate runner | U2 |
| U5 | Replace the enforcement sentence | coordinator template, instruction gate | U2, U3, U4 |
| U6 | Prose parity | `AGENTS.md`, `CONCEPTS.md`, two READMEs | U1 to U5 |

### U1. Payload text for #569, #558, #557, and #550

- **Goal:** the rendered coordinator payload carries the four text changes, and both payload gates pass.
- **Requirements:** R1 to R4, R6 to R8, R10, R11. Implements KTD1 to KTD4, KTD11.
- **Dependencies:** none.
- **Files:** `home/.chezmoitemplates/orchestration-coordinator.tmpl`, `.ci/test-agent-instructions.sh`.
- **Approach:**
  1. Line 36, directly after "…which the lead reads and validates instead of writing." insert: "A revision of the current workflow's own planning artifact is lead work, and the lead makes that edit itself. That artifact is the one plan or requirements document under `<docs_root>/plans/` or `<docs_root>/brainstorms/` that the running `ce-plan`, `ce-brainstorm`, or `ce-doc-review` step owns. The first write of an artifact is not a revision and keeps its recipient, so model elevation still authors the first plan. Every other file stays a dispatched deliverable, the documentation prose named above included."
  2. Line 53, directly after "…which the row's unavailable column already handles." insert: "The judgment row is the one case that column does not cover: there `omp` is itself the replacement reviewer, and the row names no further agent. A second launch miss there records that reviewer's pass as degraded, and the review proceeds on the remaining reviewer without waiting and without escalating. When the remaining reviewer is `claude`, the effort rule above for a degraded `codex` reviewer applies to that run."
  3. Line 53, change "running omp with that entry's model and thinking level —" to "running omp with that entry's model and thinking level pinned by omp's own `--model` and `--thinking` flags —". Do not touch the conditional or its branch strings.
  4. Line 53, directly after "…so a bare `--terminal` is rejected before the seat receives work." insert: "`worker-start` delivers the Dispatch prompt into that terminal, so the lead MUST NOT type, paste, or send the prompt itself. The confirmation stays because omp resolves `--model` by fuzzy match, so the requested id does not prove the effective model. omp's non-interactive forms — `--print`, a prompt argument, and piped stdin — are not a dispatch path: such a process runs one prompt and exits, and Orca issues a Dispatch's prompt only to a terminal that already exists. `dispatch --inject` is not a substitute, because it leaves the process unsupervised and the release and residency rules below need a supervised worker."
  5. Line 55, replace the sentence with: "A substantive failure on the omp mechanical entry is retried once on the omp implementation entry before the mechanical row leaves the agent, the one same-brief re-dispatch this paragraph permits, because the entry changes while the rung does not."
  6. `.ci/test-agent-instructions.sh`, `COORDINATOR_NEEDLES`: replace the line 628 needle with "A substantive failure on the omp mechanical entry is retried once on the omp implementation entry before the mechanical row leaves the agent". Add "A revision of the current workflow's own planning artifact is lead work, and the lead makes that edit itself.", "That artifact is the one plan or requirements document under `<docs_root>/plans/` or `<docs_root>/brainstorms/`", "The first write of an artifact is not a revision and keeps its recipient, so model elevation still authors the first plan.", and "A Unit the sizing cannot split returns to this same entry as a recorded plan defect for a re-cut."
  7. `CLAUDE_COORDINATOR_NEEDLES`: add "A second launch miss there records that reviewer's pass as degraded, and the review proceeds on the remaining reviewer without waiting and without escalating.", "pinned by omp's own `--model` and `--thinking` flags", "so the lead MUST NOT type, paste, or send the prompt itself.", and "are not a dispatch path: such a process runs one prompt and exits".
  8. Extend the negative loop at lines 672 to 678 with `omp mechanical seat`, `omp implementation seat`, and `the seat changes while`, under the message "contains roster-entry use of seat".
- **Patterns to follow:** the paragraph's dense normative register with literal MUST and MUST NOT; one needle per heredoc line; the template header's rule that the body carries no template action beyond the roster lookups and the existing conditional.
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh`: the unchanged needles at lines 576, 577, 589 to 593, and 645 to 651 still match; the replaced line 628 needle and the eight new needles match; the extended negative loop finds none of its strings in either coordinator render; the linux and darwin coordinator renders stay identical outside the executable rule.
  - Self-check, run once by hand: a scratch copy of the linux render with the old line 55 sentence appended makes the negative loop fail.
  - `.ci/test-agent-roster.sh`: the dispatch-spelling needle at line 302 matches; the committed roster renders the two-seat branch string; the one-seat stub renders the one-seat branch string and no "for mechanical work, "; the routing table counts four rows and the brief table six.
- **Verification:** `bash .ci/test-agent-instructions.sh` and `bash .ci/test-agent-roster.sh` pass.

### U2. Guard and lead intro in the hook binary

- **Goal:** `guard` denies an injected session's subagent tool call in the verified document shape, allows everything else, and fails open; the lead envelope opens with the re-entry instruction.
- **Requirements:** R12 to R15. Implements KTD5 to KTD9.
- **Dependencies:** none.
- **Files:** `packages/orchestration-hook/src/guard.ts` (new), `packages/orchestration-hook/src/cli.ts`, `packages/orchestration-hook/src/envelope.ts`, `packages/orchestration-hook/test/guard.test.ts` (new), `packages/orchestration-hook/test/cli.test.ts`, `packages/orchestration-hook/test/envelope.test.ts`, `packages/orchestration-hook/test/fixtures/pretooluse-claude-agent.json` (new).
- **Approach:**
  0. Capture real events before writing the guard. Keep all capture configuration in a per-user scratch directory and never apply to the live `$HOME`. Claude Code: run one headless `claude -p` session with `--settings <scratch file>` whose only hook is a `PreToolUse` logger (matcher `*`) that writes its stdin to a scratch file, with a prompt that makes the session call its subagent tool once. Codex: run one `codex exec` session against a scratch `CODEX_HOME` with multi-agent enabled and a matcherless logging `PreToolUse` hook, with a prompt that makes it call `spawn_agent` once. omp: load a scratch logging extension that records `toolName` from one `tool_call` event of the `task` tool. Store each captured event unedited except for the redaction the historical fixture applied (host paths and session ids), as `test/fixtures/pretooluse-claude-agent.json` and `test/fixtures/pretooluse-codex-spawn-agent.json`. If a harness cannot produce a capture, record the command and its exact error in the pull request, keep the binary-evidence name, and rely on the fail-open fallback in A1.
  1. `guard.ts` exports `SUBAGENT_TOOLS: Record<Harness, readonly string[]>` with the KTD7 values, `isInjected(role, env)` per KTD6, `denyReason(tool)`, and `decide(event, harness, env)`. `decide` returns allow unless `event.tool_name` is a string in the harness set and `isInjected` is true. `isInjected` reuses `payload()` and the skill read that `cli.ts` already has; move `readOrchestrationSkill` to a shared place instead of copying it.
  2. `denyReason` text: "The harness's own subagent tool (`<tool>`) is not available in an Orca-managed session. Orca owns agent lifecycle, so a subagent this tool starts is a worker Orca cannot supervise. Open the `orchestration` skill, load its version-matched guide, and use the Orca dispatch path instead. If this session is a dispatched worker, do the work yourself or ask the coordinator with the `ask` command from your preamble. If Orca is unreachable, report the failed command and its exact error and continue with your own reasoning only."
  3. `cli.ts`: `runGuard` becomes async. It reads stdin through the existing `readStdin` with a 500 ms bound, stopping at the first newline or at EOF, parses JSON, and calls `decide`. Wrap the whole path in the same try/catch shape `hook` uses. Every failure prints `emptyOutput(harness ?? "codex")` and returns 0. Add `guardMs` to `Io.deadlines`. Add an injectable `stdin` source to `Io`, defaulting to the process stdin, so `main`-level tests feed the event; `.ci/test-orchestration-hook.sh` keeps the compiled-binary cases on the real file descriptor. Rewrite the `runGuard` doc comment and the usage text: `guard` is the subagent tool guard, and a stale cached declaration that sends `Bash` events is still allowed.
  4. Use the step 0 captures unedited as the deny fixtures. Synthetic events appear only as parser edge cases (malformed, missing `tool_name`, non-string `tool_name`), and their test comments say so.
  5. `envelope.ts`: set `LEAD_INTRO` to "This session is the lead of an Orca-managed agent team. Before each dispatch, MUST open the `orchestration` skill and follow its version-matched guide. Both texts are below. They were read at session start from this host's installed Orca CLI. The guide is the current output of `skills get orchestration`, so do not re-fetch it. This instruction holds again after every context compaction, because a summary does not carry these rules. MUST NOT use the harness's own subagent tool in place of an Orca dispatch." Export it for the tests.
- **Patterns to follow:** the fail-open header of `cli.ts`; `capture()` and `deadlines` in `test/cli.test.ts`; temp-HOME seeding in the "managed payload files" block; no runtime dependency.
- **Test scenarios:**
  - `test/guard.test.ts`: each harness denies exactly its own names (`Agent`, `Task`; `spawn_agent`; `task`) and allows another harness's name; `Bash`, `TaskCreate`, a missing `tool_name`, and a non-string `tool_name` allow; role `none` allows; a worker with no `everyone.md` allows; a lead with no `coordinator.md` or an empty skill file allows; a lead and a worker with staged files deny; a session with `ORCA_AGENT_TEAMS_LEADER_PANE` set allows `Agent`.
  - `test/cli.test.ts`, replacing the "guard compatibility shim" block: covers AE3 and AE4 through `main`; the deny output parses to `hookEventName` `PreToolUse` and `permissionDecision` `deny`, and the reason contains "`orchestration` skill" and "Orca dispatch path"; malformed stdin, empty stdin, a missing `--harness`, and an unknown `--harness` exit 0 with the empty allow output and an empty stderr; covers AE6 with a `Bash` launch event.
  - `test/envelope.test.ts`: the lead context contains `LEAD_INTRO` directly after `PREAMBLE`; the worker context does not contain "Before each dispatch".
- **Verification:** in `packages/orchestration-hook`, `vp test` and `vp run typecheck` pass.

### U3. Declare the guard and add the regression cases

- **Goal:** both plugins declare the guard, the Codex trust record attests it, and the hook gate proves R18 against the compiled binary.
- **Requirements:** R12, R13, R15, R16, R18. Implements KTD7, KTD10.
- **Dependencies:** U2.
- **Files:** `home/.chezmoitemplates/claude-hook-declaration.tmpl`, `home/.chezmoitemplates/codex-hook-declaration.tmpl`, `home/.chezmoitemplates/codex-hook-trust.tmpl`, `.ci/test-orchestration-hook.sh`, `.ci/test-codex-settings-reconcile.sh`.
- **Approach:**
  1. Claude declaration: add a `PreToolUse` group with matcher `Agent|Task`, exec form, `args` `["guard", "--harness", "claude"]`, `timeout` 10. Keep `SessionStart` byte-identical. Add a header comment: the matcher is a cost filter and the binary decides.
  2. Codex declaration: add a `PreToolUse` group with no `matcher`, as the historical group had none, and one handler with exactly the keys `type` (`command`), `command` (`<binary> guard --harness codex`), `timeout` (10), and `additionalContextLimit` (0), and no `args` key. The binary decides by exact `tool_name` equality, so no matcher can hide a renamed tool from it. Keep `SessionStart` byte-identical. Restore the shape from `git show 79a31fa2^:.chezmoitemplates/codex-hook-declaration.tmpl`.
  3. Trust template: add `"PreToolUse" "pre_tool_use"` to `$eventLabels`.
  4. `.ci/test-orchestration-hook.sh`: replace `run_guard_shim` with `run_guard <harness> <role_env> <event_json>`, which pipes the event on the real fd. Add `run_hook_event <harness> <role_env> <extra_path> <event_json>`.
  5. Regression case (a): with the healthy-CLI lead environment, run `run_hook_event claude` with a `compact` event and with a `startup` event. Assert that the two outputs are equal and that the context contains "Before each dispatch, MUST open the `orchestration` skill".
  6. Regression case (b): with the healthy-CLI lead environment and with `$worker_env`, `run_guard claude` with the captured `Agent` event and a `Task` event, and `run_guard codex` with the captured `spawn_agent` event, each return a document where `jq -e '.hookSpecificOutput.permissionDecision == "deny"'` holds and the reason contains "orchestration".
  7. Regression case (c): with an empty role environment, the same three events return `{}` for `claude` and nothing for `codex`. With the lead environment and `HOME="$scratch/empty-home"`, the `Agent` event returns `{}`. With `$TEAM` (the agent-teams environment), the `Agent` event returns `{}`. With the lead environment and a failing Orca CLI on `PATH`, the `Agent` event returns the deny document.
  8. Keep the fail-open cases: no stdin, malformed stdin, and an unknown harness allow. Keep the `Bash` launch event as the stale-declaration case and assert `{}`.
  9. Replace the two "must not declare a PreToolUse hook" blocks: assert the Claude matcher, the exec-form `args`, and the binary path; assert the Codex group has no matcher, the command string, `additionalContextLimit` 0, and no `args` key. Replace the one-record trust assertion with two keys, `…:session_start:0:0` and `…:pre_tool_use:0:0`, both `sha256:` hashes.
  10. `.ci/test-codex-settings-reconcile.sh`: add the `pre_tool_use:0:0` key to `expected_trust_keys` and reword the comment that calls a PreToolUse record "resurrected".
- **Patterns to follow:** `require_file` and `render` through `source_root`; `env -i` with the closed `PATH`; one `pass` line per case; reach source state through `resolve_source_root` only.
- **Test scenarios:** the cases in steps 5 to 9 are the scenarios. In addition, a temporary swap of `session_start` to a different matcher in a scratch copy makes the trust-key assertion fail, run once by hand to show the assertion can fail.
- **Verification:** `bash .ci/test-orchestration-hook.sh`, `bash .ci/test-codex-settings-reconcile.sh`, `bash .ci/test-agent-trust-reconcile.sh`, `bash .ci/test-claude-codex-plugin-reconcile.sh`, and `bash .ci/test-source-root.sh` pass. In `packages/settings-reconcile`, `vp test` passes.

### U4. Block `task` from the omp extension

- **Goal:** an injected omp session cannot start its in-process `task` subagent, and every other tool call costs nothing.
- **Requirements:** R12 to R14. Implements KTD7, KTD8.
- **Dependencies:** U2.
- **Files:** `packages/omp-orca/src/index.ts`, `packages/omp-orca/test/extension.test.ts`, `.ci/test-orchestration-hook.sh`.
- **Approach:**
  1. Widen `ExtensionAPI.on` with a `tool_call` overload. The event carries `toolName: string`. The handler returns `{ block: true, reason: string }` or `undefined`.
  2. Add `invokeGuard(toolName, command, env, timeoutMs)`. It spawns `<hook> guard --harness omp` with a piped stdin, writes `{"hook_event_name":"PreToolUse","tool_name":"<toolName>"}` and a newline, and reads stdout with a 2000 ms bound. It returns the reason when stdout parses to a deny document and returns `null` on every other outcome. Reuse `stopChild`.
  3. Register the handler. When `event.toolName` is not `task`, return `undefined` without spawning. Otherwise return `{ block: true, reason }` when `invokeGuard` returns a reason.
  4. Gate runner in `.ci/test-orchestration-hook.sh`: accept both event names and keep both handlers. Call the `tool_call` handler with `{ toolName: "task" }` and with `{ toolName: "bash" }`.
- **Patterns to follow:** `invokeHook` for spawn, timeout, and size bounds; the extension reports a diagnostic on stderr and never throws.
- **Test scenarios:**
  - `test/extension.test.ts`: a stub guard that prints a deny document blocks `task` with that reason; a stub that prints nothing, prints `not json`, exits 3, or sleeps past the bound does not block; `bash` never spawns the stub, shown by a marker file the stub would write.
  - Gate: with the worker environment and the real binary, `task` returns `block: true` and a reason that contains "orchestration"; `bash` returns no block; with no `ORCA_TERMINAL_HANDLE`, `task` returns no block.
- **Verification:** in `packages/omp-orca`, `vp test`, `vp run typecheck`, and `vp run build` pass. `bash .ci/test-orchestration-hook.sh` passes.

### U5. Replace the enforcement sentence

- **Goal:** the lead-work paragraph describes the enforcement that now exists.
- **Requirements:** R17. Implements KTD11.
- **Dependencies:** U2, U3, U4.
- **Files:** `home/.chezmoitemplates/orchestration-coordinator.tmpl`, `.ci/test-agent-instructions.sh`.
- **Approach:**
  1. Line 36, replace "No PreToolUse hook enforces any of this. The shell-launch guard is removed, no edit notice is built, and this paragraph together with the no-direct-CLI rule in the Everyone payload is the whole enforcement." with: "One hook enforces one rule of the Everyone payload: in an Orca-managed session whose local payload files are staged, a tool-call guard denies the harness's own subagent tool — `Agent` and `Task` in Claude Code, `spawn_agent` in Codex, `task` in omp — and the denial names the `orchestration` skill and the Orca dispatch path. The guard fails open, and a call it does not deny is still bound by this text. No hook enforces the lead boundary itself. The shell-launch guard stays removed, no edit notice is built, and this paragraph together with the no-direct-CLI rule in the Everyone payload is the whole enforcement of that boundary."
  2. `COORDINATOR_NEEDLES`: replace the line 581 needle with "a tool-call guard denies the harness's own subagent tool — `Agent` and `Task` in Claude Code, `spawn_agent` in Codex, `task` in omp" and add "No hook enforces the lead boundary itself." Replace the line 582 needle with "The shell-launch guard stays removed, no edit notice is built, and this paragraph together with the no-direct-CLI rule in the Everyone payload is the whole enforcement of that boundary."
  3. Add "No PreToolUse hook enforces any of this." to the negative loop.
- **Patterns to follow:** as U1.
- **Test scenarios:** `.ci/test-agent-instructions.sh`: the three moved needles match; the retired sentence is absent from both coordinator renders; every other needle still matches. `.ci/test-orchestration-hook.sh`: the payload parity block still passes, because it diffs a fresh render.
- **Verification:** `bash .ci/test-agent-instructions.sh`, `bash .ci/test-agent-roster.sh`, and `bash .ci/test-orchestration-hook.sh` pass.

### U6. Prose parity

- **Goal:** the committed prose states every changed boundary once, with the payload's terms.
- **Requirements:** R5, R9, R16, R19.
- **Dependencies:** U1 to U5.
- **Files:** `AGENTS.md`, `CONCEPTS.md`, `packages/orchestration-hook/README.md`, `packages/omp-orca/README.md`.
- **Approach:**
  1. `AGENTS.md` line 70: replace "registers a `SessionStart` hook only" and the `guard` shim sentence. State that the plugin registers `SessionStart` and a `PreToolUse` guard for `Agent` and `Task`, that the Codex plugin declares `SessionStart` and a `PreToolUse` guard for `spawn_agent`, that omp blocks `task` through its extension, that the guard denies only in an Orca-managed session whose local payload files are staged, never in an Orca agent-teams session, and fails open, and that a settings deny rule was rejected because it cannot be scoped to an Orca session. Keep the trust-key sentence and add that `pre_tool_use:0:0` is a second record.
  2. `AGENTS.md` line 81: after "…the plan file is `ce-plan`'s deliverable alone." add: "After that first write, the lead revises the current workflow's own plan or requirements document under `docs/plans/` or `docs/brainstorms/` itself, while README, AGENTS, learnings, and glossary edits stay dispatched." Replace "The omp seat is the first recipient" with "The omp entries are the first recipients". Replace "the `opus[1m]` lead seat" with "the `opus[1m]` lead pin". Leave the two terminal-meaning "seat" uses.
  3. `CONCEPTS.md` `### Authoring work`: append "A later revision of that plan, or of the workflow's requirements document, is lead work: the lead edits that one artifact in place." Add `### Subagent guard` after `### Lead envelope`: one paragraph that defines the guard, its injected-session test, its three per-harness targets, and its fail-open rule. `### Launch ceremony` stays as it is.
  4. `packages/orchestration-hook/README.md`: rewrite the `guard` table row and add one sentence on the lead intro. `packages/omp-orca/README.md`: add one sentence on the `tool_call` block.
- **Patterns to follow:** `CONCEPTS.md` entries are one paragraph under an H3 with no lists; the prose names no model id the roster does not declare.
- **Test scenarios:** `.ci/test-agent-roster.sh` prose scan: every model id in `README.md` and `AGENTS.md` is in the roster allowlist. This command returns nothing:

  ```bash
  grep -nF -e 'omp seat is the first' -e 'lead seat' -e 'hook only' AGENTS.md
  ```
- **Verification:** `bash .ci/test-agent-roster.sh` passes and `git diff --check` reports nothing.

---

## Verification Contract

| Check | Applies to | What it proves |
|---|---|---|
| `bash .ci/test-agent-instructions.sh` | U1, U5 | R1 to R4, R6 to R8, R11, R17: moved and new needles, negative assertions, cross-OS parity |
| `bash .ci/test-agent-roster.sh` | U1, U5, U6 | R8, R9: both branch strings, the dispatch spelling, table counts, the prose model-id scan |
| `bash .ci/test-orchestration-hook.sh` | U2 to U5 | R12 to R15, R18: the compiled binary's deny, allow, and fail-open paths, the three regression cases, both declarations, two trust records, the extension block |
| `bash .ci/test-codex-settings-reconcile.sh`, `bash .ci/test-agent-trust-reconcile.sh`, `bash .ci/test-claude-codex-plugin-reconcile.sh` | U3 | the declared trust state carries exactly two records and the plugin version still tracks the rendered declaration |
| `bash .ci/test-build-orchestration-hook.sh`, `bash .ci/test-build-omp-integration.sh`, `bash .ci/test-source-root.sh`, `bash .ci/test-ci-wiring.sh` | U2 to U4 | the build scripts still stage both artifacts, and no gate joins `$repo_root` to a source-state name |
| `vp run -r build`, `vp run -r typecheck`, `vp run -r test` at the repository root | U2 to U4 | the workspace job CI runs |
| A scratch render of the coordinator body, read once | U1, U5 | the paragraphs read correctly on the committed two-seat branch |
| `git diff --check` and `git status` | all | no whitespace error and no file outside the units |

The scratch render follows `AGENTS.md` "Verification": a per-user scratch directory, a stub `op`, an empty config, a throwaway destination, `--source "$PWD"`, and a closed `PATH`. Use the recipe in `docs/plans/2026-09-18-0955-fix-forbid-omp-seat-reuse-plan.md`; `--source` still names the repository root, because chezmoi descends into `home/` itself.

**Post-merge operational checks, listed in the pull request body.** They are the checks issue #547 lists. They need the user's next `chezmoi apply` and a restarted session, so they are not part of the Definition of Done; the U2 step 0 captures are the pre-merge proof of the tool names and settle A1.

- In an Orca Claude Code lead session, call the subagent tool directly. The call is denied and the reason names the `orchestration` skill.
- In the same session, force a compaction, then dispatch. The session opens the `orchestration` skill and uses `worker-start`.
- In a Claude Code session outside Orca, the subagent tool works.
- In an Orca Codex session with the multi-agent feature on, ask for a `spawn_agent` call and read the hook's event. If `tool_name` is not `spawn_agent`, change the KTD7 constant and the U5 sentence in a follow-up pull request.

### Operational notes

- Both plugin versions move, because `plugin.json.tmpl` hashes the rendered declaration and the payload bodies. `run_onchange_after_update-claude-plugins.sh.tmpl` reruns on the next apply. A running session keeps its cached declaration until it restarts.
- A new Codex trust record appears under `pre_tool_use:0:0`. `chezmoi apply` owns it. Do not edit `~/.codex/config.toml` by hand.
- The hook binary rebuilds, because its source changed. `dotfiles-orca.js` rebuilds for the same reason.

---

## Definition of Done

- The coordinator payload carries the revision rule, the judgment-row clause, the "entry" sentence, the four omp launch sentences, and the new enforcement sentence. Both pinned branch strings and every pinned sentence this plan does not name are byte-identical.
- `guard` denies `Agent` and `Task` for `claude`, `spawn_agent` for `codex`, and `task` for `omp`, only in an Orca-managed session whose local payload files are staged and never in an agent-teams session, and allows on every failure path with exit 0.
- The lead envelope opens with the re-entry instruction, and the `compact` and `startup` outputs are byte-identical.
- Both plugins declare the guard, `SessionStart` is unchanged in both, and the trust state carries exactly two records with the `session_start:0:0` key and hash unmoved.
- The omp extension blocks `task` through the guard and spawns nothing for any other tool.
- `AGENTS.md`, `CONCEPTS.md`, and both package READMEs match the payload, and "seat" means the terminal of one Dispatch in all of them.
- Every command in the Verification Contract table passes. The U2 step 0 captures, or their recorded capture errors, and the post-merge operational checks are in the pull request.
- The pull request body carries `Closes #569, Closes #558, Closes #557, Closes #550, Closes #547`, or `Refs #550` under A2.
- Per unit: U1 and U5 land their sentence and its needles in one commit each; U2 lands with its package tests; U3 lands the declarations, the trust label, and every count assertion in one commit; U4 lands the extension and the gate runner together; U6 changes prose only.
- Cleanup: no scratch render, captured event, or temporary wrapper remains in the worktree, and no file under `docs/plans/` other than this plan changed.
