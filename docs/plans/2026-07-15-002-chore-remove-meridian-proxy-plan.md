---
title: Remove Meridian and cli-proxy-api Residue - Plan
type: chore
date: 2026-07-15
topic: remove-meridian-proxy
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Remove Meridian and cli-proxy-api Residue - Plan

> **Status:** Implemented (commit `c4748b5`).

## Goal Capsule

- **Objective:** Fully remove the active Meridian proxy integration, purge the leftover cli-proxy-api text and CI guards it superseded, and switch Pi's managed default from Codex to Z.ai `glm-5.2` so the main session keeps a smart model without any proxy.
- **Product authority:** Repo owner (dotfiles maintainer). Decisions in this doc are confirmed.
- **Open blockers:** None. Two items are apply-time verifications (Pi reaches `zai`/`glm-5.2` directly; `glm-5.2` honors `max` thinking), and runtime teardown is the maintainer's manual concern by explicit direction.

---

## Product Contract

### Summary

Remove every Meridian component — externals, provisioning/build/service scripts, the systemd unit, the macOS LaunchAgent, the CI smoke-builds and assertions across all four `render-dotfiles` jobs, and the `AGENTS.md`/`README.md` documentation — and delete `dot_pi/agent/readonly_models.json`, whose only job was the Meridian override. Pi's managed default moves from `openai-codex` / `gpt-5.6-sol` to the `zai` provider's `glm-5.2`; subagents stay on Codex. Purge the surviving cli-proxy-api text: the README legacy-migration note and both CI guards. OpenCode's own config is untouched — it never routed through Meridian.

### Problem Frame

Meridian is the currently-active POSIX Claude-Max loopback proxy (`127.0.0.1:3456`) that replaced the older cli-proxy-api / CLIProxyAPI proxy. Its only consumer is Pi, through `dot_pi/agent/readonly_models.json`, which overrides Pi's `anthropic` provider baseUrl to the loopback with an `x-meridian-agent: pi` header — giving Pi Claude access with no API key.

cli-proxy-api itself is already gone as a component, but un-purged text survives in two places: a "One-time migration from the legacy proxy" section in `README.md`, and two guards in `.github/workflows/render-dotfiles.yml` — one blocking the `cli-proxy-api` / `CLIProxyAPI` / `127.0.0.1:8317` literals, one blocking the `zai` / `zai-coding-plan` / `moonshotai` / `google-agy` provider prefixes in `.chezmoidata/agents.yaml`.

Removing Meridian leaves Pi's Codex default intact but strips its Claude path, so the main session needs a replacement smart model. Z.ai `glm-5.2` fills that slot and Pi reaches it directly through the existing `zai` API-key auth — no proxy, no new Anthropic key. That replacement also makes the provider-prefix guard stale, which is what ties the cli-proxy-api text purge to the Meridian removal rather than leaving it as separate cleanup.

### Key Decisions

- **Pi default → Z.ai `glm-5.2`, not re-added Claude.** Switch Pi's managed default to provider `zai` / model `glm-5.2`, reusing the existing `zai` API-key auth. No proxy and no new Anthropic key.
- **Subagents stay on Codex.** Only the main session moves to GLM; the `gpt-5.6-*` subagent overrides are unchanged.
- **`readonly_models.json` deleted outright.** Its sole content was the Meridian `anthropic` override. Pi reaches `zai` / `glm-5.2` through its built-in provider plus the existing auth, so no `models.json` entry is needed.
- **Whole provider-prefix guard removed.** The CI guard forbidding `zai` / `zai-coding-plan` / `moonshotai` / `google-agy` was cli-proxy-api-era scaffolding; all four are now legitimate direct providers, so the entire guard is removed, not just the `zai` arm.
- **No teardown machinery.** No teardown/revert script, no new `.chezmoiremove` residue entry, and no README migration note. Deleting the managed sources removes their deployed targets on the next apply; the running service, the `~/.local/share/meridian` tree, `~/.local/bin/meridian`, and `~/.config/meridian` credentials are left for manual cleanup.
- **OpenCode config untouched.** OpenCode is already decoupled from Meridian; the removal requires zero changes to `dot_config/opencode/`. The only "Meridian-plugin-for-OpenCode" traces removed are the CI absence-guards and the `opencode-scrub` residue lines — neither is OpenCode config.

### Requirements

**Meridian source removal**

