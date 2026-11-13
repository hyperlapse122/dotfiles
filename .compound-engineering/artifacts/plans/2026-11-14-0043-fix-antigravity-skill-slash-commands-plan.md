---
title: "Skills in the T3 Code Antigravity Slash Menu - Plan"
type: fix
date: 2026-11-14
topic: antigravity-skill-slash-commands
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Skills in the T3 Code Antigravity Slash Menu - Plan

## Goal Capsule

- **Objective:** In a T3 Code session on the `antigravity` provider instance, the owner finds the Compound Engineering skills in the composer's `/` menu beside the skills already listed there, and can start one from it.
- **Means:** Home Manager links every pinned plugin skill into the Antigravity skill root, the directory T3 Code already scans for Antigravity skills (KTD1).
- **Authority:** The Product Contract below, then the repository safeguards in `AGENTS.md`, then the Planning Contract.
- **Execution profile:** Two units in one PR. The implementer builds and verifies in the repository; the owner runs the production switch and the checks in T3 Code.
- **Stop conditions:** Stop if a fix would need an agent to run `darwin-rebuild switch`, `nixos-rebuild switch`, or `nr switch`, or if linking a plugin skill into the root makes Home Manager evaluation or `checkLinkTargets` fail in a way KTD3 does not cover.
- **Open blockers:** None.

---

## Product Contract

Product Contract preservation: changed: R2, R3, R5, R7, R8, R10 and the first Key Decision — planning research showed that T3 Code builds the Antigravity skill menu from its own scan of the skill directories, not from commands the runtime advertises, so the owner replaced the runtime approach with linking plugin skills where T3 Code scans. R2 and R7 now ask for evidence about the user-only skills instead of a guarantee; R3, R5, R8, and R10 described runtime behavior this work no longer adds and are removed. R1, R4, R6, R9, R11, R12, and R13 keep their meaning.

### Summary

Home Manager links every skill of every pinned plugin into the Antigravity skill root.
T3 Code then lists the Compound Engineering skills in an Antigravity session's `/` menu the same way it already lists the shared and Xcode skills.
The Antigravity ACP runtime rebuild is unchanged.

### Problem Frame

T3 Code 0.1.9 fills the Antigravity skill menu from files.
It scans `~/.gemini/config/skills` and `~/.gemini/antigravity-cli/skills` in the user's home, and `.gemini/skills`, `.agents/skills`, and `.agent/skills` in the workspace.
It also links the instance home's two skill directories to the ones in `~/.gemini`, which is why a session's model sees the shared and Xcode skills.

The Compound Engineering skills are in none of those directories.
This repository hands them to the rebuilt runtime as one store directory named by `ANTIGRAVITY_ACP_PLUGIN_SKILLS`, and the `agy` CLI gets them from its native plugin install.
A signed-in probe on 2026-11-14 confirmed the result: the session's model lists `ce-plan` and reads `ce-noslop/SKILL.md` from that store directory, while T3 Code's scan has no path that reaches them.
The owner cannot start `/ce-plan` or `/lfg` from the menu as they do in Claude Code or Codex sessions.

Nine plugin skills set `disable-model-invocation`: `ce-dogfood`, `ce-help`, `ce-polish`, `ce-product-pulse`, `ce-promote`, `ce-retune`, `ce-sweep`, `ce-test-xcode`, and `wtf`.
The session's model does not list them, so today nothing in an Antigravity session offers them.

### Key Decisions

