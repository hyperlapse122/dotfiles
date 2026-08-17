---
date: 2026-08-17
topic: feat-manage-agent-plugins-in-agents-yaml
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Plan: Manage Agent Plugins in agents.yaml and Wire Up for Oh My Pi

## Executive Summary

This plan adds support for managing portable Agent Plugins ([agent-plugins.org](https://agent-plugins.org/llms.txt) v1.0.0 standard) declaratively in `.chezmoidata/agents.yaml`, fetching them via chezmoi archive externals in `.chezmoiexternals/ai-agents.toml`, and wiring them up to Oh My Pi (`omp`) via the local `h82-dotfiles` marketplace and OMP plugin reconciler. It also evaluates and documents the migration status of `compound-engineering`: compound-engineering is already managed as an OMP marketplace plugin (`compound-engineering-plugin`) rather than an unmanaged skill, and retaining its Claude-plugin marketplace format is required because OMP's Agent Plugins loader strictly rejects skills whose frontmatter contains non-standard keys (`argument-hint`, `disable-model-invocation`).

## Problem Framing & User Value

- **Problem:** Currently, `.chezmoidata/agents.yaml` supports individual Agent Skills (`agents.skills.external`) and OMP marketplace plugins (`agents.omp.plugins` + `agents.marketplaces`), but does not have a dedicated, declarative schema for managing portable Agent Plugins (packages containing `plugin.json`, `skills/`, `mcp.json`, and client extensions per the Agent Plugins specification).
- **User Value:** Users can declare external Agent Plugins in `.chezmoidata/agents.yaml` under `agents.agentPlugins.external`. Chezmoi downloads and unpacks the version-pinned plugin archives into the local plugin marketplace tree (`~/.local/share/omp-plugins/plugins/<name>`), the `h82-dotfiles` marketplace automatically catalogs them, and `omp` installs/enables them cleanly during apply.

## Product Contract & Requirements

- **R1: Declarative Schema:** `.chezmoidata/agents.yaml` supports `agents.agentPlugins.external` containing a list of external agent plugins with fields `name`, `source`, optional `ref`, `versionSource`, `path`, and `description`.
- **R2: Archive Externals:** `.chezmoiexternals/ai-agents.toml` processes `agents.agentPlugins.external` and emits archive entries that extract plugins into `.local/share/omp-plugins/plugins/{{ .name }}` (with correct component stripping and path handling).
- **R3: Dynamic Local Marketplace Catalog:** `dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json` is converted to a chezmoi template `marketplace.json.tmpl` that dynamically includes both the native `mxm4-haptic` plugin and any declared plugins from `agents.agentPlugins.external`.
- **R4: OMP Plugin Reconciliation & Validation:** `run_onchange_after_update-omp-plugins.sh.tmpl` and `omp-plugin-reconcile-helper.ts.tmpl` are updated so that any plugin cataloged in the `h82-dotfiles` marketplace can be validated and installed (while preserving strict haptic verification for `mxm4-haptic`).
- **R5: Compound Engineering Status & Compatibility:** Retain `compound-engineering` as a `localArchive` marketplace plugin (`compound-engineering-plugin`) and document why migrating it to root `plugin.json` Agent Plugin mode is blocked (OMP's agent-plugin frontmatter validator drops 30 of 33 skills due to `argument-hint`/`disable-model-invocation`).
- **R6: Documentation:** Update `AGENTS.md` to document the new `agents.agentPlugins.external` section and its lifecycle.
- **R7: Test & CI Integrity:** Update `.ci/test-omp-agent-reconcile.sh` and ensure all CI checks and template renders pass with zero errors.

## Key Technical Decisions (KTDs)

1. **KTD1: Mirror `agents.skills.external` pattern for `agents.agentPlugins.external`**
   - *Decision:* Add `agents.agentPlugins.external` alongside `agents.skills.external` in `.chezmoidata/agents.yaml`.
   - *Rationale:* Preserves repository conventions, provides a clean separation between individual skills (`~/.agents/skills/`) and full multi-component agent plugins, and allows granular version pinning.
   - *Rejected Alternative:* Overloading `agents.skills.external` or mixing plugin declarations directly into `agents.omp.plugins`.

2. **KTD2: Extract Agent Plugins into `~/.local/share/omp-plugins/plugins/<name>`**
   - *Decision:* Extract external agent plugins into `.local/share/omp-plugins/plugins/<name>`.
   - *Rationale:* OMP's marketplace resolver enforces realpath containment (`g6(marketplaceClonePath, source)`). Placing external plugins inside the local marketplace directory (`~/.local/share/omp-plugins`) allows them to be referenced as `./plugins/<name>` without triggering realpath escape errors.
   - *Rejected Alternative:* Extracting to `~/.agents/plugins/<name>` and symlinking into `~/.local/share/omp-plugins/plugins/` (symlinks fail OMP's realpath containment check).

3. **KTD3: Templatize `dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json.tmpl`**
   - *Decision:* Convert static `marketplace.json` into a template that iterates over `.agents.agentPlugins.external` and emits entries in the `h82-dotfiles` marketplace.
   - *Rationale:* Keeps `marketplace.json` in sync with declared data automatically without requiring manual duplicate edits.

4. **KTD4: Generalize `omp-plugin-reconcile-helper.ts.tmpl` for `h82-dotfiles` marketplace**
   - *Decision:* Update `omp-plugin-reconcile-helper.ts.tmpl` in `pre` mode to verify that `h82-dotfiles` catalog exists and contains valid plugin entries, while keeping strict pre/post package verification specific to `mxm4-haptic`.
   - *Rationale:* Allows any agent plugin in `h82-dotfiles` to pass precheck and postcheck while preserving the rigorous haptic daemon verification.

5. **KTD5: Preserve Compound Engineering's `.claude-plugin/` marketplace loading**
   - *Decision:* Keep `compound-engineering` managed as a `localArchive` marketplace plugin and continue excluding/pruning root `plugin.json`.
   - *Rationale:* Upstream Compound Engineering's `SKILL.md` files include `argument-hint` and `disable-model-invocation`. When root `plugin.json` is present, OMP classifies it as an Agent Plugin and rejects 30 of 33 skills. Loading via `.claude-plugin/` preserves all 33 skills.

## Implementation Units

### U1. Add `agents.agentPlugins.external` to `.chezmoidata/agents.yaml`
- **Files:** `.chezmoidata/agents.yaml`
- **Details:** Add `agentPlugins` section with schema comments and examples under `agents:`.

### U2. Update `.chezmoiexternals/ai-agents.toml` for Agent Plugins
- **Files:** `.chezmoiexternals/ai-agents.toml`
- **Details:** Add template loop over `agents.agentPlugins.external` to emit archive external declarations targeting `[".local/share/omp-plugins/plugins/{{ .name }}"]` with `stripComponents` and `exact = true`.

### U3. Templatize `dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json.tmpl`
- **Files:** `dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json` -> `marketplace.json.tmpl`
- **Details:** Convert to chezmoi template that emits `mxm4-haptic` and all entries from `agents.agentPlugins.external`.

### U4. Update OMP Plugin Reconciler & Helper
- **Files:** `.chezmoitemplates/omp-plugin-reconcile-helper.ts.tmpl`, `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`
- **Details:** Allow non-haptic plugins in `h82-dotfiles` marketplace, update fingerprints to include `marketplace.json.tmpl`.

### U5. Update Documentation & AGENTS.md
- **Files:** `AGENTS.md`
- **Details:** Document Agent Plugins management under `agents.agentPlugins.external` and OMP usage.

### U6. Update Tests & Verification
- **Files:** `.ci/test-omp-agent-reconcile.sh`, `.ci/test-omp-real-plugin.sh`
- **Details:** Update tests to account for `marketplace.json.tmpl` and verify that multi-plugin `h82-dotfiles` marketplace passes all checks.

## Verification Contract

1. `chezmoi execute-template < .chezmoiexternals/ai-agents.toml` renders valid TOML.
2. `chezmoi execute-template < dot_local/share/omp-plugins/dot_omp-plugin/marketplace.json.tmpl` renders valid JSON with all declared plugins.
3. `chezmoi execute-template < .chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl` passes `bash -n`.
4. `.ci/test-omp-agent-reconcile.sh` passes completely in an isolated environment.
5. All `.ci/test-*.sh` scripts pass.
