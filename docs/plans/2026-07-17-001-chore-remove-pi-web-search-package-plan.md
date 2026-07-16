---
title: Remove Pi Web Search Package - Plan
type: chore
date: 2026-07-17
topic: remove-pi-web-search-package
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove Pi Web Search Package - Plan

## Goal Capsule

- **Objective:** Remove `npm:@counterposition/pi-web-search` from Pi's managed package declarations, reconcile directly stale package documentation, and prepare the narrow repository change for a mergeable pull request.
- **Authority:** The user's removal and pull-request directives govern scope; `AGENTS.md` governs data-first configuration and isolated verification.
- **Execution profile:** Lightweight declarative configuration and documentation change with no new runtime code.
- **Stop conditions:** Stop rather than broadening scope if the removal appears to require deleting the separate MCP `websearch` server, Pi's `webSearch` preferences, another package, or teardown logic.
- **Tail ownership:** The implementation workflow owns commit, push, pull-request creation, and required CI/review monitoring.

## Product Contract

### Summary

Remove the exact Pi package source from the authoritative agent data while retaining the separate web-search configuration surfaces and keeping repository guidance accurate.

### Problem Frame

`.chezmoidata/agents.yaml` is the source of truth for Pi's managed settings. Its `agents.pi.settings.packages` list is copied into the readonly `~/.pi/agent/settings.json` target and rendered into the `PACKAGES` array of `.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl`, so one data-row removal updates both consumers without editing their generic templates.

`AGENTS.md` currently lists the package as part of Pi's installed package set. Leaving that enumeration unchanged would make the source instructions disagree with the requested configuration.

### Requirements

- R1. Remove only `npm:@counterposition/pi-web-search` from `agents.pi.settings.packages` in `.chezmoidata/agents.yaml`.
- R2. Preserve the remaining package sources and order, Pi's `settings.webSearch` preferences, the MCP server named `websearch`, and all unrelated agent data.
- R3. Update the directly stale Pi package enumeration in `AGENTS.md` while preserving its data-first and readonly-settings guidance.
- R4. Verify that the rendered Pi settings and package-reconciliation trigger omit the removed source, retain the intended remaining sources, and remain syntactically valid.
- R5. Prepare one coherent repository change for a mergeable pull request with required checks monitored to a terminal state.

### Scope Boundaries

**In scope:** The exact package row in `.chezmoidata/agents.yaml`, the directly stale package enumeration in `AGENTS.md`, isolated rendering and syntax checks, and pull-request delivery.

**Out of scope:**

- Removing or renaming the `agents.mcp.servers` entry named `websearch`.
- Removing Pi's `settings.webSearch` preferences or its Exa API-key reference.
- Editing `dot_pi/agent/private_readonly_settings.json.tmpl` or `.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl`; both already consume package data generically.
- Adding a teardown, cache-pruning, or package-removal script for already-installed runtime state.
- Changing another Pi extension, model, provider, auth entry, or agent configuration.

### Acceptance Examples

- AE1. **Covers R1, R2, R4.** Rendering the managed Pi settings from the updated data produces the four remaining package sources in their existing order and omits `npm:@counterposition/pi-web-search`; the existing `webSearch` object remains present.
- AE2. **Covers R1, R2, R4.** Rendering the package-update script produces a `PACKAGES` trigger containing the same four remaining sources, omitting the removed source, and valid shell syntax.
- AE3. **Covers R2, R3.** A live-source search finds no exact removed-package reference outside the plan artifact, while the MCP `websearch` entry and Pi `webSearch` settings remain present.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Remove the exact package declaration and no broader web-search surface.** (session-settled: user-directed — chosen over retaining the package declaration: the user explicitly requested its removal.) The MCP `websearch` server and Pi's `webSearch` preferences are independent configuration surfaces and remain unchanged.
- KTD2. **Deliver through a mergeable pull request.** (session-settled: user-directed — chosen over leaving the change local or pushing directly without a PR: the user explicitly requested a PR.) A successful push is not completion until required checks and review are terminal and acceptable.
- KTD3. **Edit the data source rather than generic consumers.** The settings target deep-copies `.agents.pi.settings`, and the package-update script ranges over `.agents.pi.settings.packages`; removing one data row propagates to both rendered consumers and changes the onchange trigger.
- KTD4. **Correct directly stale documentation without adding teardown.** The package enumeration in `AGENTS.md` must match the data source, while existing installed artifacts remain runtime state outside this source-only change.

### Assumptions

- The existing generic templates serialize any valid package list, so no consumer-template change is needed.
- `pi update --extensions` remains the apply-time reconciliation mechanism; the rendered trigger change causes it to run on the next applicable apply.
- Removing the declaration does not promise deletion of every cached package artifact; Pi's managed settings and declared package set are the authoritative behavior.
- A broad `websearch` search will include intentional retained MCP and Pi settings references, so validation distinguishes the exact removed package string from those retained surfaces.

### Sources & Research

