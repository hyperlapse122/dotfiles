---
title: Doc Drift Cleanup - Plan
type: docs
date: 2026-07-16
topic: doc-drift-cleanup
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Doc Drift Cleanup - Plan

## Goal Capsule

- **Objective:** Find and fix documentation drift across every doc surface in the dotfiles repo, in a single audit-and-fix pass.
- **Product authority:** User (single-maintainer repo, `main` is trunk).
- **Open blockers:** None at requirements time.
- **Execution profile:** Hybrid — parallel discovery (sub-agents per surface) then sequential fix (single context). Standard plan depth.
- **Stop condition:** All discovery findings either fixed inline, queued for user per-change confirm, or documented as deferred with rationale; touched templates still render; modified docs' internal cross-references still resolve; diff summary delivered.

---

## Product Contract

### Summary

Full-repo doc-drift audit run as audit-and-fix in one pass: find spots where descriptions don't match current code, fix them inline, with structural edits (section merge, dedup, dead-heading) allowed when they reduce drift. Covers AGENTS.md, top-level docs, plans/, and inline doc headers/comments in data files and scripts.

### Problem Frame

The last ~2 months brought a dense refactor flurry — pi settings.json sync to a managed readonly target, compound-engineering install via a unified local archive, networking/wifi split into data-driven provisioning, the chezmoidata fact-registry refactor, non-bare garden tree support, and several agent-config restructurings. Each touched AGENTS.md and adjacent docs in scattered places, and several explicitly shipped doc-sync commits afterwards (`docs(agents): finish pi sync`, `docs(plans): trim stale teardown references`).

AGENTS.md is 1171 lines of dense, internally cross-referenced detail — exactly the surface where small inaccuracies accumulate silently and a reader (human or agent) cannot tell a stale description from a live one without reading the referenced code. The user can feel drift exists but cannot point to specific spots, which is why this is scoped audit-first rather than as targeted edits.

### Key Decisions

- **Audit-and-fix in one pass, not report-then-fix.** User's explicit choice. Faster, but commits to reviewing diffs rather than triaging a findings list.
- **Allow structural edits, not factual-only.** AGENTS.md at 1171 lines has structural drift (duplication, dead headings, ordering) alongside factual drift. Factual-only cleanup would leave it still hard to navigate.
- **Drift direction is doc → code, never code → doc.** When doc and code disagree, the doc is wrong. This audit does not modify source files to match doc claims.
- **AGENTS.md structural edits are per-change confirm, not bulk reorg.** AGENTS.md is internally cross-referenced and load-bearing for every agent session, so structural edits there get per-change user confirmation. Other docs may be restructured without per-change confirmation unless they cross-reference AGENTS.md.
- **Hybrid execution: parallel discovery, sequential fix.** Discovery fans out across disjoint surfaces (multiple sub-agents flagging drift in AGENTS.md sections, plans/, inline headers independently) to cut wall-clock. Fixes apply in a single sequential pass so cross-surface consistency edits — e.g., an AGENTS.md section move that updates a `plans/` cross-reference — happen in one context.

### Requirements

**Coverage**

- R1. Audit every doc surface: `AGENTS.md`, root `CLAUDE.md` (mirror-correctness per the import convention), `README.md`, `system/README.md`, `.opencode/commands/*.md`, `docs/plans/*.md`, `.chezmoidata/*.yaml` headers and comments, `.chezmoiscripts/*.tmpl` inline comments, and inline doc inside `dot_*` managed files.
- R2. Verify each doc claim against the referenced code or data before editing. Read the actual file the doc points at; do not trust the doc's description of itself.

**Drift categories**

- R3. Fix factual mismatch: file, script, data, or path names that do not exist as described; described behaviors that diverge from current code.
- R4. Fix stale references: mentions of removed features, deprecated patterns, old commands, or deleted files still being cited.
- R5. Fix internal contradictions: sections within the same doc (or sibling docs that mirror each other) that disagree.
- R6. Apply structural cleanup within existing scope: section merge or split, deduplication, dead-heading removal, ordering improvements. No new content.

**Fix application**

- R7. Small inaccuracies (typos, wrong filenames, broken cross-refs, single-line stale mentions) are edited inline immediately.
- R8. Structural changes to AGENTS.md require per-change user confirmation before applying, because AGENTS.md is internally cross-referenced and load-bearing for every agent session.
- R9. Structural changes to other docs proceed without per-change confirmation, except when the change alters a cross-reference that points into AGENTS.md.

**Historical artifacts**

