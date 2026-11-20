---
title: T3 Code Text Generation on Claude Code - Plan
type: refactor
date: 2026-11-20
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# T3 Code Text Generation on Claude Code - Plan

## Goal Capsule

- **Objective:** Thread titles, commit and PR text, voice transcript cleanup, and review guides run on one Claude Code Haiku model by default, so T3 Code's generated text is configured in one place.
- **Means:** Change the shared text generation selection and retire the separate review guide selection in the Home Manager settings merge (KTD1, KTD2).
- **Authority:** The Product Contract governs behavior; the Planning Contract governs implementation. Stop if the bundled T3 Code release stops resolving an unset review guide model through the shared selection.
- **Delivery:** One pull request. The implementation workflow verifies and ships the change; host activation is separate.

## Product Contract

### Summary

Replace OpenCode Haiku with Claude Code Haiku as the shared text generation model, at its native effort. Drop the review guide selection that existed only because OpenCode could not read a checkout, so review guides inherit the shared model.

### Problem Frame

T3 Code settings pick a Haiku model in two places. The shared text selection points at OpenCode's `anthropic/claude-haiku-5-5` with the `low` variant. A separate review guide selection points at Claude Code's `claude-haiku-5-5`, because OpenCode text generation cannot inspect a checkout. Once the shared model is Claude Code, the second selection repeats the first and gives the declaration two settings to keep in step.

### Requirements

**Shared model**

- R1. Use Claude Code `claude-haiku-5-5` as the shared text generation model, with no effort option so the native default applies.
- R2. Review guides use the shared model unless a source control writer override is set, in which case they follow that override. The declaration holds no review guide selection.

**Existing hosts**

- R3. A host that applied the earlier declaration loses its stored review guide selection on the next activation, and its stored shared selection carries no option from the previous model.

**Left alone**

- R4. Thread title instructions, whether review guides are enabled, source control and transcript cleanup model overrides, and project overrides keep their current values.

**Records**

- R5. The routing reference and the traits check describe the new configuration.

### Scope Boundaries

- Do not add managed source control or transcript model overrides, and do not turn review guides on.
- Do not change the model for new threads, the fallback model, or the thread title rule.
- Considered and not built: a cleanup script for the removed value. The settings merge already removes a retired key, so nothing else is needed.

### Key Decisions

- **Use the native effort default.** Governs R1. (session-settled: user-directed — chosen over keeping `low`, and over `low` for the shared model with a separate default for review guides: review guides read the checkout and share the model, and a separate selection keeps two settings to manage.)
- **Retire the review guide selection.** Governs R2, R3. (session-settled: user-directed — chosen over declaring the same value separately: the OpenCode limit that justified it no longer applies, and the request is to merge the settings.)

## Planning Contract

### Key Technical Decisions

- KTD1. **Own the shared selection as a whole object without options.** Set `textGenerationModelSelection` in `modelSelections` to the `claudeAgent` instance and `claude-haiku-5-5`, the same shape as `fallbackModelSelection`. The merge replaces an owned selection whole, so the earlier `variant` option does not survive. Serves R1, R3 (session-settled: user-directed — chosen over keeping `low`: see Key Decisions).
- KTD2. **Move the review guide key to `retiredKeys`.** Delete `reviewGuideModelSelection` from `modelSelections` and list it in `retiredKeys`, so the `remove` declaration drops whatever value the key holds, as `AGENTS.md` requires for a retired setting key. A key cannot be both owned and removed, so both edits land together. The bundled T3 Code 0.1.9 server resolves a review guide model from `reviewGuideModelSelection` when set, and otherwise from the source control writer selection, which falls back to `textGenerationModelSelection`. With the shared model on Claude Code, an unset key resolves to it. Serves R2, R3 (session-settled: user-directed — chosen over a duplicate declaration: see Key Decisions).

### Risks & Dependencies

- The retired key also drops a review guide model someone set in the app. That follows from retiring a managed key. Remove the `retiredKeys` entry once every host has rebuilt past it, as the module's comment says.
- Runtime title and commit generation needs a usable Claude Code login in the T3 Claude instance. The traits check verifies the written settings only, not a model's output.

## Implementation Units

### U1. Declare the shared model and retire the guide selection

- **Goal:** Write the new shared selection, retire the review guide key, and update the check and the reference.
- **Requirements:** R1–R5.
- **Dependencies:** None.
- **Files:**
  - `home/h82/t3code.nix`
  - `tests/t3code-traits.nix`
  - `docs/agent-routing.md`
- **Approach:**
  - In `home/h82/t3code.nix`, replace the shared selection per KTD1 and delete the review guide selection with its comment.
  - Add `reviewGuideModelSelection` to `retiredKeys` per KTD2.
  - In `tests/t3code-traits.nix`, update the expected owned selections and list the key in the expected `remove`.
  - In `docs/agent-routing.md`, rewrite the native launch paragraph to say Claude Code `claude-haiku-5-5` at its native effort is the shared model, review guides inherit it unless a source control writer override is set, and the selection does not turn on review guides.
- **Patterns to follow:** The existing whole-object selections in `modelSelections`, the retired key convention in `retiredKeys`, and the scratch-home activation exercise in `tests/t3code-traits.nix`, which asserts every declared `remove` key is absent afterwards.
- **Test scenarios:**
  - Covers R1, R3. Activate from a scratch home whose shared selection is a Codex model with a `reasoningEffort` option. Expect `textGenerationModelSelection` to equal the Claude Code Haiku selection with no `options` key.
  - Covers R2, R3. Activate from a scratch home that holds a `reviewGuideModelSelection` with an `effort` option. Expect the key to be absent afterwards.
  - Covers R4. Activate from a scratch home with a source control writer selection, a transcript cleanup selection, `reviewGuidesEnabled` set to `false`, and a project override. Expect all of them unchanged.
  - Compare the delivered declaration with the contract. Expect `own` to hold no review guide selection and `remove` to list it.
- **Verification:** The traits check passes. It verifies the settings written by activation, not that a signed-in model follows a prompt.

## Verification Contract

| Check | Command | Applies |
| --- | --- | --- |
| T3 Code traits | `nix build --no-link .#checks.x86_64-linux.t3code-traits` | U1 |
| Agent instructions | `nix build --no-link .#checks.x86_64-linux.agent-instructions` | Runs because `docs/agent-routing.md` is an input to that derivation |
| Formatting and whitespace | `nix fmt -- --ci`, `git diff --check` | Changed Nix files |
| Markdown | `markdownlint-cli2` on the changed Markdown | The routing reference and this plan |

Builds that cannot run on the local builder are reported as deferred to CI, never as passed.

## Definition of Done

- `textGenerationModelSelection` declares Claude Code `claude-haiku-5-5` with no options; no review guide selection is declared, and the key is in `retiredKeys`.
- The traits check and the agent instructions check pass, or are reported as deferred to CI with the reason.
- `docs/agent-routing.md` matches the declaration, and no other file still describes OpenCode as the shared text model.
- No abandoned-attempt code remains in the diff.
