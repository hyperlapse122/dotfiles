---
title: omp and OpenCode Harness Consolidation - Plan
type: refactor
date: 2026-11-27
topic: omp-opencode-harness-consolidation
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# omp and OpenCode Harness Consolidation - Plan

## Goal Capsule

- **Objective:** The repository manages two third-party coding harnesses, omp and OpenCode, at the same integration level, and nothing it manages still depends on Pi, native agent guards, or repository-pinned Synthetic and Anthropic model lists.
- **Means:** Retire Pi, the native guards, and the model-list pipelines under the repository's tool-retirement rules, and give omp the Compound Engineering plugin and shared skill root that OpenCode already has (KTD1, KTD2).
- **Product authority:** The repository owner. Claude Code stays managed and is out of scope except where the guard retirement (R8, R9) touches it. Product Contract meaning wins over planning detail; KTDs win on mechanism.
- **Execution profile:** One pull request, units landed in the order below. No host switch, `darwin-rebuild switch`, or `nixos-rebuild switch` is part of this work.
- **Stop conditions:** Stop and report if the omp CLI cannot register a local marketplace or install from it non-interactively (R5), or if OpenCode's built-in catalog stops listing Synthetic models with a key present (R10).
- **Who finishes:** `ce-work` implements and verifies with repository checks; the owner applies the generation on each host afterwards.
- **Open blockers:** None.

---

## Product Contract

Product Contract preservation: restructured, no scope change. Outstanding Questions answered by planning research were resolved in place; R2 was clarified to distinguish user-installed Pi extensions from repository-linked files. R-IDs unchanged.

### Summary

Retire Pi and keep omp and OpenCode as the two managed third-party harnesses.
omp receives the pinned Compound Engineering plugin and a declared shared skill root, matching OpenCode.
The `preShell` and `freezeTests` guards are retired from every harness, and the repository stops pinning Synthetic and Anthropic model lists so each harness uses its own provider catalog.

### Problem Frame

The repository maintains Pi, OpenCode, and omp side by side, each with its own package pin, release script, settings module, credential sync, and checks.
Pi carries the most repository-owned code: custom `question`, `web_search`, and `web_fetch` extensions, a managed `pi-subagents` package, and a model lock.
omp ships equivalent built-in tools (`ask`, `web_search`, `task`), so that code duplicates what omp already provides.
omp was added with installation, settings, credentials, and instruction delivery only; its plan explicitly deferred skills and plugins, so it is the least integrated harness even though the owner intends to keep it.
Model curation adds further upkeep: a Synthetic lock, a hidden-model list, a committed catalog, and an Anthropic list are refreshed by scheduled watch scripts and declared into Pi and OpenCode.

### Key Decisions

