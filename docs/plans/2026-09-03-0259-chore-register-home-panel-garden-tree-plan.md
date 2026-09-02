---
title: Register home-panel in the ~/src Garden Registry - Plan
type: chore
date: 2026-09-03
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Register home-panel in the ~/src Garden Registry - Plan

## Goal Capsule

- **Objective:** On every host that applies these dotfiles, `home-panel` is already checked out at `~/src/github.com/hyperlapse122/home-panel` with an aoe session attached, so the user starts work on it without cloning it by hand per host.
- **Means:** Declare it as one `templates: shallow` tree in the encrypted `~/src` project registry (KTD1).
- **Authority:** The root `AGENTS.md` garden rules and the manifest's own in-file conventions outrank this plan. Where they conflict, follow them and flag the conflict.
- **Execution profile:** One commit against `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Plaintext exists only in per-user scratch, never in the worktree.
- **Stop conditions:** Stop and ask if the scratch root cannot be created writable and `0700`, if decryption fails (GPG private key absent), if `garden ls` rejects the edited manifest, if the plaintext round-trip is not byte-identical, or if the ciphertext carries any recipient other than the one the committed source already has.
- **Tail ownership:** The implementer commits. Deployment is the user's call — `chezmoi apply` performs a real network clone and creates an aoe session, so it is never part of verification.

---

## Product Contract

### Summary

Add one tree to the chezmoi-managed `~/src` project registry so `garden grow` clones `hyperlapse122/home-panel` and the 90-src provisioner bootstraps it like every other declared repo. The registry is GPG ciphertext in a public repo, so the edit is a decrypt-edit-re-encrypt cycle in scratch.

### Problem Frame

`hyperlapse122/home-panel` is absent from the registry, so no host grows or sessions it. Its remote shape is the same as the already-declared `dotfiles` tree: a `github.com` repo under the user's own top-level namespace, with no umbrella group to normalize away. The on-disk layout is therefore settled by precedent, not open.

The registry is the only copy of itself — the deployed `~/.config/garden/garden.yaml` is a 0444 render, and CI never decrypts the source. A bad re-encrypt is unrecoverable, which is why the edit is staged and round-trip-verified before it replaces the committed ciphertext.

### Requirements

**Registry entry**

- R1. The registry declares tree `home-panel` with `url: https://github.com/hyperlapse122/home-panel.git`.
- R2. Its path is `github.com/hyperlapse122/home-panel` — host, group, and project leaf mirrored verbatim.
- R3. The entry carries `templates: shallow`, the same field every current tree uses for a plain shallow checkout.
- R4. The entry sits at the end of `trees:`, after `dotfiles`, in the file's existing field order (`templates`, `path`, `url`) and two-space indentation.
- R5. No other tree entry, template, command, or comment in the manifest changes.

**Ciphertext safety**

- R6. The re-encrypted source carries exactly one `pubkey enc packet`, with keyid `99F28D011988964B` — the same recipient set the committed source has, so no host loses the ability to decrypt and no extra recipient is added.
- R7. Decrypted plaintext never enters the worktree, `/tmp`, `/var/tmp`, or `/dev/shm`.
- R8. A failed round-trip leaves the committed ciphertext byte-identical to `HEAD`.

**Verification boundary**

- R9. Verification runs no `chezmoi apply`, writes nothing under `~/src`, and clones nothing from `github.com`.

### Scope Boundaries

**Out of scope**

- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — its fingerprint already hashes the registry source, so the re-run trigger is automatic and no script edit is needed.
- `.ci/test-garden-shallow-pull.sh` and `.ci/test-ci-wiring.sh` — the shallow-pull test already decrypts and parses the real registry, and is deliberately unwired from CI (KTD6).
- `.chezmoiignore`, `dot_local/share/chezmoi-command-sources/executable_src-audit`, and aoe session lifecycle. aoe owns worktrees; the registry only declares trees.
- Other trees' entries, and the manifest's header comments. The user scoped this change to one repository.
- The deployed `~/.config/garden/garden.yaml`. It is a render target, not a source.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Plain shallow checkout, not a bare tree.** Every one of the 21 current trees carries `templates: shallow` and a working-checkout path; the `.bare` + `bare: true` + explicit fetch-refspec shape is retired from this manifest. A new entry that revived it would be the only tree `src-audit` sees in that shape. Governs R3.
- KTD2. **The path mirrors the remote namespace verbatim.** `github.com/hyperlapse122/home-panel` follows `dotfiles`, the sibling under the same host and group. The umbrella-segment rewrites documented in the manifest's comments are `git.jpi.app`-specific (`products` vs. a product subgroup) and do not apply to `github.com`. Governs R2.
- KTD3. **Tree name `home-panel` — the project leaf.** It collides with none of the 21 existing names, so the `<group>-<project>` disambiguation form the manifest reserves for collisions is not needed.
- KTD4. **Append after `dotfiles`, at the end of `trees:`.** The file is append-ordered, not sorted, and its `github.com` entries already cluster at the tail. Appending keeps the diff minimal and the host clustering intact. Governs R4.
- KTD5. **The HTTPS URL is used exactly as supplied.** It matches every other entry's form. The repository is public, so the apply-time clone needs no credential, and the `10-auth` gh credential helper covers it either way.
- KTD6. **No new or edited test.** `.ci/test-garden-shallow-pull.sh` already decrypts the real registry, runs `garden ls -v` over it, and asserts the `templates` / `shallow` / `unshallow` keys survive. `.ci/test-ci-wiring.sh` records it as intentionally unwired, because no runner provisions `garden` or the private key. It is therefore a local gate, not a CI gate, and needs no change to cover a data-only addition.
- KTD7. **Stage the re-encrypt, then move it over the source.** A bare `>` redirect onto the source truncates the file before encryption runs, so a failure would destroy the only copy of the registry before any gate could catch it. Governs R8.

### Assumptions

- The implementer's host has the GPG private key imported. Absence is a stop condition, not something to work around.
- `garden` 2.7.0 and `chezmoi` v2.72.1 are available.
- The shallow default applies to this tree like every other. The user asked for a plain registration and named no history requirement; `garden cmd home-panel unshallow` retrieves full history on demand later.
- Registration is the deliverable. Deploying it (`chezmoi apply`) is a separate, user-initiated step.

---

## Implementation Units

### U1. Register the home-panel tree

**Goal:** Add the `home-panel` tree to the encrypted registry as one ciphertext change, with no other manifest content touched.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9

**Dependencies:** none

**Files:**

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` — the only file changed. No test file; see KTD6.

**Approach:**

Create scratch with `mktemp -d` beneath `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch` under `umask 077`, and install a cleanup trap on `EXIT HUP INT TERM` before decrypting, so a stop-condition exit cannot leave plaintext behind. The fallback is the pattern this repo's own scratch users already take (`.ci/test-garden-shallow-pull.sh:5`); it keeps an unset `XDG_RUNTIME_DIR` — a cron unit, a systemd service, a non-login shell — from routing plaintext to `/tmp` and breaking R7.

Decrypt to a scratch plaintext, copy it to `<scratch>/head.yaml` before editing so the scoped diff needs no second decrypt, edit the working copy, encrypt to a **staged** file in scratch, verify the round-trip against that staged file, and only then move it over the source (KTD7). Re-verify the installed source after the move: the move crosses filesystems, so it is a copy-and-unlink rather than an atomic rename.

Run every `chezmoi` invocation with `--source "$PWD"`. This checkout is a worktree, and omitting the flag triggers recursive-data errors.

Append immediately after the `dotfiles` entry, before the `commands:` key, mirroring that entry's field order and indentation:

- name `home-panel`
- `templates: shallow`
- `path: github.com/hyperlapse122/home-panel`
- `url: https://github.com/hyperlapse122/home-panel.git`

**Patterns to follow:** the `dotfiles` entry — same host, same group, same tree shape.

**Test scenarios:**

