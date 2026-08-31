---
title: "feat: Specify zsh tool for agent-of-empires default-branch project sessions"
date: 2026-08-31
topic: aoe-session-zsh-tool
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Technical Plan: Specify zsh Tool for AoE Default-Branch Project Sessions

## Goal Capsule

- **Objective:** Explicitly pass `--tool zsh` when `aoe-session` creates base sessions for primary repository checkouts on the default branch under `~/src/<host>/<group>/<project>/`.
- **Means:** Update `commands.aoe-session` in `dot_config/garden/encrypted_readonly_garden.yaml.asc` to include `--tool zsh` (alongside `--trust-hooks`), verify that `agents.aoe."config.toml"` in `.chezmoidata/agents.yaml` retains `session.custom_agents.zsh: zsh`, and update documentation in `.chezmoitemplates/agents-instructions.tmpl` and `AGENTS.md` (KTD1, KTD2).
- **Authority hierarchy:** GitHub issue #294 governs scope and acceptance criteria; repository `AGENTS.md` governs encrypted source round-trip verification and no-live-apply rules; `.chezmoitemplates/agents-instructions.tmpl` governs common instruction composition.
- **Stop conditions:** Stop and report if `aoe add` does not support `--tool zsh` (verified supported in AoE 1.15.1), if garden manifest decryption/encryption fails the recipient key-id parity check, or if changes require modifying unmanaged live files.
- **Execution profile:** Lightweight source configuration and instruction update; verified via isolated scratch decryption round-trip, `aoe-session` harness execution with canned AoE stubs, template rendering via `chezmoi execute-template`, and CI test gates.
- **Tail ownership:** The LFG pipeline owns implementation, code simplification, code review, git commit, push, PR creation, and CI monitoring.

---

## Product Contract

### Summary

When `commands.aoe-session` in `garden.yaml` provisions or registers a project session on the primary default-branch checkout (e.g. `main` or `develop` under `~/src/<host>/<group>/<project>/`), it previously invoked `aoe add "$proj" -t "$branch" -g "$group" --trust-hooks` without an explicit `--tool` parameter.

As a result, AoE defaulted to `omp` (the default AI coding agent). While AI coding agents are intended for feature-branch development worktrees (under `~/.local/share/worktrees/<name>`), primary default-branch checkouts are meant for direct interactive shell usage (git operations, rebasing/merging, log inspections, manual verification, and multi-repo audits) and should open an interactive `zsh` session instead.

This change explicitly passes `--tool zsh` in `commands.aoe-session` for primary checkouts, ensuring that newly created default-branch project sessions launch an interactive `zsh` shell.

### Problem Frame

The project ecosystem enforces a clean workflow split:
1. **Primary default-branch checkouts (`~/src/<host>/<group>/<project>/`)**: Maintained on the default branch for repository auditing, inspection, shallow-to-deep fetch, and git operations. These require an interactive shell (`zsh`).
2. **Feature branch worktrees (`~/.local/share/worktrees/<aoe-managed-name>`)**: Isolated working trees created by AoE on demand for feature implementation, bugfixes, and refactors. These run coding agents (`omp`).

Without `--tool zsh`, base sessions registered by garden bootstrap launch `omp` in the default-branch checkout, conflicting with the workflow rule that agents should work in feature worktrees rather than the primary checkout.

### Requirements

- **R1.** The garden `aoe-session` custom command in `dot_config/garden/encrypted_readonly_garden.yaml.asc` must pass `--tool zsh` when invoking `aoe add` for primary default-branch checkouts.
- **R2.** The `aoe-session` command must preserve existing `--trust-hooks`, group self-healing, existing-session detection, detached HEAD skipping, and title/group derivation semantics.
- **R3.** `.chezmoidata/agents.yaml` must continue registering `zsh: zsh` under `agents.aoe."config.toml".session.custom_agents` without `agent_detect_as` flags so AoE launches a pure `zsh` interactive shell.
- **R4.** The shared agent instructions in `.chezmoitemplates/agents-instructions.tmpl` and repository root `AGENTS.md` must document that base default-branch sessions launch an interactive `zsh` shell while coding agents operate in feature worktrees.
- **R5.** The encrypted garden manifest must be modified following the strict round-trip verification process: decrypt to a private scratch directory, verify YAML parsing, edit `aoe-session`, re-encrypt, verify recipient key-ids match `dot_config/garden/encrypted_readonly_garden.yaml.asc`, verify tree count, and confirm no plaintext is committed.

