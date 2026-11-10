---
title: "The first simctl call after an Xcode upgrade fails while it replaces the stale CoreSimulatorService"
date: 2026-10-16
category: integration-issues
module: "mobile-devices helper (Home Manager activation on macOS)"
problem_type: integration_issue
component: activation
severity: medium
symptoms:
  - "nr switch on a Mac prints \"CoreSimulator detected version change. Framework version (1174.9.2) does not match existing job version (1171.7)\" from simctl during Activating mobileDevices"
  - "simctl then reports \"Connection refused\" with \"versionOfLoadedJob: 1171.7, our version: 1174.9.2\""
  - "mobile-devices: simctl could not list device types, so the iOS Simulators were skipped, glued onto the end of simctl's last error line"
  - "xcrun simctl list devicetypes run by hand right afterwards succeeds"
root_cause: async_timing
resolution_type: code_fix
related_components:
  - tooling
tags: ["nix-darwin", "home-manager", "activation", "xcode", "simctl", "coresimulator", "ios-simulator"]
---

# The first simctl call after an Xcode upgrade fails while it replaces the stale CoreSimulatorService

## Problem

The apply that upgrades Xcode skipped every iOS Simulator. `modules/darwin/xcode.nix` upgrades Xcode from the App Store in the root phase of the apply. The user's `com.apple.CoreSimulator.CoreSimulatorService` launchd job was still the one the old Xcode had started. The first `simctl` call from the new Xcode found the version mismatch, removed the old job, and failed instead of waiting for the new one.

## Symptoms

On 2026-10-16 the apply upgraded Xcode to 27.1, which moved CoreSimulator from 1171.7 to 1174.9.2. `Activating mobileDevices` then printed:

```text
simctl[72382:5033801] CoreSimulator detected version change.  Framework version (1174.9.2) does not match existing job version (1171.7).  Attempting to remove the stale service in order to add the expected version.
simctl[72382:5033801] Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" UserInfo={NSLocalizedDescription=The loaded com.apple.CoreSimulator.CoreSimulatorService job does not match our expectations: versionOfLoadedJob: 1171.7, our version: 1174.9.2, SimServiceContextConnectFailure=3}
Error getting a serviceContext: Error Domain=NSPOSIXErrorDomain Code=61 "Connection refused" ...mobile-devices: simctl could not list device types, so the iOS Simulators were skipped
```

- The helper's skip message is glued to simctl's last line, because simctl ends its last error line without a newline.
- A few minutes later, `xcrun simctl list devicetypes -j` exited 0, and `launchctl list` showed a new `com.apple.CoreSimulator.CoreSimulatorService` process.

## What Didn't Work

- Reading the error as a broken Xcode install, or as a reason to reboot. Nothing was broken: the failing call had already removed the stale job, so the next `simctl` call launched the 1174.9.2 service and worked.
- Catching only the `devicetypes` listing. Before this fix, the runtime listing in `ios_runtime` had its own `|| runtimes=`, and the follow-up `jq` ran under `|| true`. A failed or non-JSON runtime listing therefore looked like "no runtime installed", and the helper went on to `xcodebuild -downloadPlatform iOS`, a download of about 8 GB. A cross-model review (Antigravity) found this during the fix.
- Keeping both attempts' stderr in one file, as the fix's first version did. When both attempts fail, the second attempt's error is appended right after the first one's newline-less last line, which puts the two on one line.

## Solution

`scripts/mobile-devices` lists through `simctl_list`. It tries a failed listing once more, discards the first attempt's stderr, and ends the second attempt's error with a newline:

```bash
simctl_list() {
  local out err status=0
  err=$(mktemp)
  if out=$("$xcrun" simctl list "$1" -j 2>/dev/null) || out=$("$xcrun" simctl list "$1" -j 2>"$err"); then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$(<"$err")" >&2
    status=1
  fi
  rm -f "$err"
  return "$status"
}
```

`ios_devices` lists device types and simulators through it, and `ios_runtime` lists runtimes through it with no `|| …` fallback. The helper runs `ios_devices` in a `set -e` subshell, so a runtime listing that fails, or one `jq` cannot parse, stops the iOS step with `the iOS step stopped early` and never reaches the download.

`tests/mobile-devices.sh` covers three scenarios with a stub `xcrun`:

- `a stale CoreSimulatorService after an Xcode upgrade`: the first listing fails and the second succeeds. The devices are created, and no simctl error is shown.
- `a CoreSimulatorService that never answers`: the device type listing is tried twice, simctl's error appears on its own line, and the skip message is on its own line.
- `a runtime listing that fails`: no download is attempted, and the iOS step reports that it stopped early.

## Why This Works

CoreSimulatorService is a per-user launchd job started by whichever `simctl` (or Xcode) first needed it. Upgrading Xcode replaces `/Library/Developer/PrivateFrameworks/CoreSimulator.framework` but leaves that job running. The first client of the new framework detects the mismatch, removes the job, and fails its own request. The next client starts the job from the new framework. Activation runs right after the Xcode upgrade in the same apply, so the helper is that first client. A single retry is enough, because the failed call already removed the stale job.

Stopping the iOS step on a failed runtime listing matters because "runtime missing" is the one state that starts a multi-gigabyte download. A transient listing failure must not reach that branch.

## Prevention

- Any activation step or script that calls `simctl` after `xcode.nix` may have upgraded Xcode must tolerate one failed call. Route every `simctl list` through `simctl_list`, not a direct `"$xcrun" simctl list` call.
- Never let a failed listing fall through to a branch that downloads or creates something. Let it stop the step under `set -e`, or report and return.
- When printing a tool's stderr in front of your own message, end that stderr with a newline, as `printf '%s\n' "$(<"$err")"` does. Assert whole lines with `grep -qx` in the test, because a substring check passes on the glued line.

## Related

- [avdmanager fails in nix-darwin Home Manager activation because activation has no JAVA_HOME and no which](darwin-home-manager-activation-lacks-java-home-and-which-for-avdmanager.md): the Android half of the same activation step.
