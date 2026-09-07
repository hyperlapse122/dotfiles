---
title: Drop the tmux rule from the instruction core - Plan
type: docs
date: 2026-09-07
topic: drop-tmux-instruction-rule
origin: https://github.com/hyperlapse122/dotfiles/issues/414
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Drop the tmux rule from the instruction core - Plan

## Goal Capsule

- **Objective:** An agent working on any managed harness no longer receives an instruction telling it to run long-lived processes under tmux, so it picks a way to run them that fits the environment it is actually in — including a worker pod with no interactive session.
- **Means:** Delete the single rule line from the shared instruction template and retire it in the CI pin that guards that template (KTD1, KTD2).
- **Authority hierarchy:** The R-IDs own what must be true after the change. KTD1 and KTD2 own the removal mechanism and the CI-gate treatment. `AGENTS.md` owns the standing repository rules the change must obey.
- **Stop conditions:** Stop and report if `.ci/test-agent-instructions.sh` cannot express a retired rule as a negative needle, or if the rendered instruction output diverges between harness wrappers after the edit.
- **Execution profile:** A two-file text change proved by the repository's own render gate. No host apply, no runtime behavior to exercise.
- **Tail ownership:** The pipeline owns commit, push, PR, and CI.

---

## Product Contract

### Summary

Remove `- Use tmux or an interactive shell for servers, watches, TUIs, and REPLs.` from `.chezmoitemplates/agents-instructions.tmpl`, and move its verbatim text from the positive-needle list to the negative-needle list in `.ci/test-agent-instructions.sh` so the rule cannot return.

### Problem Frame

The rule is not followed in practice, yet it is rendered into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.gemini/AGENTS.md`, so every agent session on every harness pays context for it. It also assumes a host with an interactive session to attach to. That assumption is false in an Orca per-workspace worker pod (issue #413), where tmux was present in the image only because this line required it. Inside its own section the line is the odd one out: every other entry is a MUST NOT or a hard constraint about credentials, history rewriting, or the container runtime, while this one is a workflow preference.

### Key Decisions

- **Remove the rule outright, with no replacement or conditional variant.** Restating it for interactive hosts would preserve wording nobody acts on. (session-settled: user-directed — chosen over keeping a reworded or host-conditional version of the rule: the rule is not followed in practice.) Governs R1, R2.
- **Retire the instruction, not tmux itself.** The host still uses tmux, so the tool's configuration and provisioning stay. (session-settled: user-directed — chosen over also removing tmux from host provisioning in this change: whether the host wants tmux is a separate decision.) Governs R4.

### Requirements

**Instruction core**

- R1. The rendered instruction output contains no line instructing an agent to use tmux or an interactive shell for servers, watches, TUIs, or REPLs.
- R2. No replacement rule, conditional or otherwise, takes the removed line's place; the surrounding rules in the "Secrets, destructive actions, and runtime" list are unchanged.

**CI gate**

- R3. `.ci/test-agent-instructions.sh` passes against the rendered output after the removal, and fails if the removed line is reintroduced into the template.

**Untouched surfaces**

- R4. `dot_config/tmux/tmux.conf`, the `20-base` tmux package installs, the aoe `default_attach_mode` setting, and the `agents.aoe.config.toml.tmux` keys in `.chezmoidata/agents.yaml` are unchanged.

### Scope Boundaries

- Whether the host still wants tmux itself is out of scope. `dot_config/tmux/tmux.conf` and the `20-base` package install both stay.
- `.chezmoidata/agents.yaml:110` is the aoe `tmux.status_bar` / `tmux.clipboard` configuration block. It configures aoe's own tmux integration and has no link to the instruction rule, so it is out of scope.
- The Orca worker image change that motivated this issue lives in #413 and is not part of this change.

### Sources

- Issue: https://github.com/hyperlapse122/dotfiles/issues/414
- Rule text: `.chezmoitemplates/agents-instructions.tmpl:29`
- Pin: `.ci/test-agent-instructions.sh:72`, inside the `NEEDLES` heredoc
- Gate invocation: `.github/workflows/ci.yml:71`

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Delete the whole list item, not just the tmux clause.** The line's remaining half ("or an interactive shell") carries the same unfollowed preference, and R2 forbids a replacement. (session-settled: user-directed — chosen over keeping a reworded or host-conditional version of the rule: the rule is not followed in practice.) Governs R1, R2.
- KTD2. **Move the pinned text from `NEEDLES` to `BANNED` rather than deleting it from the gate.** The script already keeps two lists: positive needles for rules an agent must still receive, and negative needles that prevent retired instruction mandates from returning. A retired rule belongs in the second list; deleting the pin outright would let the line reappear unnoticed. Governs R3.

### Assumptions

- The `BANNED` list's `grep -F` match is exact and case-sensitive, so the entry must carry the line's text verbatim, without the leading `- ` list marker — matching how the `NEEDLES` entry is written today.
- The gate renders through `chezmoi`, so local verification requires `chezmoi` on `PATH`. It is present on this host.

### Sequencing

U1 then U2. The gate change must land in the same commit as the template edit, because the current `NEEDLES` entry fails the moment the template line is gone.

---

## Implementation Units

### U1. Remove the rule from the instruction template

- **Goal:** The shared instruction core no longer carries the tmux rule.
- **Requirements:** R1, R2 (per KTD1).
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`
- **Approach:** Delete the single list item at line 29. Leave the git-config prohibition above it and the rootless Podman rule below it untouched, and do not reflow or re-order the remaining bullets.
- **Patterns to follow:** The surrounding bullets in the "Secrets, destructive actions, and runtime" list.
- **Test scenarios:** Test expectation: none -- prose removal with no behavior; U2's gate covers the rendered result.
- **Verification:** The phrase no longer appears anywhere in the template, and the section's other bullets are byte-identical to before.