### Scope Boundaries

**In scope:**
- Updating `commands.aoe-session` in `dot_config/garden/encrypted_readonly_garden.yaml.asc` to pass `--tool zsh --trust-hooks`.
- Verifying `.chezmoidata/agents.yaml` custom agent configuration for `zsh`.
- Updating documentation in `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md`.
- Updating comments in `dot_config/garden/encrypted_readonly_garden.yaml.asc` and `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` if necessary.
- Comprehensive test harness verifying `aoe add ... --tool zsh --trust-hooks` invocation for new sessions.

**Out of scope:**
- Modifying `aoe` binary or AoE internal rust codebase.
- Changing `setup-gitdir`, `setup-upstream`, or `unshallow` commands.
- Retroactively modifying existing AoE sessions in the user's live runtime database.
- Live `chezmoi apply` modifying `$HOME` during agent execution.

### Acceptance Examples

- **AE1 (Covers R1, R2).** Running the extracted `aoe-session` stanza against a mock checkout without an existing AoE session executes `aoe add "$proj" -t "$branch" -g "$group" --tool zsh --trust-hooks`.
- **AE2 (Covers R2).** Running `aoe-session` against a checkout with an existing session at the policy group prints the skip line and does not execute `aoe add` or change tools.
- **AE3 (Covers R3).** Validating `.chezmoidata/agents.yaml` confirms `session.custom_agents.zsh: zsh` is present and active.
- **AE4 (Covers R4).** Rendering `.chezmoitemplates/agents-instructions.tmpl` produces instructions explicitly documenting that primary checkouts use `zsh` base sessions and feature worktrees use coding agents (`omp`).
- **AE5 (Covers R5).** Decrypting the newly re-encrypted `dot_config/garden/encrypted_readonly_garden.yaml.asc` parses as valid YAML, matches the original tree count, and uses the exact GPG recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Pass `--tool zsh` alongside `--trust-hooks` on `aoe add` in `aoe-session`.** `aoe add` supports `--tool <TOOL>` to specify the tool launched for a new session. Passing `--tool zsh --trust-hooks` ensures that base sessions on primary checkouts launch `zsh` without interactive prompts while maintaining hook trust.
  *(session-settled: user-directed — chosen over altering global AoE default agent: keeps default coding agent for ad-hoc worktrees while making garden-bootstrapped base sessions plain shells).* Governs R1, R2.
- **KTD2. Preserve custom agent registration in `.chezmoidata/agents.yaml`.** AoE recognizes `zsh` as a custom agent via `session.custom_agents.zsh: zsh` in `agents.aoe."config.toml"`. Because no `agent_detect_as` entry is configured for `zsh`, AoE executes `zsh` as a plain interactive shell without injecting agent protocol arguments. Governs R3.
- **KTD3. Document shell vs agent workflow in instruction templates and AGENTS.md.** Explicitly clarify in `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md` under `## Repository layout and garden ownership` that `aoe-session` registers base sessions with `--tool zsh` (interactive shell) on default-branch checkouts, whereas feature-branch worktrees run coding agents. Governs R4.

### Assumptions

- `aoe` version is 1.15.1+ (verified: installed version is `aoe 1.15.1`), which supports both `--tool <TOOL>` and `--trust-hooks` flags on `aoe add`.
- Existing sessions in AoE are not retrofitted (AoE CLI does not support changing the tool of an existing session in place); newly bootstrapped sessions receive the `zsh` tool.

---

## Implementation Units

### U1. Update `commands.aoe-session` in `encrypted_readonly_garden.yaml.asc`

