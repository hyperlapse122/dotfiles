# Agent routing

The ordinary user instruction files share scope and verification, web development, writing, and temporary-resource rules. They set no model or effort. Claude Code, Codex, Antigravity, Grok, and Pi each receive their own render.

For HTML, CSS, web UI, and browser-side JavaScript work, including web platform code inside frameworks, the shared instructions require `modern-web-guidance` first alongside other applicable design and framework skills. The upstream skill defines its trigger and exclusion rules. Nix pins the unchanged skill files; its `npx modern-web-guidance@latest` commands select the npm tool independently. CLI and T3 sessions receive this common rule through their normal baseline instruction paths.

The shared template retains the following T3 context separately for launch-time attachment. Ordinary instruction files do not include it.

## T3 delegation

When delegating work in T3 Code, use T3 Code's `delegate_task` and related task tools instead of native subagent tools. This includes same-provider children and agents dispatched by skills, such as Compound Engineering (CE) scouts and reviewers.
For CE cross-model review, implementation, and reasoning elevation, replace its explicit acpx, provider CLI, and launcher-script instructions with T3 delegation. A CE call described as a shell-out rather than a subagent is still covered. Follow higher-priority host constraints, such as permission denials. This routing takes precedence over T3 Code's own guidance to use a native subagent tool for same-provider children.

Preserve CE's decisions about whether to delegate, provider selection, role, scope, access restrictions, output, and result validation. Choose the child's model and effort as the T3 CE model selection section says. Use T3 capability discovery to resolve the selected target and supported `target.options`. Give each child a self-contained brief with the goal, completion standard, required context, and accessible workspace/artifact paths. Include this routing policy only for a child that delegates further. Add no prohibition the task does not need. Authorize further delegation only when its assigned CE task requires it.

Run `ce-code-review` and `ce-simplify-code` in your own context, and delegate only the reviewers and other leaves those skills dispatch; never hand either skill whole to a child. In the brief of a child that runs verification, tell it to wait for a slow command to finish and never to interrupt it. Tell every child that evidence this machine cannot produce, such as a Darwin build on Linux, is recorded as deferred to CI, never as passed, and does not make its return incomplete.

Use T3's task lifecycle in place of CE's process runners, polling, cancellation, and transport receipts. Do not run the legacy transport alongside a T3 task. Do not fabricate controller receipts or treat task completion as proof of CE validation or serving-model identity. The scope, integration, and verification checks a CE skill prescribes still apply under T3 transport; if their contract cannot be satisfied, use CE's existing unavailable-route handling before starting incompatible transport machinery.

These sessions disable the native subagent tool on purpose. Wherever a CE rule depends on whether a subagent tool is available, `delegate_task` is that tool. When it is deferred, load it and the related task tools through the host's tool discovery, such as ToolSearch, before concluding that no subagent is available. Take CE's inline fallback for missing subagents only when `delegate_task` is still unavailable or the delegation fails. This rule does not authorize further delegation: a child whose brief says to do the work itself still does it itself.

Keep CE's existing retry, recovery, inline fallback, skip, and reporting behavior. Any resulting delegation must still use T3; do not add a separate failure policy or approval step. A wait timeout does not mean the child stopped: follow T3's lifecycle and CE's recovery prerequisites before replacing work. Each `delegate_task` child is a separate T3 thread; do not create a top-level thread to delegate work.

## T3 CE model selection

When a CE skill delegates a child, choose the child's model from the ladder of the provider the child runs on. Each rung names a model family; use the newest listed model of that family from T3 capability discovery. A family named without `Flash` excludes Flash models.

| Provider | Orchestrator | Top child rung | Middle rung | Bottom rung |
| --- | --- | --- | --- | --- |
| Claude | Fable | Opus | Sonnet | Haiku |
| Codex | astra | sol | terra | luna |
| Synthetic through pi | Kimi | GLM | GLM Flash | DeepSeek Flash |
| Antigravity | Gemini Carbon | Gemini Carbon | Gemini Hydrogen | Gemini Hydrogen |