- Round-trip fidelity: decrypt the staged ciphertext in scratch and `cmp` it against the edited plaintext; the two are byte-identical before anything overwrites the source.
- Recipient set unchanged: `gpg --list-packets` on the staged ciphertext reports exactly one `pubkey enc packet`, with keyid `99F28D011988964B`. A second recipient packet — which a local `gpg.conf` carrying `encrypt-to` or `default-recipient` adds silently — stops the run (R6).
- Manifest parses and the path resolves: `garden --config <scratch-plaintext> --root <scratch-root> ls -v --all` exits 0 and lists `home-panel` at `<scratch-root>/github.com/hyperlapse122/home-panel` (R1, R2). Both flags are load-bearing: without `--config`, garden falls back to XDG discovery and silently parses the deployed registry instead of the edit; without `--root`, path resolution reaches into the real `~/src` (R9).
- Shallow template applied: the appended entry line reads `templates: shallow`, and the `templates.shallow` block (`depth: 1`, `single-branch: false`) is unchanged in the scoped diff (R3). This is a textual assertion because garden 2.7.0 exposes no read-only view of a resolved template — `ls -v --all` prints name, path, remotes, and commands at every verbosity level, never `depth` or `single-branch` — and the runtime shallow semantics are already proved by `.ci/test-garden-shallow-pull.sh` against its own fixture.
- Nothing else moved: `diff <scratch>/head.yaml <scratch>/garden.yaml` shows exactly one added four-line block and no other change (R4, R5).
- Tree count: the manifest declares 22 trees, exactly one more than the 21 at `HEAD`. Recount at `HEAD` before asserting, so an unrelated registration landing between plan and execution does not fail this gate.
- Fingerprint re-trigger: `sha256sum` of the new source differs from `917c13c7c1101aee786c3d6d836c4cae9a89eccd1764da74d11ca8a92d2f6fbf`, so the 90-src provisioner re-runs on the next apply.
- Local garden gate: `.ci/test-garden-shallow-pull.sh` exits 0 — it decrypts the new source, parses it with `garden ls -v`, and asserts the `templates` / `shallow` / `unshallow` keys survive.
- No plaintext leak: `git status --porcelain` shows only the ciphertext source plus this plan, and the scratch directory is gone (R7).
- Committed ciphertext verified: after the staged file replaces the source, decrypt the installed source and `cmp` it against `<scratch>/garden.yaml`, and re-run the recipient check on that installed file. A mismatch means `git checkout -- dot_config/garden/encrypted_readonly_garden.yaml.asc` and stop (R6, R8).
- Abort safety: stage deliberately corrupt ciphertext to force the round-trip comparison to fail, then confirm the run stops before the move, the trap clears scratch, and `dot_config/garden/encrypted_readonly_garden.yaml.asc` is byte-identical to `HEAD` (R8).

**Verification:** Every test scenario above passes, `git diff --check` is clean, and the scoped diff touches exactly one source file plus this plan.

---

## Verification Contract

Run from the checkout root. `scratch` is a `mktemp -d` directory beneath `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch`, created under `umask 077` and removed by a trap on `EXIT HUP INT TERM`. Gates run in table order: Post-move and the Local garden gate are last, because both read the installed source rather than the staged file.

| Gate | Command shape | Proves |
|---|---|---|
| Decrypt | `chezmoi --source "$PWD" decrypt <source> > <scratch>/head.yaml`, copied to `<scratch>/garden.yaml` for editing | GPG key present; plaintext obtained outside the worktree, and the pre-edit reference kept in the same scratch (R7) |
| Round-trip | `chezmoi --source "$PWD" decrypt <staged> \| cmp - <scratch>/garden.yaml` | The staged ciphertext preserves plaintext byte-for-byte before it replaces the source |
| Recipient | `gpg --list-packets <staged>` | Exactly one `pubkey enc packet`, keyid `99F28D011988964B` — no recipient added or lost (R6) |
| Parse + path | `garden --config <scratch>/garden.yaml --root <scratch>/src ls -v --all` | garden accepts the manifest and resolves the new tree path (R1, R2) |
| Scoped diff | `diff <scratch>/head.yaml <scratch>/garden.yaml` | Exactly one four-line addition carrying `templates: shallow`; no other entry, template, or command changed (R3, R4, R5) |
| Fingerprint | `sha256sum <source>` | The value moved off `917c13c7…`, so the 90-src provisioner re-runs once the change reaches chezmoi's source directory |
| Post-move | `chezmoi --source "$PWD" decrypt <source> \| cmp - <scratch>/garden.yaml`, then `gpg --list-packets <source>` | The ciphertext that will actually be committed is intact and keeps its one recipient. The move crosses filesystems, so it is a copy-and-unlink, not an atomic rename (R6, R8) |
| Local garden gate | `.ci/test-garden-shallow-pull.sh` | The real registry still decrypts, parses, and keeps its template and command keys |
| Hygiene | `git diff --check`, `git status --porcelain` | No whitespace damage and no stray plaintext |
| Abort safety | staged-corruption rehearsal | A failed round-trip stops before the move and leaves the committed ciphertext byte-identical to `HEAD` (R8) |

