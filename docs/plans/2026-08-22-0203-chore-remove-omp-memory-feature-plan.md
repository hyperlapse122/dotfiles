---
title: Remove OMP Memory Feature - Plan
type: chore
date: 2026-08-22
topic: remove-omp-memory-feature
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove OMP Memory Feature - Plan

## Goal Capsule

- **Objective:** After the next `chezmoi apply`, omp sessions run with the memory feature fully disabled — no recall injections into prompts, no retention processing, and no memory tools or Memory prompt section in context.
- **Means:** Data-only edit of the declared omp settings map (KTD1–KTD4).
- **Authority:** The user's removal request governs scope. The root `AGENTS.md` governs data-driven editing, isolated render verification, and the no-teardown rule.
- **Execution profile:** One data-file edit verified by render-time checks. This run never applies source state to the live home directory.
- **Stop conditions:** Stop if pinning `memory.backend: off` fails the render-time validator, if compliance would require editing the provisioner or validator templates, or if a live apply rejects the pinned value — an apply-time rejection aborts the whole settings phase, not just this key.
- **Tail ownership:** The invoking LFG pipeline owns commit, push, PR, and CI watch.

---

## Product Contract

### Summary

Remove omp's mnemopi long-term-memory feature by editing the declared settings map in `.chezmoidata/agents.yaml`: pin the backend to `off` and delete the six `mnemopi.*` knob declarations. AutoLearn stays declared exactly as today. The goal is a lower per-turn token and context cost for agentic development.

### Problem Frame

Mnemopi's always-on cost is the fixed prompt prefix: the `recall`/`retain`/`reflect`/`memory_edit` tool schemas and the Memory prompt section ride in context on every turn. Its active costs are periodic, not per-turn: `autoRecall` injects retrieved memories once per session on the first model turn, capped near 5000 tokens, and `autoRetain` runs transcript extraction at most every fourth turn, on the tiny role. The user has directed removing the memory feature; the always-on prefix goes with it.

### Requirements

- R1. The memory backend is disabled: `agents.omp.settings` in `.chezmoidata/agents.yaml` declares `memory.backend: off`.
- R2. AutoLearn stays declared `autolearn.enabled: true`, unchanged from today: the learn tool it also gates requires an active memory backend, so R1 already retires it, while the backend-independent manage_skill capability is outside removal scope.
- R3. No `mnemopi.*` path remains declared anywhere in `.chezmoidata/agents.yaml`.
- R4. The change touches only `.chezmoidata/agents.yaml`; the provisioner and validator stay unchanged.

### Scope Boundaries

- Figma skill removal is not part of this plan. Its source-side retirement already landed, with CI asserting absence in `.github/workflows/render-dotfiles.yml`; the remaining live-host residue cleanup follows `docs/decommission/figma-global-skills.md` and leaves no repository artifact.
- omp's Figma row in `~/.omp/agent/agent.db` stays — `figma-auth omp` owns it.
- On-disk mnemopi data (about 51 MB under `~/.omp/agent/memories/mnemopi` on this host) stays; the no-teardown rule bars teardown scripts. If reclamation is ever wanted, `/memory clear` must run BEFORE the apply that flips the backend — afterwards only manual deletion reaches the inactive store. Stale `mnemopi.*` keys in live `config.yml` stay inert; the provisioner never reconciles undeclared paths.

### System-Wide Impact

- On the next apply, every managed host loses the `recall`/`retain`/`reflect`/`memory_edit` tools, the Memory prompt section, and autoRecall/autoRetain processing. The Auto-Learn prompt guidance and the manage_skill tool remain.
- Stored SQLite state stays on disk untouched. A faithful re-enable restores five declarations, not one: `memory.backend: mnemopi` plus the four non-default knobs this change deletes — `polyphonicRecall`, `enhancedRecall`, `proactiveLinking` as `true`, and `embeddingVariant: multilingual`, chosen for Korean-recall quality. Changing `embeddingVariant` rebuilds stored embeddings on the next writable start.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Pin `memory.backend: off` as an explicit declaration instead of deleting the line. The provisioner asserts declared paths only, so deleting the line leaves the live backend at `mnemopi`. A null declaration was rejected: reset convergence requires an empty-default key, and `off` is the non-empty upstream default (`.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` reset contract).
- KTD2. Delete the six `mnemopi.*` knob declarations outright rather than nulling them. Nulling would reset-loop on every apply because their upstream defaults are non-empty. Four of the six were deliberate non-default opt-ins (`polyphonicRecall`, `enhancedRecall`, `proactiveLinking`, `embeddingVariant: multilingual`); deleting them is accepted because the feature is removed wholesale at user direction, and KTD2 plus git history record their values for restoration.
- KTD3. Keep `autolearn.enabled: true`. The learn tool it also gates requires an active memory backend, so the backend pin alone retires learn; its manage_skill tool registers independently of the backend and is a non-memory capability this removal must not take (`omp://tools/learn.md`, `omp://tools/manage_skill.md`).
- KTD4. Full removal over narrower disables. Setting only `mnemopi.autoRecall` and `mnemopi.autoRetain` to false would keep the backend and its fixed tool prefix while dropping the periodic costs; that was not chosen because the user's directive targets the feature itself, and the always-on prefix is the cost that motivated the request.

