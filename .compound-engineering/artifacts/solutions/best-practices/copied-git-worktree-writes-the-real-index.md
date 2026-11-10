---
title: "A copied git worktree still writes the real index"
date: "2026-09-28"
last_updated: "2026-10-15"
category: best-practices
module: NixOS flake checks (mutation testing in scratch copies)
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Mutation-testing a flake check in a scratch copy of a checkout that is a git worktree"
  - "Copying a checkout with cp -r and then running git add, git commit, or git reset inside the copy"
  - "Evaluating or building a flake whose new files are not yet tracked by Git"
  - "Running a command whose cwd is a scratch copy of this checkout, which carries its own untrusted mise.toml"
  - "Writing a script that copies a checkout into a temporary directory and runs a mise shim there"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - git-worktree
  - scratch-copy
  - mise
  - pre-commit
---

# A copied git worktree still writes the real index

## Context

This repository is usually checked out as a git worktree. A worktree's `.git` is not a directory. It is a one-line file that points into the main repository:

```text
gitdir: /home/h82/nix-config/.git/worktrees/<worktree-id>
```

During the host-generic composition work (`.compound-engineering/artifacts/plans/2026-09-28-0203-refactor-host-generic-composition-plan.md`), a worker ran mutation tests in a scratch copy made with `cp -r <worktree> $TMPDIR/copy`. It ran `git add` in the copy so that the flake would evaluate the mutated files. `cp -r` copies the `.git` link file unchanged, so every git command in the copy acted on the original worktree's index. The mutations were staged in the real checkout, and the worker had to run `git reset` there to recover. The working tree was spared only because the edits happened in the copy.

A second trap sits next to this one. A flake evaluated from a git checkout sees only files Git tracks, so a module created but not yet staged is missing from `nix eval` and `nix build`. The evaluation does not fail. It either reports a missing import or quietly evaluates the tree without the new file.

A third trap appeared during the VSCodium work (`.compound-engineering/artifacts/plans/2026-09-30-1221-feat-vscodium-declarative-config-plan.md`). The checkout carries a `mise.toml`, and `python3` on `PATH` is a mise shim. The rsync copy includes that `mise.toml`, and mise has never trusted the file at the new path. A mise shim resolves its configuration from the working directory, so every shim invoked with the copy as its cwd exits non-zero with "Config files in <copy>/mise.toml are not trusted". Changing into the copy only prints the same error through the shell hook. The mutation runner applied each edit with a small Python script from inside the copy. Every edit failed, and the runner reported all ten mutations as a missing anchor without building any of them. Nothing distinguished that from a mutation that could not apply.

The pre-commit hook hit the same trap. `scripts/lint-staged-markdown` checks the whole index out into `mktemp -d` and runs `markdownlint-cli2` with that copy as its working directory. The copy includes `mise.toml`. From 2026-10-10, first on a Mac with mise 2026.10.6 and later on Linux with mise 2026.10.10, every commit that staged Markdown failed with "Config files in .../tmp.XXXX/mise.toml are not trusted", although the worktree itself was trusted. Since #218 the hook sets `MISE_TRUSTED_CONFIG_PATHS="$(pwd -P)"` and `MISE_SAFE=1` for its one `markdownlint-cli2` call inside the copy, so it lints without help and writes no trust entry. Safe mode matters because trusting the copy also trusts the staged `mise.toml`, and without it an `[env] _.source` script in a staged config runs when the shim loads.

## Guidance

Build scratch copies for mutation testing without the `.git` link, and give each copy its own repository:

```bash
M=$(mktemp -d)
rsync -a --exclude .git ./ "$M"/
git -C "$M" init -q
# mutate "$M/<path>" by absolute path, then:
git -C "$M" add -A
nix build --no-link "path:$M#checks.x86_64-linux.<check>"
rm -rf "$M"
```

`git init` plus `git add -A` makes every file, tracked or not, visible to the flake in the copy. Nothing the copy does can reach the real index.

Keep the shell's working directory in the real checkout and address the copy only by absolute path: `git -C "$M"`, file edits on `"$M/<path>"`, and `nix build "path:$M#..."`. Never `cd` into the copy. Any mise shim run from there, including `python3`, fails on the copy's untrusted `mise.toml`. Do not `mise trust` the copy either, because that records a trust entry for every throwaway directory. Make the runner tell an edit that could not be applied apart from a mutation whose anchor is missing, and treat a run where every mutation reports the same non-result as a broken runner, not as ten findings.

A script that must run a mise shim inside its copy, as the markdown hook does, sets `MISE_TRUSTED_CONFIG_PATHS` to the copy's resolved path and `MISE_SAFE=1` for that one command. When another tool's hook fails this way and you cannot change it, trust the temporary root for that one commit instead of skipping the hook: `MISE_TRUSTED_CONFIG_PATHS="$(cd "${TMPDIR:-/tmp}" && pwd -P)" git commit ...`. Resolve the path with `pwd -P`, because `$TMPDIR` on macOS sits under `/var`, a link to `/private/var`, and the error names the resolved path. The variable lasts only for that command and writes no trust entry. `git commit --no-verify` also gets past the error, but it skips the hook's checks. The shared agent instructions carry the same retry rule under `# Commit hooks`.

In the real checkout, stage new files (`git add <path>`) before trusting `nix eval`, `nix build`, or `nix flake check` output that should include them. Staging is enough, and no commit is needed.

## Why This Matters

The index corruption is silent. Nothing fails, so a coordinator that commits by path after the mutation run can sweep mutated test files into a commit. It can also find its planned commit already partly staged with content it never reviewed. Several workers share one worktree during an orchestrated run, so one worker's scratch experiment can reach another worker's commit.

The untracked-file trap makes a check look green against a tree that is not the one under review. A check whose new helper file is untracked can pass because it evaluated the old tree.

## When to Apply

- Any mutation-testing step in this repository (see `mutation-testing-reveals-decorative-nix-check-assertions.md`), especially when a worker or subagent runs it from a worktree.
- Any task spec handed to a worker that says to test in a copy. Name the rsync-and-`git init` recipe explicitly and forbid `cp -r` of the worktree.
- Any evaluation right after creating a new `.nix` file.
- Any script that runs interpreters or tools with a scratch copy as its working directory.

## Examples

Unsafe, because git commands in the copy write the worktree's real index:

```bash
cp -r . "$TMPDIR/copy" && cd "$TMPDIR/copy" && git add -A
```

Unsafe, because every mise shim run from the copy fails on its untrusted `mise.toml`:

```bash
rsync -a --exclude .git ./ "$M"/ && cd "$M" && git init -q && python3 mutate.py home/h82/dev/vscodium.nix ...
```

Safe, because the copy has its own repository and the working directory stays in the trusted checkout:

```bash
rsync -a --exclude .git ./ "$M"/ && git -C "$M" init -q && python3 mutate.py "$M/home/h82/dev/vscodium.nix" ... && git -C "$M" add -A
```