- R10. Drift in `docs/plans/*` is treated as historical. Add a `Status: Implemented` or `Status: Superseded by <ref>` note at the top when one is missing; do not rewrite plan content to retroactively match what shipped. Plans record what was planned.

### Scope Boundaries

- Filling in missing documentation. Drift cleanup is not docs expansion.
- Drift-prevention tooling — link checkers, linters, CI gates. Separate project.
- Tone, voice, or stylistic rewrite beyond what clarity requires.
- Modifying non-doc source files to "match the doc". Drift direction is doc → code only.
- Cross-repo doc consistency. This repo only.

### Dependencies / Assumptions

- The audit can read every file the docs reference; no permission gates in this single-maintainer checkout.
- The most likely drift sources are the recent refactor commits (last ~2 months). The audit should weight its attention there without ignoring older sections.

### Outstanding Questions

- **Deferred to planning:** How to verify a structural edit did not break an internal cross-reference — full grep for the old anchor before commit, agent self-review, or rely on user diff review? The verification mechanism belongs in the planning contract.

---

## Sources / Research

- Recent commit history (last ~2 months) — pi sync, compound-engineering install, networking/wifi split, fact-registry refactor, non-bare garden trees. Highest-priority drift suspect regions.
- `docs/plans/` already contains four recent plan artifacts; one prior commit (`25685b1 docs(plans): trim stale teardown references`) shows the user has done scoped drift trimming on plans before.
- Repo's own `AGENTS.md` documents the source-state / deployed-state distinction, the script-prefix policy, the no-teardown-scripts rule, and the AGENTS.md ↔ CLAUDE.md mirror contract — these are the load-bearing invariants the audit must not violate while editing docs.
- `dot_local/bin/executable_src-audit` is the existing pattern for read-only drift reporting in this repo: structured categories (`missing` / `broken` / `unmanaged`), explicit "never modifies anything", scratch under `$XDG_RUNTIME_DIR`. Discovery phase (U1–U3) follows the same shape — read-only, structured findings, no in-place edits.
- `.chezmoidata/*.yaml` headers are substantial design records (consumer maps, "why this file exists", single-source-of-truth rationale), not boilerplate. Drift there is high-impact because the headers ARE the architectural narrative.
- `.chezmoiscripts/` is organized into 10 numeric-prefixed directories; each `.sh.tmpl` carries header comments explaining purpose, gating, and trigger semantics.

---

## Planning Contract

Product Contract unchanged — Key Decisions, Requirements, Scope Boundaries, and Outstanding Questions carry forward verbatim from the brainstorm. The single `Deferred to Planning` question (cross-reference verification mechanism) is resolved by KTD4 below.

### Key Technical Decisions

- KTD1. **Hybrid execution: parallel discovery, sequential fix.** Discovery fans out as one sub-agent per surface area (AGENTS.md, plans/+READMEs, inline) — disjoint reads, no cross-surface dependency, so parallelizable. Fix applies in a single sequential pass so cross-surface consistency edits (e.g., an AGENTS.md section rename that updates a `plans/` reference) happen in one context with full visibility. Alternative considered: parallel end-to-end (rejected — coordinating cross-surface consistency edits across parallel fixers is fragile); sequential single-pass (rejected — 1171-line AGENTS.md alone makes wall-clock unattractive).
- KTD2. **Severity taxonomy drives fix application.** Findings carry one of: **P0 wrong** (doc asserts something demonstrably false against current code), **P1 misleading** (technically not false but leads the reader to a wrong conclusion), **P2 stale** (references removed features, deprecated patterns, old commands), **P3 structural** (duplication, dead heading, ordering, missing merge). P0–P2 factual fixes apply inline immediately; P3 in non-AGENTS.md docs applies inline; P3 in AGENTS.md queues for per-change user confirm (per R8).
- KTD3. **AGENTS.md structural confirmation gate is per-change, not bulk.** AGENTS.md is internally cross-referenced and load-bearing for every agent session. Structural edits there present each change individually (one diff hunk, one confirm) rather than a single "applied N structural edits" batch — the user can veto any single edit without unraveling the batch. Non-AGENTS.md docs restructure freely per R9.
- KTD4. **Cross-reference verification = grep old anchors + render check + user diff.** Resolves the Outstanding Question. After every fix pass that touches a heading or anchor: (a) grep the repo for the old anchor text to catch internal links pointing at the renamed location; (b) re-render any touched `.tmpl` with `chezmoi execute-template` to confirm template syntax intact; (c) user diff review is the final gate for AGENTS.md structural changes. `chezmoi archive` (per the AGENTS.md "Verify edits" recipe) is the no-change-gate when scope is large enough to warrant a before/after tree comparison.
- KTD5. **Drift direction is doc → code only.** When doc and code disagree, the doc is wrong. The audit never modifies source files (`.chezmoidata/*.yaml` data, `.chezmoiscripts/*.tmpl` script bodies, `dot_*` file content) to match a doc claim. A doc claim that turns out to describe desirable-but-unimplemented behavior is flagged as a finding with "doc describes aspirational behavior; either implement or rewrite doc to match reality" — the user decides the direction at fix time.
- KTD6. **CLAUDE.md mirrors are correctness-checked, not content-audited.** Root `CLAUDE.md` is a one-line `@AGENTS.md` import by repo convention. Any nested `AGENTS.md` without its sibling `CLAUDE.md` mirror (or a mirror carrying its own content) is flagged as a factual mismatch under R3 — the audit does not rewrite mirror content, only restores the one-line import where broken.

