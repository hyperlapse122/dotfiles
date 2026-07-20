---
title: Skip Non-Bare Trees in Garden Bootstrap Commands - Plan
type: fix
date: 2026-07-19
topic: garden-cmds-skip-non-bare-trees
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Skip Non-Bare Trees in Garden Bootstrap Commands - Plan

## Goal Capsule

- **Objective:** Make the three garden bootstrap custom commands (`setup-gitdir`, `setup-upstream`, `aoe-session`) self-skip non-bare trees so the documented one-pass wildcard bootstrap (`garden cmd '*' …`) works on a mixed registry, fixing the live `aoe-session` failure on `opencode-mcp-figma`.
- **Authority:** The user's bug report governs scope; the non-bare policy in `dot_agents/readonly_AGENTS.md` (plain clone, no aoe session — the bootstrap commands self-skip such trees) governs behavior; `AGENTS.md` governs the encrypted-source edit flow.
- **Execution profile:** Lightweight shell-guard change inside one age-encrypted manifest plus a matching one-line doc correction.
- **Stop conditions:** Stop rather than broadening scope if the fix appears to require teaching `aoe-session` to support non-bare trees, changing `src-audit`, or re-shaping any tree declaration.
- **Tail ownership:** The LFG pipeline owns commit, push, pull-request creation, and CI monitoring; implementation deploys the fix on this host to close out the user's live error.

## Product Contract

### Summary

Add a non-bare guard to the top of each of the three garden custom commands so they print a skip line and exit 0 when the tree path does not end in `/.bare`, and correct the one instruction line that documents the now-enforced policy.

### Problem Frame

`~/src/garden.yaml` declares `opencode-mcp-figma` as the registry's one non-bare tree (`path: github.com/gberaudo/opencode-mcp-figma`, no `bare: true`). All three custom commands derive the project root as `dirname "${TREE_PATH}"`, which is correct only for bare trees (`…/<project>/.bare` → `…/<project>`). On the non-bare tree, `dirname` climbs to the group dir `~/src/github.com/gberaudo`, so `aoe-session` runs `aoe add ~/src/github.com/gberaudo -t master -g gberaudo -w master` and fails with the reported error: `Worktree mode requires a git repository, but this path is not one: /home/h82/src/github.com/gberaudo`.

The same derivation makes the wildcard bootstrap a mixed-registry footgun beyond this one error: `setup-gitdir` would write a `gitdir: ./.bare` pointer file into the group dir (`~/src/github.com/gberaudo/.git`), corrupting a directory that is not a project at all. `setup-upstream` is not benign on a normal clone either: it fetches and prunes remote refs and re-resolves `origin/HEAD` (its branch-config writes skip only because the clone already set them), so per policy it must not run there.

The registry header documents `garden cmd '*' setup-gitdir setup-upstream aoe-session` as the new-host bootstrap; with a non-bare tree present that command cannot succeed today.

### Requirements

- R1. Each of the three custom commands skips a non-bare tree with an informative one-line message and exit status 0, so the wildcard bootstrap exits 0 on a mixed registry.
- R2. A skipped non-bare tree is untouched: no `.git` pointer file in its group dir, no git config changes inside the clone, no aoe session created.
- R3. Valid bare-tree behavior (path ends in `/.bare`) is unchanged: same pointer write, same fetch/upstream logic, same aoe-session derivation and existing-session skip.
- R4. The shared agent instructions (`dot_agents/readonly_AGENTS.md`) and the manifest's own comments describe the self-skip, so the wildcard bootstrap guidance stays accurate.

### Scope Boundaries

**In scope:** The three `commands:` stanzas and adjacent comments in `src/encrypted_readonly_garden.yaml.age`, the non-bare bullet in `dot_agents/readonly_AGENTS.md`, deploy + live verification on this host.

**Out of scope:**

- Teaching `aoe-session` to create sessions for non-bare trees — the policy stands: non-bare trees never get aoe sessions.
- Changing `src-audit`; it already recognizes both shapes via the same `*/.bare` test.
- Editing any tree declaration, re-running `garden grow`, or touching trees other than through the verification run.
- Repository-root `AGENTS.md`: its non-bare bullet carries no "do NOT run" clause and stays accurate.

**Deferred to Follow-Up Work:** Registry-level validation that a `bare: true` declaration whose path lacks the `/.bare` suffix fails loudly — the commands receive no `bare` flag from garden, so this belongs to `src-audit` or a registry linter, not to this fix. A CI-hosted decrypt-attestation gate for `*.age` PRs — needs a maintainer decision on which identity holds the age key in CI.

