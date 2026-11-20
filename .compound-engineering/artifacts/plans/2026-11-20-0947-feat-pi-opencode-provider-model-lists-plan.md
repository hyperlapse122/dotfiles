---
title: Pi and OpenCode Provider Model Lists - Plan
type: feat
date: 2026-11-20
topic: pi-opencode-provider-model-lists
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Pi and OpenCode Provider Model Lists - Plan

## Goal Capsule

- **Objective:** Pi and OpenCode both offer the current OpenAI and Anthropic models that the providers' list APIs report, including `gpt-6.2-astra` and `gpt-6.2-sol`, and new models appear without waiting for a Pi release.
- **Means:** A pre-configured model list for each provider, built from the provider's list API and models.dev, replaces Pi's compiled model lock and its source patch.
- **Product authority:** The repository owner's requests in this session.
- **Execution profile:** One pull request. Nothing in the project's instructions requires a part to ship separately.
- **Stop conditions:** Stop and report if Pi's packaged runtime rejects a declared OpenAI or Anthropic entry, or if replacing a catalog model with a declared entry breaks that model and KTD3's fallback does not restore it.
- **Open blockers:** None.

---

## Product Contract

### Summary

The OpenAI and Anthropic model lists become declared model lists instead of a runtime lock. Each list holds the models that the provider's list API returns and that pass a per-provider id filter, with details from models.dev. Pi and OpenCode declare the same entries from one committed snapshot that the existing 30-minute refresh keeps current. The Pi source patch and the compiled lock it enforces are removed.

### Problem Frame

Pi 1.5.2 compiles in a model catalog pinned to an upstream revision that predates `gpt-6.2-astra` and `gpt-6.2-sol`, and upstream main still pins the same revision. The repository's patch (`packages/pi-model-policy.patch`) also disables Pi's runtime catalog refresh and limits OpenAI and Anthropic to a lock that the refresh builds by intersecting each provider's list API with that compiled catalog. A model the compiled catalog lacks therefore never reaches Pi, however long the lock refresh runs.

OpenCode declares no OpenAI or Anthropic models and relies on its own catalog, so the two agents have no shared view of which models are in use.

### Requirements

**List contents**

- R1. Each provider's list holds every model its list API returns whose id fully matches that provider's filter (R2, R3).
- R2. OpenAI ids must fully match `gpt-(?:[0-9.]+)-(?:\w+)` and have a numeric version of 6.1 or higher.
- R3. Anthropic ids must fully match `claude-(?:\w+)-(?:[0-9\-.]+)`, and only active models are listed.
- R4. A model that passes its filter but has no models.dev entry stays out of the list, and the refresh log names it.

**Model details**

- R5. Name, context window, output limit, input modalities, reasoning support, and cost come from models.dev.
- R6. For Anthropic, the list API's context and output limits override models.dev's; cost still comes from models.dev.

**Agent consumption**

- R7. Pi declares each listed model under its provider in `~/.pi/agent/models.json`, the way it declares Synthetic's models today.
- R8. Pi's startup selection and model cycling (`enabledModels`) follow the list for OpenAI and Anthropic.
- R9. OpenCode declares the same models under `providers.openai.models` and `providers.anthropic.models` in `~/.config/opencode/opencode.json`.
- R10. Both agents read one committed snapshot per provider.
- R11. Neither agent hides a model that its own catalog defines for these providers; a listed model replaces the catalog entry with the same id.

**Runtime lock removal**

- R12. The Pi source patch, the compiled model lock it reads, `~/.pi/agent/model-lock.json`, and the `home/h82/agents/pi-policy.ts` extension are removed together with their tests and documentation. Synthetic stays defined through `models.json`.
- R13. A saved Pi session whose model is outside the list keeps running.

**Refresh**

- R14. The existing 30-minute refresh keeps both lists current, and the snapshot files and refresh tooling are named for model lists, not locks.
- R15. When a provider's list API or models.dev cannot be fetched, that provider's committed snapshot stays unchanged and no snapshot is partly updated; the refresh also fails rather than write an empty list.

### Acceptance Examples

