---
title: Register vetbot-ai in the ~/src Garden Registry - Plan
type: chore
date: 2026-07-30
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Register vetbot-ai in the ~/src Garden Registry - Plan

## Goal Capsule

- **Objective:** Declare `https://git.jpi.app/products/vetbot-ai.git` as a bare tree in the encrypted `~/src` project registry, and de-stale the `signet` comment that claims to describe the only repo of its shape.
- **Authority:** The root `AGENTS.md` garden rules and the manifest's own in-file conventions outrank this plan. Where they conflict, follow them and flag the conflict.
- **Execution profile:** One commit against `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Plaintext exists only in per-user scratch, never in the worktree.
- **Stop conditions:** Stop and ask if decryption fails (GPG key absent), if `garden ls` rejects the edited manifest, or if the plaintext round-trip is not byte-identical.
- **Tail ownership:** The implementer commits. Deployment is the user's call — `chezmoi apply` performs a real private clone and creates an aoe session, so it is never part of verification.

---

## Product Contract

### Summary

Add one tree to the chezmoi-managed `~/src` project registry so `garden grow` clones `products/vetbot-ai` and the 90-src provisioner bootstraps it like every other JPI product repo. The registry is GPG ciphertext in a public repo, so the edit is a decrypt-edit-re-encrypt cycle in scratch.

### Problem Frame

`products/vetbot-ai` is active first-party product code (private, default branch `main`, non-empty) but is absent from the registry, so no host grows or sessions it. It sits directly under the `products` umbrella group with no product subgroup — the same remote shape as the already-declared `signet` — so its on-disk normalization is settled by precedent rather than open.

The `signet` entry carries a comment asserting it is "the only git.jpi.app product repo that keeps the umbrella segment in the path". Adding a second repo of that shape falsifies that sentence in the same edit, so it must be corrected here or the manifest ships a false claim.

### Requirements

- R1. The registry declares tree `vetbot-ai` with `url: https://git.jpi.app/products/vetbot-ai.git`.
- R2. Its path is `git.jpi.app/products/vetbot-ai/.bare` — the `products` umbrella segment is retained, because it is this repo's immediate group on disk.
- R3. The entry carries `bare: true` and `remote.origin.fetch: "+refs/heads/*:refs/remotes/origin/*"`, because `git clone --bare` alone tracks no remote branches.
- R4. The `signet` comment no longer claims to describe the only repo that keeps the umbrella segment, and covers both entries.
- R5. Decrypted plaintext never enters the worktree, `/tmp`, `/var/tmp`, or `/dev/shm`.
- R6. Verification touches neither `~/src` nor the network, and runs no live `chezmoi apply`.

### Scope Boundaries

**Out of scope**

- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — its fingerprint already covers the registry source; no script change is needed.
- `.ci/test-garden-registry-relocation.sh` — it verifies the ciphertext's packet structure, never its content, so registry data changes need no test edit (KTD4).
- `.chezmoiignore`, `dot_local/bin/executable_src-audit`, and aoe session lifecycle. aoe owns worktrees; the registry only declares trees.
- Other repositories' own tree entries (`path`, `url`, `bare`, `gitconfig`) in the `products` group. The user scoped this change to one repository. The shared header comment above `signet` is the one exception, corrected per R4.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The path keeps the `products` segment.** `signet` maps `products/signet` to `git.jpi.app/products/signet/.bare` because `products` is its immediate group on disk. `vetbot-ai` has the identical remote shape, so it follows that precedent rather than the `examvue-duo`/`365flow` pattern, where the umbrella segment is dropped in favor of the product subgroup.
- KTD2. **Bare tree, not a plain clone.** Bare is the aoe worktree shape for first-party code developed through aoe. Plain clones are reserved for third-party or read-only trees never developed that way (`works`).
- KTD3. **The entry sits next to `signet`, under one shared comment.** Grouping the two umbrella-segment entries lets a single corrected comment explain the shape for both, and preserves the file's group clustering. `pacs-frontend`'s trailing position is drift from an earlier append, not a convention to copy.
- KTD4. **No new `.ci/` test.** The existing garden CI job renders templates and parses the ciphertext's packet structure; it deliberately never decrypts (CI has no private key). Registry data correctness is guarded at runtime by the provisioner's completeness check and `src-audit`.
- KTD5. **The HTTPS URL is used as supplied.** Matches every other `git.jpi.app` entry; the glab credential helper configured in `10-auth` injects auth, and the provisioner passes no tokens.

### Assumptions

