---
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Prompt and Hook Optimizations for Claude Models

## Goal Capsule

- **Objective:** Proactively optimize Claude model interactions across the dotfiles repository by adopting Anthropic's official prompting patterns for Claude Fable 5.1, Opus 5, and Sonnet 5 across agent instructions, orchestration briefs, lifecycle hooks, and harness settings.
- **Means:** Update `.chezmoitemplates/agents-instructions.tmpl`, `.chezmoitemplates/orchestration-coordinator.tmpl`, Claude Code plugin hook payloads in `packages/orchestration-hook`, and `.chezmoidata/agents.yaml`.
- **Product Authority:** Operates across user-wide dotfiles instruction templates, Claude Code session hooks, and Orca dispatch coordinator rules.
- **Open Blockers:** None.

## Product Contract

### Summary

This initiative proactively aligns the dotfiles repository with Anthropic's official prompting and behavioral guides for Claude Fable 5.1, Claude Opus 5, and Claude Sonnet 5. The optimization spans four distinct layers: agent system prompt tuning, Orca coordinator worker briefs, Claude Code plugin session lifecycle hooks (specifically context preservation during compaction), and Chezmoi-managed harness configuration and environment variables. Key outcomes include parallel tool-use batching, calibrated narration and deliverable length, prevention of redundant verification, robust context preservation across session compaction, and deterministic subagent concurrency limits.

### Primary Users & Use Cases

- U1: **Interactive Developer / Operator** working directly within Claude Code sessions who benefits from lower token waste, faster turnarounds via batched tool calls, concise answers, and persistent context across session compaction.
- U2: **Orca Coordinator Agent** orchestrating multi-agent tasks that dispatches work to Claude family workers (Opus 5, Sonnet 5, Fable 5.1) with briefs tailored to each model's operational strengths and instruction-following nuances.

### Scope Boundaries

#### In Scope

- S1: **System Prompt Tuning** in `.chezmoitemplates/agents-instructions.tmpl` (`claude` harness section):
  - Batching independent tool calls in agentic loops.
  - User-facing progress update cadence and narration calibration.
  - Response and written deliverable length calibration (`<tone_preference>`, avoiding boilerplate).
  - Task scope bounding and elimination of redundant self-verification instructions.
  - Prevention of recall loss in code-review instructions caused by overly conservative filtering prompts.
  - Frontend aesthetics directive (`<frontend_aesthetics>`) to eliminate generic design patterns.
- S2: **Orchestration Dispatch Briefs** in `.chezmoitemplates/orchestration-coordinator.tmpl`:
  - Providing upfront, complete task specifications for Opus 5 workers without stubs or placeholders.
  - Formulating unambiguous, explicit scoping boundaries for Sonnet 5 workers to account for literal instruction interpretation.
  - Eliminating redundant verification requirements from dispatch briefs.
- S3: **Lifecycle Hooks & Compaction Context Preservation** in `dot_local/share/dotfiles-claude-plugin/hooks/` and `packages/orchestration-hook`:
  - Ensuring `SessionStart` payload on `compact` events injects explicit directives on what context, decisions, and constraints to preserve during summarization.
- S4: **Chezmoi Configuration & Runtime Settings** in `.chezmoidata/agents.yaml`:
  - Adding `modelSettings.claude-sonnet-5.effortLevel: high`.
  - Declaring deterministic subagent spawn limits (`env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`) to prevent rogue native subagent spawning outside Orca.

#### Out of Scope / Deferred

- Standalone system instructions for non-Claude harnesses (`codex`, `agy`, `omp`) except where shared coordinator dispatch rules govern cross-harness delegation to Claude.
- Modifying internal source code of external archives or marketplace plugins (such as `compound-engineering`).

### Requirements

#### Agent System Prompts (`.chezmoitemplates/agents-instructions.tmpl`)

