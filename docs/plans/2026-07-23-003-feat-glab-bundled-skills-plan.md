---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "feat: manage glab bundled skills as agent-skill externals"
date: 2026-07-23
type: feat
depth: lightweight
---

# feat: Manage glab bundled skills as agent-skill externals

## Summary

Re-install GitLab CLI's two bundled agent skills — `glab` and `glab-stack`, whose
externals were removed from `.chezmoiexternals/vcs.toml` as "unused" in `e915044`
— this time through the repo's data-driven external-skills registry: entries in
`agents.skills.external` (`.chezmoidata/agents.yaml`) rendered by
`.chezmoiexternals/ai-agents.toml` into `~/.agents/skills/<name>/SKILL.md` as raw
single-file externals fetched from GitLab. Version lockstep with the glab binary
is structural: a new shared partial `.chezmoitemplates/glab-release-ref.tmpl`
resolves the latest `gitlab-org/cli` release tag, consumed by **both** `vcs.toml`
(the glab binary) and `ai-agents.toml` (the two skills). Claude Code sees the
skills through the existing dotagents `~/.claude/skills` → `~/.agents/skills`
symlink (Codex likewise), so both required harness locations are covered without
duplicating files.

This is config/packaging work, verified by `chezmoi execute-template` renders, a
lockstep assertion across the two rendered files, raw-URL fetches, and CI.

## Problem Frame

The user wants glab's bundled skills installed and *managed*, with the skill
version tracking the managed glab CLI version. The skills were once `type =
"file"` externals in `vcs.toml` (removed in `e915044`; their
`$glabSkillUrl`/`$glabStackSkillUrl` vars are still defined there, orphaned).
Since then the repo has settled on a registry model for external skills
(`agents.skills.external` → `ai-agents.toml` → `~/.agents/skills/<name>`, fanned
out to harnesses by the dotagents symlinks), which the glab skills predate and
never used. The per-harness location problem the user names is already solved by
that symlink fan-out — what is missing is declaring the two GitLab-sourced skills
in the registry and single-sourcing their version with the glab binary.

**Constraints verified during research:**

- At tag `v1.109.0` each skill subtree contains **exactly one file**,
  `internal/commands/skills/bundled/assets/<name>/SKILL.md` (GitLab API tree
  listing), and both raw URLs return HTTP 200.
- glab's tag is resolved in `vcs.toml` via `getRedirectedURL` on the GitLab
  `releases/permalink/latest` API + `curl | fromJson`; the same resolution,
  shared, is the lockstep mechanism.
- `agents.skills.external` today is GitHub-only (archive `type`, ref = latest
  GitHub release or an ls-remote-resolved branch commit). glab's skills need a
  GitLab host branch and a raw-file fetch form.
- The skills external block and the dotagents skills symlinks are POSIX-only;
  skills externals carry no container gate (wanted in devboxes).

## Requirements

- **R1** — Both `glab` and `glab-stack` deploy to
  `~/.agents/skills/<name>/SKILL.md` on POSIX hosts as chezmoi externals.
- **R2** — Both skills are visible at `~/.claude/skills/<name>/` via the existing
  dotagents `~/.claude/skills` → `~/.agents/skills` symlink (no second copy, no
  new symlink machinery).
- **R3** — The skills' ref is the glab binary's release tag, single-sourced:
  `.chezmoitemplates/glab-release-ref.tmpl` consumed by both `vcs.toml` and
  `ai-agents.toml`.
- **R4** — The skills are declared in the `agents.skills.external` registry, not
  re-added to `vcs.toml`; the orphaned `$glabSkillUrl`/`$glabStackSkillUrl` vars
  are removed.
- **R5** — All touched templates render cleanly; the tag rendered into
  `ai-agents.toml`'s skill URLs equals the tag in `vcs.toml`'s glab archive URL;
  both raw skill URLs fetch successfully; CI `render-dotfiles.yml` + `ci.yml`
  stay green.

## Key Technical Decisions

- **KTD1 — Install both `glab` and `glab-stack`.** (session-settled:
  user-directed — chosen over installing one skill or a different set: the user
  named both bundled skills explicitly.)
