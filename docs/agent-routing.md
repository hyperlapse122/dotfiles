# Agent routing

The ordinary user instruction files share scope and verification, issue linking in pull and merge requests, web development, writing, language, and temporary-resource rules. They set no model or effort. Claude Code, Codex, Antigravity, Grok, and Pi each receive their own render.

The language rules make Korean the default conversation language and English the default for artifacts such as documents, code comments, and commit messages. A language named in the conversation or the project's instructions, or the language of existing content, takes precedence for artifacts. Claude Code's render leaves out the conversation rule because its `language` setting already sets the conversation language; it keeps the artifact rule.

For HTML, CSS, web UI, and browser-side JavaScript work, including web platform code inside frameworks, the shared instructions require `modern-web-guidance` first alongside other applicable design and framework skills. The upstream skill defines its trigger and exclusion rules. Nix pins the unchanged skill files; its `npx modern-web-guidance@latest` commands select the npm tool independently. CLI and T3 sessions receive this common rule through their normal baseline instruction paths.

The shared template retains the following T3 context separately for launch-time attachment. Ordinary instruction files do not include it.

## T3 delegation

When delegating work in T3 Code, use T3 Code's `delegate_task` and related task tools instead of native subagent tools. This includes same-provider children and agents dispatched by skills, such as Compound Engineering (CE) scouts and reviewers.
For CE cross-model review, implementation, and reasoning elevation, replace its explicit acpx, provider CLI, and launcher-script instructions with T3 delegation. A CE call described as a shell-out rather than a subagent is still covered. Follow higher-priority host constraints, such as permission denials. This routing takes precedence over T3 Code's own guidance to use a native subagent tool for same-provider children.

Preserve CE's decisions about whether to delegate, provider selection, role, scope, access restrictions, output, and result validation. Choose the child's model and effort as the T3 CE model selection section says. Use T3 capability discovery to resolve the selected target and supported `target.options`. Give each child a self-contained brief with the goal, completion standard, required context, and accessible workspace/artifact paths. Include this routing policy only for a child that delegates further. Add no prohibition the task does not need. Authorize further delegation only when its assigned CE task requires it.

Run `ce-code-review` and `ce-simplify-code` in your own context, and delegate only the reviewers and other leaves those skills dispatch; never hand either skill whole to a child. In the brief of a child that runs verification, tell it to wait for a slow command to finish and never to interrupt it. Tell every child that evidence this machine cannot produce, such as a Darwin build on Linux, is recorded as deferred to CI, never as passed, and does not make its return incomplete.

Use T3's task lifecycle in place of CE's process runners, polling, cancellation, and transport receipts. Do not run the legacy transport alongside a T3 task. Do not fabricate controller receipts or treat task completion as proof of CE validation or serving-model identity. The scope, integration, and verification checks a CE skill prescribes still apply under T3 transport; if their contract cannot be satisfied, use CE's existing unavailable-route handling before starting incompatible transport machinery.

Use `delegate_task` regardless of whether native subagent tools are visible. Wherever a CE rule depends on whether a subagent tool is available, `delegate_task` is that tool. When it is deferred, load it and the related task tools through the host's tool discovery, such as ToolSearch, before concluding that no subagent is available. Take CE's inline fallback for missing subagents only when `delegate_task` is still unavailable or the delegation fails. This rule does not authorize further delegation: a child whose brief says to do the work itself still does it itself.

Keep CE's existing retry, recovery, inline fallback, skip, and reporting behavior. Any resulting delegation must still use T3; do not add a separate failure policy or approval step. A wait timeout does not mean the child stopped: follow T3's lifecycle and CE's recovery prerequisites before replacing work. Each `delegate_task` child is a separate T3 thread; do not create a top-level thread to delegate work.

## T3 CE model selection

When a CE skill delegates a child, choose the child's model from the ladder of the provider the child runs on. Each rung names a model family; use the newest listed model of that family from T3 capability discovery. A family named without `Flash` excludes Flash models, and a family named with `Pro` includes only Pro models.