### Assumptions

- The audit can read every file the docs reference; the single-maintainer checkout has no permission gates.
- The most likely drift sources are the recent refactor commits (last ~2 months), so discovery should weight attention there without ignoring older sections.
- "Inline doc" inside `dot_*` managed files means comment blocks or template-piped documentation sections, not arbitrary code comments. Discovery filters for blocks that describe behavior, intent, or contracts — not implementation comments.
- The user is available to confirm AGENTS.md structural changes synchronously during the fix pass (audit-and-fix mode, per the brainstorm).

### Sequencing

1. **U1–U3 in parallel** (discovery, one sub-agent each) — disjoint surfaces, no ordering constraint.
2. **U4** (consolidation) — must follow U1–U3.
3. **U5** (fix pass) — must follow U4.
4. **U6** (verification) — must follow U5.

U1–U3 are sub-agent dispatches (parallel). U4–U6 are run by the lead agent in sequence.

---

## Implementation Units

### U1. Discovery — AGENTS.md

- **Goal:** Find every spot in `AGENTS.md` where the doc diverges from current code, data, or repo state.
- **Files:** `AGENTS.md` (1171 lines). Cross-checked against every file/path/script the doc names.
- **Patterns:** Walk section by section. For each load-bearing claim — a filename, a script name, a `.chezmoidata` key, a behavior description, a cross-reference — verify by reading the referenced source. Flag mismatches with current text, contradicting evidence (`file:line`), suggested fix, and severity (KTD2). The script-prefix policy section, the single-source-of-truth bullets, and the recent-refactor sections (pi sync, compound-engineering, networking/wifi, fact-registry, non-bare garden trees) are the highest-yield regions.
- **Pattern reference:** `dot_local/bin/executable_src-audit` for the read-only-structured-findings shape.
- **Test scenarios:** Each finding must be verifiable by re-reading both the doc claim and the contradicting source. A finding that cannot be grounded in `file:line` evidence is dropped, not reported.
- **Verification:** Self-verifying — a finding is the verification (doc claim + contradicting source). Lead agent reviews the findings list for false positives before consolidation.
- **Output:** Findings list (severity, AGENTS.md location, current text, contradicting source `file:line`, suggested fix).

### U2. Discovery — plans/ and top-level docs

- **Goal:** Find drift in plan artifacts and the smaller top-level docs.
- **Files:** `docs/plans/*.md`, `README.md`, `system/README.md`, `.opencode/commands/*.md`, root `CLAUDE.md` (mirror-correctness per KTD6).
- **Patterns:**
  - For each `docs/plans/*.md`: check whether the plan describes work that has since been changed, removed, or superseded; flag missing `Status:` notes per R10. Do not rewrite plan content per R10/R11.
  - For `README.md` and `system/README.md`: cross-check described setup flow, prerequisites, and repo-structure claims against current state (file paths exist, commands resolve, the described apply behavior matches what scripts actually do).
  - For `.opencode/commands/*.md`: verify each command file's described trigger/behavior matches the command's actual implementation.
  - For root `CLAUDE.md`: verify it is the one-line `@AGENTS.md` import and nothing else.
- **Pattern reference:** The recent commit `25685b1 docs(plans): trim stale teardown references` for the prior scoped drift trim shape.
- **Test scenarios:** Plan-status findings are verifiable by checking commit history / merged work. README findings are verifiable by running the described commands or reading the referenced scripts.
- **Verification:** Lead agent reviews the findings list before consolidation.
- **Output:** Findings list (severity, file:line, current text, contradicting evidence, suggested fix).

