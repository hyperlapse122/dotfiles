---
title: Use Non-Interactive GitLab CI Wait - Plan
type: fix
date: 2026-07-30
topic: noninteractive-glab-ci-wait
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Use Non-Interactive GitLab CI Wait - Plan

## Goal Capsule

- **Objective:** Prevent GitLab CI monitoring from stopping at a post-completion action prompt by replacing the shared `glab ci status --live` instruction with `glab ci status --wait`.
- **Product authority:** The user's confirmed scope in this session. `.chezmoitemplates/agents-instructions.tmpl` owns the rule, and six harness wrappers render it.
- **Execution profile:** One clause-scoped prose edit to the shared instruction template, followed by isolated render verification. No live `chezmoi apply` is authorized.
- **Open blockers:** None.

## Product Contract

### Summary

Every managed agent harness must use the native, non-interactive GitLab CI watcher. The change applies to CI waiting only. Failure diagnosis and remediation remain the responsibility of the agent that receives the terminal result.

### Problem Frame

The shared CI rule currently names `glab ci status --live`. In an interactive terminal, that mode can present `Choose an action:` after the pipeline reaches a terminal state. An autonomous agent can remain blocked at that prompt even though the pipeline wait is complete.

GitLab CLI 1.110.0 documents `--wait` as waiting until the pipeline finishes and returning without a prompt. Its implementation reuses live status updates, disables the prompt path, and returns a non-zero status for a failed pipeline. This preserves the native blocking watcher while removing the interactive handoff.

### Requirements

- R1. The shared GitLab CI watcher command MUST be `glab ci status --wait`.
- R2. All six managed harness renders MUST contain the new watcher command and MUST NOT retain `glab ci status --live`.
- R3. The GitHub watcher commands and the surrounding prohibitions against polling, weakening, skipping, rerunning to hide a failure, and `[skip ci]` MUST remain unchanged.
- R4. The existing obligation to wait for terminal green CI MUST remain authoritative. A non-green terminal state is not successful merely because the watcher returned control.
- R5. The change MUST use the existing shared instruction fan-out. It MUST NOT add a `glab-ci-monitoring` skill, a per-harness instruction copy, or a new workflow abstraction.
- R6. Failure-log analysis, retry policy, and remediation behavior MUST remain outside this change.

### Scope Boundaries

**In scope**

- Replace only the `--live` flag in the GitLab watcher token at `.chezmoitemplates/agents-instructions.tmpl:56`.
- Verify the rendered instruction contract for Claude, Codex, OpenCode, AGY, omp, and Pi.

**Non-goals**

- Adding or changing a personal agent skill.
- Editing the external `glab` skill or GitLab CLI installation.
- Changing GitHub CI watcher guidance.
- Prescribing failure diagnosis or follow-up actions.
- Writing deployed `$HOME` targets or running `chezmoi apply` without a later explicit request.

### Acceptance Examples

- AE1. **Covers R1, R2.** Each of the six harness wrappers renders `glab ci status --wait` exactly once, and none renders `glab ci status --live`.
- AE2. **Covers R3.** A pre-edit versus post-edit render comparison changes only `--live` to `--wait` in the CI watcher sentence. The GitHub watcher tokens and every neighboring prohibition remain byte-identical.
- AE3. **Covers R4, R6.** The rendered rule still requires terminal green CI. It does not add retry, log-viewing, or remediation instructions.
- AE4. **Covers R5.** No skill, wrapper, workflow, or per-harness instruction source is added or modified.

## Planning Contract

### Key Technical Decisions

- KTD1. **Use `glab ci status --wait`.** (session-settled: user-approved — chosen over retaining `--live`: `--wait` preserves the native blocking watch while suppressing the post-completion action prompt.) GitLab CLI 1.110.0 documents this behavior, and its source shows that wait mode disables the interactive prompt path.
- KTD2. **Change the shared instruction instead of creating a skill.** (session-settled: user-directed — chosen over a new `glab-ci-monitoring` skill: the user confirmed that a skill would add no value beyond the shared command correction.)
- KTD3. **Apply the rule to every GitLab CI wait.** (session-settled: user-directed — chosen over limiting it to pipeline mode or explicit invocations: partial coverage would leave the interactive stall in other agent runs.)
- KTD4. **Stop ownership at the terminal wait result.** (session-settled: user-directed — chosen over bundling failure analysis and remediation: each agent retains responsibility for interpreting the final state and selecting follow-up action.)
- KTD5. **Reuse isolated render proof instead of adding a prose-content test.** Prior changes to this template verify all six rendered wrappers, the exact phrase delta, and preservation of harness variance. No existing CI test owns instruction prose, and a dedicated source-text assertion would test incidental wording rather than runtime behavior.

### Risks and Dependencies

