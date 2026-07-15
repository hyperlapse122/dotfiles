---
title: Remove User-Scoped Local Agent Skills - Plan
type: chore
date: 2026-07-15
topic: remove-local-agent-skills
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Remove User-Scoped Local Agent Skills - Plan

## Goal Capsule

- **Objective:** Delete all twelve user-scoped *local* (`path:`) agent skills from the dotfiles source and reconcile every reference to them so no agent instruction points at a skill that no longer ships.
- **Product authority:** Repo owner (dotfiles maintainer). Decisions in this doc are confirmed.
- **Open blockers:** None. Scope is settled; two low-risk items are flagged as apply-time verifications, not blockers.

---

## Product Contract

### Summary

Remove the twelve vendored `path:` skills under `dot_agents/skills/` and their `[[skills]]` declarations, then clean up every place the two agent-instruction files, the README, and the `src-audit` tool still reference them. `harness-delegation` is removed in full — its always-on guardrail section goes too, not just the skill. The remaining always-on guardrails, the external skills, the project-scoped skills, and the MCP/dotagents scaffolding are untouched.

### Problem Frame

`dot_agents/skills/` holds twelve local `path:` skills that deploy to `~/.agents/skills/` and register with `dotagents` for Claude Code and Codex. They are distinct from the *external* user-scoped skills (`playwright-cli`, `improve`, fetched as chezmoi externals) and from the repo's own *project-scoped* skills (`ce-*`, `dotagents`). The cost of removal is not the twelve directories — it is the reference web. The Routing Index and inline `→ skill` citations in `dot_agents/readonly_AGENTS.md` deploy to every agent (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`), and the repo `AGENTS.md`, `README.md`, and `dot_local/bin/executable_src-audit` all name these skills. Deleting the directories without reconciling those references would leave every agent on every machine pointed at skills that no longer exist — a violation of the repo's zero-drift standard.

### Key Decisions

- **Local skills only.** "User-scoped local skills" resolves to the twelve vendored `path:skills/<name>` entries. The word *local* excludes the external user-scoped skills (`playwright-cli`, `improve`), which stay. Project-scoped skills stay.
- **`harness-delegation` removed in full.** Unlike the other eleven, its always-on "Delegating to another agent harness" guardrail section in `readonly_AGENTS.md` is removed as well, not just the skill. After this change no delegation guidance remains — including the least-privilege, no-secrets-in-brief, stay-accountable, and no-onward-delegation rules.
- **Guardrails stay; only skill pointers go.** For the other eleven, removal strips the detailed playbooks and their `→ skill` citations, but the self-contained always-on rule bodies (branch naming, commit messages, rebase, issue↔MR scope, CI/CD, JS package managers, project layout, GitLab CLI) remain verbatim as agent behavior.
- **dotagents/MCP scaffolding stays.** `agents.toml`, `agents = ["claude", "codex"]`, the `[trust]` block, the `install-dotagents-skills` script, and the `~/.claude/skills` symlink remain, because the external skills and MCP servers still depend on them. dotagents becomes an MCP-only provisioner.

### Requirements

**Skill deletion**

R1. All twelve local skill directories are deleted from `dot_agents/skills/`: `ci-cd-monitoring`, `daily-report`, `git-branch-cleanup`, `git-workflow`, `gitlab-issues`, `glab`, `glab-stack`, `harness-delegation`, `js-package-managers`, `pr-mr`, `ship-issue`, `src-layout`.

R2. All twelve `[[skills]]` blocks are removed from `dot_agents/private_readonly_agents.toml.tmpl`, leaving `version`, `agents`, `[trust]`, and the `.agents.mcp.servers` range intact. The header comment that describes the "twelve local path skills" is rewritten to reflect that only MCP servers remain declared here.

**Shared agent-instruction reconciliation — `dot_agents/readonly_AGENTS.md`**

R3. The ten Routing Index rows for removed skills are deleted, leaving only the `playwright-cli` row.

R4. The "Delegating to another agent harness (guardrail)" section is removed in full, along with its Routing Index row and its `→ harness-delegation` citation.

R5. Every dangling `→ <skill>` citation for a removed skill is stripped from the retained guardrail sections (the parentheticals pointing to `git-workflow`, `pr-mr`, `gitlab-issues`, `ci-cd-monitoring`, `js-package-managers`, `src-layout`). The guardrail *bodies* stay verbatim. The `→ playwright-cli` citation stays.

**Repository documentation reconciliation**

R6. The repo `AGENTS.md` is reconciled so every "twelve local skills" reference reflects zero local skills: the "Agent skills, MCPs & trust — managed by dotagents" section, the harness-delegation prose, the "Single source of truth" agent bullets, and the `.chezmoiremove` explanatory comment (currently "eleven chezmoi-managed local skills"). dotagents is described as provisioning MCP servers only; externals remain described as chezmoi externals.