- **KTD2 — Version lockstep via a shared `glab-release-ref.tmpl` partial.**
  (session-settled: user-directed — chosen over an independent skills pin: the
  skills must reference the same version as the glab CLI.) The partial moves
  `vcs.toml`'s existing GitLab `releases/permalink/latest` resolution into
  `.chezmoitemplates/`, modeled on `compound-engineering-ref.tmpl` (doc comment
  lists consumers). `vcs.toml` migrates to it, so the binary and the skills can
  never be *configured* against different releases — the resolution logic is
  single-sourced. Each consumer still re-resolves the moving `latest` pointer in
  its own render pass, so a release landing mid-render can transiently desync
  the two (see Risks); that is a re-render flake, not a lockstep break.
- **KTD3 — Manage through the `agents.skills.external` registry, not
  `vcs.toml`.** (session-settled: user-directed — chosen over keeping the skills
  as `vcs.toml` externals: harness-specific skill locations do not fit vcs.toml
  ownership.) The registry is the repo's sanctioned external-skills mechanism;
  the per-harness fan-out is the dotagents symlink's job. Rejected alternatives:
  dotagents `[[skills]]` registration (repo decision: dotagents is MCP-only);
  vendored copies under `dot_agents/skills/` (stale snapshots duplicating
  upstream content; the `dot_agents/skills/` path is reserved for
  locally-authored personal skills like `daily-report`); and glab's own
  `glab skills install --global` (present at v1.109.0 — it installs the
  binary-embedded skills to `~/.agents/skills/` with intrinsic version
  lockstep — but it is imperative and EXPERIMENTAL, not chezmoi-converged: no
  registry entry, no render-time verification, no pruning of drifted files,
  and a manual run would silently overwrite the chezmoi-managed files until
  the next apply).
- **KTD4 — GitLab branch fetches raw single files, not a repo archive.** Each
  skill subtree at the tag is exactly one `SKILL.md`, so the `host: gitlab`
  branch emits `type = "file"` externals targeting
  `~/.agents/skills/<name>/SKILL.md` with the raw URL form
  `https://gitlab.com/<source>/-/raw/<ref>/<skillPath>/SKILL.md?ref_type=tags`
  (KBs, versus the whole `gitlab-org/cli` tarball per skill). Three new optional
  `skills.external` schema keys carry this: `host` (default `github`; `gitlab`
  selects the raw-file branch), `versionSource: glabRelease` (ref from the shared
  partial; mutually exclusive with `ref`, unknown values `fail`), and `skillPath`
  (repo-internal directory holding `SKILL.md`, required for `host: gitlab`).
- **KTD5 — Inherit the skills block's gates unchanged.** POSIX-only (matches the
  dotagents symlink gate) and no container gate (skills are wanted in devboxes);
  no `.chezmoiignore` change.

## Assumptions

Pipeline (headless) run — inferred decisions recorded for review:

- **A1 — One deploy + symlink covers both required locations.** The user's
  "`~/.agents/skills` and `~/.claude/skills`" requirement is met by deploying to
  `~/.agents/skills/<name>/` and relying on the existing dotagents
  `~/.claude/skills` → `~/.agents/skills` symlink (the same fan-out
  `daily-report` relies on; `~/.codex/skills` works the same way) — not by
  writing two physical copies.
- **A2 — Upstream skill dirs stay single-file.** If a future tag adds sibling
  files (e.g. `references/`), the gitlab branch must switch to an archive form;
  the `ai-agents.toml` comment records this.
- **A3 — Track the latest release, not a hard pin on v1.109.0.** The v1.109.0
  link identified the tree; "same version as glab" means following the same
  moving `latest` resolution the glab binary already uses.

## Implementation Units

### U1. Shared glab release partial + `vcs.toml` migration

**Goal:** Single-source the `gitlab-org/cli` latest-release tag and remove the
dead skill URL vars.

**Requirements:** R3, R4; KTD2.

**Dependencies:** none.

**Files:** `.chezmoitemplates/glab-release-ref.tmpl` (create);
`.chezmoiexternals/vcs.toml` (modify).

**Approach:** Move the tag resolution (the `getRedirectedURL
"https://gitlab.com/api/v4/projects/34675721/releases/permalink/latest"` +
`output "curl" "-fsSL" … | fromJson` → `tag_name` logic) into the partial
verbatim — it already fails closed via `curl -f`. Give the partial a doc comment
naming its consumers, the `compound-engineering-ref.tmpl` shape. In `vcs.toml`
replace `$glabLatestReleaseUrl`/`$glabLatestRelease` with `$glabTag :=
includeTemplate "glab-release-ref.tmpl" .` and build `$glabArchiveUrl` from
`$glabTag`; delete the orphaned `$glabSkillUrl`/`$glabStackSkillUrl`; drop
"(+ its bundled skills)" from the line-1 summary comment (the skills move to
`ai-agents.toml`).

