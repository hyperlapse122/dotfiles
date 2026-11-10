---
title: "An unset init.defaultBranch leaves a bare repo's HEAD dangling for a second clone"
date: 2026-09-23
category: best-practices
module: "NixOS flake checks (update-dependencies-reconcile git sandbox)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Writing a Nix check that creates a bare git repo with `git init --bare` inside a sandboxed HOME (e.g. `export HOME=$TMPDIR`, as this repo's checks do) and clones it more than once"
  - "A test renames an unborn local branch to `main` with `git checkout -qb main` rather than relying on `init.defaultBranch`, because the sandbox's HOME carries no git config"
  - "A check has only ever been run interactively from a developer shell, where ambient git config such as `init.defaultBranch=main` is already set globally, and has never been run inside `nix build .#checks.<system>.<name>`"
root_cause: incomplete_setup
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - flake-checks
  - nix
  - git
  - bare-repository
  - head-symref
  - init-defaultbranch
  - sandboxed-home
---

# An unset init.defaultBranch leaves a bare repo's HEAD dangling for a second clone

## Context

`tests/update-dependencies-reconcile.sh`, registered as the `update-dependencies-reconcile` check in `flake.nix` (consolidating the former standalone `tests/update-dependencies-push-order.sh` / `update-dependencies-push-order` check), exercises CI workflow steps against a real, sandboxed git remote. Its diverged-origin scenario needs a second, independent clone of the same from-scratch bare origin, to simulate a concurrent contributor pushing before the main scenario's clone does.

That second clone failed even though the origin already held a real, pushed `main` branch:

```text
warning: You appear to have cloned an empty repository.
warning: remote HEAD refers to nonexistent ref, unable to checkout
error: src refspec main does not match any
error: failed to push some refs to '.../diverged-origin.git'
```

`git ls-remote` against that same origin, run immediately before the failing clone, showed `refs/heads/main` present with a valid commit SHA -- the ref genuinely existed with real content. This was not the first clone's push silently failing.

The failure reproduced **only** inside `nix build .#checks.x86_64-linux.update-dependencies-push-order` (which runs with `export HOME=$TMPDIR`, the check's `runCommand` in `flake.nix`), never when the identical script was run interactively from a developer shell. The first debugging step -- re-running the script by hand outside `nix build` -- reproduced nothing, which was itself misleading at first (it suggested a Nix-build-specific bug) but turned out to be the actual diagnostic signal: the interactive shell already had `init.defaultBranch=main` set in `~/.gitconfig`, which made the branch-naming ambiguity this bug depends on never arise. When a check fails only under `nix build` and passes identically run by hand, look first for an ambient-environment difference the interactive shell is silently supplying -- `HOME`, gitconfig, locale, `PATH` -- rather than assuming a Nix evaluation or sandboxing bug.

## Guidance

Immediately after `git init --bare` on a from-scratch origin that will be cloned more than once, pin its `HEAD` symref explicitly, before anything clones it:

```sh
"$git_bin" init -q --bare "$origin"
"$git_bin" --git-dir "$origin" symbolic-ref HEAD refs/heads/main
"$git_bin" clone -q "$origin" "$clone"
```

This is the fix in `setup_clone()` (`tests/update-dependencies-reconcile.sh`, carried over from the former `tests/update-dependencies-push-order.sh`), which pins `HEAD` to `refs/heads/main` before anything clones the bare sandbox origin so a second clone after the first push never follows an unborn `refs/heads/master`.

## Why This Matters

`git init --bare "$origin"` sets that repo's `HEAD` to a symbolic ref pointing at `refs/heads/<name>`, where `<name>` comes from `init.defaultBranch` if configured, or git's compiled-in fallback (historically `master`) if not. Under `export HOME=$TMPDIR` there is no gitconfig at all, so the fallback name applies to the bare origin's `HEAD`.

The first `git clone` of that still-empty origin gets its own local unborn branch, named by the same client-side fallback rule -- but `setup_clone` immediately renames that unborn branch to `main` with `git checkout -qb main` (in `setup_clone()`) before the first commit lands. So the branch that actually gets committed to and pushed is `main`, and the push creates `refs/heads/main` on the bare origin with real content.

Nothing in a `git push` ever touches the *origin's own* `HEAD` symref -- pushing a branch creates or updates that branch's ref, not `HEAD`. So after the first clone's push, the origin's `HEAD` is still the symref set at init time, still pointing at the fallback name, a ref that has never existed on that origin and never will. A second, independent `git clone` of that origin follows the origin's `HEAD` to decide what to check out locally, finds it points at a nonexistent ref, and fails exactly as shown above -- leaving that second clone with no locally named branch at all (its own client-side fallback naming applies again, not `main`). That is why the subsequent `git push origin main` from the second clone has no local `main` ref to push: `src refspec main does not match any`.

Explicitly running `git --git-dir "$origin" symbolic-ref HEAD refs/heads/main` right after `git init --bare` pins the origin's default branch regardless of any ambient client config, present or absent. Every subsequent clone of that origin then follows a `HEAD` that resolves correctly: to the unborn `main` before anything is pushed, and to the real `main` afterward.

## When to Apply

The boundary condition is whether a test helper creates more than one clone of the same from-scratch bare repository. `tests/nr.sh`'s `make_repo()` (`tests/nr.sh:26-35`) never needed this fix because it creates a plain, non-bare repository with `git init -q` and is never cloned at all -- the script under test operates on that working directory directly via `--flake-dir`, so there is no bare-origin `HEAD` symref and no second clone to be misled by it.

Any future Nix check in this repo (or a similar sandboxed-build test harness elsewhere) that creates a bare git repository and clones it more than once needs this fix. A helper that only ever creates one repo and one clone of it does not, since there is no second clone left to follow a stale `HEAD`.

## Examples

```sh
# after:
"$git_bin" init -q --bare "$origin"

# add immediately, before the first clone:
"$git_bin" --git-dir "$origin" symbolic-ref HEAD refs/heads/main

"$git_bin" clone -q "$origin" "$clone"
```

Symptom without the fix, on a second clone of the same origin:

```text
warning: remote HEAD refers to nonexistent ref, unable to checkout
error: src refspec main does not match any
```

## Related

- [A fixture that starts two sources equal cannot prove which one a check reads](converged-fixture-state-defeats-nix-check-mutation-testing.md) -- a different failure class in the same test family: there, two fixture instances start in the same state so the check can't tell correct from buggy; here, both clones are equally broken by the same upstream cause (the origin's stale `HEAD`), and the fix is in origin setup, not fixture design.
- [Restrictive service umask blocks SOPS user secrets](../integration-issues/sops-service-umask-blocks-user-secrets.md) and [tmpfs GNUPGHOME card provisioning traps](../integration-issues/tmpfs-gnupghome-card-provisioning-traps.md) -- the same meta-pattern reached a different way: a sandboxed or freshly created environment silently lacks ambient configuration a normal environment carries (there, `~/.gnupg` state Home Manager only writes into the real home; here, `init.defaultBranch` a developer's `~/.gitconfig` normally carries), producing a failure only in the isolated case.