- Top child rung: reviewers that CE assigns to the session or parent model, such as `correctness-reviewer`, `security-reviewer`, and `adversarial-reviewer`, and CE's cross-model review peers.
- Middle rung: implementation workers, CE's mid-tier and generation-tier children, and any CE child whose skill names no tier.
- Bottom rung: CE's extraction-tier and cheapest-capable children, such as grounding scouts.

Where a CE skill says to inherit the session or parent model, or to omit the model override because model names are unknown, use the ladder instead. A child never runs above the column of the model that delegates it: a role placed higher runs on the delegating model, or on another provider's model in that same column. A child that delegates further applies these rules with its own model as the limit.

Set no effort for a ladder-selected child, so T3's default for that model applies. A Codex child is the exception: pass `reasoningEffort` `high` in `target.options`. An effort that a CE skill suggests by default is not a named effort.
For a middle-rung Codex implementation worker, pass `reasoningEffort` `xhigh` instead; every other Codex child's effort stays `high`.

A model or effort that the user's prompt or CE configuration names for a child wins over this section; pass a named effort in `target.options`. CE configuration includes `cross_model_model`, `cross_model_effort`, `work_engine_preferences`, `work_engine_effort`, `plan_model`, and `brainstorm_model`.

If the catalog lists no model for a rung, use the next lower rung of the same provider. If none is listed, use the next higher rung of that provider within the limit above, and only then the delegating model. Name the substitution in your report. Providers without a row and delegations outside CE skills keep their current model selection.

### Gemini selection evidence

On 2026-11-14, each setting below ran the same repository-grounding and Python settings-repair task twice in fresh T3 child threads, one at a time. Completion time runs from T3's `startedAt` to `completedAt`, including tool use and answer generation. A repair passes only when all 16 behavioral checks pass. All ten runs completed normally and answered the four grounding questions correctly.

| Requested model and thinking level | Completion times (seconds) | Repairs passing all 16 checks |
| --- | --- | --- |
| Gemini 4 Carbon high | 260.7, 262.0 | 2/2 |
| Gemini 4 Argon high | 40.4, 48.7 | 0/2 |
| Gemini 3.8 Flash high | 47.4, 51.6 | 0/2 |
| Gemini 4 Hydrogen high | 51.0, 50.9 | 1/2 |
| Gemini 4 Hydrogen xhigh | 58.8, 76.7 | 1/2 |

The repairs that failed changed their result on a second application when a managed object replaced a scalar and defaults supplied sibling keys. That check was added after the first outputs exposed the gap, then applied to every repair without changing the task prompt. These are two samples of one bounded task, not estimates of general accuracy or failure rates; long-running orchestration and full diff reviews were not measured. T3 recorded the requested models and options, but supplied no independent serving-model attestation. Token use and subscription consumption were not measured.

The results support trying Carbon for planning and demanding reviews, where its longer completion time can be acceptable, and Hydrogen for implementation and extraction. Hydrogen high took about as long as Flash in this task; xhigh took longer without increasing the number of fully passing repairs. The ladder keeps effort unset for Antigravity children; the discovered T3 default was high for both Carbon and Hydrogen. An explicit xhigh request still takes precedence. Google's [Carbon model card](https://deepmind.google/models/model-cards/gemini-4-carbon/) describes long-horizon reasoning, while the [Hydrogen model card](https://deepmind.google/models/model-cards/gemini-4-hydrogen/) describes rapid execution and sub-agent use.

The first Hydrogen xhigh request was rejected before launch because T3 listed only low, medium, and high. After the error, a fresh capability lookup listed xhigh and both measured xhigh runs launched successfully. The rejected preflight is excluded from the table. Refresh capability evidence after a rejection before concluding that a UI-visible option is unavailable.

## Native T3 launches

`home/h82/t3code.nix` merges the captured server and client preferences into writable T3 settings. New threads use Codex `gpt-6.1-sol` at xhigh effort, with Claude Opus 5.5 as fallback and `gpt-6-luna` for text generation. Threads start with full access in a worktree. Inactive worktree cleanup uses five days. The interface uses Pretendard Variable; code and terminals use Jetendard. Baseline-only settings remain declared unless the overlay replaces them, and unrelated user settings survive application.