**Patterns to follow:** `.chezmoitemplates/compound-engineering-ref.tmpl`
(shared ref partial with consumer documentation).

**Test scenarios:** `Test expectation: none — template/config; verified by the
render checks below (no application code path to unit-test).`

**Verification:** `chezmoi execute-template` of `vcs.toml` renders a glab archive
URL carrying the same tag as before the change (a moving `latest` aside, the
resolution is identical); the partial emits a bare `vX.Y.Z` tag with no stray
whitespace; no reference to `glabSkillUrl` remains anywhere.

### U2. Registry data for the two skills

**Goal:** Declare both skills in `agents.skills.external`.

**Requirements:** R1, R4; KTD1, KTD3, KTD4.

**Dependencies:** none (inert until U3 renders them).

**Files:** `.chezmoidata/agents.yaml` (modify).

**Approach:** Append two entries to `agents.skills.external` — `glab` and
`glab-stack`, each with `source: gitlab-org/cli`, `host: gitlab`,
`versionSource: glabRelease`, and `skillPath:
internal/commands/skills/bundled/assets/<name>`. Update the skills comment block:
document the `host`/`versionSource`/`skillPath` keys and adjust the "fetched from
GitHub" wording so it no longer claims GitHub-only sourcing.

**Test scenarios:** `Test expectation: none — data; exercised by U3's render
verification.`

**Verification:** YAML parses; the entries sit alongside the existing
GitHub-sourced ones without altering them.

### U3. GitLab branch in the `ai-agents.toml` skills loop

**Goal:** Render the two GitLab raw-file skill externals from the registry data.

**Requirements:** R1, R2, R3, R5; KTD2, KTD3, KTD4, KTD5; A2. (R2 is satisfied
by the files this unit renders landing under `~/.agents/skills/`, which the
existing dotagents `~/.claude/skills` symlink fans out — no separate check or
artifact is needed.)

**Dependencies:** U1 (the partial), U2 (the data).

**Files:** `.chezmoiexternals/ai-agents.toml` (modify).

**Approach:** In the `agents.skills.external` range loop: capture the root
context before `range` (the `opencode.plugins` block below already does `$ctx :=
.`) so the partial can be included with full data. Extend ref resolution with a
`versionSource` branch — `glabRelease` → `includeTemplate
"glab-release-ref.tmpl"`; any other value → `fail` (mirroring the
`opencode.plugins` unsupported-versionSource guard); `ref` and the default
`gitHubLatestRelease` paths unchanged. When an entry's `host` is `gitlab`, emit a
`type = "file"` external `[".agents/skills/<name>/SKILL.md"]` with the raw URL
built from `source`/`$ref`/`skillPath`; otherwise emit the existing GitHub
archive form untouched. Update the section's big comment: the gitlab raw-file
branch, the `versionSource` rule, the single-file assumption (A2), and refresh
semantics (the tag sits in the URL, so a release bump is a new cache key and a
re-fetch; an upstream removal 404s and fails apply loudly).

**Patterns to follow:** the same file's `opencode.plugins` `versionSource` +
`includeTemplate` guard; the orphaned `$glabSkillUrl` construction in `vcs.toml`
(the exact raw-URL form, already 200-verified at v1.109.0).

**Test scenarios:** `Test expectation: none — declarative externals; verified by
the render + fetch smoke below.`

**Verification:**
- Rendered `ai-agents.toml` is valid TOML and contains
  `[".agents/skills/glab/SKILL.md"]` and `[".agents/skills/glab-stack/SKILL.md"]`
  whose URL tag **equals** the tag in the rendered `vcs.toml` glab archive URL
  (the R3 lockstep assertion).
- Both rendered raw URLs return HTTP 200; the GitHub-sourced skill entries render
  byte-identical to before.
- `chezmoi execute-template` succeeds for the file (the repo's op-stub render
  harness per `AGENTS.md`); CI `render-dotfiles.yml` renders every platform
  (windows skips the POSIX-gated block).

### U4. Contract and comment reconciliation

**Goal:** Keep the written ownership contract accurate about the new branch.

**Requirements:** KTD3, KTD4.

**Dependencies:** U1–U3 (documents what they landed).

**Files:** `AGENTS.md` (modify); verify-only: `README.md`,
`dot_agents/private_readonly_agents.toml.tmpl`.

