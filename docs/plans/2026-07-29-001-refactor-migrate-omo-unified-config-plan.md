---
title: Migrate oh-my-openagent config to unified omo.jsonc - Plan
type: refactor
date: 2026-07-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Migrate oh-my-openagent config to unified omo.jsonc - Plan

## Goal Capsule

- **Objective:** Move the chezmoi-managed oh-my-openagent configuration from the legacy `~/.config/opencode/oh-my-openagent.json` surface to the v4.19.3 unified `~/.omo/omo.jsonc` surface, preserving every configured key, and bump the plugin pin to 4.19.3 so surface and version move atomically.
- **Authority hierarchy:** AGENTS.md source-layout and verification rules > upstream v4.19.3 configuration reference > this plan.
- **Stop conditions:** a render through `chezmoi execute-template` fails to produce the asserted JSON shape; the release-lock generator cannot resolve 4.19.3; any change outside the scoped file list appears.
- **Execution profile:** three units, all template/data/comment edits plus one generated lock refresh; no live `$HOME` apply at any point.
- **Tail ownership:** verification is render-only in a scratch destination per AGENTS.md; deployment is explicitly out of scope.

---

## Product Contract

### Summary

Replace the legacy oh-my-openagent config source with a new `dot_omo/` tree that deploys `~/.omo/omo.jsonc` with all plugin settings nested under the `"[opencode]"` block, remove the legacy deployed file through a chezmoi `remove_` attribute, regenerate the release lock at oh-my-openagent 4.19.3, and sweep stale references to the old config path and schema.

### Problem Frame

oh-my-openagent v4.19.3 removed the legacy config loaders: `oh-my-openagent.json[c]` is now read only by a one-time migration engine, and `~/.omo/omo.jsonc` is the single runtime config surface. This repo still deploys the legacy file (readonly) from `dot_config/opencode/readonly_oh-my-openagent.json.tmpl`, so once the plugin pin moves to 4.19.3 the managed model mappings and feature toggles would be ignored by the plugin and silently revert to upstream defaults.

### Requirements

**Config surface migration**

- R1. A new chezmoi source deploys `~/.omo/omo.jsonc` with `$schema` pointing at upstream `assets/omo.schema.json` and every plugin setting nested under a `"[opencode]"` block.
- R2. `agents` and `categories` remain data-driven from `.agents.opencode.ohMyOpenagent` in `.chezmoidata/agents.yaml`, rendered by the template rather than hand-copied.
- R3. All existing static keys are preserved verbatim under `"[opencode]"`: `claude_code`, `disabled_mcps`, `disabled_skills`, `disabled_hooks`, `browser_automation_engine`, `git_master`, `notification`.

**Legacy removal**

- R4. The legacy source template is deleted and the deployed `~/.config/opencode/oh-my-openagent.json` is removed on apply via a chezmoi `remove_` attribute, following the existing `remove_oh-my-openagent.jsonc` precedent.

**Version coherence**

- R5. The release lock's oh-my-openagent entry moves to 4.19.3 through the `packages/release-lock` generator, never by hand-editing `.chezmoidata/releases.json`.

**Reference sweep**

- R6. Stale references to the legacy config file and schema are updated: `.chezmoidata/agents.yaml` comments (lines 18-19, 505, 581), the `readonly_opencode.json.tmpl:62` comment, and `.opencode/commands/sync-omo-models.md` (template path and JSON assertion paths).

**Verification**

- R7. All changed templates are rendered through `chezmoi execute-template` with the AGENTS.md scratch-directory procedure; no live `$HOME` apply occurs.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. **New source `dot_omo/readonly_omo.jsonc.tmpl` with all settings under `"[opencode]"`, including `agents`/`categories`.** Chosen over placing `agents`/`categories` at the shared base level: this repo configures only the OpenCode harness, and the `[opencode]` placement matches both the upstream quick-start and the shape the migration engine itself imports. Sibling opencode configs are all `readonly_`, so the new file keeps that attribute.
- KTD-2. **Legacy removal via the `remove_` source attribute** (`dot_config/opencode/remove_oh-my-openagent.json`). Chosen over a `.chezmoiremove` entry — `.chezmoiremove` is reserved for unmanaged paths and its comments document that deleting a managed source alone never prunes the target — and over delegating removal to omo's migration engine, which would leave a repo-managed readonly file fighting the engine's backup/move behavior.
- KTD-3. **Keep the `readonly_` (0444) attribute on the new file.** For the opencode migration group this plan manages, the engine only writes `_migrations` markers when a legacy source exists to import; once R4 lands there is nothing of ours to migrate. Upstream documents additional migration sources this repo does not manage (`~/.omo/config.jsonc`, project `.opencode/oh-my-openagent.json[c]`, legacy profile dirs) whose markers are likewise written into the target `omo.jsonc` — a stray one on a host would fail against the 0444 file; that accepted consequence is covered in Risks. The readonly convention stays consistent with `readonly_opencode.json.tmpl` and `readonly_tui.json.tmpl`.
- KTD-4. **Bundle the release-lock bump to 4.19.3 in the same change.** Chosen over waiting for the hourly `refresh-release-lock.yml` run: a 4.19.2 plugin does not read `~/.omo/omo.jsonc`, so landing the config migration ahead of the pin would open a window where the deployed model mappings are inert.

