---
title: Confirm Before Filing Issues in Repositories the User Does Not Manage - Plan
type: docs
date: 2026-08-05
topic: external-repo-issue-confirmation
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
deepened: 2026-08-05
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/149
---

# Confirm Before Filing Issues in Repositories the User Does Not Manage - Plan

## Goal Capsule

- **Objective:** Require explicit user confirmation — naming target repository, title, and body — before the agent creates an issue in a repository the user does not manage. Make the gate survive `lfg` autopilot and outrank the skill-level fallback chain that would otherwise file first.
- **Product authority:** Issue #149. `.chezmoitemplates/agents-instructions.tmpl` is the common instruction source; one edit reaches every agent surface through the harness wrappers.
- **Execution profile:** Three prose edits to one shared template. Source-only — no `chezmoi apply`, because the user did not request deployment.
- **Open blockers:** None.

---

## Product Contract

### Summary

The instruction core already limits issue creation to one purpose and gates it on a declared tracker, but it treats every repository alike. Filing into a third-party repository is a public, external side effect that cannot be undone, so it needs a human in the loop that the current rules never require. The gate itself is one paragraph edit. Making it hold needs two more, because the file's other rules currently defeat it: the `lfg` autopilot paragraph overrides ask-before-irreversible-action guidance, and the completion paragraph permits exactly one record-only outcome, which is not this one. All three edits are in the same file and land in one commit.

### Problem Frame

- `.chezmoitemplates/agents-instructions.tmpl:50` permits issue creation for exactly one purpose — routing an actionable code-review finding the MR/PR does not fix — and requires a duplicate search first. Neither precondition distinguishes the user's own repositories from third-party ones.
- `.chezmoitemplates/agents-instructions.tmpl:52` gates filing on a tracker the project declares. A third-party project can declare a tracker; the gate then passes and the agent files upstream with no confirmation.
- `.chezmoitemplates/agents-instructions.tmpl:17` states that during `lfg` the agent "MUST NOT pause to ask the user questions or seek confirmations" and that the autopilot "overrides the general ask-before-ambiguous/irreversible-action guidance". It carves out only the secrets and CI-weakening guards. A confirmation duty added at line 50 alone would read as overridden here.
- `.chezmoitemplates/agents-instructions.tmpl:52` also states that the no-declared-tracker case is "the one exception to the two-state rule" under which a committed record may stand alone. A new record-only outcome for unmanaged repositories would contradict that sentence directly, leaving two conflicting MUST-level rules in one file for exactly the motivating case.
- The `lfg` residual handoff (step 6) is the automated filing path, and it does **not** already implement the wanted refusal. Its `references/tracker-defer.md` computes `any_sink_available` from reachability alone — `gh auth status` plus `gh repo view --json hasIssuesEnabled` — with no repository-management dimension, and its GitHub Issues tier files via `gh issue create` where "Repo defaults to the current repo". A third-party checkout with a working `gh` therefore reaches `filed`, never `no_sink`. The `no_sink` bucket is a real durable sink, but nothing routes an unmanaged-repository finding into it today.
- Host CLIs derive a default issue target from the checkout's remotes. In a fork that default is not reliably the user's own fork, so a confirmation, an access test, and a filing call that each resolve the target independently can name three different repositories.
- Owner-name matching is not a usable test of "manages". The user maintains organization repositories they do not own, and a fork the user owns can have an upstream parent they do not.
- Both hosts expose a usable access datum, verified on this workstation. GitHub: `gh repo view --json viewerPermission`. GitLab: `glab api projects/<url-encoded-path>` returns `permissions.project_access` and `permissions.group_access`, each null or carrying an `access_level`.
- The template has exactly one harness conditional, an omp-only island at lines 67-69. All three target paragraphs sit in the unconditional body.

### Requirements