- R1. **Parallel Tool Batching Nudge:** `.chezmoitemplates/agents-instructions.tmpl` MUST instruct Claude to list required resources privately and request all independent tool calls in parallel within a single response turn during agent loops.
- R2. **Progress Update Cadence:** `.chezmoitemplates/agents-instructions.tmpl` MUST direct Claude to state intended actions in a single sentence before the first tool call, emit concise updates only on meaningful findings or direction changes, and lead final responses with the concrete outcome.
- R3. **Response and Deliverable Conciseness:** `.chezmoitemplates/agents-instructions.tmpl` MUST include tone and brevity calibration (`<tone_preference>`) and explicitly instruct that written file deliverables contain substantive content without boilerplate, filler sections, or redundant summaries.
- R4. **Task Scope Bounding and Verification Discipline:** `.chezmoitemplates/agents-instructions.tmpl` MUST constrain execution to the requested scope, make routine judgment calls autonomously, and forbid unrequested re-verification passes, double-checks, or unrequested file extensions.
- R5. **Code Review Recall Protection:** `.chezmoitemplates/agents-instructions.tmpl` MUST guide code review behaviors to report all valid findings rather than applying conservative thresholds that cause Sonnet 5 and Opus 5 to suppress valid lower-severity issues.
- R6. **Frontend Aesthetics Directive:** `.chezmoitemplates/agents-instructions.tmpl` MUST include a `<frontend_aesthetics>` directive instructing Claude to avoid generic AI design defaults (e.g., cliché font pairings, default purple gradients) and instead use distinct, context-tailored styling.

#### Orchestration Dispatch Briefs (`.chezmoitemplates/orchestration-coordinator.tmpl`)

- R7. **Upfront Task Specifications in Worker Briefs:** `.chezmoitemplates/orchestration-coordinator.tmpl` MUST instruct the coordinator to supply complete task specifications upfront when dispatching to Opus 5 workers, avoiding placeholders or deferred discovery.
- R8. **Explicit Scoping for Sonnet Workers:** `.chezmoitemplates/orchestration-coordinator.tmpl` MUST instruct the coordinator to define explicit, literal boundaries in briefs for Sonnet 5 workers to leverage its literal instruction following.

#### Lifecycle Hooks & Context Preservation (`packages/orchestration-hook`)

- R9. **Compaction Context Preservation Guidance:** The session-start hook payload in `packages/orchestration-hook` MUST provide guidance for session compaction events (`compact`), directing the model to retain all key technical decisions, active constraints, and unfinished work items during context summarization.

#### Harness Settings & Runtime Environment (`.chezmoidata/agents.yaml`)

- R10. **Claude Harness Settings and Subagent Limits:** `.chezmoidata/agents.yaml` MUST configure `modelSettings.claude-sonnet-5.effortLevel: high` and assert environment variables `env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: "1"` and `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS: "2"`.

### Key Decisions