### Acceptance Examples

- AE1. **Covers R1, R2.** Running each command with `TREE_PATH=~/src/github.com/gberaudo/opencode-mcp-figma` prints a skip line naming the tree, exits 0, and leaves `~/src/github.com/gberaudo/` without a `.git` file, the clone's git config unchanged, and its remote refs and `origin/HEAD` untouched (no fetch, no prune).
- AE2. **Covers R3.** Running each pre-change and post-change command against a disposable bare fixture (a local bare repo with a `file://` remote, plus an `aoe` stub on PATH) produces identical outcomes: same pointer content, same fetch/upstream behavior, same `aoe add` arguments for a session-less tree.
- AE3. **Covers R1, R2, R3.** After `chezmoi apply` deploys the edited manifest, `garden --chdir ~/src cmd '*' setup-gitdir setup-upstream aoe-session` exits 0, prints skip lines for `opencode-mcp-figma`, and no aoe session exists for it.

## Planning Contract

### Key Technical Decisions

- KTD-1. **Guard inside each command, not at the call site.** The non-bare policy is already documented; enforcing it inside the commands removes the footgun for every caller (wildcard bootstrap, per-tree runs, future hosts) and keeps the documented one-pass bootstrap valid. Rejected alternatives: teaching `aoe-session` non-bare support (contradicts the no-aoe policy) and documenting "don't use `'*'`" (leaves `setup-gitdir`'s stray-file write live).
- KTD-2. **Detect non-bare by `*/.bare` path suffix, not a git probe.** A `case "${TREE_PATH}" in */.bare)` test implements the manifest convention that every valid bare tree's path ends in `/.bare`, is the same test `src-audit` already uses (`dot_local/bin/executable_src-audit`), needs no subprocess, and resolves correctly even for a not-yet-grown tree.
- KTD-3. **Skip exits 0 with the message on stdout.** A non-zero skip would fail the wildcard run; the shape mirrors the existing `aoe-session` success-skip (`… already has a session — skipping`).

### Assumptions

- The wildcard bootstrap failing on this registry is unwanted behavior, not a signal that non-bare trees should join the bootstrap — the policy text in `dot_agents/readonly_AGENTS.md` already settles that.
- Garden's textual `${…}` expansion covers `${TREE_PATH}` and `${TREE_NAME}` inside a `case` word, as it does in the existing command bodies.

## Implementation Units

### U1. Guard the three bootstrap commands in the garden manifest

- **Goal:** Every bootstrap command self-skips non-bare trees, and the manifest comments document it.
- **Requirements:** R1, R2, R3, R4 (comment half).
- **Dependencies:** none.
- **Files:** `src/encrypted_readonly_garden.yaml.age` (edit through the decrypt → scratch-edit → re-encrypt flow; the scratch copy is a mode-600 file under `$XDG_RUNTIME_DIR`, trap-cleaned, never printed to stdout).
- **Approach:** At the top of each of `setup-gitdir`, `setup-upstream`, `aoe-session`, add the KTD-2 `case` guard: `*/.bare)` falls through to the existing body; anything else prints `<cmd>: <tree> is a non-bare tree (plain clone) — skipping` and exits 0. Bare-tree bodies stay byte-identical below the guard. Update the header comment block (the wildcard-bootstrap paragraph) and the non-bare example comment to state that the three commands self-skip non-bare trees. Every `chezmoi` decrypt/encrypt/apply invocation runs with `--source` pointed at this worktree — the default source is the main checkout at `~/.local/share/chezmoi`, which would redeploy the pre-change manifest.
- **Patterns to follow:** The existing `aoe-session` stanza for message/exit style; `dot_local/bin/executable_src-audit` for the `*/.bare` shape test.
- **Test scenarios:**
  - Non-bare skip (Covers AE1): harness-run each extracted command with `TREE_PATH`/`TREE_NAME`/`GARDEN_ROOT` set for `opencode-mcp-figma` → skip line on stdout, exit 0, no `~/src/github.com/gberaudo/.git` created, clone config untouched, no aoe session added.
  - Bare-tree parity (Covers AE2): extract the pre-change and post-change stanzas and run both against a disposable bare fixture (a local bare repo cloned `--bare` from a local source, `file://` remote, an `aoe` stub on PATH recording its arguments) → identical pointer content, identical upstream/config state, identical `aoe add` invocation; live bare trees are exercised only by the post-deploy wildcard run, not by the harness.
  - Malformed-registry edge: a `bare: true` tree whose path lacks the `/.bare` suffix is treated as non-bare and skips — accepted for now (the commands receive no `bare` flag from garden, so they cannot distinguish it); flagging such declarations is deferred to registry-level validation (see Deferred to Follow-Up Work).
  - YAML validity: the decrypted scratch copy parses (`yq` against the scratch file, output discarded) and the decrypted diff against the currently deployed file shows only guard and comment lines added.
- **Verification:** Wildcard run green post-deploy (AE3); no stray files under `~/src/github.com/gberaudo/`; `aoe list` shows no `gberaudo` session.

### U2. Correct the non-bare policy line in the shared agent instructions

- **Goal:** The deployed-instruction source stops saying the bootstrap commands must not run on non-bare trees and instead says they skip them.
- **Requirements:** R4.
- **Dependencies:** U1 (docs describe implemented behavior).
- **Files:** `dot_agents/readonly_AGENTS.md` (the "A tree MAY instead be non-bare …" bullet in Project layout).
- **Approach:** Replace the "do NOT run `setup-gitdir` / `setup-upstream` / `aoe-session` on it" clause with a statement that the three commands self-skip non-bare trees, keeping the rest of the bullet (plain clone, real `.git/`, no worktrees, no aoe session, `src-audit` recognizes both shapes) intact.
- **Test scenarios:**
  - Test expectation: none — prose-only correction; no consumer parses this text.
- **Verification:** The rewritten sentence matches the behavior implemented in U1; no other bullet in the file references the old warning.

## Verification Contract

| Gate | Command / check | Proves |
|---|---|---|
| Source round-trip | `chezmoi decrypt` into a mode-600 scratch file under `$XDG_RUNTIME_DIR` (trap-cleaned, never printed to stdout); the decrypted YAML parses and diffs against the deployed `~/src/garden.yaml` as guard + comment lines only | Edit correctness, no manifest drift |
| Command harness | Extract each stanza; run under `sh` with `TREE_PATH`/`TREE_NAME`/`GARDEN_ROOT`: the real non-bare tree (skip leg) and a disposable bare fixture with an `aoe` stub (pre/post parity leg) | AE1, AE2 |
| Deploy | `chezmoi apply --source "$PWD" ~/src/garden.yaml ~/.agents/AGENTS.md ~/.claude/CLAUDE.md ~/.codex/AGENTS.md ~/.config/opencode/AGENTS.md ~/.pi/agent/AGENTS.md` — the `--source` is load-bearing: the default source is the main checkout, not this worktree (targeted live deploy, done because the user asked to fix the live error) | Deployed manifest and instruction files match edited source |
| End-to-end | Preflight: `test ! -e ~/src/github.com/gberaudo/.git` before the run (no residue from the failed bootstrap; verified absent today). Then `garden --chdir ~/src cmd '*' setup-gitdir setup-upstream aoe-session` exits 0; the stray-file test still holds after; `aoe list` has no `gberaudo` session | AE3, R1, R2 |
| Hygiene | No plaintext `garden.yaml` content committed (only the `.age` blob); scratch copy removed | Secrets policy |

## Definition of Done

- The reported error no longer occurs: the wildcard bootstrap exits 0 on this host with `opencode-mcp-figma` cleanly skipped.
- Bare trees behave exactly as before (pointer, upstreams, sessions all idempotent).
- The deployed `~/src/garden.yaml` carries the guards (apply performed and stated plainly).
- `dot_agents/readonly_AGENTS.md` matches implemented behavior.
- No plaintext registry in git; scratch files removed; no leftover experimental edits beyond U1/U2.
- Change lands on `bugfix/garden-cmds-skip-non-bare-trees` (`fix/` is not in the repo's Git Flow prefix set) with a PR whose CI (`render-dotfiles.yml`, `ci.yml`) reaches a terminal green state and whose body carries the redacted semantic diff of the manifest change (guard + comment lines only — the command stanzas contain no registry identifiers).

## Appendix

Root-cause trace (from the deployed manifest): `aoe-session` runs `proj="$(dirname "${TREE_PATH}")"`; for the non-bare tree `TREE_PATH=~/src/github.com/gberaudo/opencode-mcp-figma`, so `proj=~/src/github.com/gberaudo` and the final `aoe add "$proj" -t "$branch" -g "$group" -w "$branch"` receives a non-repository path — the exact text of the reported error. `[master]` in the garden output header is that tree's checked-out branch.