### U2. Retire the pinned rule in the CI render gate

- **Goal:** The gate stops requiring the removed line and starts rejecting its return.
- **Requirements:** R3 (per KTD2).
- **Dependencies:** U1.
- **Files:** `.ci/test-agent-instructions.sh`
- **Approach:**
  1. Remove the entry from the `NEEDLES` heredoc.
  2. Add the same verbatim text to the `BANNED` heredoc.
- **Patterns to follow:** The existing `BANNED` entries, which carry retired instruction text with no list marker or trailing punctuation changes.
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh` exits 0 against the post-U1 template.
  - Restoring the removed line to the template makes the script fail with `retired instruction reintroduced: Use tmux or an interactive shell for servers, watches, TUIs, and REPLs.`; revert the restoration afterwards.
  - The three harness wrapper renders still compare byte-identical, so the gate's `cmp` assertion is unaffected.
- **Verification:** The gate passes on the change and fails on a reintroduction.

---

## Verification Contract

| Gate | Command | Applies to | Done signal |
|---|---|---|---|
| Instruction render gate | `.ci/test-agent-instructions.sh` | U1, U2 | Exits 0 with no `lost rule` or `retired instruction reintroduced` failure |
| Reintroduction proof | Re-add the line to the template, rerun the gate, then revert | U2 | The gate fails naming the banned line, and the revert restores a passing run |
| Untouched-surface check | `git status --porcelain` | R4 | Only `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, and this plan document under `docs/plans/` appear |

CI runs the same gate from `.github/workflows/ci.yml:71`.

---

## Definition of Done

- The tmux rule is gone from `.chezmoitemplates/agents-instructions.tmpl` with no replacement text (R1, R2).
- The rule's verbatim text sits in `.ci/test-agent-instructions.sh`'s `BANNED` list and no longer in `NEEDLES` (R3).
- `.ci/test-agent-instructions.sh` passes locally, and fails when the line is reintroduced.
- No file other than `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, and this plan document under `docs/plans/` is added or modified (R4).
- No experimental or dead-end edits remain in the diff.
- The PR body closes issue #414.