- AE1. **Covers R1, R2, R5, R7, R9.** Given the OpenAI list API returns `gpt-6.2-sol` and `gpt-6.2-astra`, models.dev defines both, and Pi's compiled catalog defines neither, when the refresh runs and the host switches, both models appear in Pi and in OpenCode.
- AE2. **Covers R2.** Given the OpenAI list API returns `gpt-5.6-sol`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6.1`, and `gpt-6.1-codex-spark`, only `gpt-6.1-sol` enters the list: `gpt-5.6-sol` and `gpt-6-sol` are below version 6.1, `gpt-6.1` has no family suffix, and `gpt-6.1-codex-spark` does not fully match.
- AE3. **Covers R4.** Given a newly listed `gpt-6.3-sol` passes the OpenAI filter and models.dev has no entry for it yet, it is absent from the list and the refresh log names it; a later refresh adds it once models.dev defines it.
- AE4. **Covers R6.** Given the Anthropic list API reports a context limit that differs from models.dev's for the same model, the list carries the API's limit and models.dev's cost.
- AE5. **Covers R15.** Given models.dev is unreachable during a refresh, neither committed snapshot changes and the refresh reports the failure.

### Key Decisions

- **The providers' list APIs decide which models are available, and Pi's compiled catalog no longer takes part.** The OpenAI and Anthropic list APIs are the source of truth for availability. Governs R1. (session-settled: user-directed — chosen over pinning a newer pi.dev catalog revision and over intersecting with Pi's compiled catalog: neither lists `gpt-6.2-astra` and `gpt-6.2-sol` for Pi today.)
- **models.dev supplies model details.** It covers both providers, including `gpt-6.2-sol` and `gpt-6.2-astra`, and OpenAI's list API returns no details. Governs R5, R6. (session-settled: user-directed — chosen over taking details from Pi's catalog: its pinned revision lacks the new models.)
- **The result is a pre-configured model list, not an enforced lock.** The Pi patch is removed rather than extended, so the list declares models and does not hide others. Governs R7, R11, R12. (session-settled: user-directed — chosen over keeping and extending the patch so it accepts models absent from Pi's compiled catalog: the owner wants a pre-configured list, not a lockfile.)
- **A per-provider id filter plus a version threshold defines which models count.** It replaces a chat-model check against Pi's catalog. Governs R2, R3, R4. (session-settled: user-directed — chosen over listing every chat model and over a major-version-5 cutoff: only the current generations belong in the list.)
- **Dated Anthropic ids stay in the list next to their alias ids.** Ids such as `claude-haiku-4-5-20251001` pass the filter and are not excluded. Governs R3. (session-settled: user-directed — chosen over excluding dated ids: they are usable models.)
- **OpenCode mirrors Pi by adding the same entries.** It does not disable the rest of its own catalog for these providers. Governs R9, R11.
- **OpenAI lists only versions 6.1 and higher, compared numerically.** Every 5.x model and the 6.0 models are excluded, which today leaves `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6.2-astra`, and `gpt-6.2-sol`. The threshold applies to OpenAI only; applying it to Anthropic would drop `claude-opus-5` and `claude-fable-5`. Governs R2.

### Scope Boundaries

**Deferred for later**

- Hiding models that an agent's own catalog defines (OpenCode `disabled` entries, or an enforcement mechanism for Pi).
- A declared entry for models dropped by R2 or R4, such as `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.3-codex-spark`, and `gpt-5.6-cyber`; each stays visible only where an agent's own catalog defines it.

**Outside this work**

- Any replacement for the runtime enforcement the patch provided: blocking extension or `models.json` provider overrides, blocking `baseUrl` overrides, and preventing Pi's catalog refresh from pi.dev.
- The Synthetic model list, OpenCode's mirroring of Pi's visible Synthetic models, and the OpenCode Go catalog snapshot.
- The Pi release pin and its compiled catalog revision.
- Claude Code and Codex model lists.

### Dependencies / Assumptions

- The OpenAI list API returns `gpt-6.2-astra` and `gpt-6.2-sol`. This is unverified: no API key was used while writing this plan. models.dev defines both as of 2026-11-20.
- models.dev ids equal the providers' API ids for the models that pass the filters. Every id that passes today has a models.dev entry: the two OpenAI ids in the current lock (`gpt-6.1-sol`, `gpt-6.1-terra`), the eighteen Anthropic ids, and `gpt-6.2-astra` and `gpt-6.2-sol`, which only models.dev defines.
- A `models` entry on a built-in provider in Pi's `models.json` adds or replaces the model with the same id (`models.md` in the Pi 1.5.2 docs).
- The Anthropic list API reports context and output limits but no prices.

### Outstanding Questions

**Deferred to Planning**

- How a declared entry states API type and endpoint settings for a built-in provider, and how models.dev fields map onto Pi's and OpenCode's entry shapes.
- The snapshot's shape and file names, and the new names for the refresh tooling, workflow steps, and flake checks.
- Whether `scripts/pi-state` derives `enabledModels` directly from the snapshot.
- How the numeric version is read from ids with more than one dot.
- Which existing tests and docs the removal and rename touch (`tests/pi-runtime-policy.mjs`, `tests/pi-runtime.py`, `tests/update-workflow.py`, `tests/test_pi_provider_locks_watch.py`, `tests/opencode.nix`, `docs/repository-reference.md`).

### Sources / Research

- `packages/pi-model-policy.patch` and `packages/pi-runtime.nix`: the lock, its enforcement, and the compiled catalog pin.
- `home/h82/agents/pi-locks.nix`, `home/h82/agents/pi.nix`, `home/h82/agents/pi-policy.ts`, `scripts/pi-state`: Pi's lock wiring, policy extension, and `enabledModels`.
- `home/h82/agents/opencode.nix`: OpenCode's declared Synthetic and Go entries.
- `scripts/pi-provider-locks-watch` and `.github/workflows/update-dependencies.yml`: the current refresh.
- Pi 1.5.2 source at `b4afdddf44e059c67ccf5097e5317d913521b470`: `remote-catalog-provider.ts` (pi.dev refresh every 4 hours) and `docs/models.md`.
- OpenAI "List models" and Anthropic "List Models" API references; models.dev `api.json`.

---

## Planning Contract

Product Contract unchanged.

### Key Technical Decisions

- KTD1. **One snapshot per provider in Pi's `models.json` row shape.** `home/h82/agents/openai-models.json` and `home/h82/agents/anthropic-models.json` hold `{"models": [...]}` sorted by `id`; each row carries `id`, `name`, `reasoning`, `input`, `cost` (`input`, `output`, `cacheRead`, `cacheWrite`), `contextWindow`, and `maxTokens`. This is the row shape of the Synthetic lock, so OpenCode reuses the mapping `home/h82/agents/opencode.nix` already applies to Synthetic rows. Serves R5, R10.
- KTD2. **One tool replaces `pi-provider-locks-watch`.** `scripts/provider-models-watch` takes `--provider openai|anthropic`, fetches the provider's list API with the key on stdin (the existing `scripts/catalog_snapshot.py` helpers), fetches `https://models.dev/api.json` without a key, applies the R2/R3 filter, maps rows, and writes the snapshot through `write_if_changed`. It exits non-zero without writing on any fetch failure or an empty result. Serves R1-R6, R14, R15.
- KTD3. **Pi declares the rows under the built-in provider and sets `api` only.** `providers.openai` uses `api: "openai-responses"` and `providers.anthropic` uses `api: "anthropic-messages"` with no `baseUrl`, so the built-in endpoint and authentication stay. A declared row replaces a catalog model with the same id (Pi `docs/models.md`), which can drop catalog-only fields such as `compat` or a thinking-level map. U2 checks this against the packaged runtime; if a replaced model loses behavior, U2 declares only the ids the compiled catalog lacks, takes that id set from the same runtime check, records it as a static list beside the snapshots, and notes the narrowing in the PR. Serves R7, R11.
- KTD4. **`scripts/pi-state` reads Synthetic ids from `models.json` and receives the other ids as arguments.** `home/h82/agents/pi.nix` passes every snapshot id to `pi-state` as `--model openai/<id>` or `--model anthropic/<id>` (the way it passes `--hide-model` today), so `enabledModels` covers every snapshot id even when KTD3's fallback declares fewer rows. `pi-state` writes `enabledModels` as the visible Synthetic ids plus those ids, and drops the `dotfiles-policy.ts` entry that earlier activations wrote into `settings.json` `extensions` and into the launch wrapper. Serves R8, R12, R13.
- KTD5. **The version floor reads the first capture as a (major, minor) pair.** `gpt-6.1-sol` yields (6, 1) and passes `>= (6, 1)`; `gpt-6-sol` yields (6, 0) and fails. A capture that is not one or two dot-separated integers is rejected and the refresh log names the id. Serves R2.
- KTD6. **models.dev field mapping.** `name`, `reasoning`, `modalities.input` (keeping `text` and `image`), `cost.input`, `cost.output`, `cost.cache_read` and `cost.cache_write` (0 when absent), `limit.context`, and `limit.output`. For Anthropic, `max_input_tokens` and `max_tokens` from the list API replace the last two when they are not null. Serves R5, R6.
- KTD7. **The first snapshots are seeded from models.dev, and the next scheduled refresh replaces them.** No API key is available while implementing, so OpenAI is seeded with the four ids that pass the filter today and Anthropic with the eighteen ids of the current lock, limits taken from models.dev. The refresh keeps these correct afterwards. Serves R1, R14.

