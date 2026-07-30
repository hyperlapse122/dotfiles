---
title: Drop opencode-mcp-figma from the ~/src Garden Registry - Plan
type: chore
date: 2026-07-30
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Drop opencode-mcp-figma from the ~/src Garden Registry - Plan

## Goal Capsule

- **Objective:** Remove the `opencode-mcp-figma` tree declaration (`https://github.com/gberaudo/opencode-mcp-figma.git`) from the GPG-encrypted `~/src` project registry, leaving all thirteen other trees untouched.
- **Authority:** The root `AGENTS.md` garden and secrets rules, plus the registry manifest's own header procedure, outrank this plan. Where they conflict, follow them and flag the conflict.
- **Execution profile:** One commit against `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Plaintext exists only in per-user scratch, never in the worktree.
- **Stop conditions:** Stop and ask if `chezmoi decrypt` fails (GPG key absent), if `garden ls` rejects the edited manifest, or if the staged round-trip is not byte-identical to the edited plaintext.
- **Tail ownership:** LFG pipeline run — the implementer commits, pushes, opens the PR, and watches CI. Deployment (`chezmoi apply`) is never part of verification: it performs real network clones and mutates aoe state.

---

## Product Contract

### Summary

Delete one `trees:` entry from the chezmoi-managed `~/src` project registry so no host grows or sessions `github.com/gberaudo/opencode-mcp-figma` any more. The registry is GPG ciphertext in a public repo, so the edit is a decrypt-edit-re-encrypt cycle in scratch with a round-trip gate before the source is overwritten. Removal is declaration-only: the existing clone on this host and its aoe session are left in place for `src-audit` to report as unmanaged.

### Problem Frame

`opencode-mcp-figma` was declared as the registry's first non-bare (plain-clone) tree so the upstream Figma MCP OAuth helper could be cloned and kept updatable. That need is gone — `figma-auth` (`packages/figma-auth`, built by `.chezmoiscripts/60-build/`) now owns the Figma MCP OAuth flow for both harnesses, and the upstream repo survives only as a research citation inside historical plan documents. A declared tree that nobody needs still costs every apply: the 90-src provisioner grows it, bootstraps it, and its completeness check can fail an unrelated apply if that clone ever breaks or becomes unreachable.

Nothing outside `docs/plans/` prose references the tree — no script, template, `.chezmoidata/` file, or instruction source — so the removal is a pure data deletion with no follow-on edits.

### Requirements

**Registry**

- R1. The registry no longer declares a tree named `opencode-mcp-figma`.
- R2. The thirteen remaining tree declarations and the `garden:`/`commands:` blocks are byte-identical to their current content.
- R3. The non-bare shape comment that sits above the removed stanza is retained, because `works` follows it and is the same shape.

**Delivery discipline**

- R4. Decrypted plaintext never enters the worktree, `/tmp`, `/var/tmp`, or `/dev/shm`.
- R5. Verification touches neither `~/src` nor the network, and runs no live `chezmoi apply`.

### Scope Boundaries

**Out of scope**

- Deleting the checkout at `~/src/github.com/gberaudo/opencode-mcp-figma` or its aoe session. See KTD1.
- `.chezmoiremove`, `.chezmoiignore`, `dot_local/bin/executable_src-audit`, and the 90-src provisioner. None of them names an individual tree.
- The historical `docs/plans/` documents that cite the upstream repo. They describe the world as it was; rewriting them would falsify the record.
- Anything about `packages/figma-auth` or the `figma` MCP configuration. This change removes a clone declaration, not a capability.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Declaration-only removal; the local clone and its aoe session stay.** The root `AGENTS.md` forbids teardown/revert scripts, aoe owns session and worktree lifecycle ("never hand-remove/unlock worktrees; delete through aoe or ask its owner"), and `src-audit` surfaces an unmanaged tree rather than deleting it. Chosen over pairing the removal with a cleanup step: that would be an unrequested destructive action on a path this change does not own. The residual is reported to the user as a one-time manual reversal, not scripted.
- KTD2. **The non-bare explanatory comment is kept.** It documents the plain-clone shape for the contiguous non-bare block, and `works` is the next entry. Chosen over deleting comment plus stanza together: that would strip the only inline explanation of the shape `works` uses.
- KTD3. **Re-encrypt to a staged file, gate the round-trip, then move.** `chezmoi encrypt > <source>` truncates the destination before encryption runs, so a gpg failure would destroy the canonical ciphertext with no recovery. Encrypt to scratch, decrypt the staged file, `cmp` it against the edited plaintext, and only then `mv`.
- KTD4. **No new `.ci/` test.** `.ci/test-garden-registry-relocation.sh` deliberately never decrypts the registry (CI has no GPG private key) and asserts only that the source is real PGP ciphertext. Registry *data* has no CI coverage by design; its runtime guards are the provisioner's completeness check and `src-audit`. A tree count assertion would need the private key.
- KTD5. **No documentation or instruction edits.** A repo-wide search finds `opencode-mcp-figma` and `gberaudo` only in `docs/plans/` prose. Neither the root `AGENTS.md` nor the shared agent instructions name the tree.

### Assumptions

- The implementer's host has the GPG private key imported (`CC740A29852C0E95`), so `chezmoi decrypt` works. Absence is a stop condition, not something to work around.
- `garden` and a writable `$XDG_RUNTIME_DIR` are available.

---

## Implementation Units

### U1. Remove the tree declaration from the encrypted registry

**Goal:** Delete the three-line `opencode-mcp-figma:` stanza from the registry plaintext and re-encrypt, as one ciphertext change.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** none

**Files:**

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` — the only file changed. No test file; see KTD4.

