---
title: ce-sweep GitLab Issues Source Overlay - Plan
type: feat
date: 2026-07-29
topic: ce-sweep-gitlab-issues-overlay
execution: code
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
---

# ce-sweep GitLab Issues Source Overlay - Plan

## Goal Capsule

- **Objective:** make ce-sweep's `type: gitlab-issues` source load one canonical persona on every device, instead of agents improvising a new `gitlab-issues.md` each run.
- **Product authority:** this plan owns the GitLab-issues source persona and its overlay delivery. An upstream contribution and a merge-request persona are adjacent candidates, not active scope.
- **Open blockers:** none.

---

## Product Contract

_Product Contract unchanged — requirements, scope, acceptance examples, and the four session-settled Key Decisions are preserved verbatim. This enrichment adds the Planning Contract, Implementation Units, Verification Contract, and Definition of Done._

### Summary

Add a canonical `gitlab-issues.md` source persona for ce-sweep, version-controlled in this dotfiles repo, and inject it into the currently-pinned compound-engineering version directory so a `type: gitlab-issues` feedback source stops being re-authored per run and converges across devices. Delivery removes the `exact` flag from the compound-engineering external so the tree is additive and injected overlays survive, plus a `run_onchange_after_` provisioner for version bumps and content edits.

### Problem Frame

ce-sweep dispatches a per-source subagent seeded with `references/sources/<type>.md`, where `<type>` comes from a project's `feedback_sources` config. `email.md`, `github-issues.md`, and `slack.md` ship upstream; `gitlab-issues.md` does not. When the file is absent, the subagent writes its own each run, and the results drift.

The drift is structural, not accidental. The compound-engineering install at `~/.local/share/compound-engineering/<version>/` is a chezmoi external archive that previously set `exact = true`, so every apply reconciled that tree to the upstream release and removed any file the release did not ship. A version bump creates a fresh version directory on top of that. So a persona file an agent drops into the versioned tree was wiped on the next apply or the next release, and the next device re-authors it differently. The fix removes `exact` so the tree is additive, then injects a canonical overlay from outside the versioned tree.

### Key Decisions

- **Local chezmoi overlay, not an upstream contribution** (session-settled: user-directed — chosen over an upstream PR and over local-then-upstream: it converges all devices immediately, keeps the customization private, and does not depend on upstream accept or release timing). The canonical persona lives in this dotfiles repo and is injected into the versioned tree, surviving re-extract and version bumps.
- **`glab` as the native tool** (session-settled: user-approved — chosen over raw GitLab API: matches the `github-issues` persona's use of `gh`, the environment's glab skill/MCP, and the native-CLI credential hardening).
- **Issues only; merge requests are a separate type** (session-settled: user-approved — chosen over including MRs: GitLab exposes issues and MRs on distinct endpoints, so the persona needs no PR-exclusion logic).
- **Confidential issues are included but auto-sensitive** (session-settled: user-directed — chosen over plain-treat and over skip: a confidential marker is a reliable sensitivity signal, and the state file may be committed).

### Requirements

**Persona content**

- R1. The overlay provides a `gitlab-issues` source persona that mirrors the `github-issues` persona contract — item schema, availability probe, fetch guidance, untrusted-input handling, and tool guidance — adapted to GitLab.
- R2. The persona uses `glab` for every GitLab operation. It may use `glab api` for read-only fields that issue subcommands do not expose, but never uses direct HTTP clients, manually injects credentials, or performs API writes; the only write is the configured label addition through `glab issue update`.
- R3. The persona maps each GitLab issue into the sweep item schema: `id` as the stable issue reference, `author_class` inferred from GitLab membership and association, and ack/close-out driven only by the configured label names.
- R4. The persona covers issues only. Merge requests are out of scope and would be a separate `gitlab-mrs` source type.
- R5. A confidential issue is included in the sweep and treated as `sensitive` automatically. The source persona returns per-item sensitivity, and the overlaid ce-sweep contract propagates it to `upsert-item`, where `body` and `quote` are dropped before the state file is written. The persisted title is replaced with a neutral confidential-issue summary.

**Overlay delivery and durability**

