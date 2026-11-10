---
title: "A declared line identical to a distribution default makes a verbatim check vacuous"
date: "2026-10-15"
category: best-practices
module: NixOS flake checks (udev rules)
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A check asserts that a line the repository declares appears verbatim in a materialized output, such as a udev rules directory, a tmpfiles.d directory, or a generated config file"
  - "The same output also carries files shipped by systemd, nixpkgs, or another upstream package"
  - "The declared line pins a value that an upstream file already sets today, so the repository's line restates the current default"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - udev
  - systemd
  - verbatim-match
---

# A declared line identical to a distribution default makes a verbatim check vacuous

## Context

Issue #213 pinned the host's `/dev/kvm` mode to 0666 for rootless Podman containers. Before the fix, the host got 0666 only from systemd's `dev-kvm-mode` build default. `modules/nixos/services/podman.nix` declared the udev rule, and `tests/udev-device-access.nix` asserted that this rule, matched verbatim, was the last rule in the materialized `/etc/udev/rules.d` that assigned `/dev/kvm` a `MODE`.

When review asked for `OPTIONS+="static_node=kvm"`, the working draft of the rule became `KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"`; that draft was never committed. systemd's own `50-udev-default.rules` ships exactly this line (line 116 in the systemd 261.3 rules this flake builds). The positive branch therefore passed with the repository's rule deleted, because systemd's copy matched the same text. The check was green and guarded nothing. It failed only on its negative branch: the production configuration re-evaluated with `my.podman.enable` forced off still carried the "declared" line, because systemd shipped it.

## Guidance

Before you assert a declared line verbatim in a materialized output, grep the built output for that exact text with the declaration removed. If an upstream file already carries it, make the repository's line textually distinct while keeping it semantically equivalent. Then a verbatim match can find only the repository's rule.

For udev, reordering assignment keys changes nothing about the rule's effect. `modules/nixos/services/podman.nix:38` now reads `KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"`, with a comment saying why `MODE` comes before `GROUP`. The check pins that exact text (`tests/udev-device-access.nix:105`).

Mutation-test every such check by **deleting the declaration**, not only by weakening it. A weakened line, such as one with `static_node` dropped, still differs from upstream and fails, so that mutant cannot reveal the coincidence. Only the deleted one can.

A check that reads "the last line matching a pattern" also needs a pattern that matches every form a competing line can take. In the same change, the scan first missed a later rule written `MODE="0600", KERNEL=="kvm"` and an earlier `MODE:=` that pins the mode against later rules. `tests/udev-device-access.nix:206` matches either key order, and the check fails on any `MODE:=` (`tests/udev-device-access.nix:225`).

## Why This Matters

Pinning a value the platform already sets is the usual reason to declare it at all: the declaration protects against the default changing. That is also exactly when the declared text tends to equal the default's text, so the check reads the upstream copy and goes on passing after the declaration is gone. Nobody notices until upstream changes the default, which is the event the declaration and the check were both meant to catch.

## When to Apply

- Writing or reviewing a check that matches a declared line with `grep -Fx` or equality against files under `/etc` or another built tree that merges upstream packages.
- Declaring a udev rule, tmpfiles entry, sysctl, or similar setting whose value restates a systemd or nixpkgs default.
- Choosing mutants for such a check: include "remove the declaration" alongside "change the declared value".

## Examples

Before, the check passed with the declaration removed:

```nix
services.udev.extraRules = ''
  KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"
'';
```

```text
$ grep -n 'KERNEL=="kvm"' <rules.d>/50-udev-default.rules
116:KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"
```

After, the rule is distinct from systemd's, and deleting it fails the check:

```nix
services.udev.extraRules = ''
  KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"
'';
```

```text
MS-7D91: the last rule assigning /dev/kvm a MODE is not: KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"
```

The same caution applies to the tmpfiles entry `z /dev/kvm 0666 - kvm -` the fix declares. systemd's `static-nodes-permissions.conf` writes `z /dev/kvm          0666 - kvm -` with extra spaces, so an exact-line match does not confuse the two. A whitespace-normalizing match would.

Related: [mutation testing reveals decorative Nix check assertions](mutation-testing-reveals-decorative-nix-check-assertions.md); [a fixture that starts two sources equal](converged-fixture-state-defeats-nix-check-mutation-testing.md), the same blind spot in a test fixture rather than in a built output; and [a check that splits outputs by the trait it guards cannot catch a widened default](trait-split-check-cannot-catch-a-widened-default.md). Here the trait split's negative branch, which that learning describes, is what exposed the coincidence.
