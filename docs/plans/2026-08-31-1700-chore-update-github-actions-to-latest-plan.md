---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Chore: Update GitHub Actions Workflows to Latest Versions

## Goal Capsule

- **Objective**: All GitHub Actions referenced across `.github/workflows/` (`ci.yml`, `merge-commit-only.yml`, `refresh-release-lock.yml`, `render-dotfiles.yml`) are updated to their latest stable releases/tags according to upstream repository tags.
- **Means**: Audit each action repository (`actions/checkout`, `oven-sh/setup-bun`, `voidzero-dev/setup-vp`, `dtolnay/rust-toolchain`, `Swatinem/rust-cache`, `actions/upload-artifact`, `actions/download-artifact`) via GitHub API, update any outdated action references in `.github/workflows/*.yml`, and verify all workflow files pass local syntax, template, and test validations. (KTD1)
- **Authority Hierarchy**: User request > Repository CI conventions > Toolchain version policies.
- **Stop Conditions**: All actions in `.github/workflows/*.yml` verified and updated to latest versions with zero regressions in CI/lint/render tests.

## Product Contract

### Summary
Update all GitHub Actions referenced across workflow definitions in `.github/workflows/` to their newest releases, ensuring CI pipelines use current action versions.

### Problem Frame
Workflow files under `.github/workflows/` invoke various GitHub actions. Keeping them pinned to their latest stable major releases ensures compatibility, security patches, performance improvements, and alignment with modern GitHub runner environments.

### Requirements
- **R1**: Audit and update all actions referenced in `.github/workflows/ci.yml`.
- **R2**: Audit and update all actions referenced in `.github/workflows/merge-commit-only.yml`.
- **R3**: Audit and update all actions referenced in `.github/workflows/refresh-release-lock.yml`.
- **R4**: Audit and update all actions referenced in `.github/workflows/render-dotfiles.yml`.
- **R5**: Ensure all workflow files remain syntactically valid and pass local regression/validation tests (`.ci/test-merge-commit-only-gates.sh`, `.ci/test-agent-instructions.sh`, etc.).

## Planning Contract

### Key Technical Decisions
- **KTD1: Use upstream major version tags or canonical tracking branches**:
  - `actions/checkout`: `@v7` (upstream `v7.0.1`)
  - `oven-sh/setup-bun`: `@v2` (upstream `v2.2.0`)
  - `voidzero-dev/setup-vp`: `@v1` (upstream `v1.18.0`)
  - `dtolnay/rust-toolchain`: `@stable` (upstream tracking branch for stable toolchain)
  - `Swatinem/rust-cache`: `@v2` (upstream `v2.9.2`)
  - `actions/upload-artifact`: `@v7` (upstream `v7.0.1`)
  - `actions/download-artifact`: `@v8` (upstream `v8.0.1`)

### Technical Design
Each workflow in `.github/workflows/` is inspected for action references (`uses:` lines). The versions are verified against upstream releases. Any outdated references or syntax inconsistencies are addressed while preserving all input parameters, environment variables, step names, and condition logic.

### Assumptions
- All actions currently specified are using the latest major release tags (`v7` for checkout/upload-artifact, `v8` for download-artifact, `v2` for setup-bun/rust-cache, `v1` for setup-vp, `stable` for rust-toolchain).
- No structural changes to action input parameters are required as existing major versions match the latest available upstream tags.

## Implementation Units

### U1: Audit and Verify Action Versions
- **Goal**: Query GitHub API for all referenced actions to confirm current upstream latest releases and tags.
- **Requirements**: R1, R2, R3, R4, R5
- **Files**: `.github/workflows/*.yml`
- **Approach**: Inspect `actions/checkout`, `oven-sh/setup-bun`, `voidzero-dev/setup-vp`, `dtolnay/rust-toolchain`, `Swatinem/rust-cache`, `actions/upload-artifact`, `actions/download-artifact`.
- **Verification**: GitHub API queries confirm exact tags.

### U2: Update Action References
- **Goal**: Apply any necessary version bumps or formatting fixes to `.github/workflows/*.yml`.
- **Requirements**: R1, R2, R3, R4
- **Files**:
  - `.github/workflows/ci.yml`
  - `.github/workflows/merge-commit-only.yml`
  - `.github/workflows/refresh-release-lock.yml`
  - `.github/workflows/render-dotfiles.yml`
- **Approach**: Update action versions to verified latest major tags across all jobs.
- **Verification**: Workflows contain the latest action tags.

### U3: Validate Workflows and Run Regression Gates
- **Goal**: Ensure all workflow files pass local gates and template checks.
- **Requirements**: R5
- **Files**: `.ci/test-merge-commit-only-gates.sh`, `.ci/test-agent-instructions.sh`
- **Approach**: Execute local CI test fixtures to prove no regressions.
- **Verification**: Test scripts execute and exit 0.

## Verification Contract

- **Workflow YAML validation**: Confirm all 4 YAML files parse without syntax errors.
- **Local CI gate testing**:
  - `.ci/test-merge-commit-only-gates.sh`
  - `.ci/test-agent-instructions.sh`
  - Render validation via chezmoi if applicable.

## Definition of Done

- All actions in `.github/workflows/ci.yml`, `.github/workflows/merge-commit-only.yml`, `.github/workflows/refresh-release-lock.yml`, and `.github/workflows/render-dotfiles.yml` are verified against the latest upstream releases.
- All local tests and verification checks pass cleanly.