- R1. Before creating an issue in a repository the user does not manage, the agent MUST ask the user for confirmation.
- R2. The confirmation request MUST state the target repository, the proposed title, and the proposed body.
- R3. The agent MUST wait for an explicit answer. Absence of an answer MUST NOT be treated as consent.
- R4. "Does not manage" MUST be decided from the host's own access data, never from the owner name. Write access or better means the user manages the repository.
- R5. The access test MUST be fail-closed. An unavailable, failed, or ambiguous result MUST be treated as external.
- R6. The gate MUST stack on the existing issue-creation gates — the single permitted purpose, the duplicate search, and the declared-tracker gate — and MUST NOT weaken any of them.
- R7. An unattended run cannot obtain the confirmation, so it MUST NOT file into a repository the user does not manage. The finding MUST fall to the committed-record fallback and MUST be reported.
- R8. The `lfg` autopilot paragraph MUST name this gate among the prohibitions that survive autopilot. The naming MUST read as a prohibition that still binds, and MUST NOT read as permission to resume ordinary confirmation prompts during an unattended run.
- R9. The rule MUST be added to `.chezmoitemplates/agents-instructions.tmpl`, the common instruction source, not to a harness wrapper.
- R10. Everything else in the three edited paragraphs MUST survive unchanged in meaning.
- R11. The target repository MUST be resolved once, explicitly and authoritatively, never from a CLI remote-derived default. It is the repository hosting the MR/PR under review, or the work's target repository when none exists; in a fork that is the upstream parent, never the fork the agent pushed from. That single resolved value MUST be reused for the access test, for the confirmation request, and for the filing call.
- R12. The gate MUST bind before any skill-level fallback chain. The agent MUST re-apply the check immediately before invoking any tracker, Defer, or residual-handoff filing step, whatever that step's own probe reported, and a skill instruction to file silently or to skip blocking questions MUST NOT authorize filing into an unmanaged repository.
- R13. The completion paragraph MUST name the unattended-plus-unmanaged case as an explicit second exception to its two-state rule, so R7's record-only outcome does not contradict it.
- R14. The gate MUST cover commenting on an existing issue in an unmanaged repository, not only creating a new one. The duplicate-reuse duty above it MUST NOT become an ungated path to posting in a stranger's tracker.

### Scope Boundaries

**In scope**

- Sentences inserted into the issue-lifecycle paragraph at `.chezmoitemplates/agents-instructions.tmpl:50`, after the duplicate-search sentence.
- The carve-out clause amended in the `lfg` autopilot paragraph at `.chezmoitemplates/agents-instructions.tmpl:17`.
- The two-state exception sentence amended in the completion paragraph at `.chezmoitemplates/agents-instructions.tmpl:52`.

**Non-goals**

- `chezmoi apply`. The root `AGENTS.md` permits deployment only when the user asks; this run edits source state only. The deployed `~/.omp/agent/AGENTS.md` keeps its current text until the user applies.
- Editing the `lfg`, `ce-code-review`, or `tracker-defer` skill files. They live in the read-only plugin cache under `~/.omp/plugins/cache/`, so an edit there is neither repo-owned nor durable across a plugin update. R12 closes the same gap in the surface this repository does own: the instruction core binds the agent that executes those skills.
- The root `AGENTS.md` supplement. It never restated the issue rules and may not weaken the core.
- A machine-readable allowlist of managed repositories. The access probe answers the question live.

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R9.** The omp render carries the gate, and it names the target repository, the proposed title, the proposed body, and the duty to wait for an explicit answer.
- AE2. **Covers R4, R5.** The render names both host access probes with their write-or-better thresholds and states the fail-closed direction.
- AE3. **Covers R6.** The render states that the gate stacks on the existing rules and weakens none of them.
- AE4. **Covers R7, R8.** The render forbids unattended filing into an unmanaged repository and points at the committed-record fallback; the autopilot paragraph lists the gate among the prohibitions that still hold, phrased as a prohibition rather than a re-permission.
- AE5. **Covers R10.** The render still carries the single-purpose permission, the duplicate-search duty, the label/milestone/assignee prohibition, the self-assignment exception, the `Closes #N` / `Refs #N` chain, the autopilot merge-and-open obligations, and the completion paragraph's CI-watch and blocker chains.
- AE6. **Covers R11.** The render requires one explicit target resolution, names which repository is authoritative including the fork case, and states that the same resolved repository is used for the access test, the confirmation, and the filing call.
- AE7. **Covers R12.** The render states that the gate applies before any skill-level fallback chain, requires the check to be re-applied immediately before any tracker/Defer/residual-handoff filing step, and denies a silent-filing skill instruction any authority to bypass it.
- AE8. **Covers R13.** The completion paragraph names two exceptions to its two-state rule, and no longer says there is exactly one.
- AE9. **Covers R14.** The render states that the gate covers commenting on an existing issue as well as filing a new one, and the unattended prohibition names both acts.

