---
title: "A check that imports a builtins.toFile copy passes locally and fails nix flake check --no-build"
date: "2026-10-19"
category: best-practices
module: "NixOS flake checks (read-only flake-check evaluation, tests/t3code-traits.nix)"
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "A check rewrites a package or module source with builtins.replaceStrings, writes it with builtins.toFile, and imports the result to evaluate it against substitute siblings"
  - "A check passes in a local nix flake check or nix build but CI's eval-only flake-check job fails with error: path '/nix/store/...' is not valid"
  - "Planning a check that needs a module or package evaluated with its sibling files swapped for fixtures"
root_cause: wrong_api
resolution_type: test_fix
related_components:
  - tooling
tags:
  - flake-checks
  - nix
  - read-only-mode
  - builtins-tofile
  - import
  - mutation-testing
  - ci
---

# A check that imports a builtins.toFile copy passes locally and fails nix flake check --no-build

## Context

To prove which pin file a package reads even when both pins name the same release, two checks evaluated a rewritten copy of the source. They read `packages/antigravity-acp-path.nix` (and `home/h82/t3code.nix`), pointed its sibling paths at synthetic pin files with `builtins.replaceStrings`, wrote the result with `builtins.toFile`, and imported it. (`packages/antigravity-acp-path.nix`, `packages/antigravity-acp.nix`, `tests/antigravity-acp-path-profiles.nix`, and `home/h82/t3code.nix`'s Antigravity pin check were later removed when standalone Antigravity ACP packaging was retired; `home/h82/t3code.nix`, `tests/t3code-traits.nix`, and CI's `nix flake check --no-build` gate remain.) Every local `nix flake check` and `nix build .#checks...` passed. CI's `flake-check` job, which runs `nix flake check --no-build` (`.github/workflows/check.yml`), failed at evaluation:

```text
… while realising the context of path '/nix/store/h99aaqqs6ip7vsgr6f55cb9ajn1qp5h5-antigravity-acp-path.nix'
error: path '/nix/store/h99aaqqs6ip7vsgr6f55cb9ajn1qp5h5-antigravity-acp-path.nix' is not valid
```

`nix flake check --no-build` evaluates in read-only mode. There `builtins.toFile` computes the store path but never writes the file, so importing that path finds nothing. Locally the copy was already in the store from an earlier build, so the same evaluation succeeded. Deleting that one store path (`nix store delete /nix/store/<hash>-antigravity-acp-path.nix`) and rerunning `nix flake check --no-build` reproduces the CI failure on the developer machine.

## Guidance

- Never `import` (or pass to the module system) a path produced by `builtins.toFile` in anything a flake check evaluates. It works only when the store already holds that exact path.
- A symlinked fixture directory does not work either: Nix resolves `./sibling` paths inside an imported file against the symlink's target, so the real siblings load, not the fixtures.
- When the question is which file a source reads, check the source text with `builtins.readFile` and `lib.hasInfix`, and fail inside the builder. Require the expected read expression and reject any mention of the wrong file (shown below on the historical `antigravity-acp-path.nix` check):

```nix
pathPackageSource = builtins.readFile ../packages/antigravity-acp-path.nix;
readsPathPin = lib.hasInfix "builtins.readFile ./antigravity-acp-release.json" pathPackageSource;
namesT3Pin = lib.hasInfix "t3code-release.json" pathPackageSource;
```

Keep the check that compares real built paths beside it; the text check covers only the case where the two pins converge.

- Before trusting a new check that evaluates generated Nix, reproduce CI's read-only evaluation locally: delete any store path the check writes at evaluation time, then run `nix flake check --no-build`.

## Why This Matters

The failure is invisible on the machine that wrote the check, because any prior build leaves the generated file in the store and every later local run reuses it. Only a fresh store under read-only evaluation exposes it, and CI's `flake-check` job is exactly that, so the PR goes red after every local gate passed.

## When to Apply

Any check that builds Nix source at evaluation time and then evaluates it. `builtins.toFile` is the case observed here. `pkgs.writeText` followed by `import` would need import-from-derivation, which an eval-only run has no build step to satisfy; that variant was not tried.

## Examples

Before (historical `tests/antigravity-acp-path-profiles.nix`, passed locally, failed in CI):

```nix
syntheticPathPackage = import (builtins.toFile "antigravity-acp-path.nix" (
  builtins.replaceStrings
    [ "./antigravity-acp.nix" "./antigravity-acp-release.json" "./t3code-release.json" ]
    [ "${../packages/antigravity-acp.nix}" (builtins.toFile "antigravity-acp-release.json" ...) ... ]
    (builtins.readFile ../packages/antigravity-acp-path.nix)
)) { inherit pkgs; };
```

After: the source-text check above, with each failure written inside the builder through `lib.optionalString`. Swapping the pin file each consumer reads turns both checks red, whatever versions the two pins name.
