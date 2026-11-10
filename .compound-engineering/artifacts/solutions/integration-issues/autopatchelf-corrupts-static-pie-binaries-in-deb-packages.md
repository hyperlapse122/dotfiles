---
title: "autoPatchelfHook corrupts static-pie and prebuilt Go binaries bundled in a .deb, and postFixup runs before the hook"
date: "2026-10-01"
category: integration-issues
module: "ChatGPT, T3 Code CLI, and WiFiman Desktop packages (packages/chatgpt.nix, packages/t3code-cli.nix, packages/wifiman-desktop.nix)"
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "The bundled resources/codex, rg, and codex-code-mode-host segfault (exit 139) even on --version after the build"
  - "readelf -d shows a RUNPATH on those files, although they are static-pie executables with no PT_INTERP"
  - "Restoring the set-aside originals from the derivation's postFixup attribute leaves the patched files in place, because the restore runs before the patching"
  - "A presence-only flake check passes, because the patched binary still exists and is executable"
  - "The WiFiman Desktop .deb's dynamically linked Go binaries (wg, wireguard-go, wifiman-desktopd) segfault (exit 139) once any RUNPATH is added, although ldd resolves every library"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - testing_framework
tags: ["autopatchelf", "static-pie", "nixpkgs", "stdenv", "postfixup", "postfixuphooks", "deb-package", "flake-checks", "go", "runpath", "wifiman"]
retire_when: "auto-patchelf in nixpkgs skips static-pie executables (ET_DYN with no PT_INTERP) in is_static_executable; check pkgs/by-name/au/auto-patchelf/source/auto-patchelf.py in the locked nixpkgs rev. The Go-binary section retires only when `patchelf --add-rpath` leaves the WiFiman .deb's wg and wireguard-go runnable"
---

# autoPatchelf adds a runpath to static-pie binaries, and an implicit postFixup cannot undo it

## Problem

The problem first appeared in the ChatGPT desktop package. It was removed on 2026-10-17 and restored on 2026-10-24 with the static-pie workaround intact; `packages/t3code-cli.nix` also carries the workaround. The original ChatGPT package repackaged the upstream `.deb` with `autoPatchelfHook` and set `appendRunpaths` to libGL and libpulseaudio so Chromium could `dlopen` them. The ChatGPT 26.928.31416 `.deb` also bundled three static-pie binaries under `lib/chatgpt` in the built package output: `resources/codex`, `resources/rg`, and `resources/codex-code-mode-host`. autoPatchelf gave each of them a `RUNPATH`, and they segfaulted.

autoPatchelf's static-binary skip does not cover static-pie, so the binaries have to be protected by hand. The first attempt at that also failed, because of the order in which stdenv runs a `postFixup` attribute and the `postFixupHooks` array.

## Symptoms

- `resources/codex --version` and `resources/rg --version` in the built package exit with status 139 (SIGSEGV).
- `readelf -d` on the bundled binaries shows a `RUNPATH` of `<libglvnd>/lib:<libpulseaudio>/lib`, the `appendRunpaths` value, on files that have no `DT_NEEDED` entries and no interpreter.
- `file -b` reports them as `static-pie linked`, which is ELF type `ET_DYN` with no `.interp`.
- The ChatGPT package's original flake check stayed green the whole time. It asserted only that `bin/chatgpt` is executable, that the desktop entry exists, and that the wrapper has no ozone flag. Every bundled file was present and executable, so the check never noticed that the binaries crashed.

## What Didn't Work

