---
title: Agent Conversation and Artifact Language Rules - Plan
type: feat
date: 2026-11-15
topic: agent-language-rules
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Agent Conversation and Artifact Language Rules - Plan

## Goal Capsule

- **Objective:** Whichever managed coding agent the owner uses, it talks to the owner in Korean and writes persistent artifacts in English, unless an instruction or the existing content calls for another language.
- **Means:** One language section in the common branch of the shared instruction template, with the conversation rule gated off for Claude Code (KTD1).
- **Product authority:** This Product Contract; the owner confirmed the scope in the brainstorm dialogue. Product Contract unchanged by planning.
- **Execution profile:** One PR. Template, test receipts, and routing doc change together because the receipts pin the rendered bytes.
- **Stop conditions:** Stop if the rendered Claude Code file would still contain the conversation rule, or if another harness's render would lose it.
- **Open blockers:** None.

---

## Product Contract

### Summary

The shared user-scope instructions gain one language section with two rules. The conversation rule makes Korean the default language for talking to the owner and is left out of Claude Code's rendering, because Claude Code's own `language` setting already supplies it. The artifact rule makes English the default for persistent output in every managed harness, unless a conversation instruction, a project instruction, or the language of the existing content says otherwise.

### Problem Frame

Only Claude Code has a fixed conversation language today: its settings tier declares `language = "korean"`. Codex, Pi, Grok Build, and Antigravity have none, so the language of a reply depends on the model and the prompt. No harness has a stated default for artifacts either. Claude Code's language setting even asks for code comments in Korean, while this repository and the owner's other projects expect English documentation. The result is inconsistent output across harnesses and between conversation and files.

### Key Decisions

