---
title: Register telerad-payment in the ~/src Garden Registry - Plan
type: chore
date: 2026-09-03
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Register telerad-payment in the ~/src Garden Registry - Plan

## Goal Capsule

- **Objective:** On every host that applies these dotfiles, `telerad-payment` is already checked out at `~/src/git.jpi.app/examvue-365-flow/telerad-payment` with an aoe session attached, so the user starts work on it without cloning it by hand per host.
- **Means:** Declare it as one `templates: shallow` tree in the encrypted `~/src` project registry (KTD4).
- **Authority:** The root `AGENTS.md` garden rules and the manifest's own in-file conventions outrank this plan. Where they conflict, follow them and flag the conflict.
- **Execution profile:** One commit against `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Plaintext exists only in per-user scratch, never in the worktree.
- **Stop conditions:** Stop and ask if the scratch root cannot be created writable and `0700`, if decryption fails (GPG private key absent), if `garden ls` rejects the edited manifest, if the plaintext round-trip is not byte-identical, or if the ciphertext carries any recipient other than the one the committed source already has.
- **Tail ownership:** The implementer commits. Deployment is the user's call — `chezmoi apply` performs a real network clone and creates an aoe session, so it is never part of verification.

---

## Product Contract

### Summary

Add one tree to the chezmoi-managed `~/src` project registry so `garden grow` clones `products/365flow/telerad-payment` from `git.jpi.app` and the 90-src provisioner bootstraps it like every other declared repo. The registry is GPG ciphertext in a public repo, so the edit is a decrypt-edit-re-encrypt cycle in scratch.

### Problem Frame

`products/365flow/telerad-payment` is absent from the registry, so no host grows or sessions it. Its remote shape matches the seven `365flow` trees the registry already declares — a repo under the `products` umbrella inside the `365flow` product subgroup — so the on-disk layout is settled by the manifest's own documented rewrite rule, not open.

The registry is the only copy of itself. The deployed `~/.config/garden/garden.yaml` is a 0444 render, and CI never decrypts the source. A bad re-encrypt is unrecoverable, which is why the edit is staged and round-trip-verified before it replaces the committed ciphertext.

### Requirements

**Registry entry**

- R1. The registry declares tree `telerad-payment` with `url: https://git.jpi.app/products/365flow/telerad-payment.git`.
- R2. Its path is `git.jpi.app/examvue-365-flow/telerad-payment` — the `products` umbrella segment dropped in favor of the product-family form the manifest's `365flow` comment prescribes.
- R3. The entry carries `templates: shallow`, the same field every current tree uses for a plain shallow checkout, and declares no `worktree:` tree.
- R4. The entry sits at the end of `trees:`, after `home-panel`, in the file's existing field order (`templates`, `path`, `url`) and two-space indentation.
- R5. No other tree entry, template, command, or comment in the manifest changes.

**Ciphertext safety**

- R6. The re-encrypted source carries exactly one `pubkey enc packet`, with keyid `99F28D011988964B` — the same recipient set the committed source has, so no host loses the ability to decrypt and no extra recipient is added.
- R7. Decrypted plaintext never enters the worktree, `/tmp`, `/var/tmp`, or `/dev/shm`.
- R8. A failed round-trip leaves the committed ciphertext byte-identical to `HEAD`.

**Verification boundary**

- R9. Verification runs no `chezmoi apply`, writes nothing under `~/src`, and clones nothing from `git.jpi.app`.
- R10. The changed file is `dot_config/garden/encrypted_readonly_garden.yaml.asc`; the deployed `~/.config/garden/garden.yaml` is not written.

### Scope Boundaries

**Out of scope**

- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — its fingerprint already hashes the registry source, so the re-run trigger is automatic and no script edit is needed.
- `.ci/test-garden-shallow-pull.sh` and `.ci/test-ci-wiring.sh` — the shallow-pull test already decrypts and parses the real registry, and is deliberately unwired from CI (KTD9).
- `.chezmoiignore`, `dot_local/share/chezmoi-command-sources/executable_src-audit`, and aoe session lifecycle. aoe owns worktrees; the registry only declares trees.
- Other trees' entries, and the manifest's header comments. The user scoped this change to one repository.
- The deployed `~/.config/garden/garden.yaml`. It is a render target, not a source.
- Credential provisioning for `git.jpi.app`. Twelve trees already clone from that host on apply, so the existing `10-auth` credential path covers this one.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Edit the encrypted source, staged in scratch.** The change lands in `dot_config/garden/encrypted_readonly_garden.yaml.asc`. (session-settled: user-directed — chosen over editing the deployed `~/.config/garden/garden.yaml`: the deployed file is a 0444 render regenerated on the next apply.) Governs R10.
- KTD2. **Plaintext stays outside the repository.** Scratch lives under `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch`, created with `umask 077` and removed by a trap. (session-settled: user-approved — chosen over committing a plaintext copy for reviewability: the repo's sole-ciphertext rule forbids plaintext garden state in git.) Governs R7.
- KTD3. **Stage the re-encrypt, verify, then move it over the source.** A bare `>` redirect onto the source truncates the file before encryption runs, so a failure would destroy the only copy of the registry before any gate could catch it. (session-settled: user-approved — chosen over re-encrypting straight onto the source and validating afterwards: a failed round-trip caught after the overwrite is unrecoverable.) Governs R8.
- KTD4. **Plain shallow checkout, not a bare tree and not a garden `worktree:`.** All 22 current trees carry `templates: shallow` and a working-checkout path; the `.bare` + `bare: true` shape is retired from this manifest, and `worktree:` trees are forbidden because aoe owns worktrees. (session-settled: user-approved — chosen over inventing a new entry shape: the registry's consumers and the repository layout rule both require the existing shape.) Governs R3.
- KTD5. **The path drops `products` in favor of the product-family segment `examvue-365-flow`.** The manifest's own comment states the rule: a repo under a product subgroup drops the `products` umbrella, and the `365flow` subgroup carries its product-family prefix on disk. All seven existing `365flow` trees follow it. Governs R2.
- KTD6. **Tree name `telerad-payment` — the project leaf.** It collides with none of the 22 existing names, so the `<group>-<project>` disambiguation form the manifest reserves for collisions is not needed.
- KTD7. **Append after `home-panel`, at the end of `trees:`.** The file is append-ordered, not sorted or clustered by host — `pacs-frontend` is itself a `365flow` tree that sits outside the `365flow` block for the same reason. Appending keeps the diff minimal and leaves the block comments anchored to the entries they were written for.
- KTD8. **The HTTPS URL is used exactly as supplied.** It matches every other `git.jpi.app` entry's form. The repository is private, so the apply-time clone needs the credential path the other twelve `git.jpi.app` trees already use; no registry-side change makes that work.
- KTD9. **No new or edited test.** `.ci/test-garden-shallow-pull.sh` already decrypts the real registry, runs `garden ls -v` over it, and asserts the `templates` / `shallow` / `unshallow` keys survive. `.ci/test-ci-wiring.sh` records it as intentionally unwired, because no runner provisions `garden` or the private key. It is a local gate, not a CI gate, and needs no change to cover a data-only addition.

### Assumptions

These are un-validated bets the planning run made; the user did not confirm them.

- The shallow default applies to this tree like every other. The user asked for a plain registration and named no history requirement; `garden cmd telerad-payment unshallow` retrieves full history on demand later.
- No tree-specific bootstrap command is needed. `setup-upstream` and `aoe-session` are declared once for all trees and are the whole bootstrap; no existing entry declares anything extra.
- The implementer's host has the GPG private key imported. Absence is a stop condition, not something to work around.
- `garden` and `chezmoi` are available on the implementer's host.
- Registration is the deliverable. Deploying it (`chezmoi apply`) is a separate, user-initiated step.
- The default branch is `main`, so `aoe-session` attaches rather than skipping on a detached HEAD.

---

## Implementation Units

### U1. Register the telerad-payment tree

**Goal:** Add the `telerad-payment` tree to the encrypted registry as one ciphertext change, with no other manifest content touched.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10

**Dependencies:** none

**Files:**

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` — the only file changed. No test file; see KTD9.

**Execution note:** This is data-only configuration. Prefer parse-and-round-trip proof over unit coverage, and rehearse the abort path before trusting the move.

**Approach:**

1. Create scratch with `mktemp -d` beneath `${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch` under `umask 077`, and install a cleanup trap on `EXIT HUP INT TERM` before decrypting, so a stop-condition exit cannot leave plaintext behind (KTD2). The `XDG_RUNTIME_DIR` fallback is the pattern this repo's own scratch users already take (`.ci/test-garden-shallow-pull.sh`); it keeps an unset `XDG_RUNTIME_DIR` from routing plaintext to `/tmp`.
2. Decrypt the source to a scratch plaintext, then copy it to `<scratch>/head.yaml` before editing so the scoped diff needs no second decrypt.
3. Edit the working copy: append the entry immediately after the `home-panel` entry, before the `commands:` key, mirroring that entry's field order and indentation — name `telerad-payment`, `templates: shallow`, `path: git.jpi.app/examvue-365-flow/telerad-payment`, `url: https://git.jpi.app/products/365flow/telerad-payment.git` (R1, R2, R3, R4; KTD5, KTD6, KTD7).
4. Encrypt to a **staged** file in scratch, run every verification gate against that staged file, and only then move it over the source (KTD3).
5. Re-verify the installed source after the move: the move may cross filesystems, so it is a copy-and-unlink rather than an atomic rename.

Run every `chezmoi` invocation with `--source "$PWD"`. This checkout is a worktree, and omitting the flag triggers recursive-data errors.

**Patterns to follow:** the seven existing `365flow` entries — same host, same umbrella rewrite, same tree shape. `telerad-openapi` and `telerad-frontend` are the closest siblings.

**Test scenarios:**

- Round-trip fidelity: decrypt the staged ciphertext in scratch and `cmp` it against the edited plaintext; the two are byte-identical before anything overwrites the source.
- Recipient set unchanged: `gpg --list-packets` on the staged ciphertext reports exactly one `pubkey enc packet`, with keyid `99F28D011988964B`. A second recipient packet — which a local `gpg.conf` carrying `encrypt-to` or `default-recipient` adds silently — stops the run (R6).
- Manifest parses and the path resolves: `garden --config <scratch-plaintext> --root <scratch-root> ls -v --all` exits 0 and lists `telerad-payment` at `<scratch-root>/git.jpi.app/examvue-365-flow/telerad-payment` (R1, R2). Both flags are load-bearing: without `--config`, garden falls back to XDG discovery and silently parses the deployed registry instead of the edit; without `--root`, path resolution reaches into the real `~/src` (R9).
- Shallow template applied: the appended entry line reads `templates: shallow`, and the `templates.shallow` block (`depth: 1`, `single-branch: false`) is unchanged in the scoped diff (R3). This is a textual assertion because garden exposes no read-only view of a resolved template — `ls -v --all` prints name, path, remotes, and commands at every verbosity level, never `depth` or `single-branch` — and the runtime shallow semantics are already proved by `.ci/test-garden-shallow-pull.sh` against its own fixture.
- No garden worktree declared: the scoped diff introduces no `worktree:` key anywhere (R3).
- Nothing else moved: `diff <scratch>/head.yaml <scratch>/garden.yaml` shows exactly one added four-line block and no other change (R4, R5).
- Tree count: the manifest declares 23 trees, exactly one more than the 22 at `HEAD`. Recount at `HEAD` before asserting, so an unrelated registration landing between plan and execution does not fail this gate.
- Fingerprint re-trigger: `sha256sum` of the new source differs from `9698a9c506b5314a3a9fb0f7f461c9d5632b88a9d68c5025b3b22ac3472fa626`, so the 90-src provisioner re-runs on the next apply.
- Local garden gate: `.ci/test-garden-shallow-pull.sh` exits 0 — it decrypts the new source, parses it with `garden ls -v`, and asserts the `templates` / `shallow` / `unshallow` keys survive.
- No plaintext leak: `git status --porcelain` shows only the ciphertext source plus this plan, and the scratch directory is gone (R7).
- Deployed copy untouched: `~/.config/garden/garden.yaml` still matches its pre-run checksum, proving the edit went to the source (R10).
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
| Scoped diff | `diff <scratch>/head.yaml <scratch>/garden.yaml` | Exactly one four-line addition carrying `templates: shallow` and no `worktree:` key; no other entry, template, or command changed (R3, R4, R5) |
| Fingerprint | `sha256sum <source>` | The value moved off `9698a9c5…`, so the 90-src provisioner re-runs once the change reaches chezmoi's source directory |
| Deployed copy | checksum of `~/.config/garden/garden.yaml` before and after | The 0444 render was not edited; the change went to the encrypted source (R10) |
| Post-move | `chezmoi --source "$PWD" decrypt <source> \| cmp - <scratch>/garden.yaml`, then `gpg --list-packets <source>` | The ciphertext that will actually be committed is intact and keeps its one recipient. The move may cross filesystems, so it is a copy-and-unlink, not an atomic rename (R6, R8) |
| Local garden gate | `.ci/test-garden-shallow-pull.sh` | The real registry still decrypts, parses, and keeps its template and command keys |
| Hygiene | `git diff --check`, `git status --porcelain` | No whitespace damage and no stray plaintext |
| Abort safety | staged-corruption rehearsal | A failed round-trip stops before the move and leaves the committed ciphertext byte-identical to `HEAD` (R8) |

Prohibited as verification: `chezmoi apply`, `garden grow` against the real registry, any write against `~/src`, and any clone from `git.jpi.app`. The Local garden gate's own `garden grow` is exempt: it runs only against a `file://` fixture inside its own scratch root, so it satisfies R7 and R9. The registry is verified as data, not by provisioning it (R9).

---

## Risks & Dependencies

- **Whole-file ciphertext churn.** gpg is non-deterministic, so the diff is the entire blob and carries no reviewable signal. Review the intent from this plan and the commit message, not the diff.
- **Editing the wrong copy.** `~/.config/garden/garden.yaml` is the 0444 deployed target; editing it is silently discarded on the next apply. The source is `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Recipient drift.** Encrypting to a different recipient than the committed source would lock every other host out of the registry, and CI would stay green because it never decrypts. Hence the explicit keyid gate.
- **Single copy.** The encrypted source is the only copy of the registry. KTD3's staged move is what keeps a failed encrypt from destroying it.
- **Private remote.** The repository is private on `git.jpi.app`, so a host without that credential fails at apply time, not at commit time. Twelve existing trees share that dependency; this change adds no new credential surface.

---

## Documentation / Operational Notes

The next `chezmoi apply` re-runs the 90-src provisioner, because the fingerprint over the encrypted source changed. It shallow-clones the repository into `~/src/git.jpi.app/examvue-365-flow/telerad-payment`, runs `setup-upstream` to set `origin/HEAD`, and asks aoe to create a session on the default branch in group `git.jpi.app/examvue-365-flow/telerad-payment`. It also re-runs grow and bootstrap across every other declared tree; each step is idempotent.

That whole-registry sweep is a precondition, not a no-op. The provisioner's completeness check fails the apply and names any declared tree that is missing, broken, or half-cloned, so an unrelated pre-existing tree can fail this apply even when the registry edit is sound. Run `src-audit` first when the host's `~/src` state is uncertain.

No `AGENTS.md` or `.chezmoitemplates/agents-instructions.tmpl` change is needed. The garden rules there already describe this workflow; this change only adds data.

---

## Definition of Done

- R1 through R10 hold.
- Every Verification Contract gate passes.
- One commit touches `dot_config/garden/encrypted_readonly_garden.yaml.asc` and this plan file, and nothing else; the message is a lowercase Conventional Commit describing the registry addition.
- No plaintext registry copy exists in the worktree or in scratch.
- No scaffolding survives: no leftover scratch scripts, no commented-out registry entries, no temporary helper files.

---

## Sources & Research

- `dot_config/garden/encrypted_readonly_garden.yaml.asc` (read via its deployed render, `~/.config/garden/garden.yaml`, verified byte-identical to the worktree source by checksum) — tree schema, the `templates: shallow` shape shared by all 22 current trees, the `365flow` umbrella-rewrite comment, the append ordering, and the `setup-upstream` / `aoe-session` command bodies that consume each entry.
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — the fingerprint over the encrypted source, the grow-completeness gate, and `GIT_TERMINAL_PROMPT=0`.
- `.ci/test-garden-shallow-pull.sh` — decrypts the real registry and asserts it parses; `.ci/test-ci-wiring.sh` records it as intentionally unwired from CI. Evidence for KTD9.
- `.chezmoi.toml.tmpl` — `encryption = "gpg"`, recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`; the committed ciphertext's pubkey-enc keyid is `99F28D011988964B`.
- GitLab API for `products/365flow/telerad-payment` on `git.jpi.app` — the project exists (id 73), is private and non-empty, sits in namespace `ExamVue 365 Flow` (path `365flow`), and its default branch is `main`.
- `docs/plans/2026-09-03-0259-chore-register-home-panel-garden-tree-plan.md` — the prior registration plan whose decrypt-edit-re-encrypt workflow and verification shape this plan follows. Its `github.com` path rule does not apply here; KTD5 follows the manifest's `products`/subgroup rewrite instead.