| Provider | Orchestrator | Top child rung | Middle rung | Bottom rung |
| --- | --- | --- | --- | --- |
| Claude | Fable | Opus | Sonnet | Haiku |
| Codex | astra | sol | terra | luna |
| Synthetic through pi | Kimi | Kimi Pro | GLM | GLM Flash |
| Antigravity | Gemini Carbon | Gemini Hydrogen | Gemini Hydrogen | Gemini Hydrogen |

- Top child rung: reviewers that CE assigns to the session or parent model, such as `correctness-reviewer`, `security-reviewer`, and `adversarial-reviewer`, and CE's cross-model review peers.
- Middle rung: implementation workers, CE's mid-tier and generation-tier children, and any CE child whose skill names no tier.
- Bottom rung: CE's extraction-tier and cheapest-capable children, such as grounding scouts.

Where a CE skill says to inherit the session or parent model, or to omit the model override because model names are unknown, use the ladder instead. A child never runs above the column of the model that delegates it: a role placed higher runs on the delegating model, or on another provider's model in that same column. A child that delegates further applies these rules with its own model as the limit.

Set no effort for a ladder-selected child, so T3's default for that model applies. A Codex child is the exception: pass `reasoningEffort` `high` in `target.options`. An effort that a CE skill suggests by default is not a named effort.
For a middle-rung Codex implementation worker, pass `reasoningEffort` `xhigh` instead; every other Codex child's effort stays `high`.
An Antigravity child is also an exception: pass `thinking_level` `xhigh` for a top-rung child, `high` for a middle-rung child, and `medium` for a bottom-rung child in `target.options`.

T3 Code lists a Gemini model's `thinking_level` values only after a session on that model has run, so Gemini Hydrogen can lack `xhigh` in `orchestrator_capabilities`, and `delegate_task` rejects a value the list lacks. When a child needs Hydrogen at `xhigh` and the list lacks it, refresh the list yourself without asking the user: start one probe child on Gemini Hydrogen at the lowest listed `thinking_level`, or with no options when none is listed, with `mode` `wait` and a task that only replies `OK`, then call `orchestrator_capabilities` again. Delegate at `xhigh` when it is now listed; otherwise delegate at the highest listed level and name the substitution in your report, as for a missing model.

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

The results support trying Carbon for planning and demanding reviews, where its longer completion time can be acceptable, and Hydrogen for implementation and extraction. Hydrogen high took about as long as Flash in this task; xhigh took longer without increasing the number of fully passing repairs. At the time, the ladder left Antigravity effort unset and the discovered T3 default was high for both Carbon and Hydrogen. Google's [Carbon model card](https://deepmind.google/models/model-cards/gemini-4-carbon/) describes long-horizon reasoning, while the [Hydrogen model card](https://deepmind.google/models/model-cards/gemini-4-hydrogen/) describes rapid execution and sub-agent use.

The first Hydrogen xhigh request was rejected before launch because T3 listed only low, medium, and high. After the error, a fresh capability lookup listed xhigh and both measured xhigh runs launched successfully. The rejected preflight is excluded from the table. T3 Code's server explains the gap: it records a Gemini model's `thinking_level` values only from a session on that model, and gives a model it has not observed the current session model's list. A rejected option does not refresh that list, so the T3 instructions start a short Hydrogen probe child to record Hydrogen's levels before delegating at xhigh.

### Antigravity and Synthetic ladder evidence

On 2026-11-16 the owner retuned the Antigravity and Synthetic rows against the Artificial Analysis Intelligence Index v5.0.1 chart dated 15 Nov '26, which covered the models this machine can reach. No new local benchmark ran for this change.

