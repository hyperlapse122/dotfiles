---
title: Install AdGuard for Mac - Plan
type: feat
date: 2026-11-24
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Install AdGuard for Mac

## Goal Capsule

A newly configured Mac has AdGuard available to open. The owner registers the license and chooses filters in the app. Deliver this in one change using the existing Homebrew cask list (KTD1).

## Product Contract

### Summary

Install the stable AdGuard for Mac desktop app as part of the normal macOS configuration.

### Problem Frame

The Mac setup already installs desktop apps, but the owner still has to obtain AdGuard separately.

### Requirements

- R1. Both bootstrap and production macOS configurations install AdGuard when it is missing.
- R2. The owner controls license registration and filter selection in AdGuard.

## Planning Contract

### Key Technical Decisions

- KTD1. Add the official `adguard` cask to `darwinOnly` in `modules/shared/darwin-apps.nix`. The existing `modules/darwin/homebrew.nix` consumes that list for both configurations. [Homebrew cask](https://formulae.brew.sh/cask/adguard)
- KTD2. Limit provisioning to app installation (session-settled: user-directed — chosen over managing filter lists in dotfiles: the owner wants to configure AdGuard in the app).

## Implementation Units

### U1. Declare and verify the macOS cask

Add `adguard` alongside the other Mac-only casks (R1). In the Homebrew paragraph of `docs/macos.md`, identify AdGuard as an installed app and explain where to register the license and choose filters (R2).

Extend the existing named-cask assertion in `tests/darwin-config.nix` with `adguard`. Its separate fixture assertion already compares each profile’s evaluated casks with the shared list. Together these cover two regressions: removing AdGuard from the list and dropping it from either profile.

## Verification Contract

- Run `agent-check` on the changed Nix and Markdown files.
- On Apple silicon, run `nix build --no-link .#checks.aarch64-darwin.darwin-config`. This checks the declared installation in both profiles without activating the host.
- Review the implementation diff for R2. License registration and filter selection belong to the app’s initial setup.

## Definition of Done

U1 is complete when both configurations declare the stable cask, the named-cask assertion passes, and the macOS guide explains the owner’s setup steps. Remove any temporary verification edits before handoff.
