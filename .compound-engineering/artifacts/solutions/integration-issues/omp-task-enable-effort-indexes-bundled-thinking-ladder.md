---
title: OMP task.enableEffort indexes bundled thinking.efforts directly, sending rejected minimal on gemini-3.8-flash
date: "2026-10-26"
category: integration-issues
module: OMP role orchestration and model declarations (home/h82/agents/omp-roles.nix, home/h82/agents/omp-declarations.py)
problem_type: integration_issue
component: tooling
symptoms:
  - "With `task.enableEffort = true` and `agentModelOverrides.task = \"google-antigravity/gemini-3.8-flash:low\"`, passing `effort: \"lo\"` on a `task` subagent sets `thinkingLevel: \"minimal\"`, which Google's Gemini API rejects with HTTP 400 on `gemini-3.8-flash`"
  - "Passing `effort: \"med\"` on a `task` subagent sets `thinkingLevel: \"low\"`, leaving `P4` (`medium`) unreachable on general `task` workers while `effort: \"medium\"` fails schema validation (`Use \"lo\", \"med\", or \"hi\"`)"
  - "T3 Code's `omp` ACP `session/set_config_option` advertises `\"minimal\"` among the `thinking` options for `google-antigravity/gemini-3.8-flash`"
root_cause: config_error
resolution_type: config_change
severity: high
retire_when: "Upstream oh-my-pi drops `minimal` from bundled `google-antigravity/gemini-3.8-flash` metadata; check `omp models --json` in a scratch home with fake `google-antigravity` OAuth and empty `models.yml`"
tags: ["omp", "google-antigravity", "gemini-3-8-flash", "enable-effort", "thinking-level", "model-overrides", "acp", "t3code"]
---

# OMP task.enableEffort indexes bundled thinking.efforts directly, sending rejected minimal on gemini-3.8-flash

## Problem

Enabling `task.enableEffort = true` alongside `task.agentModelOverrides.task = "google-antigravity/gemini-3.8-flash:low"` in `home/h82/agents/omp-roles.nix` appears to anchor `task` subagents at `low` and scale up from there, but OMP `18.12.6` resolves `tasks[].effort` (`"lo"`, `"med"`, `"hi"`) against the model's full `thinking.efforts` array rather than the `:low` override floor. Because OMP `18.12.6` bundles `google-antigravity/gemini-3.8-flash` with `["minimal", "low", "medium", "high"]`, `effort: "lo"` sends `minimal` (rejected with HTTP 400 by upstream Gemini validation on `gemini-3.8-flash`), `effort: "med"` resolves to `low` instead of `P4`'s `medium`, and T3 Code's ACP picker exposes `minimal`.

## Symptoms

- In standalone OMP with `task.enableEffort = true` (`home/h82/agents/omp-roles.nix:15`), `task` exposes `effort` with enum `"lo" | "med" | "hi"`; passing profile name `"medium"` fails schema validation before the child starts (`Use "lo", "med", or "hi"`).
- Passing `effort: "lo"` to a `task` child on `google-antigravity/gemini-3.8-flash` records `thinkingLevel: "minimal"` in the child session, violating the upstream Gemini API constraint (`low`, `medium`, `high` only on `gemini-3.8-flash`).
- Passing `effort: "med"` on the 4-level bundled ladder resolves to `thinkingLevel: "low"`, silently downgrading non-review `P4` `task` dispatches to `P3`, while `"hi"` jumps straight to `"high"`.
- In `omp --mode acp`, selecting `google-antigravity/gemini-3.8-flash` returns `["off", "auto", "minimal", "low", "medium", "high"]` for the `thinking` config option.

## What Didn't Work

- **Relying on the `:low` suffix in `task.agentModelOverrides.task = "google-antigravity/gemini-3.8-flash:low"`.** That suffix sets the default thinking level only when `tasks[].effort` is omitted; once `task.enableEffort = true` prompts the parent to pass `effort`, OMP indexes `"lo"`/`"med"`/`"hi"` across the model's `thinking.efforts` list from index `0`.
- **Adding a full `google-antigravity` provider entry with `models` or `apiKey` in `models.yml`.** `google-antigravity` authenticates through OAuth credentials stored in `~/.omp/agent/agent.db` (`auth.json` import), not a static SOPS API key; declaring `models` or `apiKey` under `providers.google-antigravity` would shadow bundled transport metadata or break OAuth resolution.

## Solution

Override only `gemini-3.8-flash`'s `thinking` ladder under `providers["google-antigravity"]["modelOverrides"]` in `home/h82/agents/omp-declarations.py` (`lines 75-85`), leaving `models` and `apiKey` absent so OAuth discovery and bundled endpoints stay intact:

```python
providers = {
    "google-antigravity": {
        "modelOverrides": {
            "gemini-3.8-flash": {
                "thinking": {"mode": "effort", "efforts": ["low", "medium", "high"]},
            }
        }
    }
}
```

Pair that override with explicit `"lo"` (`P3` `low`) and `"med"` (`P4` `medium`) `tasks[].effort` guidance in `home/h82/agents/instructions/instructions.md.tmpl` (`line 241`), and assert in `tests/omp-acp.py` (`lines 106-107, 391-392`) that `providers["google-antigravity"]` contains only `modelOverrides` and that ACP `session/set_config_option` on `google-antigravity/gemini-3.8-flash` advertises `{"off", "auto", "low", "medium", "high"}`.

## Why This Works

OMP merges `models.yml` `modelOverrides` onto bundled provider models without replacing the provider's OAuth credential lookup or built-in model roster. Narrowing `gemini-3.8-flash`'s `thinking.efforts` to the three upstream-valid levels `["low", "medium", "high"]` gives OMP's 3-bucket `effort` selector an exact 1-to-1 mapping (`"lo"` -> `"low"`, `"med"` -> `"medium"`, `"hi"` -> `"high"`), keeps omitted `effort` at `"low"` via `agentModelOverrides.task`, and removes `"minimal"` from T3 Code's ACP `thinking` option list.

## Prevention

- Before enabling `task.enableEffort = true` or assigning a model to `task.agentModelOverrides` in `home/h82/agents/omp-roles.nix`, inspect `omp models --json` for that model's bundled `thinking` array and verify every listed effort level is accepted by the upstream provider API.
- When a bundled OAuth provider model lists an invalid or misaligned effort level, patch it in `home/h82/agents/omp-declarations.py` with a `modelOverrides`-only entry (asserting `set(providers[name]) == {"modelOverrides"}` in `tests/omp_models_load.py` and `tests/omp-acp.py`) rather than declaring `apiKey` or `models`.
- Test the effective ladder through `omp --mode acp` `session/set_config_option` (`tests/omp-acp.py`), not just static `config.yml` key checks (`tests/omp_settings_applied.py`).

## Related Issues

- Issues [#357](https://github.com/hyperlapse122/nix-config/issues/357) and [#359](https://github.com/hyperlapse122/nix-config/issues/359) introduced the `google-antigravity` Gemini defaults and `P1`-`P6` role orchestration in OMP and T3 Code.
- [Benchmark a cross-model review peer in T3 Code before changing its model or effort](../best-practices/benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md): earlier observation on `GLM-5.3` that a catalog-advertised thinking level can fail or misbehave until verified against the runtime.
- [Claude Code ignores global-config keys declared in settings.json](claude-code-global-config-keys-ignored-in-settings-json.md): sibling harness trap where static config declarations pass mirror checks while runtime resolution follows a different path.