- **Keep omp and OpenCode; retire Pi.** (session-settled: user-directed — chosen over keeping a single harness (omp only, OpenCode only, or Pi with plugins): omp covers Pi's extensions natively, and OpenCode is the only non-Claude Compound Engineering review peer.) Governs R1–R4.
- **omp reaches parity with OpenCode by gaining the CE plugin and a shared skill root.** (session-settled: user-directed — chosen over leaving omp at install-and-settings integration.) Governs R5–R7.
- **Guard parity is reached by removal, across every harness.** (session-settled: user-directed — chosen over removing the guards from OpenCode only while keeping them in Claude Code.) Governs R8–R9.
- **Harnesses manage Synthetic and Anthropic models themselves.** (session-settled: user-directed — chosen over keeping the Synthetic lock and Anthropic list as OpenCode-owned data.) Governs R10–R12.
- **Pi-only model settings are not ported to omp.** Pi's `enabledModels` selection and its local Ollama model setup end with Pi; omp keeps its own model roles. Governs R4.

### Requirements

**Pi retirement**

- R1. Pi is removed from repository management on both host kinds: its package and release pins, Home Manager module, wrapper and state scripts, extensions, `pi-subagents` package, instruction adapter, skill root, and checks.
- R2. Retirement follows the Tool retirement rules in `docs/contributing.md`: existing Pi settings, credentials, user-installed extensions, and session data stay on disk, and fresh homes no longer acquire Pi or its configuration. Files the repository linked into `~/.pi` are removed by Home Manager's link cleanup.
- R3. Shared assets Pi consumed (CE release pins, shared skills, instructions, provider keys) stay while omp, OpenCode, or Claude Code still consumes them.
- R4. Pi's user-facing tools have an omp counterpart with no new repository code: questions use omp `ask`, web search uses omp `web_search`, and subagents use omp `task`.

**omp parity with OpenCode**

- R5. omp has the Compound Engineering plugin installed at the same pinned release that OpenCode uses.
- R6. The shared skills linked into every managed skill root are also linked into a declared omp skill root.
- R7. Repository checks cover omp's plugin and skill delivery to the same extent they cover OpenCode's.

**Native guard retirement**

- R8. The `preShell` and `freezeTests` guards and the `my.agentHooks` options are retired for every harness, including Claude Code, together with their shared quality-hook implementation and checks.
- R9. Activation removes previously written guard entries from managed settings files without disturbing unrelated user settings.

**Model list retirement**

- R10. The repository no longer pins Synthetic models: the model lock, hidden-model list, committed Synthetic catalog, and `synthetic-models-watch` are retired.
- R11. The repository no longer pins Anthropic models: `anthropic-models.json` and `provider-models-watch` are retired.
- R12. OpenCode and omp keep receiving their Synthetic and Anthropic API keys through the existing credential pipelines; only the repository-declared model rows go away.

**Documentation**

- R13. Repository documentation describes the two-harness setup and no longer documents Pi, the native guards, or the retired model lists as active.

### Acceptance Examples

- AE1. **Covers R2.** Given a host that already has `~/.pi/agent/` with sessions and settings, when the new configuration is applied, then those files remain and `pi` is no longer on the managed PATH.
- AE2. **Covers R5, R6.** Given a fresh home, when the configuration is applied and omp starts in a non-project directory, then the CE skills and the shared lens skills appear in omp's skill list.
- AE3. **Covers R8, R9.** Given a repository containing `.agents/freeze-tests`, when an agent in any managed harness edits a test file, then no repository-managed hook blocks the edit, and the Claude Code settings no longer carry the guard hook entry.
- AE4. **Covers R10, R12.** Given the new configuration, when OpenCode lists Synthetic models, then the list comes from OpenCode's own provider catalog and requests authenticate with the managed Synthetic key.

### Scope Boundaries

- Claude Code's other settings, plugins, and instructions are unchanged.
- The OpenCode Go catalog and `opencode-go-models-watch` stay, as do the OpenRouter, OpenCode Go, and Exa key pipelines.
- omp does not become a CE cross-model review peer; CE has no omp route, so OpenCode remains the only non-Claude peer.
- No cleanup that deletes existing Pi state, guard files, pulled Ollama models, or model caches on hosts.
- No replacement guard mechanism for any harness.
- Not built: a watch over the dated Synthetic model ids `home/h82/agents/omp.nix` names in `modelRoles`. Dropping the Synthetic watch job removes the only drift warning; the owner chose native model management (settled decision 4). Add a narrow watch only if a pinned omp role id disappears in practice.
- Not built: an `omp` setting that disables marketplace auto-update. omp's default `marketplace.autoUpdate` is `notify`, which only logs, so the pin already owns the installed version.

#### Deferred to Follow-Up Work

- Prune the one-shot cleanups this change adds (Claude `hookGroups` with empty events, OpenCode empty `providers.synthetic.models` and `providers.anthropic.models` declarations) after every host has applied the generation and the owner confirms, following the precedent of `cce4981` and `5ba2e30`.
- Owner-side cleanup outside the repository: the GitHub Actions secrets `SYNTHETIC_API_KEY` and `ANTHROPIC_API_KEY`, and the `model-reconcile` issue label with any open reconcile issue.

### Dependencies / Assumptions

- omp `v19.2.1` lists `ask`, `web_search`, and `task` as built-in tools (`omp --help`), which R4 relies on.
- The pinned CE source (`compound-engineering-v3.38.3`) ships `.omp-plugin/marketplace.json` (marketplace `compound-engineering-plugin`, plugin `compound-engineering`), and omp accepts a local directory as a marketplace source (omp `docs/marketplace.md`).
- omp discovers user skills natively from `~/.omp/agent/skills`; foreign roots such as `~/.claude/skills` and `~/.config/opencode/skills` are opt-in through `enabledProviders`, so one declared omp root yields each skill once (omp `docs/skills.md`, `packages/coding-agent/src/discovery/builtin.ts`).
- OpenCode `2.4.2` lists 8 Synthetic and 18 Anthropic models from its built-in catalog in a scratch home with only fake `SYNTHETIC_API_KEY` and `ANTHROPIC_API_KEY` set, including the Synthetic ids omp's `modelRoles` name. Checked on 2026-11-27.
- OpenCode currently reads `pi-model-lock.json` and `pi-hidden-models.nix` (`home/h82/agents/opencode.nix:23-24`), so R10 changes OpenCode's model list, not only Pi's.

### Assumptions

- Pipeline run: the plan-time scoping confirmation was skipped. These bets were made without the owner:
  - The repository-provisioned local Ollama `pi-*` model is retired with Pi (KTD5), since only Pi used it. The Ollama server stays for omp.
  - omp gets its own version-keyed CE plugin directory beside Claude Code's under `~/.local/share/agent-plugins/` (KTD1).
  - Pi's previously installed CE plugin and its `~/.pi/agent/settings.json` stay as state; a hand-run Pi warns about the removed extension paths, which is acceptable under the retirement rules.

### Sources / Research

- `docs/contributing.md` — Tool retirement rules, Testing guidelines, and the harness and skill-root lists that change.
- `docs/agent-routing.md` — current Pi tools, model lists, guards, and CE review peers.
- `scripts/agent-settings` — `merge()` reconciles only declared paths; `ownEntries`, `removePaths`, `removeEntries`, and `hookGroups` are its retirement mechanisms.
- `scripts/agent-plugin-sync` — the harness-adapter pattern; the removed Codex adapter (`git show 955d5b7^:scripts/agent-plugin-sync`) is the template for a second adapter.
- Retirement precedents: `955d5b7` (Codex harness), `4a01a17` (Codex package and updater), `7f213b7` (OpenAI model list), `20e16a9` (hook removal by empty events), `25e5842` (T3 Code).
- `.compound-engineering/artifacts/plans/2026-11-24-2117-feat-omp-managed-cli-harness-plan.md` — omp integration scope that deferred skills and plugins.
- `.compound-engineering/artifacts/solutions/best-practices/order-home-manager-link-cleanup-after-link-generation.md` — Home Manager removes undeclared links on the next switch.
- `.compound-engineering/artifacts/solutions/best-practices/home-manager-activation-does-not-run-on-every-rebuild.md` — activation-only cleanup runs only on a real switch.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **omp gets CE through a new `omp` adapter in `scripts/agent-plugin-sync` and a membership row in `home/h82/agents/agent-plugins.nix`.** This reuses the pinned flake input, the version-keyed link, readback, and rollback that Claude Code already uses, which an OpenCode-style `omp plugin link` activation would not have. The adapter reads `.omp-plugin/marketplace.json` and drives `omp plugin marketplace add`, `install --scope user`, `upgrade`, `enable`, and the `--json` listings. The omp row gets its own version-keyed base (for example `~/.local/share/agent-plugins/compound-engineering-omp`), because `prune()` deletes every sibling segment in a base and a shared base would let one harness's prune delete the other's rollback target. Claude's existing base is unchanged. Governs R5, R7.
- KTD2. **The omp skill root is `.omp/agent/skills`, added to the `roots` list in `home/h82/agents/skills.nix`.** It is omp's native user root, and Home Manager directory links are accepted there. Adding it also extends the macOS Xcode skill export, which reads `my.agentSkillRoots`. Governs R6.
- KTD3. **The Claude guard hook is removed by declaring the quality hook group with every event empty, not by dropping the declaration.** `agent-settings` reconciles hooks only when `hookGroups` is declared, so dropping it would leave a `PreToolUse` handler pointing at a store path that will be garbage-collected. This follows `20e16a9`; the `hookGroups` support in `scripts/agent-settings` stays while the one-shot lives. Governs R8, R9.
- KTD4. **OpenCode's Synthetic and Anthropic model rows are removed by keeping `providers.synthetic.models` and `providers.anthropic.models` declared as ledger-owned sets with no entries.** Dropping the rows would leave every previously written row, including the `disabled = true` rows that hide catalog models, in `opencode.json`. `agent-settings` is changed so an empty owned set never creates a missing path, so fresh homes get no empty provider stubs. Governs R10, R11, R12.
- KTD5. **The local Ollama model provisioning retires with Pi.** `packages/ollama-model.nix` names only the `pi-*` model, and omp uses other Ollama models the repository does not provision. The Ollama server, its package, and its release pin stay; pulled models stay on disk. Governs R1, R2.
- KTD6. **Pi absence is checked by extending `tests/agent-unmanaged`** with the Pi binaries and `.pi` home files, following the Antigravity precedent. The unregistered `tests/agent-retirement.py` is deleted because its assertions are stale. Governs R1, R2.
- KTD7. **T3's one-shot cleanup keeps working by inlining the five hidden Synthetic ids** that `home/h82/t3-retirement.nix` imports from `pi-hidden-models.nix`, so it still removes exactly what T3 wrote. Governs R10.
- KTD8. **The scheduled update workflow keeps only the OpenCode Go catalog and harness pin updates.** The Synthetic and Anthropic steps, the Synthetic-only `watch` job, the `drift` dispatch option, and the `pi-release` steps go; `tests/update-workflow.py` and `tests/update-dependencies-reconcile.sh` move their fixtures to the OpenCode Go catalog and another harness pin so their failure-mode coverage survives. Governs R1, R10, R11.

### High-Level Technical Design

How each retired surface is cleaned up on a host that applied an earlier generation:

| Surface | Mechanism | Who removes it |
| --- | --- | --- |
| Pi package, `pi` on PATH | dropped from `home.packages` | Home Manager on switch |
| `~/.pi/agent/{models.json, dotfiles-*.ts, pi-subagents}`, `.pi/agent/skills/*` links | undeclared `home.file` | Home Manager link cleanup |
| `~/.pi/agent/settings.json`, auth, sessions, `AGENTS.md` copy | not managed | stays as user state (R2) |
| Claude `PreToolUse` guard handler in `~/.claude/settings.json` | `hookGroups` with empty events (KTD3) | `agent-settings` at activation |
| `~/.config/opencode/plugins/dotfiles-agent-quality.ts` | undeclared `xdg.configFile` | Home Manager link cleanup |
| OpenCode Synthetic and Anthropic model rows | empty owned sets (KTD4) | `agent-settings` at activation |
| Ollama `pi-*` provisioning job | unit or launchd agent no longer declared | Home Manager or NixOS on switch; model data stays |

### Implementation Constraints

- Follow `docs/contributing.md` Tool retirement: no deletion manifests, no data-wiping uninstall, no cleanup of user state.
- Exercise activation blocks in a scratch `HOME` and read materialized `home-files`; register new or moved checks in a shard (`check-shards-guard`) and any check reading Home Manager closures under `hostClosureChecks` in `tests/linux-checks.nix`.
- Probe omp and OpenCode only with a scratch `HOME` and fake keys, and stop any server process the probe starts. Never touch the owner's real `~/.omp`, `~/.pi`, or OpenCode state.
- Repository documentation stays in English.

---

## Implementation Units

### U1. Retire the Pi harness

**Goal:** Remove Pi and everything that exists only for Pi from the repository, leaving host state untouched.

**Requirements:** R1, R2, R3, R4; KTD6, KTD7.

**Dependencies:** None.

**Files:**

- Delete: `packages/pi.nix`, `packages/pi-runtime.nix`, `packages/pi-release.json`, `packages/harness-source.nix`, `packages/pi-subagents.nix`, `packages/pi-subagents-release.json`, `packages/pi-subagents/`, `scripts/pi`, `scripts/pi-state`, `scripts/pi-release`, `home/h82/agents/pi.nix`, `home/h82/agents/pi-web.ts`, `home/h82/agents/pi-question.ts`, `tests/pi.nix`, `tests/pi-activation.py`, `tests/pi-ollama.py`, `tests/pi-runtime.py`, `tests/pi-settings.py`, `tests/pi-state.py`, `tests/pi-subagents.py`, `tests/pi-subagents-provider.mjs`, `tests/pi-tools.mjs`, `tests/pi-trust.mjs`, `tests/pi-wrapper.py`, `tests/test_pi_release.py`, `tests/agent-retirement.py`
- Modify: `home/h82/agents/default.nix`, `packages/default.nix`, `packages/agent-tools.nix`, `scripts/agent-instructions`, `home/h82/t3-retirement.nix`, `home/h82/agents/decide-server.nix`, `modules/nixos/system/secrets.nix` (consumer descriptions)
- Test: `tests/agent-unmanaged.nix`, `tests/agent-unmanaged.py`, `tests/agent-instructions.nix`, `tests/agent-instructions.py`, `tests/linux-checks.nix`, `tests/darwin-outputs.nix`, `tests/python-script-checks.nix`

**Approach:**

1. Delete the Pi files listed above; keep `packages/npm-release-package.nix`, which `packages/acpx.nix` uses.
2. Drop Pi from the module imports, package set, and `agent-tools` helpers.
3. Drop the `pi` delivery from `scripts/agent-instructions` and move `.pi/agent/AGENTS.md` into the retired-paths list of `tests/agent-instructions.nix`.
4. Inline the five hidden Synthetic ids into `home/h82/t3-retirement.nix` (KTD7) before `pi-hidden-models.nix` is deleted in U4.
5. Drop `timeout = 1800` from `home/h82/agents/decide-server.nix` if Pi was its only reader; keep it if Claude's entry uses it.
6. Remove Pi from check registrations, and extend `tests/agent-unmanaged` with `pi`, `pi-acp`, `pi-acp-readonly`, and `.pi` (KTD6).

**Patterns to follow:** `955d5b7` (Codex harness retirement) and `tests/agent-unmanaged.py` (Antigravity absence).

**Test scenarios:**

- Covers AE1. On both host kinds, the Home Manager path contains no `pi`, `pi-acp`, or `pi-acp-readonly` binary, and `home-files` contains no `.pi/` target.
- `agent-instructions` activation in a scratch `HOME` that already holds `.pi/agent/AGENTS.md` leaves that file unchanged and still writes the Claude, OpenCode, and omp files.
- T3's one-shot still removes exactly the five hidden Synthetic ids it wrote, with the existing `tests/test_retire_t3.py` cases passing unchanged.

**Verification:** No flake output, check, or Home Manager generation references Pi, and the absence check fails if a Pi binary or `.pi` file is reintroduced.

### U2. Retire the local Ollama model provisioning

**Goal:** Stop provisioning the Pi-only `pi-*` Ollama model on both hosts while keeping the Ollama server.

**Requirements:** R1, R2; KTD5.

**Dependencies:** U1.

**Files:**

- Delete: `packages/ollama-model.nix`, `packages/ollama-provision.nix`, `scripts/ollama-provision.sh`, `tests/ollama-provision.sh`, and the provisioning-only checks among `tests/ollama-user-service.nix` and `tests/ollama-boot.nix`
- Modify: `modules/nixos/services/ollama.nix`, `home/h82/dev/ollama-darwin.nix`
- Test: `tests/darwin-outputs.nix`, `tests/linux-checks.nix`, `tests/vm-checks.nix`

**Approach:**

1. Remove the provisioning unit from `modules/nixos/services/ollama.nix` and the provisioning launchd agent from `home/h82/dev/ollama-darwin.nix`; keep the server unit, darwin app bootstrap, `packages/ollama.nix`, and its release pin.
2. Keep any part of `tests/ollama-user-service.nix` or `tests/ollama-boot.nix` that checks the server itself; delete only what checks provisioning.
3. Update check registrations, including the VM registry if a VM test changes.

**Test scenarios:**

- On NixOS, the Ollama server user unit is still declared and no provisioning unit exists.
- On macOS, the Ollama launchd setup still starts the server and declares no provisioning agent.

**Verification:** No output references `ollama-model` or `ollama-provision`, and the server checks still pass.

### U3. Retire the native guards from every harness

**Goal:** Remove `preShell` and `freezeTests` from Claude Code, OpenCode, and Pi remnants, and clean up the Claude hook already written on hosts.

**Requirements:** R8, R9; KTD3.

**Dependencies:** U1.

**Files:**

- Delete: `home/h82/agents/agent-hooks.nix`, `home/h82/agents/quality-hooks.nix`, `home/h82/agents/opencode-quality.ts`, `home/h82/agents/pi-quality.ts`, `packages/agent-quality-hook.nix`, `scripts/agent-quality-hook`, `tests/lib/quality-hook-renderer.nix`, `tests/agent-hook-lifecycle.py`, `tests/agent-hooks.nix`, `tests/agent-hooks.py`
- Modify: `home/h82/agents/default.nix`, `home/h82/agents/claude.nix`, `home/h82/agents/opencode.nix`
- Test: `tests/claude.nix`, `tests/test_agent_settings.py`, `tests/shared-checks.nix`, `tests/auth-provisioning.nix`

**Approach:**

1. In `claude.nix`, replace the imported `hookGroups` with an inline declaration carrying the existing identity (`statusMessage`, `commandPrefix`, `commandSuffix` from `quality-hooks.nix`) and `PreToolUse`, `PostToolUse`, and `Stop` set to empty (KTD3).
2. In `opencode.nix`, drop the quality import and the `opencode/plugins/dotfiles-agent-quality.ts` config file.
3. Move the "empty events remove managed handlers and keep custom ones" coverage from `tests/agent-hooks.py` into `tests/claude.nix` or `tests/test_agent_settings.py` before deleting the old checks.
4. Replace the VM subtest in `tests/auth-provisioning.nix` that ran the OpenCode quality hook with a plain OpenCode command through `/run/current-system/sw/bin/opencode`, so the nix-ld coverage it gave survives.

**Patterns to follow:** `20e16a9` (retire edit and turn-end feedback).

**Test scenarios:**

- Covers AE3. Running `claudeSettings` activation in a scratch `HOME` whose `settings.json` holds the managed `PreToolUse` guard handler and a custom `PreToolUse` handler leaves only the custom handler.
- The same activation over a `settings.json` with no hooks adds no `hooks` key.
- `home-files` contains no `opencode/plugins/dotfiles-agent-quality.ts`.
- The VM test still runs OpenCode through the nix-ld loader.

**Verification:** No module declares `my.agentHooks`, no package builds `agent-quality-hook`, and the Claude cleanup is proven by an executed activation.

### U4. Stop pinning Synthetic and Anthropic models

**Goal:** Remove the repository's Synthetic and Anthropic model lists and let OpenCode and omp use their native catalogs, removing previously written rows on hosts.

**Requirements:** R10, R11, R12; KTD4, KTD7.

**Dependencies:** U1 (Pi no longer reads the lock).

**Files:**

- Delete: `home/h82/agents/pi-model-lock.json`, `home/h82/agents/pi-hidden-models.nix`, `home/h82/agents/synthetic-catalog.json`, `home/h82/agents/synthetic-models.nix`, `home/h82/agents/anthropic-models.json`, `scripts/synthetic-models-watch`, `scripts/provider-models-watch`, `tests/synthetic-models.nix`, `tests/synthetic-models-reconcile.sh`, `tests/fixtures/synthetic-models/`, `tests/test_synthetic_models_watch.py`, `tests/test_provider_models_watch.py`
- Modify: `home/h82/agents/opencode.nix`, `scripts/agent-settings`, `packages/agent-tools.nix`, `packages/default.nix`, `scripts/catalog_snapshot.py` (docstring)
- Test: `tests/opencode.nix`, `tests/test_agent_settings.py`, `tests/linux-checks.nix`, `tests/python-script-checks.nix`, `tests/workflow-checks.nix`

**Approach:**

1. In `opencode.nix`, remove the lock, hidden list, catalog, and Anthropic list inputs and keep `providers.synthetic.models` and `providers.anthropic.models` as owned sets with no entries (KTD4). Keep the OpenCode Go set, plugin pin, and `opencodeAuth` keys unchanged.
2. In `scripts/agent-settings`, make an owned set with no entries a no-op when its path does not exist, while it still removes stale owned rows when the path exists.
3. Drop the two watch helpers from the package set and their checks; keep `scripts/catalog_snapshot.py`, which `opencode-go-models-watch` uses.

**Execution note:** Add the `agent-settings` empty-set case test-first; it is the only behavior change in shared merge code.

**Test scenarios:**

- Covers AE4. `opencodeSettings` activation over a seed holding ledger-owned Synthetic and Anthropic rows (including `disabled = true` rows) and a user-added `my-own-model` removes the owned rows and keeps `my-own-model`.
- The same activation in an empty scratch `HOME` writes no `providers.synthetic` or `providers.anthropic` path.
- `agent-settings` unit case: an owned set with no entries over a missing path leaves the document unchanged.
- `agent-settings` unit case: an owned set with no entries over an existing path with ledger-owned and unowned entries removes only the owned ones.
- The OpenCode Go rows and the CE plugin entry are unchanged in the merged output.

**Verification:** No file in the repository declares a Synthetic or Anthropic model row, and executed activations prove both host cleanup and fresh-home cleanliness.

### U5. Trim the scheduled update workflow and CI verify scope

**Goal:** Keep the scheduled workflow working with only the OpenCode Go catalog and the remaining harness pins.

**Requirements:** R1, R10, R11; KTD8.

**Dependencies:** U1, U4.

**Files:**

- Modify: `.github/workflows/update-dependencies.yml`, `scripts/ci-update-verify`
- Test: `tests/update-workflow.py`, `tests/update-dependencies-reconcile.sh`, `tests/workflow-checks.nix`

**Approach:**

1. Remove the Synthetic and Anthropic refresh steps, the `watch` job, the `drift` dispatch option and its gate, the `pi-release` update and commit steps, and the matching report lines; reduce the catalog publish condition to the OpenCode Go step. Rename the workflow if its name still mentions model catalogs in the plural sense it no longer has.
2. In `scripts/ci-update-verify`, keep `opencode-go-models-watch` in the catalogs scope and add `opencode`, which reads the Go snapshot; drop `pi`, `synthetic-models`, and `provider-models-watch`.
3. Move `tests/update-workflow.py` fixtures from `synthetic-catalog.json` to `opencode-go-catalog.json`, drop the Synthetic, Anthropic, and drift cases, and update the expected job count and verify targets.
4. Repoint the `pi-release` fixture in `tests/update-dependencies-reconcile.sh` to another harness pin so the partial-pin and failed-updater cases keep coverage.

**Test scenarios:**

- The workflow check accepts the trimmed workflow and fails if a Synthetic, Anthropic, or Pi step is reintroduced.
- The catalog publish step still runs when only the OpenCode Go snapshot changes.
- The reconcile script's partial-pin and failed-updater mutations still turn their checks red against the new harness pin.

**Verification:** `UPDATE_CHECK_NAMES` and the workflow check pass, and every registered verify target exists as a flake check.

### U6. Install the CE plugin into omp

**Goal:** omp installs the pinned Compound Engineering plugin through the same sync helper Claude Code uses.

**Requirements:** R5, R7; KTD1.

**Dependencies:** None.

**Files:**

- Modify: `scripts/agent-plugin-sync`, `home/h82/agents/agent-plugins.nix`
- Test: `tests/test_agent_plugin_sync.py`, `tests/agent-plugins.nix`

**Approach:**

1. Add an `omp` adapter modeled on the removed Codex adapter: marketplace manifest `.omp-plugin/marketplace.json`, plugin manifest `.claude-plugin/plugin.json` (the pinned tree has no `.omp-plugin/plugin.json`; omp's install version resolution reads the Claude one), user scope, and the omp `--json` listing shapes for marketplaces and installed plugins.
2. Confirm the listing shapes and whether a marketplace added from a read-only store path reinstalls cleanly by running the pinned omp binary in a scratch `HOME`; record what the adapter relies on in its comments.
3. Add `{ name = "compound-engineering"; harness = "omp"; }` to `membership` and `harnesses.omp` with the `programs.omp.package` binary, and give the omp row its own base (KTD1). Adjust the shared-base retire guard in `agent-plugins.nix` so it keys on the base a row actually uses.

**Execution note:** Probe the real omp CLI in a scratch `HOME` before writing the fake-CLI tests, so the fakes mirror real output.

**Test scenarios:**

- Covers AE2. Against a fake `omp` CLI, sync registers the versioned marketplace link, installs `compound-engineering@compound-engineering-plugin` at user scope, and enables it.
- A second sync with the same segment makes no changes.
- A new segment re-registers the marketplace at the new link and prunes the old version after readback succeeds.
- A failed install restores the previous marketplace registration and exits non-zero.
- `--dry-run` prints planned actions and runs no mutating omp command.
- The omp adapter's manifest check passes against the real pinned CE source tree, not only a fake tree.
- After a version bump where the Claude row has already pruned its own old segment, a failed omp install restores omp's previous registration, whose link still exists in omp's base.
- `tests/agent-plugins.nix` checks that the omp row's `--cli` is the installed omp binary and its `--source` is the pinned flake input.

**Verification:** Both host configurations run the omp sync from `agentPlugins` activation, and the sync helper's test suite covers the omp adapter's order, rollback, and readback.

### U7. Link shared skills into omp

**Goal:** omp sees every shared skill once through its native user root.

**Requirements:** R6, R7; KTD2.

**Dependencies:** U1 (the Pi root leaves the list in the same edit).

**Files:**

- Modify: `home/h82/agents/skills.nix`
- Test: `tests/official-skills.nix`, `tests/korean-skills.nix`, `tests/pinned-skills.nix`, `tests/test-audit-skill.nix`, `tests/darwin-config.nix`, `tests/darwin-outputs.nix`, `tests/omp.nix`

**Approach:**

1. Set `roots` to `.claude/skills`, `.config/opencode/skills`, and `.omp/agent/skills`.
2. Update every literal root list in the skill checks and the macOS Xcode export arguments, and their "three harness roots" headers.
3. Check that every generated or pinned skill has a `description`, since omp's native root requires one.

**Test scenarios:**

- Covers AE2. `home-files` contains each shared skill under `.omp/agent/skills/<name>` and under no `.pi/` path.
- The Korean skill check still forbids `.agents/skills` and `.codex/skills`.
- The macOS Xcode export installs into the three current roots.

**Verification:** Every skill delivery check lists exactly the three current roots.

### U8. Update documentation

**Goal:** Documentation describes omp and OpenCode as the managed third-party harnesses and nothing retired as active.

**Requirements:** R13.

**Dependencies:** U1–U7.

**Files:**

- Modify: `README.md`, `docs/agent-routing.md`, `docs/repository-reference.md`, `docs/contributing.md`, `docs/macos.md`, `docs/decide.md`, `docs/shell.md`, `secrets/README.md`, `CONCEPTS.md`

**Approach:**

1. Remove the Pi sections, the native guard section, the Synthetic and Anthropic list descriptions, drift reporting, and the local Ollama Pi model section.
2. Add omp to the skill-discovery table, the plugin and skill-root lists in `docs/contributing.md`, and the README harness list; add Pi to the retired-tools list.
3. In `CONCEPTS.md`, remove **Model source** (no instance remains) and narrow **Catalog snapshot** to the OpenCode Go snapshot.
4. Fix the stale OpenCode version in `README.md`.

**Test expectation:** none -- documentation only; `agent-instructions` and Markdown lint run in the Verification Contract.

**Verification:** A search of `docs/`, `README.md`, `secrets/README.md`, and `CONCEPTS.md` finds Pi only in the retired-tools list or as T3 history.

---

## Verification Contract

| Gate | Command or check | Applies to |
| --- | --- | --- |
| Project checker | `nix develop .#agent-check -c ./scripts/agent-check` | every unit |
| Linux checks | `nix build --no-link` of the affected checks: `opencode`, `omp`, `claude`, `agent-plugins`, `agent-plugin-sync`, `agent-settings`, `agent-instructions`, `agent-unmanaged`, `korean-skills`, `official-skills`, `pinned-skills`, `test-audit-skill`, `opencode-go-models-watch`, and the workflow checks | U1–U7 |
| Shards | `nix build --no-link .#checkShards.<name>` for each shard holding a changed check, including `hosts` | U1–U7 |
| Darwin outputs | `darwin-outputs` and `darwin-config` checks | U1, U2, U6, U7 |
| VM | `auth-provisioning` and any changed Ollama VM test from `tests/vm-checks.nix`, when the platform can run them; report if it cannot | U2, U3 |
| Shared instructions | `agent-instructions` after `CONCEPTS.md` and `docs/agent-routing.md` change | U8 |

Report repository and VM checks separately from host verification, which only the owner can do after applying the generation.

---

## Definition of Done

- R1–R13 hold, and each AE is covered by an executed check.
- No flake output, check, workflow step, or document references Pi, the native guards, or the retired model lists except the retired-tools list, T3 history, and the one-shot cleanups KTD3 and KTD4 describe.
- All gates in the Verification Contract pass, or a gate that cannot run on this platform is reported with its reason.
- Every new or moved check is registered in a shard, and host-closure checks sit under `hostClosureChecks`.
- Dead-end code from abandoned approaches is removed from the diff.
