---
title: Drop nix-config from the ~/src Garden Registry - Plan
type: chore
date: 2026-08-31
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Drop nix-config from the ~/src Garden Registry - Plan

## Goal Capsule

- **Objective:** Remove the `nix-config` tree declaration (`https://github.com/hyperlapse122/nix-config.git`) from the GPG-encrypted `~/src` project registry (`dot_config/garden/encrypted_readonly_garden.yaml.asc`), leaving all twenty other trees untouched.
- **Authority:** The root `AGENTS.md` garden and secrets rules, plus the registry manifest's own header procedure, outrank this plan. Where they conflict, follow them and flag the conflict.
- **Execution profile:** One commit against `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Plaintext exists only in per-user scratch under `$XDG_RUNTIME_DIR`, never in the worktree.
- **Stop conditions:** Stop and ask if `chezmoi decrypt` fails (GPG key absent), if `garden ls` rejects the edited manifest, or if the staged round-trip is not byte-identical to the edited plaintext.
- **Tail ownership:** LFG pipeline run — the implementer commits, pushes, opens the PR, and watches CI. Deployment (`chezmoi apply`) is never part of verification: it performs real network operations and mutates aoe state.

---

## Product Contract

### Summary

Delete the `nix-config` `trees:` entry from the chezmoi-managed `~/src` project registry so garden stops managing the repository under `~/src`. The registry is GPG ciphertext in the dotfiles repo, so the edit is a decrypt-edit-re-encrypt cycle in scratch with a round-trip gate before the source is overwritten. Removal is declaration-only: the existing clone on this host and its aoe session are left in place for `src-audit` to report as unmanaged.

### Problem Frame

Issue #288 requests un-managing `nix-config` (`github.com/hyperlapse122/nix-config`) from the garden manifest. `nix-config` is declared under `trees:` in `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Removing the declaration prevents garden from growing and managing it on future applies.

Nothing outside `docs/plans/` prose references the tree in dotfiles, so the removal is a pure data deletion with no follow-on edits.

### Requirements

**Registry**

- R1. The registry no longer declares a tree named `nix-config`.
- R2. The twenty remaining tree declarations and the `garden:`/`commands:` blocks are byte-identical to their current content.
- R3. The surrounding structure in `dot_config/garden/encrypted_readonly_garden.yaml.asc` is preserved without unintended modifications.

**Delivery discipline**

- R4. Decrypted plaintext never enters the worktree, `/tmp`, `/var/tmp`, or `/dev/shm`.
- R5. Verification touches neither `~/src` nor the network, and runs no live `chezmoi apply`.

### Scope Boundaries

**Out of scope**

- Deleting the checkout at `~/src/github.com/hyperlapse122/nix-config` or its aoe session (see KTD1).
- Modifying `.chezmoiremove`, `.chezmoiignore`, `dot_local/bin/executable_src-audit`, or the 90-src provisioner.
- Modifying historical `docs/plans/` documents that cite `nix-config`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Declaration-only removal; the local clone and its aoe session stay.** The root `AGENTS.md` forbids teardown/revert scripts, aoe owns session and worktree lifecycle ("never hand-remove/unlock worktrees; delete through aoe or ask its owner"), and `src-audit` surfaces an unmanaged tree rather than deleting it. The residual is reported to the user as a one-time manual action.
- KTD2. **Re-encrypt to a staged file, gate the round-trip, then move.** `chezmoi encrypt > <source>` would truncate the destination before encryption runs. Encrypt to scratch, decrypt the staged file, `cmp` it against the edited plaintext, verify key IDs, and only then `mv`.
- KTD3. **No new `.ci/` test.** `.ci/test-garden-registry-relocation.sh` deliberately never decrypts the registry (CI has no GPG private key) and asserts only that the source is real PGP ciphertext.
- KTD4. **Rename branch before pushing.** Current branch `celts` is an aoe placeholder name; before push, rename in place to `chore/garden-drop-nix-config` per `AGENTS.md`.

### Assumptions

- The host has the GPG private key imported, so `chezmoi decrypt` works.
- `garden` and a writable `$XDG_RUNTIME_DIR` are available.

---

## Implementation Units

### U1. Remove the nix-config tree declaration from the encrypted registry

**Goal:** Delete the three-line `nix-config:` stanza from the registry plaintext and re-encrypt, as one ciphertext change.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** none

**Files:**

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` — the only file changed.

**Approach:**

Create scratch with `umask 077` and `mktemp -d` beneath `$XDG_RUNTIME_DIR`, installing a cleanup trap on `EXIT HUP INT TERM` before decrypting. Run every `chezmoi` invocation with `--source "$PWD"`.

Decrypt to `$scratch/garden.yaml`. Delete exactly the three lines:

```yaml
  nix-config:
    path: github.com/hyperlapse122/nix-config
    url: https://github.com/hyperlapse122/nix-config.git
