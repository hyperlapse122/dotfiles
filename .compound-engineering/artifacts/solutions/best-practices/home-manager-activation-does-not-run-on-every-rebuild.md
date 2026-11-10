---
title: "Home Manager activation does not re-run when the generation is unchanged"
date: 2026-09-22
category: best-practices
module: "Home Manager activation (claude settings merge)"
problem_type: best_practice
component: activation
severity: medium
applies_when:
  - "A home.activation entry reasserts state that something outside the repository can change between rebuilds"
  - "Documentation, a requirement, or a hardware checklist says activation-time work happens on every rebuild or every switch"
  - "A verification step asks the operator to change a value at runtime, rebuild, and confirm it reverted"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - home-manager
  - activation
  - nixos-rebuild
  - systemd
  - verification
---

## Context

`home/h82/agents/claude.nix` (formerly `home/h82/claude.nix`) declares a `home.activation` entry that merges a declared set of keys into `~/.claude/settings.json`, a file Claude Code owns and rewrites at runtime. The point of the entry is that runtime drift in a declared key gets corrected.

Four places said that correction happens "on every rebuild": the module comment, the former `docs/provisioning.md`, requirement R5 of the plan, and a new hardware checklist item in the former `docs/verification.md` (both manuals have since been removed; settings-tier ownership, activation reassertion, and hardware-check boundaries now live in `CONCEPTS.md` and `AGENTS.md`). The checklist item told the operator to change a declared value with `/config`, run `nixos-rebuild switch`, and confirm the value reverted — adding that a value which survives "means the merge did not run".

Followed literally, that check fails on a correctly working mechanism, because the merge genuinely does not run.

## Guidance

Activation-time work is reasserted on every rebuild **that produces a new Home Manager generation**, not on every `nixos-rebuild switch`. State the guarantee that way in comments, requirements, and docs, and write any verification step so it changes something in the repository in the same rebuild.

Do not phrase an activation-time guarantee as "on every rebuild", "on every switch", or "on activation" without qualification. A reader takes those as unconditional, and the one case that matters — the user changed something at runtime and nothing else changed — is exactly the case where they are false.

## Why it holds

Home Manager's NixOS module renders one systemd unit per user. On this host:

```ini
X-StopIfChanged=false
ExecStart=/nix/store/…-hm-setup-env /nix/store/…-home-manager-generation
RemainAfterExit=yes
Type=oneshot
```

Three properties combine. The unit is a `oneshot` with `RemainAfterExit=yes`, so once it has run it stays `active` rather than returning to `inactive`. Its `ExecStart` embeds the Home Manager generation's store path, so the unit file's contents are a function of that generation. And `switch-to-configuration` acts only on units whose definition changed between the old and new system closures.

So a rebuild whose Home Manager generation is byte-identical produces a byte-identical unit file, `switch-to-configuration` classifies it as unchanged, and the already-active oneshot is left alone. Its activation script — every `home.activation` entry, including one after `installPackages` — does not execute. Nothing reports this, because nothing failed.

Editing anything that feeds the generation (a declared value, a package, a dotfile) changes the generation path, changes the unit, and makes the unit restart, which is why the mechanism looks unconditional during development: an author testing a change is always in the case where it does run.

## How to check

Read the unit out of the built closure rather than reasoning about it:

```sh
nix build --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.toplevel
grep -E 'Type|RemainAfterExit|ExecStart' \
  <result>/etc/systemd/system/home-manager-<user>.service
```

If `ExecStart` carries a generation store path and the unit is a `RemainAfterExit` oneshot, the guarantee is conditional on the generation changing.

## Scope and limits

This is about whether activation *runs*, not about whether an activation script is correct. A script that is wrong will also be wrong when it does run.

It applies to Home Manager as a NixOS module, where activation is driven by a system unit. A standalone `home-manager switch` invoked directly runs activation unconditionally, so the same repository can show both behaviours depending on how it is applied. Both other host kinds here run it unconditionally. On a non-NixOS Linux host, `scripts/nr-linux` runs the generation's `activate` directly after the system layer. On a macOS host, Home Manager's nix-darwin module runs each user's `activate` from `system.activationScripts.postActivation`. So on those hosts every apply reasserts, and the conditional guarantee is specific to NixOS hosts.

It is not specific to this repository's settings merge. Any `home.activation` entry whose job is to reassert state that drifts between rebuilds inherits the same conditional guarantee — the more the entry exists to correct outside changes, the more the gap matters, because outside changes are precisely what does not change the generation.

The related checks under `.compound-engineering/artifacts/solutions/best-practices/` cover a different failure: an assertion that cannot go red. This one is not an assertion problem. `tests/claude.nix` correctly asserts that the activation entry exists and is ordered after `installPackages`; no check can observe whether `switch-to-configuration` chose to restart the unit, so only the wording in the docs could keep the operator from filing a false bug report.
