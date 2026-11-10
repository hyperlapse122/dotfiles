---
title: Forcing a Home Manager file another module declares conditionally breaks evaluation
date: "2026-10-07"
category: integration-issues
module: Home Manager file entries (programs.mise global config)
problem_type: integration_issue
component: activation
severity: medium
symptoms:
  - "Evaluation fails with: The option `home-manager.users.h82.xdg.configFile.\"mise/config.toml\".source' was accessed but has no value defined"
  - "Disabling programs.mise, or setting mutableSettings = true, breaks every host's evaluation instead of just dropping the managed file"
  - "A check mutation that removes the upstream declaration fails at evaluation, not inside the check's builder, even though the lookup carries an `or` fallback"
root_cause: config_error
resolution_type: code_fix
tags: ["home-manager", "xdg-configfile", "home-file", "force", "mkif", "evaluation-error", "mutation-testing", "mise"]
---

# Forcing a Home Manager file another module declares conditionally breaks evaluation

## Problem

To make the mise global config immutable, `home/h82/shell/shell.nix` needed `force = true` on `xdg.configFile."mise/config.toml"`, so activation replaces the writable file an earlier generation left. The Home Manager `programs.mise` module declares that file itself, and only under a condition. A bare `force` declaration evaluates fine while the condition holds and breaks evaluation as soon as it does not.

## Symptoms

- `nix eval` or a host build fails with `xdg.configFile."mise/config.toml".source' was accessed but has no value defined`.
- Turning off `programs.mise.enable`, or setting `programs.mise.mutableSettings = true`, breaks evaluation of every host.
- In an early draft of `tests/mise-settings.nix`, mutations that revert to the mutable layout or drop `globalConfig` failed at evaluation, and an `or` fallback such as `entry.user.xdg.configFile."mise/config.toml".source or ""` did not help. The shipped check reads `home-files` instead.

## What Didn't Work

- **An unconditional `xdg.configFile."mise/config.toml".force = true;`** This was the first plan. It works only while the module also declares the file.
- **`builtins.tryEval` around the check's `source` lookup.** One reviewer suggested this. It would have kept the check's mutations reaching the builder, but the host configuration itself would still fail to evaluate, so it only hid the defect.
- **`force = lib.mkIf cond true` on the inner value.** The attribute `xdg.configFile."mise/config.toml"` still exists: `attrsOf submodule` creates the entry from the definition even when the value's `mkIf` is false. Reading its `source` still throws. Observed on 2026-10-07 by extending a host with `home-manager.users.h82.xdg.configFile."x-probe".force = lib.mkIf false true;`: `xdg.configFile ? "x-probe"` was `true`, and `builtins.tryEval (….source or "fallback")` reported `success = false`.

## Solution

Gate the whole attrset on the exact condition under which the upstream module declares the file, including its outer `enable` guard:

```nix
let
  mise = config.programs.mise;
  # The condition under which the Home Manager module writes globalConfig to
  # mise/config.toml.
  miseManagesGlobal = mise.enable && !mise.mutableSettings && mise.globalConfig != { };
in
{
  xdg.configFile = lib.mkIf miseManagesGlobal { "mise/config.toml".force = true; };
}
```

The condition mirrors the module (`modules/programs/mise.nix` in the pinned Home Manager source, not this repo): `config = mkIf cfg.enable { … }`. `globalConfigPath` is `mise/config.toml` only when `mutableSettings` is false (line 10). The entry is declared only `mkIf (cfg.globalConfig != { })` on the `${globalConfigPath}` entry.

## Why This Works

A Home Manager file entry's `source` option (Home Manager's `modules/lib/file-type.nix:70`) has no default. Only `text` fills it, through `mkIf (config.text != null)`. A definition that sets only `force` still creates the entry, and the entry then has no `source`. Anything that reads the entry, including Home Manager building `home-files` and a check's lookup, throws an evaluation error. Nix's `or` catches a missing attribute, not a throw. Only `builtins.tryEval` catches a throw.

A `mkIf` on the attrset passed to `xdg.configFile` removes the definition entirely when the condition is false. The entry then never exists, the module's own declaration decides whether the file is managed, and an `or` fallback in a check sees a missing attribute again.

## Prevention

- When you override one field (`force`, `executable`, `enable`) of a `home.file` or `xdg.configFile` entry that another module declares, gate the override with `lib.mkIf` at the attrset level on that module's own condition. Copy the condition from the module source, including its outer `mkIf cfg.enable`.
- Mutation-test the override by turning each part of the upstream condition off (`enable = false`, the mutable option on, an empty config). Each mutation must fail inside the check's builder, not at evaluation; see `.compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md`.
- A related trap that the code comment in `home/h82/shell/shell.nix` records: even with `force = true`, Home Manager's linker leaves a regular target whose content matches the generated source in place (Home Manager's `modules/files.nix:366-368`). The file then stays writable. This flake removes it with a `home.activation` entry between `writeBoundary` and `linkGeneration`.

## Related Issues

- `.compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md`: the same symptom class, a mutation that only breaks evaluation.
- `.compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md`: why `tests/mise-settings.nix` reads `home-files` rather than the entry's option values.
