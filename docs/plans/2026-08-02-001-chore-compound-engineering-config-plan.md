---
title: Compound Engineering Project Configuration - Plan
type: chore
date: 2026-08-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Compound Engineering Project Configuration - Plan

## Goal Capsule

- **Objective:** Add tracked shared Compound Engineering configuration, a current example, and an ignored machine-local configuration without changing active CE defaults.
- **Authority:** The user-approved local-config and ignore choices, the user-directed shared-config request, repository instructions, then this plan.
- **Execution profile:** One bounded configuration unit followed by repository and CE health checks.
- **Stop conditions:** Stop if the local file is tracked, the example differs from the bundled CE template, the shared file activates an unrequested setting, or the CE health check reports a project issue.
- **Tail ownership:** Commit the plan and configuration changes, open a mergeable pull request, watch CI, and merge after required checks and review complete.

---

## Product Contract

### Summary

The repository will carry a shared `docs_root` configuration surface and a current full example configuration. Each checkout can also carry an ignored local configuration. All settings remain commented so the project keeps native defaults until maintainers opt in.

### Problem Frame

The repository had no durable CE configuration surface. Machine-local preferences also needed a safe file that Git would not track. A shared file must be distinguishable from the local file so maintainers know which layer applies across clones.

### Requirements

- R1. Track `.compound-engineering/config.yaml` as the shared project configuration.
- R2. Track `.compound-engineering/config.local.example.yaml` as the current full settings example from Compound Engineering 3.21.0.
- R3. Create `.compound-engineering/config.local.yaml` for this checkout with the same optional settings and keep it ignored by Git.
- R4. Add `.compound-engineering/*.local.yaml` to the repository root `.gitignore` without changing unrelated rules.
- R5. Keep every CE preference commented so the artifact root remains `docs/` and the CE Work implementation engine remains native.
- R6. Limit the shared file to the supported `docs_root` key and explain that a local `docs_root` value takes precedence.
- R7. Preserve a healthy CE setup and a clean repository diff.

### Acceptance Examples

- AE1. Given a clean checkout, when Git status is inspected, then `config.yaml` and `config.local.example.yaml` are trackable while `config.local.yaml` is ignored. Covers R1-R4.
- AE2. Given the added files, when the bundled CE health check runs, then it reports a healthy project, `docs/` as the default artifact root, native CE Work routing, and a current example. Covers R2, R5, R7.
- AE3. Given a maintainer opens `config.yaml`, when they read its content, then they see only the supported shared `docs_root` option and its local override precedence. Covers R6.

### Scope Boundaries

- Do not enable `docs_root`, model routing, output formats, product pulse, or any other optional CE setting. Do not present local-only settings as shared settings.
- Do not change the bundled Compound Engineering plugin or deployed user-level configuration.
- Do not apply chezmoi to the live home directory.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Create the local configuration from the current bundled template.** `(session-settled: user-approved — chosen over no local config: the user selected creation during setup.)` This keeps every supported preference discoverable without enabling one.
- KTD2. **Ignore all `.compound-engineering/*.local.yaml` files.** `(session-settled: user-approved — chosen over tracking the checkout-local file: machine-specific preferences must not enter version control.)`
- KTD3. **Add a separate tracked shared configuration.** `(session-settled: user-directed — chosen over local-only configuration: the user requested a shared layer for every clone and worktree.)`
- KTD4. **Limit the shared file to the commented `docs_root` setting.** Compound Engineering 3.21.0 reads only `docs_root` from the tracked layer. Other preferences remain local-only, so copying the full local template would promise unsupported shared behavior.

### Existing Patterns

- `.gitignore:30-32` already groups Compound Engineering rules under a dedicated heading.
- `.compound-engineering/config.local.example.yaml` is compared byte-for-byte with the bundled `ce-setup/references/config-template.yaml` by the CE health check.
- The CE `docs_root` resolution contract reads `.compound-engineering/config.local.yaml` before `.compound-engineering/config.yaml` and uses `docs/` when neither layer sets the key.

### Sequencing

1. Refresh the tracked example from the bundled template.
2. Create the ignored local copy and a tracked shared file that documents only `docs_root`.
3. Explain the supported shared scope and local-over-shared `docs_root` precedence.
4. Add the local-file ignore pattern.
5. Run CE and repository verification before shipping.

---

## Implementation Units

### U1. Add repository-local Compound Engineering configuration

- **Goal:** Satisfy R1-R7 without activating optional behavior.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7.
- **Files:** `.compound-engineering/config.yaml`, `.compound-engineering/config.local.example.yaml`, `.compound-engineering/config.local.yaml`, `.gitignore`.
- **Approach:** Use the CE 3.21.0 template for the example and local file. Create a concise shared file that contains only the commented `docs_root` option and its local-over-shared precedence. Add the narrow `*.local.yaml` ignore rule under the existing Compound Engineering section.
- **Test Scenarios:**
  - Compare both `.compound-engineering/config.local.example.yaml` and `.compound-engineering/config.local.yaml` with the bundled CE 3.21.0 `ce-setup/references/config-template.yaml` and require byte equality.
  - Inspect `.compound-engineering/config.yaml` and require it to contain only comments plus the commented `docs_root` option, including local-over-shared precedence guidance.
  - Run `ce-setup/scripts/check-health --version 3.21.0` from the loaded `ce-setup` skill directory with the repository root as the working directory. Require all project checks to pass.
  - Require `.compound-engineering/config.local.yaml` to exist before using `git check-ignore` to require it to be ignored.
  - Inspect Git status and require the shared and example files to remain visible as tracked candidates while the local file stays absent.
  - Stage the intended tracked artifacts, then run `git diff --cached --check` so newly created files are covered.
  - Run `git diff --check` and require no whitespace errors in remaining unstaged changes.
- **Verification:** The CE report states `Project config healthy`, `Artifact root: docs/`, `CE Work implementation engine: native`, and `Example config is current`.
- **Dependencies:** None.

---

## Verification Contract

| Gate | Applies to | Required result |
|---|---|---|
| Bundled `ce-setup/scripts/check-health --version 3.21.0` | U1 | Exit status 0; project config healthy; optional settings remain native/default. |
| Example and local template byte comparisons | U1 | Both files exactly match the bundled CE 3.21.0 template. |
| Shared-file content inspection | U1 | Only the supported commented `docs_root` option and accurate local precedence guidance are present. |
| Local config existence and ignore checks | U1 | The file exists and `git check-ignore -q .compound-engineering/config.local.yaml` exits 0. |
| `git diff --cached --check` after staging intended artifacts | U1 | Exit status 0 and all newly created tracked files are covered. |
| `git diff --check` | U1 | Exit status 0 for remaining unstaged changes. |
| Scoped Git status and diff inspection | U1 | Only requested CE configuration, ignore, and plan artifacts are present. |

No browser test applies because this change has no user interface or runtime page.

---

## Definition of Done

- U1 satisfies R1-R7 and all listed test scenarios.
- The CE health report is healthy.
- The local configuration is ignored and not committed.
- The shared configuration, example, ignore rule, and this plan are committed on the current branch.
- CI reaches terminal success.
- The pull request is mergeable and merged without bypassing checks or review.
- No abandoned or unrelated changes remain in the diff.