**Trusting autoPatchelf to skip static binaries.** It does skip some. The `pkgs/...` paths cited below are files in the flake's locked nixpkgs input (`nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath'`), not in this repository. `is_static_executable` returns true only for `e_type == 'ET_EXEC'` with no `.interp` section (`pkgs/by-name/au/auto-patchelf/source/auto-patchelf.py:34-36`), and `auto_patchelf_file` skips only those files (`auto-patchelf.py:364-367`). A static-pie binary is `ET_DYN`, so it is not skipped. It gets no interpreter, because `is_dynamic_executable` checks for `.interp` (`auto-patchelf.py:40-44`, used at `:403`), but `append_rpaths` is still added to its rpath (`auto-patchelf.py:471`), and any non-empty rpath is written with `patchelf --set-rpath` (`auto-patchelf.py:485-489`). In the ChatGPT package that rpath was never empty, because `appendRunpaths` was always set. In `packages/t3code-cli.nix` it is empty today, because nothing sets `appendRunpaths` or `runtimeDependencies`, but that is one attribute away.

**Setting the binaries aside in `installPhase` and restoring them in the `postFixup` attribute.** The idea was to copy each static-pie file to `$TMPDIR` before the hook ran and to copy it back in `postFixup`, assuming the automatic patching had already happened by then. The restored files still had the `RUNPATH`. The automatic hook does not run before `postFixup`. It is registered as an element of the array, `postFixupHooks+=(autoPatchelfPostFixup)` (`pkgs/by-name/au/autoPatchelfHook/auto-patchelf.sh:104`), and `fixupPhase` ends with `runHook postFixup` (`pkgs/stdenv/generic/setup.sh:1658`). `runHook` iterates `"_callImplicitHook 0 $hookName"` first and the `${hookName}Hooks` array after it (`setup.sh:203-217`, the loop at `:211`). `_callImplicitHook` evaluates the derivation's `postFixup` string (`setup.sh:246-259`). So the restore ran first, and `autoPatchelfPostFixup` then patched the restored originals.

## Solution

Turn off the automatic hook and call `autoPatchelf` from the `postFixup` attribute, followed by the restore. The phase then controls the order itself.

Before (the failed attempt, never committed; `installPhase` already set the files aside):

```nix
  postFixup = ''
    # Runs before autoPatchelfPostFixup, so the restored files get patched anyway.
    (cd "$TMPDIR/static-pie" && find . -type f -print0 | while IFS= read -r -d "" file; do
      install -Dm755 "$file" "$out/lib/chatgpt/$file"
    done)
  '';
```

After, as `packages/t3code-cli.nix` carries it today (`packages/t3code-cli.nix:57-71` and `:84-90`):

```nix
  installPhase = ''
    ...
    mkdir -p "$TMPDIR/static-pie"
    find . -type f -exec file -0 -- {} + | while IFS= read -r -d "" path && IFS= read -r type; do
      case $type in
        *'static-pie linked'*) install -Dm755 "$path" "$TMPDIR/static-pie/$path" ;;
      esac
    done
    ...
  '';

  dontAutoPatchelf = true;
  postFixup = lib.optionalString isLinux ''
    autoPatchelf -- "$out"
    (cd "$TMPDIR/static-pie" && find . -type f -print0 | while IFS= read -r -d "" file; do
      install -Dm755 "$file" "$out/libexec/t3code/$file"
    done)
  '';