- The implementer's host has the GPG private key imported, so decryption works. Absence is a stop condition, not something to work around.
- `garden` 2.6.1 and a writable `$XDG_RUNTIME_DIR` are available.

---

## Implementation Units

### U1. Register the vetbot-ai bare tree

**Goal:** Add the `vetbot-ai` bare tree beside `signet` and rewrite their shared comment so it describes both, as one ciphertext change.

**Requirements:** R1, R2, R3, R4, R5, R6

**Dependencies:** none

**Files:**

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` — the only file changed. No test file; see KTD4.

**Approach:**

Create scratch with `umask 077` beneath `$XDG_RUNTIME_DIR` and install a cleanup trap on `EXIT HUP INT TERM` before decrypting, so a stop-condition exit cannot leave plaintext behind. Decrypt to a scratch plaintext, edit it, encrypt to a **staged** file in scratch, verify the round-trip against that staged file, and only then move it over the source. Never redirect encryption straight onto the source: the shell truncates the destination before encryption runs, so a failure would destroy the canonical ciphertext before any gate could catch it.

Run every `chezmoi` invocation with `--source "$PWD"`; this checkout is a nested worktree and omitting it triggers recursive-data errors.

Insert the tree immediately after `signet`, mirroring that entry's field order (`path`, `url`, `bare`, `gitconfig`) and its quoted refspec form:

- name `vetbot-ai`
- `path: git.jpi.app/products/vetbot-ai/.bare`
- `url: https://git.jpi.app/products/vetbot-ai.git`
- `bare: true`
- `gitconfig.remote.origin.fetch: "+refs/heads/*:refs/remotes/origin/*"`

Rewrite the comment above `signet` so it explains the shape rather than counting instances: repos sitting directly under `products` with no product subgroup keep the umbrella segment, because `products` is then their immediate group on disk. Leave the rest of the header alone.

**Patterns to follow:** the `signet` entry (same remote shape, same normalization) for the tree; the header's existing comment voice and line width for the correction.

**Test scenarios:**

- Round-trip fidelity: decrypt the staged ciphertext in scratch and `cmp` it against the edited plaintext; the two are byte-identical before anything overwrites the source.
- Recipient preserved: the staged ciphertext's `pubkey enc packet` keyid equals `99F28D011988964B`, the keyid the committed source already carries, so no host loses the ability to decrypt.
- Manifest parses and paths resolve: a read-only `garden ls --all --no-commands --no-remotes --no-gardens --no-groups -v`, pointed at the edited scratch plaintext with `--config` and at a scratch directory with `--root`, exits 0 and lists `vetbot-ai` at `<scratch-root>/git.jpi.app/products/vetbot-ai/.bare`, with the pre-existing thirteen trees unchanged. Both flags are load-bearing: without `--config`, garden falls back to XDG discovery and silently parses the deployed registry instead of the edit, so the gate passes while proving nothing; without `--root`, path resolution reaches into the real `~/src`.
- Entry fields present: the parsed manifest reports the new tree as bare with `remote.origin.fetch` exactly `+refs/heads/*:refs/remotes/origin/*` (R3). A refspec typo resolves the same path, so the path check above cannot stand in for this one.
- Tree count: the manifest declares fourteen trees, exactly one more than the thirteen at `HEAD`.
- Provisioner re-trigger: the rendered reconcile script's fingerprint comment for the registry differs from `f399aaf8e66b54124d105c024d40fee13d7f9f8abc72401be2bebdf72a33749c` and equals `sha256sum` of the new source.
- Comment accuracy: the manifest contains no claim that one repo is the only one keeping the umbrella segment.
- CI-gate parity: `gpg --list-packets` on the new source still reports both a `pubkey enc packet` and an `encrypted data packet`, the two assertions the garden CI job makes.
- No plaintext leak: `git status --porcelain` shows only the ciphertext source plus this plan, and the scratch directory is gone.
- Aborted run leaves the source intact: force the round-trip comparison to fail by staging deliberately corrupt ciphertext, then confirm the run aborts before the move, the trap clears scratch, and `dot_config/garden/encrypted_readonly_garden.yaml.asc` is byte-identical to `HEAD`.

**Verification:** All ten scenarios pass, `git diff --check` is clean, and the scoped diff touches exactly one source file.

---

## Verification Contract

Run from the checkout root. `scratch` is a directory beneath `$XDG_RUNTIME_DIR`, created under `umask 077` and removed by a trap on `EXIT HUP INT TERM`.