Claude, Codex, and Pi share their normal homes, credentials, plugins, and baseline instruction files with CLI sessions. Activation renders only the template's T3 branch into private files under `~/.t3/userdata/instructions/`. The launch composer passes Claude `--append-system-prompt-file`, Codex `-c developer_instructions=...`, and Pi `--append-system-prompt`. Existing append options and Codex developer instructions are composed with the addition. Claude append-file paths must be absolute. Reapply after changing those files or native Codex developer instructions; their contents are captured during application. The private `dotfiles-launch-state.json` tracks contributions so repeated application preserves unrelated argument and environment edits. CLI launches receive the baseline only.

Claude uses idle compaction before the cache expires and denies the native `Agent` tool. Codex disables `multi_agent`, `multi_agent_v2`, and `multi_agent_v2_dynamic_tools`; Grok receives `GROK_SUBAGENTS=0`. These controls apply to T3 launches. Pi uses the managed package in the shared user profile, with its `default` model hidden while preserving other hidden choices. Antigravity sessions in T3 Code run the ACP runtime that `packages/antigravity-acp.nix` rebuilds, not the one T3 Code downloads. The rebuild adds the shared instructions, read from the rule files in `~/.gemini/config/rules/`, in front of the client's system prompt addition, and receives the skills of every pinned plugin from one store directory, including for Compound Engineering run homes. Those plugin skills are also linked into `~/.gemini/antigravity-cli/skills`, which T3 Code scans for its Antigravity skill menu. T3 Code's `antigravity` driver accepts no per-launch prompt option, so the T3-only branch does not reach these sessions. The retired third-party Antigravity adapter is removed only when its command path matches the old managed adapter; a custom adapter under that ID causes a refusal.

T3 cannot enforce a read-only delegate. A read-only brief or worktree isolation does not supply that guarantee; CE workflows requiring enforced read-only access use their existing unavailable-route handling. The T3 Code 0.1.7 Grok driver accepts no prompt addition, so Grok receives no T3 instruction addition. Its native baseline still loads.

Close T3 before applying and relaunch it afterward. Repository checks execute the rendered activation and inspect launch arguments and instruction files. They do not establish authenticated provider requests, model compliance, or native macOS behavior.

## Pi tools and project trust

The Pi package builds pinned upstream source with the committed Synthetic model lock compiled into its runtime. Its fixed-hash source fetch lets Nix read package metadata and dependency locks without building a derivation during evaluation. Project settings, extension registrations, refreshes, and reloads cannot add models or replace their locked routes through Pi's supported APIs. The policy extension diagnoses invalid restored sessions. Trusted extensions still execute arbitrary JavaScript as the user; the model lock does not sandbox that code.

The shared `~/.pi/agent/` contains the repository-owned `question`, `web_search`, and `web_fetch` extensions. Questions use native select and input dialogs, with distinct cancellation, empty-answer, and unavailable-UI results. Web tools use Exa and return bounded source content with URLs for citations. Page content is untrusted input.

The wrapper clears inherited `EXA_API_KEY` and exports only `DOTFILES_PI_EXA_KEY_FILE`, pointing to the existing published `exa_api_key`. The extension reads the file on each call. It does not copy the key into Pi settings, authentication, arguments, or subprocess environments. A missing key disables web calls without preventing Pi or questions from working. Trusted extensions can still read files accessible to the user.

T3's launch composer adds `--approve` for Pi and preserves user-added arguments through its ownership ledger. Approval applies to that run and does not update remembered project decisions. Terminal Pi uses native per-project trust prompts, preserving previous decisions. T3 project resources and web queries carry the code-execution and disclosure risks accepted in issue [#139](https://github.com/hyperlapse122/dotfiles/issues/139).

Repository checks exercise materialized files for both host kinds, packaged CLI and SDK model paths, native RPC dialogs, subprocess environments, and project skill discovery. These checks use fake credentials. They do not establish the live T3 dialog experience, signed-in Exa calls, or either host's installed generation; those require post-switch evidence from the owner.