- **Put plugin skills where T3 Code already looks; add no runtime behavior.** Governs R1, R6. (session-settled: user-directed — chosen over having the rebuilt runtime advertise skills as slash commands and rewrite `/<name>` prompts, and over adding that prompt handling for the nine user-only skills now: T3 Code already lists skills from files, runtime advertisement would list the shared and Xcode skills a second time, and whether the nine need prompt handling is unknown until they are tried)
- **Cover every pinned plugin, not only Compound Engineering.** A later plugin's skills reach the menu with no Antigravity-specific work. Governs R1. (session-settled: user-directed — chosen over Compound Engineering plugin skills only: the owner wants the same set as every other harness)
- **Report what the nine user-only skills do; do not promise it.** Governs R2, R7. (session-settled: user-approved — chosen over guaranteeing they run: T3 Code's Antigravity scan reads only `name` and `description`, so they should be listed, but whether a picked one runs can only be seen in a signed-in session)
- **The change applies on both hosts.** Governs R9. (session-settled: user-approved — chosen over a macOS-only or T3 Code-only switch: one behavior is simpler to check)

### Requirements

**Menu contents**

- R1. The `/` menu of a T3 Code Antigravity session lists every skill of every pinned plugin, beside the shared skills, the Xcode skills on macOS, and the workspace's skills that it lists today.
- R2. The owner learns from this work whether the menu lists the skills that set `disable-model-invocation`.
- R4. Each entry shows the skill's name and the description from its `SKILL.md`.
- R6. Each skill appears once in the menu and once in the session model's own skill list.

**Running a picked skill**

- R7. A plugin skill picked from the menu runs in the session. For the skills R2 names, the owner learns whether a picked one runs.

**Reach**

- R9. The behavior applies on both hosts, and a plugin added to the pinned sources reaches the menu without further Antigravity work.

**Evidence**

- R11. A repository check proves that every plugin skill is linked into the Antigravity skill root and resolves to its plugin source, with a mutation that fails it.
- R12. A signed-in T3 Code session on the macOS host shows the plugin skills in the `/` menu and runs a picked one; this evidence is reported apart from the repository checks.
- R13. `docs/agent-routing.md`, `AGENTS.md`, and `CONCEPTS.md` describe where plugin skills reach Antigravity, wherever they describe it today.

### Key Flows

- F1. Run a skill from the menu
  - **Trigger:** The owner types `/` in the composer of a T3 Code Antigravity thread.
  - **Steps:** The menu lists the plugin skills beside the skills it listed before. The owner picks `ce-plan` and adds a request. The session reads `ce-plan/SKILL.md` and follows it with that request.
  - **Covered by:** R1, R4, R7

### Acceptance Examples

- AE1. **Covers R1, R7.** Given a production switch has run and a new T3 Code Antigravity thread is open in this repository, when the owner picks `ce-plan` from the `/` menu and adds `add a check`, then the session loads the `ce-plan` skill with that request.
- AE2. **Covers R2, R7.** Given the same thread, when the owner opens the `/` menu and tries `ce-polish`, then the owner records whether it is listed and whether it runs.
- AE3. **Covers R1.** Given the same thread, when the owner opens the `/` menu, then `humanizer` and `modern-web-guidance` are still listed.
- AE4. **Covers R6.** Given plugin skills are linked into the skill root and also handed to the runtime as a store directory, when the session's model lists its skills, then `ce-plan` appears once.
- AE5. **Covers R9.** Given a second plugin with one skill joins the pinned sources, when the configuration is evaluated, then that skill is linked into the Antigravity skill root.

### Scope Boundaries

- The rebuilt Antigravity ACP runtime, its overlays, and its wrapper are unchanged. The runtime advertises no skill as a command and rewrites no prompt.
- T3 Code is not patched.
- The `agy` CLI keeps its native plugin install, as `AGENTS.md` requires.
- Hiding a skill that forbids user invocation is out of scope: T3 Code's Antigravity scan does not read that flag, and no pinned skill sets it.
- Making the nine user-only skills run when the evidence shows they do not is later work, decided after R2 and R7 report.
- The T3-only instruction branch still does not reach Antigravity sessions.

### Dependencies / Assumptions

- T3 Code 0.1.9 scans the five directories the Problem Frame names and keeps the first skill it finds for each name. This was read in the installed bundle; R12 confirms it in the composer.
- T3 Code links `<instance home>/config/skills` and `<instance home>/antigravity-cli/skills` to the same directories under `~/.gemini`. Both links exist on the macOS host.
- Runtime 1.4.5 lists a skill once when two of its skill directories hold the name, and the first directory wins. A signed-in probe on 2026-11-14 showed this with `ce-noslop` linked into the skill root and present in the store directory: one entry, read from the store directory, and an unchanged total of 65.
- On the macOS host, `agy` CLI 1.5.8 moved `~/.gemini/antigravity-cli/skills` to `~/.gemini/config/skills` on 2026-11-14 and left a symlink behind. Home Manager's links now land in `config/skills` through that symlink.

### Sources / Research

- T3 Code 0.1.9 bundle, `src/provider/Drivers/AntigravitySkills.ts`: `discoverAntigravitySkills` and `linkAntigravityUserSkills`, the scan and the instance-home links.
- `home/h82/agents/skills.nix`, `home/h82/agents/plugin-skills.nix`: the skill roots, the plugin skill enumeration, and the store directory the wrapper receives.
- `home/h82/agents/xcode-skills.nix`: the activation entries that link Xcode skills into the roots around declared names.
- `tests/antigravity-skills.nix`: the check that today requires plugin skills to stay out of `~/.gemini/antigravity-cli/skills`.
- `packages/antigravity-acp-path.nix`, `packages/antigravity-acp-overlay/paths_overlay.py`: the runtime's plugin skills directory, which this work leaves in place.
- `.compound-engineering/artifacts/solutions/integration-issues/antigravity-acp-runtime-loads-no-global-rule-files.md`: the signed-in probe method.
- `.compound-engineering/artifacts/plans/2026-11-11-1004-feat-antigravity-first-tier-harness-plan.md`: the plan that kept plugin skills out of the skill root so the CLI would list each once.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`home/h82/agents/skills.nix` declares one `home.file` link per plugin skill under the Antigravity skill root, and under no other root.** Implements R1, R4, R9. The other harnesses load plugin skills through their own plugin install, so only Antigravity gains links. Each link targets the skill directory in the plugin source, the same shape the shared skills have, so `SKILL.md` is a regular file. The links come from the `plugin.skills` enumeration the store directory already uses, so a new plugin needs no further code.
- KTD2. **The runtime's plugin skills directory stays.** Implements R6. Compound Engineering's run homes read skills only from their own `GEMINI_HOME`, and the wrapper links only the shared names there, so the store directory is still how plugin skills reach those runs. In a T3 Code session both sources now hold the plugin names, and the runtime lists each once.
- KTD3. **The Xcode release entry receives the plugin skill names as well as the shared ones.** Implements R1. An exported Xcode skill that shares a plugin skill's name would otherwise sit at the link target as a foreign symlink, and `checkLinkTargets` would stop activation. The helper releases a name in every root; the install entry then links it again wherever the name is free.
- KTD4. **`tests/antigravity-skills.nix` reverses its disjointness assertion.** Implements R11. It reads the materialized `home.file` targets and requires, for every plugin skill, a link under `.gemini/antigravity-cli/skills/` whose source is that skill's directory in the plugin source. It keeps the assertion that the store directory holds exactly the plugin skills.
- KTD5. **The CLI keeps its plugin install and may now reach a plugin skill through both the plugin and the skill root.** `AGENTS.md` requires the native install, so it is not removed. The CLI is not signed in on the macOS host, so its listing cannot be observed there; the Verification Contract carries the check for a signed-in CLI.

### Assumptions

- Home Manager creates and replaces a link whose parent directory is a symlink, which is what `~/.gemini/antigravity-cli/skills` is on the macOS host since the CLI's migration. The first production switch after that migration is the evidence, for the shared skills as much as for the new links.
- The `agy` CLI lists a skill once when a plugin and the skill root both provide it, as the ACP runtime does. If it lists the skill twice, the owner decides between accepting that and dropping the CLI's plugin install, which needs a change to the `AGENTS.md` rule.
- T3 Code inserts a picked Antigravity skill into the prompt in a form the session's model acts on, as it does for the shared skills today.

### Sequencing

U1 first. U2 documents the result.

---

## Implementation Units

### U1. Plugin skills in the Antigravity skill root

- **Goal:** Every plugin skill is linked into the Antigravity skill root, the Xcode step yields those names, and the check proves the links.
- **Requirements:** R1, R4, R6, R9, R11; KTD1 through KTD4.
- **Dependencies:** None.
- **Files:** `home/h82/agents/skills.nix`, `home/h82/agents/xcode-skills.nix`, `tests/antigravity-skills.nix`.
- **Approach:**
  1. Add the plugin skill links to `config.home.file` under the Antigravity root, from the existing `pluginSkills` value.
  2. Expose the names the Antigravity root declares, shared and plugin, so `xcode-skills.nix` passes them to the release entry.
  3. Correct the comments in `skills.nix` that say plugin skills stay out of the roots and that `~/.gemini/config/skills` is not read.
  4. Replace the disjointness assertion in the check as KTD4 states, and extend the second-plugin case to the links.
- **Patterns to follow:** the shared skill links in `home/h82/agents/skills.nix`; the `sharedTargets` reading of `home.file` in `tests/antigravity-skills.nix`.
- **Execution note:** Change the check first and watch it fail on the current module. Before trusting it, read the mutation-testing learnings `AGENTS.md` lists under "Before adding a repository check", in particular the materialized-output and converged-fixture entries.
- **Test scenarios:**
  - Covers AE4, R11. For every host entry, each plugin skill name has a `home.file` target under `.gemini/antigravity-cli/skills/` whose source equals that skill's directory in the pinned plugin source.
  - No plugin skill name has a `home.file` target under `.claude/skills`, `.codex/skills`, `.grok/skills`, or `.pi/agent/skills`.
  - The shared skills are still linked into the Antigravity root, and the store directory still holds exactly the plugin skills.
  - Covers AE5. With the second-plugin fixture added to the sources, `second-skill` is among the names the root declares.
  - A plugin skill named like a shared skill still stops evaluation.
  - On a macOS production entry, the release activation entry names a plugin skill and a shared skill.
- **Verification:** The check passes, and each scenario fails when its behavior is removed: the links dropped, the links added to every root, the source pointed at the store directory's link, the plugin names withheld from the release entry.

### U2. Documentation

- **Goal:** The repository's documents say where plugin skills reach Antigravity.
- **Requirements:** R13.
- **Dependencies:** U1.
- **Files:** `AGENTS.md`, `docs/agent-routing.md`, `CONCEPTS.md`, `.compound-engineering/artifacts/solutions/integration-issues/antigravity-acp-runtime-loads-no-global-rule-files.md`.
- **Approach:**
  1. In `AGENTS.md`, the harness plugin and skill integration section states that plugin skills are also linked into the Antigravity skill root, which is what T3 Code's skill menu reads.
  2. In `docs/agent-routing.md`, the Antigravity sentence says the same.
  3. In `CONCEPTS.md`, refine the skill root entry only where it now misstates Antigravity.
  4. In the solution document, correct the sentence that says plugin skills come only from the store directory.
- **Test scenarios:** Test expectation: none -- documentation. The `agent-instructions` check takes `AGENTS.md`, `CONCEPTS.md`, and `docs/agent-routing.md` as inputs and must still pass.
- **Verification:** `markdownlint-cli2` passes on the changed files and the `agent-instructions` check inputs evaluate.

---

## Verification Contract

| Check | Command | Proves | Where |
| --- | --- | --- | --- |
| Plugin skill links | `checks.x86_64-linux.antigravity-skills` | U1 scenarios | CI light shard |
| Instruction inputs | `checks.x86_64-linux.agent-instructions` | U2 keeps the check inputs valid | CI light shard |
| Linux-only inputs from macOS | `nix derivation show` on the two `x86_64-linux` checks above | their text inputs evaluate with the change | macOS builder |
| macOS configuration | `nix build --no-link .#checks.aarch64-darwin.darwin-config` and `.#checks.aarch64-darwin.darwin-outputs` | the Home Manager generation builds with the new links | macOS builder |
| Declared macOS checks | `nix flake check` | `checks.aarch64-darwin` has no regression | macOS builder |
| Text hygiene | `git diff --check` and `markdownlint-cli2` on changed Markdown | formatting | local |
| Formatting | `nix fmt -- --ci` | Nix layout | CI `fmt` job; `formatter.aarch64-darwin` is absent |
| Linux and closure jobs | `host-checks`, `vm-checks`, `build`, `build-darwin` under the `full-ci` label | every production and bootstrap output | CI |
| Mac evidence | the owner runs a production switch, opens a new T3 Code Antigravity thread, and confirms `ce-plan` in the `/` menu, a picked `ce-plan` running, `humanizer` still listed, and what `ce-polish` does | AE1, AE2, AE3, R12, the Home Manager assumption | owner, reported separately |
| CLI listing | on a host with a signed-in `agy` CLI, the owner asks it to list its skills and counts `ce-plan` | KTD5's assumption | owner, reported separately |

Every check except `darwin-config` and `darwin-outputs` is `x86_64-linux`. Follow `.compound-engineering/artifacts/solutions/best-practices/verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md` for the `nix derivation show` row. A Linux check that has not run is deferred to CI, never passed.

## Definition of Done

- U1 and U2 are implemented and their verification outcomes hold.
- Every row of the Verification Contract that a macOS builder can run has passed locally; rows deferred to CI or to the owner are reported as deferred, not passed.
- The runtime rebuild, its overlays, and the wrapper are untouched in the diff.
- No abandoned experiment, unused option, or test-only production seam remains in the diff.
- The PR body lists what was verified locally, what waits on CI, the Mac evidence the owner still has to collect, and the CLI's skills-directory migration found on 2026-11-14.
