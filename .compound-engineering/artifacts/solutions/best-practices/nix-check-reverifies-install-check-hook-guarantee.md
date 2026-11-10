---
title: "A flake check that re-executes a binary can duplicate a guarantee its derivation's own install-check hook already enforced"
date: 2026-09-23
category: best-practices
module: "NixOS flake checks (claude-code version-pin guard)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Writing or reviewing a flake check that asserts a property of a built package by re-running the package's own binary and re-parsing its output, such as `actualVersion=$(${pkg}/bin/foo --version)`"
  - "The package's own derivation already declares an install-check mechanism (`doInstallCheck` with `nativeInstallCheckInputs = [ ... versionCheckHook ... ]`, or an equivalent custom `installCheckPhase`) that enforces the same property unconditionally at build time"
  - "The check's real purpose is catching a wiring regression upstream of the build (an override argument silently not taking effect), not verifying anything intrinsic to the binary itself"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - install-check-hook
---

## Context

While adding `checks.claude-code` (a guard for the claude-code manifest-override pin — see `.compound-engineering/artifacts/plans/2026-09-23-1652-feat-claude-code-auto-update-plan.md`, KTD5), the first draft asserted the built package's version by shelling out and re-parsing the binary's own output:

```nix
actualVersion=$(${claudePkg}/bin/claude --version)
case "$actualVersion" in
  *"${pinnedVersion}"*) ;;
  *)
    echo "claude-code on ${hostName} reports version '$actualVersion', expected pin ${pinnedVersion}" >&2
    exit 1
    ;;
esac
```

nixpkgs' `claude-code` derivation (`pkgs/by-name/cl/claude-code/package.nix`, at this repo's locked nixpkgs revision) already declares:

```nix
doInstallCheck = true;
nativeInstallCheckInputs = [ writableTmpDirAsHomeHook versionCheckHook ];
versionCheckKeepEnvironment = [ "HOME" ];
versionCheckProgramArg = "--version";
```

`versionCheckHook` already runs `bin/claude --version` during the derivation's own build and fails the build outright unless the output matches `finalAttrs.version` — the exact `manifest.version` this repo's override argument supplies. By the time `${claudePkg}` successfully evaluates to a built store path inside the check's shell (forced by interpolating it at all), that guarantee has already been discharged. The check's own re-invocation was proving something Nix had already proven.

## Guidance

Before writing a check that re-executes a package's binary (or otherwise redoes work) to verify a property of the built output, check whether the package's own derivation already enforces that property unconditionally at build time via an install-check mechanism (`doInstallCheck` + `nativeInstallCheckInputs`/`versionCheckHook`, a custom `installCheckPhase`, or an equivalent). If it does, and the check already forces the build (by interpolating `${pkg}` or similar), read the already-verified value from a plain derivation attribute instead of re-executing anything:

```nix
versionMismatch = pkgs.lib.optionalString (claudePkg != null && claudePkg.version != pinnedVersion) ''
  echo "claude-code on ${hostName} is built from version '${claudePkg.version}', expected pin ${pinnedVersion}" >&2
  exit 1
'';
```

## Why This Matters

The eval-time attribute read catches the exact same regression class — an override silently not taking effect, so the package builds from a stale or wrong pin — with identical guard strength, because `claudePkg.version` and the binary's own `--version` output are already forced to agree by the upstream hook. It needs zero shell execution of the binary and one fewer parsing step to get wrong, and it drops a needless dependency on the exact `--version` output format (extra wrapping text such as `"(Claude Code)"`) that a re-parse would otherwise have to tolerate.

Verified in this session: `nix build .#checks.x86_64-linux.claude-code` produced identical pass/fail behavior before and after the simplification, confirmed by re-running both of the check's mutation rounds (package removed from `home.packages`; package present but resolving to a stale/unpinned version) against the eval-time version and observing the same failures with the same messages.

## When to Apply

Any time a new flake check's first instinct is "run the binary and check its output" for a property (version, a compiled-in constant, a build flag) that the binary's own package derivation could plausibly already assert via an install-check hook. Check the derivation source — at the locked revision, since the hook's presence is a fact about that specific revision, not about the package in general — for `doInstallCheck`, `installCheckPhase`, `versionCheckHook`, or a package-specific equivalent before writing the shell-level re-check.

Does not apply when the property being checked is not one the derivation's own build step already enforces — for example, asserting that two independently-computed consumers of a package resolve to the identical store path (`tests/agent-plugins.nix`'s claude-code consumer-consistency check, added in the same session) needed no install-check hook, because no single derivation's build step touches both consumers; there is nothing upstream for a hook to have already verified.

## Examples

- Before/after diff above (`checks.claude-code` in `flake.nix`, this session).
- Before adding a runtime `--version` / `--help` / `-V` shell-out to a new flake check for any other package already in `home.packages`, check whether that package's own derivation already runs the same check via `versionCheckHook` or an equivalent.