### Assumptions

- Pi's packaged runtime accepts `providers.openai` and `providers.anthropic` entries in `models.json` once the source patch is gone. U2 proves this by running the packaged runtime.
- `pi-model-lock.json` stays as the Synthetic model source and keeps its name; renaming it is outside this work.
- Removing the patch makes Pi refresh its catalog from pi.dev at runtime. The declared rows replace same-id entries, so the refresh does not override them.

---

## Implementation Units

### U1. Provider model list tool

**Goal:** Replace the lock watcher with a tool that builds each provider's model list from its list API and models.dev.

**Requirements:** R1, R2, R3, R4, R5, R6, R15; AE1, AE2, AE3, AE4, AE5.

**Dependencies:** None.

**Files:**

- Create: `scripts/provider-models-watch`, `tests/test_provider_models_watch.py`
- Delete: `scripts/pi-provider-locks-watch`, `tests/test_pi_provider_locks_watch.py`
- Modify: `scripts/catalog_snapshot.py` (only if a shared helper is missing), `packages/agent-tools.nix`, `flake.nix`, `scripts/ci-update-verify`

**Approach:**

- Move the fetch, retry, key-on-stdin, and redirect-refusal behavior of the old tool into the new one unchanged.
- Add the models.dev fetch, the per-provider filter and version floor (KTD5), the row mapping (KTD6), and the Anthropic override.
- Log each filter-passing id that has no models.dev entry and leave it out of the snapshot.
- Accept `--catalog` for the provider list and `--models-dev` for the models.dev document so tests run offline, as the old tool did for its inputs.
- Rename the package in `packages/agent-tools.nix` and the flake check in `flake.nix`, and update the catalog verification target in `scripts/ci-update-verify`.