R7. `README.md` is updated wherever it describes dotagents deploying "local agent skills" (the apply-flow narrative and the `dot_agents/` structure bullet) to reflect MCP-only dotagents provisioning.

R8. `dot_local/bin/executable_src-audit` drops its "Procedure reference: the src-layout skill" line, which dangles once `src-layout` is gone.

**Deployment cleanup**

R9. Deleting the chezmoi-managed skill sources removes the deployed `~/.agents/skills/<name>` targets on the next apply, leaving only the external skills there. No `dotagents` lock residue or orphaned directory remains (see Dependencies for the verification).

R10. `.chezmoiscripts/70-agents/run_onchange_after_install-dotagents-skills.sh.tmpl` is not modified except for its descriptive header comment (skills → MCP-only); its fingerprint over the `agents.toml` template re-triggers automatically on the R2 edit, so dotagents re-runs and de-registers the skills with no manual step.

### Scope Boundaries

**In scope:** the twelve skill directories, their `[[skills]]` blocks, the `readonly_AGENTS.md` reconciliation (including the harness-delegation guardrail section), the repo `AGENTS.md` / `README.md` / `src-audit` reconciliation, and deployment-cleanup verification.

**Out of scope:**
- External user-scoped skills (`playwright-cli`, `improve`) and their `agents.skills.external` / `.chezmoiexternals/ai-agents.toml` machinery.
- Project-scoped skills under `.agents/skills/` (`ce-*`, `dotagents`) and project `.opencode/commands/` entries such as `daily-report.md`.
- The MCP servers (`codegraph`, `glab`, `context7`, `websearch`) and the dotagents/`agents.toml`/install-script scaffolding beyond R2/R10.
- The eleven retained guardrail bodies (branch naming, commits, rebase, issue↔MR, CI/CD, JS package managers, project layout, GitLab CLI) — kept, only their skill pointers removed.
- Other delegation mechanisms (`pi-subagents`, oh-my-openagent per-agent models) — unrelated to the `harness-delegation` skill.

### Success Criteria

- After `chezmoi apply`, `~/.agents/skills/` contains only the external skills; the twelve are gone with no residue.
- Searching the source tree for each removed skill name returns only historical `docs/plans/` hits — no live instruction, tool, or config references a removed skill.
- The rendered `readonly_AGENTS.md` has a one-row Routing Index (`playwright-cli`) and no "Delegating to another agent harness" section; every retained guardrail body is unchanged.
- The stub-`op` render + archive checks pass with no template errors (`private_readonly_agents.toml.tmpl` still renders valid TOML; the install-dotagents-skills fingerprint changes and re-triggers).

### Dependencies / Assumptions

- **Assumption (verify at apply):** `dot_agents/skills/<name>/` are chezmoi-managed targets, so deleting the source auto-removes `~/.agents/skills/<name>` — no `.chezmoiremove` entries needed. This follows the repo's own rule ("delete the source entry; chezmoi removes the deployed target"); the existing `.chezmoiremove` `ce-*` entries exist only because those skills were dotagents-*fetched*, not chezmoi-managed. Confirm on a real apply that dotagents leaves no stale lock entry or directory.
- **Assumption:** the `[trust] git_domains = ["git.jpi.app"]` entry is inert once the local skills go — no dotagents git-source references `git.jpi.app` (every occurrence is glab auth, the git credential config, or VSCodium settings). Dropping it is optional cleanup, not required.
- The `install-dotagents-skills` script provisions MCP servers independently of any skill, so an empty skill set does not break provisioning.

### Outstanding Questions

**Resolve before planning:** none.

**Deferred to planning:**
- Whether to also drop the inert `git.jpi.app` `[trust]` entry (recommend keeping — harmless and future-proofs re-adding a git-sourced skill; drop only if a leaner core is wanted).
- Exact rewording of the reconciled prose in `AGENTS.md` / `README.md` (mechanical; settle while editing).

---

## Planning Contract

**Product Contract preservation:** unchanged — this enrichment adds only HOW (Planning Contract, Implementation Units, Verification Contract, Definition of Done). No R-ID text or scope boundary was altered.

### Key Technical Decisions

KTD1. **Source deletion, not `.chezmoiremove`, for the skill directories.** `dot_agents/skills/<name>/` are chezmoi-managed targets, so deleting the source removes the deployed `~/.agents/skills/<name>` on the next apply. This differs from the existing `.chezmoiremove` `ce-*` entries, which exist only because those skills were dotagents-*fetched* (chezmoi never owned them). No new `.chezmoiremove` entries are added. Confirm at apply that no dotagents lock entry or empty directory residue remains (A1).