**Approach:** Extend the agent-surfaces sentence in `AGENTS.md` ("External skills
come from `agents.skills.external` → …") with one clause: GitLab-sourced
`glab`/`glab-stack` single-file skills are pinned to the glab release via
`.chezmoitemplates/glab-release-ref.tmpl`, which `vcs.toml`'s glab binary also
consumes. `README.md`'s skills wording and the `agents.toml.tmpl` comment are
strictly verify-only — research already confirmed neither makes a GitHub-only
claim, so this plan changes nothing in them and the DoD's five-path diff limit
stays unconditional.

**Test scenarios:** `Test expectation: none — documentation.`

**Verification:** `CLAUDE.md` remains exactly `@AGENTS.md` (one-line include,
untouched); `git diff --check` clean.

## Scope Boundaries

**In scope:** the four units above — the shared partial, registry data, the
gitlab render branch, and the contract clause.

### Deferred to Follow-Up Work

- **Archive-form GitLab skills** — only if upstream adds sibling files to a
  skill's subtree (A2); the raw-file branch is correct today.
- **Windows skills support** — blocked on the POSIX-only dotagents symlink, a
  pre-existing posture unchanged by this plan.

**Out of scope:** applying to live `$HOME` (deploy only when the user asks);
changing how the glab binary itself is fetched; teaching dotagents about skills
again; any harness beyond the existing symlink fan-out.

## Risks

- **Upstream moves or removes a skill** → the raw URL 404s and apply fails
  loudly (fail-closed, intended). Fix path: adjust `skillPath` or drop the entry.
- **A glab release landing mid-render transiently desyncs binary and skills** —
  each consumer file re-resolves `releases/permalink/latest` in its own render
  pass (KTD2), so a publish between the two renders puts them on different tags
  for that apply and can flake R5's tag-equality assertion. Self-heals on the
  next apply; R5 retry semantics are re-render both files and compare again
  before treating a mismatch as a real lockstep break.
- **One added render-time GitLab API call per consumer file** — the same posture
  `vcs.toml` already takes for glab; the GitLab anonymous API budget covers it.
- **`e915044` removed these skills as "unused"** — re-adding is explicit user
  direction; what changed since is the registry + symlink fan-out that makes them
  managed and discoverable.

## Verification Contract / Definition of Done

- All unit verifications pass, including the R3 cross-file tag equality check and
  the two raw-URL 200 fetches.
- `git diff --check` clean; diff limited to the five touched paths
  (`.chezmoitemplates/glab-release-ref.tmpl`, `.chezmoiexternals/vcs.toml`,
  `.chezmoidata/agents.yaml`, `.chezmoiexternals/ai-agents.toml`, `AGENTS.md`).
- CI `render-dotfiles.yml` and `ci.yml` green on the PR.
- No live `$HOME` apply performed.

## Sources & Research

- `.chezmoiexternals/vcs.toml` — glab tag resolution + orphaned
  `$glabSkillUrl`/`$glabStackSkillUrl`; `git show e915044` — the removed
  `[glab-skill]`/`[glab-stack-skill]` raw-file externals (targets were
  `.agents/skills/<name>/SKILL.md`).
- `.chezmoiexternals/ai-agents.toml` — the `agents.skills.external` archive loop,
  its GitHub-only comment, and the `opencode.plugins` `versionSource` guard.
- `.chezmoidata/agents.yaml` — skills comment block + current list
  (playwright-cli, agent-browser, improve).
- GitLab API: `repository/tree` at `v1.109.0` under
  `internal/commands/skills/bundled/assets` (each skill = one `SKILL.md`); both
  raw `SKILL.md` URLs return HTTP 200.
- `dot_agents/private_readonly_agents.toml.tmpl` and
  `.chezmoiscripts/70-agents/run_onchange_after_install-dotagents-skills.sh.tmpl`
  — the dotagents `~/.claude/skills` symlink ownership (MCP-only posture).
- `docs/plans/2026-07-21-006-refactor-migrate-daily-report-skill-plan.md` — the
  symlink fan-out model; `docs/plans/2026-07-21-002-feat-agent-browser-external-plan.md`
  — the external-addition plan shape; `.chezmoitemplates/compound-engineering-ref.tmpl`
  — the shared-ref partial precedent.
- Repo conventions: `AGENTS.md` — agent surfaces & ownership, render verification
  harness, single-source-of-truth table.
