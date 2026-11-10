---
title: "A check that reads an option value passes when the option is disabled or renamed"
date: 2026-09-21
category: best-practices
module: "NixOS flake checks (claude managed settings, Home Manager files)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check asserts on a NixOS or Home Manager option value such as environment.etc.<name>.text or home.file.<name>.text"
  - "A check decides whether a file is managed by testing for an attribute name rather than the destination that attribute resolves to"
  - "Mutation testing a check by changing what the module declares, without also changing whether that declaration reaches the activated system"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - home-manager
  - environment-etc
  - option-defaults
---

# A check that reads an option value passes when the option is disabled or renamed

## Context

This example describes `tests/claude.nix` as it stood when this learning was written. The managed settings tier has since been retired: the defaults now merge into `~/.claude/settings.json` at activation, and the check asserts that no `environment.etc` entry declares `claude-code/managed-settings.json`. The lesson about reading the materialized output still applies.

At the time, `tests/claude.nix` guarded the declarative Claude Code defaults: `/etc/claude-code/managed-settings.json` had to set `autoMemoryEnabled`, `model`, and `effortLevel`, and Home Manager must not own `~/.claude/settings.json`. The obvious way to write both assertions is to read the option the module sets:

```nix
managedSettingsJson = host.config.environment.etc."claude-code/managed-settings.json".text or null;
claudeUserSettingsManaged = userConfig.home.file ? ".claude/settings.json";
```

Both assertions are sound, both fail on the mutations a reviewer reaches for first (change the value, delete the key), and both are green while the property they exist to protect can already be false.

This is a level above the two learnings this repository already carries. [Decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) are assertions that cannot fail. [A mutation that only breaks evaluation](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) is a mutation that never reaches a sound assertion. Here the assertion runs, fails correctly on the value it reads, and still misses — because the value it reads is a *proxy* for the thing the check claims, and the option system can break the link between the two.

## The two gaps

**An `environment.etc` entry carries an `enable` flag beside its `text`.** Set `enable = false` and `text` keeps evaluating to the same JSON, so a check reading `.text` stays green, while the NixOS etc module skips the entry and the activated host has no file at all: no model, no effort level, no memory kill switch. The check asserts what the module *declares*, not what activation *writes*.

**Home Manager resolves each `home.file` entry's destination from its `target`, which merely defaults to the attribute name.** So

```nix
home.file.claudeSettings = {
  target = ".claude/settings.json";
  text = "{}";
};
```

lands a file at exactly the forbidden path while `home.file ? ".claude/settings.json"` is still false. The check reports that nothing manages the file and passes, and activation is left to collide with the file Claude Code owns and rewrites.

Neither gap is reachable by mutating a value. Both are reached by mutating *how the declaration is wired*, which is the mutation category a value-focused round never tries.

## The guard

Assert the thing that decides the outcome, not the attribute that usually implies it:

```nix
managedEnabled=${esc (lib.boolToString (entry.enable or false))}
if [ "$managedEnabled" != "true" ]; then ... exit 1; fi

claudeSettingsTargeted = lib.any (
  file: (file.target or "") == ".claude/settings.json"
) (lib.attrValues userConfig.home.file);
```

The `or` fallbacks keep the earlier learning's rule intact: a removed entry still fails inside the builder rather than during evaluation.

Today `tests/claude.nix` applies the `target` half to the merged `~/.claude/settings.json` and `~/.claude.json` and asserts that no `environment.etc` entry declares `claude-code/managed-settings.json`; the `enable` half stays as a general lesson for any `environment.etc` entry.

## What was verified

Each round is `nix build --no-link .#checks.x86_64-linux.claude`.

| Round | Mutation | Before the guard | After the guard |
| --- | --- | --- | --- |
| 1 | `enable = false` beside `text` in `modules/nixos/claude.nix` (historical: that module no longer exists) | green — the host writes no file | red, in the builder: `Expected /etc/claude-code/managed-settings.json to be enabled` |
| 2 | `home.file.claudeSettings` with `target = ".claude/settings.json"` | green — the file is managed anyway | red, in the builder: `Home Manager must not target ~/.claude/settings.json` |
| 3 | value and key mutations on `model`, `effortLevel`, `autoMemoryEnabled` | red | red |

Round 3 is the control: the value mutations were already caught by the original check, which is exactly why the first two gaps were invisible. A mutation suite that only edits values scores full marks on a check with both holes in it.

## How to apply

- For each assertion, name the property in plain words ("activation writes this file", "nothing manages this path"), then ask which option values could make that property false. Every one of them belongs in the assertion, not just the one the module happens to set.
- Watch for options whose effect is gated by a sibling: `environment.etc.<name>.enable`, `home.file.<name>.enable`, and any `mkIf` around the module itself. A default of `true` is what makes the gate easy to forget.
- Watch for options whose key is a default rather than the contract: `home.file.<name>.target`, `environment.etc.<name>.target`. Assert over resolved values with `lib.any` on `lib.attrValues`, never over attribute names.
- Add a wiring mutation to every round: disable the entry, rename the attribute, gate the module on a condition. These are the mutations that separate a check on the output from a check on the declaration.
- Assert every host the option should hold on. Both checks here originally read only the production configuration, so a change gating either module on `config.my.bootstrap` would have left the bootstrap system unguarded and every check green.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion cannot fail.
- [A mutation that only breaks Nix evaluation proves nothing about a check](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — the mutation never reaches the assertion.
- This doc — the assertion runs and passes, on a value that no longer stands for the property.

## Out of scope

Whether Claude Code actually honored the managed settings tier at runtime — or whether an installed host cleared the retired `/etc/claude-code/managed-settings.json` file on switch — is a post-activation check on the live machine, not a build-time question (see `CONCEPTS.md` and `AGENTS.md`).
