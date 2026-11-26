---
title: "Order explicit Home Manager link cleanup after linkGeneration"
date: 2026-11-26
category: best-practices
module: "Home Manager activation (instruction guide migration)"
problem_type: best_practice
component: activation
severity: medium
applies_when:
  - "An activation step removes paths that a previous Home Manager generation declared under home.file"
  - "A Home Manager activation prints 'does not link into a Home Manager generation' while deleting an orphan link"
root_cause: logic_error
resolution_type: code_fix
tags: [home-manager, activation, linkgeneration, migration, symlink]
---

# Order explicit Home Manager link cleanup after linkGeneration

## Context

Retiring two `home.file` declarations in `home/h82/agents/instructions/default.nix` needed a migration for links already installed on existing homes. The rejected first approach put the removal in the instruction activation step, which runs after `installPackages`, and tested only `-L` before deleting. Both choices are wrong for a retired declaration: they run before Home Manager's own cleanup and claim every symlink at the path, including one a user created.

Home Manager's `linkGeneration` already handles this case. Its `cleanOldGen` walks every leaf in the previous generation's `home-files` directory and pipes each to `legacyCleanup`. `legacyCleanup` deletes a target only when the path is absent from the new generation and the link's target matches `${storeDir}/*-home-manager-files/*`, then runs `rmdir -p --ignore-fail-on-non-empty` on the parent path. For a path absent from the new generation whose link does not match, it prints `Path '...' does not link into a Home Manager generation. Skipping delete.` (`modules/files.nix`, `legacyCleanup` and `cleanOldGen`, in Home Manager's flake input rather than this repository).

## Guidance

When a `home.file` declaration is retired, let `linkGeneration` remove the old links. Do not add an earlier removal step: by the time it runs, Home Manager has not performed its ownership check, so an `-L` test deletes a user's symlink and the later check reports the misleading warning.

When the issue requires an explicit migration anyway, make it a dedicated entry ordered after `linkGeneration` and mirror Home Manager's ownership test:

```nix
home.activation.legacyInstructionGuides = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  if [[ ! -v DRY_RUN ]]; then
    if [[ -L "$HOME/${path}" && "$(readlink "$HOME/${path}")" == ${builtins.storeDir}/*-home-manager-files/* ]]; then
      rm -f "$HOME/${path}"
    fi
    rmdir "$HOME/${legacyGuideDirectory}" 2>/dev/null || :
  fi
'';
```

Keep three details:

- Name the exact retired paths. Never `rm -rf` a directory or accept any symlink at the path.
- Remove the directory with `rmdir` and ignore its failure, so a user's unrelated file keeps it. Do not use `rmdir -p`; the parent `~/.local/share/nix-config` holds other files such as `refresh-agent-instructions`.
- Test by executing the extracted activation block against a temporary home seeded with links whose target is a `*-home-manager-files` store path, a foreign symlink, a regular file, and an unrelated file. Also assert the entry's `after` list contains `linkGeneration`.

This is not the same shape as forcing a still-declared file. A `home.file` entry with `force = true` can still meet a regular target that Home Manager leaves in place when its content matches the generated source; that case needs a removal step before `linkGeneration`. Retiring the declaration removes the entry from the new generation, so `linkGeneration` itself owns the orphan cleanup.

## Why This Matters

An earlier removal duplicates work and changes what Home Manager observes. The owned links are already gone when `linkGeneration` runs, so its cleanup reports `does not link into a Home Manager generation. Skipping delete.` even though the deletion succeeded, which sends the next reader after a bug that is not there. The `-L`-only predicate is the second defect: a symlink a user placed at the retired path is not Home Manager's, and deleting it loses data the migration was supposed to leave alone.

Running after `linkGeneration` makes the explicit step a no-op on a normal switch and a repair where Home Manager left state behind. The delivery check proves three outcomes without depending on Home Manager's internal script: store links are removed, a user's symlink survives, and a non-empty directory survives. The Nix-level assertion also proves no `home.file` entry remains for the retired paths, so a later generation has nothing to recreate.

## When to Apply

- Retiring a `home.file` declaration that existing homes already materialized.
- Debugging `does not link into a Home Manager generation` during a migration switch.
- Reviewing any activation cleanup that deletes paths under `$HOME`, especially one ordered before `linkGeneration`.

## Examples

Before, inside the delivery step that runs before `linkGeneration`:

```nix
if [[ -L "$HOME/${path}" ]]; then
  rm -f "$HOME/${path}"
fi
```

The owned link disappears before Home Manager checks it, a user symlink is deleted, and the next `linkGeneration` warns.

After, as a dedicated entry:

```nix
home.activation.legacyInstructionGuides = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  if [[ ! -v DRY_RUN ]]; then
    for path in ${legacyGuides}; do
      if [[ -L "$HOME/$path" && "$(readlink "$HOME/$path")" == ${builtins.storeDir}/*-home-manager-files/* ]]; then
        rm -f "$HOME/$path"
      fi
    done
    rmdir "$HOME/${legacyGuideDirectory}" 2>/dev/null || :
  fi
'';
```

The delivery check seeds the old state, runs this block, and asserts that store links vanish, a foreign symlink and regular file survive through a later delivery activation, and a Nix-level assertion proves no `home.file` entry remains for the retired paths.

## Related

- Issue [#322](https://github.com/hyperlapse122/dotfiles/issues/322) requests the migration implemented on this branch; PR [#321](https://github.com/hyperlapse122/dotfiles/pull/321), already merged, supplies the preceding instruction reset.
- [A check that greps an activation step's arguments passes when the step only echoes them](../best-practices/activation-step-grep-check-passes-an-echo-only-step.md) requires executing the block.
- [A check that reads an option value passes when the option is disabled or renamed](../best-practices/nix-check-reads-option-value-not-materialized-output.md) requires asserting resolved `home.file` targets.
- [Home Manager activation does not re-run when the generation is unchanged](../best-practices/home-manager-activation-does-not-run-on-every-rebuild.md) bounds the guarantee to a new generation.
- [Forcing a file another module declares conditionally breaks evaluation](../integration-issues/home-manager-force-on-undeclared-file-entry-breaks-evaluation.md) covers the `force = true` case that does need an earlier removal.
- [Orca rejects hardlinked Nix store skill files](../integration-issues/orca-rejects-hardlinked-nix-store-skill-files.md) records the same ownership-aware cleanup shape.