- D1. **Layer-Separated Holistic Optimization** (session-settled: user-directed — chosen over prompt-only or phased approaches: aligns prompt text, coordinator briefs, lifecycle hook payloads, and runtime settings together for maximum proactive impact).
- D2. **Deterministic Subagent Caps via Environment Variables** (session-settled: user-approved — reinforces Orca dispatch exclusivity while allowing sanctioned skill delegation under strict depth and concurrency ceilings).
- D3. **Compaction-Aware SessionStart Payload** (session-settled: user-approved — leverages Claude Code's native `compact` matcher to maintain critical architectural decisions across long agent sessions).

### Acceptance Criteria & Verification Signals

- AC1. **Template Rendering Integrity:** `chezmoi execute-template < .chezmoitemplates/agents-instructions.tmpl` renders valid markdown for all four harness types (`claude`, `codex`, `agy`, `omp`) without syntax or template errors.
- AC2. **Coordinator Template Parity:** `chezmoi execute-template < .chezmoitemplates/orchestration-coordinator.tmpl` renders cleanly and preserves all Orca sizing rules while adding Claude-specific brief instructions.
- AC3. **Hook Test Suite Pass:** Running tests in `packages/orchestration-hook` (`pnpm test` or `bun test`) succeeds with zero errors, confirming all hook fixtures and envelope outputs remain valid.
- AC4. **Claude Settings Reconciler Validation:** `.ci/test-claude-settings-reconcile.sh` executes successfully against the updated `.chezmoidata/agents.yaml` without schema or type assertion failures.
- AC5. **Agent Instructions Validation:** `.ci/test-agent-instructions.sh` completes successfully, verifying all required sentinels and instruction boundaries remain intact.

## Planning Contract

### Key Technical Decisions

- **KTD1: Claude Harness Prompt Enhancement in `.chezmoitemplates/agents-instructions.tmpl`** (Governs R1, R2, R3, R4, R5, R6)
  The `{{ if eq .harness "claude" -}}` block in `agents-instructions.tmpl` is expanded to include Anthropic's official prompting patterns for Claude Fable 5.1, Opus 5, and Sonnet 5:
  - Parallel tool batching nudge: *"First privately list what you need next; then request every item that doesn't depend on another's result in this one response."*
  - Narration cadence: Say intended actions in one sentence before the first tool call; emit updates only on meaningful findings or direction shifts; lead final responses with outcomes.
  - Conciseness & deliverable calibration: Include `<tone_preference>Keep outputs reasonably concise. Skip non-essential context and boilerplate.</tone_preference>` and instruct that file deliverables omit filler sections and redundant summaries.
  - Task scoping & verification discipline: Deliver requested scope without unprompted widening or narrowing; omit redundant self-checking/double-checking routines.
  - Code review recall protection: Direct code reviews to report all valid findings rather than applying conservative severity filters that cause Sonnet 5 and Opus 5 to suppress valid lower-severity issues.
  - Frontend aesthetics: Include `<frontend_aesthetics>NEVER use generic AI-generated aesthetics like overused font families, cliched color schemes (purple gradients on white or dark backgrounds), and cookie-cutter layouts. Use unique fonts, cohesive colors, and context-specific styling.</frontend_aesthetics>`.

- **KTD2: Orchestration Dispatch Guidance in `.chezmoitemplates/orchestration-coordinator.tmpl`** (Governs R7, R8)
  When the Orca coordinator dispatches work to Claude workers:
  - Opus 5: Provide complete, upfront task specifications without stubs or placeholders.
  - Sonnet 5: Define unambiguous, literal boundaries in briefs to match its literal instruction interpretation.
  - Omit redundant verification requests in worker briefs.

- **KTD3: Context Preservation During Compaction in `packages/orchestration-hook` and Templates** (Governs R9)
  The session payload in `.chezmoitemplates/orchestration-everyone.tmpl` injects clear compaction preservation guidance: when compacting or summarizing conversation context, the model MUST preserve active goals, architectural decisions, user constraints, unfinished implementation units, and exact file paths/identifiers.

- **KTD4: Claude Settings and Deterministic Subagent Limits in `.chezmoidata/agents.yaml`** (Governs R10)
  In `.chezmoidata/agents.yaml` under `agents.claude.settings`:
  - Add `modelSettings.claude-sonnet-5.effortLevel: high`.
  - Assert environment variables `env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: "1"` and `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS: "2"`.
  - Ensure `.ci/test-claude-settings-reconcile.sh` validates the new keys cleanly.

### Technical Design & Architecture

The change modifies four files across three subsystems:
1. Instruction templates (`.chezmoitemplates/agents-instructions.tmpl`, `.chezmoitemplates/orchestration-coordinator.tmpl`, `.chezmoitemplates/orchestration-everyone.tmpl`)
2. Orchestration hook package (`packages/orchestration-hook`)
3. Data configuration (`.chezmoidata/agents.yaml`)

No new binaries or packages are introduced. The existing Chezmoi templating pipeline, settings reconciler, and hook compilation scripts are reused as-is.

### Sequencing & Dependencies

1. U1 (Prompt Tuning) and U2 (Coordinator Briefs) are pure template edits that can proceed immediately.
2. U3 (Compaction Context Preservation) updates the Everyone orchestration template and tests in `packages/orchestration-hook`.
3. U4 (Harness Settings) updates `.chezmoidata/agents.yaml` and verifies with the settings reconciler test.
4. U5 runs the entire CI and test suite.

## Implementation Units

### U1. System Prompt Optimization in `.chezmoitemplates/agents-instructions.tmpl`
- **Goal:** Incorporate official Fable 5.1, Opus 5, and Sonnet 5 prompting patterns into the Claude harness section of agent instructions.
- **Requirements:** R1, R2, R3, R4, R5, R6
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`
- **Approach:**
  - Update `{{ if eq .harness "claude" -}}` in `.chezmoitemplates/agents-instructions.tmpl`.
  - Add parallel tool batching nudge.
  - Calibrate user-facing progress updates and narration cadence.
  - Add `<tone_preference>` and deliverable length calibration.
  - Constrain task scope and remove redundant verification instructions.
  - Add code review recall protection instruction.
  - Add `<frontend_aesthetics>` directive.
- **Test Scenarios:**
  - `chezmoi execute-template < .chezmoitemplates/agents-instructions.tmpl` renders without error for all harnesses.
  - `.ci/test-agent-instructions.sh` passes.
- **Verification:** `.ci/test-agent-instructions.sh` exits 0.

### U2. Orchestration Dispatch Guidance in `.chezmoitemplates/orchestration-coordinator.tmpl`
- **Goal:** Ensure Orca coordinator dispatches to Claude family workers with optimized brief structures.
- **Requirements:** R7, R8
- **Files:** `.chezmoitemplates/orchestration-coordinator.tmpl`
- **Approach:**
  - In `.chezmoitemplates/orchestration-coordinator.tmpl`, under worker dispatch instructions, add guidance for Claude worker models:
    - Supply complete task specs upfront for Opus 5.
    - Provide explicit, literal boundaries for Sonnet 5.
    - Omit redundant verification steps in worker briefs.
- **Test Scenarios:**
  - `chezmoi execute-template < .chezmoitemplates/orchestration-coordinator.tmpl` renders cleanly.
- **Verification:** Template renders with exit code 0.

### U3. Compaction Context Preservation in Templates and Hooks
- **Goal:** Ensure session compaction retains critical architectural decisions and constraints.
- **Requirements:** R9
- **Files:** `.chezmoitemplates/orchestration-everyone.tmpl`, `packages/orchestration-hook/`
- **Approach:**
  - Add compaction preservation instructions to `.chezmoitemplates/orchestration-everyone.tmpl`.
  - Verify that `packages/orchestration-hook` builds and passes its test suite with the updated template embedded.
- **Test Scenarios:**
  - `pnpm --prefix packages/orchestration-hook test` runs and all tests pass.
  - `.ci/test-agent-instructions.sh` passes with sentinels intact.
- **Verification:** Hook test suite exits 0.

### U4. Harness Settings and Subagent Limits in `.chezmoidata/agents.yaml`
- **Goal:** Configure Sonnet 5 effort level and deterministic subagent environment limits.
- **Requirements:** R10
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:**
  - In `.chezmoidata/agents.yaml`, under `agents.claude.settings`:
    - Add `modelSettings.claude-sonnet-5.effortLevel: high`.
    - Add `env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: "1"`.
    - Add `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS: "2"`.
- **Test Scenarios:**
  - Run `.ci/test-claude-settings-reconcile.sh` to verify settings schema, path syntax, and leaf-assertion tests.
- **Verification:** `.ci/test-claude-settings-reconcile.sh` exits 0.

### U5. Full Quality Gate Verification
- **Goal:** Validate end-to-end repository integrity across templates, hooks, and tests.
- **Requirements:** AC1, AC2, AC3, AC4, AC5
- **Files:** None (validation only)
- **Approach:**
  - Run all CI verification scripts:
    - `.ci/test-agent-instructions.sh`
    - `.ci/test-claude-settings-reconcile.sh`
    - `pnpm --prefix packages/orchestration-hook test`
    - `chezmoi execute-template` across updated templates
- **Test Scenarios:**
  - All test scripts return exit code 0.
- **Verification:** All tests pass with zero failures.

## Verification Contract

- Run `chezmoi execute-template < .chezmoitemplates/agents-instructions.tmpl`
- Run `chezmoi execute-template < .chezmoitemplates/orchestration-coordinator.tmpl`
- Run `.ci/test-agent-instructions.sh`
- Run `.ci/test-claude-settings-reconcile.sh`
- Run `pnpm --prefix packages/orchestration-hook test`

## Definition of Done

- All requirements R1 through R10 are implemented across U1 through U4.
- All verification commands in the Verification Contract succeed with exit code 0.
- No syntax, template rendering, or validation assertion errors exist.
- No unstaged scrap or temporary files remain in the working tree.
