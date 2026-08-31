---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix Script PATH Resolution, Codegraph Command Path, and Autostart Configuration

## Goal Capsule

- **Objective**: Ensure chezmoi provisioning and capability probing scripts reliably resolve binaries in `~/.local/bin` during fresh initialization, correct the `codegraph` command unit symlink target, remove the `claude.desktop` autostart configuration, and upgrade `bun` to version 1.4.0 across mise and packages.
- **Means**: Add `$HOME/.local/bin` and `$HOME/.local/sbin` to `$PATH` in `.install-prerequisites.sh` and affected `.chezmoiscripts/` entry points (KTD1), update `codegraph` `relPath` to `bin/codegraph` in `.chezmoidata/commands.yaml` (KTD2), delete `dot_config/autostart/private_claude-desktop.desktop`, clean up `dot_config/autostart/.chezmoiignore`, declare `.config/autostart/claude-desktop.desktop` in `.chezmoiremove` (KTD3), and bump `bun` to `1.4.0` in `mise.toml`, `packages/package.json`, and workflow definitions (KTD4).
- **Authority Hierarchy**: `.chezmoidata/commands.yaml` (command manifest) > `mise.toml` (tool runtime pins) > `.install-prerequisites.sh` / `.chezmoiscripts/` (provisioning lifecycle) > `dot_config/autostart/` (autostart targets).
- **Stop Conditions**: Stop and report if template rendering fails or CI capability cache / skip declaration checks fail.

## Product Contract

### Summary

This change resolves three separate issues across dotfiles provisioning and configuration:
1. **Issue #324**: Non-login and non-interactive subshells in `chezmoi apply` omit `$HOME/.local/bin` from `$PATH`, causing `command -v mise`, `command -v garden`, `command -v aoe`, and capability caching in `.install-prerequisites.sh` to fail on fresh systems or when invoked with standard system `$PATH`.
2. **Issue #325**: The `codegraph` command unit in `.chezmoidata/commands.yaml` declares `relPath: codegraph` instead of `relPath: bin/codegraph`, creating a broken symlink `~/.local/bin/codegraph -> ../lib/commands/current/codegraph/codegraph`.
3. **Issue #326**: `dot_config/autostart/private_claude-desktop.desktop` launches Claude Desktop automatically on system startup for Ubuntu systems; this autostart entry should be decommissioned and pruned.

### Problem Frame

During fresh machine provisioning, `chezmoi` runs in a shell where `$PATH` is defaulted to system directories (e.g. `/usr/bin:/bin`). Since tools like `mise`, `garden`, `aoe`, and `omp` are installed to or symlinked into `~/.local/bin`, scripts that check `command -v <tool>` fail or skip incorrectly. Furthermore, capability caching runs before login shell dotfiles are sourced. Concurrently, the `codegraph` command symlink is broken due to incorrect `relPath` in the command manifest, and `claude-desktop.desktop` runs unintentionally on Ubuntu login.

### Requirements

