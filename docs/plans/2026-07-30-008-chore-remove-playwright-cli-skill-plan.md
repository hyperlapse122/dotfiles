---
title: Remove the playwright-cli Agent Skill - Plan
type: chore
date: 2026-07-30
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove the playwright-cli Agent Skill - Plan

## Goal Capsule

- **Objective:** Stop provisioning and routing agents to the `playwright-cli` skill, and retire its release-lock identity without changing the distinct `agent-browser` capability.
- **Authority:** The user request and the repository's agent-surface ownership rules outrank this plan. `.chezmoidata/agents.yaml` remains the skill and MCP source of truth; `packages/release-lock/src/registry.ts` remains the release source of truth.
- **Execution profile:** Remove one external-skill entry, prune its deployed target on the next user-initiated apply, remove its live instruction references, and retire its generated release metadata. No MCP server named `playwright-cli` exists to delete.
- **Stop conditions:** Stop if repository evidence connects `playwright-cli` to the `agent-browser` MCP, if the release-lock refresh is partial or fails, or if a render changes any unrelated agent skill or MCP declaration.
- **Tail ownership:** LFG owns implementation, review, commit, PR creation, and CI. Verification must not run a live `chezmoi apply` against `$HOME`.

---

## Product Contract

### Summary

Remove the `playwright-cli` external skill from the managed agent inventory and eliminate live routing text that requires it. Preserve `agent-browser`, whose skill, MCP server, and binary are independent declarations.

### Problem Frame

`.chezmoidata/agents.yaml` provisions `playwright-cli` as an external skill, while the shared instruction template tells every managed harness to load it for browser and Playwright work. Removing only the YAML row would stop future fetches but leave agents routed to a missing skill, leave the deployed skill directory unmanaged, and leave an unused release-lock registry key.

The MCP inventory contains no server named `playwright-cli`. Its browser-related server is `agent-browser`, with its own skill and binary. Treating that distinct row as the requested MCP would remove more capability than the user named.

### Requirements

- R1. `agents.skills.external` no longer declares `playwright-cli` or `microsoft/playwright-cli`.
- R2. `agents.mcp.servers` contains no `playwright-cli` entry, and the existing `agent-browser` MCP and skill declarations remain unchanged.
- R3. Managed agent instructions contain no live requirement or routing reference to the retired `playwright-cli` skill.
- R4. The release-lock registry and generated lock contain no `playwright-cli` key after a successful authoritative refresh.
- R5. Generic skill rendering still emits every remaining external skill and no `playwright-cli` target.
- R6. Historical records under `docs/plans/` remain unchanged.
- R7. Verification uses isolated rendering and repository tests only; it does not deploy to the live home directory.
- R8. The next user-initiated apply prunes the deployed `.agents/skills/playwright-cli` target through `.chezmoiremove`; implementation does not apply changes to the live home directory.

### Scope Boundaries

**Out of scope**

- The independent `agent-browser` external binary, skill, MCP server, and release-lock entry.
- Historical `playwright-cli` references in completed plan documents.
- A manual or live `chezmoi apply`; implementation declares the forward-only prune, and the next user-initiated apply performs deployed-state reconciliation.
- A replacement static routing rule for `agent-browser`; its skill and MCP already advertise their own applicability.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Match names, not capabilities.** Remove the `playwright-cli` external-skill row and verify that no same-name MCP row exists. Preserve `agent-browser` because it has separate source, command, skill, and release identities.
- KTD2. **Remove the obsolete routing sentences instead of substituting new policy.** Delete the routing sentence whose only operation-skill example is `playwright-cli`, and delete the final browser-work clause from the LFG paragraph. Adding new `agent-browser` routing language would expand the request and duplicate instructions already supplied by that skill and MCP.
- KTD3. **Retire release metadata through its generator.** Delete the version-only registry entry, then run the release-lock CLI. A clean resolution is authoritative and prunes retired keys; a partial resolution retains old keys by design and is therefore a stop condition for this change.
- KTD4. **Keep generic consumers generic.** `.chezmoiexternals/ai-agents.toml` already ranges over `agents.skills.external`. It needs verification, not a per-skill edit.
- KTD5. **Use existing tests and render smoke checks.** The release-lock suite already proves that clean refreshes prune retired keys and partial refreshes retain the last good lock. This removal introduces no new runtime branch that needs a new test.
- KTD6. **Prune the deployed external through `.chezmoiremove`.** Removing an external declaration stops management but does not remove the already-deployed target. Add the exact `.agents/skills/playwright-cli` target path to the repository's forward-only removal manifest; do not add a teardown script or run a live apply.

