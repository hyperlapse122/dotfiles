---
title: Build aarch64-linux outputs on the macOS host in a Podman Nix container
date: "2026-10-20"
category: best-practices
module: "Nix packages and flake checks (local verification on macOS)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Changing a Linux-only package, such as an Electron app repackaged from a .deb, while working on the macOS host, which has no Linux builder"
  - "A Linux build failure, such as autoPatchelf finding no provider for a library, would otherwise surface only in CI"
  - "Building a non-NixOS fixture's Home Manager or system-manager output before pushing"
  - "Checking that an AppArmor profile parses on the Ubuntu release it targets"
tags: ["macos", "aarch64-darwin", "aarch64-linux", "linux-builder", "podman", "libkrun", "nixos-nix-image", "autopatchelf", "electron", "deb", "apparmor", "verification"]
related_components:
  - tooling
retire_when: "The macOS host gains a Linux builder (a nix-darwin linux-builder or a remote builder), so `nix build` reaches Linux outputs directly"
---

# Build aarch64-linux outputs on the macOS host in a Podman Nix container

## Context

The macOS host has no Linux builder, so `nix build` cannot produce a Linux package or a `checks.*-linux` output there. [Verify a Linux-only Nix check's text inputs on macOS through nix derivation show](verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md) covers what evaluation alone can prove. Evaluation cannot catch a build-time failure. While adding Grok Bot (`packages/grok-bot.nix`, built from xAI's `.deb`), code review found that the four native Node addons under `resources/app.asar.unpacked` need `libstdc++.so.6`, which no `buildInputs` entry provided, so `autoPatchelfHook` would fail the build on Linux. Without a local builder, the only proof that the fix worked would have been the first CI run. Grok Bot, its package, and its AppArmor profile were later removed (issue #284), so the Grok Bot paths below are the historical case; substitute the package or profile you are changing.

The host already runs a Podman machine for the container setup (`podman machine list` shows `podman-machine-default`, VM type `libkrun`, and `podman info` reports `arm64 linux`). That VM can run the official `nixos/nix` image and build aarch64-linux outputs for real.

## Guidance

Copy the committed tree under `$HOME`, start `docker.io/nixos/nix:latest` with that copy mounted, and build inside the container:

```sh
S=$HOME/.cache/nix-config-src
rm -rf "$S" && mkdir -p "$S" && git archive HEAD | tar -x -C "$S"
podman run --rm -v "$S":/src:ro docker.io/nixos/nix:latest sh -c '
  printf "experimental-features = nix-command flakes\nfilter-syscalls = false\nsandbox = false\n" >> /etc/nix/nix.conf
  cp -r /src /work && cd /work && git init -q && git add -A
  nix build --no-link --print-out-paths "path:/work#checks.aarch64-linux.<fixture check>"
'
```

The flake exposes no `packages.aarch64-linux`, so to build one package, import it against the flake's own nixpkgs:

```sh
nix build -L --no-link --impure --expr '
  let f = builtins.getFlake "path:/work";
      pkgs = import f.inputs.nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; };
  in import /work/packages/<package>.nix { inherit pkgs; }'
```

Each step in this setup works around a failure seen while finding it:

- The source must live under `$HOME`. The Podman machine does not share the macOS `/tmp`, so `-v /tmp/...` fails with `statfs /tmp/...: no such file or directory`.
- `git archive HEAD` copies only committed files, so commit or stage the change first, or copy the working tree instead.
- The container's `nix.conf` needs flakes enabled, and `filter-syscalls = false` and `sandbox = false` to build inside an unprivileged container.
- The mount is read-only, and Nix wants a writable flake source. Copy it to `/work`. `git init && git add -A` makes the copy usable as a flake, and `path:/work#…` avoids git's dirty-tree rules.
- The VM is arm64, so only aarch64-linux outputs build. An `x86_64-linux` check such as `non-nixos-outputs` still needs CI's `check-shards` jobs or the evaluation-only method in the linked learning.

For an AppArmor profile, an `ubuntu:24.04` container runs the distribution's own parser, which is the one a non-NixOS host would load the profile with:

```sh
podman run --rm -v "$HOME/.cache/profile":/p:ro docker.io/library/ubuntu:24.04 sh -c '
  apt-get update -qq && apt-get install -y -qq apparmor >/dev/null
  cp /p/<profile> /etc/apparmor.d/ && apparmor_parser --skip-kernel-load --debug /etc/apparmor.d/<profile> >/dev/null && echo PARSE_OK'
```

## Why This Matters

These builds caught what evaluation could not. The Grok Bot build (since removed) reported `auto-patchelf: 0 dependencies could not be satisfied` after `pkgs.stdenv.cc.cc.lib` joined `buildInputs` (`packages/grok-bot.nix`). Running the built `bin/grok-bot` as the container's root user reached Electron's `Running as root without --no-sandbox is not supported`, which shows every shared library loaded and execution reached Electron's main code. Building `checks.aarch64-linux.non-nixos-system-<fixture>` and `non-nixos-home-<fixture>` proved the system-manager AppArmor module and the Home Manager generation build. The Ubuntu container showed AppArmor 4.0.1 accepts the profile's `abi <abi/4.0>` line.

Without this, each of those would have been a push, a wait for CI, and another push.

## When to Apply

- Before pushing any change to a Linux package's build steps, its `buildInputs`, its patching, or its unpacking.
- When a reviewer claims a Linux build will fail, so the claim can be tested instead of argued.
- Not for `x86_64-linux`-only checks. The VM cannot run them, so use the evaluation-only method and leave the build to CI.

## Examples

Confirm a reported missing library before fixing it. Unpack the `.deb` on the Mac and read each ELF file's `NEEDED` entries with `nix shell nixpkgs#llvm -c llvm-readelf -d <file>`. Then rebuild in the container and look for the `auto-patchelf` summary line:

```text
grok-bot> auto-patchelf: 0 dependencies could not be satisfied
```

The same build log shows whether a `postFixup` step that restores static-pie binaries ran, and whether the wrapper carries `unset APPIMAGE` (`grep -x 'unset APPIMAGE' $out/bin/grok-bot`).