KTD2. **`harness-delegation` removed in full; the other citing skills keep their guardrail bodies.** In `dot_agents/readonly_AGENTS.md` the "Delegating to another agent harness" guardrail section is deleted along with the skill. Every other always-on guardrail body (branch naming, commit messages, rebase, issue↔MR scope, CI/CD, JS package managers, project layout, GitLab CLI) stays verbatim; only its now-dangling `→ <skill>` citation is stripped.

KTD3. **dotagents becomes MCP-only; the scaffolding stays.** `version`, `agents = ["claude", "codex"]`, `[trust]`, the `.agents.mcp.servers` range, and the `install-dotagents-skills` script are retained. Editing the toml changes that script's fingerprint over the file, so dotagents re-runs and de-registers the skills automatically on the next apply — no manual step and no script logic change (only its header comment updates).

KTD4. **`git.jpi.app` `[trust]` entry left in place.** Verified inert (no dotagents git-source references it), but harmless and future-proofs re-adding a git-sourced skill. Dropping it is optional cleanup, out of scope by default (see Outstanding Questions).

### Assumptions

- A1. Deleting the chezmoi-managed skill sources removes the deployed targets on apply; verify no dotagents lock entry or empty `~/.agents/skills/<name>` directory persists.
- A2. Removing the `[[skills]]` blocks leaves valid TOML (`version`, `agents`, `[trust]`, then the MCP range) and dotagents provisions MCP servers with an empty skill set.

### Sequencing

U1-U4 touch disjoint files and are independent — do them in any order, landing as one logical commit. Run the Verification Contract after all edits. No cross-unit dependency. High-Level Technical Design is omitted: the change is deletion plus reference reconciliation, fully carried by the units and the reference map in each unit.

---

## Implementation Units

### U1. Remove the twelve local skills

- **Goal:** Delete the vendored skills and their registration.
- **Requirements:** R1, R2.
- **Files:** `dot_agents/skills/` (delete all twelve subdirectories: `ci-cd-monitoring`, `daily-report`, `git-branch-cleanup`, `git-workflow`, `gitlab-issues`, `glab`, `glab-stack`, `harness-delegation`, `js-package-managers`, `pr-mr`, `ship-issue`, `src-layout`); `dot_agents/private_readonly_agents.toml.tmpl`.
- **Approach:** Delete the twelve directories. In the toml, remove the twelve `[[skills]]` blocks (currently lines 25-71), leaving `version`, `agents`, `[trust]`, and the `{{- range .agents.mcp.servers }}` block untouched. Rewrite the header comment so it no longer describes "twelve local path skills" — state that only MCP servers are declared here now (externals deploy via `.chezmoiexternals`).
- **Test Scenarios:** Rendered toml is valid TOML with the `[[mcp]]` blocks intact and zero `[[skills]]` blocks; the `git.jpi.app` `[trust]` entry is retained.
- **Verification:** V1.

### U2. Reconcile the shared core instructions (`readonly_AGENTS.md`)

- **Goal:** Remove every reference to the removed skills from the deployed agent core; delete the harness-delegation guardrail in full; keep all other guardrail bodies verbatim.
- **Requirements:** R3, R4, R5.
- **Files:** `dot_agents/readonly_AGENTS.md`.
- **Approach:**
  - **Routing Index:** delete the ten rows for removed skills (`pr-mr`, `gitlab-issues`, `ci-cd-monitoring`, `git-workflow`, `js-package-managers`, `ship-issue`, `git-branch-cleanup`, `daily-report`, `src-layout`, `harness-delegation`), leaving only the `playwright-cli` row.
  - **Guardrail section:** delete the entire "## Delegating to another agent harness (guardrail)" section.
  - **Citations:** strip each dangling `→ <skill>` parenthetical for a removed skill from the retained guardrail sections (Branch naming, Commit messages, Rebase, Issue↔MR scope, CI/CD, JavaScript package managers, Project layout, GitLab CLI); keep the guardrail bodies verbatim. Keep the `→ playwright-cli` citation in Browser automation.
  - Leave the header `> Skills:` note intact (it still applies to `playwright-cli`); reword only if it names a removed skill.
- **Test Scenarios:** Routing Index has exactly one row (`playwright-cli`); no "Delegating to another agent harness" heading; searching the file for any removed skill name returns nothing; every retained guardrail rule body is unchanged.
- **Verification:** V2, V3.

### U3. Reconcile the repository `AGENTS.md` and `.chezmoiremove`