### Assumptions

- The user's “MCP” means a `playwright-cli`-named declaration in the named MCP inventory, not the distinct `agent-browser` server.
- The release sources are reachable during implementation so the generated lock can be refreshed with zero failures. A failed refresh is not bypassed or hand-edited.

### Sequencing

Retire the skill and release registry entry first, and declare the deployed-target prune in the same unit. Refresh the generated lock only after the registry no longer contains `playwright-cli`. Then remove the shared instruction references and run the full render and test gates against the final source state.

---

## Implementation Units

### U1. Retire the playwright-cli skill identity

**Goal:** Remove the skill from the agent inventory and release-lock sources while preserving every sibling declaration.

**Requirements:** R1, R2, R4, R5, R7, R8; KTD1, KTD3, KTD4, KTD5, KTD6

**Dependencies:** none

**Files:**

- `.chezmoidata/agents.yaml` — remove only the `playwright-cli` external-skill list item.
- `.chezmoiremove` — add the exact deployed external-skill target so the next user-initiated apply prunes it.
- `packages/release-lock/src/registry.ts` — remove the version-only registry entry and its now-obsolete comment.
- `.chezmoidata/releases.json` — generated output refreshed through the release-lock CLI, never hand-edited.
- `packages/release-lock/test/cli.test.ts` — existing clean-refresh pruning and partial-refresh preservation coverage, used unchanged.
- `packages/release-lock/test/registry.test.ts` — existing registry integrity coverage, used unchanged.
- `.chezmoiexternals/ai-agents.toml` — generic external-skill render loop, verified unchanged.

**Approach:** Delete the exact `playwright-cli` rows from the two hand-maintained registries. Add `.agents/skills/playwright-cli` to `.chezmoiremove` in its existing agent-skill removal section. Re-run the release-lock generator and accept its output only on exit 0. Inspect the generated diff so unrelated version movement does not hide the intended retired-key removal. Do not touch the generic external-skill template or any `agent-browser` row.

**Patterns to follow:** `.chezmoidata/agents.yaml` as the neutral agent source; `packages/release-lock/src/cli.ts` clean-refresh contract; the prior local-agent-skills removal plan's dangling-reference rule; existing forward-only agent-skill entries in `.chezmoiremove`.

**Test scenarios:**

- Inventory isolation: rendering the external-skills template produces no `.agents/skills/playwright-cli` target and still produces `agent-browser`, `improve`, `glab`, and `glab-stack` targets.
- Deployed-target reconciliation: rendering `.chezmoiremove` contains the exact `.agents/skills/playwright-cli` prune path and preserves the existing agent-skill removal entries.
- MCP isolation: the shared MCP inventory renders successfully for Claude and omp; `agent-browser` is unchanged and no `playwright-cli` server appears.
- Release retirement: a successful generator run removes only the retired `playwright-cli` key unless upstream versions independently changed during the same authoritative refresh.
- Failure safety: the existing CLI test proves a partial refresh retains retired keys and exits nonzero, so implementation treats any such run as failed rather than claiming the lock was pruned.

**Verification:** The release-lock tests and typecheck pass; isolated chezmoi rendering shows the skill absent, the prune declared, and all sibling skills/MCP servers intact.

### U2. Remove live playwright-cli routing instructions

**Goal:** Ensure no managed harness is told to load a skill that source state no longer provides.

**Requirements:** R3, R6, R7; KTD2

**Dependencies:** U1

**Files:**

- `.chezmoitemplates/agents-instructions.tmpl` — remove the `playwright-cli` routing sentence and the final browser-work clause while preserving unrelated LFG, Figma, tmux, process, and scratch rules.
- `dot_claude/readonly_CLAUDE.md.tmpl` — existing wrapper, rendered unchanged except for included instruction content.
- `dot_codex/readonly_AGENTS.md.tmpl` — existing wrapper, rendered unchanged except for included instruction content.
- `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` — existing wrapper, rendered unchanged except for included instruction content.

**Approach:** Make sentence-scoped edits to the common instruction source. Remove the operation-skill sentence whose only example is `playwright-cli`; remove only the final browser-work sentence from the LFG paragraph. Do not add replacement `agent-browser` policy or edit the one-line harness wrappers. Preserve the repository `CLAUDE.md` mirrors exactly as `@AGENTS.md`.

**Patterns to follow:** The shared-instruction composition rule in `AGENTS.md`; the prior local-agent-skills removal plan's rule that no live routing reference may survive a removed skill.

**Test scenarios:**