- R6. A canonical `gitlab-issues.md` is authored and version-controlled in this dotfiles repo as the single source of truth for the persona.
- R7. After every `chezmoi apply`, the canonical file is present at `skills/ce-sweep/references/sources/gitlab-issues.md` inside the currently-pinned compound-engineering version directory, regardless of a re-extract or a version bump.
- R8. The injection is part of the apply lifecycle, runs after the external file phase, and re-runs whenever the canonical content or the pinned compound-engineering version changes.

**Integration contract**

- R9. ce-sweep's source-loading path remains `<type>` -> `references/sources/<type>.md`. A minimal overlaid skill-contract change adds optional per-item `sensitive` output and propagates it to `upsert-item`; the bundled state script is unchanged because it already redacts sensitive item payloads.

### Acceptance Examples

- AE1. **Covers R5.**
  - **Given:** an open GitLab issue marked confidential.
  - **When:** the persona maps it.
  - **Then:** the item is upserted with `sensitive: true`; its `body` and `quote` are not written to the state file, while `id`, `origin`, author class, and a neutral confidential-issue summary are retained.
- AE2. **Covers R7.**
  - **Given:** the compound-engineering external re-extracts.
  - **When:** `chezmoi apply` completes.
  - **Then:** `gitlab-issues.md` is present in the current version's `references/sources/`, byte-identical to the dotfiles canonical file, because the external is additive (no `exact` wipe) and the provisioner injects on change.
- AE3. **Covers R7, R8.**
  - **Given:** a compound-engineering release bump creates a new version directory.
  - **When:** apply completes.
  - **Then:** the persona is present in the new version's `references/sources/` with no dependence on the old version directory.

### Success Criteria

- After apply on any device, the injected `gitlab-issues.md` is byte-identical across devices — no per-device authoring drift.
- A `type: gitlab-issues` source runs deterministically in ce-sweep: the subagent is seeded with the canonical persona every run and never improvises one.

### Scope Boundaries

- Upstreaming the persona to `EveryInc/compound-engineering-plugin` is out of scope; it is a possible follow-up once the content stabilizes.
- A `gitlab-mrs` merge-request persona is out of scope.
- Changing ce-sweep's source-loading path or bundled state script is out of scope. The overlay keeps `<type>` -> `references/sources/<type>.md` intact and changes only the skill contract needed to carry optional per-item sensitivity into the existing redaction engine.
- The per-project `feedback_sources` config entry that selects `type: gitlab-issues` lives in the user's project repo and is out of scope; this plan delivers the persona, not the config.

### Dependencies and Assumptions

- The compound-engineering install is a chezmoi external archive. With `exact` removed it is additive: chezmoi adds/updates archive files but no longer removes others, so an injected overlay survives across applies.
- The overlay assumes ce-sweep continues to resolve personas from `references/sources/<type>.md` relative to its skill directory. If a future release changes that contract, the injection target moves with it.
- The user's per-project config is assumed to carry a `type: gitlab-issues` entry pointing at a GitLab project or group; the overlay provides the persona, not the config.

### Outstanding Questions

- OQ1. (Deferred to Planning) If a future compound-engineering release ships its own `references/sources/gitlab-issues.md`, the local overlay collides with it. Decide then whether to drop the overlay for the upstream file; no auto-reconciliation is planned now.

### Sources and Research

