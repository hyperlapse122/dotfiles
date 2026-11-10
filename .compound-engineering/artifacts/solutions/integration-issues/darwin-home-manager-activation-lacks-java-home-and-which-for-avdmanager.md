---
title: "avdmanager fails in nix-darwin Home Manager activation because activation has no JAVA_HOME and no which"
date: 2026-10-09
category: integration-issues
module: "mobile-devices helper (Home Manager activation on macOS)"
problem_type: integration_issue
component: activation
severity: medium
symptoms:
  - "nr switch on a Mac prints \"mobile-devices: avdmanager could not list AVDs, so the Android Virtual Devices were skipped\" and creates no AVD"
  - "The iOS Simulators from the same activation step are created normally"
  - "avdmanager list avd -c succeeds when run by hand in a terminal"
root_cause: incomplete_setup
resolution_type: code_fix
related_components:
  - tooling
tags: ["nix-darwin", "home-manager", "activation", "avdmanager", "java-home", "android-sdk", "path"]
---

# avdmanager fails in nix-darwin Home Manager activation because activation has no JAVA_HOME and no which

## Problem

The `mobileDevices` activation step skipped every Android Virtual Device on macOS. The avdmanager start script could not find Java, because Home Manager activation runs without the session variables and with a PATH that has no `which`.

## Symptoms

- An apply prints `mobile-devices: avdmanager could not list AVDs, so the Android Virtual Devices were skipped`, and no AVD exists afterwards.
- The iOS half of the same step works.
- `avdmanager list avd -c` in an ordinary terminal exits 0, so the tool looks healthy.

## What Didn't Work

- **Reproducing the failure in a terminal.** A login shell has `JAVA_HOME` from `programs.java` (`home/h82/dev/android.nix:60`), and `/usr/bin/which` and `/usr/bin/awk` on PATH, so avdmanager works there. The failure appears only in activation's environment.
- **Adding `which` to the helper's PATH alone.** With `which` present, avdmanager finds the JDK that its Nix wrapper puts first on PATH and lists AVDs. But the start script's JDK version check then prints `awk: command not found` and `test: : integer expected`, because activation's PATH has no awk either. It passes only because a failed `test` counts as "version is not too old". Setting `JAVA_HOME` avoids the `which` lookup completely, and adding gawk makes the version check real.

## Solution

Reproduce with activation's own PATH. Line 7 of a Home Manager generation's `activate` script is its `export PATH=...`. On nix-darwin, the system `activate` script names the generation: `launchctl asuser ... sudo -u <user> --set-home .../activation-<user>`, and that script points at `...-home-manager-generation`.

```sh
P=$(sed -n 7p "$gen/activate" | sed 's/^export PATH="//;s/"$//')
S=$HOME/Library/Android/sdk
env -i HOME=$HOME PATH="$P" ANDROID_HOME=$S ANDROID_SDK_ROOT=$S \
  $S/cmdline-tools/latest/bin/avdmanager list avd -c
# ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH.
```

The fix, as it stands in the tree:

- The helper takes a required `--java-home` and exports it with the SDK variables before it runs avdmanager (`scripts/mobile-devices:188`).
- Activation passes the JDK `programs.java` installs: `--java-home ${lib.escapeShellArg config.programs.java.package.home}` (`home/h82/dev/mobile-devices.nix:80`).
- `pkgs.gawk` is in the helper's `runtimeInputs` for the version check (`packages/mobile-devices.nix:6`).
- The listing failure message now ends with avdmanager's stdout, because its start script writes `die` messages to stdout and the helper captures stdout (`scripts/mobile-devices:191`).

## Why This Works

nix-darwin runs Home Manager activation through `sudo -u <user> --set-home`. Home Manager's activate script then sets its own PATH: bash, coreutils, diffutils, findutils, gettext, gnugrep, gnused, jq, ncurses, and nix. Nothing reads `home.sessionVariables`, and `/usr/bin` is not on PATH. The androidenv wrapper for avdmanager prepends its JDK's `bin` to PATH and sets `ANDROID_HOME` and `ANDROID_SDK_ROOT`, but not `JAVA_HOME`. The upstream start script uses `$JAVA_HOME/bin/java` when `JAVA_HOME` is set. Otherwise it runs `which java || die`, so it dies when `which` is missing, even though `java` is on PATH. With `JAVA_HOME` set, the `which` branch never runs. With gawk present, the `java -version | awk` check gets a real version number.

The helper used `avds=$("$avdmanager" list avd -c)`. That substitution took the `die` text in with the stdout, so the only visible line was the helper's own one-sentence message. That is why the cause could not be seen from the apply log.

## Prevention

- Treat Home Manager activation as a non-login environment. A tool called from `home.activation` gets every variable and every PATH entry it needs from the call itself or from the helper's `runtimeInputs`. Never rely on `home.sessionVariables` or on `/usr/bin`.
- Before calling a vendor CLI from activation, run it under `env -i` with the generation's PATH, as shown above. A vendor start script often depends on `which`, `awk`, `uname`, or similar tools.
- When a helper captures a tool's stdout, put the captured text into the failure message. Vendor start scripts often print fatal errors on stdout.
- `tests/mobile-devices.sh` models this: its stub avdmanager fails as the real one does unless `$JAVA_HOME/bin/java` is executable, and the helper is run with `JAVA_HOME` unset. The `darwin-outputs` check confirms that the built activation passes a `--java-home` whose `bin/java` runs.

## Related Issues

- [Home Manager activation does not re-run when the generation is unchanged](../best-practices/home-manager-activation-does-not-run-on-every-rebuild.md): same activation layer, different failure.
- [system-manager activate exits 0 after a partial activation](../best-practices/system-manager-activate-exits-zero-on-partial-failure.md): another activation path that hides the real error.
- [T3 Code's Antigravity ACP server finds no CA bundle on NixOS](t3code-antigravity-acp-openssl-missing-ca-bundle-hangs-sessions.md): a tool started from a reduced environment that lacks a variable it expects.