Prohibited as verification: `chezmoi apply`, `garden grow` against the real registry, any write against `~/src`, and any clone from `github.com`. The Local garden gate's own `garden grow` is exempt: it runs only against a `file://` fixture inside its own scratch root, so it satisfies R7 and R9. The registry is verified as data, not by provisioning it (R9).

---

## Risks & Dependencies

- **Whole-file ciphertext churn.** gpg is non-deterministic, so the diff is the entire blob and carries no reviewable signal. Review the intent from this plan and the commit message, not the diff.
- **Editing the wrong copy.** `~/.config/garden/garden.yaml` is the 0444 deployed target; editing it is silently discarded on the next apply. The source is `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Recipient drift.** Encrypting to a different recipient than the committed source would lock every other host out of the registry, and CI would stay green because it never decrypts. Hence the explicit keyid gate.
- **Single copy.** The encrypted source is the only copy of the registry. KTD7's staged move is what keeps a failed encrypt from destroying it.

---

## Documentation / Operational Notes

The next `chezmoi apply` re-runs the 90-src provisioner, because the fingerprint over the encrypted source changed. It shallow-clones the repository into `~/src/github.com/hyperlapse122/home-panel`, runs `setup-upstream` to set `origin/HEAD`, and asks aoe to create a session on the default branch in group `github.com/hyperlapse122/home-panel`. It also re-runs grow and bootstrap across every other declared tree; each step is idempotent.

That whole-registry sweep is a precondition, not a no-op. The provisioner's completeness check fails the apply and names any declared tree that is missing, broken, or half-cloned, so an unrelated pre-existing tree can fail this apply even when the registry edit is sound. Run `src-audit` first when the host's `~/src` state is uncertain.

No `AGENTS.md` or `.chezmoitemplates/agents-instructions.tmpl` change is needed. The garden rules there already describe this workflow; this change only adds data.

---

## Definition of Done

- R1 through R9 hold.
- Every Verification Contract gate passes.
- One commit touches `dot_config/garden/encrypted_readonly_garden.yaml.asc` and this plan file, and nothing else; the message is a lowercase Conventional Commit describing the registry addition.
- No plaintext registry copy exists in the worktree or in scratch.
- No scaffolding survives: no leftover scratch scripts, no commented-out registry entries, no temporary helper files.

---

## Sources & Research

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` (read via its deployed render, `~/.config/garden/garden.yaml`) — tree schema, the `templates: shallow` shape shared by all 21 current trees, the `dotfiles` precedent for `github.com`, the append ordering, and the `setup-upstream` / `aoe-session` command bodies that consume each entry.
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — the fingerprint over the encrypted source, the grow-completeness gate, and `GIT_TERMINAL_PROMPT=0`.
- `.ci/test-garden-shallow-pull.sh:124-142` — decrypts the real registry and asserts it parses; `.ci/test-ci-wiring.sh:49` records it as intentionally unwired from CI. Evidence for KTD6.
- `.chezmoi.toml.tmpl:19-24` — `encryption = "gpg"`, recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`; the committed ciphertext's pubkey-enc keyid is `99F28D011988964B`.
- GitHub API for `hyperlapse122/home-panel` — the repository exists, is public and non-empty, and its default branch is `main`.
- `docs/plans/2026-07-30-007-chore-garden-register-vetbot-ai-plan.md` — the prior registration plan whose decrypt-edit-re-encrypt workflow and verification shape this plan follows. Not its tree shape: that plan predates the bare-to-shallow migration, so KTD1 follows the current manifest instead.