### Success Criteria

One commit changes only the template and this plan. The omp render satisfies AE1-AE9. Both CI workflows are green on the pull request.

---

## Key Technical Decisions

- **KTD1 — Put the gate in the issue-lifecycle paragraph, immediately after the duplicate search.** Both are pre-filing preconditions on the same action, so they read as one chain. Issue #149 names this paragraph explicitly. The completion paragraph is edited too, but only for its exception count (KTD9), not for filing mechanics.
- **KTD2 — Decide "manages" from live access data, not from the owner name.** *Chosen over comparing the repository owner to the authenticated user: that test marks every organization repository the user maintains as external, and marks a fork the user owns as managed even when the filing target is the upstream parent.* Both probes are verified on this workstation:
  - GitHub — `gh repo view <owner>/<repo> --json viewerPermission`; `ADMIN`, `MAINTAIN`, or `WRITE` means managed.
  - GitLab — `glab api projects/<url-encoded-path>`; managed when `permissions.project_access.access_level` or `permissions.group_access.access_level` is at least `30` (Developer). Verified in both directions: an unmanaged project returns both objects null, and a managed one returns an access level. The path must be URL-encoded (`%2F`); the slashes-intact form the repository's `glab` rule prefers for other subcommands returns a null body on this raw API path.
- **KTD3 — Make the test fail-closed.** *Chosen over proceeding when the probe is unavailable: an unauthenticated, rate-limited, or private-repository failure is exactly the state in which the agent knows least, and the repository's own fact convention is that a false or unknown gate MUST skip rather than grant.* Because KTD2 names a working probe for both hosts, fail-closed is the genuine error path here, not the normal path.
- **KTD4 — State the rule for both hosts.** *Chosen over a GitHub-only clause: the surrounding paragraph is dual-platform in every other sentence, the hazard is identical on a third-party GitLab project, and `glab` is the primary GitLab CLI on this workstation.* Four reviewers flagged the earlier draft because it extended the rule to GitLab without a verified probe, which under KTD3 would have fail-closed every GitLab filing including the user's own. KTD2's verified `glab` probe removes that objection; without it, the correct move would have been to narrow to GitHub. Issue #149's acceptance criterion is satisfied because GitHub is named directly.
- **KTD5 — Amend the `lfg` autopilot carve-out in the same change.** *Chosen over editing only the issue paragraph: line 17 states that autopilot overrides the general ask-before-irreversible-action guidance and lists the guards that survive it. A confirmation duty not on that list is overridden by construction, and `lfg` step 6 is the only automated path that files issues, so the gate would be dead precisely where it matters.* This is a correctness dependency of R1, not extra scope.
- **KTD6 — Unattended runs are prohibited from filing, not permitted to proceed with a disclosure.** *Chosen over filing anyway and reporting afterwards: the hazard is the external side effect itself, and a post-hoc note does not undo a public issue in someone else's tracker.* The committed record is the durable sink, and R13 makes it a sanctioned outcome rather than a rule violation.
- **KTD7 — Source-only; do not run `chezmoi apply`.** *Chosen over deploying in this run: the root `AGENTS.md` permits deployment only when the user asks, and this request did not.* The deployed target updates on the user's next apply.
- **KTD8 — Close the fallback-chain race in the instruction core, not in the skill file.** *Chosen over amending `tracker-defer.md`'s GitHub Issues tier: that file lives in the read-only plugin cache, so the edit would be lost on the next plugin update and is not this repository's to own.* `tracker-defer`'s sink probe is reachability-only and its GitHub tier defaults the repo to the current checkout, so without R12 an unattended third-party run files before the gate is ever consulted. The instruction core binds the agent that executes the skill, so an explicit precedence sentence there is both durable and sufficient.
- **KTD9 — Amend the completion paragraph's exception count rather than rewording R7.** *Chosen over leaving line 52 alone: it currently says the no-declared-tracker case is "the one exception to the two-state rule", so R7's record-only outcome would ship as a direct contradiction in the same file.* The amendment adds the second exception and changes nothing else in that paragraph.