### Assumptions

- Every preserved key (`claude_code`, `disabled_mcps`, `disabled_skills`, `disabled_hooks`, `browser_automation_engine`, `git_master`, `notification`) remains valid in v4.19.3; all nine keys (including `agents`/`categories`) are present under `[opencode].properties` in `assets/omo.schema.json` at the v4.19.3 tag. The prose configuration reference documents only a subset (`claude_code` does not appear there), so the schema is the validity oracle.
- The hourly refresh workflow would bump the pin anyway; U2 performs the same machine generation deterministically so the PR is atomic.
- The legacy deployed file on existing hosts contains the same content this repo manages, so omo's no-clobber import (if it runs before the next apply) produces no user data that the managed `omo.jsonc` would lose.

### Sequencing

U1 and U2 are independent; U3 depends on U1 (it points references at the file U1 creates). Land order: U2 → U1 → U3 keeps every intermediate state coherent (pin first, then surface, then comments).

---

## Implementation Units

### U1. Unified omo.jsonc source and legacy removal

- **Goal:** Deploy `~/.omo/omo.jsonc` from a new `dot_omo/` tree and remove the legacy config from both source and target.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none (U2 may land first per sequencing, but does not block)
- **Files:**
  - `dot_omo/readonly_omo.jsonc.tmpl` (create)
  - `dot_config/opencode/readonly_oh-my-openagent.json.tmpl` (delete)
  - `dot_config/opencode/remove_oh-my-openagent.json` (create, `{}` body like the `.jsonc` precedent)
- **Approach:** The new template emits a top object with `$schema` (`https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json`) and a `"[opencode]"` block holding the nine keys: the seven static keys from R3 plus the data-driven `agents`/`categories` from R2. `agents`/`categories` are injected from `.agents.opencode.ohMyOpenagent` with the same `toPrettyJson "\t" | trim | replace` indent-shift pattern as the old template, adjusted one level deeper (two-tab shift) because the block now nests inside `"[opencode]"`. Static blocks are copied verbatim from the old template. The `remove_` file mirrors `dot_config/opencode/remove_oh-my-openagent.jsonc` exactly apart from the target basename.
- **Patterns to follow:** the deleted template's rendering idiom; `dot_config/opencode/remove_oh-my-openagent.jsonc` for the removal attribute.
- **Test scenarios:**
  - Render `dot_omo/readonly_omo.jsonc.tmpl` via `chezmoi execute-template` (scratch config, stub `op`, `--source "$PWD"`): output parses as strict JSON.
  - Top-level keys are exactly `$schema` and `[opencode]`; `[opencode]` contains exactly the nine keys (seven static + agents/categories).
  - Rendered `[opencode].agents` and `[opencode].categories` deep-equal the data in `.chezmoidata/agents.yaml`.
  - Render the old template (pre-deletion, from git HEAD) and assert the new render's `[opencode]` block deep-equals the old render's top-level object minus `$schema`.
  - `chezmoi managed` (or `chezmoi status` dry-run against the scratch destination) lists `~/.omo/omo.jsonc` as managed and `.config/opencode/oh-my-openagent.json` as removed.
- **Verification:** all render assertions pass and the legacy template is gone from the source tree.

### U2. Release-lock bump to oh-my-openagent 4.19.3