- **R1 (Issue #324)**: `.install-prerequisites.sh` must prepend `$HOME/.local/bin` and `$HOME/.local/sbin` to `$PATH` before performing capability caching, tool checks, and prerequisite installation.
- **R2 (Issue #324)**: `.chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl` must ensure `$HOME/.local/bin` is in `$PATH` and check fallback locations (`$HOME/.local/bin/mise`, `$HOME/.local/share/chezmoi-commands/incomplete/mise/mise`) if `mise` is not yet on `$PATH`.
- **R3 (Issue #324)**: All `.chezmoiscripts/` scripts that invoke local binaries (`00-tools/run_once_before_mise-trust.sh.tmpl`, `60-build/run_onchange_after_build-figma-auth.sh.tmpl`, `60-build/run_onchange_after_build-settings-reconcile.sh.tmpl`, `60-build/run_after_build-mxm4-haptic.sh.tmpl`, `70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`, `90-src/run_onchange_after_reconcile-garden.sh.tmpl`) must ensure `$HOME/.local/bin` is in `$PATH`.
- **R4 (Issue #325)**: `.chezmoidata/commands.yaml` must set `relPath: bin/codegraph` for the `codegraph` command under `commands.units.codegraph`.
- **R5 (Issue #326)**: `dot_config/autostart/private_claude-desktop.desktop` must be removed from the repository.
- **R6 (Issue #326)**: `dot_config/autostart/.chezmoiignore` must remove the Ubuntu-scoped ignore rule for `private_claude-desktop.desktop`.
- **R7 (Issue #326)**: `.chezmoiremove` must include `.config/autostart/claude-desktop.desktop` to prune existing deployed copies.
- **R8 (Bun Upgrade)**: `bun` must be upgraded to `1.4.0` in `mise.toml`, `mise.lock`, `packages/package.json`, `packages/README.md`, and `.github/workflows/refresh-release-lock.yml`.

### Success Criteria

1. `.install-prerequisites.sh` executes with `PATH="/usr/bin:/bin"` and properly probes capabilities that reside in `~/.local/bin`.
2. `00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl` builds and stages `command-reconcile` even when `$HOME/.local/bin` was omitted from parent `$PATH`.
3. `reconcile-commands` manifests render `relPath: bin/codegraph` for `codegraph`.
4. `claude-desktop.desktop` is deleted from source, removed from `.chezmoiignore`, and added to `.chezmoiremove`.
5. CI test suites (`.ci/test-capability-cache.sh`, `.ci/check-skip-declarations.sh`, `.ci/test-build-command-reconcile.sh`) pass cleanly.

## Planning Contract

### Key Technical Decisions

- **KTD1: Defensively Prepend PATH Across Scripts**:
  In `.install-prerequisites.sh` and `.chezmoiscripts/`, defensively prepend `$HOME/.local/bin` and `$HOME/.local/sbin` to `$PATH` using standard bash `case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac` syntax.
- **KTD2: Codegraph Relative Path Fix**:
  In `.chezmoidata/commands.yaml`, changing `relPath: codegraph` to `relPath: bin/codegraph` matches the unpacked directory layout (`bin/codegraph`) of upstream `codegraph` release archives.
- **KTD3: Autostart Decommissioning Lifecycle**:
  Follow standard repository lifecycle: delete source file, clean `.chezmoiignore`, and declare target in `.chezmoiremove` so previously deployed files on Ubuntu systems are pruned on subsequent apply.
- **KTD4: Bun 1.4.0 Version Bump**:
  Update `bun` from `1.3.14` to `1.4.0` across the repo's tool configuration, lockfiles, package manifests, and GitHub workflows.

## Implementation Units

### U1. Prepend `$HOME/.local/bin` in `.install-prerequisites.sh`
- **Goal**: Ensure `.install-prerequisites.sh` has `$HOME/.local/bin` and `$HOME/.local/sbin` on `$PATH` for capability checks (`command-present` probes) and prerequisite checks (`op`, `mise`).
- **Files**: `.install-prerequisites.sh`
- **Approach**: Add the `$PATH` normalization block right after `set -euo pipefail`.
- **Test Scenarios**:
  - Run `.ci/test-capability-cache.sh` and verify all capability checks resolve correctly.

### U2. Normalize `$PATH` and fallback resolution in `.chezmoiscripts/`
- **Goal**: Ensure provisioning scripts in `00-tools`, `60-build`, `70-agents`, and `90-src` prepend `$HOME/.local/bin` to `$PATH` and resolve `mise` reliably.
- **Files**:
  - `.chezmoiscripts/00-tools/run_once_before_mise-trust.sh.tmpl`
  - `.chezmoiscripts/00-tools/run_onchange_after_10-build-command-reconcile.sh.tmpl`
  - `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl`
  - `.chezmoiscripts/60-build/run_onchange_after_build-settings-reconcile.sh.tmpl`
  - `.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh.tmpl`
  - `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`
  - `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`
- **Approach**:
  - Add `$HOME/.local/bin` to `$PATH` in each script.
  - In `build-command-reconcile`, also check fallback paths for `mise` (`$HOME/.local/bin/mise`, `$HOME/.local/share/chezmoi-commands/incomplete/mise/mise`).
- **Test Scenarios**:
  - Render scripts with dummy `op` CLI and verify rendered content.
  - Run `.ci/check-skip-declarations.sh` and `.ci/test-build-command-reconcile.sh`.

### U3. Fix `codegraph` command relative path in `.chezmoidata/commands.yaml`
- **Goal**: Point `codegraph` command symlink to `bin/codegraph`.
- **Files**: `.chezmoidata/commands.yaml`
- **Approach**: Update `relPath: codegraph` to `relPath: bin/codegraph` under `commands.units.codegraph`.
- **Test Scenarios**:
  - Run `.ci/test-command-manifest.sh` to ensure command manifest validation passes.

### U4. Remove `claude.desktop` autostart and add to `.chezmoiremove`
- **Goal**: Delete `dot_config/autostart/private_claude-desktop.desktop`, clean up `dot_config/autostart/.chezmoiignore`, and add `.config/autostart/claude-desktop.desktop` to `.chezmoiremove`.
- **Files**:
  - `dot_config/autostart/private_claude-desktop.desktop` (delete)
  - `dot_config/autostart/.chezmoiignore`
  - `.chezmoiremove`
- **Approach**: Remove file, remove Ubuntu condition block in `.chezmoiignore`, append entry with comment in `.chezmoiremove`.
- **Test Scenarios**:
  - Render autostart targets and verify `.chezmoiremove` contains `.config/autostart/claude-desktop.desktop`.
### U5. Upgrade Bun to 1.4.0
- **Goal**: Bump `bun` pin to 1.4.0 across `mise.toml`, `packages/package.json`, `packages/README.md`, and `.github/workflows/refresh-release-lock.yml`.
- **Files**:
  - `mise.toml`
  - `packages/package.json`
  - `packages/README.md`
  - `.github/workflows/refresh-release-lock.yml`
- **Approach**: Update the version strings, then run `mise install` / `mise lock` to update `mise.lock`.
- **Test Scenarios**:
  - Run `mise exec -- bun --version` and verify it reports `1.4.0`.

## Verification Contract

| Test / Check | Target / Command | Expectation |
|---|---|---|
| Skip declarations | `.ci/check-skip-declarations.sh` | Clean exit 0, matrix matches rendered instances |
| Capability cache | `.ci/test-capability-cache.sh` | Clean exit 0, all capability probes pass |
| Command manifest | `.ci/test-command-manifest.sh` | Clean exit 0, valid manifest schema and units |
| Template rendering | `chezmoi execute-template` with dummy op stub | All changed templates render without error |

## Definition of Done

1. All 5 implementation units (U1-U5) implemented and verified.
2. All CI checks (`check-skip-declarations.sh`, `test-capability-cache.sh`, `test-command-manifest.sh`) pass.
3. Template rendering verified using dummy `op` CLI and scratch destination.
4. No temporary test files or unstaged debris left in workspace.
