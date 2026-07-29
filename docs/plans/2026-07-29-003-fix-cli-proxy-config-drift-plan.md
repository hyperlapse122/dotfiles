---
title: "fix: prevent false CLIProxyAPI config drift"
date: 2026-07-29
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# fix: prevent false CLIProxyAPI config drift

## Goal Capsule

- Make the CLIProxyAPI provisioner idempotent after the service rewrites its seeded management secret.
- Preserve one-shot ownership of the runtime configuration and credentials.
- Verify the behavior without a live `chezmoi apply`, Podman operation, or user-service restart.

---

## Product Contract

### Summary

The second `chezmoi apply` must not report non-secret drift when CLIProxyAPI has changed only runtime-owned representation, such as the hashed management secret or non-semantic YAML formatting.

### Problem Frame

The provisioner compares the runtime file and the seeded template as text after it removes `secret-key:` lines.
CLIProxyAPI owns the runtime file after seeding and can rewrite YAML representation on first start.
Textual representation changes can therefore produce a false non-secret drift warning even when every managed non-secret value is unchanged.

### Requirements

- R1. A second provisioner run must accept a runtime config whose managed non-secret values equal the desired config.
- R2. A changed managed non-secret value must still emit the existing re-seed warning.
- R3. Secret values and runtime-only representation changes must not affect the drift result.
- R4. The runtime config and credential files must remain one-shot seeds.
- R5. Verification must use isolated rendered scripts and stubbed runtime commands.

### Scope Boundaries

- Keep the current runtime paths, credential contract, rollout behavior, and manual re-seed instruction.
- Do not adopt runtime changes into chezmoi source state.
- Do not run a live apply or a real container build during verification.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Compare a canonical projection of the complete managed non-secret field allowlist instead of comparing full file text. The allowlist is `port`, `remote-management.allow-remote`, `remote-management.disable-control-panel`, `auth-dir`, `api-keys`, `debug`, `logging-to-file`, and `usage-statistics-enabled`. This ignores comments, key order, scalar quoting, the runtime-owned secret, and unrelated runtime additions while retaining value-level drift detection.
- KTD2. Parse the generated YAML subset inside the rendered shell provisioner. Accept plain or quoted scalar values and the empty inline list used by the template. Reject missing, duplicate, malformed, nested, aliased, tagged, or multiline managed values. This avoids a new runtime package dependency and defines a bounded portability contract for Linux and macOS.
- KTD3. Exercise the rendered Linux provisioner across seed, equivalent-rewrite reconciliation, and managed-drift runs in the isolated integration test. Stub Podman and the user service manager so the test covers the full lifecycle without deployment.

### Assumptions

- CLIProxyAPI preserves the YAML mapping structure and managed keys when it rewrites the runtime file.
- Runtime-added keys are not managed drift unless the source template explicitly owns them.

---

## Implementation Units

### U1. Canonical managed-field drift comparison

- **Goal:** Replace representation-sensitive comparison with managed value comparison.
- **Requirements:** R1, R2, R3, R4; KTD1, KTD2.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/90-services/run_onchange_after_provision-cli-proxy-api.sh.tmpl`
- **Approach:** Add a shell helper that emits the KTD1 allowlist as stable path-and-value records. Normalize whitespace and equivalent scalar quoting only. Generate desired and runtime projections separately. Require every allowlisted path exactly once with its expected scalar or empty-list type. Treat any projection failure, missing path, duplicate path, malformed nesting, unsupported YAML form, or value mismatch as drift. Continue to seed only when the runtime file is absent.
- **Patterns to follow:** Existing `seed_config`, `warn`, and dependency-free shell helpers in the provisioner.
- **Test scenarios:** An unchanged seed produces no warning. A runtime file with a rewritten secret, comments removed, keys reordered, and equivalent scalar quotes produces no warning. Each security-sensitive managed path is included in the projection. A changed managed value produces the current re-seed warning. Missing, duplicate, malformed, wrong-type, aliased, tagged, and multiline managed values fail closed with the warning.
- **Verification:** The rendered script is valid Bash and preserves the existing seed, warning, credential, and rollout messages.

### U2. Isolated second-run regression coverage

- **Goal:** Reproduce the apply-twice lifecycle without changing the live home directory.
- **Requirements:** R1, R2, R3, R5; KTD3.
- **Dependencies:** U1.
- **Files:** `.ci/test-cli-proxy-api-integration.sh`
- **Approach:** Run the rendered provisioner against the test fake home with stubbed Podman and systemd commands. Mutate only runtime-owned YAML representation before the second run, then assert no drift warning. Change one managed value and assert the warning remains.
- **Execution note:** Establish the false-warning regression case before finalizing the comparison helper.
- **Patterns to follow:** The existing per-user scratch directory, stub command directory, rendered provisioner, and fail helper.
- **Test scenarios:** First run seeds the file. Second run after secret hashing and supported formatting changes is clean. Subsequent runs cover a managed-value change and the fail-closed projection cases from U1. No command touches the real service or data root.
- **Verification:** `.ci/test-cli-proxy-api-integration.sh` passes in the isolated environment.

---

## Verification Contract

- Run `.ci/test-cli-proxy-api-integration.sh`.
- Render the changed provisioner with the repository `op` stub and validate it with `bash -n`.
- Run `git diff --check`.
- Confirm `CLAUDE.md` contains only `@AGENTS.md`.
- Inspect `git status` and the diff limited to the requested files and this plan.

---

## Definition of Done

- Repeated isolated provisioning does not report drift for equivalent managed non-secret configuration.
- A real managed non-secret change still reports the re-seed warning.
- One-shot secret and config ownership remains unchanged.
- No live apply, container rollout, or user-service restart occurs during verification.
- All repository checks pass and the change is delivered through a reviewed, green pull request.
