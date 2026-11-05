---
title: Managed Harness CE Integration Policy - Plan
type: docs
date: 2026-11-05
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Managed Harness CE Integration Policy - Plan

## Goal Capsule

- **Objective:** The owner can use Compound Engineering in every repository-managed AI harness, and open harness-onboarding work explicitly includes that outcome.
- **Means:** Extend the existing onboarding rules and annotate the five open onboarding issues (KTD1, KTD2).
- **Authority:** The user-confirmed scope in this conversation and the Product Contract below; existing bootstrap and shared-instruction constraints remain in force.
- **Execution profile:** One repository documentation change, suitable for one PR, plus five GitHub issue comments. The implementing agent completes verification and reports comment URLs; committing, pushing, or opening a PR requires separate shipping authority.
- **Stop conditions:** No planning blockers. Report an execution-time posting or native-verification failure without claiming the affected requirement is complete.

## Product Contract

### Summary

Make CE integration a required part of managed-harness onboarding, repair any current coverage gap, and record the requirement on the existing harness-addition issues.
Do not add new harnesses in this change.

### Problem Frame

The repository already requires shared user-scope instructions for every managed harness, but its onboarding rules do not impose the same requirement for CE.
The open harness issues describe generic plugin integration without naming CE as a completion condition.

### Key Decisions

- **Cover existing managed harnesses and pending onboarding, not new installations.** Governs R1, R4. (session-settled: user-directed — chosen over adding Claude Code and Codex now: the user requested gap repair for managed harnesses and comments on the open addition issues.)
- **Match omp's reproducibility principles rather than its commands.** Governs R2, R3. (session-settled: user-approved — chosen over prescribing omp's installation commands to every host: each harness needs its own supported native integration.)

### Requirements

**Current coverage and permanent policy**

- R1. Inventory repository-managed AI harnesses and complete any missing CE connection without onboarding an additional harness.
- R2. Add a mandatory CE integration rule immediately after the existing shared-instruction rules in `AGENTS.md`, and reflect it in the user and source onboarding documentation.
- R3. The rule must require user-scope CE registration, installation, and enablement through the host-supported mechanism, using the repository-pinned CE revision and explicit apply, with actual native skill discovery and invocation verification on that harness's eligible platforms.

**Open onboarding issues**

- R4. Add a requirement comment to each open onboarding issue #30, #31, #32, #33, and #34 without rewriting its body or closing it.
- R5. Each comment must identify CE as an onboarding completion condition under R3, reference the shared-instruction connection requirement, and preserve the issue's existing platform and provider constraints.

**Ownership and safety**

- R6. Keep worktree preparation read-only for personal settings and leave unrelated plugins, settings, pins, and shared-instruction content unchanged unless R1 identifies a real missing connection.

### Acceptance Examples

- AE1. **Covers R1, R6.** With the current inventory, omp already has a CE integration; the audit preserves that implementation rather than adding duplicate registration or treating T3 Code's omp ACP frontend as a separate CE host.
- AE2. **Covers R2, R3.** A future harness onboarding reader sees that both shared instructions and a verified CE integration are required before onboarding is complete.
- AE3. **Covers R4, R5.** Each named issue has a visible requirement comment; pi issue #33 still requires synthetic.new as its only provider, and no comment claims that the new harness is already integrated.

### Scope Boundaries

- No new harness installation, universal installer, new pin format, CE version refresh, or change to omp's existing update/reconciliation lifecycle.
- No injection of repository-maintenance policies into `home/.chezmoitemplates/agent-instructions`; this change concerns repository onboarding rules.
- No automatic issue-comment bot or persistent issue-posting ledger; direct posting and read-back suffice for five comments.

## Planning Contract

### Key Technical Decisions

- KTD1. **Extend the existing rule and documentation locations.** Implements R2, R3 in `AGENTS.md`, `README.md` under Shared instructions/Harness plugins, and `home/README.md` under shared user-scope instructions and harness plugins. Keep the current coverage description accurate and point onboarding readers to the existing plugin declaration, lock, and native verification patterns.
- KTD2. **Use direct GitHub comments, not new automation.** Implements R4, R5 through the existing authenticated GitHub CLI. Read each issue and its comments before posting; reuse an already-equivalent comment rather than posting a duplicate when resuming. Record each resulting permalink in the delivery report.
- KTD3. **Preserve the current CE implementation.** For R1, repository declarations currently identify only omp as a managed execution harness: `home/.chezmoidata/personal-apps.json`, `home/.chezmoidata/harness-plugins.json`, and the native omp adapters agree. T3 Code manages an omp ACP provider, not an additional independently provisioned harness. Recheck that inventory during implementation and use the existing smoke seam for AE1.