- **Goal:** Bring the repo's own documentation to zero local skills with no drift.
- **Requirements:** R6.
- **Files:** `AGENTS.md`, `.chezmoiremove`.
- **Approach:** Rewrite the "### Agent skills, MCPs & trust — managed by `dotagents`" section (the `dotagents` scope line, the `[trust]` description, and the twelve-skill enumeration bullet) so dotagents provisions MCP servers + trust only and the local `path:` skills are gone. Remove the `harness-delegation`-skill reference at the pi-MCP `lifecycle: eager` bullet and the `src-layout`-skill reference in the garden/src section — reword to describe the behavior without citing a skill. Update the "Single source of truth" clause stating the twelve local skills stay literal `path:` entries. Update the script-tree table cell ("dotagents skills/MCPs" → MCPs) and the container-section mention if it names local skills. Update the `.chezmoiremove` explanatory comment referencing "the eleven chezmoi-managed local skills" so it no longer asserts a local-skill count; leave the `ce-*` / `lfg` removal patterns themselves unchanged.
- **Test Scenarios:** No live prose in `AGENTS.md` claims local `path:` skills exist; the `.chezmoiremove` comment is consistent with zero local skills; the `ce-*` removal entries are byte-unchanged.
- **Verification:** V2.

### U4. Reconcile `README.md` and `src-audit`

- **Goal:** Fix the two peripheral references.
- **Requirements:** R7, R8.
- **Files:** `README.md`, `dot_local/bin/executable_src-audit`.
- **Approach:** In `README.md`, update the apply-flow narrative and the `dot_agents/` structure bullet where they say dotagents deploys "local agent skills" so they describe MCP-server provisioning only (externals still deploy via `.chezmoiexternals`). In `executable_src-audit`, remove the "Procedure reference: the src-layout skill" line (dangling once the skill is gone).
- **Test Scenarios:** Neither file references a removed skill; `README.md` still correctly describes external-skill and MCP provisioning.
- **Verification:** V2.

---

## Verification Contract

This is a documentation/config change — proof is render validity plus zero dangling references, not unit tests. All render checks use the stub-`op` + throwaway-destination recipe documented in `AGENTS.md` ("The stub-`op` + throwaway-destination recipe"), so no real 1Password auth or live `$HOME` is touched.

- V1. **Render the toml.** `chezmoi execute-template < dot_agents/private_readonly_agents.toml.tmpl` under the stub-`op` recipe (drop the trailing newline in the stub so the rendered TOML parses). Expect: valid TOML, `[[mcp]]` blocks present, zero `[[skills]]` blocks, exit 0.
- V2. **Dangling-reference sweep.** `rg -n 'path:skills/' dot_agents/` → zero hits. `rg -n 'dot_agents/skills' --glob '!docs/plans/**'` → zero hits. For each removed skill name, confirm no live Routing Index row or `→ <skill>` citation survives in `AGENTS.md` or `dot_agents/readonly_AGENTS.md` (historical `docs/plans/` hits are allowed; bare CLI mentions of `glab` are not skill references).
- V3. **Render a wrapper that includes the core.** Stub-`op` render of `dot_claude/readonly_CLAUDE.md.tmpl` (or the codex / opencode wrapper); expect the included `readonly_AGENTS.md` body to show a one-row Routing Index and no "Delegating to another agent harness" section.
- V4. **Archive diff (optional, thorough).** Archive base vs branch per the `AGENTS.md` recipe (`--exclude=encrypted,externals,scripts`) and confirm the only target-state changes are the removed skill files plus the intended doc edits.
- V5. **Real apply (host-dependent, end-to-end).** On a real host, `chezmoi apply`, then confirm `~/.agents/skills/` contains only the external skills (`playwright-cli`, `improve`) and dotagents left no lock or empty-directory residue (A1). Flag explicitly if not run in this environment.

---

## Definition of Done

- All twelve `dot_agents/skills/` subdirectories deleted; all twelve `[[skills]]` blocks removed; the toml renders as valid TOML with `[[mcp]]` blocks intact (V1).
- `dot_agents/readonly_AGENTS.md`: Routing Index has only the `playwright-cli` row; the "Delegating to another agent harness" section is gone; every other guardrail body is byte-unchanged; no `→ <removed-skill>` citation remains.
- `AGENTS.md`, `.chezmoiremove`, `README.md`, and `dot_local/bin/executable_src-audit` reflect zero local skills with no drift.
- V2 dangling-reference sweep returns only historical `docs/plans/` hits.
- Product Contract unchanged (WHAT boundary preserved).
- No abandoned or experimental edits left in the diff.
- Lands as one logical commit in the repo's Conventional Commits style (`chore(agents): …`), per one-change-one-commit.