---

## Assumptions

- A1. No automated check asserts instruction body text. No `.ci/` script renders or greps this template, so an isolated render plus targeted phrase searches are the available mechanical gates.
- A2. `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` is the only wrapper that includes this template. Rendering it proves the change for every current agent surface.
- A3. The branch must carry a work-descriptive Git-Flow slug before the first push, not the aoe worktree name.

---

## Implementation Units

### U1. Add the unmanaged-repository confirmation gate

- **Goal:** The issue-lifecycle paragraph requires explicit, fully-specified confirmation before the agent files an issue in a repository the user does not manage; pins the target to one authoritative resolution; outranks any skill-level fallback chain; and forbids the filing outright when no one can answer.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R9, R10, R11, R12. Implements KTD1, KTD2, KTD3, KTD4, KTD6, KTD8.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the paragraph at line 50, inserting after the sentence ending "instead of creating a duplicate." and before the sentence beginning "Self-assignment of the authenticated user is the sole exception".
- **Approach:**
  1. Insert the gate at that boundary so it joins the existing chain of pre-filing preconditions.
  2. State the confirmation duty, the wait duty, and that no answer is not consent.
  3. Require the request to state target repository, proposed title, and proposed body.
  4. Require one explicit, authoritative target resolution, reused for the access test, the confirmation, and the filing call, and forbid relying on a CLI remote-derived default — which in a fork need not be the user's own fork (R11).
  5. Give the access test with its write-or-better threshold and name both verified probes from KTD2: the GitHub `viewerPermission` values and the GitLab `access_level` floor.
  6. State the fail-closed direction.
  7. State that the gate applies before any skill-level fallback chain, so a sink probe that only checks reachability cannot file ahead of it (R12).
  8. State that the gate stacks on the rules above and weakens none of them.
  9. State the unattended prohibition and point it at the committed-record fallback, which U3 makes a sanctioned outcome.
- **Execution note:** Prose edit to a shared instruction contract. Read the whole paragraph before editing and confirm the sentence boundary, so the self-assignment sentence that follows is neither absorbed nor reflowed.
- **Patterns to follow:** The compact RFC-2119 clause style used throughout this file; its obligation-then-exception sentence shape; its inline-code style for commands and identifiers. The prose-edit approach in `docs/plans/2026-07-30-003-docs-route-review-findings-plan.md`, which edited this same paragraph.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A1).` Proven by the Verification Contract.
- **Verification:** The omp wrapper renders without a template error. The render satisfies AE1, AE2, AE3, AE6, AE7, and the unattended half of AE4. The paragraph's untouched sentences satisfy their part of AE5.

### U2. Keep the gate alive under `lfg` autopilot

- **Goal:** The autopilot paragraph names the unmanaged-repository confirmation gate among the prohibitions that survive an unattended run, so the new duty is not read as overridden — and does so without reopening ordinary confirmation prompts.
- **Requirements:** R8, R10. Implements KTD5.
- **Dependencies:** U1 — the gate U2 names is the one U1 creates. Both land in one commit.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the final clause of the paragraph at line 17, currently "the secrets and CI-weakening guards are separate prohibitions, not confirmations, and still hold."
- **Approach:** Extend that clause only. Add the unmanaged-repository issue-filing gate to the list of prohibitions that survive autopilot, keeping the clause's existing "prohibitions, not confirmations" framing so the addition inherits it. Leave the preceding sentences — full autonomy, opening the MR/PR, merging once CI is green — byte-identical.
- **Execution note:** The edit must not turn the clause into a general re-permission to ask questions during `lfg`. What survives autopilot is the refusal to file, not a prompt; an unattended run still does not stop to ask (R8, second sentence).
- **Patterns to follow:** The existing list shape in that clause; the same guard-versus-confirmation distinction it already draws.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A1).` Proven by the Verification Contract.
- **Verification:** The render satisfies the autopilot half of AE4. The autopilot paragraph's untouched sentences satisfy their part of AE5.

