---
title: Resolve mise lock conflicts outside automatic tool activation
date: 2026-11-06
category: integration-issues
module: Worktree tool activation
problem_type: workflow_issue
component: tooling
severity: medium
applies_when:
  - "The command runner activates mise before executing commands in this worktree"
  - "A Git merge leaves conflict markers in mise.lock"
tags: [mise, lockfile, merge, t3-code, windows]
---

# Resolve mise lock conflicts outside automatic tool activation

## Context

During preparation of [PR #74](https://github.com/hyperlapse122/dotfiles/pull/74), the T3 command environment invoked mise before the requested command. With a conflicted `mise.lock`, tool resolution ran before the intended bookkeeping command. It also changed the `exclude-newer` timestamp in `.mise/locks/pipx-keyring/25.7.0~12237102/uv.lock`; its package entries were unchanged.

## Guidance

Run conflict recovery commands from a temporary directory outside the repository. Address Git through `git -C` and use an already installed interpreter by absolute path. Disabling the shell login flag alone did not prevent the observed activation.

Resolve the lock from both parent versions, preserving each intended tool entry. Parse the resulting TOML and compare its entries with the parents before committing. Inspect unstaged changes after every command that might activate tools. Restore unrelated generated metadata only after checking that it came from this recovery attempt and contains no user edits.

## Why This Matters

A command that appears read-only can have a tool activation step before it. The feature diff cannot explain that environment behavior, and an automatically rewritten lock can hide the selections that the merge was supposed to preserve.

## When to Apply

Use this recovery procedure when the command environment automatically activates mise and its project lock is temporarily invalid. It is not evidence that every shell or T3 configuration behaves this way.

## Examples

In an external command working directory, use explicit repository and interpreter paths:

```powershell
git -C $taskRepo status --short
& $taskPython -c 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())' "$taskRepo/mise.lock"
```

For PR #74, commands run outside the repository stopped the incidental regeneration. The merged lock retained both parents' tool entries. Windows application tests and the native Linux zsh smoke passed afterward; the PR was still pending when this record was written.

## Related

- [Worktree tool declarations](../../../../mise.toml)