| Rung | Before | After | AA score after (before) | Local timing |
| --- | --- | --- | --- | --- |
| Antigravity top | Gemini 4 Carbon high | Gemini 4 Hydrogen xhigh | 54 (60) | 58.8 s, 76.7 s on the 2026-11-14 task (Carbon: 260.7 s, 262.0 s) |
| Antigravity middle | Gemini 4 Hydrogen at the T3 default | Gemini 4 Hydrogen high | 51 (54 at xhigh) | 51.0 s, 50.9 s on the 2026-11-14 task |
| Antigravity bottom | Gemini 4 Hydrogen at the T3 default | Gemini 4 Hydrogen medium | 41 (54 at xhigh) | Not measured |
| Synthetic top | GLM-5.3 | Kimi K3.1 Pro | 46 (32 at max) | Not measured; Kimi K3 high took 10-14 min as a review peer on 2026-10-21 |
| Synthetic middle | GLM-5.3 Flash | GLM-5.3 | 32 at max (28) | Not measured at Pi's default; 24-25 min at max and 20.5 min at high as a review peer on 2026-10-21 |
| Synthetic bottom | DeepSeek V4.1 Flash 1017 | GLM-5.3 Flash | 28 (29 at high) | 10-19 min at high as a review peer on 2026-10-21 (DeepSeek: 48 min at max, 101 min at high) |

By 2026-11-16 T3 listed xhigh as Hydrogen's default `thinking_level`, so middle and bottom children that left effort unset had been running at xhigh. The ladder now names each Antigravity level, so a later change to that default does not move it. Synthetic children keep effort unset: Pi lists `thinking` levels only up to high, so the chart's max scores are upper bounds, not the configured setting. The Synthetic middle rung trades GLM-5.3 Flash's speed for GLM-5.3's higher score, and the bottom rung drops DeepSeek, the slowest Synthetic model measured.

## T3 PR and MR babysitting

When `ce-babysit-pr` runs in T3 Code, directly or through another skill, use `watch_pull_request` and `unwatch_pull_request` for its watch lifecycle. This replaces `pr-snapshot watch`, CLI `--watch` commands, polling loops, background detectors, and scheduled wakeups. Keep `gh` for GitHub and `glab` for GitLab reads and authorized mutations.

Handle existing feedback and failures before the first wait, and refresh the target before waiting again so work arriving during a tick is handled. Arm the T3 watch with the full PR or MR URL and end the turn. It stays active across wakes and pushes; resume the skill's tick on fresh state without re-arming unless T3 reports that the watch stopped. Call `unwatch_pull_request` at a true stop, when changing the watched target, or before handing the work back to the user.

Resolve the forge from the target URL or repository remote. Apply the babysit workflow to GitHub PRs and GitLab MRs; for GitLab, replace the GitHub-only entry gates in `ce-babysit-pr` and its delegated skills with the corresponding GitLab operations. Use `glab mr` and `glab api` for state, logs, replies, discussion resolution, and authorized changes.

For GitLab, replace GitHub-only snapshot and feedback helpers with fresh reads of the head SHA, discussions and notes with their revisions, pipelines and jobs, approvals, mergeability, and base and branch state. Persist feedback IDs and source revisions, head-scoped CI marks and action claims, typed feedback decisions, and residuals across T3 wakes. Pass the relevant state and this forge substitution to delegated feedback and CI work.

The watcher supplies wakeups; the skill still owns feedback-before-CI ordering, stale-head handling, action claims, readiness, budgets, and mutation authority. Preserve those rules with forge-equivalent evidence and operations, including positively confirmed stack management where required. Report a required evidence or operation gap as a blocker rather than treating it as satisfied or dropping the rule.

## T3 multi-PR threads

T3 Code auto-settles a thread once all of its linked pull requests have merged, which can happen between one merge and the next pull request of a multi-PR plan. When the plan for a task has more than one pull or merge request, pin the thread with `t3_thread_organize` (`action: pin`) when you create the first one. Auto-settle skips pinned threads; settling or snoozing does not keep the thread active. After the last planned pull or merge request merges, unpin the thread (`action: unpin`), but only if you pinned it. T3 Code does not report whether a thread is already pinned, so leave it pinned when the user says they pinned it. When you hand the work back while planned pull or merge requests remain, leave the thread pinned and say so in your report.