- ce-sweep loads each source persona from `references/sources/<type>.md` at dispatch. In the compound-engineering install (`~/.local/share/compound-engineering/<version>/`), that is `skills/ce-sweep/SKILL.md`, Phase 2b; `<type>` comes from the per-project `feedback_sources` config entry.
- In that install, `skills/ce-sweep/references/sources/github-issues.md` is the mirror template: item schema, availability probe via `gh auth status`, `gh issue list --search "updated:>=<cursor>"`, untrusted-input handling, and the single-configured-label write discipline.
- The compound-engineering external is the `localArchive` archive block in `.chezmoiexternals/ai-agents.toml` (driven by `agents.opencode.plugins` entry `compound-engineering`, `install: localArchive`, `externalPath: .local/share/compound-engineering`). CE is currently the sole `localArchive` plugin, so the block's `exact = true` (line 356) is CE-specific; the separate agent-skills block's `exact = true` (line 312) is unrelated and stays.
- `.chezmoiscripts/00-tools/run_onchange_after_compound-engineering.sh.tmpl` resolves the pinned version directory and prunes siblings — the version-resolution pattern to mirror.
- `.chezmoitemplates/fingerprint.tmpl` emits a content-hash fingerprint into the rendered script; chezmoi hashes the whole rendered script to decide re-run, so a rendered version literal plus this fingerprint over the overlay source catches both version bumps and content edits. `.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.sh.tmpl` is the neighbor that fingerprints a deployed source tree.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Deployed overlay tree merged into the CE version dir by a provisioner** (session-settled: user-directed — chosen over an upstream PR and local-then-upstream: converges all devices immediately, keeps the customization private, avoids release-timing dependence). The canonical persona lives under a new deployed overlays tree and a provisioner merges it onto the current CE version directory. Instantiates the brainstorm's local-overlay decision; the file lives outside the versioned tree and is injected into it.
- KTD2. **`glab` native tooling** (session-settled: user-approved — chosen over direct HTTP clients and non-native credential injection: parity with the `github-issues` persona's native CLI, matches the glab skill, and keeps credentials inside the official CLI). The persona uses issue subcommands where they expose the needed data and permits read-only `glab api` calls for membership data; it never performs API writes.
- KTD3. **Issues only** (session-settled: user-approved — chosen over including MRs: GitLab exposes issues and MRs on distinct endpoints, so no PR-exclusion logic is needed). The persona uses `glab issue list` and never `glab mr list`.
- KTD4. **Confidential implies auto-sensitive** (session-settled: user-directed — chosen over plain-treat and skip: a confidential marker is a reliable sensitivity signal and the state file may be committed). The persona sets `sensitive: true` on any confidential issue so the engine drops `body`/`quote`.
- KTD5. **Generic overlay-tree merge, not a single-file copier.** The provisioner mirrors the whole `~/.local/share/compound-engineering-overlays/` tree onto the CE version dir at matching relative paths, so any future overlay persona (or other overlaid file) works with no script change. Rejected: a copier hardcoded to the one `gitlab-issues.md` path. The user's stated problem is recurrent ("agents keep creating sources"), the generic form is no more complex than the single-file form, and the carrying cost is a one-line merge — the YAGNI bar for low-cost, problem-aligned generality is met.
- KTD6. **Remove `exact` from the CE external (make it additive) + `run_onchange_after_` provisioner.** (user-directed mid-planning — chosen over a bare `run_after_` re-injection workaround: addresses the every-apply wipe at the root rather than working around it, and keeps the trigger within the `run_onchange_` pattern `AGENTS.md` prefers over bare `run_after_`.) The compound-engineering `localArchive` external currently sets `exact = true`, which makes chezmoi remove non-archive files from the version dir on every apply — the root cause of an injected overlay being wiped. Removing `exact` makes the external additive (chezmoi adds/updates archive files but leaves others), so an injected overlay survives no-change applies without re-injection. The provisioner is then `run_onchange_after_`, triggered by the rendered version literal (re-inject into a fresh version dir on a bump) plus `fingerprint.tmpl` over the overlays source (re-inject on a content edit); it does not need to run every apply. Tradeoff, accepted: the CE version dir is no longer self-cleaning within a version cycle — upstream deletions and stray files accumulate until the next version bump creates a fresh dir, which resets the tree. CE is the sole `localArchive` plugin, so removing `exact` from the shared template is CE-equivalent today.
- KTD7. **Overlay the minimal ce-sweep sensitivity contract.** (user-approved continuation after feasibility review — chosen over marking the entire GitLab source sensitive: preserves useful content for public issues while making confidential issues safe.) The canonical overlay includes `skills/ce-sweep/SKILL.md` with only the source-output schema and phase-2d propagation changed: personas may return optional `sensitive`, and item sensitivity is true when either the source config or the item says so. The existing state engine remains authoritative for dropping `body` and `quote`.

### High-Level Technical Design

Removing `exact` makes the CE external additive, so the injected overlay survives no-change applies; the `run_onchange_after_` provisioner only re-runs on a version bump (fresh version dir) or a content edit.

```mermaid
sequenceDiagram
  participant Apply as chezmoi apply
  participant File as file phase
  participant Script as script phase (run_onchange_after_)
  participant CE as CE version dir (additive, no exact)
  Apply->>File: run
  File->>CE: reconcile compound-engineering external (additive: adds archive files, leaves the overlay)
  File->>File: deploy overlays source tree (~/.local/share/compound-engineering-overlays/)
  Apply->>Script: fires on version bump or overlay content change
  Script->>CE: merge overlays/. onto CE/ (inject gitlab-issues.md)
  Note over CE: persona present; survives no-change applies; re-injected on version bump
```

The provisioner resolves the current version directory the same way the prune script does (from `agents.opencode.plugins` `compound-engineering` entry's `externalPath` plus `.chezmoitemplates/compound-engineering-ref.tmpl`), then performs a portable recursive merge of the deployed overlays tree onto that directory. It is idempotent and defensive: it exits 0 when either the overlays tree or the version directory is absent, matching the prune script's `[ -d "$CURRENT" ] || exit 0` guard.

---

## Implementation Units

### U1. Author the canonical `gitlab-issues` source persona

- **Goal:** produce the canonical persona markdown that ce-sweep seeds its GitLab-issues subagent with, mirroring the upstream `github-issues` persona for `glab`.
- **Requirements:** R1, R2, R3, R4, R5 (also AE1).
- **Dependencies:** none.
- **Files:**
  - `dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md` (create; deploys to `~/.local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md`).
- **Approach:** Mirror the `github-issues.md` contract section-for-section — opening role paragraph (GitLab Issues source connector, reports facts only, never advances cursors), the item-schema table, Invocation Contract, Availability Probe, Fetch Guidance, Untrusted Input Handling, Tool Guidance — substituting GitLab for GitHub throughout. The upstream `github-issues.md` is verified to exist at `skills/ce-sweep/references/sources/github-issues.md` in the current compound-engineering install (confirmed during planning). GitLab-specific mappings:
  - `id` is `group/project#<iid>` (GitLab issue IIDs are project-scoped and repeat across projects, so the full path plus IID is the stable id, parallel to `owner/repo#1234`).
  - `author_class` from GitLab author membership: project members (Owner/Maintainer/Developer/Reporter) map to `teammate`; a non-member human reporter to `customer`; bot/app/service users to `bot`. Resolve membership through a read-only `glab api projects/<url-encoded-path>/members/all/<user-id>` request after issue retrieval; a 404 means non-member, while other API failures degrade the source rather than guessing.
  - Issues only via `glab issue list`; state explicitly that merge requests are a separate source type and that no PR/MR filtering is needed because the issues endpoint does not return them.
  - Confidential rule (the behavioral addition over `github-issues`): when the issue's `confidential` flag is true, the mapped item carries `sensitive: true` and a neutral summary such as `Confidential GitLab issue <id>`; state this both in the item-schema `body`/`media` rows and a dedicated short note, since the overlaid sweep contract passes item sensitivity to the engine, which drops `body`/`quote` before writing state.
  - Availability probe uses `glab auth status` for read and a label-update capability check for write, with the same two exact degrade sentences as `github-issues.md` (tools-unavailable skip; write-degraded read-only ingest).
  - Tool guidance permits `glab issue list` / `glab issue view` and read-only `glab api` membership reads plus exactly one configured label-add write via `glab issue update <iid> --repo <group/project> --label <configured-label>`; the trusted project path comes from source configuration, never issue-authored content. Never comment, close, reopen, or perform any other write.
  - Cursor reads use `glab issue list --repo <group/project> --order updated_at --sort desc --output json --page <n> --per-page <size>`. Paginate newest-first, client-filter inclusively on `updated_at >= cursor`, and stop only after a complete page falls below the cursor. Dedupe by `id`.
- **Patterns to follow:** the upstream `github-issues.md` persona in the compound-engineering install at `skills/ce-sweep/references/sources/github-issues.md`; the glab skill conventions (pass GitLab paths with slashes intact, prefer `:fullpath`).
- **Test scenarios:**
  - Covers AE1. A confidential issue maps to an item with `sensitive: true` and the persona states `body`/`quote` are dropped for sensitive items.
  - Availability probe emits the exact tools-unavailable skip sentence when `glab auth` fails, and the exact write-degraded sentence when read works but label-edit does not.
  - Tool surface is `glab` read plus the single configured `glab issue update --repo ... --label` write; the persona never authorizes comments, close, reopen, or cursor advancement.
  - Scope uses `glab issue list` only; the persona does not reference `glab mr list` or merge-request fetching.
  - `id` mapping is documented as `group/project#<iid>`.
- **Verification:** U5's content-contract checks grep-enforce every scenario above against the rendered/deployed persona.
- **Execution note:** Author the persona by adapting the upstream `github-issues.md` prose in place rather than writing from scratch, so the contract stays structurally identical and the GitLab divergence is limited to the mapped substitutions plus the confidential rule.

### U2. Make the compound-engineering external additive

- **Goal:** remove `exact = true` from the CE `localArchive` external so the version dir no longer wipes non-archive files on apply, letting an injected overlay persist across no-change applies.
- **Requirements:** R7, R8 (the durability substrate the provisioner in U3 relies on).
- **Dependencies:** none (independent of U1/U3; lands first so the tree is additive before/when the provisioner injects).
- **Files:**
  - `.chezmoiexternals/ai-agents.toml` (edit: delete the `exact = true` line in the `localArchive` block — the entry whose target is `[{{ .externalPath }}/{{ $verSegment }}]`; update the surrounding block comment that currently says `exact=true so a version's extracted tree cleans up upstream deletions` to explain the additive behavior and the overlay rationale). Do NOT touch the unrelated agent-skills block's `exact = true`.
- **Approach:** Chezmoi's `exact = true` removes target entries not present in the archive on every reconciliation; removing it makes the archive external additive (add/update only). CE is the sole `install: localArchive` plugin, so editing the shared `localArchive` template block is CE-equivalent today; note in the comment that a future second `localArchive` plugin would inherit additive behavior (acceptable, and required for any future overlay). The comment should also record the tradeoff: the version dir no longer self-cleans upstream deletions within a version cycle, reset on each version bump.
- **Patterns to follow:** the existing `localArchive` block comment style (multi-line `{{- /* ... */ -}}` explaining the mechanism and its neighbors).
- **Test scenarios:**
  - Test expectation: none -- this is a one-line config flag removal with a comment edit; its effect (additive extract preserves the overlay) is asserted structurally by U4 (the rendered block omits `exact`) and end-to-end by the acceptance apply.
- **Verification:** U5 renders `.chezmoiexternals/ai-agents.toml` and asserts the `localArchive` (CE) block contains no `exact` key while the agent-skills block still does.

### U3. Add the overlay-injection provisioner

- **Goal:** a `run_onchange_after_` script that merges the deployed overlays tree onto the current compound-engineering version directory on version bumps and overlay content changes.
- **Requirements:** R6, R7, R8, R9 (also AE2, AE3).
- **Dependencies:** U1 (the overlays tree must contain the persona), U2 (the external is additive so an injected file survives no-change applies without re-injection).
- **Files:**
  - `.chezmoiscripts/00-tools/run_onchange_after_compound-engineering-overlays.sh.tmpl` (create).
- **Approach:** Mirror the prune script's version resolution and the `install-agent-plugins` onchange pattern. Gate `{{ if ne .chezmoi.os "windows" }}`; resolve `$ceRef` via `.chezmoitemplates/compound-engineering-ref.tmpl`, derive `$ceVersion` (`v<semver>`) and `$BASE_DIR`/`$CURRENT` from the `agents.opencode.plugins` `compound-engineering` entry's `externalPath`, exactly as the prune script does. Render `$ceVersion` into the script body so a version bump changes the rendered content and re-runs the script (injecting into the fresh version dir). Emit the `fingerprint.tmpl` partial over `dot_local/share/compound-engineering-overlays/**` so an overlay content edit also re-runs. At run time: set `OVERLAYS="$HOME/<externalPath>-overlays"` and `CURRENT="$HOME/<externalPath>/$ceVersion"`; if either directory is absent, exit 0; otherwise perform a portable recursive merge of `$OVERLAYS/.` onto `$CURRENT/` (POSIX `cp -Rp`, creating intermediate dirs), overwriting same-named files. The script owns only the merge; it never prunes version directories (the prune script still owns that) and never modifies the overlays source. It does not need to run every apply because U2 made the external additive.
- **Patterns to follow:** `.chezmoiscripts/00-tools/run_onchange_after_compound-engineering.sh.tmpl` (version resolution, defensive `[ -d ] || exit 0` skip); `.chezmoitemplates/fingerprint.tmpl`; `.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.sh.tmpl` (fingerprinting a deployed source tree).
- **Test scenarios:**
  - Covers AE2, AE3. After the provisioner runs against a scratch CE tree containing `skills/ce-sweep/references/sources/{email,github-issues,slack}.md`, `gitlab-issues.md` is present in that same directory.
  - The three upstream source files remain present after the merge (merge, not replace).
  - When the overlays directory is absent, the script exits 0 without writing under the CE tree.
  - When the CE version directory is absent, the script exits 0 (defensive skip, matching the prune script).
  - The injected `gitlab-issues.md` is byte-identical to the deployed overlay source.
  - The rendered script contains the version literal (bump re-trigger) and the `fingerprint.tmpl` glob over the overlays source (content-edit re-trigger).
  - Render is shellcheck-clean under both linux and darwin gates.
- **Verification:** U5 renders this script, rewrites the resolved CE path to a scratch fixture, and runs it to assert the scenarios above.
- **Execution note:** The merge command must be portable across GNU and BSD `cp` because the script renders for linux and darwin; CI runs linux only, so darwin portability is a manual acceptance item (recorded in Definition of Done).

### U4. Overlay per-item sensitivity propagation

- **Goal:** make persona-provided sensitivity reach the existing state-engine redaction path without changing the state script.
- **Requirements:** R5, R9 (also AE1 and KTD7).
- **Dependencies:** none.
- **Files:**
  - `dot_local/share/compound-engineering-overlays/skills/ce-sweep/SKILL.md` (create from the pinned upstream skill with the minimal contract changes).
- **Approach:** Copy the pinned ce-sweep `SKILL.md` into the canonical overlay tree. Add optional `sensitive` to the mapped-item output in phase 2b. In phase 2d, require `"sensitive": true` in the JSON passed to `upsert-item` when either the source config or the mapped item is sensitive. Preserve all other upstream text byte-for-byte so future release diffs make drift visible. The state engine already strips `body` and `quote`, so no Python change is needed.
- **Patterns to follow:** the pinned upstream `skills/ce-sweep/SKILL.md`; `skills/ce-sweep/references/state-schema.md` sensitive semantics.
- **Test scenarios:**
  - A mapped public issue under a non-sensitive source is upserted without forced sensitivity.
  - A mapped confidential issue under a non-sensitive source is upserted with `sensitive: true`.
  - A source configured sensitive still forces sensitivity on every item.
  - The overlaid skill retains the existing source persona lookup and phase ordering.
- **Verification:** the isolated test diffs the overlay against the pinned skill and permits only the documented sensitivity-contract edits, then exercises the state engine with public and confidential fixtures.

### U5. Add CI verification

- **Goal:** an isolated, network-free CI test proving the CE external is additive (no `exact`), the provisioner injects and merges correctly, and the persona satisfies its content contract — modeled on the existing render-and-stub tests.
- **Requirements:** R1–R5, R7, R8 (also the byte-identical success criterion).
- **Dependencies:** U1, U2, U3, U4.
- **Files:**
  - `.ci/test-compound-engineering-overlays.sh` (create).
  - `.github/workflows/ci.yml` (add a job that installs chezmoi, renders the external and the provisioner with a stub `op` and empty config under `--source "$PWD"`, and runs the test).
- **Approach:** Follow the `smoke-agy-plugin-installer.sh` shape. Render `.chezmoiexternals/ai-agents.toml` via `chezmoi execute-template` and assert the `localArchive` (CE) block omits `exact` while the agent-skills block still has it. Render the provisioner; rewrite the resolved CE path inside the rendered script to a scratch fixture; build a fake CE tree (`skills/ce-sweep/references/sources/` with the three upstream filenames) and a deployed overlays tree (the canonical persona and overlaid skill); run the provisioner and assert the injection and merge scenarios from U3/U4. Run content-contract checks over the persona and exercise `sweep-state.py` with public/confidential fixtures to prove per-item redaction. Keep the test hermetic — no real apply, no network, per the repo verification rules.
- **Patterns to follow:** `.ci/smoke-agy-plugin-installer.sh` (render + rewrite-path + stub-bin + assert); `.ci/test-cli-proxy-api-render-matrix.sh` (content-contract grep over rendered output); the `codex-wrapper` job in `.github/workflows/ci.yml` (chezmoi install + `execute-template` + run test).
- **Test scenarios:**
  - The rendered `localArchive` (CE) block has no `exact` key; the agent-skills block still does.
  - The test exits 0 when the provisioner injects the persona into the fake CE tree and leaves the three upstream source files intact (merge, not replace).
  - The test exits non-zero if the persona is missing any required contract token or references `gh`/MR listing.
  - The test exits 0 when the overlays dir is absent (provisioner skips cleanly).
  - The test exits 0 when the CE version dir is absent (provisioner skips cleanly).
  - The test asserts the injected persona is byte-identical to the deployed overlay source.
  - A confidential fixture persists a neutral summary and no `body`/`quote`; a public fixture retains its content.
  - Cursor guidance contains newest-first pagination and inclusive client filtering, and the label write includes the trusted `--repo` selector.
- **Verification:** the new `ci.yml` job is green on push.

---

## Verification Contract

| Unit | Gate | How |
|---|---|---|
| U1 | Persona content contract | `.ci/test-compound-engineering-overlays.sh` content-contract grep (glab, item-schema, confidential→sensitive, degrade sentences, single-label tool guidance; no `gh`/MR listing) |
| U2 | Additive external | `.ci/test-compound-engineering-overlays.sh` asserts the rendered CE `localArchive` block omits `exact` (agent-skills block retains it) |
| U3 | Provisioner behavior | `.ci/test-compound-engineering-overlays.sh`: injects persona and skill overlay, preserves upstream files, skips cleanly when either dir absent, byte-identical, re-trigger via version literal + fingerprint glob |
| U4 | Per-item sensitivity | isolated state-engine fixtures prove confidential items lose `body`/`quote` and receive a neutral summary while public items remain intact |
| U2, U3 | Render + lint | `render-dotfiles.yml` renders the `.tmpl`; CI shellchecks the rendered script (watch the Windows-render CRLF trap) |
| U5 | Test infra | new `ci.yml` job green on ubuntu-latest |
| All | Acceptance (isolated) | two consecutive applies use `--source "$PWD"` and an isolated destination with stubbed runtime commands; the injected persona and skill overlay remain byte-identical and upstream source files remain intact |

---

## Definition of Done

- The canonical persona exists at `dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/sources/gitlab-issues.md`.
- `.chezmoiexternals/ai-agents.toml` no longer sets `exact` on the CE `localArchive` block (agent-skills block unchanged), with an updated comment recording the additive behavior and the no-self-cleaning tradeoff.
- The provisioner `.chezmoiscripts/00-tools/run_onchange_after_compound-engineering-overlays.sh.tmpl` renders under linux and darwin, is shellcheck-clean, and re-runs on version bumps and overlay content edits.
- `.ci/test-compound-engineering-overlays.sh` and its `ci.yml` job pass on ubuntu-latest.
- Two isolated applies with `--source "$PWD"` and a throwaway destination leave the persona and skill overlay byte-identical to source with the three upstream source files intact.
- Confidential-item fixtures prove the persisted state contains no title detail, `body`, or `quote`; public-item fixtures retain normal content.

Post-deployment acceptance, intentionally outside LFG completion: after the user requests a real deployment, confirm first/no-change apply behavior on a host, darwin merge portability on macOS, and a ce-sweep run with `type: gitlab-issues`.
