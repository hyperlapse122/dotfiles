---
title: "refactor(scripts): share the user-manager deadline guard between 30-linux scripts"
date: "2026-09-12"
type: implementation-plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/487
---

## Goal Capsule

Extract the duplicate user-manager deadline assignment and validation logic from `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl` and `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl` into a parameterized partial template `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl`. Include the partial from both scripts to ensure both renders remain functionally identical while eliminating duplicated validation logic.

## Product Contract

### Requirements

- R1. Create `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl` taking `(dict "ctx" . "name" "<script>" [ "includeReload" true ])`.
- R2. If the template argument is not a map or `name` is missing, fail at render time with a clear descriptive message following repository conventions (`shared-host-guard.sh.tmpl`, `sudo-elevation-guard.sh.tmpl`).
- R3. Emitted bash code assigns `user_manager_deadline_secs=${CAPABILITY_PROBE_DEADLINE_SECS:-5}` and `user_manager_term_grace_secs=${CAPABILITY_PROBE_TERM_GRACE_SECS:-2}`. If `includeReload` is true, also emit `user_manager_reload_deadline_secs=${USER_MANAGER_RELOAD_DEADLINE_SECS:-30}` with its explanatory comment.
- R4. Emitted bash code validates that all defined deadline variables match `^[1-9][0-9]*$` or prints `"<name>: user-manager deadlines must be positive integer seconds"` to stderr and exits 1.
- R5. Refactor `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl` to include the partial with `name: "reload-user-systemd"` and `includeReload: true`.
- R6. Refactor `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl` to include the partial with `name: "setup-podman-cluster"`.
- R7. Ensure that the rendered output of both scripts preserves all runtime behavior, error messages, and exit codes.
- R8. Ensure all CI gates, including `.ci/test-user-systemd-reload.sh`, `.ci/test-podman-cluster-convergence.sh`, and `.ci/test-ci-wiring.sh`, pass.

### Scope Boundaries

- In scope:
  - Creating `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl`.
  - Updating `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl`.
  - Updating `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl`.
  - Verifying render parity and running all relevant test suites.
- Out of scope:
  - Changing deadline default values (5s probe, 2s grace, 30s reload).
  - Touching other scripts outside 30-linux.

## Planning Contract

### Key Technical Decisions

- KTD1. Partial Parameterization: The partial accepts a dict with required `name` and optional `includeReload` (default false). When `includeReload` is true, it includes the reload deadline variable and its check in the compound condition.
- KTD2. Map and Argument Guard: Follow the pattern in `shared-host-guard.sh.tmpl`:
  ```gotemplate
  {{- if not (kindIs "map" .) -}}
  {{-   fail (printf "user-manager-deadline-guard.sh.tmpl: expected a dict, got a %s (%v)" (kindOf .) . .) -}}
  {{- end -}}
  {{- if not (hasKey . "name") -}}
  {{-   fail "user-manager-deadline-guard.sh.tmpl: missing required parameter 'name'" -}}
  {{- end -}}
  ```
- KTD3. Preserving Exact Bash Behavior: Both caller scripts validate deadlines before running any `systemctl --user` commands. The regex validation and error exit must match character-for-character with the caller's script name in the error message.

## Implementation Units

### U1. Create `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl`

- Files: `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl`
- Tasks:
  1. Author template with parameter validation and comments.
  2. Implement deadline assignments and compound regex validation.
  3. Support `includeReload` toggle for `USER_MANAGER_RELOAD_DEADLINE_SECS`.
- Test scenarios:
  - Render with `includeReload: false` produces probe and term grace assignments and two-clause validation.
  - Render with `includeReload: true` produces probe, grace, reload assignments and three-clause validation.

### U2. Refactor `run_after_reload-user-systemd.sh.tmpl` and `run_after_setup-podman-cluster.sh.tmpl`

- Files:
  - `.chezmoiscripts/30-linux/run_after_reload-user-systemd.sh.tmpl`
  - `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl`
- Tasks:
  1. Replace deadline block in `run_after_reload-user-systemd.sh.tmpl` with `{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" (dict "ctx" . "name" "reload-user-systemd" "includeReload" true) }}`.
  2. Replace deadline block in `run_after_setup-podman-cluster.sh.tmpl` with `{{ includeTemplate "user-manager-deadline-guard.sh.tmpl" (dict "ctx" . "name" "setup-podman-cluster") }}`.
- Test scenarios:
  - Compare rendered shell output before and after refactoring to confirm exact behavioral parity.

### U3. Verification and CI Testing

- Files:
  - `.ci/test-user-systemd-reload.sh`
- Tasks:
  1. Run `.ci/test-user-systemd-reload.sh` to test responsive manager, timeouts, invalid deadlines (0, x), empty strings.
  2. Run `.ci/test-podman-cluster-convergence.sh` against rendered `setup-podman-cluster.sh`.
  3. Run `.ci/test-ci-wiring.sh`.
  4. Run `git diff` on rendered scripts to verify byte parity.

## Verification Contract

- Run `.ci/test-user-systemd-reload.sh` -> must exit 0 with "user-systemd-reload: PASS".
- Run `.ci/test-ci-wiring.sh` -> must exit 0 with "all tests passed".
- Render `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl` with chezmoi and verify shellcheck and execution.

## Definition of Done

- `.chezmoitemplates/user-manager-deadline-guard.sh.tmpl` exists and is used by both `run_after_reload-user-systemd.sh.tmpl` and `run_after_setup-podman-cluster.sh.tmpl`.
- No duplicated deadline validation logic remains in those two scripts.
- All tests and CI checks pass cleanly.
