---
title: "lib.hasInfix over a whole activation script overflows the Linux Nix evaluator's stack"
date: 2026-10-28
category: logic-errors
module: "macOS fixture checks (tests/darwin-config.nix)"
problem_type: test_failure
component: testing_framework
severity: medium
symptoms:
  - "checks.x86_64-linux.darwin-config failed in CI's flake-check and check-shards (light-3) jobs with \"error: stack overflow (possible infinite recursion)\""
  - "The same evaluation succeeded on macOS and in an arm64 Linux container with the same Nix version"
  - "The failure appeared when a change only made the nix-darwin system activation script longer, by adding Dock defaults with long persistent-apps plists"
root_cause: wrong_api
resolution_type: test_fix
related_components:
  - development_workflow
tags:
  - nix
  - nix-darwin
  - flake-checks
  - regex
  - stack-overflow
  - hasinfix
  - darwin-config
---

# lib.hasInfix over a whole activation script overflows the Linux Nix evaluator's stack

## Problem

A check that searches a long generated string with `lib.hasInfix` can fail evaluation on Linux with a stack overflow, even though nothing recurses forever and the same check evaluates on macOS. In PR #407, adding Dock defaults to the macOS fixture made `checks.x86_64-linux.darwin-config` fail in CI, without any change to the checks that overflowed.

## Symptoms

- `error: stack overflow (possible infinite recursion)` right after `checking derivation checks.x86_64-linux.darwin-config...` in `nix flake check --no-build`, and the same error in the `check-shards (light-3)` build.
- No failure on macOS, and none in an arm64 Linux container running CI's Nix 2.35.2 at its default stack.

## What Didn't Work

- Suspecting the new Dock assertions: removing `assertDock` entirely left the branch just as deep. Taking `modules/darwin/dock.nix` out of the profile was what restored `main`'s depth, so the configuration change, not the new test, triggered it.
- Running the zap check's `builtins.split` store-path regex line by line: no change. That regex starts with a literal (`/nix/store/`), and each match attempt stays short.
- Reproducing in an emulated `--platform linux/amd64` container: Nix segfaulted there even on `main`, so it proves nothing. A cached amd64 image also silently replaced the arm64 one until `--platform linux/arm64` was forced.

## Solution

Search a long text one line at a time when the infix holds no newline. `tests/darwin-config.nix` now defines:

```nix
hasInfixInLines = infix: text: lib.any (lib.hasInfix infix) (lib.splitString "\n" text);
```

It replaces `lib.hasInfix` in the three checks that searched whole activation scripts: the zap check, and the TLS inspection CA checks on `afterEtc` and, in bootstrap, the whole `script`. After the change the check evaluates within a 48 MiB stack, where `main` itself overflows.

## Why This Works

nixpkgs defines `lib.hasInfix` as `builtins.match ".*${escapeRegex infix}.*"` (its `lib/strings.nix`, in the pinned nixpkgs input rather than this repository). Nix on Linux links libstdc++, whose `std::regex` backtracking executor recurses about once per character a `.*` consumes, so stack use grows with the length of the string. Nix asks for a 60 MiB stack; a full nix-darwin activation script, with multi-kilobyte XML plists in it, needs about that much. Measured with `ulimit -Ss N; ulimit -Hs N` on arm64: `main` evaluated at 56 MiB, while the branch with Dock plists needed all 60 MiB. x86_64 frames are larger, so CI went over. On macOS, Nix links libc++, whose regex does not recurse this way, which is why it never reproduced locally. Lines are short, so each `hasInfix` call stays shallow.

## Prevention

- Never run `lib.hasInfix`, `builtins.match`, or a `.*`-heavy `builtins.split` over a whole generated script or file in a check; split it into lines first, or match a bounded slice.
- To test a stack hypothesis off CI, evaluate the check's `drvPath` in `docker.io/nixos/nix:<CI version>` forced to `--platform linux/arm64`, under a lowered `ulimit -Hs`, for `main` and the branch side by side. Exit 139 is the overflow, and Nix prints "Stack size hard limit ... less than the desired 62914560" as a warning, not a failure. The container setup is in [build aarch64-linux outputs on macOS in a Podman Nix container](../best-practices/build-aarch64-linux-outputs-on-macos-in-a-podman-nix-container.md).
- A change that only lengthens activation text (new defaults, plists, embedded files) can break a check it never touched; run `nix flake check --no-build` on Linux, or the container method above, before pushing such a change.

## Related Issues

- PR #407 (Dock defaults on macOS hosts), where the fix landed.
- [Verify a Linux-only Nix check's text inputs on macOS through nix derivation show](../best-practices/verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md): evaluating on macOS does not reproduce Linux evaluator limits.
