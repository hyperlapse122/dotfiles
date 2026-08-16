---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Plan: Fix compound-engineering plugin.json Change Warning on Chezmoi Apply

## Executive Summary

During `chezmoi apply`, an interactive prompt or error occurs: `.local/share/compound-engineering/v3.22.0/plugin.json has changed since chezmoi last wrote it?`. This happens because `.chezmoiexternals/ai-agents.toml` extracts the full GitHub archive of `compound-engineering-plugin` (including its root `plugin.json`), and then `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` deletes `$CURRENT/plugin.json` because OMP's agent-plugin parser breaks when root `plugin.json` is present. Chezmoi detects that a file it extracted and tracked was deleted outside its file phase, triggering the change-detection prompt.

The fix configures `exclude = ["*/plugin.json"]` on the `compound-engineering-plugin` localArchive external via `.chezmoidata/agents.yaml` and `.chezmoiexternals/ai-agents.toml`, preventing chezmoi from ever extracting or tracking `plugin.json`.

## Problem Framing & User Value

- **Trigger:** Applying dotfiles via `chezmoi apply` halts or prompts with `.local/share/compound-engineering/v3.22.0/plugin.json has changed since chezmoi last wrote it?`. In non-interactive environments (CI or background runs), this fails with `could not open a new TTY`.
- **Root Cause:** Chezmoi manages external archives declaratively. When extracting `.local/share/compound-engineering/v<semver>`, chezmoi writes `plugin.json` and records it in its internal entry state. Later in the apply sequence, `run_after_compound-engineering-overlays.sh.tmpl` removes `plugin.json` with `rm -f`. On subsequent applies, chezmoi's drift detection sees that `plugin.json` is missing/modified and prompts the user.
- **User Value:** `chezmoi apply` runs cleanly and idempotently without prompting or failing on `plugin.json`.

## Key Technical Decisions (KTDs)

1. **KTD1: Data-driven archive exclusion in `.chezmoidata/agents.yaml`**
   - *Decision:* Declare `exclude: ["*/plugin.json"]` under `agents.marketplaces.compound-engineering-plugin` in `.chezmoidata/agents.yaml`.
   - *Rationale:* Adheres to the repository's Single Source of Truth principle (AGENTS.md). Template logic in `.chezmoiexternals/ai-agents.toml` reads `$authority.exclude` generically for any `localArchive`.
   - *Rejected Alternative:* Hardcoding `exclude = ["*/plugin.json"]` in `.chezmoiexternals/ai-agents.toml`.

2. **KTD2: Glob pattern for stripComponents archive exclusion**
   - *Decision:* Use `"*/plugin.json"` as the exclude pattern.
   - *Rationale:* Chezmoi evaluates `exclude` against paths inside the tarball prior to `stripComponents = 1` stripping (e.g. `compound-engineering-plugin-<tag>/plugin.json`). Testing confirmed `"*/plugin.json"` excludes the root `plugin.json` while preserving subdirectories like `.claude-plugin/marketplace.json`.
   - *Rejected Alternative:* Using bare `"plugin.json"`, which does not match top-level archive members prefixed with the repository tag directory.

3. **KTD3: Retain defensive cleanup in overlay script**
   - *Decision:* Keep `rm -f -- "$CURRENT/plugin.json"` in `run_after_compound-engineering-overlays.sh.tmpl`.
   - *Rationale:* On existing machines where `plugin.json` was already written before this fix, the script cleans it up. Because `plugin.json` is no longer managed or tracked by chezmoi, the removal causes zero chezmoi warnings on future applies.

## Implementation Scope & Boundaries

- **In Scope:**
  - Update `.chezmoidata/agents.yaml` to declare `exclude: ["*/plugin.json"]` for `compound-engineering-plugin`.
  - Update `.chezmoiexternals/ai-agents.toml` to emit `exclude` for `localArchive` marketplaces when declared.
  - Update `.ci/test-compound-engineering-overlays.sh` to assert `exclude` is rendered and test repeated applies.
- **Out of Scope:**
  - Modifying `i-have-adhd` or other localArchive marketplaces that do not have extraneous root manifests.
  - Changing OMP plugin reconciliation logic.

## Implementation Units

- **U1: Add `exclude` to `.chezmoidata/agents.yaml` and `.chezmoiexternals/ai-agents.toml`**
  - *Files:* `.chezmoidata/agents.yaml`, `.chezmoiexternals/ai-agents.toml`
  - *Details:* Add `exclude: ["*/plugin.json"]` to `compound-engineering-plugin` in `agents.yaml`. In `ai-agents.toml`, render `exclude = {{ toJson $authority.exclude }}` when `exclude` is present.
- **U2: Update and verify `.ci/test-compound-engineering-overlays.sh`**
  - *Files:* `.ci/test-compound-engineering-overlays.sh`
  - *Details:* Add assertions that rendered `ai-agents.toml` contains `exclude = ["*/plugin.json"]` in the compound-engineering block. Verify all tests pass.

## Verification Contract

1. `chezmoi execute-template < .chezmoiexternals/ai-agents.toml` renders `exclude = ["*/plugin.json"]` in `[".local/share/compound-engineering/v3.22.0"]`.
2. `.ci/test-compound-engineering-overlays.sh` passes with zero errors.
3. Full CI test suite (`.ci/test-*.sh`) passes.

## Definition of Done

- `.chezmoidata/agents.yaml` and `.chezmoiexternals/ai-agents.toml` updated.
- `.ci/test-compound-engineering-overlays.sh` updated and passing.
- No chezmoi apply warnings or prompts regarding `plugin.json`.
