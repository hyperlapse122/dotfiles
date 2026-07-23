---
title: Add hyperlapse/works as a Non-Bare Garden Tree - Plan
type: chore
date: 2026-07-23
topic: garden-add-works-non-bare
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Add hyperlapse/works as a Non-Bare Garden Tree - Plan

## Goal Capsule

- **Objective:** Register `https://git.jpi.app/hyperlapse/works.git` in the `~/src` garden as a **non-bare** (plain-clone) tree — a repo that is cloned and updatable but never developed through aoe worktrees.
- **Authority:** The user's request governs scope (explicit "non-bare"); the non-bare policy documented inside `src/encrypted_readonly_garden.yaml.asc` and `dot_agents/readonly_AGENTS.md` governs the entry shape; repo `AGENTS.md` governs the encrypted-source edit flow (decrypt to scratch → edit → re-encrypt, never commit plaintext).
- **Execution profile:** Lightweight — a 3-line YAML insertion inside one GPG-encrypted manifest.
- **Stop conditions:** Stop rather than broadening scope if the entry appears to need a `bare: true`/refspec block, a `worktree:` tree, a group-normalization decision with no clear precedent, or any edit beyond the single `trees:` insertion.
- **Tail ownership:** The LFG pipeline owns commit, push, PR creation, and CI monitoring.

## Product Contract

### Summary

Add one `trees:` entry named `works` to the decrypted `~/src/garden.yaml`, mirroring the registry's only existing non-bare tree (`opencode-mcp-figma`), and re-encrypt the source `src/encrypted_readonly_garden.yaml.asc`.

### Problem Frame

The garden registry (`src/encrypted_readonly_garden.yaml.asc`, GPG-encrypted, deployed read-only to `~/src/garden.yaml`) is the declared source of truth for the `~/src/<host>/[<group>/]<project>` layout. It currently declares 9 trees: 8 **bare** (aoe-managed, `path` ends in `/.bare` with `bare: true` + an explicit fetch refspec) and 1 **non-bare** (`opencode-mcp-figma`: plain clone, no `bare`, no refspec, `path` has no `/.bare`). The user wants `git.jpi.app/hyperlapse/works` added as a **non-bare** tree so `garden grow` performs a normal `git clone` and the three bootstrap commands self-skip it (they skip any path not ending in `/.bare`).

### Requirements

- **R1.** A new `trees.works` entry exists with `path: git.jpi.app/hyperlapse/works` and `url: https://git.jpi.app/hyperlapse/works.git`.
- **R2.** The entry is **non-bare**: no `bare:` key, no `gitconfig`/refspec block, and the `path` does **not** end in `/.bare` and carries no `worktree:` tree.
- **R3.** The change lives only in the re-encrypted `src/encrypted_readonly_garden.yaml.asc`; no plaintext copy is committed and no other tree/command stanza is altered.
- **R4.** `chezmoi diff` for `~/src/garden.yaml` shows exactly the 3 added plaintext lines; a decrypt round-trip of the new source equals the intended edited plaintext.

### Scope Boundaries

**In scope:** One `trees:` insertion in `src/encrypted_readonly_garden.yaml.asc`; decrypt/edit/re-encrypt via the AGENTS.md non-interactive flow; local verification (`chezmoi diff`, decrypt round-trip).

**Out of scope:**
- Running `garden grow works` / cloning the repo on this host (grow-on-demand; the manifest is the union across hosts — a tree not grown here is not an error).
- Correcting the manifest's stale header comments that still say "AGE-ENCRYPTED" / reference `.yaml.age` (pre-existing doc drift, unrelated to this entry).
- Any `bare`/aoe/worktree treatment, `src-audit` changes, or edits to other trees.
- Deciding a non-default path group: the URL namespace is `hyperlapse`, so the layout group is `hyperlapse` (mirrors the non-bare `opencode-mcp-figma` shape `host/namespace/project`).

## The Change

Insert as the **last `trees:` entry** (immediately after `opencode-mcp-figma`, before `commands:`), grouping the two non-bare trees together and yielding a clean contiguous insertion:

```yaml
  works:
    path: git.jpi.app/hyperlapse/works
    url: https://git.jpi.app/hyperlapse/works.git
```

Decisions:
- **Tree name `works`** — the project leaf; no collision with existing tree names.
- **`path: git.jpi.app/hyperlapse/works`** — `<host>/<group>/<project>`, group taken from the URL namespace `hyperlapse`, no `/.bare` suffix (non-bare).
- **`url`** — verbatim from the user's request.
- No `bare:`, no `gitconfig.remote.origin.fetch` — those are bare-tree only.

## Implementation Steps

Reference file: `src/encrypted_readonly_garden.yaml.asc`. Use `git rev-parse --show-toplevel` for the source root; scratch under `${XDG_RUNTIME_DIR:-$HOME/.cache}` (never `/tmp`), `umask 077`, cleaned up after.

1. `SRC="$(chezmoi source-path)"`; decrypt the source: `chezmoi decrypt "$SRC/src/encrypted_readonly_garden.yaml.asc" > "$SCRATCH/garden.yaml"`.
2. Insert the `works` block after the `opencode-mcp-figma` stanza (the last tree before the `commands:` line), preserving 2-space YAML indentation.
3. Re-encrypt back to the source: `chezmoi encrypt "$SCRATCH/garden.yaml" > "$SRC/src/encrypted_readonly_garden.yaml.asc"`.
4. `rm -f "$SCRATCH/garden.yaml"` (shred the plaintext scratch).

## Verification

- **Round-trip:** `chezmoi decrypt` the new source and confirm it equals the intended edited plaintext (diff against the pre-edit decrypt shows only the 3 added lines).
- **Render:** `chezmoi diff ~/src/garden.yaml` shows only the 3 added plaintext lines (the read-only deployed copy gains exactly the new stanza).
- **No leak:** `git diff --stat` / `git diff` touches only `src/encrypted_readonly_garden.yaml.asc` (ciphertext) and the plan doc; `git status` shows no plaintext `garden.yaml` in the tree; `git diff --check` clean.
- **Shape:** the new stanza has no `bare:`/refspec and a `path` without `/.bare`.

## Risks

- **Plaintext leak** — mitigated: scratch lives only in `$XDG_RUNTIME_DIR`, is removed, and `~/src/garden.yaml`/`.chezmoiignore` keep the deployed copy out of git; verify `git status` before commit.
- **Wrong encryption format** — mitigated: reuse `chezmoi encrypt` (configured `encryption = "gpg"`, recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`); confirm the round-trip decrypt succeeds before commit.
- **Group-normalization ambiguity** — low: no `git.jpi.app/hyperlapse` sibling exists; `hyperlapse` (URL namespace) is the natural group and mirrors the non-bare precedent.
