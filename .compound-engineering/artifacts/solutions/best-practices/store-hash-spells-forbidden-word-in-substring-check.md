---
title: "A store path hash can spell the word a substring check forbids"
date: 2026-10-22
category: best-practices
module: "macOS fixture check (tests/darwin-config.nix)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check forbids a short word in generated text, such as an activation script, a unit file, or a rendered config, with lib.hasInfix, grep, or another substring match"
  - "The text under test interpolates store paths, so it changes whenever any input of those paths changes"
  - "A check fails on a branch whose diff does not touch what the check guards, and passes on the base"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - flake-checks
  - nix
  - store-paths
  - false-positive
  - mutation-testing
  - darwin
---

# A store path hash can spell the word a substring check forbids

## Context

`tests/darwin-config.nix` forbids any `zap` in the macOS fixture's activation, because `brew uninstall --zap` deletes an app's user data. Until this change it asserted `!lib.hasInfix "zap" postActivation`, where `postActivation` is the whole `system.activationScripts.postActivation.text`, store paths included.

A branch that only rewrote one sentence of the shared agent instructions template (`home/h82/agents/instructions/instructions.md.tmpl`) failed `nix flake check` with `magnolia: no activation step may zap a cask, since --zap deletes the app's user data`. The same check passed on `origin/main`. Nothing in the diff touched Homebrew or the retired-cask step. The new instructions file changed the Home Manager generation, and its activation path became `/nix/store/r8m1ldyh1jglwgqzapjizark25g4l97w-activ…`, whose hash holds `zap`. The failure read as a regression in the change under review and pointed at the wrong code.

Nix store hashes use a base32 alphabet of the digits and the lowercase letters without `e`, `o`, `u`, and `t`, so any short word built from the other letters will turn up in some hash eventually. A store path name can also carry the word on purpose, for example a package called `zapper`.

## Guidance

Before matching a forbidden word in text that holds store paths, replace every whole store path, hash and name, with a fixed word that cannot contain it, and pin that filter with its own regression cases.

```nix
withoutStorePaths =
  text:
  lib.concatStrings (
    map (part: if lib.isString part then part else "/nix/store/STOREPATH") (
      builtins.split "/nix/store/[0-9a-z]{32}-[-+._?=A-Za-z0-9]+" (plain text)
    )
  );
```

- Cut the name too, not only the hash: a hash-only cut still fails on a path named `zapper`. The name is not a command, so the guard loses nothing by ignoring it, and `/nix/store/<hash>-brew/bin/brew uninstall --zap` keeps its `--zap` after the cut.
- Read the widest text the guard means. The fix also moved the zap check from `postActivation` to `system.activationScripts.script.text`, the whole activation, so a `--zap` in another step cannot slip past.
- Pin the filter with cases that do not depend on today's hashes: a hash that spells the word must pass, a store path name that holds it must pass, and a real `--zap` after a store path must fail. The live hash that exposed the bug changes with the next unrelated edit, so it cannot be the regression test.

## Why This Matters

The false positive lands on whoever next changes any input of the generation, usually in an unrelated pull request, and it names a guard that change never touched. The first instinct is to suspect the diff, which wastes the investigation. Here the evidence that settled it was running the same check at `origin/main` (`nix build "git+file://$PWD?rev=<main>#checks.x86_64-linux.darwin-config"`) and then reading the fixture's activation text for the word.

The opposite mistake is just as easy. Narrowing the match to `--zap` or a word boundary would also have hidden the false positive, but it bets that every form the guard exists for spells the flag one way. Replacing store paths keeps the check as strict as before on everything that is not a store path.

## When to Apply

- A check grep-matches a short forbidden token (`zap`, `rm`, `curl`, `sudo`) in an evaluated script or generated file.
- A check fails with no change to its subject: compare against the base revision first, then search the evaluated text for the word inside a `/nix/store/` path.
- Mutation-testing such a filter: widen the cut (for example `{32}-.*`) and confirm the real-`--zap` case fails; narrow it to the hash alone and confirm the store-path-name case fails.

## Examples

Before, a substring check on text that carries store paths:

```nix
(check (!lib.hasInfix "zap" postActivation)
  "${entry.name}: no activation step may zap a cask, since --zap deletes the app's user data")
```

After, the check reads the whole activation with store paths replaced, and the filter carries its own cases (`tests/darwin-config.nix`, `assertZapFilter`):

```nix
activationWithoutStorePaths = withoutStorePaths config.system.activationScripts.script.text;

(check (!lib.hasInfix "zap" (withoutStorePaths "/nix/store/r8m1ldyh1jglwgqzapjizark25g4l97w-activate"))
  "zap check: a store hash that spells zap must not count as a zap")
(check (lib.hasInfix "zap" (withoutStorePaths "/nix/store/r8m1ldyh1jglwgqqapjizark25g4l97w-brew/bin/brew uninstall --cask --zap foo"))
  "zap check: a real --zap after a store path must still count as a zap")
```

Mutation evidence from this session: injecting `--zap` into the retired-cask step's `brew uninstall` failed the check for both fixture variants; widening the cut to `{32}-.*` failed the real-`--zap` case; cutting only the hash failed the store-path-name case.

## Related

- [Mutation testing reveals decorative Nix check assertions](mutation-testing-reveals-decorative-nix-check-assertions.md)
- [A substring check for a required instruction sentence passes when the sentence is negated](substring-sentence-check-passes-a-negated-instruction.md)
- [Fixture state that cannot distinguish a bug from its fix](converged-fixture-state-defeats-nix-check-mutation-testing.md)
