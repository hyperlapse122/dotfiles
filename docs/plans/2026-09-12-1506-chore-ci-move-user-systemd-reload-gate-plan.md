---
title: "chore(ci): move the user-systemd reload gate to fatal-boundary-gates"
date: "2026-09-12"
type: implementation-plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/488
---

## Goal Capsule

Move `.ci/test-user-systemd-reload.sh` and its render item from the `agent-reconciliation` job to `fatal-boundary-gates` in `.github/workflows/ci.yml`. This aligns CI failure reporting with the concern under test (systemd user manager rather than agent harness reconciliation) and places it beside its sibling `.chezmoiscripts/30-linux/run_after_*` gate (`test-podman-cluster-convergence.sh`).

## Product Contract

### Requirements

- R1. Move the template render entry for `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl:user-systemd-reload.sh` out of `agent-reconciliation` and into `fatal-boundary-gates` in `.github/workflows/ci.yml`.
- R2. Move the gate invocation `.ci/test-user-systemd-reload.sh "$RUNNER_TEMP/user-systemd-reload.sh"` out of `agent-reconciliation` and into `fatal-boundary-gates` in `.github/workflows/ci.yml`.
- R3. Preserve CI gate wiring integrity: verify that `.ci/test-ci-wiring.sh` continues to pass and all tests in `.ci/test-user-systemd-reload.sh` pass.

### Scope Boundaries

- In scope: `.github/workflows/ci.yml` relocation of the render entry, file permissions, and test step.
- Out of scope: Modifying `.ci/test-user-systemd-reload.sh` internal test assertions or touching unrelated CI jobs.

## Planning Contract

### Key Technical Decisions

- KTD1. In `agent-reconciliation`: remove `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl:user-systemd-reload.sh` from the render `for` loop and the trailing `chmod 700` list, and remove `.ci/test-user-systemd-reload.sh "$RUNNER_TEMP/user-systemd-reload.sh"` from the `Test agent reconciliation` step.
- KTD2. In `fatal-boundary-gates`: add `".chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl:user-systemd-reload.sh"` to the `Render the fatal-boundary scripts under test` loop (which already runs `chmod 700 "$RUNNER_TEMP/$output_name"` for every item), and add `.ci/test-user-systemd-reload.sh "$RUNNER_TEMP/user-systemd-reload.sh"` to the `Run fatal-boundary gates` step immediately after `.ci/test-podman-cluster-convergence.sh`.

## Implementation Units

### U1. Relocate user-systemd reload gate in CI workflow

- Files: `.github/workflows/ci.yml`
- Tasks:
  1. Remove user-systemd reload script from `agent-reconciliation` render loop and chmod step.
  2. Remove `.ci/test-user-systemd-reload.sh` invocation from `Test agent reconciliation`.
  3. Add user-systemd reload script to `fatal-boundary-gates` render loop.
  4. Add `.ci/test-user-systemd-reload.sh "$RUNNER_TEMP/user-systemd-reload.sh"` to `Run fatal-boundary gates`.
- Test scenarios:
  - Verify `.ci/test-ci-wiring.sh` passes without errors.
  - Verify `.ci/test-user-systemd-reload.sh` passes locally.

## Verification Contract

- Run `.ci/test-ci-wiring.sh` to confirm wiring coverage and job aggregation.
- Run `.ci/test-user-systemd-reload.sh` to verify script execution.
- Validate `.github/workflows/ci.yml` YAML syntax and structure.

## Definition of Done

- `.github/workflows/ci.yml` has `.ci/test-user-systemd-reload.sh` wired into `fatal-boundary-gates`.
- `agent-reconciliation` contains only agent harness reconciler gates.
- `.ci/test-ci-wiring.sh` passes completely.