R1. The whole Meridian region of `.chezmoiexternals/ai-agents.toml` is removed — the version-resolution template blocks and the `[meridian]`, `[meridian.checksum]`, `[meridian-plugin-pi-scrub]`, and `[meridian-plugin-hermes-scrub]` sections — and the two Meridian mentions in the file's comments are reconciled.

R2. The Meridian provisioning, build, and service scripts are deleted: `.chezmoiscripts/00-tools/run_onchange_after_meridian.sh.tmpl`, `.chezmoiscripts/60-build/run_onchange_after_build-meridian-plugin-pi-scrub.sh.tmpl`, `.chezmoiscripts/60-build/run_onchange_after_build-meridian-plugin-hermes-scrub.sh.tmpl`, and `.chezmoiscripts/90-services/run_onchange_after_meridian-service.sh.tmpl`.

R3. The managed service artifacts are deleted: `dot_config/systemd/user/meridian.service` (Linux) and `Library/LaunchAgents/dev.h82.meridian.plist` (macOS).

R4. Every `.chezmoiignore` rule or comment that exists only to gate Meridian files is reconciled — the Windows `.pi/agent/models.json` skip line is removed (the `.pi/agent/extensions/mxm4-haptic.ts` skip stays), and the two Meridian-referencing comments (the Pi-block rationale and the container-block "Meridian scrub-plugin builds are kept" note) are rewritten.

**Pi routing change**

R5. `dot_pi/agent/readonly_models.json` is deleted.

R6. Pi's managed default in `.chezmoidata/agents.yaml` changes from `defaultProvider: openai-codex` / `defaultModel: gpt-5.6-sol` to provider `zai` / model `glm-5.2`. The `subagents` overrides stay on `gpt-5.6-*`, and the existing `zai` API-key auth entry stays.

**cli-proxy-api text purge**

R7. The "One-time migration from the legacy proxy" section and every Meridian narrative in `README.md` (the apply-flow Meridian paragraph, and the `Library/` and externals structure bullets naming Meridian) are removed, leaving the surrounding README self-consistent.

R8. Both cli-proxy-api CI guards are removed from `.github/workflows/render-dotfiles.yml`: the legacy-literal guard (`cli-proxy-api` / `CLIProxyAPI` / `127.0.0.1:8317`) and the entire provider-prefix guard (`zai` / `zai-coding-plan` / `moonshotai` / `google-agy`).

R9. All Meridian CI content is removed from `.github/workflows/render-dotfiles.yml` across every job: the Linux and macOS "Assert Meridian internals" steps, the "Smoke-build the Meridian pi-scrub external" step, both Windows steps ("Assert POSIX Meridian targets are excluded" and "Assert POSIX Meridian internals are excluded"), the Pi `models.json` exact-match assertions (which would otherwise fail once the source is deleted), the `meridian.service` / plist unit assertions, and the OpenCode/tui "no meridian plugin" jq guards. Non-Meridian assertions in shared steps are preserved.

**Docs reconciliation**

R10. Every Meridian section and paragraph in the repo `AGENTS.md` is removed (the Meridian toolchain-quirks block, the Pi `models.json` override description, the scrub-plugin bullets, and the `00-tools` / `60-build` / `90-services` Meridian references including the container-keep notes), leaving the surrounding non-Meridian content intact and self-consistent.

**Deployment residue**

R11. The existing Meridian `opencode-scrub` entries (and their explanatory comment) are removed from `.chezmoiremove`; no new residue-cleanup entry is added. Deleting the `readonly_models.json`, `meridian.service`, and plist sources auto-removes their deployed targets on the next apply. The `~/.local/share/meridian` tree, `~/.local/bin/meridian` symlink, live user service, and `~/.config/meridian` credentials are left for manual cleanup.

### Acceptance Examples

- AE1. **Covers R6.** **Given** Pi starts with the new managed default, **When** the main session initializes, **Then** it uses provider `zai` / model `glm-5.2` while subagents still use their `gpt-5.6-*` overrides.
- AE2. **Covers R8.** **Given** the provider-prefix guard is removed, **When** `agents.yaml` names `zai` as Pi's default provider, **Then** the render-dotfiles workflow no longer fails on a `zai`-family reference.
- AE3. **Covers R1, R9.** **Given** the Meridian externals and CI assertions are gone, **When** the render-dotfiles workflow runs, **Then** it makes no `[meridian*]` assertion, the rendered-internals matrix passes with no Meridian external, and no job references a deleted Meridian target.