- `.chezmoidata/agents.yaml` — authoritative Pi package list, retained `settings.webSearch` preferences, and MCP server declaration.
- `dot_pi/agent/private_readonly_settings.json.tmpl` — deep-copies `.agents.pi.settings` into the managed readonly settings target.
- `.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl` — ranges over package data to form its rendered onchange trigger and invokes `pi update --extensions`.
- `AGENTS.md` — package-set documentation, no-teardown rule, isolated stub-`op` verification recipe, and PR/CI completion requirements.
- `.github/workflows/render-dotfiles.yml` — existing rendered-file, rendered-internals, and shell-lint coverage for pull requests.

---

## Implementation Units

### U1. Remove the Pi web-search package declaration

- **Goal:** Remove the requested package source while preserving all other Pi settings and package declarations.
- **Requirements:** R1, R2, R4; KTD1, KTD3; AE1, AE2, AE3.
- **Dependencies:** None.
- **Files:** `.chezmoidata/agents.yaml`; rendered verification targets `dot_pi/agent/private_readonly_settings.json.tmpl` and `.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl` without modifying them.
- **Approach:** Delete only the `npm:@counterposition/pi-web-search` list item. Keep the remaining package entries in order and leave `settings.webSearch`, the MCP `websearch` entry, and unrelated agent data untouched.
- **Patterns to follow:** The data-first rule in `.chezmoidata/agents.yaml` and the existing generic consumers.
- **Execution note:** Use isolated render/smoke proof rather than adding unit-test scaffolding for this declarative source edit.
- **Test scenarios:**
  - Covers AE1. Render the managed Pi settings through the repository's stub-`op` and throwaway-destination recipe, parse the output as JSON, and verify the exact four retained package sources and unchanged `webSearch` object.
  - Covers AE2. Render the package-update script through the same isolated recipe, verify its `PACKAGES` trigger contains the four retained sources and not the removed source, and validate shell syntax.
  - Covers AE3. Search live source for the exact removed package string and separately assert that the MCP `websearch` entry and Pi `webSearch` settings remain present.
- **Verification:** V1, V2, and V3 in the Verification Contract.

### U2. Reconcile package documentation and delivery scope

- **Goal:** Keep the Pi package documentation accurate and leave the change ready for pull-request delivery.
- **Requirements:** R3, R5; KTD2, KTD4; AE3.
- **Dependencies:** U1.
- **Files:** `AGENTS.md`.
- **Approach:** Remove the stale package name from the current package enumeration while preserving the explanation of `.agents.pi.settings.packages`, managed readonly settings, the rendered onchange trigger, and `pi update --extensions`. Keep the source and documentation edits as one coherent change for the PR workflow.
- **Patterns to follow:** Existing Pi configuration guidance in `AGENTS.md`, repository Conventional Commit rules, and required CI/review monitoring.
- **Test expectation:** No new automated test file; documentation and declarative configuration are verified by the existing render and CI surfaces.
- **Verification:** V3, V4, and V5 in the Verification Contract.

---

## Verification Contract

All render-only checks use the `AGENTS.md` stub-`op` plus a throwaway destination and `--source` set to the current worktree; they never target the live `$HOME`.

- V1. **Managed settings render:** Render `dot_pi/agent/private_readonly_settings.json.tmpl`, parse the result as JSON, and verify that `packages` equals the four retained sources in order, excludes `npm:@counterposition/pi-web-search`, and retains `webSearch`.
- V2. **Package-update script render:** Render `.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl`, verify the rendered `PACKAGES` array excludes the removed source and retains the four remaining sources, then run shell syntax validation. Record that the rendered-content change retriggers the script on the next applicable apply.
- V3. **Scope and drift sweep:** Search live source outside `docs/plans/**` for the exact removed package string and expect no matches after implementation. Separately confirm the MCP `name: websearch`, `settings.webSearch`, and all four retained package sources remain. Review `git diff --check` and the final diff for unrelated changes.
- V4. **Repository validation:** Use the applicable local render/config checks without touching live `$HOME`; rely on V1–V3 and the pull-request render workflow when no narrower package-list test exists.
- V5. **Mergeability gate:** Push the branch, open the requested PR, and monitor required GitHub Actions workflows and automated review to terminal success. Do not declare completion while checks are running, failing, cancelled, or have unresolved actionable review feedback.

---

## Definition of Done

- `.chezmoidata/agents.yaml` no longer declares `npm:@counterposition/pi-web-search` under `agents.pi.settings.packages`.
- The four remaining package sources retain their order, and the MCP `websearch` plus Pi `settings.webSearch` configuration remain unchanged.
- `AGENTS.md` no longer claims the removed package is installed and still documents the data-driven readonly-settings and onchange mechanism accurately.
- V1 and V2 prove both generated consumers omit the removed source and remain valid; V3 proves no unintended web-search surface or unrelated agent configuration changed.
- No teardown script, cache-pruning logic, generated-file edit, unrelated dependency change, or abandoned experimental edit enters the implementation diff.
- The branch is delivered as one coherent Conventional Commit, the requested PR is open and mergeable, required checks are terminal and green, and no actionable review finding remains unresolved.