**Patterns to follow:** `scripts/pi-provider-locks-watch`, `scripts/opencode-go-models-watch`, `tests/test_opencode_go_models_watch.py`, the `pythonScriptCheckWith` registration in `flake.nix`.

**Test scenarios:**

- Covers AE1. Given an OpenAI list containing `gpt-6.2-sol` and `gpt-6.2-astra` and a models.dev document defining both, the snapshot holds both with models.dev details.
- Covers AE2. Given the OpenAI list `gpt-5.6-sol`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6.1`, `gpt-6.1-codex-spark`, only `gpt-6.1-sol` is written.
- Covers AE3. Given `gpt-6.3-sol` in the list and absent from models.dev, it is not written and stderr names it.
- Covers AE4. Given an Anthropic list row with `max_input_tokens` and `max_tokens` that differ from models.dev, the row carries the API values and models.dev cost; a null API value keeps models.dev's.
- Anthropic rows with `lifecycle` other than `active` and ids that fail the filter are not written; a dated id such as `claude-haiku-4-5-20251001` is written.
- Covers AE5. A failing provider fetch and a failing models.dev fetch each exit non-zero and leave an existing snapshot file byte-identical.
- A list that filters to nothing exits non-zero and leaves the snapshot untouched.
- A request never carries the key in argv or reaches a redirect target (the old tool's checks, carried over).
- An id whose version capture is not one or two integers is rejected and named in the log.

**Verification:** The renamed flake check passes and the old check name no longer exists.

### U2. Pi declares the lists and drops the runtime lock

**Goal:** Pi offers the listed OpenAI and Anthropic models from `models.json` and runs without the source patch, compiled lock, or policy extension.

**Requirements:** R5, R7, R8, R10, R11, R12, R13; AE1.

**Dependencies:** U1 (snapshot shape).

**Files:**

- Create: `home/h82/agents/openai-models.json`, `home/h82/agents/anthropic-models.json`
- Modify: `home/h82/agents/pi.nix`, `packages/pi.nix`, `packages/pi-runtime.nix`, `scripts/pi`, `scripts/pi-state`, `tests/pi.nix`, `tests/pi-runtime.py`, `tests/pi-state.py`, `tests/pi-activation.py`, `tests/pi-wrapper.py`
- Delete: `packages/pi-model-policy.patch`, `home/h82/agents/pi-policy.ts`, `home/h82/agents/pi-locks.nix`, `home/h82/agents/pi-openai-model-lock.json`, `home/h82/agents/pi-anthropic-model-lock.json`, `tests/pi-runtime-policy.mjs`, `tests/pi-policy.mjs`

**Approach:**

- Seed both snapshots as KTD7 describes, from the models.dev document through the U1 tool in offline mode.
- In `home/h82/agents/pi.nix`, write `providers.openai` and `providers.anthropic` into the `models.json` text next to `providers.synthetic` (KTD3), and remove the `model-lock.json` and `dotfiles-policy.ts` files and the `policy` derivation.
- In `packages/pi.nix` and `packages/pi-runtime.nix`, remove the `modelLock` and `policyPatch` arguments, the `patches` entry, and the `postPatch` that writes the compiled lock; keep the compiled catalog fetch.
- In `scripts/pi-state`, apply KTD4 and retire the old extension entry; in `home/h82/agents/pi.nix`, pass the snapshot ids to the `pi-state` activation call.
- In `scripts/pi`, stop passing `--extension "$agent/dotfiles-policy.ts"`, and in `tests/pi-wrapper.py` drop the step that re-links that file.
- In `tests/pi-runtime.py`, replace the lock-based assertions with a `--list-models` run against the home-files `models.json` and the packaged runtime.
- Point `tests/pi-activation.py` at the file the auth test still needs (`models.json`).

**Execution note:** Prove the packaged runtime first: build `pi` and list models with the new `models.json` before touching the tests, since KTD3's fallback depends on that result.

**Patterns to follow:** The Synthetic provider block in `home/h82/agents/pi.nix`, `tests/pi-state.py`, the offline `--list-models` invocation already in `tests/pi-runtime.py`.

**Test scenarios:**

- Covers AE1. The packaged runtime lists `openai gpt-6.2-sol` and `openai gpt-6.2-astra`, which its compiled catalog does not define.
- A declared id that the compiled catalog also defines is listed once and keeps working (KTD3's check; record the outcome).
- `settings.json` gets `enabledModels` equal to the visible Synthetic ids plus `openai/<id>` and `anthropic/<id>` for every id passed with `--model`, and no `openai/*` or `anthropic/*` glob.
- The installed `bin/pi` wrapper loads only the web and question extensions and starts without the policy file present.
- A `settings.json` that already lists `dotfiles-policy.ts` under `extensions` comes out without it and with the other managed extensions intact.
- Covers R13. A saved session whose model is outside the snapshots starts without the old "managed model lock" stop.
- `pi-state` with a hidden Synthetic model still hides it, with ids read from `models.json`.
- No built or rendered output, including the `bin/pi` wrapper, still contains `model-lock.json`, `dotfiles-policy.ts`, or `dotfiles-model-lock`.

**Verification:** The `pi` flake check passes on each configured user entry.

### U3. OpenCode declares the same lists

**Goal:** OpenCode offers the same OpenAI and Anthropic entries from the same snapshots.

**Requirements:** R9, R10, R11; AE1.

**Dependencies:** U1, U2 (snapshots).

**Files:**

- Modify: `home/h82/agents/opencode.nix`, `tests/opencode.nix`

**Approach:**

- Map each snapshot row with the conversion `opencode.nix` applies to Synthetic rows (`name`, `limit.context`, `limit.output`, `cost`, `cache`), and add two `ownEntries` for `providers.openai.models` and `providers.anthropic.models` beside the Synthetic and Go entries.
- Declare no `disabled` entries for these providers (R11).
- Keep the Synthetic block and the Go catalog block unchanged.

**Patterns to follow:** The `syntheticModels` and `goModels` definitions and the `ownEntries` list in `home/h82/agents/opencode.nix`.

**Test scenarios:**

- Covers AE1. The merged `opencode.json` declares `gpt-6.2-sol` and `gpt-6.2-astra` under `providers.openai.models`, with limits and cost from the snapshot.
- Every Anthropic snapshot row appears under `providers.anthropic.models`.
- No `disabled` entry is declared under `providers.openai` or `providers.anthropic`.
- The Synthetic and Go entries are unchanged from before.
- Re-running activation after a snapshot row is removed drops that row from the file and leaves unrelated user settings alone (the ownership ledger behavior).

**Verification:** The `opencode` flake check passes on each configured user entry.

### U4. Refresh workflow, remaining checks, and docs

**Goal:** The scheduled refresh updates the new snapshots, and the repository's checks and documentation describe model lists instead of locks.

**Requirements:** R14, R15; AE5.

**Dependencies:** U1, U2, U3.

**Files:**

- Modify: `.github/workflows/update-dependencies.yml`, `tests/update-workflow.py`, `README.md`, `docs/repository-reference.md`, `docs/agent-routing.md`, `secrets/README.md`, `flake.nix`, and `tests/check-shards.nix` only if the shard guard asks for it

**Approach:**

- Replace the two lock refresh steps with steps that run `nix run .#provider-models-watch -- --provider <name> --snapshot <file>` against the new snapshot files, keeping each step independent: a missing secret or a failure for one provider leaves the other provider's step running and its committed snapshot unchanged.
- Update the fake workflow driver and expectations in `tests/update-workflow.py` for the new tool name and snapshot paths.
- Register the renamed check where `check-shards-guard` expects it.
- Rewrite the Pi sentences in `README.md`, `docs/repository-reference.md` (the `home/h82/` entry), and `docs/agent-routing.md` (the Pi package paragraph) to describe declared model lists, and note that `scripts/provider-models-watch` replaced `pi-provider-locks-watch`; in `secrets/README.md`, change the sentence about the scheduled job's API-key secrets from model locks to model lists.

**Patterns to follow:** The existing Pi lock steps in `.github/workflows/update-dependencies.yml` and the one-check-per-workflow rule in `AGENTS.md`.

**Test scenarios:**

- Covers AE5. With the OpenAI step failing, the Anthropic snapshot still publishes, and the reverse (the existing independence assertions, renamed).
- A missing `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` leaves that provider's snapshot unchanged and does not block the other.
- A changed snapshot produces a commit titled for the model list; an unchanged one produces none.
- `check-shards-guard` finds the renamed check in a shard and no reference to the old name remains.

**Verification:** `update-dependencies-reconcile` and `check-shards-guard` pass, and `grep` finds none of `pi-provider-locks-watch`, `pi-model-policy`, `pi-policy.ts`, or `dotfiles-policy.ts` outside `.compound-engineering/`.

---

## Verification Contract

| Gate | Command or evidence | Applies to |
| --- | --- | --- |
| Formatting | `nix fmt -- --ci` | All Nix changes (Linux builder) |
| Whitespace | `git diff --check` | All units |
| Markdown | `markdownlint-cli2` on changed Markdown | README, docs, this plan |
| Tool tests | `nix build --no-link .#checks.x86_64-linux.provider-models-watch` | U1 |
| Pi | `nix build --no-link .#checks.x86_64-linux.pi` | U2 |
| OpenCode | `nix build --no-link .#checks.x86_64-linux.opencode` | U3 |
| Workflow and shards | `nix build --no-link .#checks.x86_64-linux.update-dependencies-reconcile` and the `check-shards-guard` check | U4 |
| Instructions | the `agent-instructions` check, since `docs/agent-routing.md` changes | U4 |
| Full CI | `full-ci` label with `host-checks`, `vm-checks`, `build`, and `build-darwin` green on the head commit | Before the PR is ready |

Local results and checks deferred to CI are reported separately; `aarch64-darwin` outputs build on CI.

## Definition of Done

- Every unit's verification passes and every R-ID has a unit that advances it.
- `gpt-6.2-astra` and `gpt-6.2-sol` appear in the packaged Pi runtime's model list and in the merged OpenCode settings.
- No file, check, workflow step, wrapper, or document still names the removed patch, the policy extension (`pi-policy.ts` or `dotfiles-policy.ts`), the compiled lock, or `pi-provider-locks-watch`.
- The PR body carries the removal's consequences from the Product Contract (no runtime enforcement, pi.dev refresh, no stop for out-of-list sessions) and KTD3's outcome.
- No abandoned-attempt code remains in the diff.

## Risks

- **Replaced catalog entries may lose fields.** A declared row replaces the catalog model with the same id (KTD3); U2 checks it and falls back to declaring only ids the compiled catalog lacks.
- **The seeded snapshots can differ from the live API lists.** The OpenAI list API may not return the four seeded ids, and Anthropic limits come from models.dev until the first refresh (KTD7); the scheduled refresh corrects both.
- **The models.dev document is a new unpinned input.** A malformed or reshaped document makes the refresh fail and leaves the committed snapshots in place (R15).
