---
title: Session Non-Bare Garden Trees in aoe with Per-Shape Tool Selection - Plan
type: feat
date: 2026-07-27
topic: garden-aoe-session-non-bare
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Session Non-Bare Garden Trees in aoe with Per-Shape Tool Selection - Plan

## Goal Capsule

- **Objective:** Make the garden `aoe-session` bootstrap create aoe sessions for both tree shapes — bare trees open their default-branch worktree with the registered plain-shell `zsh` agent (`--tool zsh`), non-bare plain clones open a default-tool session on the checkout — while group-policy enforcement and the other two bootstrap commands stay exactly as they are.
- **Authority:** GitHub issue `hyperlapse122/dotfiles#94` governs scope and behavior; `AGENTS.md` governs the encrypted-source edit flow and the no-live-apply verification boundary.
- **Execution profile:** Lightweight — one stanza plus comments inside the GPG-encrypted garden manifest, and two comment-only doc surfaces; harness-verified, no live deploy.
- **Stop conditions:** Stop rather than broaden scope if the change appears to require editing `.chezmoidata/agents.yaml`, retro-fitting the tool of existing sessions, adding a fourth garden command, or running a live `chezmoi apply`.
- **Tail ownership:** The LFG pipeline owns commit, push, pull-request creation, and CI monitoring; the live `chezmoi apply` that creates the real sessions is the user's post-merge step.

## Product Contract

### Summary

Extend the garden `aoe-session` command so every tree shape gets an aoe session, with the session tool chosen by tree shape: bare trees get `--tool zsh` (plain shell on the default-branch worktree), non-bare trees get aoe's default tool on the checkout. This finishes the `zsh` custom-agent wiring registered in commit `e89391f` and lifts the non-bare self-skip introduced by `docs/plans/2026-07-19-001-fix-garden-cmds-non-bare-skip-plan.md` — for `aoe-session` only.

### Problem Frame

The garden registry declares two tree shapes, and `aoe-session` mishandles both today. For bare trees it creates the default-branch-worktree session with aoe's default tool, a coding agent — but the intended workflow is shell-first: the default branch opens a plain shell, and feature-branch coding sessions are created separately on demand. The `zsh` custom agent was registered in `.chezmoidata/agents.yaml` (`session.custom_agents.zsh: zsh`, no `agent_detect_as` entry so aoe injects no agent flags) with exactly this later wiring in mind, yet nothing ever passes `--tool zsh`. For non-bare trees (plain clones of third-party tools, no worktree layout) `aoe-session` self-skips, so those projects never appear in aoe at all and any session for them is a manual, ungrouped `aoe add`. The fix is per-shape session creation inside the one bootstrap command, not a new command: the wildcard bootstrap and the apply-time reconcile both invoke the fixed triple `setup-gitdir setup-upstream aoe-session`.

### Requirements

**Session behavior**

- R1. New sessions for bare trees select the registered `zsh` custom agent: the single creation call becomes `aoe add "$proj" -t "$branch" -g "$group" -w "$branch" --tool zsh`.
- R2. Non-bare trees get a session on the checkout itself — `aoe add "$proj" -t "$branch" -g "$group"` with aoe's default tool, no `-w`, no `--tool` — and `aoe-session` no longer self-skips them (one narrow guard remains: a non-bare tree whose HEAD is unresolvable skips with a notice instead of failing — see KTD-4).
- R3. Existing sessions of either shape receive group-policy enforcement only (the matcher compares the per-shape session path: `$proj/$branch` bare, `$proj` non-bare); an existing session's tool is never retro-fitted.
- R4. `setup-gitdir` and `setup-upstream` stay byte-identical and keep self-skipping non-bare trees.

**Docs and hygiene**

- R5. Every comment that states the old all-three-skip behavior — the manifest header paragraph, the manifest non-bare example block, the `aoe-session` stanza comment, and the reconcile script's bootstrap comment — describes the new per-shape behavior, and the composed agent instructions' worktree-only description of `aoe-session` is extended to cover both shapes.
- R6. Verification is render/harness-only: the plaintext registry never enters git, and no live `chezmoi apply` or real `aoe add` runs.

### Scope Boundaries

**Out of scope:**