### U3. Sanction the record-only outcome in the completion paragraph

- **Goal:** The completion paragraph names two exceptions to its two-state rule, so the unattended-plus-unmanaged record-only outcome is a sanctioned end state rather than a contradiction of the same file.
- **Requirements:** R13, R10. Implements KTD9.
- **Dependencies:** U1 — the outcome U3 sanctions is the one U1's prohibition produces. All three units land in one commit.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the sentence at line 52 beginning "With no such declaration, the one exception to the two-state rule applies".
- **Approach:** Rewrite that sentence so the no-declared-tracker case is named as one exception rather than the only one, then add the second: an unattended run barred by the unmanaged-repository gate records the finding and reports it. Change nothing else in the paragraph — the CI-watch chain, the two-state rule itself, the supplement-not-replace rule, the advisory exemption, the issue-contents requirement, the declared-tracker gate, and the blocker chain all stay byte-identical.
- **Execution note:** The two-state rule stays a `MUST`. This edit widens its exception list by exactly one named case; it does not soften the rule or add a general escape.
- **Patterns to follow:** The obligation-then-exception sentence shape already used in this paragraph.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A1).` Proven by the Verification Contract.
- **Verification:** The render satisfies AE8. The paragraph's untouched sentences satisfy their part of AE5, and the phrase "the one exception to the two-state rule" no longer appears.

---

## Verification Contract

| Check | Command / method | Units |
| --- | --- | --- |
| Render check | `chezmoi --config <scratch>/empty.toml --source "$PWD" --destination <scratch>/target execute-template < dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`, with a stubbed `op` on `PATH` and a per-user scratch directory. Exit 0, no template error. The edited file is a `.chezmoitemplates` partial, not a target, so it is compared as rendered text. | U1, U2, U3 |
| Presence check | The render states the confirmation duty, the explicit wait, target repository, proposed title, proposed body, the write-or-better access test, `viewerPermission`, the GitLab `access_level` floor, the fail-closed direction, the stacks-and-weakens-none clause, the unattended prohibition, and that it points at the committed-record fallback (AE1, AE2, AE3, AE4). | U1 |
| Target-resolution check | The render requires one explicit target resolution and states that the same resolved repository is reused for the access test, the confirmation, and the filing call (AE6). | U1 |
| Fallback-precedence check | The render states that the gate applies before any skill-level fallback chain (AE7). | U1 |
| Autopilot check | The render's autopilot paragraph lists the unmanaged-repository issue-filing gate among the prohibitions that still hold, and still reads as a prohibition rather than permission to prompt (AE4). | U2 |
| Two-state-exception check | The render's completion paragraph names two exceptions to the two-state rule, and `the one exception to the two-state rule` returns zero matches (AE8). | U3 |
| Preservation check | The render still contains the single-purpose permission, the duplicate-search duty, the label/milestone/assignee prohibition, `MUST NOT run a direct issue close or reopen`, the self-assignment exception, `Closes #1, Closes #2, Closes #3`, the autopilot merge-and-open obligations, and the completion paragraph's CI-watch and blocker chains (AE5). | U1, U2, U3 |
| Harness-island check | The omp-only `glab` CLI sentence still renders, proving the single harness conditional survived. | U1, U2, U3 |
| Source-delta check | `git diff --word-diff` on the template shows only the inserted sentences and the two amended clauses — no reflow of surrounding sentences. `git diff --check` is clean. | U1, U2, U3 |
| Scope check | `git status` and the diff show only `.chezmoitemplates/agents-instructions.tmpl` and this plan changed. | U1, U2, U3 |
| Branch check | The branch carries a work-descriptive Git-Flow slug before the first push, not the aoe worktree name (A3). | U1, U2, U3 |
| CI | `ci.yml` triggers on every push and pull request. `render-dotfiles.yml` triggers on pull requests, and its `apply --init (fedora)` job renders the full managed tree including this template's target. Both MUST reach terminal success on the pull request. | U1, U2, U3 |

