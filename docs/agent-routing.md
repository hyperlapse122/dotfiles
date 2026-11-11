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

## Native T3 launches

`home/h82/t3code.nix` merges the captured server and client preferences into writable T3 settings. New threads use Codex `gpt-6.1-sol` at high effort, with Claude Opus 5.5 as fallback and `gpt-6-luna` for text generation. Threads start with full access in a worktree. Inactive worktree cleanup uses five days. The interface uses Pretendard Variable; code and terminals use Jetendard. Baseline-only settings remain declared unless the overlay replaces them, and unrelated user settings survive application.

Claude, Codex, and Pi share their normal homes, credentials, plugins, and baseline instruction files with CLI sessions. Activation renders only the template's T3 branch into private files under `~/.t3/userdata/instructions/`. The launch composer passes Claude `--append-system-prompt-file`, Codex `-c developer_instructions=...`, and Pi `--append-system-prompt`. Existing append options and Codex developer instructions are composed with the addition. Claude append-file paths must be absolute. Reapply after changing those files or native Codex developer instructions; their contents are captured during application. The private `dotfiles-launch-state.json` tracks contributions so repeated application preserves unrelated argument and environment edits. CLI launches receive the baseline only.

Claude uses idle compaction before the cache expires and denies the native `Agent` tool. Codex disables `multi_agent`, `multi_agent_v2`, and `multi_agent_v2_dynamic_tools`; Grok receives `GROK_SUBAGENTS=0`. These controls apply to T3 launches. Pi uses the restored package in the shared user profile, with its `default` model hidden while preserving other hidden choices. Antigravity sessions in T3 Code run the ACP runtime that `packages/antigravity-acp.nix` rebuilds, not the one T3 Code downloads. The rebuild adds the shared instructions, read from the rule files in `~/.gemini/config/rules/`, in front of the client's system prompt addition, and lists the skills of every pinned plugin from one store directory. T3 Code's `antigravity` driver accepts no per-launch prompt option, so the T3-only branch does not reach these sessions. The retired third-party Antigravity adapter is removed only when its command path matches the old managed adapter; a custom adapter under that ID causes a refusal.

T3 cannot enforce a read-only delegate. A read-only brief or worktree isolation does not supply that guarantee; CE workflows requiring enforced read-only access use their existing unavailable-route handling. The T3 Code 0.1.7 Grok driver accepts no prompt addition, so Grok receives no T3 instruction addition. Its native baseline still loads.

Close T3 before applying and relaunch it afterward. Repository checks execute the rendered activation and inspect launch arguments and instruction files. They do not establish authenticated provider requests, model compliance, or native macOS behavior.