- Each managed wrapper renders without `playwright-cli` or `microsoft/playwright-cli`.
- The rendered text around the removed sentences retains the unrelated `ce-work`/`ce-debug`, Figma MCP, tmux, and scratch-directory rules byte-for-byte.
- A live-source search finds no `playwright-cli` reference outside generated release data before refresh and historical `docs/plans/` records after refresh.

**Verification:** All three managed instruction wrappers render successfully, historical plans are the only remaining textual references, and the repository mirrors remain one-line `@AGENTS.md` files.

---

## Verification Contract

| Gate | Scope | Proves |
|---|---|---|
| Release-lock unit tests | `packages/release-lock`, `vp test` | Registry removal preserves resolver and clean/partial refresh contracts |
| Release-lock typecheck | `packages/release-lock`, `vp run typecheck` | The registry edit keeps the TypeScript contract valid |
| Authoritative lock refresh | repository root, `bun run packages/release-lock/src/cli.ts` | Generated `releases.json` no longer contains the retired key; exit 0 is mandatory |
| External-skill render | isolated `chezmoi execute-template` on `.chezmoiexternals/ai-agents.toml` | `playwright-cli` is absent and remaining skills still render |
| Removal-manifest render | isolated `chezmoi execute-template` on `.chezmoiremove` | The deployed skill target is pruned on the next apply while existing removal entries remain |
| MCP render test | `.ci/test-open-design-mcp-render.sh` | The unchanged shared MCP inventory remains valid across consumers and gates |
| Instruction wrapper renders | isolated `chezmoi execute-template` for Claude, Codex, and omp wrappers | No managed harness receives a dangling routing rule |
| Reference sweep | live source excluding `docs/plans/` | No active configuration, instruction, or release source names `playwright-cli`; only the intentional `.chezmoiremove` prune entry remains |
| Repository hygiene | `git diff --check`, scoped diff, `git status` | No whitespace damage, generated-file drift, or out-of-scope edit |

All chezmoi commands use `--source "$PWD"`, an empty config, a throwaway destination under per-user scratch, and a stub `op` where template rendering resolves secrets. Do not run `chezmoi apply`.

---

## Risks & Dependencies

- **Ambiguous MCP wording.** The only browser MCP is `agent-browser`. Removing it would violate R2 and remove an independent capability.
- **Partial lock refresh.** Any resolver failure overlays the old lock and retains retired keys. The refresh must exit 0; do not hand-edit the generated JSON to simulate success.
- **Dangling instruction fan-out.** One stale sentence in the shared template reaches every managed harness, so all wrapper renders must be checked.
- **Deployed external residue.** Deleting the source declaration alone would leave the fetched skill unmanaged. The exact `.chezmoiremove` entry prunes that target on the next user-initiated apply without introducing a teardown script.
- **Concurrent upstream releases.** A clean lock refresh can legitimately update unrelated versions. Review and report such generated changes rather than misclassifying them as part of the requested removal.

---

## Definition of Done

- R1 through R8 hold.
- U1 and U2 verification passes, including release-lock tests, typecheck, clean lock refresh, removal-manifest render, MCP render test, external-skill render, all three instruction wrapper renders, the reference sweep, and repository hygiene checks.
- `playwright-cli` remains only in historical `docs/plans/` files and the intentional `.chezmoiremove` prune entry; `agent-browser` remains fully declared.
- No live `$HOME` deployment occurs.
- No obsolete comments, temporary files, or abandoned replacement routing rules remain in the diff.

---

## Sources & Research

- `.chezmoidata/agents.yaml` — current MCP and external-skill inventories; no `playwright-cli` MCP row exists.
- `.chezmoiexternals/ai-agents.toml` — generic external-skill render loop and independent `agent-browser` binary declaration.
- `.chezmoitemplates/agents-instructions.tmpl` — two live `playwright-cli` routing clauses shared by all managed harnesses.
- `packages/release-lock/src/registry.ts`, `packages/release-lock/src/cli.ts`, and `packages/release-lock/test/cli.test.ts` — version-only registry key and the tested authoritative-clean-refresh pruning contract.
- `docs/plans/2026-07-15-001-chore-remove-local-agent-skills-plan.md` — established dangling-reference and historical-plan handling for skill removals.
- `.chezmoiremove` and `AGENTS.md` — forward-only deployed-target pruning, source-of-truth ownership, generated-lock discipline, isolated chezmoi verification, and no-live-apply rules.
- No `docs/solutions/`, `CONCEPTS.md`, or relevant product strategy file exists. Local patterns were sufficient, so external research was not load-bearing.