### U3. Discovery — inline doc

- **Goal:** Find drift in YAML header comments, script template comments, external-config comments, partial-template headers, and inline doc inside managed files.
- **Files:**
  - `.chezmoidata/*.yaml` (12 files) — header comment blocks (the design-record narrative).
  - `.chezmoiscripts/**/*.tmpl` — header comments per script plus inline comments.
  - `.chezmoiexternals/*.toml` (6 files: `ai-agents`, `dev-tools`, `fonts`, `k8s`, `system`, `vcs`) — header comments describing what each external fetches and how it's consumed.
  - `.chezmoitemplates/*.tmpl` (14 partials) — header comments where present (some partials have minimal headers, that's fine).
  - `agents.toml` (root) — repo-scoped dotagents config comments.
  - `packages/**/*.md` — workspace docs: `packages/README.md`, `packages/AGENTS.md` + sibling `packages/CLAUDE.md` mirror-correctness per KTD6, per-package `README.md` files.
  - `dot_*/**` — filtered for doc-bearing comment blocks or template-piped documentation (not arbitrary code comments).
- **Patterns:** Extract header comments and inline doc blocks. For each described behavior, data key, or consumer map, verify against the actual file content. The `.chezmoidata/*.yaml` headers are high-value: they describe consumer maps ("this key flows to templates X, Y, Z") that drift when consumers are added or removed. The `.chezmoiscripts/*.tmpl` headers describe trigger semantics (`run_onchange` fingerprint dependency) that drift when dependencies are added or removed. The `.chezmoiexternals/*.toml` headers describe what each external provides and where it lands — drift when externals are renamed or removed. `packages/AGENTS.md` and the nested `packages/CLAUDE.md` mirror are subject to the same mirror-correctness rule as the root pair (KTD6).
- **Pattern reference:** `AGENTS.md`'s "Single source of truth" section documents the consumer relationships that `.chezmoidata` headers must stay consistent with.
- **Test scenarios:** Consumer-map findings are verifiable by grepping for the named consumer. Trigger-semantics findings are verifiable by reading the script's actual `fingerprint.tmpl` invocation.
- **Verification:** Lead agent reviews the findings list before consolidation.
- **Output:** Findings list (severity, file:line, current doc text, contradicting evidence, suggested fix).

### U4. Consolidation and prioritization

- **Goal:** Merge U1–U3 findings into a single prioritized fix queue; identify cross-surface patterns and structural cleanups.
- **Files:** Reads the three findings lists; writes a consolidated queue (in-memory or scratch under `$XDG_RUNTIME_DIR/agent-scratch/`, per the AGENTS.md temp-file policy).
- **Patterns:**
  - Dedupe cross-surface findings (same drift surfaced from two angles).
  - Sort by severity (P0 → P3) and within severity by surface area.
  - Identify structural patterns: repeated drift across sections suggests a systematic issue (e.g., a removed feature still referenced in five places) — group these into one structural fix rather than five factual fixes.
  - Separate the queue into "fix inline" (P0–P2 factual; P3 non-AGENTS.md structural) and "queue for user confirm" (P3 AGENTS.md structural).
- **Test scenarios:** The consolidated queue is sanity-checked: every queue item traces back to a U1–U3 finding; no duplicates; severities applied consistently.
- **Verification:** Lead agent confirms dedupe and severity assignment before handing to U5.
- **Output:** Prioritized fix queue with severity tags; structural items grouped; AGENTS.md structural items separated.

### U5. Sequential fix pass

- **Goal:** Apply fixes from the prioritized queue; queue AGENTS.md structural changes for per-change user confirmation.
- **Files:** Whatever U4's queue touches — `AGENTS.md`, `docs/plans/*.md`, `README.md`, `system/README.md`, `.opencode/commands/*.md`, `.chezmoidata/*.yaml`, `.chezmoiscripts/**/*.tmpl`, `dot_*/**`.
- **Patterns:**
  - Walk the queue in priority order.
  - For each P0–P2 factual finding: apply the fix inline immediately.
  - For each P3 structural finding outside AGENTS.md: apply inline.
  - For each P3 structural finding in AGENTS.md: present the change as a single diff hunk to the user, wait for confirm or veto, then apply or skip. One at a time per KTD3.
  - For each fix: agent self-review — does the fix accurately reflect current code? does it introduce a new internal contradiction? does it break a cross-reference?
- **Pattern reference:** KTD2 (severity), KTD3 (AGENTS.md per-change confirm), KTD5 (drift direction).
- **Test scenarios:**
  - A factual fix to a wrong filename: re-read the actual file to confirm the new name resolves.
  - A stale-reference removal: confirm the referenced feature/command is actually removed (commit history), not just renamed.
  - A structural merge of duplicate sections: confirm no internal link points at one of the pre-merge section anchors without updating.
- **Verification:** Per-fix agent self-review (above); U6 runs after the full pass.
- **Output:** Applied changes (commit-ready diff); queued AGENTS.md structural confirmations resolved during the pass; final list of any deferred items with rationale.

### U6. Verification — cross-reference integrity and render check

- **Goal:** Confirm the fix pass introduced no broken templates, no broken cross-references, and no new internal contradictions.
- **Files:** Every file touched in U5.
- **Patterns:**
  - **Cross-reference integrity:** For every heading or anchor changed in U5, grep the repo for the old anchor text. Any hit outside the changed file is a broken cross-reference to fix.
  - **Template render check:** For every `.tmpl` touched in U5, run `chezmoi execute-template < <file>` to confirm template syntax intact. Use the AGENTS.md "Verify edits" stub-`op` recipe when the template carries `onepasswordRead` references — never against real `$HOME`.
  - **Archive no-change gate (when scope warrants):** If U5 touched >20 files or restructured AGENTS.md substantially, run the archive-before / archive-after `diff -r` shape from the AGENTS.md recipe to confirm no unintended target-state changes. Skipped for small scoped passes where per-fix self-review is sufficient evidence.
  - **Internal contradiction sweep:** For each modified section in AGENTS.md, scan sibling sections for claims that now contradict the edited text.
- **Pattern reference:** KTD4 (verification mechanism), AGENTS.md "Verify edits (don't eyeball raw `.tmpl`)" recipe for the stub-`op` pattern.
- **Test scenarios:**
  - A changed heading: `grep -rn "<old-heading-anchor>" .` returns no hits outside the file being edited.
  - A touched `.tmpl`: `chezmoi execute-template` exits 0 and renders to expected content shape.
  - A merged section: no sibling section's prose references the pre-merge section by its old role.
- **Verification:** This unit IS the verification step. Results feed back into U5 if any check fails (re-edit and re-verify).
- **Output:** Verification report — green checklist or list of regressions to address; final diff summary for user review.

---

## Verification Contract

| Unit | Verification | Done signal |
|---|---|---|
| U1 | Findings self-verifying (each carries `file:line` contradicting evidence) | Lead review confirms no false positives |
| U2 | Findings verifiable via commit history or running described commands | Lead review confirms no false positives |
| U3 | Findings verifiable via grep for named consumers or reading script triggers | Lead review confirms no false positives |
| U4 | Consolidated queue traces 1:1 to U1–U3 findings, no dupes, severities consistent | Lead review confirms dedupe |
| U5 | Per-fix self-review: new text matches code, no new contradiction, no broken xref | Per-fix check passes |
| U6 | Cross-reference grep clean, templates render, archive gate clean (when invoked) | All checks green or regressions addressed |

Repo-wide verification commands (run from `<repo-root>`):

- `chezmoi execute-template < .chezmoiscripts/<path>.tmpl` — render a touched template in isolation.
- Stub-`op` recipe from AGENTS.md "Verify edits" — for any template carrying `onepasswordRead`, to avoid real 1Password auth.
- `chezmoi archive --exclude=encrypted,externals,scripts --output <tar>` + `diff -r` against pre-change baseline — no-change gate for large-scope passes.
- `grep -rn "<old-anchor>" .` — for every changed heading/anchor in AGENTS.md.

---

## Definition of Done

- Every discovery finding (U1–U3 consolidated in U4) is in one of three states: **fixed** (applied in U5), **queued-and-resolved** (AGENTS.md structural, user confirmed or vetoed during U5), or **deferred with rationale** (recorded explicitly, not silently dropped).
- All U6 verification checks pass: cross-reference grep clean for every changed anchor; every touched `.tmpl` renders; archive gate clean when invoked.
- Diff summary delivered to the user covering: files touched, finding count by severity, AGENTS.md structural changes applied vs vetoed, items deferred with rationale.
- No source files (`.chezmoidata/*.yaml` data, `.chezmoiscripts/*.tmpl` script bodies, `dot_*` content) modified to match doc claims — drift direction held to doc → code per KTD5.
- The repo's load-bearing invariants (source-state model, script-prefix policy, no-teardown-scripts rule, AGENTS.md ↔ CLAUDE.md mirror contract) remain intact.