---

## Definition of Done

- `.chezmoitemplates/agents-instructions.tmpl` satisfies R1-R14.
- The omp render satisfies AE1-AE9.
- The branch is renamed in place to a work-descriptive Git-Flow slug before the first push.
- One lowercase Conventional Commit with a `docs(agents):` subject lands the change. A pull request carrying `Closes #149` is open, and both workflows are green on it.
- No `chezmoi apply` was run (KTD7).

---

## Open Questions

- None blocking.

---

## System-Wide Impact

Every agent run on this workstation reads the rendered instruction core, so all three edits change agent behavior everywhere once the user applies. The behavior change is a new refusal path, not a new capability: runs that used to file upstream silently will now either ask or fall back to the committed record. R12 and R13 are what make that refusal reach the automated path — without them the `lfg` residual handoff would keep filing through a reachability-only sink probe, and the record-only outcome would violate the completion paragraph's two-state rule.

---

## Sources / Research

- Issue #149 — the request, its proposed change, and its three acceptance criteria.
- `.chezmoitemplates/agents-instructions.tmpl:17` — the autopilot carve-out amended by U2; `:50` — the issue-lifecycle paragraph extended by U1; `:52` — the completion paragraph amended by U3, including the "one exception to the two-state rule" sentence and the declared-tracker gate; `:67-69` — the sole harness conditional, untouched.
- `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` — the one-line `includeTemplate "agents-instructions.tmpl" (dict "harness" "omp")` wrapper, and the only render needed to prove the change (A2).
- `gh repo view --json` field list on this host — confirms `viewerPermission` exists alongside `owner`, `nameWithOwner`, and `viewerCanAdminister` (KTD2). `gh issue create --repo` confirms an explicit target flag exists (R11).
- `glab api projects/<url-encoded-path>` run against one unmanaged and one managed project on this host — confirms `permissions.project_access` / `permissions.group_access` and the `access_level` values that back the GitLab half of KTD2, and confirms the slashes-intact form returns a null body on this raw API path.
- `lfg` skill `references/tracker-defer.md` — `any_sink_available` computed from `gh auth status` plus `gh repo view --json hasIssuesEnabled` with no management dimension, and the GitHub Issues tier documented as `gh issue create` with "Repo defaults to the current repo". This is the evidence for KTD8 and R12.
- `docs/plans/2026-07-30-003-docs-route-review-findings-plan.md` — prior art for editing this same paragraph, including the isolated-render verification contract reused here.
- Root `AGENTS.md` — edit source state, never deployed `$HOME`; apply only on user request (KTD7); `--source "$PWD"` for nested worktrees; fail-safe gate direction (KTD3).
- `.github/workflows/ci.yml` and `.github/workflows/render-dotfiles.yml` — unfiltered triggers; the `apply --init (fedora)` job is the only CI surface that renders this template, and it asserts nothing about its content (A1).
- `ce-doc-review` round 1, six personas — three P0 findings (completion-paragraph contradiction, unresolved target repository, fallback-chain race) and one P1 converged across four reviewers (unverified GitLab probe) were applied; the GitLab probe was verified rather than narrowed away.
- `ce-code-review` round 1, five personas (cross-model peer unavailable: omp host un-attestable) — a P0 converged across the security and adversarial lenses (prose precedence over `tracker-defer`'s silent fallback chain was unenforceable as written) and a P1 converged across the same two (the duplicate-reuse duty let an agent comment in a stranger's tracker ungated) drove R12's runtime re-check and R14. A P1 from the agent-native lens (which repository is authoritative in a fork) drove R11's second sentence. Standards-lens P3s split the inserted multi-idea sentences to satisfy this file's own ASD-STE100 rule.
