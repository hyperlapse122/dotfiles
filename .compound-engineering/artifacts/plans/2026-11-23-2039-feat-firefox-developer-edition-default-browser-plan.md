---
title: Firefox Developer Edition as the default browser
type: feat
date: 2026-11-23
topic: firefox-developer-edition-default-browser
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Firefox Developer Edition as the default browser

## Goal Capsule

- **Objective.** Open everyday web links in Firefox Developer Edition on the NixOS desktop and Mac, and receive new Developer Edition releases directly from Mozilla.
- **Product authority.** The owner's choices about browser defaults, updates and existing workflows are recorded below.
- **Open blockers.** None.

## Product Contract

### Summary

Make Firefox Developer Edition the everyday browser on both machines. Its built-in updater follows Mozilla's Developer Edition channel independently of dotfiles releases.

### Key Decisions

- **Both desktops.** Governs R1, R3. (session-settled: user-directed — chosen over switching a single device: the owner wants the same browser on both.)
- **Firefox owns updates.** Governs R2. (session-settled: user-approved — chosen over advancing a version in dotfiles: the browser can pick up a release without a configuration change.)
- **Leave existing browser data in place.** The owner excluded profile migration from the switch.

### Requirements

**Installation and updates**

- R1. A fresh installation on either machine obtains the latest Firefox Developer Edition build for its platform directly from Mozilla. [Official downloads](https://www.firefox.com/en-US/channel/desktop/developer/)
- R2. On both machines, Firefox automatically downloads its own updates from Mozilla and can apply them on restart independently of a dotfiles update. [Mozilla update guide](https://support.mozilla.org/en-US/kb/update-firefox-latest-release)

**Opening links and keeping Chrome available for Flutter**

- R3. HTTP and HTTPS links opened from another application launch Firefox Developer Edition on both systems.
- R4. The existing browser icon in the KDE taskbar opens Firefox Developer Edition.
- R5. Flutter's Chrome target continues to launch Google Chrome on both platforms.

### Key Flows and Acceptance Examples

- F1. The user installs the browser, accepts the default-browser change if macOS requests confirmation, and opens a web link from a mail or chat app. Firefox Developer Edition displays the page. Covers R1, R3.
- AE1. On NixOS, clicking the pinned browser icon opens the same edition as clicking a link in chat. Covers R3, R4.
- AE2. With a newer Developer Edition update available, Firefox downloads it and reports the newer version after restart on each machine. Reapplying the same dotfiles revision preserves that version. Covers R2.
- AE3. After the switch, starting a Flutter web session with the Chrome target opens Chrome. Covers R5.

### Scope Boundaries

The switch covers browser installation, updates and default link handling. Importing bookmarks, passwords, history or other profile data is outside the browser switch.

## Planning Contract

- KTD1. **Install the upstream Korean build in a writable directory.** Fetch from Mozilla's latest Developer Edition endpoint on first install. Keep the extracted application outside the Nix store. Publish completed downloads atomically, preserve existing installations and let Firefox replace its own files. A failed first download must be retryable. Covers R1, R2.
- KTD2. **Use desktop-native handlers.** On NixOS use a stable desktop entry with a launcher that supplies the runtime libraries to Mozilla's unmodified binaries. Set KDE's preferred browser and both web schemes while preserving unrelated preferences. On macOS use the signed application bundle and Launch Services in the user session, including its consent prompt. Covers R3, R4.

## Implementation Units

### U1. Install and launch the Linux build

Add the installer and launcher under `home/h82/desktop/` and wire them into the Linux desktop imports. Use the existing NixOS ELF loader with a browser-specific library path. Exercise the upstream executable in an isolated home, including a headless page render, and check repeat installation and URL forwarding. Covers R1–R4.

### U2. Install and select the macOS build

Install Mozilla's latest DMG as the primary user. Reuse an existing official Developer Edition bundle, and keep subsequent applies from replacing a self-updated app. Configure default selection using macOS's user-session facilities. Check the generated Darwin configuration and document the native confirmation and update checks. Covers R1–R3.

### U3. Verify the Flutter browser target

Verify that Flutter discovers Google Chrome as its web target on both platforms. Covers R5.

## Verification Contract

Run `agent-check` and focused Nix checks with repository fixtures. Exercise initial provision and a second invocation against the same user-owned installation. Check desktop resolution and run Firefox against an isolated profile on Linux. Separate local fixture evidence from the remaining live checks on each desktop.

## Definition of Done

Both platforms obtain Developer Edition from Mozilla and preserve Firefox-managed upgrades. Desktop links and KDE's pinned browser resolve to it. The PR reports verification for each platform.