- Retro-fitting `--tool zsh` onto sessions that already exist (see KTD-2).
- `.chezmoidata/agents.yaml` — the `zsh` custom agent is already registered; nothing there changes.
- `src-audit` — it recognizes both tree shapes already and has no aoe-session logic.
- Non-bare support in `setup-gitdir` / `setup-upstream` — their skips stand.
- Any live `chezmoi apply` into `$HOME` or real `aoe add` — deferred to the user post-merge.

**Deferred to Follow-Up Work:**

- The manifest header's stale AGE/`.age` references (pre-existing drift from the GPG migration — the source is now `src/encrypted_readonly_garden.yaml.asc`; unrelated to this behavior change).
- The user-run `chezmoi apply` after merge, which creates the real sessions: default-tool sessions for the non-bare trees, `--tool zsh` for any bare tree lacking one.
- Existing bare-tree sessions keep their current (coding-agent) tool after apply — only newly created sessions get `--tool zsh` (KTD-2). To reach the shell-first end state for an existing session, the user removes it (`aoe remove <title>`, losing its session state) and reruns the bootstrap; otherwise it stays as-is indefinitely.
- Contingency for the post-merge apply: if a non-bare `aoe add` fails against the real CLI (the harness only exercises a stub), the reconcile re-fails every apply until remedied — the remedy is to remove the bad session (`aoe remove`) or to restore the non-bare skip guard temporarily and re-apply.

### Acceptance Examples

- AE1. **Covers R1.** Harness-running the extracted `aoe-session` stanza against a bare fixture with no existing session invokes exactly `aoe add <project> -t <default-branch> -g <host>/<group>/<project> -w <default-branch> --tool zsh`, once.
- AE2. **Covers R2.** Harness-running against a non-bare fixture (plain clone, path without `/.bare`) with no existing session invokes exactly `aoe add <checkout> -t <checked-out-branch> -g <host>/<group>/<project>` — no `-w`, no `--tool`.
- AE3. **Covers R3.** With an existing session whose group drifted, either shape issues only `aoe group move <id> <group>`; with the correct group it prints the skip line; in neither case does `aoe add` run or a tool change.
- AE4. **Covers R4.** Harness-running `setup-gitdir` / `setup-upstream` against the non-bare fixture prints the skip line, exits 0, and leaves the clone untouched.

## Planning Contract

### Key Technical Decisions

- KTD-1. **Extend `aoe-session` with a shape flag, not a fourth command.** The wildcard bootstrap, the apply-time reconcile (`.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`), and the documented manual flow all invoke the fixed triple; a new command would force call-site changes everywhere and split one tree's session logic across two stanzas.
- KTD-2. **`--tool zsh` applies only to the bare new-session path; existing sessions are never retro-fitted.** aoe exposes no change-tool operation (only add and group-move), so re-pointing an existing session would mean deleting and recreating it — destructive to live state, and the issue scopes the wiring to new sessions.
- KTD-3. **Non-bare sessions attach to the checkout path with aoe's default tool and no `-w`.** A plain clone has no worktree layout for `-w` to manage, and the issue assigns the branch-workflow-free trees the default tool. The existing-session matcher therefore compares the session path against `$proj/$branch` for bare trees and `$proj` for non-bare ones.
- KTD-4. **Branch resolution reads `${TREE_PATH}` HEAD for both shapes, but an unresolvable HEAD fails only bare trees.** For a bare tree the bare repo's HEAD is the default branch; for a plain clone the checkout's HEAD is the checked-out branch. A bare tree with an unresolvable HEAD keeps the existing `cannot resolve the default branch` exit-1 path — an unreadable bare HEAD signals a broken tree. A non-bare tree with a detached HEAD instead skips with a notice and exit 0: a pinned tag/commit checkout is a normal, deliberate state for a third-party tool clone, and failing there would abort the wildcard bootstrap and re-fail every apply (the reconcile runs under `set -euo pipefail`) for a tree that harmlessly self-skipped before this change.
- KTD-5. **The comment sweep covers only surfaces that state the old behavior, and the kept policy clause is qualified in place.** The composed instructions' "never developed through aoe" clause stays, but gains the distinction this plan draws — non-bare trees get no aoe worktree development; their session attaches to the checkout for tooling and inspection — so the text agents read encodes the distinction rather than leaving it plan-only.

### Assumptions