### Scope Boundaries

- **OpenCode configuration** (`dot_config/opencode/**`, its providers, models, and plugins) — untouched. OpenCode never routed through Meridian; the only OpenCode-adjacent edits are removing the CI meridian-absence guards and the `opencode-scrub` residue lines, neither of which is OpenCode config.
- **Pi's Kimi (`kimi-coding`) and Z.ai (`zai`) auth entries** — kept; `zai` is now load-bearing.
- **The Pi `mxm4-haptic` extension and the haptic build scripts** — untouched (not Meridian).
- **Re-adding Claude to Pi via a direct Anthropic API key** — explicitly not done; `glm-5.2` replaces that slot.
- **Runtime Meridian residue** (`~/.local/share/meridian`, `~/.local/bin/meridian`), the live user service, and `~/.config/meridian` credentials — left for manual cleanup. No teardown script, `.chezmoiremove` residue entry, or README migration note is added.

### Dependencies / Assumptions

- Pi resolves a built-in `zai` provider using the existing `op://Private/Z.ai/API Key` (api_key auth) without a `models.json` baseUrl override — the basis for deleting `readonly_models.json`. Verify at apply time (A1).
- `defaultThinkingLevel: max` is honored by `glm-5.2`, or degrades gracefully if not. Verify at apply time (A2).
- Deleting the managed `meridian.service` / plist sources does not stop an already-running, already-enabled service; disabling it is a manual step the maintainer owns (per Scope Boundaries).

### Outstanding Questions

**Deferred to Planning**

- Exact serialization of the Pi default in `agents.yaml` (`defaultProvider: zai` + `defaultModel: glm-5.2`) — settle while editing; the surrounding `defaults` comment is updated to match.

### Sources / Research

- `dot_pi/agent/readonly_models.json` — the sole Meridian consumer (`anthropic` baseUrl → `127.0.0.1:3456`, header `x-meridian-agent: pi`).
- `.chezmoidata/agents.yaml` — `pi.defaults` (current Codex default) and `pi.auth.providers` (`kimi-coding`, `zai`).
- `.github/workflows/render-dotfiles.yml` — Meridian rendered-file assertions and smoke-builds in the Linux/macOS apply and internals jobs and the Windows exclusion job, the legacy-literal guard, and the provider-prefix guard.
- `README.md` — the Meridian apply-flow paragraph and the "One-time migration from the legacy proxy" section.
- `.chezmoiignore` (Pi POSIX block, container block) / `.chezmoiremove` (`opencode-scrub` residue) — Meridian file gating and residue entries.
- `AGENTS.md` — the Meridian toolchain-quirks block, Pi `models.json` override, and scrub-plugin documentation.
- Prior art: [`docs/plans/2026-07-15-001-chore-remove-local-agent-skills-plan.md`](docs/plans/2026-07-15-001-chore-remove-local-agent-skills-plan.md) — the repo's removal-plan shape (source-deletion + reference reconciliation, stub-`op` verification).

---

## Planning Contract

**Product Contract preservation:** changed — R8/R9 CI scope was expanded to the full Meridian surface (including the OpenCode-meridian-absence guards and the whole provider-prefix guard), and R11 residue handling was revised to add no new `.chezmoiremove` entries with runtime residue left for manual cleanup. Both changes were directed by the user during planning ("remove the guard from ci", "remove meridian plugin for opencode", "skipping creating teardown-like things"). All other R-IDs and scope boundaries are unchanged.

### Key Technical Decisions

KTD1. **Source deletion + reference reconciliation, no teardown script.** Deleting the managed sources (`readonly_models.json`, `meridian.service`, the plist) removes their deployed targets on the next apply; deleting the scripts and externals stops provisioning. This follows the repo's documented rule ("delete the source entry; chezmoi removes the deployed target") and its no-teardown-script prohibition. No `run_*` revert script is added.

KTD2. **Pi default via `agents.pi.defaults`, unslashed keys.** The default becomes `defaultProvider: zai` / `defaultModel: glm-5.2` (separate keys, matching the current `openai-codex` / `gpt-5.6-sol` shape), which `run_onchange_after_config-pi.sh.tmpl` merges into the live `settings.json`. Because the keys are unslashed, they never carried the `zai/` literal the removed guard matched. `readonly_models.json` is deleted outright — `zai` is reached through Pi's built-in provider plus the existing `zai` api_key auth (A1).