**Approach:**

Create scratch with `umask 077` and `mktemp -d` beneath `$XDG_RUNTIME_DIR`, installing a cleanup trap on `EXIT HUP INT TERM` before decrypting, so a stop-condition exit cannot leave plaintext behind. Run every `chezmoi` invocation with `--source "$PWD"`: this checkout is a nested worktree and omitting it triggers recursive-data errors.

Decrypt to `$scratch/garden.yaml`. Delete exactly the three lines

```yaml
  opencode-mcp-figma:
    path: github.com/gberaudo/opencode-mcp-figma
    url: https://github.com/gberaudo/opencode-mcp-figma.git
```

leaving the four comment lines above them and the `works:` stanza below them in place (KTD2, KTD3). Encrypt to the staged `$scratch/reenc.asc`, run the round-trip gate against that staged file, and only then `mv` it over the source.

This non-interactive scratch path is the one the root `AGENTS.md` sanctions alongside the `chezmoi edit ~/.config/garden/garden.yaml` wrapper; the wrapper is unusable here because it opens `codium --wait`.

**Patterns to follow:** the decrypt-edit-stage-verify-move cycle documented in the registry header and used by `docs/plans/2026-07-30-001-chore-garden-register-examvueduo-ai-plan.md` (U1).

**Test scenarios:**

- Round-trip fidelity: decrypt the staged ciphertext in scratch and `cmp` it against the edited plaintext; identical, before anything overwrites the source.
- Recipient set unchanged: the staged ciphertext's encrypted-to key id set equals the source's at `HEAD` (a single subkey, `99F28D011988964B`).
- Exact deletion: a `diff` of the pre-edit and post-edit plaintext shows exactly three deleted lines and zero added or modified lines (R1, R2, R3).
- Manifest parses and paths resolve: `garden --config <scratch plaintext> ls --all --no-commands --no-remotes --no-gardens --no-groups -v` exits 0, does not list `opencode-mcp-figma`, and still lists the other thirteen trees.
- Tree count: the manifest declares thirteen trees, exactly one fewer than the fourteen at `HEAD`.
- Provisioner re-trigger: the rendered reconcile script's fingerprint comment for `dot_config/garden/encrypted_readonly_garden.yaml.asc` equals `sha256sum` of the new source and differs from the pre-edit value.
- Cleanup on an aborted run: force the round-trip gate to fail (stage deliberately corrupt ciphertext) and confirm the trap removes scratch and leaves the source byte-identical to `HEAD`.
- No plaintext leak: `git status --porcelain` shows only the ciphertext source plus this plan file, and the scratch directory is gone.

**Verification:** All eight scenarios pass, `git diff --check` is clean, and the scoped diff touches exactly one source file.

---

## Verification Contract

Run from the checkout root. `scratch` is a `mktemp -d` directory beneath `$XDG_RUNTIME_DIR`, created under `umask 077` and removed by a trap on `EXIT HUP INT TERM`.

