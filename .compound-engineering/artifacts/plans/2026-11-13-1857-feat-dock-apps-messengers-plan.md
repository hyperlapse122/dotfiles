---
title: "feat: Pin Apps and messengers to the macOS Dock"
type: feat
date: 2026-11-13
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Pin Apps and Messengers to the macOS Dock

## Goal Capsule

- **Objective:** Open the macOS app list, KakaoTalk, and Telegram Desktop directly from the declared Dock.
- **Means:** Extend the existing nix-darwin Dock list and its materialized-output check.
- **Authority:** The layout approved in this conversation and repository safeguards govern the change.
- **Execution profile:** One implementation unit and one PR; LFG implements, verifies, reviews, and publishes it. The owner controls merging and system activation.
- **Stop condition:** Stop if the approved Apps launcher cannot be pinned through the existing configuration.

## Product Contract

### Summary

Pin Apps immediately after Finder and place KakaoTalk and Telegram Desktop immediately after Messages.

### Problem Frame

The declared Dock omits the app browser and the owner's two messengers, requiring other ways to open them.

### Requirements

- R1. The Dock starts Finder, Apps, Google Chrome, and App Store, in that order.
- R2. The messenger sequence is Messages, KakaoTalk, Telegram Desktop, FaceTime, and Phone.
- R3. Configuration application restores these pins through the existing Dock management without changing other app ordering or Dock preferences.

### Key Decisions

- KD1. Use the current built-in Apps launcher; governs R1 (session-settled: user-directed — chosen over restoring the old full-screen Launchpad: the owner selected the current default Apps app).
- KD2. Group KakaoTalk and Telegram Desktop directly after Messages; governs R2 (session-settled: user-approved — chosen over leaving their placement unspecified: the owner confirmed the proposed messenger sequence).

### Scope Boundaries

- No replacement launcher, app installation changes, or live system activation is part of this change.

## Planning Contract

### Key Technical Decisions

- KTD1. Add `/System/Applications/Apps.app` first in `modules/darwin/dock.nix`; Finder is a system-owned anchor and must not be duplicated in persistent apps. Implements R1.
- KTD2. Use the installed bundles `/Applications/KakaoTalk.app` and `/Applications/Telegram Desktop.app`, following the existing App Store and Homebrew installation choices. Implements R2.
- KTD3. Update the existing expected Dock order in `tests/darwin-config.nix`, which reads normalized Dock tiles for fixtures with and without the T3 desktop trait. Do not add a separate check. Implements R1–R3.

## Implementation Units

### U1. Extend the declared Dock order

- **Goal:** Deliver R1–R3 together.
- **Files:** `modules/darwin/dock.nix`, `tests/darwin-config.nix`.
- **Dependencies:** None.
- **Approach:** Insert the three bundle paths and update the existing expected list; correct the adjacent stale Dock comment while editing that test section.
- **Test scenarios:** Check the complete normalized pinned order for T3-enabled and T3-disabled fixtures; retain Downloads, host apps, icon-size, recent-app, and unmanaged-preference assertions.
- **Verification:** The existing Darwin configuration check passes; removing a requested pin must make it fail. The configuration check proves the normalized tiles; the existing `tests/darwin-outputs.nix` check exercises activation writes. Neither proves a click in the owner's live Dock.
- **Execution note:** Prefer the existing configuration and activation checks over a new test harness.

## Verification Contract

- Run `git diff --check` and lint the changed Markdown with `markdownlint-cli2`.
- Run `nix build --no-link .#checks.aarch64-darwin.darwin-config .#checks.aarch64-darwin.darwin-outputs` and `nix flake check --no-build` on this Mac.
- Check formatting on a supported builder or defer it to CI; the flake has no Darwin formatter.
- Require successful current-head CI, including `host-checks`, `vm-checks`, `build`, and `build-darwin` via `full-ci`, before reporting merge readiness.
- Report live Dock verification separately; do not activate the host configuration without an explicit owner instruction naming that step.

## Definition of Done

U1 is implemented and committed, the relevant local check passes, independent code-review findings are assessed, and the PR records validation and any pending evidence.
Remove any experimental changes or task-owned temporary resources before completion.
