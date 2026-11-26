---
title: Remove Legacy Installed Instruction Guides - Plan
type: refactor
date: 2026-11-26
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove Legacy Installed Instruction Guides - Plan

## Goal Capsule

- **Objective:** After the next Home Manager generation, neither legacy guide exists under `~/.local/share/nix-config/agent-instructions/`, and the authoritative `task-guide.md` and `t3-guide.md` still live in the repository for future instruction authoring.
- **Means:** Drop the two `home.file` guide declarations and add a migration activation step, ordered after Home Manager's link cleanup, that removes the installed links an earlier generation left (KTD1).
- **Authority:** Issue [#322](https://github.com/hyperlapse122/dotfiles/issues/322) is the work source. `AGENTS.md` and [Contributing](../../../docs/contributing.md) govern verification and documentation, except where the issue explicitly authorizes deleting existing state, which reverses the tool-retirement default for these two paths.
- **Execution profile:** One pull request. Three units.
- **Stop conditions:** Evidence that Home Manager did not install these paths as symlinks into the store, or that the removal cannot preserve unrelated files under the legacy directory.

---

## Product Contract

### Summary

Home Manager stops declaring the two guide copies. Activation removes the previously installed links at their exact paths and removes the legacy directory only when it is left empty. Tests read guide content from the repository sources and exercise the migration against a seeded temporary home. The documentation states that the guides are repository-only.

### Problem Frame

Pull request [#321](https://github.com/hyperlapse122/dotfiles/pull/321) reset the rendered instruction files and removed automatic guide references, but deliberately kept installing the guides (its R6). The issue now reverses that decision: the empty instruction files make the installed copies dead weight, and they duplicate sources that already live in the checkout. Historical plans stay unchanged; this plan supersedes the installation requirement only.

### Requirements

**Packaging and migration**

- R1. `home/h82/agents/instructions/default.nix` declares no `home.file` entry for `.local/share/nix-config/agent-instructions/task-guide.md` or `t3-guide.md`. The source files stay in `home/h82/agents/instructions/`.
- R2. Activation removes the two previously installed links, then removes `.local/share/nix-config/agent-instructions/` when it is empty. It removes only links whose target is a Home Manager files path, so a user file or foreign symlink at either path survives and keeps the directory. Other paths under `~/.local/share/nix-config/`, including `refresh-agent-instructions`, are untouched. The step runs after `linkGeneration`.
- R3. Guide-content checks read `home/h82/agents/instructions/task-guide.md` and `t3-guide.md` directly and keep asserting their passages and retired wording. The delivery check asserts zero `home.file` declarations for the legacy destinations, asserts the migration step is ordered after `linkGeneration`, and runs that step against a home seeded with the old links and repeated activations.
- R4. Checks prove the removal and preservation behavior by executing the migration step, not by grepping its text.

**Documentation**

- R5. `docs/agent-routing.md`, `docs/contributing.md`, and `README.md` describe the guides as repository-only; `docs/agent-routing.md` names the migration. No current documentation points to an installed copy.
- R6. `nix develop .#agent-check -c ./scripts/agent-check` passes, and `nix build --no-link .#checks.x86_64-linux.agent-instructions` builds green.

### Scope Boundaries

- In scope: the two guide declarations, the migration step, the instruction delivery checks, and the three documentation files that still describe installed guides.
- Out of scope: the guide sources, the shared template, `refresh-agent-instructions`, other retired destinations, and historical plans under `.compound-engineering/artifacts/plans/`.
- Considered and not built: relying only on Home Manager's `linkGeneration` cleanup. Its `legacyCleanup` already deletes old-generation store links and removes emptied parents, so the explicit step is redundant on a normal switch. It stays because issue #322 requests an explicit migration and because it keeps the outcome independent of Home Manager's implementation; ordering it after `linkGeneration` removes the harm a redundant step could cause. Evidence that would change the call: Home Manager dropping its orphan cleanup, or the issue owner preferring the smaller change.
- Deferred to follow-up work: none.

### Sources

- Issue [#322](https://github.com/hyperlapse122/dotfiles/issues/322) supplies scope, preservation constraint, and acceptance.
- PR [#321](https://github.com/hyperlapse122/dotfiles/pull/321) and plan `2026-11-26-1020-refactor-reset-harness-instructions-plan.md` establish the current empty-instruction baseline and the installation this plan retires.
- `.compound-engineering/artifacts/solutions/best-practices/activation-step-grep-check-passes-an-echo-only-step.md` requires executing the step.
- `.compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md` requires asserting resolved `home.file` targets, not attribute names.
- `.compound-engineering/artifacts/solutions/best-practices/home-manager-activation-does-not-run-on-every-rebuild.md` bounds what activation can promise on NixOS.
- Home Manager's `modules/files.nix` `legacyCleanup` removes old-generation store links and empty parents, and skips paths that do not link into `*-home-manager-files`; the plan's ordering and ownership test follow it.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The migration is a dedicated `legacyInstructionGuides` activation entry ordered after `linkGeneration`.** Home Manager's `linkGeneration` already deletes old-generation store links and removes emptied parents before the new links are created. Running the explicit migration after it means Home Manager owns the normal removal, the explicit step covers whatever it leaves, and the step cannot trip Home Manager's "does not link into a Home Manager generation" warning or preempt its ownership check. Rejected: embedding the removal in `agentInstructions`, which runs after `installPackages` and therefore before `linkGeneration`; that deletes the links before Home Manager checks them, deletes a foreign symlink, and prints a misleading warning on the migration switch. Rejected: relying only on `linkGeneration`, which would drop a migration the issue explicitly requests and leave nothing of our own to exercise.
- KTD2. **Remove a legacy path only when it is a symlink whose target matches `${storeDir}/*-home-manager-files/*`; preserve anything else.** That is the same ownership test Home Manager uses. `home.file` with a `source` installs a store link, so a matching link is the owned artifact and `rm` deletes the link rather than its target. A regular file, or a symlink to a repository source, can only be a user replacement, so deleting it would destroy data the issue asks to preserve. The directory is removed with `rmdir` and its failure ignored, which succeeds only when empty. Rejected: an `-L` test alone, which deletes a user-created symlink at the owned path; unconditional `rm -f`, which deletes a user file.
- KTD3. **The check asserts resolved `home.file` targets and the activation DAG, then seeds the old state and executes the migration step twice.** A Nix-level assertion covers the resolved `target` values and the entry's `after` list; a Python run covers the filesystem effect. Rejected: asserting the activation text contains `rm`, which passes on an echoed or commented command.

### Assumptions

- Home Manager installed both guides as links into a `*-home-manager-files` store path, as `source = ./task-guide.md` implies. The current declaration and the helper's migration comment in `scripts/agent-instructions`, which replaces links rather than their targets, are the evidence.
- On a normal switch, `linkGeneration` already removes those links and the emptied directory. The explicit step is the issue's requested guarantee; running it after `linkGeneration` makes it a no-op there and a repair where Home Manager left state behind.
- A user file or a symlink outside the Home Manager files path at either guide path is out of scope for removal and keeps the legacy directory in place. The issue's "preserve unexpected user files" language covers it.
- Removing the declarations is enough to stop recreation: a new generation's `linkGeneration` has no entry to link. The runtime check proves removal, and the Nix-level check proves the declaration is gone.

---

## Implementation Units

### U1. Retire the guide declarations and add the migration step

- **Goal:** Stop declaring the installed guide copies and remove the links earlier generations left behind, after Home Manager's own cleanup.
- **Requirements:** R1, R2
- **Dependencies:** None
- **Files:** `home/h82/agents/instructions/default.nix`
- **Approach:**
  - Delete the two `home.file` entries for `.local/share/nix-config/agent-instructions/{task-guide,t3-guide}.md`. Keep the `refresh-agent-instructions` entry and the `agentInstructions` step unchanged.
  - Add a `legacyGuides` list, a `legacyGuideDirectory` constant, and a `homeManagerFilePattern = "${builtins.storeDir}/*-home-manager-files/*"` in the `let` block.
  - Add `home.activation.legacyInstructionGuides = lib.hm.dag.entryAfter [ "linkGeneration" ] ''…''`. Keep the `DRY_RUN` guard. For each legacy path, remove it only when it is a symlink and `readlink` reports a target matching `homeManagerFilePattern`; leave every other file or link in place.
  - Remove the legacy directory with `rmdir` and ignore its failure, so an unrelated file keeps the directory.
- **Patterns to follow:** The `DRY_RUN` guard and `lib.hm.dag.entryAfter` shape already in `agent-plugins.nix` and this module; the ownership test mirrors Home Manager's `legacyCleanup`; `lib.escapeShellArg` for paths if the list grows.
- **Test scenarios:**
  - A seeded home with both guide links and an unrelated `keep.md` loses both links and keeps `keep.md`; the directory remains.
  - A seeded home with only the two guide links loses both links and the empty directory.
  - A symlink at `task-guide.md` pointing at a repository source survives.
  - A regular file at `t3-guide.md` survives.
  - A second activation leaves the directory absent and recreates nothing.
  - With `DRY_RUN` set, activation removes nothing.
- **Verification:** The migration script, executed in a temporary home, produces the filesystem states above. No `home.file` entry names either destination, and the activation entry's `after` list contains `linkGeneration`.

### U2. Re-point the delivery checks at the sources and the migration

- **Goal:** Keep guide-content coverage and prove the migration through its materialized activation entry.
- **Requirements:** R3, R4, R6
- **Dependencies:** U1
- **Files:** `tests/agent-instructions.nix`, `tests/agent-instructions.py`
- **Approach:**
  - In `tests/agent-instructions.nix`, move both guide destinations into `retiredPaths` so the existing helper asserts zero resolved `home.file` targets. Drop the two positive guide assertions.
  - Assert `entry.user.home.activation.legacyInstructionGuides.after` contains `linkGeneration`, and carry its `data` in the manifest as `cleanup`. Remove the `guides` field.
  - Pass the two source paths from `home/h82/agents/instructions/` to `tests/agent-instructions.py` as arguments.
  - In `tests/agent-instructions.py`, read `task-guide.md` and `t3-guide.md` from the repository sources for the passage and retired-wording checks, replacing reads from the materialized guide directory.
  - In the per-entry loop, seed the legacy directory with links whose targets are existing `*-home-manager-files` paths from the entry's `git` manifest value, plus an unrelated `keep.md`. Run the cleanup script, then the delivery activation, and assert the links are gone while `keep.md` survives and the native destinations stay regular and empty. Delete `keep.md`, run cleanup twice, and assert the directory stays absent.
  - Add the foreign-symlink and regular-file preservation scenarios: seed a link to a repository source and a regular file at the guide paths, run cleanup, and assert both survive.
- **Patterns to follow:** `tests/agent-instructions.py` already creates a temporary home per entry and runs `entry['activation']` with `bash -eu`. `tests/agent-instructions.nix` already expresses retired destinations as `target`-based absences and reads activation metadata from the user configuration.
- **Test scenarios:**
  - Zero `home.file` entries resolve to either legacy target, `refresh-agent-instructions` still resolves to one, and the migration entry's `after` list names `linkGeneration`.
  - Source content contains the checked passages and lacks the retired T3 wording.
  - Seeded store links are removed; an unrelated file survives; the directory disappears only after the unrelated file is gone.
  - A foreign symlink and a regular file at guide paths survive with their content unchanged.
  - The native destination files remain regular zero-byte files after the same activation.
- **Verification:** `nix build --no-link .#checks.x86_64-linux.agent-instructions` passes. Mutation rounds fail: re-adding one `home.file` guide declaration fails the Nix assertion; removing `linkGeneration` from the entry's `after` list fails the ordering assertion; deleting the removal block fails the seeded-home scenario; widening the ownership test to any symlink fails the foreign-symlink scenario.

### U3. Update the guide documentation

- **Goal:** Remove the claim that Home Manager installs the guides and record the migration.
- **Requirements:** R5
- **Dependencies:** U1
- **Files:** `docs/agent-routing.md`, `docs/contributing.md`, `README.md`
- **Approach:**
  - In `docs/agent-routing.md`'s `## T3 task guidance` section, keep the links and coverage descriptions. Replace both installation claims — the sentence naming the Home Manager destination and the clause saying the task guide is installed beside it — with one sentence stating that both guides live only in the checkout, that activation removes the copies earlier generations installed at `~/.local/share/nix-config/agent-instructions/`, and that unrelated files under that directory are left alone.
  - In Contributing's user-scope instruction rule, replace "the installed guides" with the repository sources under `home/h82/agents/instructions/`. Leave the tool-retirement rule untouched; the issue is the explicit authorization it requires.
  - In `README.md`'s T3 Code bullet, replace "the installed task guides" with the repository sources under `home/h82/agents/instructions/`. Leave the shared guides/skills sentence on the following bullet alone; it describes pinned skill packs, not these files.
- **Patterns to follow:** The compact present-tense style of the surrounding routing document.
- **Test scenarios:** None — documentation only. Markdown lint runs through `agent-check`.
- **Verification:** `rg -n 'nix-config/agent-instructions|installed ((task|T3) )?guides?' docs *.md` returns only the migration description in `docs/agent-routing.md`; no current doc claims an installed guide copy.

---

## Verification Contract

| Command | Proves | Units |
| --- | --- | --- |
| `nix build --no-link .#checks.x86_64-linux.agent-instructions` | Resolved `home.file` targets, activation ordering, source-based content checks, removal, preservation, repeat activation | U1, U2 |
| `nix develop .#agent-check -c ./scripts/agent-check` | Nix formatting and Markdown lint for the changed files | U2, U3 |
| `nix fmt -- --ci` | Formatting parity with CI | U1, U2 |
| Four mutation rounds from U2 | The new assertions fail when their behavior breaks | U2 |

Darwin execution of the same check comes from `tests/darwin-outputs.nix` importing the module, but it builds only on `aarch64-darwin`. Local Linux evidence does not establish it; CI's `build-darwin` job covers it.

## Definition of Done

- No `home.file` declaration names either legacy guide, and both guides remain in `home/h82/agents/instructions/`.
- Activation removes the two installed store links from a seeded home and removes the directory only when empty. It runs after `linkGeneration`, and unrelated files, foreign symlinks, and other `~/.local/share/nix-config/` paths are untouched.
- Guide-content checks read the repository sources; the delivery check asserts the activation ordering and executes the migration to prove removal, preservation, and repeat activation.
- Documentation in `docs/agent-routing.md`, `docs/contributing.md`, and `README.md` points to the sources, and routing names the migration.
- `agent-check` and the `agent-instructions` check pass on the change. The four mutation rounds were observed red.
- Abandoned experiments and temporary scratch files are removed.
