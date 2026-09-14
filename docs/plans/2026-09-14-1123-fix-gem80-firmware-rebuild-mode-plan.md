---
title: Fix Gem80 Firmware Rebuild Gate Reproducibility Mode - Plan
type: fix
date: "2026-09-14"
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix Gem80 Firmware Rebuild Gate Reproducibility Mode - Plan

## Goal Capsule

- **Objective:** Weekly scheduled firmware rebuild check passes cleanly when rebuilding from the pinned QMK fork commit, while still reporting any binary hash differences as an informative warning.
- **Means:** Set `firmware.gem80.rebuildMode: build-only` in `.chezmoidata/firmware.yaml` (KTD1).
- **Authority hierarchy:** Product Contract requirements govern behavior; Key Technical Decisions govern implementation mechanics within requirement boundaries.
- **Stop conditions:** If container build fails to compile `nuphy/gem80/ansi:hostrgb`, or if `.ci/test-gem80-firmware-pin-gates.sh` fails.
- **Execution profile:** Direct configuration repair and test verification.
- **Finisher:** Autonomous pipeline (`lfg`).

## Product Contract

### Summary

Revert `rebuildMode` in `.chezmoidata/firmware.yaml` from `match-sha256` back to `build-only` as originally decided in KTD3 of `docs/plans/2026-09-10-1424-feat-firmware-pin-liveness-watch-plan.md`. QMK's build system embeds the build date via `QMK_BUILDDATE` into the EEPROM magic bytes in `quantum/via.c`, making bit-reproducible rebuilds across different calendar days impossible without modifying upstream/fork build behavior.

### Problem Frame

The weekly gem80 firmware rebuild check failed in GitHub Actions run 34752604644 (the first weekly rebuild run on Sunday Sep 13) with an output mismatch: the rebuilt binary had sha256 `06a7ee...` while the committed record expected `5fa2aa...`. Inspection of the compiled binaries shows that out of 74,132 bytes, only 8 bytes differ: four bytes representing the BCD-encoded day of the month in `via_eeprom_is_valid`, `eeconfig_init_via`, and `via_init`, plus the trailing 4-byte CRC. Because `match-sha256` was enabled following same-day local verification on Sep 10, weekly builds on subsequent dates fail.

### Key Decisions

- **Accept hash difference under `build-only` mode**: Revert `firmware.gem80.rebuildMode` to `build-only`. Governs R1, R2. *(session-settled: user-directed — chosen over eliminating non-reproducible build-time timestamps from QMK: user explicitly decided in KTD3 to lower the guarantee level rather than paying the cost of securing upstream bit reproducibility).*

### Requirements

- R1. `.chezmoidata/firmware.yaml` declares `firmware.gem80.rebuildMode: build-only`.
- R2. `.ci/check-gem80-firmware-rebuild.sh` accepts binary hash differences without failing when run against the repository state.
- R3. `.ci/test-gem80-firmware-pin-gates.sh` passes all test cases.
- R4. Issue #506 is resolved by this configuration repair.

## Planning Contract

### Key Technical Decisions

- KTD1. **Revert `firmware.gem80.rebuildMode` to `build-only` in `.chezmoidata/firmware.yaml`.** Governs R1. *(session-settled: user-directed — chosen over patching QMK build system: aligns with KTD3 from `2026-09-10-1424-feat-firmware-pin-liveness-watch-plan.md`).*

### High-Level Technical Design

A single configuration value update in `.chezmoidata/firmware.yaml`. The existing `.ci/check-gem80-firmware-rebuild.sh` script already supports `build-only` mode: it warns when hashes differ but exits 0 when the container build succeeds.

### Assumptions

- A1. `.ci/check-gem80-firmware-rebuild.sh` handles `build-only` mode correctly by emitting a warning and returning exit 0 (already verified by `.ci/test-gem80-firmware-pin-gates.sh`).

### Sequencing

U1 -> Verification.

## Implementation Units

### U1. Set firmware rebuild mode to build-only

- **Goal:** Change `rebuildMode` in `.chezmoidata/firmware.yaml` from `match-sha256` to `build-only`.
- **Requirements:** R1, R2.
- **Files:** `.chezmoidata/firmware.yaml`
- **Approach:** Edit `.chezmoidata/firmware.yaml` to set `rebuildMode: build-only`.
- **Test Scenarios:**
  - Happy path: `.ci/test-gem80-firmware-pin-gates.sh` passes.
  - Evaluation gate: `.ci/check-gem80-firmware-rebuild.sh --eval 06a7ee73bae8dc23455f253dc893947175ce6e3f99e7547b9dd4b896d9f1e33f` exits 0 and logs the notice.
- **Verification:** Run `.ci/test-gem80-firmware-pin-gates.sh` and evaluate `.ci/check-gem80-firmware-rebuild.sh --eval`.

## Verification Contract

1. Run `.ci/test-gem80-firmware-pin-gates.sh` to ensure all pin gate and rebuild gate unit tests pass.
2. Run `.ci/check-gem80-firmware-rebuild.sh --eval 06a7ee73bae8dc23455f253dc893947175ce6e3f99e7547b9dd4b896d9f1e33f` to verify that the CI run 34752604644 hash is accepted under `build-only` mode with exit 0.

## Definition of Done

- `.chezmoidata/firmware.yaml` declares `firmware.gem80.rebuildMode: build-only`.
- All automated checks in `.ci/test-gem80-firmware-pin-gates.sh` pass.
- Scratch directories under `/tmp` created during debugging are removed.