```

Encrypt to the staged `$scratch/reenc.asc`, run the round-trip gate against that staged file (cmp decrypted content, verify recipient key IDs match), and only then `mv` it over `dot_config/garden/encrypted_readonly_garden.yaml.asc`.

**Test scenarios:**

- Round-trip fidelity: decrypt the staged ciphertext in scratch and `cmp` it against the edited plaintext; identical, before anything overwrites the source.
- Recipient set unchanged: the staged ciphertext's encrypted-to key id set equals the source's at `HEAD` (subkey `99F28D011988964B`).
- Exact deletion: a `diff` of the pre-edit and post-edit plaintext shows exactly three deleted lines and zero added or modified lines (R1, R2, R3).
- Manifest parses and paths resolve: `garden --config <scratch plaintext> ls --all --no-commands --no-remotes --no-gardens --no-groups -v` exits 0, does not list `nix-config`, and still lists the other twenty trees.
- Tree count: the manifest declares twenty trees, exactly one fewer than the twenty-one at `HEAD`.
- Provisioner re-trigger: the rendered reconcile script's fingerprint comment for `dot_config/garden/encrypted_readonly_garden.yaml.asc` equals `sha256sum` of the new source and differs from the pre-edit value.
- No plaintext leak: `git status --porcelain` shows only the ciphertext source plus plan files, and the scratch directory is gone.

**Verification:** All scenarios pass, `git diff --check` is clean, and the scoped diff touches exactly one source file.

---

## Verification Contract

Run from the checkout root. `scratch` is a `mktemp -d` directory beneath `$XDG_RUNTIME_DIR`, created under `umask 077` and removed by a trap on `EXIT HUP INT TERM`.

| Gate | Command | Proves |
|---|---|---|
| Decrypt | `chezmoi --source "$PWD" decrypt dot_config/garden/encrypted_readonly_garden.yaml.asc > "$scratch/garden.yaml"` | GPG key present; plaintext obtained outside the worktree (R4) |
| Exact deletion | `diff "$scratch/garden.yaml.orig" "$scratch/garden.yaml"` | Three lines removed, nothing else touched (R1, R2, R3) |
| Round-trip | `chezmoi --source "$PWD" decrypt "$scratch/reenc.asc" \| cmp - "$scratch/garden.yaml"` | The staged ciphertext preserves the edited plaintext byte-for-byte before it replaces the source |
| Recipients | `gpg --list-packets` on the staged file and on `HEAD`'s source, comparing the encrypted-to key ids | Re-encryption did not change or drop a recipient |
| Parse + count | `garden --config "$scratch/garden.yaml" ls --all --no-commands --no-remotes --no-gardens --no-groups -v` | garden accepts the manifest; the tree is gone and twenty remain (R1, R5) |
| Fingerprint | render `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` via `chezmoi execute-template` with the documented `op` stub, and compare its fingerprint comment to `sha256sum dot_config/garden/encrypted_readonly_garden.yaml.asc` | The 90-src provisioner will re-run on the next apply |
| Regression | `.ci/test-garden-registry-relocation.sh` | The registry's path, gating, and ciphertext invariants still hold |
| Hygiene | `git diff --check`, `git status --porcelain` | No whitespace damage; no stray plaintext |

---

## Risks & Dependencies

- **Whole-file ciphertext churn.** gpg is non-deterministic, so the diff is the entire blob and carries no reviewable signal. Review intent from plan and commit message.
- **Editing the wrong copy.** `~/.config/garden/garden.yaml` is the 0444 deployed target; source is `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Truncation on naive re-encrypt.** Staged file in scratch plus the round-trip gate prevents corrupting canonical ciphertext.

---

## Documentation / Operational Notes

The next `chezmoi apply` re-runs the 90-src provisioner because the fingerprint changed. It grows and bootstraps the twenty remaining trees; the provisioner is additive only, so it neither removes nor relocates the dropped clone.

Two residuals survive on any host that already grew the tree:
1. The checkout at `~/src/github.com/hyperlapse122/nix-config` stays on disk. `src-audit` will begin reporting it as unmanaged; it will never delete it.
2. Its aoe session (group `github.com/hyperlapse122/nix-config`) stays registered.

Removing either is a one-time manual action by the user if desired.

---

## Definition of Done

- R1 through R5 hold.
- All Verification Contract gates pass.
- One commit touches `dot_config/garden/encrypted_readonly_garden.yaml.asc`; the message is `chore: drop nix-config from garden manifest`.
- No plaintext registry copy exists anywhere in the worktree or in scratch.
- The two surviving residuals are reported in the PR.

---

## Sources & Research

- `~/.config/garden/garden.yaml` (deployed target) — current twenty-one-tree content and the three-line stanza to delete.
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — ciphertext fingerprint and additive-only contract.
- `docs/plans/2026-07-30-004-chore-garden-drop-opencode-mcp-figma-plan.md` — prior plan pattern for garden tree removal.
