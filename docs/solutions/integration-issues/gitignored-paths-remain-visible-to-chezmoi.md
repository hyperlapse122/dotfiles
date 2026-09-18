---
title: A Gitignored Path Is Still Part of the chezmoi Source State
date: 2026-09-18
last_updated: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "a non-dot top-level path is in .gitignore, absent from git ls-files, and still deployed into $HOME by chezmoi apply"
  - "removing a ./<name> line from .chezmoiignore looks safe because git does not track <name>"
  - "CI renders cleanly while a developer's own checkout would deploy a generated directory"
root_cause: incorrect_assumption
resolution_type: workflow_improvement
severity: high
tags:
  - chezmoi
  - gitignore
  - chezmoiignore
  - source-state
  - deployment-boundary
---

# A Gitignored Path Is Still Part of the chezmoi Source State

## Problem

`.gitignore` hides a path from git. It hides nothing from chezmoi.

chezmoi reads the source directory from the filesystem and never consults git.
So a non-dot top-level path that exists inside the source directory is part of
the source state whether or not git tracks it, and `chezmoi apply` deploys it
into `$HOME` unless `.chezmoiignore` denies it.

The reasoning that fails is short and feels sound: *this path is gitignored, so
it is not really part of the repository, so chezmoi does not see it either.*
Each clause is true except the last.

## Symptoms

- `git ls-files` and `git status` both show nothing for the path, while
  `chezmoi apply` writes it to `$HOME`.
- A `./<name>` line in `.chezmoiignore` looks redundant, because nothing in the
  tracked tree is named `<name>`.
- CI stays green. The render workflow copies the source tree before it stages
  its own output directory, so the generated path never exists inside the copy
  the workflow applies from. Only a developer's checkout reproduces the case.

## What Didn't Work

**Reading the CI workflow as proof about every checkout.**
`.github/workflows/render-dotfiles.yml:120-135` cuts the chezmoi source copy,
and `:278` stages `_artifacts/` afterwards. That ordering is real, and it does
prove `_artifacts` is absent from the source copy *in CI*. It proves nothing
about a local checkout where someone ran those steps, and a requirement written
on that premise removed a denial that had been protecting the local case.

## Solution

A path that is generated inside the source directory and hidden from git owes
**two** obligations, not one:

- `.gitignore` covers it, so it never reaches a commit.
- `.chezmoiignore` covers it, so it never reaches `$HOME`.

`.ci/test-top-level-deployment-boundary.sh` enforces the second one without a
list. It enumerates the source root on disk — not `git ls-files` — and requires
every non-dot name it finds there to be ignored unless the inventory declares it
deployed. A generated directory nobody thought to declare is caught because it is
present, not because someone remembered to write it down.

The first obligation needs no gate of its own: a path that is not gitignored
gets committed, which makes it a tracked top-level entry, which the inventory
check already covers.

`.ci/top-level-boundary-inventory.yaml` also carries `preemptive_denials`
(`agents.lock`, `_artifacts`). That list grants nothing. It only says a denial is
deliberate, so the stale-entry check does not report it when the path it guards
is legitimately absent from a clean checkout. Forgetting to list one is loud: the
denial gets flagged stale.

**When adding a tool that generates a non-dot path at the repository root, deny
it in `.chezmoiignore` and add it to `.gitignore`.** The gate will tell you if
you miss the denial while the path exists, and will tell you the denial looks
stale if the path is usually absent — at which point list it under
`preemptive_denials`.

## Why This Works

The two ignore files answer different questions and share no mechanism.
`.gitignore` answers "what may enter a commit"; `.chezmoiignore` answers "what
may reach the target". A path can be outside the first and inside the second,
which is exactly the shape that deploys repository internals into a home
directory with nothing red anywhere.

## Prevention

- Never infer chezmoi's view of the source tree from git's view of it.
- Before deleting a `.chezmoiignore` line for a path git does not track, ask
  whether anything writes that path into the source directory at any point.
- Treat a premise established from a CI workflow as a claim about CI until it is
  checked against a developer checkout.

## Related Issues

- [Deploying a Root-Owned /etc File from an Orca Worktree Re-Runs Every onchange System Script](chezmoi-worktree-root-etc-file-deployment.md)
  — the other direction of the same boundary: what the source path is changes
  what chezmoi decides, in that case for `run_onchange` hashes.