KTD3. **Whole Meridian CI surface removed; surgical within shared steps.** Meridian-only CI steps ("Assert Meridian internals" on Linux and macOS, "Smoke-build the Meridian pi-scrub external", and both Windows steps — "Assert POSIX Meridian targets are excluded" and "Assert POSIX Meridian internals are excluded") are deleted whole, along with the two cli-proxy-api guards inside the Linux internals step. In the shared Linux/macOS `apply --init` steps, only the Meridian lines are excised — the Pi `models.json` exact-match assertion (which would fail once the source is gone), the `meridian.service`/plist unit assertions, the OpenCode/tui meridian-absence jq guards, and any shell variables that only those lines defined — while every non-Meridian assertion in the same step is preserved. Each edited job must retain valid remaining steps and no orphaned `${...}` variable (A4).

KTD4. **No-teardown residue handling.** The existing Meridian `opencode-scrub` `.chezmoiremove` entries are removed (purging the reference); no new residue entry is added. Runtime residue, the live service, and credentials are the maintainer's manual concern, by explicit direction and consistent with the repo's no-teardown rule. The deployed `~/.pi/agent/models.json` is still auto-removed by source deletion — that is chezmoi's normal managed-target behavior, not teardown machinery.

KTD5. **Verification is render-validity + dangling-reference sweep + CI YAML validity, not unit tests.** This is a config/docs change, so proof is: templates still render under the stub-`op` recipe, zero Meridian/cli-proxy-api references remain in source, and the workflow still parses with no orphaned variables. The archive-diff gate sees only the managed-target deletions (`models.json`, unit, plist); the script/externals/CI changes are verified via `execute-template` and the rendered-internals output, per the AGENTS.md "archive gate sees TARGETS, not SCRIPTS" caveat.

### Removal-surface map

| Surface | Files | Action | Unit |
|---|---|---|---|
| Externals | `.chezmoiexternals/ai-agents.toml` | Delete Meridian region + reconcile comments | U1 |
| Scripts | 4 scripts under `.chezmoiscripts/00-tools`, `60-build` (×2), `90-services` | Delete | U2 |
| Service artifacts | `dot_config/systemd/user/meridian.service`, `Library/LaunchAgents/dev.h82.meridian.plist` | Delete | U2 |
| Pi routing | `.chezmoidata/agents.yaml`, `dot_pi/agent/readonly_models.json` | Edit default / delete | U3 |
| Ignore + remove | `.chezmoiignore`, `.chezmoiremove` | Reconcile / remove entries | U4 |
| CI | `.github/workflows/render-dotfiles.yml` | Remove all Meridian + both cli-proxy-api guards | U5 |
| Docs | `AGENTS.md`, `README.md` | Purge Meridian + cli-proxy-api narrative | U6 |

### Assumptions

- A1. Pi resolves `zai` / `glm-5.2` directly via its built-in `zai` provider and the existing `op://Private/Z.ai/API Key` api_key auth, with no `models.json` baseUrl override. If Pi has no built-in `zai` provider, a minimal `zai` provider definition would be needed instead of deleting `readonly_models.json` — surface as a blocker rather than guessing. Verify at apply.
- A2. `glm-5.2` honors `defaultThinkingLevel: max` (or degrades gracefully). Verify at apply.
- A3. Deleting the managed `readonly_models.json`, `meridian.service`, and plist sources removes their deployed targets on the next apply; deleting scripts/externals stops provisioning but does not stop an already-running service.
- A4. Removing whole CI steps and the interleaved Meridian lines leaves each job with valid remaining steps and no orphaned shell variables; `render-dotfiles.yml` still parses as valid YAML.

### Sequencing

U1-U6 touch disjoint files and are independent — do them in any order and land them as one logical commit (`chore`). Run the Verification Contract after all edits. High-Level Technical Design is omitted: the change is deletion plus reference reconciliation, fully carried by the units and the removal-surface map above.

---

## Implementation Units

### U1. Remove the Meridian externals

