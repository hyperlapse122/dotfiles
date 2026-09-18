---
title: A Same-Spelling Lint Cannot Prove an Identity Indirection Is Complete
date: 2026-09-18
last_updated: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: workflow_issue
component: development_workflow
applies_when:
  - "a refactor routes paths through an indirection that returns its input unchanged until a later switch (a marker file, a flag, a config key) flips it"
  - "a static lint is offered as proof that every call site was re-pointed"
  - "the switch is flipped in a separate, later commit or phase"
root_cause: incorrect_assumption
resolution_type: workflow_improvement
severity: high
tags:
  - chezmoi
  - chezmoiroot
  - source-root
  - migration
  - lint
  - rehearsal
  - ci
---

# A Same-Spelling Lint Cannot Prove an Identity Indirection Is Complete

## Context

Issue #559 moved this repository's chezmoi source state from the repository root into `home/`, behind a one-line `.chezmoiroot`. It ran in two phases. Phase A added a source-root indirection at every layer while the two roots still coincided. Phase B renamed the files and added `.chezmoiroot`.

For the `.ci` gates, the indirection is `resolve_source_root` and `join_source_state` in `.ci/lib/source-root.sh:55` and `.ci/lib/source-root.sh:91`. Until `.chezmoiroot` exists, `resolve_source_root <root>` returns `<root>` unchanged (`.ci/lib/source-root.sh:59`). It is the identity function.

The plan treated the lint in `.ci/test-source-root.sh` (`lint_source_state_joins`, `.ci/test-source-root.sh:258`) as proof of completeness. That lint rejects any `$repo_root/<source-state name>` join, using `SOURCE_ROOT_JOIN_PATTERN` (`.ci/lib/source-root.sh:140`). It reached zero after 109 joins across 42 files were re-pointed.

The proof was false. 19 gates still reached source state through spellings the pattern never matched. Every one of them passed every Phase A test, because the identity indirection resolved a wrong path to the same place as a right one.

## Guidance

When an indirection is the identity function until a later switch flips it, **exercise the flipped state before you flip it.** A lint over one spelling is a proxy, not a proof.

Build a rehearsal of the post-switch state and run the real gates there:

1. Copy the working tree: every tracked file plus every untracked, non-ignored file, so uncommitted edits and new files are included.
2. Apply the switch in the copy: here, move each source-state top-level entry under `home/` and write `.chezmoiroot` containing `home`.
3. Give the copy a git index (`git init` then `git add -A`) so gates that call `git rev-parse` or `git ls-files` still run.
4. Run every gate in the checkout **and** in the copy. Diff the pass sets.

When a replayed step points `HOME` at a throwaway directory, also unset `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME`. chezmoi reads those before `HOME`. On a host that sets them, `chezmoi init` in a fakehome writes the fakehome `sourceDir` into the real `~/.config/chezmoi/chezmoi.toml`, and it records script state in the real `chezmoistate.boltdb`. After the scratch directory is removed, every later `chezmoi` command fails with `stat <fakehome>/src/...: no such file or directory`. To recover, run `chezmoi init --source="$HOME/src/github.com/hyperlapse122/dotfiles"`.

A gate that passes in the checkout and fails in the rehearsal is a latent post-switch break. The run that found these 19 used exactly this diff:

```text
pass in checkout, FAIL in rehearsal (post-switch latent):
  test-agent-instructions   render-gate-helpers.sh: <rehearsal>/dot_claude/...: No such file
  test-compound-engineering-overlays   <rehearsal>/.chezmoiscripts/...: No such file
  check-skip-declarations   missing scan root <rehearsal>/.chezmoiscripts
  ...
```

Gates that fail in both trees carry no signal about the switch: they need arguments or a CI-only context. Triage them separately. Do not assume they are harmless. One of them here (`.ci/test-fedora-fact-block-baseline.sh`) was a genuine regression from Phase A, not an environment gap.

## Why This Matters

The four spellings the lint missed are ordinary shell, and each will recur in the next path migration:

- **A differently named root variable.** A script sets `root=${1:-$(pwd)}` or `local dir=$1` and joins `$root/.chezmoiscripts/...`. The pattern names only `repo_root`.
- **A relative path from the working directory.** `execute-template < .chezmoiscripts/...` has no variable at all.
- **A path built by the caller and passed into a helper.** A helper like `render()` receives a finished input path, so the helper looks correct while its caller joins onto the repository root.
- **A whole-checkout symlink-farm fixture.** A test that symlinks every top-level entry of the checkout into a scratch directory, then swaps in a private copy of one entry. After the switch the farm also inherits `.chezmoiroot` and a `home` link. chezmoi then reads the **real** `home/.chezmoidata` instead of the private copy. The test either stops testing anything or, worse, writes through the link into real data.

None of these fails before the switch. That is what makes the lint's zero dangerous: it looks like completion exactly when the remaining defects are invisible.

## When to Apply

- Any staged move of a root, prefix, base path, or mount point behind a marker, flag, or config key.
- Any refactor whose Phase A is "introduce an indirection; no behaviour change", where the only evidence of completeness is a search for the old spelling.
- Before the commit that flips the switch, not after it: the rehearsal is cheap, while a post-switch CI failure across dozens of gates is not.

## Examples

Before, a gate built on a variable the lint ignores:

```sh
root=${1:-$(pwd)}
< "$root/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl"
```

After, the same gate resolves its own source root from that variable:

```sh
root=${1:-$(pwd)}
source_root=$(resolve_source_root "$root")
< "$source_root/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl"
```

A symlink-farm fixture must place its private copy in the fixture's own source root, and that source root must be a real directory of links, never a link back into the checkout. `populate_fixture_source_root` (`.ci/lib/source-root.sh:110`) now does this for the three fixtures that needed it.

## Related

- [A gitignored path is still part of the chezmoi source state](gitignored-paths-remain-visible-to-chezmoi.md): why the source root is read from disk, which is what makes `.chezmoiroot` meaningful.
- [Deploying a root-owned /etc file from an Orca worktree re-runs every onchange system script](chezmoi-worktree-root-etc-file-deployment.md): why rendered scripts resolve the source directory at run time, the constraint the run-time half of this indirection had to keep.