- Garden expands `${...}` in the reworked stanza exactly as in the current one — no new expansion surface is introduced (same `${TREE_PATH}` / `${TREE_NAME}` / `${GARDEN_ROOT}` variables; shell-local variables stay unbraced, e.g. `$proj`, `$bare`).
- `aoe add [PATH]` without `-w` accepts a plain directory — the CLI help defines PATH as "Project directory (defaults to current directory)" — and `aoe list --json` records the resulting session path in a form the existing-session matcher (with its `/./` normalization) compares equal to `$proj`. Both confirmations land with the user's post-merge apply; the contingency note in Deferred to Follow-Up Work covers a surprise.
- aoe's configured default tool is the intended agent for non-bare sessions, per the issue ("aoe 기본 tool").
- Updating the reconcile-script comment and the composed-instructions sentences is in scope under the repository's doc-sweep rule, although the issue names only the manifest comments.

## Implementation Units

### U1. Rework `aoe-session` for per-shape sessions in the garden manifest

- **Goal:** Bare new sessions use `--tool zsh`; non-bare trees get default-tool sessions on the checkout; the manifest comments match.
- **Requirements:** R1, R2, R3, R4, R5 (manifest half), R6.
- **Dependencies:** none.
- **Files:** `src/encrypted_readonly_garden.yaml.asc` — edited through the documented non-interactive flow: `chezmoi --source "$PWD" decrypt src/encrypted_readonly_garden.yaml.asc` into a mode-600 per-user scratch copy (outside the repo), edit the scratch, `chezmoi --source "$PWD" encrypt <scratch>` back over the `.asc`. Both directions were round-trip-verified during planning. The scratch copy is trap-cleaned afterwards; plaintext is never printed to stdout or committed.
- **Approach:** Replace the non-bare self-skip guard with a shape split that sets `proj` and a `bare` flag; keep the shared `rel`/`group` derivation; resolve `branch` from `${TREE_PATH}` HEAD, with the empty-branch outcome split per shape (KTD-4: bare exits 1, non-bare skips with a notice and exit 0); derive the session path per shape; run the existing-session enforce block unchanged against that path; branch the creation call per KTD-2/KTD-3. Update the three comment sites inside the manifest (R5): the header's "All three commands SELF-SKIP non-bare trees" paragraph, the non-bare example block's "the three custom commands below self-skip these trees" clause, and the `aoe-session` stanza comment (per-shape behavior plus the zsh rationale: default-branch worktrees open a plain shell; feature-branch coding sessions are created separately on demand).
- **Technical design** (directional, not implementation specification):
  ```sh
  case "${TREE_PATH}" in
    */.bare) proj="$(dirname "${TREE_PATH}")"; bare=1 ;;
    *)       proj="${TREE_PATH}";               bare=  ;;
  esac
  # group derivation unchanged; branch from git -C "${TREE_PATH}" HEAD
  # empty branch: bare -> error exit 1 (existing path); non-bare -> notice + exit 0
  # session_path = bare ? "$proj/$branch" : "$proj"
  # existing-session enforce block unchanged, matched on session_path
  # bare:     aoe add "$proj" -t "$branch" -g "$group" -w "$branch" --tool zsh
  # non-bare: aoe add "$proj" -t "$branch" -g "$group"
  ```
