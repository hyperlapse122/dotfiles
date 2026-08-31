---
title: "feat: Make agent-of-empires trust repo-defined hooks automatically in garden session bootstrap"
date: 2026-08-31
topic: aoe-session-trust-repo-hooks
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Technical Plan: Trust Repo-Defined Hooks in AoE Garden Session Bootstrap

## Goal Capsule

- **Objective:** Enable non-interactive and automated initialization of AoE sessions during garden provisioning (`garden cmd '*' aoe-session` and `chezmoi apply`) without blocking on repo hook/MCP trust confirmation prompts.
- **Means:** Pass `--trust-hooks` in `commands.aoe-session` within `dot_config/garden/encrypted_readonly_garden.yaml.asc` and update the instruction documentation across `.chezmoitemplates/agents-instructions.tmpl` and `AGENTS.md` (KTD1, KTD2).
- **Authority hierarchy:** GitHub issue #293 governs scope and acceptance criteria; repository `AGENTS.md` governs the encrypted source round-trip verification and no-live-apply rules; `.chezmoitemplates/agents-instructions.tmpl` governs common instruction composition.
- **Stop conditions:** Stop and report if `aoe add` does not support `--trust-hooks` (verified supported in AoE 1.15.1), if garden manifest decryption/encryption fails the recipient key-id parity check, or if changes require modifying unmanaged live files.
- **Execution profile:** Lightweight source configuration and instruction update; verified via isolated scratch decryption round-trip, `aoe-session` harness execution with canned AoE stubs, template rendering via `chezmoi execute-template`, and CI test gates.
- **Tail ownership:** The LFG pipeline owns implementation, code simplification, code review, git commit, push, PR creation, and CI monitoring.

---

## Product Contract

### Summary
When growing repositories or initializing workspace sessions via `garden cmd '*' aoe-session` (including during `chezmoi apply` via `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`), repositories declaring lifecycle hooks (`on_create`, `on_launch`, etc.) or project MCP servers in `.agent-of-empires/config.toml` trigger an interactive terminal confirmation prompt (`Trust this repo (hooks and project MCP shown above)? [y/N]`). This blocks unattended, headless, and CI execution.

This change adds `--trust-hooks` to `aoe add` in the garden `aoe-session` command so that all garden-managed repositories automatically trust repo-defined hooks and project-local MCP servers upon session creation. Matching documentation updates in `.chezmoitemplates/agents-instructions.tmpl` and `AGENTS.md` ensure instructions accurately reflect this automated trust behavior.

### Problem Frame
Garden bootstrap is designed to be fully automated and idempotent. When a user runs `garden cmd '*' aoe-session` or when `chezmoi apply` reconciles the garden on manifest changes, any repository containing an `.agent-of-empires/config.toml` file with hooks prompts for interactive confirmation. In headless environments (such as remote provisioning, CI, or automated script execution), stdin is non-interactive or unattended, causing the bootstrap process to hang indefinitely or fail session creation.

### Requirements

- **R1.** The garden `aoe-session` custom command in `dot_config/garden/encrypted_readonly_garden.yaml.asc` must pass `--trust-hooks` when creating new sessions with `aoe add`, bypassing interactive prompts.
- **R2.** The `aoe-session` command must preserve existing group self-healing, existing-session detection, detached HEAD skipping, and title/group derivation semantics.
- **R3.** The shared agent instructions in `.chezmoitemplates/agents-instructions.tmpl` and repository root `AGENTS.md` must document that `aoe-session` automatically trusts repo-defined hooks and project MCP servers (`--trust-hooks`).
- **R4.** The encrypted garden manifest must be modified following the strict round-trip verification process: decrypt to a private scratch directory, verify YAML parsing, edit `aoe-session`, re-encrypt, verify recipient key-ids match `dot_config/garden/encrypted_readonly_garden.yaml.asc`, verify tree count, and confirm no plaintext is committed.

### Scope Boundaries