| Gate | Proves |
|---|---|
| Decrypt | GPG key present; plaintext obtained outside the worktree (R5) |
| Round-trip | The staged ciphertext preserves plaintext byte-for-byte before it replaces the source |
| Recipient + packets | The new ciphertext keeps keyid `99F28D011988964B` and satisfies the garden CI job's packet assertions |
| Parse + paths | `garden`, pointed at the scratch plaintext and a scratch root, accepts the manifest and resolves the new tree path (R1, R2) |
| Entry fields | The new tree is bare and carries the exact fetch refspec, so a typo cannot pass as a resolved path (R3) |
| Fingerprint | The 90-src provisioner will re-run on the next apply |
| Hygiene | `git diff --check` and `git status --porcelain` show no whitespace damage and no stray plaintext |
| Abort safety | A failed round-trip stops before the move, clears scratch, and leaves the committed ciphertext byte-identical to `HEAD` |

Prohibited as verification: `chezmoi apply`, `garden grow`, any write against `~/src`, and any command that clones from `git.jpi.app`. The registry is verified as data, not by provisioning it (R6).

---

## Risks & Dependencies

- **Whole-file ciphertext churn.** gpg is non-deterministic, so the diff is the entire blob and carries no reviewable signal. Review the intent from this plan and the commit message, not the diff.
- **Editing the wrong copy.** `~/.config/garden/garden.yaml` is the 0444 deployed target; editing it is silently discarded on the next apply. The source is `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Private repository.** The clone at apply time depends on the glab credential helper from `10-auth`. The provisioner sets `GIT_TERMINAL_PROMPT=0`, so a missing credential fails the apply fast instead of hanging on a prompt.
- **Recipient drift.** Encrypting with a different recipient than the committed source would silently lock every other host out of the registry, and CI would stay green because it never decrypts. Hence the explicit keyid gate.

---

## Documentation / Operational Notes

The next `chezmoi apply` re-runs the 90-src provisioner because the fingerprint changed. It clones the repository into `~/src/git.jpi.app/products/vetbot-ai/.bare`, writes the `.git` pointer, fetches and sets upstreams, and asks aoe to create a locked `main` worktree with a `zsh`-tool session in group `git.jpi.app/products/vetbot-ai`. It also re-runs grow and bootstrap across all other declared trees; every step is idempotent.

That whole-registry sweep is a precondition, not a no-op. The provisioner's completeness check fails the apply and names any declared tree that is missing, broken, or half-cloned, so an unrelated pre-existing tree can fail this apply even when the registry edit itself is sound. Run `src-audit` first when the host's `~/src` state is uncertain.

The apply is deliberately not part of verification. It performs a real network clone and mutates aoe state, and repository policy forbids exercising a live `$HOME` apply as a check. Deployment is a separate, user-initiated step.

No `~/.agents` or root `AGENTS.md` change is needed. The garden rules there already describe this workflow; this change only adds data.

---

## Definition of Done

- R1 through R6 hold.
- All seven Verification Contract gates pass.
- One commit touches `dot_config/garden/encrypted_readonly_garden.yaml.asc`; the message is a lowercase Conventional Commit describing the registry addition.
- No plaintext registry copy exists anywhere in the worktree or in scratch.
- No scaffolding survives: no leftover scratch scripts, no commented-out registry entries, no temporary helper files.

---

## Sources & Research

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` (decrypted in scratch) — tree schema, the bare/non-bare/root-external shapes, the `signet` umbrella-segment precedent and its stale "only" claim, and the `setup-gitdir` / `setup-upstream` / `aoe-session` command bodies that consume each entry.
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — fingerprint over the encrypted source, the grow-completeness gate, and `GIT_TERMINAL_PROMPT=0`.
- `.ci/test-garden-registry-relocation.sh` and `.github/workflows/ci.yml` — the CI job never decrypts; it asserts armor plus `pubkey enc packet` and `encrypted data packet`. Evidence for KTD4.
- `.chezmoi.toml.tmpl` — `encryption = "gpg"`, recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`; the committed ciphertext's pubkey-enc keyid is `99F28D011988964B`.
- GitLab API `projects/products%2Fvetbot-ai` on `git.jpi.app` — confirmed the leaf is `vetbot-ai`, the default branch is `main`, and the repository is non-empty and private.
- `docs/plans/2026-07-30-001-chore-garden-register-examvueduo-ai-plan.md` — the prior registration plan whose decrypt-edit-re-encrypt workflow and verification shape this plan follows. Not its path-shape decision: KTD1 follows the `signet` precedent instead.