- **Patterns to follow:** the existing `aoe-session` stanza (message/exit style, unbraced shell variables under garden's `${...}` expansion, the `aoe list --json | jq` session matcher with its `/./` normalization); `dot_local/bin/executable_src-audit` for the `*/.bare` shape test.
- **Test scenarios:**
  - Bare new session (Covers AE1): disposable bare fixture plus an `aoe` stub recording argv → exactly one `aoe add` carrying `-w <branch>` and `--tool zsh`; group carries the host segment.
  - Non-bare new session (Covers AE2): disposable plain-clone fixture → exactly one `aoe add` on the checkout path with no `-w` and no `--tool`; group is the checkout's host-including path under the garden root.
  - Existing session, drifted group, both shapes (Covers AE3): canned `aoe list --json` returns a session on the per-shape path → only `aoe group move <id> <group>` runs; with the correct group, the skip line prints; `aoe add` never runs.
  - Detached-HEAD edge (KTD-4): non-bare fixture with a detached HEAD → the stanza prints a skip notice and exits 0; a bare fixture whose HEAD cannot be resolved still prints `cannot resolve the default branch` and exits 1.
  - Skip guards unchanged (Covers AE4): `setup-gitdir` / `setup-upstream` on the non-bare fixture print their skip lines, exit 0, and write nothing; both stanzas are byte-identical in the decrypted diff.
  - Manifest hygiene: the decrypted plaintext parses as YAML (`yq`, output discarded), and the decrypted diff against the pre-edit copy touches only the `aoe-session` stanza and the three comment sites.
- **Verification:** All harness cases pass; the re-encrypted `.asc` decrypts back to the edited scratch copy; `git status` shows no plaintext registry.

### U2. Sync the two doc surfaces for per-shape sessioning

- **Goal:** The reconcile-script comment stops claiming every bootstrap command skips non-bare trees, and the composed agent instructions describe per-shape sessioning instead of worktree-only sessioning.
- **Requirements:** R5.
- **Dependencies:** U1 (docs describe implemented behavior).
- **Files:** `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` (the "each command self-skips non-bare trees" comment above the bootstrap invocation), `.chezmoitemplates/agents-instructions.tmpl` (the sentence describing what `aoe-session` does, and the session title/group sentence).
- **Approach:** Adjust only the stale sentences. The script comment now says `setup-gitdir` / `setup-upstream` self-skip non-bare trees while `aoe-session` creates a default-tool session directly on the non-bare checkout (group self-heal unchanged). The instructions' `aoe-session` sentence gains the non-bare clause — no worktree; the session attaches to the checkout — and notes that bare default-branch sessions launch the plain-shell `zsh` agent; the session title/group sentence notes the title is the worktree name for bare trees and the checked-out branch for non-bare ones. The "never developed through aoe" policy clause stays, qualified in place with the worktree-vs-checkout-session distinction (KTD-5).
- **Test scenarios:**
  - Test expectation: none — comment/prose-only edits; no consumer parses either text. The script template must still render through `chezmoi execute-template` (per-user stub-`op` scratch per `AGENTS.md`).
- **Verification:** The rendered script carries the new comment; `git diff --check` is clean; the instructions' `aoe-session` sentence covers both shapes (locked worktree for bare, checkout-attached session for non-bare) and no longer describes `aoe-session` as worktree-only.

## Verification Contract

| Gate | Command / check | Proves |
|---|---|---|
| Source round-trip | `chezmoi --source "$PWD" decrypt src/encrypted_readonly_garden.yaml.asc` into a mode-600 scratch; `yq` parses it; decrypted diff vs the pre-edit copy shows only the stanza and comment lines | Edit correctness, no manifest drift, R4 |
| Command harness | Extract `aoe-session` (and the two skip guards) from the edited plaintext; run under `sh` against disposable bare/non-bare fixtures with an `aoe` stub recording argv and canned `aoe list --json` | AE1–AE4, R1–R4 |
| Template render | `chezmoi execute-template` on the 90-src script via the `AGENTS.md` stub-`op` scratch | U2 renders |
| Hygiene | `git status` shows only the `.asc`, the two text files, and this plan; `git diff --check`; scratch copies removed | R6, secrets policy |
| PR redaction check | Before the PR is opened, grep the semantic diff prepared for the PR body against the registry's identifiers (tree names and host/group paths from the decrypted manifest) — zero matches required | DoD's "no registry identifiers" claim, secrets policy |
| No live side effects | No `chezmoi apply` into `$HOME`, no real `aoe add`; stated plainly in the PR body | R6 |

## Definition of Done

- The edited `.asc` decrypts to the reworked stanza; harness cases AE1–AE4 pass; `setup-gitdir` and `setup-upstream` are byte-identical before and after; a detached-HEAD non-bare fixture skips with a notice (exit 0) while the bare failure path stays exit 1.
- The manifest comments, the reconcile-script comment, and the composed instructions all describe per-shape sessioning.
- No plaintext registry in git; scratch files removed; no leftover experimental edits beyond U1/U2.
- The change lands on a work-descriptive branch — the checked-out `wei` is renamed in place per the repo's branch rules (it is absent from the remote), e.g. `feature/garden-aoe-session-non-bare` — with a PR whose CI (`render-dotfiles.yml`, `ci.yml`) reaches terminal green and whose body carries the redacted semantic diff of the manifest change (verified identifier-free per the PR redaction check).
- Live `chezmoi apply` and the resulting real session creation are explicitly left to the user after merge.