- **Goal:** Delete every Meridian fetch and its template scaffolding from the AI-agents externals.
- **Requirements:** R1.
- **Dependencies:** none.
- **Files:** `.chezmoiexternals/ai-agents.toml`.
- **Approach:** Delete the entire Meridian region — the `$meridian*` version-resolution template blocks (GitHub-release → NPM-version cross-check, sha512 decode, the pi-scrub and hermes-scrub commit resolution) and the `[meridian]`, `[meridian.checksum]`, `[meridian-plugin-pi-scrub]`, and `[meridian-plugin-hermes-scrub]` sections. Reconcile the two comment mentions: the file-top header comment listing "meridian, the pi/hermes scrub plugins", and the later comment referencing "the meridian-plugin-hermes-scrub pattern". Leave every non-Meridian external (claude, codex, agy, opencode, pi, codegraph, aoe, agent skills) untouched.
- **Patterns to follow:** the existing per-tool external block structure in the same file.
- **Test scenarios:** `Covers AE3.` Rendered `ai-agents.toml` under the stub-`op` recipe contains zero `[meridian` sections and no `$meridian` template variable; the non-Meridian externals still render; `chezmoi execute-template` exits 0 with no template error.
- **Verification:** V1, V2.

### U2. Delete the Meridian scripts and service artifacts

- **Goal:** Remove all Meridian provisioning, build, and service files.
- **Requirements:** R2, R3.
- **Dependencies:** none.
- **Files (delete):** `.chezmoiscripts/00-tools/run_onchange_after_meridian.sh.tmpl`, `.chezmoiscripts/60-build/run_onchange_after_build-meridian-plugin-pi-scrub.sh.tmpl`, `.chezmoiscripts/60-build/run_onchange_after_build-meridian-plugin-hermes-scrub.sh.tmpl`, `.chezmoiscripts/90-services/run_onchange_after_meridian-service.sh.tmpl`, `dot_config/systemd/user/meridian.service`, `Library/LaunchAgents/dev.h82.meridian.plist`.
- **Approach:** Straight deletion. Confirm no other script references these by name (a shared fingerprint, an `includeTemplate`, or a sibling script); the V2 grep sweep covers this.
- **Test expectation:** none -- pure file deletion; correctness is proven by the V2 dangling-reference sweep and the V3 CI-validity check (the CI no longer asserts these paths after U5).
- **Verification:** V2.

### U3. Switch the Pi default and delete `readonly_models.json`

- **Goal:** Point Pi's managed default at Z.ai `glm-5.2` and remove the Meridian override.
- **Requirements:** R5, R6.
- **Dependencies:** none.
- **Files:** `.chezmoidata/agents.yaml`; `dot_pi/agent/readonly_models.json` (delete).
- **Approach:** In `agents.pi.defaults`, change `defaultProvider: openai-codex` → `zai` and `defaultModel: gpt-5.6-sol` → `glm-5.2`. Leave `defaultThinkingLevel: max` and the whole `subagents` block (all `gpt-5.6-*`) unchanged; leave `pi.auth.providers` (`kimi-coding`, `zai`) unchanged. Update the `defaults` comment if it names the old provider/model. Delete `dot_pi/agent/readonly_models.json` — its only content was the Meridian `anthropic` override.
- **Patterns to follow:** the existing `defaults` key shape (separate `defaultProvider` / `defaultModel`, unslashed).
- **Execution note:** confirm A1 (Pi reaches `zai`/`glm-5.2` directly) before treating the `readonly_models.json` deletion as complete; if Pi needs an explicit `zai` baseUrl, stop and surface it rather than shipping a broken default.
- **Test scenarios:** `Covers AE1.` Rendering `run_onchange_after_config-pi.sh.tmpl` (which merges `agents.pi.defaults` into `settings.json`) shows `defaultProvider: zai` and `defaultModel: glm-5.2`, with the `subagents` overrides still `gpt-5.6-*`; the `zai` auth entry is still present in the rendered `config-pi-auth` merge. No source renders a `~/.pi/agent/models.json`.
- **Verification:** V1, V4.

### U4. Reconcile `.chezmoiignore` and `.chezmoiremove`