- **Goal:** Regenerate `.chezmoidata/releases.json` so the oh-my-openagent pin is 4.19.3.
- **Requirements:** R5
- **Dependencies:** none
- **Files:** `.chezmoidata/releases.json` (generated output only)
- **Approach:** Run the `packages/release-lock` generator the same way `refresh-release-lock.yml` does (`cli.ts --out` per that workflow). Do not hand-edit the lock. The generator supports only full-lock regeneration (`--out`/`--stdout`; no per-tool scoping — verified against `packages/release-lock/src/cli.ts`), so any unrelated version drift it picks up is kept and disclosed in the commit/PR.
- **Execution note:** This is generated output; the only proof needed is the generator's own exit status plus a scoped diff.
- **Test scenarios:**
  - Lock entry `.tools["oh-my-openagent"].version` (path per the lock's actual schema) equals `4.19.3`.
  - `git diff` on `.chezmoidata/releases.json` shows only version-field changes.
  - Rendering `readonly_opencode.json.tmpl` now emits `oh-my-openagent@4.19.3` in the `plugin` array.
- **Verification:** generator exits 0; the rendered plugin spec reflects the new pin.

### U3. Stale reference sweep

- **Goal:** Point every live reference at the new config path, schema, and JSON shape.
- **Requirements:** R6
- **Dependencies:** U1
- **Files:**
  - `.chezmoidata/agents.yaml` (comments at lines 18-19, 505, 581)
  - `dot_config/opencode/readonly_opencode.json.tmpl` (comment at line 62)
  - `.opencode/commands/sync-omo-models.md` (template path ~line 207, JSON assertion ~line 209)
- **Approach:** Update comments to name `~/.omo/omo.jsonc` and its `"[opencode]"` block instead of `oh-my-openagent.jsonc`. In `readonly_opencode.json.tmpl:62` the comment names a source template, so repoint it at `dot_omo/readonly_omo.jsonc.tmpl` (a template name), not at the deployed path. In `sync-omo-models.md`, retarget the verification recipe to render `dot_omo/readonly_omo.jsonc.tmpl` and change the node assertions from `j.agents`/`j.categories` to `j["[opencode]"].agents`/`j["[opencode]"].categories`. While there, verify the command's two upstream `raw.githubusercontent.com` TS URLs still resolve on the upstream `dev` branch (the repo restructured into a monorepo); update the paths only if they 404. Do not touch `docs/plans/` history.
- **Test scenarios:**
  - A repo grep for `oh-my-openagent.jsonc`, `oh-my-opencode.schema.json`, and `readonly_oh-my-openagent.json.tmpl` outside `docs/plans/` returns no live references.
  - The updated `sync-omo-models.md` verification block, run as written, renders the new template and its assertions pass against the rendered JSON.
- **Verification:** grep sweep is clean and the command's own verification recipe succeeds.

---

## Verification Contract

| Gate | Command shape | Pass signal |
|---|---|---|
| Template render | `chezmoi --config <scratch>/empty.toml --source "$PWD" --destination <scratch>/target execute-template < <template>` with stub `op` on PATH per AGENTS.md | renders without error for every changed template |
| JSON shape | node assertion script over the rendered `omo.jsonc` output | top keys `[opencode]`+`$schema`; nine keys (seven static + agents/categories); agents/categories deep-equal YAML data |
| Plugin pin | render `readonly_opencode.json.tmpl` and inspect `plugin` | contains `oh-my-openagent@4.19.3` |
| Lock diff | `git diff .chezmoidata/releases.json` | version-field changes only |
| Reference sweep | grep for legacy config names outside `docs/plans/` | no live references |
| Repo hygiene | `git diff --check`, scoped `git status` | clean; diff limited to the files listed in U1-U3 |

No live `chezmoi apply` against `$HOME` is part of verification at any point.

---

## Definition of Done

- U1-U3 landed; every Verification Contract gate passes.
- Rendered `~/.omo/omo.jsonc` carries all nine keys (seven static plus data-driven agents/categories) identical to the legacy render.
- The legacy template is deleted, `remove_oh-my-openagent.json` exists, and the lock pins 4.19.3.
- No abandoned-attempt files or scratch artifacts remain in the diff; no changes outside the files listed in the units.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Plugin 4.19.2 ignores `~/.omo/omo.jsonc`, so landing the config before the pin inverts the breakage this plan fixes | U2 lands the pin bump first (KTD-4) |
| On a host, omo's migration engine may run before the next apply and import the legacy file into `~/.omo/omo.jsonc`, backing the legacy file up | Benign: the subsequent apply replaces `omo.jsonc` with identical managed content and the `remove_` no-ops on the already-moved legacy file (Assumptions) |
| The release-lock regeneration picks up unrelated tools' version drift | The generator has no per-tool scoping (full-lock `--out` only); disclose the extra entries in the PR |
| A host carries a stray unmanaged migration source (`~/.omo/config.jsonc`, project `.opencode/oh-my-openagent.json[c]`, legacy profile dirs); the engine writes `_migrations` markers into the target `~/.omo/omo.jsonc`, which the managed 0444 file rejects (EACCES) on every plugin start | Delete the stray source, or accept the recurring diagnostic — the managed file is authoritative and no-clobber means no data loss |
| Upstream moved the `model-core` TS files during its monorepo restructure, breaking `sync-omo-models.md` fetches | U3 verifies the URLs and updates them only on 404 |

## Sources & Research

- Release notes: <https://github.com/code-yeongyu/oh-my-openagent/releases/tag/v4.19.3> — legacy loaders gone, `omo.jsonc` the single config surface.
- v4.19.3 configuration reference (`docs/reference/configuration.md` on the tag): file locations, `"[opencode]"` block semantics, migration engine behavior, all preserved keys documented.
- Repo sweep (5-agent research, 2026-07-29): legacy source `dot_config/opencode/readonly_oh-my-openagent.json.tmpl`; removal precedent `dot_config/opencode/remove_oh-my-openagent.jsonc`; data source `.chezmoidata/agents.yaml:504+`; stale-reference set at `agents.yaml:18-19,505,581`, `readonly_opencode.json.tmpl:62`, `.opencode/commands/sync-omo-models.md:207,209`; pin at `.chezmoidata/releases.json:532-536` via `packages/release-lock/src/registry.ts:242-246`.