- **Goal:** Update `aoe add` in `commands.aoe-session` to pass `--tool zsh --trust-hooks` and update comments in the decrypted garden manifest.
- **Requirements:** R1, R2, R5
- **Dependencies:** None
- **Files:** `dot_config/garden/encrypted_readonly_garden.yaml.asc`
- **Approach:**
  1. Decrypt `dot_config/garden/encrypted_readonly_garden.yaml.asc` to a private scratch file (`$XDG_RUNTIME_DIR/scratch/garden.yaml`).
  2. Modify `commands.aoe-session`: change `aoe add "$proj" -t "$branch" -g "$group" --trust-hooks` to `aoe add "$proj" -t "$branch" -g "$group" --tool zsh --trust-hooks`.
  3. Update comments on `aoe-session` to document the `zsh` tool and automatic hook trust.
  4. Encrypt the scratch file back with `chezmoi encrypt` using recipient `A7F1956CD1A035A139BC7ABFCC740A29852C0E95`.
  5. Decrypt the newly encrypted file to another scratch location, verify YAML parsing with `yq`, verify tree count is identical to pre-edit state, and verify recipient key IDs match.
  6. Atomically replace `dot_config/garden/encrypted_readonly_garden.yaml.asc` and wipe scratch files.
- **Patterns to follow:** Prior garden manifest updates (e.g. `docs/plans/2026-08-31-1155-feat-aoe-session-trust-repo-hooks-plan.md`).
- **Test Scenarios:**
  - *Happy path (manifest validation):* Decrypted YAML parses cleanly; tree count equals pre-edit count; git diff shows only ciphertext changed.
  - *Integration (aoe-session execution):* Extract `aoe-session` script and run against a test directory with a mock `aoe` binary; assert that `aoe add` is invoked with `--tool zsh --trust-hooks`.
- **Verification:** Scratch harness passes, and `gpg --list-packets` verifies recipient key-id.

### U2. Update shared instructions, repository supplement, and script comments

- **Goal:** Document that `aoe-session` creates interactive `zsh` base sessions on default-branch checkouts.
- **Requirements:** R4
- **Dependencies:** U1
- **Files:**
  - `.chezmoitemplates/agents-instructions.tmpl`
  - `AGENTS.md`
  - `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` (if comments mention session tool)
- **Approach:**
  1. In `.chezmoitemplates/agents-instructions.tmpl`, update the garden bootstrap paragraph under `## Repository layout and garden ownership` to state that `aoe-session` creates base sessions with `--tool zsh` (interactive shell) on primary default-branch checkouts while trusting repository hooks (`--trust-hooks`).
  2. In root `AGENTS.md`, update the matching sentence under `## Repository layout and garden ownership`.
- **Patterns to follow:** Compact RFC-2119 and clear instruction style in `agents-instructions.tmpl`.
- **Test Scenarios:**
  - *Happy path (render parity):* `.ci/test-agent-instructions.sh` passes; `chezmoi execute-template` renders without syntax errors.
  - *Diff check:* Instructions clearly differentiate `zsh` shell on primary checkouts vs coding agents on feature worktrees.
- **Verification:** `.ci/test-agent-instructions.sh` passes with zero regressions.

---

## Verification Contract

| Test / Gate | Command / Action | Expected Result |
| :--- | :--- | :--- |
| **Manifest Round-trip** | Decrypt scratch round-trip + YAML parse check | Valid YAML, same tree count, matching recipient key-id |
| **AoE Session Harness** | Run extracted `aoe-session` against mock git repository with stub `aoe` | `aoe add "$proj" -t "$branch" -g "$group" --tool zsh --trust-hooks` is called |
| **Instruction Gates** | `.ci/test-agent-instructions.sh` | All positive and negative needle tests pass |
| **Render Template** | `chezmoi execute-template < dot_omp/private_agent/private_readonly_AGENTS.md.tmpl` | Renders correctly with `--tool zsh` documented |
| **Clean Diff** | `git diff --check` and `git status` | Clean diff, no plaintext leaks, no unmanaged residue |

---

## Definition of Done

- [ ] `dot_config/garden/encrypted_readonly_garden.yaml.asc` updated with `--tool zsh --trust-hooks` in `commands.aoe-session`.
- [ ] Decrypt round-trip verification passes and tree count is preserved.
- [ ] `.chezmoitemplates/agents-instructions.tmpl` and root `AGENTS.md` updated to document `--tool zsh` for primary checkout base sessions.
- [ ] `.ci/test-agent-instructions.sh` passes.
- [ ] No plaintext garden registry or secrets committed.
- [ ] Branch renamed to Git Flow descriptive slug (`feature/aoe-session-zsh-tool`).
- [ ] PR created and CI passes.