- **Terminal-status semantics:** In GitLab CLI 1.110.0, `--wait` returns a non-zero status for `failed`, but other non-green terminal statuses are not all mapped to failure. R4 keeps the printed final status subject to the existing terminal-green obligation; this change does not add a wrapper around `glab`.
- **Managed-version precondition:** The repository release lock pins GitLab CLI 1.110.0, which supports `--wait`. The later user-authorized apply must deploy that pin before an agent follows the rendered instruction.
- **Fan-out drift:** Older plans mention four or five wrappers. The current source has six. Verification must use the current six-wrapper list.
- **Deployment boundary:** The source edit does not update the deployed instruction files until a user-authorized apply occurs.

## Implementation Units

### U1. Replace the interactive GitLab watcher flag

- **Goal:** Every managed agent instruction uses the non-interactive GitLab CI watcher without changing adjacent CI policy.
- **Requirements:** R1-R6. Implements KTD1-KTD5.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`.
- **Approach:** Read the full paragraph under `## Branches, commits, issues, blockers`. Replace only the `--live` flag inside the existing `glab ci status --live` inline-code token. Do not reflow the sentence or change the GitHub watcher commands, the terminal-green wording, or the prohibitions that follow.
- **Execution note:** Treat this as a shared instruction-contract edit. Verify the composed wrappers instead of editing or comparing deployed targets as source.
- **Patterns to follow:** The clause-scoped edit and six-wrapper render contract in `docs/plans/2026-07-30-002-docs-drop-figma-parity-stop-rules-plan.md` and `docs/plans/2026-07-30-003-docs-route-review-findings-plan.md`.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion.` The Verification Contract proves the rendered contract and exact delta.
- **Verification:** All six wrappers render without template errors. Each render satisfies AE1-AE4, and the wrapper sources remain unchanged one-line includes.

## Verification Contract

- **Render check.** Render `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_gemini/readonly_GEMINI.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`, and `dot_pi/private_agent/private_readonly_AGENTS.md.tmpl` through `chezmoi execute-template` with `--source "$PWD"`, a stub `op`, an empty config, and a throwaway per-user scratch destination.
- **Presence and absence check.** Each render contains `glab ci status --wait` exactly once and contains zero instances of `glab ci status --live` (AE1).
- **Preservation check.** Each render still contains `gh run watch --exit-status`, `gh pr checks --watch`, `wait for terminal green CI`, and the complete `never poll, weaken, skip, rerun to hide, or `[skip ci]` a failure` clause (AE2, AE3).
- **Baseline check.** Compare each pre-edit and post-edit render. The only common-instruction delta is the GitLab flag. Harness-specific differences between OpenCode, Pi, omp, and the other wrappers remain unchanged.
- **Source-delta check.** The word diff for `.chezmoitemplates/agents-instructions.tmpl` shows only `--live` replaced by `--wait`, with no surrounding reflow.
- **Scope check.** `git diff --check`, `git status`, and a scoped diff show only `.chezmoitemplates/agents-instructions.tmpl` plus this plan changed for this work. No deployed target or new skill is present.
- **CI check if pushed.** Both `.github/workflows/ci.yml` and `.github/workflows/render-dotfiles.yml` reach terminal success. Watch GitLab-hosted CI with `glab ci status --wait` when this repository is mirrored or executed on GitLab.

## Definition of Done

- `.chezmoitemplates/agents-instructions.tmpl` satisfies R1, R3, R4, R5, and R6 with a one-token flag replacement.
- All six isolated renders satisfy R2 and AE1-AE4.
- No wrapper, skill, workflow, deployed instruction target, or unrelated source changes.
- Repository diff and formatting checks pass. Any pushed CI reaches terminal green.

## Sources / Research

- `.chezmoitemplates/agents-instructions.tmpl:56` — the shared CI watcher sentence and sole source occurrence of `glab ci status --live`.
- The six wrapper paths in the Verification Contract — one-line `includeTemplate "agents-instructions.tmpl" (dict "harness" "<id>")` consumers.
- `docs/plans/2026-07-30-002-docs-drop-figma-parity-stop-rules-plan.md` and `docs/plans/2026-07-30-003-docs-route-review-findings-plan.md` — current six-wrapper prior art for clause-scoped instruction edits and isolated render verification.
- [GitLab CLI 1.110.0 `glab ci status` documentation](https://gitlab.com/gitlab-org/cli/-/blob/v1.110.0/docs/source/ci/status.md) — defines `--wait` as waiting for pipeline completion without a prompt.
- [GitLab CLI 1.110.0 status implementation](https://gitlab.com/gitlab-org/cli/-/blob/v1.110.0/internal/commands/ci/status/status.go) — wait-mode prompt suppression, terminal-status polling, and failed-pipeline exit behavior.
- User decisions in this session — all GitLab waits use the shared non-interactive command; no separate skill; downstream failure handling remains agent-owned.
