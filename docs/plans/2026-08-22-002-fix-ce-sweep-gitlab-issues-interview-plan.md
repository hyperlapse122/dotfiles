---
title: "fix: add gitlab-issues to ce-sweep setup interview overlay"
date: 2026-08-22
type: fix
topic: ce-sweep-gitlab-issues-interview
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Fix: Add GitLab Issues to ce-sweep Setup Interview Overlay

## Goal Capsule

- **Objective:** make `ce-sweep`'s interactive setup interview (`references/interview.md`) present `gitlab-issues` as a selectable feedback source option alongside GitHub Issues, Slack, and Email.
- **Product authority:** this repository manages local compound-engineering overlays under `dot_local/share/compound-engineering-overlays/`.
- **Open blockers:** none.

## Problem Frame

`ce-sweep` dispatches feedback sources configured in `.compound-engineering/config.local.yaml`.
When `ce-sweep` runs with `feedback_sources` unset (or via `ce-sweep setup` / `ce-sweep reconfigure`), it executes `skills/ce-sweep/references/interview.md` to conduct an interactive setup interview.
Currently, `interview.md` hardcodes only three source types: `slack`, `github-issues`, and `email-experimental`.
While this repository provisions the canonical GitLab source connector persona at `skills/ce-sweep/references/sources/gitlab-issues.md`, the setup interview never surfaces `gitlab-issues` to the user and does not define GitLab target (`group/project`) or label defaults (`feedback:ack` / `feedback:resolved`).
Furthermore, `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` only copies `gitlab-issues.md`.

## Requirements

- R1. Provide an overlaid `skills/ce-sweep/references/interview.md` under `dot_local/share/compound-engineering-overlays/` that includes `gitlab-issues` in the source type list (target `group/project`, default ack `feedback:ack`, default closeout `feedback:resolved`).
- R2. Update `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` to install all managed overlay files from `~/.local/share/compound-engineering-overlays/` (specifically `references/sources/gitlab-issues.md` and `references/interview.md`) into the pinned compound-engineering version directory.
- R3. Preserve the exact upstream `skills/ce-sweep/SKILL.md` and upstream sources (`email.md`, `github-issues.md`, `slack.md`).
- R4. Update `.ci/test-compound-engineering-overlays.sh` to verify that both `gitlab-issues.md` and `interview.md` are installed, byte-identical to their overlay sources, and that all safety invariants (foreign symlink handling, plain directory validation, plugin.json pruning) pass.

## Success Criteria

- Running `ce-sweep setup` or interactive first-run presents `gitlab-issues` as a valid selectable option with proper target format and label defaults.
- `.ci/test-compound-engineering-overlays.sh` passes completely.
- Template rendering and shellcheck pass.

## Implementation Steps

1. Create `dot_local/share/compound-engineering-overlays/skills/ce-sweep/references/interview.md` with `gitlab-issues` documented in sections 1, 2, and 8.
2. Update `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` to iterate through managed overlay files or copy both `gitlab-issues.md` and `interview.md` cleanly.
3. Update `.ci/test-compound-engineering-overlays.sh` to include `interview.md` in the overlay test fixtures and assertions.
4. Execute verification tests locally to confirm everything passes.
