---
name: git-workflow
description: >
  Detailed git branch-naming, commit-message, and rebase-conflict playbook.
  Load this BEFORE naming or renaming a branch, before writing a commit
  message, or before resolving a rebase conflict — whenever you need the
  exhaustive Git Flow prefix set, the forbidden-branch-shape table, the
  in-place rename recipes, the full Conventional Commits type table
  (scopes, body, breaking-change, trailers, examples), or intent-based
  rebase conflict resolution and the --ours/--theirs reversal detail.
  Do NOT load it for routine `git add`/`git status`/`git push` of an
  already-named branch with a message you already have, for PR/MR creation
  (use `pr-mr`), or for CI/CD pipeline work (use `ci-cd-monitoring`). The
  always-on one-line versions of these rules live in the core AGENTS.md;
  this skill is the reference detail behind them.
---

# Git workflow — branches, commits, rebase

The core `AGENTS.md` already states the binding one-liners (prefix gate, lowercase
Conventional Commit subject, `--ours`/`--theirs` reversal). This skill is the
exhaustive reference. **Nothing here weakens the core — it expands it.**

## Branch naming

The single rule: a branch name **MUST** start with a Git Flow prefix. The gate is
the agent reading this — CI, hooks, and the host do **not** check it.

1. Before the **very first commit** on any newly-created or newly-switched-to branch,
   **MUST** run `git branch --show-current`.
2. **MUST** confirm the output starts with one of `feature/`, `bugfix/`, `hotfix/`,
   `refactor/`, `docs/`, `chore/`, `release/` (or the project-defined equivalent set).
3. Treat **every** fresh branch as failing the gate until that confirmation is made
   explicitly. The gate runs **once per branch** — re-running it on every commit is
   unnecessary; skipping it on the first commit is **forbidden**.
4. Gate fails → **MUST** rename in place *before* the first commit lands:
   `git branch -m <current-name> <prefix>/<3-6-word-slug>`.

Renaming **after** commits land (especially after push) leaks the bad name into history,
the remote, and any open PR/MR. It is **forbidden** as a workaround for skipping the
pre-first-commit gate.

A bare human-authored slug (`add-auth`, `fix-login`) is **just as forbidden** as an
auto-generated name (`opencode/playful-engine`, `13-feat-x`). The gate rejects **shape,
not provenance** — "I picked it manually" is not an exemption.

Slug **MUST** be a 3–6 word human-authored summary — not the full issue title, not the
issue number, not a single word, not a placeholder. Words separated by `-`.
**One task = one branch.** Name needs changing → rename it; **MUST NOT** create a sibling
branch for the same work.

→ Full forbidden-shape table, rename recipes, and the prefix→commit-type table:
[`references/branch-naming.md`](references/branch-naming.md).

## Commit messages

**MUST** follow [Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>)<!>: <description>`.

- **Subject**: lowercase, imperative, no period, ≤50 chars (≤72 max). **The ENTIRE
  subject MUST be lowercase** — no exceptions for acronyms (`mcp`, `api`, `jwt`, `url`,
  `html`, `css`, `aws`), brand names (`figma`, `github`, `gitlab`, `react`, `vite`),
  proper nouns, or initialisms. commitlint `subject-case: [2, 'always', 'lower-case']`
  rejects any uppercase character — preserving case for "real" names fails the commit-msg
  hook and CI. A token that must appear in canonical case goes in the **body** (no case
  rule), never the subject.
- **MUST NOT**: emojis, sentence case, trailing periods, vague subjects (`update stuff`,
  `fix things`, `wip`), AI-tool branding (no "Generated with Claude", no `🤖`, no
  `Co-authored-by:` trailer naming an AI).

→ Full type table, scope/body/breaking-change rules, trailers, and worked examples:
[`references/commit-messages.md`](references/commit-messages.md).

## Rebase

Resolve conflicts by **intent, not reflex**:

- **Regenerated / generated artifacts** (lockfiles, build outputs, sequence-numbered
  migrations, generated configs): take `main`'s version, then re-run the generator on
  top so your additions reproduce on the new base.
- **Hand-written code**: review both sides and merge intentionally. **MUST NOT** blindly
  pick `--ours` or `--theirs` — that silently drops one side's work.

During a rebase, Git's `--ours` / `--theirs` are **reversed** vs. merge: `--ours` is
`main` (the rebase target being replayed onto); `--theirs` is the feature commit being
applied. Wrong side / wrong direction → `git rebase --abort` and restart.
**MUST NOT** continue.

→ Detail: [`references/rebase.md`](references/rebase.md).
