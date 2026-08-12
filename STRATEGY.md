---
name: dotfiles
last_updated: 2026-08-13
---

# dotfiles Strategy

## Target problem

A working machine is the product of hundreds of undocumented manual decisions, so a
new or reinstalled host can never be reproduced. The crux: the pieces that matter
most — secrets, root-owned `/etc`, agent auth — are exactly the ones a plain dotfiles
link farm cannot carry.

## Our approach

Declare it as data, never as a script: every decision lives in a `.chezmoidata` file
or a shared template partial, and scripts are dumb reconcilers over that data. Every
change is held to a rebuild-grade standard — a setting that only works because of how
this host happens to be is drift, not configuration.

## Who it's for

**Primary:** The single operator changing one setting on a live machine — hiring
dotfiles to make that change land everywhere and stay landed, without risking the
workstation currently in use.

## Key metrics

- **Idempotent-apply cleanliness** — a second apply on unchanged source changes zero
  targets and reruns zero onchange scripts; measured by an empty `chezmoi diff`
  against a scratch destination plus rendered-script comparison.
- **Unowned live surface** — count of config surfaces the machine depends on that the
  repo does not declare (hand-edited targets, unmanaged dotenv lines, vendor-rewritten
  files without per-key assertion); measured by drift sweep plus `chezmoi verify`.
- **Duplicate-knowledge defects** — instances where a version, fact, secret ref, or
  setting exists in more than one place, or a consumer bypasses its declared owner;
  measured by review at change time.
- **Manual steps to a working host** — count of operator actions still required beyond
  the one bootstrap command on a bare host; measured by hand at each rebuild,
  container run, or CI apply.

## Tracks

### Declarative host provisioning

The package authority, the root-owned `/etc` manifest, host facts and their gates,
networking, and desktop config — everything the OS needs, expressed as data with a
dumb reconciler.

_Why it serves the approach:_ this is where "never a script" is won or lost.

### Hermetic supply chain

The generated release lock, grouped externals, and mise pins, so a source-state read
performs no network I/O and every artifact is version-and-digest addressed.

_Why it serves the approach:_ a replay on a bare host produces the same bytes as today.

### Secrets and identity

1Password-resolved refs at render time, GPG/age material, keyring-encrypted host
prompts, and CLI auth (glab, container registries).

_Why it serves the approach:_ it carries the part of host state a plain link farm
cannot carry at all.

### Project garden and worktrees

The `~/src` layout, the encrypted project registry, aoe session/worktree ownership,
and `src-audit` reconciliation.

_Why it serves the approach:_ declares the working environment itself as data, not just
the config around it.
