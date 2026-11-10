# Agent routing

The ordinary user instruction files share writing and temporary-resource rules. They set no model or effort. Claude Code, Codex, Antigravity, Grok, and Pi each receive their own render.

The shared template retains the following T3 context separately for launch-time attachment. Ordinary instruction files do not include it.

## T3 delegation

When delegating work in T3 Code, use T3 Code's `delegate_task` and related task tools instead of native subagent tools. This includes same-provider children and agents dispatched by skills, such as Compound Engineering (CE) scouts and reviewers.
For CE cross-model review, implementation, and reasoning elevation, replace its explicit acpx, provider CLI, and launcher-script instructions with T3 delegation. A CE call described as a shell-out rather than a subagent is still covered. Follow higher-priority host constraints.

Preserve CE's decisions about whether to delegate, provider selection, role, scope, access restrictions, output, and result validation. Choose the child's model and effort as the T3 CE model selection section says. Use T3 capability discovery to resolve the selected target and supported `target.options`. Give each child a self-contained brief with the required context, accessible workspace/artifact paths, and this routing policy. Authorize further delegation only when its assigned CE task requires it.

Use T3's task lifecycle in place of CE's process runners, polling, cancellation, and transport receipts. Do not run the legacy transport alongside a T3 task. Do not fabricate controller receipts or treat task completion as proof of CE validation or serving-model identity. Retain substantive scope, integration, and verification checks; if their contract cannot be satisfied, use CE's existing unavailable-route handling before starting incompatible transport machinery.

Keep CE's existing retry, recovery, inline fallback, skip, and reporting behavior. Any resulting delegation must still use T3; do not add a separate failure policy or approval step. A wait timeout does not mean the child stopped: follow T3's lifecycle and CE's recovery prerequisites before replacing work. Each `delegate_task` child is a separate T3 thread; do not create a top-level thread to delegate work.

## T3 CE model selection

When a CE skill delegates a child, choose the child's model from the ladder of the provider the child runs on. Each rung names a model family; use the newest listed model of that family from T3 capability discovery. A family named without `Flash` excludes Flash models.

| Provider | Orchestrator | Top child rung | Middle rung | Bottom rung |
| --- | --- | --- | --- | --- |
| Claude | Fable | Opus | Sonnet | Haiku |
| Codex | astra | sol | terra | luna |
| Synthetic through pi | Kimi | GLM | GLM Flash | DeepSeek Flash |
| Antigravity | Gemini Argon | Gemini Argon | Gemini Flash | Gemini Flash |

- Top child rung: reviewers that CE assigns to the session or parent model, such as `correctness-reviewer`, `security-reviewer`, and `adversarial-reviewer`, and CE's cross-model review peers.
- Middle rung: implementation workers, CE's mid-tier and generation-tier children, and any CE child whose skill names no tier.
- Bottom rung: CE's extraction-tier and cheapest-capable children, such as grounding scouts.

Where a CE skill says to inherit the session or parent model, or to omit the model override because model names are unknown, use the ladder instead. A child never runs above the column of the model that delegates it: a role placed higher runs on the delegating model, or on another provider's model in that same column. A child that delegates further applies these rules with its own model as the limit.

Set no effort for a ladder-selected child, so T3's default for that model applies. An effort that a CE skill suggests by default is not a named effort.

A model or effort that the user's prompt or CE configuration names for a child wins over this section; pass a named effort in `target.options`. CE configuration includes `cross_model_model`, `cross_model_effort`, `work_engine_preferences`, `work_engine_effort`, `plan_model`, and `brainstorm_model`.

If the catalog lists no model for a rung, use the next lower rung of the same provider. If none is listed, use the next higher rung of that provider within the limit above, and only then the delegating model. Name the substitution in your report. Providers without a row and delegations outside CE skills keep their current model selection.