```

`pkgs.file` is in `nativeBuildInputs` (`packages/t3code-cli.nix:31-34`) for the detection. The files are found by their `file` type rather than by a fixed list of names, so a static binary added in a later release is protected too. On x86_64 that covers the Cursor SDK's `rg` and `cursorsandbox`; the arm64 tarball has none, because its `rg` is `ET_EXEC`, which is why the set-aside directory is created even when nothing is set aside.

The `t3code` check in `flake.nix` runs the binaries instead of only checking that they exist: `t3 --version`, and the bundled static-pie `rg` under `node_modules/@cursor/sdk-<platform>/bin/rg`, which fails with "the bundled static-pie rg in t3code-cli does not run".

When the fix was first made in the ChatGPT package, the bundled binaries reported `codex-cli 0.159.2` and `ripgrep 15.2.0`, and the ChatGPT Electron binary kept its `RUNPATH`, so the libGL and libpulseaudio `dlopen` path was unchanged. As a mutation test in that session, re-enabling the automatic hook turned the ChatGPT package's check red.

## Why This Works

`dontAutoPatchelf` makes `autoPatchelfPostFixup` return without doing anything (`auto-patchelf.sh:95`), but the hook still defines the `autoPatchelf` shell function (`auto-patchelf.sh:42-84`). That function reads the same `appendRunpaths` and `autoPatchelfIgnoreMissingDeps` attributes (`auto-patchelf.sh:56-57`), so calling it from `postFixup` patches the same way the automatic hook would. Because the call and the restore are in one string, they run in the order they are written. The static-pie files are patched along with everything else and then overwritten with the unpatched copies saved before `$out` existed. Every other ELF file, the Electron binary included, keeps its patched interpreter and runpath.

A static-pie binary relocates itself at startup and has no dynamic loader that would read a `RUNPATH`, so the entry does nothing useful. Rewriting the file with `patchelf --set-rpath` is what left these binaries segfaulting (exit 139). This session did not establish the exact mechanism inside the binary, only that the patched files crash and the unpatched ones run. Leaving them byte-for-byte as shipped avoids the problem.

## Prevention

- When a package uses `autoPatchelfHook` with `appendRunpaths` or `runtimeDependencies`, run `file` over the unpacked tree and look for `static-pie linked`. autoPatchelf skips only `ET_EXEC` static binaries (`auto-patchelf.py:34-36`), so a static-pie binary will be patched.
- Do not try to undo the hook's work in the `postFixup` attribute. A derivation's own `pre*`/`post*` string runs before that hook's `*Hooks` array (`setup.sh:211`), so it cannot run after `autoPatchelfPostFixup`. Set `dontAutoPatchelf = true` and call `autoPatchelf` yourself where the order matters.
- When a check covers a binary that patching or wrapping can break, run it (`--version` is enough). Checking that the file exists and is executable passes on a binary that segfaults. Mutation-test the check by re-enabling the breaking step, as described in [mutation testing for check assertions](../best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md).
- Before removing this workaround, confirm that nixpkgs' `is_static_executable` also covers `ET_DYN` files without `.interp`, or that `autoPatchelfPostFixup` skips them. Then rebuild with the automatic hook re-enabled and confirm that the `t3code` check stays green on x86_64.
- A prebuilt Go binary with an interpreter breaks the same way; see the next section. Give a runpath only to the files that `dlopen` the library, never through `appendRunpaths`, which reaches every ELF file.

## Dynamically linked Go binaries break the same way

The WiFiman Desktop 1.3.0 `.deb` (`packages/wifiman-desktop.nix`) bundles three Go binaries under `lib/wifiman-desktop`: `wg`, `wireguard-go`, and the `wifiman-desktopd` daemon. These are not static-pie. `file` reports `ELF 64-bit LSB executable ... dynamically linked`, each has an `INTERP` and one `DT_NEEDED` entry, `libc.so.6`, so autoPatchelf rightly gives them the Nix interpreter, and they run. The Tauri GUI needs `libayatana-appindicator3.so.1` on its runpath for the tray, because it `dlopen`s it by name. Once that runpath reached the Go binaries too, all three exited 139 on `--version` or `-h`. `ldd` still listed every library as resolved, so an `ldd`-only check passed.

Reproduced on copies of the built files: `patchelf --add-rpath <glibc>/lib wg`, and the same on `wireguard-go`, turns a working binary into one that exits 139. `readelf -lW` shows why patchelf had to make room. In the shipped file, `DYNAMIC` sits at `0x679540`, inside the last, writable `LOAD` segment. After the patch, a new `DYNAMIC` of `0x130` bytes sits at `0x400238`, inside the first `LOAD`, which is `R E`. The loader writes to the dynamic section at startup, so that relocation plausibly explains the crash. This session observed the move and the crash, but did not trace the write itself.

The fix uses the same structure as above: `dontAutoPatchelf = true`, then in `postFixup`, `autoPatchelf -- "$out"` with no `appendRunpaths`, so the Go binaries get only their interpreter and no `RUNPATH`, then `patchelf --add-rpath` with libayatana-appindicator on `$out/bin/.wifiman-desktop-wrapped` alone (`packages/wifiman-desktop.nix:66-77`). The `wifiman` check (`tests/wifiman.nix`) runs `wireguard-go --version`, `wg -h` (the bundled `wg` takes no `--version`; `-h` prints `Usage of ...` and exits 2), and the daemon under `timeout 5`. Status 128 or more, other than `timeout`'s 124, fails. A mutation that adds the runpath to the Go binaries turned the check red with "the bundled wireguard-go does not run".

Inside the build sandbox the daemon exits 2 by itself: it has no `/etc/machine-id` and panics after it has started. The check therefore accepts any status below 128 and also requires the daemon's `Running Go service version` line in `$BASE/wifiman-desktop.log`, so a daemon that never starts still fails.