- **Project context includes the language of existing content, not only explicit instructions.** An edited file keeps its language, and new files and commit messages follow the repository's predominant language. Governs R5. (session-settled: user-directed — chosen over honoring only explicit project instructions, and over following only the edited file while new files stay English: existing Korean documents and Korean commit histories should not be switched to English silently)
- **Claude Code gets the artifact rule but not the conversation rule, in CLI and T3 Code sessions alike.** Its `language` setting reaches both session kinds, and a second conversation rule would only duplicate it. Governs R3, R6. (session-settled: user-approved — chosen over rendering the conversation rule for every harness: the owner excluded Claude Code because its settings already inject the language)
- **The language the owner writes in is not a language instruction.** An English message still gets a Korean reply, matching Claude Code's behavior. Governs R2. (session-settled: user-approved — chosen over mirroring the language of each message: keeps every harness consistent with Claude Code)
- **Code comments are artifacts, and the artifact rule wins over a harness's conversation-language setting.** Without this, Claude Code's setting would keep producing Korean comments. Governs R4, R6. (session-settled: user-approved — chosen over leaving comments to each harness's language setting: the owner wants English artifacts by default)

### Requirements

**Conversation language**

- R1. Agents converse with the owner in Korean unless a conversation or project instruction names another conversation language.
- R2. The conversation rule covers every message addressed to the owner, including questions, progress notes, answers, and final reports; the language of the owner's own message does not count as an instruction.
- R3. Claude Code's rendered instructions omit the conversation rule; the other managed harnesses (Codex, Pi, Grok Build, Antigravity) receive it.

**Artifact language**

- R4. Artifacts are persistent output: documents, code comments and docstrings, commit messages, PR descriptions, issues, and user-facing strings in code.
- R5. An artifact's language is chosen by the first source that applies: a language instruction in the conversation, a language instruction in the project's instructions, the language of the existing content being edited (for new files and commit messages, the repository's predominant language), and otherwise English.
- R6. Every managed harness, Claude Code included, receives the artifact rule, and for artifacts it takes precedence over a harness's conversation-language setting.

**Delivery**

- R7. The rules live once in the common branch of the shared instruction template, so each harness receives them through its native baseline path in both CLI and T3 Code sessions.

### Acceptance Examples

- AE1. **Covers R1, R2.** Given a Codex session with no language instruction, when the owner asks a question in English, the agent answers in Korean.
- AE2. **Covers R5.** Given a repository with no language instruction and a Korean README, when the agent edits that README, it writes the edit in Korean.
- AE3. **Covers R5.** Given a repository with no language instruction and an English commit history, when the owner, writing in Korean, asks for a commit, the commit message is in English.
- AE4. **Covers R4, R6.** Given a Claude Code session with `language = "korean"`, when the agent adds a code comment in a repository with no language instruction and English code, the comment is in English.
- AE5. **Covers R5.** Given the owner says "write this PR description in Korean", the PR description is in Korean regardless of the repository's language.
- AE6. **Covers R3.** Claude Code's rendered instruction file contains the artifact rule and no conversation rule; Codex's contains both.

### Scope Boundaries

- Text exchanged only between agents, such as delegation briefs and the reports a subagent returns to its caller, is covered by neither rule.
- The existing Writing skills section stays as it is; it already chooses skills by the language of the text.
- Claude Code's `language` setting stays as declared.
- No T3-only copy of the rules; the T3 branch carries only T3-specific additions.

### Sources / Research

- `home/h82/agents/instructions/instructions.md.tmpl`: the shared template, with the T3-only branch and the common branch.
- `home/h82/agents/claude.nix`: declares `language = "korean"` in Claude Code's settings tier.
- `AGENTS.md` "User-scope harness instructions": a template change updates the receipt hashes in `tests/agent-instructions.py` and keeps `docs/agent-routing.md` aligned.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Gate the conversation rule with `{{ if not .claude }}` inside one shared `# Language` section.** `scripts/agent-instructions` renders each delivery with every harness flag set to a boolean (`flags = {name: name == delivery ...}`), so `.claude` always exists in the common branch and the gate cannot trip `missingkey`. The T3 branch never reaches the section. Governs R3, R7.
- KTD2. **Place the section directly after `# Writing skills`.** Both concern the language of output, and keeping the section before the container sections leaves the Antigravity rule-file packing by top-level section unaffected in practice. Governs R7.
- KTD3. **Split the receipt table in `tests/agent-instructions.py` by harness group.** Today one hash per host kind must match all five renders. After KTD1, the Claude render differs, so the table gains `darwin-claude` and `nixos-claude` entries, and the receipt lookup takes the harness into account. The exact-bytes receipts then prove AE6: Claude's body omits the conversation rule and the other four include it. Governs R3, R6.

### Assumptions

- The Claude Code `language` setting keeps reaching T3 Code Claude sessions through `~/.claude/settings.json`; this session's system prompt shows it does today.

---

## Implementation Units

### U1. Add the language section and update its receipts

- **Goal:** The shared template renders the conversation rule for Codex, Pi, Grok Build, and Antigravity, and the artifact rule for all five harnesses.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7 (Key Decisions governing R2–R6 carry the session-settled labels).
- **Dependencies:** None.
- **Files:**
  - `home/h82/agents/instructions/instructions.md.tmpl`
  - `tests/agent-instructions.py`
- **Approach:**
  1. Add a `# Language` section after `# Writing skills` in the common branch (KTD2).
  2. Wrap the conversation paragraph in `{{ if not .claude -}} … {{ end -}}` (KTD1); its text states R1 and R2.
  3. Follow it with the unconditional artifact paragraph stating R4, R5, and R6, including that the rule wins over a harness's conversation-language setting for artifacts.
  4. Render each host kind and harness group, then record the new hashes in `EXPECTED` with the harness-aware lookup (KTD3), covering the `exercise` loop and the activation loop in `main`.
- **Patterns to follow:** Existing `{{ if eq .kind "darwin" }}` gating in the same template; the existing `check_receipt` mutation probes.
- **Test scenarios:**
  - Covers AE6. A Claude Code render for each host kind matches its `-claude` receipt, and the Codex, Grok, Pi, and Antigravity renders match the shared receipt.
  - A template mutation that drops `not` from the gate fails both receipt groups.
  - The T3 render still contains `T3 delegation`, lacks `Writing skills`, and keeps its unchanged `t3` receipt.
  - The branch-isolation probe still finds each `<harness>-only` marker only in its own render.
  - Seam: receipts catch any byte change in the rendered policy, but they cannot show that a running agent obeys it; AE1–AE5 are behavioral and fall to hardware checks.
- **Verification:** The `agent-instructions` check passes with the new receipts, and a manual read of the rendered Claude and Codex files shows the expected sections.

### U2. Align the routing document

- **Goal:** `docs/agent-routing.md` lists the language rules among the shared rules and says Claude Code's conversation language comes from its settings.
- **Requirements:** R3, R7.
- **Dependencies:** U1.
- **Files:** `docs/agent-routing.md`
- **Approach:** Extend the opening sentence that enumerates shared rules, and add one sentence on the Claude Code exception. The `agent-instructions` check reads this file, so it reruns with U1.
- **Test expectation:** none -- documentation; covered by the `agent-instructions` check run and markdown lint.
- **Verification:** `markdownlint-cli2` passes on the changed file.

---

## Verification Contract

| Gate | Command | Applies to |
| --- | --- | --- |
| Instruction receipts | `nix build --no-link .#checks.x86_64-linux.agent-instructions` | U1, U2 |
| Markdown lint | `markdownlint-cli2 docs/agent-routing.md .compound-engineering/artifacts/plans/2026-11-15-2309-feat-agent-language-rules-plan.md` | U2, plan |
| Whitespace | `git diff --check` | all |
| Full CI | `full-ci` label: `host-checks`, `vm-checks`, `build`, `build-darwin` on the PR head | PR readiness |

Darwin receipts are produced by the same renderer on Linux; the `checks.aarch64-darwin` run is deferred to CI's `build-darwin`.

---

## Definition of Done

- The `agent-instructions` check passes with receipts that distinguish the Claude Code render from the other four.
- The rendered Claude Code file contains the artifact rule and no conversation rule; the Codex file contains both.
- `docs/agent-routing.md` names the language rules and the Claude Code exception.
- No abandoned experimental edits remain in the diff.
