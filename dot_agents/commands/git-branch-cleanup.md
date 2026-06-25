---
name: git-branch-cleanup
description: Prune stale remote-tracking branches and optionally delete local branches whose upstream was removed. Runs across all configured remotes by default. Triggers on "clean up dangling branches", "prune stale remotes", "remove deleted branches", "git branch cleanup", "gone branches".
---

# Git Branch Cleanup

Prune stale/dangling remote-tracking branches that no longer exist on their remote repositories. By default, operate across **all configured remotes** in the repository.

## Workflow

### 1. Verify Git Repository

First, verify the current directory is a git repository:

```bash
git rev-parse --git-dir
```

If this fails, report that the working directory is not a git repository and exit.

### 2. Enumerate Remotes

By default, operate on **every** remote configured in the repository:

```bash
git remote
```

- If the user specified a remote (e.g., "prune upstream"), restrict the operation to that single remote.
- If no remotes are configured, report "No remotes configured" and exit.
- Otherwise, proceed with the full list of remotes.

### 3. Dry-Run Preview (Always)

Always show what will be pruned before actually doing it. Use `git fetch --prune --dry-run` across all remotes in one pass:

```bash
# Default: preview prune across ALL remotes
git fetch --all --prune --dry-run
```

```bash
# Single-remote override (only when the user specified one)
git remote prune <remote> --dry-run
```

Parse the output to extract the branch names that will be removed, grouped by remote.

### 4. Execute Pruning

If branches were found in the dry-run, proceed with the actual prune across all remotes:

```bash
# Default: fetch + prune across ALL remotes
git fetch --all --prune
```

```bash
# Single-remote override (only when the user specified one)
git remote prune <remote>
git fetch --prune <remote>
```

`git fetch --all --prune` both refreshes remote-tracking refs and removes stale ones in a single command — no separate `git remote prune` loop is needed.

### 5. Optional: Clean Up Local Branches

After pruning remote-tracking refs, local branches whose upstream was deleted become orphans. Identify them:

```bash
git branch -vv | grep ': gone]'
```

These are local branches whose upstream no longer exists (on any remote). Offer to delete them:

```bash
# For each "gone" branch
git branch -d <branch-name>
```

Use `-d` (safe delete) by default. Only use `-D` (force delete) if the user explicitly requests it.

## Safety Rules

- Always run `--dry-run` first to show what will happen.
- Never prune without showing the preview.
- Use safe delete (`-d`) for local branches — it prevents deleting branches with unmerged commits.
- Only force delete (`-D`) if explicitly requested by the user.
- Confirm with the user before deleting local branches.
- `git fetch --all` performs network I/O against every remote; warn the user if the repo has many remotes or slow ones.

## Output Format

Report the results clearly, grouped by remote when multiple remotes are involved:

```
Pruned <N> stale remote-tracking branch(es) across <R> remote(s):

  origin:
    - origin/feature/old-branch-1
    - origin/fix/merged-pr-2

  upstream:
    - upstream/feature/abandoned-experiment

[Optional] Removed <M> local branch(es) with deleted upstreams:
  - feature/old-branch-1
  - fix/merged-pr-2
```

If no stale branches were found:

```
No stale remote-tracking branches found across <R> remote(s). Everything is clean!
```

## Common Scenarios

**Scenario 1: Basic cleanup (default — all remotes)**
User: "clean up dangling branches"
Action: Enumerate all remotes, run `git fetch --all --prune --dry-run`, show results grouped by remote, then `git fetch --all --prune` if any found.

**Scenario 2: Specific remote**
User: "prune stale branches from upstream"
Action: Restrict to `upstream` only — use `git remote prune upstream --dry-run` then `git remote prune upstream` + `git fetch --prune upstream`.

**Scenario 3: Full cleanup including local branches**
User: "remove all branches that track deleted remotes"
Action: Prune remote-tracking branches across all remotes, then identify and offer to delete local "gone" branches.

**Scenario 4: Non-interactive/CI usage**
User: "prune branches without prompting"
Action: Skip confirmation prompts.

**Scenario 5: Single-remote repo**
User: "clean up dangling branches" (repo has only `origin`)
Action: Default all-remotes behavior degenerates naturally to just `origin`; no special-casing needed.
