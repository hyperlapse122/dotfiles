# Agent routing

The ordinary user instruction files share scope and verification, issue linking in pull and merge requests, web development, writing, language, and temporary-resource rules. They set no model or effort. Claude Code, Codex, Pi, and OpenCode each receive their own render; OpenCode's is the shared base render with no branch of its own.

The shared instructions call for one `decide` judgment during CI triage when the failure evidence leaves multiple plausible read-only checks and the answer would change which check runs first. The agent verifies the suggested lead and continues the investigation if the tool yields no usable answer. [Decide MCP tool](decide.md#use-the-mcp-tool)

The language rules make Korean the default conversation language and English the default for artifacts such as documents, code comments, and commit messages. A language named in the conversation or the project's instructions, or the language of existing content, takes precedence for artifacts. Claude Code's render leaves out the conversation rule because its `language` setting already sets the conversation language; it keeps the artifact rule.

For HTML, CSS, web UI, and browser-side JavaScript work, including web platform code inside frameworks, the shared instructions require `modern-web-guidance` first alongside other applicable design and framework skills. The upstream skill defines its trigger and exclusion rules. Nix pins the unchanged skill files; its `npx modern-web-guidance@latest` commands select the npm tool independently. CLI and T3 sessions receive this common rule through their normal baseline instruction paths.

Nix installs `untangle-codebase` and `prune-tests` in all four user skill roots. The shared instructions direct agents to read `untangle-codebase` for structural refactoring and `prune-tests` alongside `test-audit` for test audits and cleanup. `untangle-codebase` retains the upstream model-invocation opt-out. Agents can read its criteria directly within the scope of the request.

Shared Home Manager configuration installs [acpx](../packages/acpx.nix) on both NixOS and macOS. The package honors user-level `~/.acpx/config.json` and skips project-local `.acpxrc.json` when resolving configuration.

The shared template retains the following T3 context separately for launch-time attachment. Ordinary instruction files do not include it.

## Decide for subagent roles

Once a workflow has decided to delegate, the parent uses the role selector on the existing launch route. A required role or a sole eligible role goes directly to the launcher. With two or more eligible roles, the parent asks `judge` once using `choice` and passes the selected role to the launcher. The existing selection path handles sessions without a role choice and any unavailable or unusable judgment.

The parent checks role purpose, conditions, tools, and compatibility with required launch settings before asking. Claude Code starts with the pinned catalog at `~/.local/share/nix-config/claude-code-agents.json` and applies the session's effective definitions. The request contains a short task summary and eligible role descriptions that the configured backend may receive. It includes an `insufficient_evidence` option. [Pinned catalog](../packages/claude-code-agents.json) · [Decide backends](decide.md#backends-and-models)

A Claude Code `fork` uses the parent's model and full conversation. It qualifies only when the workflow permits those effective settings. [Claude Code fork behavior](https://code.claude.com/docs/en/sub-agents#how-forks-differ-from-other-subagents)

T3 0.1.9's `delegate_task` applies its `role` as guidance in the child prompt. Provider, model, effort, and tool access come from the launch route. A native launch inside T3 uses the harness's own selector when available. [T3 child prompt construction](https://github.com/pingdotgg/t3code/blob/v0.1.9/apps/server/src/mcp/delegatedTaskModes.ts#L90-L94)

### Session checks

These checks used the pinned harnesses, staged policy, synthetic Markdown fixtures, and local MLX judgments on macOS. Role availability depends on the active launch tool and session permissions.

| Harness | Standalone | Managed T3 Code |
| --- | --- | --- |
| Claude Code | The parent sent `Explore` and `general-purpose` for a native file lookup. `judge` chose `Explore`, and the launch passed `subagent_type: Explore`. | The native planning task sent `Plan` and `general-purpose`. `judge` chose `Plan`, and the launch passed `subagent_type: Plan`. |
| Codex | The tested `spawn_agent` exposed no role selector. It launched through its default path without judgment. | The tested native tool exposed no role selector. On a task routed to `delegate_task`, `judge` chose `research` from `general` and `research`, and the launch passed `role: research`. |
| Pi | Pi has no configured subagents or native role selector. | On a task routed to `delegate_task`, `judge` chose `research` from `general` and `research`, and the launch passed `role: research`. |

Each recorded judgment included `insufficient_evidence`. Claude also launched a required `Explore` role and a sole eligible `Explore` role without judgment. When the session denied the MCP call, Claude used its default selection path and completed the task.

## T3 delegation

Follow T3 Code's orchestration guidance when choosing a delegation tool. Use a provider's native tool for same-provider foreground work when it can carry the required model, settings, and access. Use `delegate_task` for another provider, a worktree, background work, or a task that requests it.
For CE cross-model review, implementation, and reasoning elevation, use T3 delegation in place of explicit acpx, provider CLI, and launcher-script calls. A CE call described as a shell-out is still covered.

Preserve CE's decisions about whether to delegate, provider selection, role, scope, access restrictions, output, and result validation. The cross-model review exception below applies to access restrictions only. For T3 delegation, choose the child's model and effort as the T3 CE model selection section says and use T3 capability discovery to resolve the target and supported `target.options`. Give each child a self-contained brief with the goal, completion standard, required context, and accessible workspace or artifact paths. Include delegation guidance for children that need it.

CE cross-model review peers (`ce-doc-review`, `ce-code-review`, and similar skills) require an isolated process: an empty workspace, read-only controls, restricted tool access, and no project context or MCP servers. `delegate_task` cannot enforce that isolation, and the owner accepts the risk. Never skip, downgrade, or declare a peer unavailable because the isolation cannot be provided. Run the peer through `delegate_task` with normal workspace and tool access, a self-contained brief that carries the reviewed material, and an instruction not to modify files. State in the review's coverage that isolation was not enforced. This waives only the isolation: the disclosure of what leaves the machine, an explicit user prohibition on external review, `cross_model_review_mode: off`, and CE's allowlist and route choice still apply.

Run `ce-code-review` and `ce-simplify-code` in your own context, and delegate only the reviewers and other leaves those skills dispatch; never hand either skill whole to a child. In the brief of a child that runs verification, tell it to wait for a slow command to finish and never to interrupt it. Tell every child that evidence this machine cannot produce, such as a Darwin build on Linux, is recorded as deferred to CI, never as passed, and does not make its return incomplete.

For tasks started through T3, use its lifecycle in place of CE's process runners, polling, cancellation, and transport receipts. Do not run the legacy transport alongside a T3 task. Do not fabricate controller receipts or treat task completion as proof of CE validation or serving-model identity. The scope, integration, and verification checks a CE skill prescribes still apply under T3 transport; if their contract cannot be satisfied for a reason other than the waived isolation, use CE's existing unavailable-route handling before starting incompatible transport machinery.

Discover eligible tools for the route the task needs, including deferred tools. Follow CE's unavailable-route handling when the route is unavailable or fails. Keep CE's retry, recovery, fallback, and reporting behavior. A T3 wait timeout does not mean the child stopped. Follow T3's lifecycle and CE's recovery prerequisites before replacing work. Each `delegate_task` child is a separate T3 thread.

## T3 CE model selection

When a CE skill uses `delegate_task`, choose the child's model from the ladder of the provider the child runs on. Each rung names a model family; use the newest listed model of that family from T3 capability discovery. A family named without `Flash` excludes Flash models, and a family named with `Pro` includes only Pro models.

| Provider | Orchestrator | Top child rung | Middle rung | Bottom rung |
| --- | --- | --- | --- | --- |
| Claude | Fable | Opus | Sonnet | Haiku |
| Codex | astra | sol | terra | luna |
| Synthetic through pi | Kimi | Kimi Pro | GLM | GLM Flash |

- Top child rung: reviewers that CE assigns to the session or parent model, such as `correctness-reviewer`, `security-reviewer`, and `adversarial-reviewer`, and CE's cross-model review peers.
- Middle rung: implementation workers, CE's mid-tier and generation-tier children, and any CE child whose skill names no tier.
- Bottom rung: CE's extraction-tier and cheapest-capable children, such as grounding scouts.

Where a CE skill says to inherit the session or parent model, or to omit the model override because model names are unknown, use the ladder instead. A child never runs above the column of the model that delegates it: a role placed higher runs on the delegating model, or on another provider's model in that same column. A child that delegates further applies these rules with its own model as the limit.

Set no effort for a ladder-selected child, so T3's default for that model applies. An effort that a CE skill suggests by default is not a named effort.
For a Codex child, pass `reasoningEffort` in `target.options`: use `xhigh` for every Terra child regardless of role and for every middle-rung implementation worker; use `high` for other Codex children.

A model or effort that the user's prompt or CE configuration names for a child wins over this section; pass a named effort in `target.options`. CE configuration includes `cross_model_model`, `cross_model_effort`, `work_engine_preferences`, `work_engine_effort`, `plan_model`, and `brainstorm_model`.

If the catalog lists no model for a rung, use the next lower rung of the same provider. If none is listed, use the next higher rung of that provider within the limit above, and only then the delegating model. Name the substitution in your report. Providers without a row and delegations outside CE skills keep their current model selection.

### Synthetic ladder evidence

On 2026-11-16 the owner retuned the Synthetic row against the Artificial Analysis Intelligence Index v5.0.1 chart dated 15 Nov '26, which covered the models this machine can reach. No new local benchmark ran for this change.

| Rung | Before | After | AA score after (before) | Local timing |
| --- | --- | --- | --- | --- |
| Synthetic top | GLM-5.3 | Kimi K3.1 Pro | 46 (32 at max) | Not measured; Kimi K3 high took 10-14 min as a review peer on 2026-10-21 |
| Synthetic middle | GLM-5.3 Flash | GLM-5.3 | 32 at max (28) | Not measured at Pi's default; 24-25 min at max and 20.5 min at high as a review peer on 2026-10-21 |
| Synthetic bottom | DeepSeek V4.1 Flash 1017 | GLM-5.3 Flash | 28 (29 at high) | 10-19 min at high as a review peer on 2026-10-21 (DeepSeek: 48 min at max, 101 min at high) |

Synthetic children keep effort unset: Pi lists `thinking` levels only up to high, so the chart's max scores are upper bounds, not the configured setting. The Synthetic middle rung trades GLM-5.3 Flash's speed for GLM-5.3's higher score, and the bottom rung drops DeepSeek, the slowest Synthetic model measured.

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

`home/h82/t3code.nix` merges the captured server and client preferences into writable T3 settings. New threads use Codex `gpt-6.2-sol` at `high` effort, with Claude Opus 5.5 as fallback and `gpt-6-luna` for text generation. Threads start with full access in a worktree. Inactive worktree cleanup uses five days. The interface uses Pretendard Variable; code and terminals use Jetendard. Baseline-only settings remain declared unless the overlay replaces them, and unrelated user settings survive application.

Claude, Codex, Pi, and OpenCode share their normal homes, credentials, plugins, and baseline instruction files with CLI sessions. Activation renders only the template's T3 branch into private files under `~/.t3/userdata/instructions/`. The launch composer passes Claude `--append-system-prompt-file`, Codex `-c developer_instructions=...`, and Pi `--append-system-prompt`. OpenCode has no such option, and a global `instructions` entry would reach sessions outside T3 Code, so the OpenCode instance lists its file in `OPENCODE_CONFIG_CONTENT` in its environment, which T3 Code hands to the server it starts. OpenCode reads the baseline from `~/.config/opencode/AGENTS.md`. Existing append options and Codex developer instructions are composed with the addition. Claude append-file paths must be absolute. Reapply after changing those files or native Codex developer instructions; their contents are captured during application. The private `dotfiles-launch-state.json` tracks contributions so repeated application preserves unrelated argument and environment edits. CLI launches receive the baseline only.

Claude uses idle compaction before the cache expires. The T3 provider uses Claude's default subagent depth unless its environment includes a user-specified value. The standalone CLI retains its configured cap. Activation retires dotfiles' old Claude and existing-mode Codex launch controls using their recorded contributions. Pi uses the managed package in the shared user profile and hides its `default` model while preserving the user's other hidden choices.

Activation removes the retired Grok Build launch configuration and disables the default Grok instance. T3 Code 0.1.9 can otherwise restore the instance from session history.

The repository's Compound Engineering review peers are Claude and Codex. Activation disables the former managed Antigravity ACP provider and removes its launch override on upgrade. Saved credentials and conversations stay on disk.

T3 cannot enforce a read-only delegate. A read-only brief or worktree isolation does not supply that guarantee; CE workflows requiring enforced read-only access use their existing unavailable-route handling.

Close T3 before applying and relaunch it afterward. Repository checks execute the rendered activation and inspect launch arguments and instruction files. These checks establish activation output; they do not establish signed-in provider behavior, model compliance, or the T3 desktop experience on either host.

## Pi tools and project trust

The Pi package builds pinned upstream source with the committed Synthetic model lock compiled into its runtime. Its fixed-hash source fetch lets Nix read package metadata and dependency locks without building a derivation during evaluation. Project settings, extension registrations, refreshes, and reloads cannot add models or replace their locked routes through Pi's supported APIs. The policy extension diagnoses invalid restored sessions. Trusted extensions still execute arbitrary JavaScript as the user; the model lock does not sandbox that code.

The shared `~/.pi/agent/` contains the repository-owned `question`, `web_search`, and `web_fetch` extensions. Questions use native select and input dialogs, with distinct cancellation, empty-answer, and unavailable-UI results. Web tools use Exa and return bounded source content with URLs for citations. Page content is untrusted input.

The wrapper clears inherited `EXA_API_KEY` and exports only `DOTFILES_PI_EXA_KEY_FILE`, pointing to the existing published `exa_api_key`. The extension reads the file on each call. It does not copy the key into Pi settings, authentication, arguments, or subprocess environments. A missing key disables web calls without preventing Pi or questions from working. Trusted extensions can still read files accessible to the user.

T3's launch composer adds `--approve` for Pi and preserves user-added arguments through its ownership ledger. Approval applies to that run and does not update remembered project decisions. Terminal Pi uses native per-project trust prompts, preserving previous decisions. T3 project resources and web queries carry the code-execution and disclosure risks accepted in issue [#139](https://github.com/hyperlapse122/dotfiles/issues/139).

Repository checks exercise materialized files for both host kinds, packaged CLI and SDK model paths, native RPC dialogs, subprocess environments, and project skill discovery. These checks use fake credentials. They do not establish the live T3 dialog experience, signed-in Exa calls, or either host's installed generation; those require post-switch evidence from the owner.