| Gate | Command | Proves |
|---|---|---|
| Decrypt | `chezmoi --source "$PWD" decrypt dot_config/garden/encrypted_readonly_garden.yaml.asc > "$scratch/garden.yaml"` | GPG key present; plaintext obtained outside the worktree (R4) |
| Exact deletion | `diff "$scratch/garden.yaml.orig" "$scratch/garden.yaml"` | Three lines removed, nothing else touched (R1, R2, R3) |
| Round-trip | `chezmoi --source "$PWD" decrypt "$scratch/reenc.asc" \| cmp - "$scratch/garden.yaml"` | The staged ciphertext preserves the edited plaintext byte-for-byte before it replaces the source |
| Recipients | `gpg --list-packets` on the staged file and on `HEAD`'s source, comparing the encrypted-to key ids | Re-encryption did not change or drop a recipient |
| Parse + count | `garden --config "$scratch/garden.yaml" ls --all --no-commands --no-remotes --no-gardens --no-groups -v` | garden accepts the manifest; the tree is gone and thirteen remain (R1, R5) |
| Fingerprint | render `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` via `chezmoi execute-template` with the documented `op` stub, and compare its fingerprint comment to `sha256sum dot_config/garden/encrypted_readonly_garden.yaml.asc` | The 90-src provisioner will re-run on the next apply |
| Regression | `.ci/test-garden-registry-relocation.sh` | The registry's path, gating, and ciphertext invariants still hold |
| Hygiene | `git diff --check`, `git status --porcelain`, and an injected round-trip failure | No whitespace damage; no stray plaintext; the trap clears scratch and leaves the source untouched on an aborted run |

Prohibited as verification: `chezmoi apply`, `garden grow`, and any command that reaches the network or mutates `~/src` or aoe state. The registry is verified as data, not by provisioning it (R5).

---

## Risks & Dependencies

- **Whole-file ciphertext churn.** gpg is non-deterministic, so the diff is the entire blob and carries no reviewable signal. Review the intent from this plan and the commit message, not the diff.
- **Editing the wrong copy.** `~/.config/garden/garden.yaml` is the 0444 deployed target; editing it is silently discarded on the next apply. The source is `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Truncation on a naive re-encrypt.** Redirecting `chezmoi encrypt` onto the source destroys the canonical ciphertext if gpg fails. KTD3's staged file plus the round-trip gate is the mitigation; it is not optional.
- **Provisioner over-trigger.** Any re-encrypt changes the fingerprint, so the next apply re-runs grow-and-bootstrap across the whole registry even though only a deletion happened. That sweep is idempotent, but its completeness check can fail the apply because of an unrelated pre-existing broken tree. Run `src-audit` first when the host's `~/src` state is uncertain.

---

## Documentation / Operational Notes

The next `chezmoi apply` re-runs the 90-src provisioner because the fingerprint changed. It grows and bootstraps the thirteen remaining trees; the provisioner is additive only, so it neither removes nor relocates the dropped clone.

Two residuals therefore survive on any host that already grew the tree, and both are deliberate (KTD1):

1. The checkout at `~/src/github.com/gberaudo/opencode-mcp-figma` stays on disk. `src-audit` will begin reporting it as unmanaged; it will never delete it.
2. Its aoe session (group `github.com/gberaudo/opencode-mcp-figma`) stays registered.

Removing either is a one-time manual reversal the user performs: `aoe` owns session removal, and the directory removal is a plain `rm -rf` of a path this repository does not manage. Neither belongs in a provisioning script.

---

## Definition of Done

- R1 through R5 hold.
- All eight Verification Contract gates pass.
- One commit touches `dot_config/garden/encrypted_readonly_garden.yaml.asc`; the message is a lowercase Conventional Commit describing the registry removal.
- No plaintext registry copy exists anywhere in the worktree or in scratch.
- No scaffolding survives: no leftover scratch scripts, no commented-out registry entry, no temporary helper files.
- The two surviving residuals above are reported to the user rather than silently left unmentioned.

---

## Sources & Research

- `~/.config/garden/garden.yaml` (deployed target) — current fourteen-tree content, the three-line stanza to delete, the non-bare comment block that must stay, and the header's sanctioned non-interactive edit recipe.
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — the ciphertext fingerprint, the additive-only contract ("trees dropped from the manifest are left in place for `src-audit` to report"), and the grow-completeness gate.
- `.ci/test-garden-registry-relocation.sh` — evidence for KTD4: CI never decrypts the registry and asserts no tree data.
- `.chezmoi.toml.tmpl` — `encryption = "gpg"`, recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`.
- Repo-wide search for `opencode-mcp-figma` / `gberaudo` — hits confined to `docs/plans/`, the evidence behind KTD5.
- `docs/plans/2026-07-30-001-chore-garden-register-examvueduo-ai-plan.md` — the inverse operation; its U1 approach is the pattern followed here.
