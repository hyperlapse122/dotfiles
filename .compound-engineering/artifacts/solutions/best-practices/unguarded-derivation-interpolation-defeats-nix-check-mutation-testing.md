---
title: "A mutation that only breaks Nix evaluation proves nothing about a check"
date: 2026-09-21
category: best-practices
module: "NixOS flake checks (desktop-packages derivation guard, assertUserPackage)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check resolves a package derivation out of a configuration and interpolates its store path into the builder script"
  - "Mutation-testing a check by removing the thing it asserts on, rather than by corrupting that thing"
  - "Copying the shape of an existing check that only computes booleans into one that needs a derivation"
  - "A mutation round was recorded as caught because the build went red, without reading where it went red"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - optionalstring
  - findfirst
  - lazy-evaluation
  - null-coercion
---

# A mutation that only breaks Nix evaluation proves nothing about a check

## Context

The `feat/kleopatra-gpg-gui` work added `kdePackages.kleopatra` to the user package list in `home/h82/default.nix` and registered a `kleopatra-gui` check in `flake.nix` to guard it. Unlike its sibling `python3-runtime` as it was then, this check could not settle for a boolean: it asserts that the package in the configuration ships `bin/kleopatra` and the `org.kde.kleopatra.desktop` entry, so it needs the derivation itself, resolved with `pkgs.lib.lists.findFirst (p: (p.pname or "") == "kleopatra") null ...`.

That logic now lives in the shared `assertUserPackage` helper in `flake.nix`, which `desktop-packages` (consolidating the former `kleopatra-gui` and `telegram-desktop` checks), `claude-desktop`, `chatgpt`, and `claude-code` call through `forEveryConfiguration`, and `python3-runtime` calls through `forEveryUser`. `userPackageOf` does the `findFirst ... null`, and the helper keeps the guard this doc describes. The snippets below show the original single-check form.

That one difference — a resolved derivation instead of a boolean — changes what the repo's mutation-testing discipline actually measures. The existing learning on [decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) covers assertions that cannot fail. This is the level below it: the assertion here is sound, and the *mutation* is what silently fails to reach it. Nothing about a red mutation round tells you which of the two you are looking at.

## The practice

**When you mutate a check, read where it went red, not only that it went red.** A mutation round has proved the assertion only when the failure came out of the builder and carried the assertion's own message. A failure raised by the Nix evaluator before any builder ran is not evidence about the check; it is evidence that the check does not evaluate under that mutation.

For the `desktop-packages` check (originally `kleopatra-gui`), the two outcomes look identical in a terminal that only watches the exit code:

```sh
# the mutation: drop the package the check guards
sed -i '/kdePackages.kleopatra/d' home/h82/default.nix
nix build --no-link .#checks.x86_64-linux.desktop-packages
```

With the store path interpolated **unguarded**, that command fails with

```text
error: cannot coerce null to a string: null
```

at evaluation time. No derivation is built, no builder output exists, and the check's own `missing kleopatra in user packages` message never prints. The round looks red, an implementer following the repo's discipline records a pass, and the assertion that was supposedly being exercised never ran once. That is a false pass of the mutation round itself.

With the interpolation guarded, the same mutation fails **inside** the builder, and the log carries the intended reason.

## The guard

Route every store-path interpolation through `lib.optionalString`, splitting the builder into an absent branch and a present branch. `lib.optionalString` does not force its string argument when the condition is false, so the null derivation is never coerced when the package is missing:

```nix
absent = pkgs.lib.optionalString (kleopatra == null) ''
  echo 'missing kleopatra in user packages' >&2
  exit 1
'';
present = pkgs.lib.optionalString (kleopatra != null) ''
  if [ ! -x ${kleopatra}/bin/kleopatra ]; then
  ...
'';
```

`assertUserPackage` keeps the same two branches, `optionalString (package == null)` and `optionalString (package != null)`. The comment above it records the constraint, because the guard looks like redundant defensiveness to anyone who has not watched the unguarded version abort.

The two branches are exclusive at the Nix level rather than the shell level: whichever condition is false expands to the empty string, so only one branch's text is ever spliced into the builder at all. The failure exit is still load-bearing. Without it, the absent branch would print its message and then fall through to `touch $out`, and the check would pass while announcing its own failure. The helper sets `fail=1` in place of `exit 1` so that every host is reported, and `forEveryConfiguration` exits after the last host when `fail` is set.

## Why the sibling check hides the trap

When this was written, `python3-runtime` computed only booleans, `pkgs.lib.lists.any (p: (p.pname or "") == "python3") userPackages`, and took its binaries from `nativeBuildInputs`, not from anything resolved out of the user's configuration. Its trailing `python3 --version` and `uv --version` commands sat outside any guard and were safe there, because nothing in them could be null. Its `optionalString` calls did ordinary conditional-text work, not laziness work. It now calls `assertUserPackage` too, but the trap still applies to any new check that copies a boolean-only shape.

Copying that shape for a check that resolves a derivation is exactly what invites the failure. The visible structure is the same; the reason the structure is safe is not.

## What was verified

Four rounds at capture time against the standalone check (now consolidated into `desktop-packages`), each one `nix build --no-link .#checks.x86_64-linux.kleopatra-gui`:

| Round | Tree | Result |
| --- | --- | --- |
| Baseline | guarded, package present | green |
| Removal mutation | guarded, package removed from `home/h82/default.nix` | red **inside the builder**; log shows `missing kleopatra in user packages` then `exit 1` |
| Content mutation | guarded, desktop-entry assertion pointed at a filename the package does not ship | red inside the builder with `kleopatra package ships no ... entry` |
| Control | `optionalString` removed from the assertion block, package removed | `error: cannot coerce null to a string: null` at evaluation; no builder output, no package-name message |

The control round separates the unguarded version from the guarded one. Without it, rounds two and three alone would have read as a clean mutation suite on either version of the check.

## How to apply

- Before mutating, ask what the check's assertions *depend on*. A check that depends only on values computed in the flake (booleans, counts, string comparisons) can be mutated freely. A check that depends on a value resolved out of the configuration — a derivation, an attribute set, a path — can be mutated into non-evaluation instead of into failure.
- Prefer a removal mutation *and* a content mutation. Removal tests the resolution path and the absent branch; content tests the assertion. Passing only one leaves half the check unproven, and removal is precisely the mutation that can break evaluation.
- Read `nix log` for the failing derivation, or keep `set -x` at the top of the builder as this check does. A round that produced no builder output produced no evidence.
- Treat `lib.findFirst ... null` as a signal. The `null` default is the whole hazard: it is what makes the absent case representable, and what makes interpolating the result an evaluation-time trap. Wherever that `null` can reach a string context, guard it.
- Generalise past `optionalString`: any Nix construct that avoids forcing its argument works. The rule is that the failing branch must be reachable as *shell*, not as evaluation.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion-level case: a check green because its assertions could not fail. This doc is the round-level case: a mutation round red for a reason the assertions had no part in. Both defeat the same discipline, and both are found only by reading *why* a check was red rather than *that* it was.

## Out of scope

That Kleopatra launches, finds the user's GPG keyring, and is reachable from the Plasma launcher is hardware and desktop verification; see `CONCEPTS.md` (`Hardware check`) and `AGENTS.md`. A build-time check on the package's contents cannot reach any of it.