### Assumptions

- `off` is a valid `memory.backend` value and the upstream default; omp's settings documentation records the enum `off|local|hindsight|mnemopi`. The render gate proves chezmoi resolves the unquoted scalar as the string `"off"`, not a YAML boolean.
- Both changed values pass the render-time validator's charset and type gates; a render smoke confirmed this. Enum membership itself is checked only at apply time, where a rejection aborts the settings phase loudly.

### Risks & Dependencies

- `.ci/test-omp-agent-reconcile.sh` derives its expectations from the rendered declared map, so its count assertions self-adjust; no test edit is expected.
- Live hosts keep stale `mnemopi.*` values in `config.yml` as inert data; accepted while the backend is off.
- The saving's magnitude is unmeasured; the recurring residue after removal is bounded by the fixed prompt prefix that motivates it. `display.showTokenUsage` is already enabled for a before/after comparison.

### Sources

- `.chezmoidata/agents.yaml` — the settings block this plan edits.
- `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` — per-key assertion and drift/reset semantics behind KTD1/KTD2.
- `.chezmoitemplates/omp-settings-validate.tmpl` — null rejection list and charset gates cited by KTD1/KTD2.
- `omp://settings.md` and `omp://mnemosyne-memory-backend.md` — backend enum/default, knob defaults, injection and retention cadences behind the Problem Frame and KTD2.
- `omp://tools/learn.md` and `omp://tools/manage_skill.md` — tool-registration gates behind KTD3.
- `docs/decommission/figma-global-skills.md` — boundary for the figma exclusion.

---

## Implementation Units

### U1. Disable memory declarations in omp settings

- **Goal:** The declared settings map carries `memory.backend: off` where the mnemopi block was, with no `mnemopi.*` declaration left and `autolearn.enabled: true` preserved.
- **Requirements:** R1, R2, R3, R4
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:** Replace the eight-line memory block from `memory.backend: mnemopi` through `mnemopi.proactiveLinking` with the one-line constraint comment plus `memory.backend: off`; keep the following `autolearn.enabled: true` line as-is. Change nothing else in the file.
- **Test Scenarios:**
  - The render gate (G1) exits 0, proving the validator accepts the pinned value.
  - The rendered script's embedded declared JSON contains `"memory.backend": "off"` in string form, retains `"autolearn.enabled": true`, and contains no `mnemopi.` occurrence (G2).
  - The scoped diff names only `.chezmoidata/agents.yaml` (G3).
- **Verification:** Gates G1–G3 against the final tree; G4 is the post-apply manual probe on the first host apply.

---

## Verification Contract

| Gate | Check | Covers |
|---|---|---|
| G1 | Render `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` through `chezmoi execute-template` with the stub `op`, empty config, and `--source "$PWD"`; the command exits 0 | R1–R4 |
| G2 | The rendered script's embedded declared JSON contains `"memory.backend": "off"` and `"autolearn.enabled": true` and no `mnemopi.` occurrence | R1, R2, R3 |
| G3 | `git diff --check` is clean and the scoped diff names only `.chezmoidata/agents.yaml` | R4 |
| G4 | Post-apply manual probe: after the next real `chezmoi apply`, `omp config get memory.backend` prints `off`, and a fresh session exposes none of the four memory tools or the Memory section | Goal Capsule objective |

CI additionally runs `.github/workflows/render-dotfiles.yml` and `.github/workflows/ci.yml`; `.ci/test-omp-agent-reconcile.sh` self-adjusts to the new declared-path count.

---

## Definition of Done

- **Global:** U1 complete; gates G1–G3 green on the final tree; both CI workflows reach terminal green on the PR; G4 recorded as the post-apply probe for the first host apply.
- **Per-unit U1:** All three test scenarios hold with no uncommitted edits left behind.
- **Cleanup:** No scratch or render artifacts inside the repository; no `mnemopi.*` path remains declared in the changed file (the constraint comment may name the backend).
