---
name: git-branch-cleanup
description: |
  Clean up stale and dangling remote-tracking branches from git repositories.
  Use this skill when the user mentions removing dangling branches, cleaning up stale remote-tracking branches, pruning deleted branches, or maintaining git branch hygiene. Also use when the user wants to remove references to branches that no longer exist on the remote, clean up origin/* branches that have been deleted by teammates, or synchronize local branch tracking with the actual remote state.
---

# Git Branch Cleanup Skill

Clean up stale/dangling remote-tracking branches that no longer exist on the remote repository.

## Workflow

### 1. Verify Git Repository

First, verify we're in a git repository:

```bash
git rev-parse --git-dir
```

If this fails, report that we're not in a git repository and exit.

### 2. Identify the Remote

Default to `origin`, but check if other remotes exist:

```bash
git remote
```

If multiple remotes exist and the user didn't specify one, use `origin` as the default but mention which remote is being used.

### 3. Dry-Run Preview (Always)

Always show what will be pruned before actually doing it:

```bash
git remote prune <remote> --dry-run
```

Parse the output to extract the branch names that will be removed.

### 4. Execute Pruning

If branches were found in the dry-run, proceed with the actual prune:

```bash
git remote prune <remote>
```

Then follow up with a fetch to ensure full cleanup:

```bash
git fetch --prune <remote>
```

### 5. Optional: Clean Up Local Branches

If the user wants to also remove local branches that were tracking the now-deleted remote branches, identify them first:

```bash
git branch -vv | grep ': gone]'
```

These are local branches whose upstream no longer exists. You can offer to delete them:

```bash
# For each "gone" branch
git branch -d <branch-name>
```

Use `-d` (safe delete) by default. Only use `-D` (force delete) if the user explicitly requests it.

## Output Format

Report the results clearly:

```
Pruned <N> stale remote-tracking branch(es) from <remote>:
  - origin/feature/old-branch-1
  - origin/fix/merged-pr-2

[Optional] Removed <M> local branch(es) with deleted upstreams:
  - feature/old-branch-1
  - fix/merged-pr-2
```

If no stale branches were found:

```
No stale remote-tracking branches found. Everything is clean!
```

## Safety Considerations

- Always run `--dry-run` first to show what will happen
- Never prune without showing the preview
- Use safe delete (`-d`) for local branches - it prevents deleting branches with unmerged commits
- Only force delete (`-D`) if explicitly requested by the user
- Be careful with local branch cleanup - confirm with the user before deleting

## Common Scenarios

**Scenario 1: Basic cleanup**
User: "clean up dangling branches"
Action: Run dry-run on origin, show results, prune if any found

**Scenario 2: Specific remote**
User: "prune stale branches from upstream"
Action: Use "upstream" as the remote name instead of origin

**Scenario 3: Full cleanup including local branches**
User: "remove all branches that track deleted remotes"
Action: Prune remote-tracking branches, then identify and offer to delete local "gone" branches

**Scenario 4: Non-interactive/CI usage**
User: "prune branches without prompting"
Action: Skip confirmation prompts (not applicable in this skill as it doesn't prompt interactively)