## T3 visual options

When a skill such as `ce-brainstorm` or `ce-prototype` presents visual options, create wireframes directly without asking whether to use text or a visual. This standing preference overrides a skill's per-decision text-versus-visual opt-in.

Write self-contained HTML and use T3 Code's `html_preview` followed by `html_render` to show the options inline in the current thread. Use this display path instead of the skill's local display server for these comparisons. After showing the options, collect the user's choice or revisions through the normal question tool or chat.

When a prototype question depends on visual finish or hands-on interaction, preserve the fidelity and interaction needed to answer it.

## Native T3 launches

`home/h82/t3code.nix` merges the captured server and client preferences into writable T3 settings. New threads use Codex `gpt-6.1-sol` at xhigh effort, with Claude Opus 5.5 as fallback and `gpt-6-luna` for text generation. Threads start with full access in a worktree. Inactive worktree cleanup uses five days. The interface uses Pretendard Variable; code and terminals use Jetendard. Baseline-only settings remain declared unless the overlay replaces them, and unrelated user settings survive application.

Claude, Codex, Pi, and Grok share their normal homes, credentials, plugins, and baseline instruction files with CLI sessions. Activation renders only the template's T3 branch into private files under `~/.t3/userdata/instructions/`. The launch composer passes Claude `--append-system-prompt-file`, Codex `-c developer_instructions=...`, and Pi `--append-system-prompt`. Existing append options and Codex developer instructions are composed with the addition. Claude append-file paths must be absolute. Reapply after changing those files or native Codex developer instructions; their contents are captured during application. The private `dotfiles-launch-state.json` tracks contributions so repeated application preserves unrelated argument and environment edits. CLI launches receive the baseline only.

Grok's T3 provider uses `config.binaryPath` to select the packaged `t3-grok-instructions` adapter. It reads `~/.t3/userdata/instructions/grok.md` for each ACP `session/prompt` and adds one embedded text resource with URI `t3-instructions://dotfiles/grok`. This supplies current context to new, loaded, and resumed sessions, including delegated children, without changing the original text, native command arguments, T3 instruction blocks, or session setup metadata. It replaces only its own resource when a request already contains it. A missing, empty, or unreadable addition stops task forwarding. The adapter forwards other protocol traffic and runs the normal packaged Grok with the original arguments and home; ordinary CLI launches use that Grok directly. Historical prompts retain their original context. The addition is prompt context, not a system-prompt replacement or a guarantee of model compliance.

Claude uses idle compaction before the cache expires and denies the native `Agent` tool. Codex disables `multi_agent`, `multi_agent_v2`, and `multi_agent_v2_dynamic_tools`; Grok receives `GROK_SUBAGENTS=0`. These controls apply to T3 launches. The rebuilt Antigravity ACP runtime disables its built-in `start_subagent` tool, and with it the browser subagent, in every session whatever client starts it. Pi uses the managed package in the shared user profile, with its `default` model hidden while preserving other hidden choices. Antigravity sessions in T3 Code run the ACP runtime that `packages/antigravity-acp.nix` rebuilds, not the one T3 Code downloads. The rebuild adds the shared instructions, read from the rule files in `~/.gemini/config/rules/`, in front of the client's system prompt addition, and receives the skills of every pinned plugin from one store directory, including for Compound Engineering run homes. Those plugin skills are also linked into `~/.gemini/antigravity-cli/skills`, which T3 Code scans for its Antigravity skill menu. The retired third-party Antigravity adapter is removed only when its command path matches the old managed adapter; a custom adapter under that ID causes a refusal.