- **Goal:** Remove the dead Meridian gating and residue references without adding teardown machinery.
- **Requirements:** R4, R11.
- **Dependencies:** none (independent of U3's source deletion).
- **Files:** `.chezmoiignore`, `.chezmoiremove`.
- **Approach:** In `.chezmoiignore`, remove the Windows-block `.pi/agent/models.json` line (keep `.pi/agent/extensions/mxm4-haptic.ts`) and rewrite its preceding comment so it no longer describes routing Anthropic models through Meridian; rewrite the container-block comment that says "both Meridian scrub-plugin builds are deliberately KEPT" to drop the Meridian mention (there is no Meridian ignore *line* in the container block, only the comment). In `.chezmoiremove`, delete the `opencode-scrub` comment block and its two entries (`.config/meridian/plugins/opencode-scrub.js`, `.local/share/meridian/plugins/opencode-scrub`); add no new entries. Leave the `ce-*` / `lfg` entries and the `.config/opencode/commands` entry byte-unchanged.
- **Patterns to follow:** the repo's "reconcile the comment when you remove the gated file" convention.
- **Test scenarios:** `.chezmoiignore` renders with no `models.json` / `Meridian` reference and still skips the haptic extension on Windows; `.chezmoiremove` has zero `meridian` references and its `ce-*` / `lfg` lines are unchanged; both files render without error.
- **Verification:** V1, V2.

### U5. Purge Meridian and cli-proxy-api from CI

- **Goal:** Remove the entire Meridian CI surface and both cli-proxy-api guards while keeping every job valid.
- **Requirements:** R8, R9.
- **Dependencies:** none (but the models.json/service/plist assertions must go or they fail once U2/U3 land).
- **Files:** `.github/workflows/render-dotfiles.yml`.
- **Approach:** Delete whole Meridian-only steps: "Assert Meridian internals and source hygiene" (Linux — this also contains the legacy-literal guard and the provider-prefix guard, both removed here), "Smoke-build the Meridian pi-scrub external", "Assert Meridian internals (macos)", and both Windows steps ("Assert POSIX Meridian targets are excluded (windows)" and "Assert POSIX Meridian internals are excluded (windows)"). In the shared Linux and macOS `apply --init` steps, remove only the Meridian lines — the Pi `models.json` exact-match `jq` assertion, the `meridian.service` / plist unit assertions, and the OpenCode/tui `all(contains("meridian") | not)` guards — plus any shell variable (`pi_models`, `unit`, `plist`, `service`, `linker`, `pi_scrub_builder`, `hermes_scrub_builder`) that only those removed lines defined. Preserve every non-Meridian assertion in the shared steps. After editing, confirm each job still has at least one valid step and no dangling `${...}` reference.
- **Execution note:** work job-by-job; after each edit, re-scan that job for orphaned variables and empty steps before moving on. This is the delicate unit — surgical line removal inside shared steps, whole-step deletion for Meridian-only steps.
- **Test scenarios:** `Covers AE2, AE3.` `rg -i 'meridian' .github/workflows/render-dotfiles.yml` returns zero hits; `rg -n 'cli-proxy|CLIProxy|127\.0\.0\.1:8317|zai|zai-coding-plan|moonshotai|google-agy' .github/workflows/render-dotfiles.yml` returns zero hits; the file parses as valid YAML; no step references a `${...}` variable that is no longer defined.
- **Verification:** V2, V3.

### U6. Purge Meridian and cli-proxy-api from the docs

- **Goal:** Bring `AGENTS.md` and `README.md` to zero Meridian / cli-proxy-api references with no drift.
- **Requirements:** R7, R10.
- **Dependencies:** none.
- **Files:** `AGENTS.md`, `README.md`.
- **Approach:** In `AGENTS.md`, remove the Meridian toolchain-quirks block (the "**Meridian** is the POSIX user-scoped Claude Max proxy…" paragraphs, the "Prompt scrubbers:" paragraph, and the unmanaged-`~/.config/meridian` paragraph), the Pi "**Anthropic through Meridian**" `models.json` override paragraph, and every Meridian mention in the `.chezmoiexternals` grouping description, the `00-tools` / `60-build` / `90-services` script-tree rows, and the container-section keep-notes — rewriting the surrounding text so each list/table stays self-consistent. In `README.md`, remove the "### One-time migration from the legacy proxy" section, the Meridian apply-flow paragraph, and the `Library/` and `.chezmoiexternals/` structure bullets' Meridian mentions. Do not touch unrelated content.
- **Patterns to follow:** the sibling removal plan's doc-reconciliation approach (remove the reference, keep the surrounding structure valid).
- **Test scenarios:** `rg -i 'meridian|cli-proxy|CLIProxy' AGENTS.md README.md` returns zero hits; each edited list/table/section still reads coherently (no dangling "and Meridian" fragments, no orphaned bullet).
- **Verification:** V2.

---

## Verification Contract

This is a documentation/config change — proof is render validity, workflow validity, and zero dangling references, not unit tests. All render checks use the stub-`op` + throwaway-destination recipe documented in `AGENTS.md` ("The stub-`op` + throwaway-destination recipe"), so no real 1Password auth or live `$HOME` is touched. Inject the GitHub token as the recipe notes (`GITHUB_TOKEN="$(gh auth token)"`) so the externals render.

- V1. **Render the edited templates.** Under the stub-`op` recipe, `chezmoi execute-template` on `.chezmoiexternals/ai-agents.toml`, `.chezmoiignore`, and the Pi config scripts. Expect: exit 0, no template error, and no `[meridian` / `$meridian` / `models.json` output in the rendered externals and ignore set.
- V2. **Dangling-reference sweep.** `rg -i 'meridian' --glob '!docs/plans/**'` over the source tree returns zero hits. `rg -n 'cli-proxy|CLIProxy|127\.0\.0\.1:8317' --glob '!docs/plans/**'` returns zero hits. `rg -n '(zai|zai-coding-plan|moonshotai|google-agy)/' .chezmoidata/agents.yaml .github/workflows/render-dotfiles.yml` returns zero hits. (Historical `docs/plans/` hits are allowed.)
- V3. **CI workflow validity.** `.github/workflows/render-dotfiles.yml` parses as valid YAML (a YAML load, or `actionlint` if available); grep each removed shell variable name (`pi_models`, `unit`, `plist`, `service`, `linker`, `pi_scrub_builder`, `hermes_scrub_builder`) and confirm no surviving `${var}` use lacks a definition; every job still has at least one step.
- V4. **Pi default renders.** Under the stub-`op` recipe, render `run_onchange_after_config-pi.sh.tmpl`; expect the merged defaults to carry `defaultProvider: zai` / `defaultModel: glm-5.2` with `subagents` still on `gpt-5.6-*`, and `run_onchange_after_config-pi-auth.sh.tmpl` to still carry the `zai` api_key provider.
- V5. **Archive + rendered-internals diff (thorough).** Archive base vs branch per the `AGENTS.md` recipe (`--exclude=encrypted,externals,scripts`); confirm the only target-state changes are the deleted `~/.pi/agent/models.json`, `~/.config/systemd/user/meridian.service`, and `~/Library/LaunchAgents/dev.h82.meridian.plist`, plus the `.chezmoiignore` edit. Because the archive gate does not see scripts/externals, additionally diff the rendered script/externals text (per-side `execute-template`, or the CI `rendered-internals-<os>` artifacts) to confirm the script and externals deletions.
- V6. **Real apply (host-dependent, end-to-end).** On a real host, `chezmoi apply`, then confirm Pi's main session uses `zai`/`glm-5.2` (A1) and honors `max` (A2), the `meridian.service` unit and `~/.pi/agent/models.json` are gone, and the render is clean. Flag explicitly if not run in this environment. Disabling the live service and clearing `~/.config/meridian` / `~/.local/share/meridian` are the maintainer's manual steps, out of this plan's automated scope.

---

## Definition of Done

- The Meridian region and both scrub-plugin sections are gone from `.chezmoiexternals/ai-agents.toml`; the four Meridian scripts, the systemd unit, and the macOS plist are deleted (R1-R3).
- Pi's managed default is `zai` / `glm-5.2` with subagents unchanged; `dot_pi/agent/readonly_models.json` is deleted; the `zai` and `kimi-coding` auth entries are intact (R5, R6, AE1).
- `.chezmoiignore` no longer gates a Meridian file and its comments are reconciled; `.chezmoiremove` has no Meridian entry and its `ce-*` / `lfg` lines are byte-unchanged; no new residue entry was added (R4, R11).
- `render-dotfiles.yml` contains zero Meridian and zero cli-proxy-api references (both guards gone), parses as valid YAML, and has no orphaned shell variable; every job retains valid steps (R8, R9, AE2, AE3, V3).
- `AGENTS.md` and `README.md` contain zero Meridian / cli-proxy-api references and read coherently (R7, R10).
- V2 dangling-reference sweep returns only historical `docs/plans/` hits; V1/V4 renders exit 0.
- No abandoned or experimental edits remain in the diff.
- Lands as one logical commit in the repo's Conventional Commits style (`chore(agents):` or similar), per one-change-one-commit.