### Sources

- `home/README.md`: harness plugin data, native omp registration lifecycle, and shared user-scope instruction onboarding.
- `README.md`: Harness plugins and Shared instructions describe the current omp-only deployment.
- `home/.chezmoidata/harness-plugin-lock.json`: the CE release identity and full commit SHA are already repository-owned.
- `tests/smoke_harness_plugins.py`: real disposable-home apply and native skill discovery; it also checks local marketplace cutover, pinning, unchanged-action skipping, and unrelated plugin preservation.
- The open issue bodies listed in U2: each already asks for native instructions/skills/plugin integration and explicit-apply isolation.

## Implementation Units

### U1. Audit coverage and add the onboarding requirement

**Goal:** Current managed harness coverage is accounted for, and future onboarding has an explicit CE completion condition.

**Requirements:** R1–R3, R6; AE1, AE2.

**Dependencies:** None.

**Files:** Modify `AGENTS.md`, `README.md`, and `home/README.md`. Inspect the declarations and lock cited above; retain `home/.chezmoitemplates/agent-instructions` unchanged. Existing verification: `tests/smoke_harness_plugins.py`.

**Approach:**
1. Confirm KTD3 against the current worktree; do not interpret a pending issue or an optional T3 provider as an installed managed harness.
2. Add the R2/R3 policy after the existing shared-instruction rules, following KTD1.
3. Update both onboarding guides, distinguishing the mandatory policy from the currently connected hosts.

**Patterns:** Existing `AGENTS.md` user-scope harness rules and `home/README.md` onboarding guidance.

**Test expectation:** No new permanent tests for documentation wording. Use the existing native smoke for current coverage; it proves omp discovery and existing reconciliation, not future host support or a model's adherence to prose.

**Verification:** AE1 and AE2 hold; the documentation agrees on scope and no personal-home apply occurred. If the inventory reveals a genuine missing current adapter, implement it through the existing chezmoi/plugin patterns and prove native discovery and invocation before completing R1.

### U2. Annotate the five open onboarding issues

**Goal:** Each pending harness addition explicitly owns the CE requirement.

**Requirements:** R4, R5; AE3.

**Dependencies:** U1 establishes the wording to carry into comments.

**Files:** No repository code files. External targets:

| Issue | Harness | URL |
|---|---|---|
| #30 | Claude Code | https://github.com/hyperlapse122/dotfiles/issues/30 |
| #31 | Codex | https://github.com/hyperlapse122/dotfiles/issues/31 |
| #32 | Antigravity | https://github.com/hyperlapse122/dotfiles/issues/32 |
| #33 | pi | https://github.com/hyperlapse122/dotfiles/issues/33 |
| #34 | Grok Build | https://github.com/hyperlapse122/dotfiles/issues/34 |

**Approach:** Follow KTD2. Write comments in English, name the target harness, and present R3/R5 as requirements for that issue rather than claims of completed work. Point readers to `home/README.md` for the existing CE pattern and shared-instruction onboarding procedure. For pi, explicitly retain the synthetic.new-only constraint.

**Test expectation:** None — these are external documentation comments, not new application behavior.

**Verification:** Read back all five comments from GitHub, check AE3, and collect their permalinks. Posting failures remain incomplete work and are reported per the Goal Capsule.

## Verification Contract

- **Current native coverage:** During implementation, run `mise exec -- python tests/smoke_harness_plugins.py` in its disposable destination and retain the actual result. It must not target the owner's real home.
- **Documentation:** Inspect the rendered onboarding sections for R2/R3, accurate omp-only current coverage, and no added global instruction policies. Do not add source-text tests to pin wording.
- **External delivery:** Read each GitHub comment back and report a permalink for every U2 target. Do not represent a draft or a successful local CLI launch as a posted comment.
- **Verification boundary:** Planning does not execute these checks or post comments; future harness-native verification belongs to the respective onboarding issue.

## Definition of Done

- U1 meets its linked requirements and acceptance examples, with the current native smoke result recorded.
- U2 has verified comment permalinks for all five targets, with existing issue bodies, states, and constraints retained.
- No unrelated pins, runtime behavior, personal settings, or shared-instruction policy content changed; no temporary verification artifacts remain.