The repository-managed `antigravity` provider receives its T3 addition through `ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE`, reconciled by `scripts/t3-instructions.py` to the absolute path of `~/.t3/userdata/instructions/antigravity.md`. T3 Code 0.1.9 passes provider environment entries to the ACP runtime even though its Antigravity driver exposes no native prompt option. The overlay composes baseline rules, the selected file, and the client's system prompt addition in that order. An explicitly selected unreadable file fails prompt assembly. The shared wrapper supplies no T3 file by default, so `agy` CLI and non-T3 ACP launches keep the baseline only. Reapplication replaces the owned environment entry while preserving other entries and settings; owner-created provider instances retain their own configuration.

Antigravity CLI and ACP both receive `allowNonWorkspaceAccess = true` through their mutable user settings. The ACP wrapper supplies `ANTIGRAVITY_ACP_SHARED_SETTINGS_FILE`, defaulting to `~/.gemini/antigravity-acp/settings.json`, so T3 provider instance homes and CE private run homes receive the same access setting while retaining their own authentication and conversations. An explicit shared-file path takes precedence; without one, the runtime reads its current ACP settings file.

The ACP server overlay applies the boolean setting to native harness containment, native `view_file`, and the client file tools. Enabling it permits reads and edits outside workspace folders in every session mode, while the existing approval policies still decide whether commands and file changes need approval. Workspace metadata stays intact. A false, absent, malformed, or unreadable setting keeps the runtime's existing workspace boundary.

T3 cannot enforce a read-only delegate. A read-only brief or worktree isolation does not supply that guarantee; CE workflows requiring enforced read-only access use their existing unavailable-route handling. T3 Code 0.1.9's Grok driver accepts no prompt addition, so the Grok adapter uses the supported binary-path setting and ACP prompt context instead.

Close T3 before applying and relaunch it afterward. Repository checks execute the rendered activation and inspect launch arguments and instruction files. The Grok adapter package also runs its pinned Grok against a local API fixture with fake credentials and inspects the model input for fresh, loaded, resumed, cold-loaded, skill, and post-compact tasks. These checks establish instruction delivery through that runtime path; they do not establish signed-in provider behavior, model compliance, or the T3 desktop experience on either host.

## Pi tools and project trust

The Pi package builds pinned upstream source with the committed Synthetic model lock compiled into its runtime. Its fixed-hash source fetch lets Nix read package metadata and dependency locks without building a derivation during evaluation. Project settings, extension registrations, refreshes, and reloads cannot add models or replace their locked routes through Pi's supported APIs. The policy extension diagnoses invalid restored sessions. Trusted extensions still execute arbitrary JavaScript as the user; the model lock does not sandbox that code.

The shared `~/.pi/agent/` contains the repository-owned `question`, `web_search`, and `web_fetch` extensions. Questions use native select and input dialogs, with distinct cancellation, empty-answer, and unavailable-UI results. Web tools use Exa and return bounded source content with URLs for citations. Page content is untrusted input.

The wrapper clears inherited `EXA_API_KEY` and exports only `DOTFILES_PI_EXA_KEY_FILE`, pointing to the existing published `exa_api_key`. The extension reads the file on each call. It does not copy the key into Pi settings, authentication, arguments, or subprocess environments. A missing key disables web calls without preventing Pi or questions from working. Trusted extensions can still read files accessible to the user.

T3's launch composer adds `--approve` for Pi and preserves user-added arguments through its ownership ledger. Approval applies to that run and does not update remembered project decisions. Terminal Pi uses native per-project trust prompts, preserving previous decisions. T3 project resources and web queries carry the code-execution and disclosure risks accepted in issue [#139](https://github.com/hyperlapse122/dotfiles/issues/139).

Repository checks exercise materialized files for both host kinds, packaged CLI and SDK model paths, native RPC dialogs, subprocess environments, and project skill discovery. These checks use fake credentials. They do not establish the live T3 dialog experience, signed-in Exa calls, or either host's installed generation; those require post-switch evidence from the owner.