**In scope:**
- Updating `commands.aoe-session` in `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- Updating documentation in `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md`.
- Updating comments in `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` if necessary.
- Comprehensive test harness verifying `aoe add ... --trust-hooks` invocation for new sessions.

**Out of scope:**
- Modifying `aoe` binary or AoE internal rust codebase (AoE already supports `--trust-hooks` natively in v1.15.1).
- Changing `setup-gitdir` or `setup-upstream` commands.
- Live `chezmoi apply` modifying `$HOME` during agent execution.
- Modifying `trusted_repos.toml` directly (AoE handles this automatically when `--trust-hooks` is passed).

### Acceptance Examples

- **AE1 (Covers R1, R2).** Running the extracted `aoe-session` stanza against a mock checkout without an existing AoE session executes `aoe add "$proj" -t "$branch" -g "$group" --trust-hooks`.
- **AE2 (Covers R2).** Running `aoe-session` against a checkout with an existing session at the policy group prints the skip line and does not execute `aoe add` or prompt.
- **AE3 (Covers R3).** Rendering `.chezmoitemplates/agents-instructions.tmpl` into `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` produces text stating that `aoe-session` passes `--trust-hooks`.
- **AE4 (Covers R4).** Decrypting the newly re-encrypted `dot_config/garden/encrypted_readonly_garden.yaml.asc` parses as valid YAML, matches the original tree count, and uses the exact GPG recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Pass `--trust-hooks` on `aoe add` in `aoe-session`.** `aoe add` natively exposes `--trust-hooks`, which marks hooks and project-local MCP servers as trusted in `trusted_repos.toml` during session addition without prompting. Adding this flag directly to the `aoe add "$proj" -t "$branch" -g "$group"` line in the garden manifest solves the automated bootstrap blocker at the root source.
  *(session-settled: user-directed — chosen over manually injecting hashes into `trusted_repos.toml`: native CLI flag ensures schema and hash compatibility across AoE updates).* Governs R1.
- **KTD2. Update common agent instructions and repository supplement.** Update the garden bootstrap description in `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md` to mention `--trust-hooks`. Governs R3.
- **KTD3. Encrypted manifest round-trip verification.** Perform all manifest edits via a temporary scratch file, verifying YAML syntax and GPG recipient key-ID match (`99F28D011988964B` for `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`) before replacing `dot_config/garden/encrypted_readonly_garden.yaml.asc`. Governs R4.

### Assumptions

- `aoe` version is 1.15.1+ (verified: installed version is `aoe 1.15.1`), which includes the `--trust-hooks` flag on `aoe add`.
- Existing sessions in AoE already had their trust established or will establish trust on re-creation. Group moves for existing sessions do not prompt for hook trust.

---

## Implementation Units

### U1. Update `commands.aoe-session` in `encrypted_readonly_garden.yaml.asc`

- **Goal:** Append `--trust-hooks` to `aoe add` in `commands.aoe-session` and update header comments in the decrypted garden manifest.
- **Requirements:** R1, R2, R4
- **Dependencies:** None
- **Files:** `dot_config/garden/encrypted_readonly_garden.yaml.asc`
- **Approach:**
  1. Decrypt `dot_config/garden/encrypted_readonly_garden.yaml.asc` to a private scratch file (`$XDG_RUNTIME_DIR/scratch/garden.yaml`).
  2. Modify `commands.aoe-session`: change `aoe add "$proj" -t "$branch" -g "$group"` to `aoe add "$proj" -t "$branch" -g "$group" --trust-hooks`.
  3. Update comments on `aoe-session` to document automatic hook trust.
  4. Encrypt the scratch file back with `chezmoi encrypt` using recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`.
  5. Decrypt the newly encrypted file to another scratch location, verify YAML parsing with `yq`, verify tree count is identical to pre-edit state, and verify recipient key IDs match.
  6. Atomically replace `dot_config/garden/encrypted_readonly_garden.yaml.asc` and wipe scratch files.
- **Patterns to follow:** Prior garden manifest updates (e.g. `docs/plans/2026-08-31-0923-refactor-src-worktree-management-plan.md`).
- **Test Scenarios:**
  - *Happy path (manifest validation):* Decrypted YAML parses cleanly; tree count equals pre-edit count; git diff shows only ciphertext changed.
  - *Integration (aoe-session execution):* Extract `aoe-session` script and run against a test directory with a mock `aoe` binary; assert that `aoe add` is invoked with `--trust-hooks`.
- **Verification:** Scratch harness passes, and `gpg --list-packets` verifies recipient key-id.

### U2. Update shared instructions and repository supplement

- **Goal:** Document that `aoe-session` automatically trusts repo hooks and project MCP servers.
- **Requirements:** R3
- **Dependencies:** U1
- **Files:**
  - `.chezmoitemplates/agents-instructions.tmpl`
  - `AGENTS.md`
- **Approach:**
  1. In `.chezmoitemplates/agents-instructions.tmpl`, update the garden bootstrap paragraph under `## Repository layout and garden ownership` to state that `aoe-session` automatically trusts repository hooks and project MCP servers (`--trust-hooks`).
  2. In root `AGENTS.md`, update the matching sentence under `## Repository layout and garden ownership`.
- **Patterns to follow:** Compact RFC-2119 and clear instruction style in `agents-instructions.tmpl`.
- **Test Scenarios:**
  - *Happy path (render parity):* `.ci/test-agent-instructions.sh` passes; `chezmoi execute-template` renders without syntax errors.
  - *Word diff check:* Only the `--trust-hooks` clause is added to the paragraph without altering surrounding rules.
- **Verification:** `.ci/test-agent-instructions.sh` passes with zero regressions.

---

## Verification Contract

| Test / Gate | Command / Action | Expected Result |
| :--- | :--- | :--- |
| **Manifest Round-trip** | Decrypt scratch round-trip + YAML parse check | Valid YAML, same tree count, matching recipient key-id |
| **AoE Session Harness** | Run extracted `aoe-session` against mock git repository with stub `aoe` | `aoe add "$proj" -t "$branch" -g "$group" --trust-hooks` is called |
| **Instruction Gates** | `.ci/test-agent-instructions.sh` | All positive and negative needle tests pass |
| **Render Template** | `chezmoi execute-template < dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` | Renders correctly with `--trust-hooks` documented |
| **Clean Diff** | `git diff --check` and `git status` | Clean diff, no plaintext leaks, no unmanaged residue |

---

## Definition of Done

- [ ] `dot_config/garden/encrypted_readonly_garden.yaml.asc` updated with `--trust-hooks` in `commands.aoe-session`.
- [ ] Decrypt round-trip verification passes and tree count is preserved.
- [ ] `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md` updated to document `--trust-hooks`.
- [ ] `.ci/test-agent-instructions.sh` passes.
- [ ] No plaintext garden registry or secrets committed.
- [ ] Branch renamed to Git Flow descriptive slug (`feature/aoe-session-trust-repo-hooks`).
- [ ] PR created and CI passes.
