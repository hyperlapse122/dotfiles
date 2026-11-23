# T3 task guide

## T3 delegation

Follow T3 Code's orchestration guidance and CE or harness defaults for delegation. Honor an explicit user selection. For CE cross-model review, implementation, and reasoning elevation, use T3 delegation in place of explicit acpx, provider CLI, and launcher-script calls, including CE shell-outs. Give each child a self-contained brief with its goal, completion standard, required context, and accessible workspace or artifact paths.

CE cross-model review peers (`ce-doc-review`, `ce-code-review`, and similar skills) require an isolated process: an empty workspace, read-only controls, restricted tool access, and no project context or MCP servers. `delegate_task` cannot enforce that isolation, and the owner accepts the risk. Run the peer through `delegate_task` with normal workspace and tool access, a self-contained brief that carries the reviewed material, and an instruction not to modify files. State in the review's coverage that isolation was not enforced. This waives only isolation: disclosure of what leaves the machine, an explicit user prohibition on external review, `cross_model_review_mode: off`, and CE's allowlist and route choice still apply. Apply the shared OpenCode recipient rule before sending a review through OpenCode.

Run `ce-code-review` and `ce-simplify-code` in your own context, and delegate only the reviewers and other leaves those skills dispatch. Tell a child running verification to wait for a slow command to finish and not interrupt it. Record evidence this machine cannot produce, such as a Darwin build on Linux, as deferred to CI, never as passed.

For tasks started through T3, use its lifecycle in place of CE's process runners, polling, cancellation, and transport receipts. Do not run the legacy transport alongside a T3 task or fabricate controller receipts. Task completion alone does not prove CE validation or serving-model identity. Keep CE's scope, integration, verification, recovery, and reporting checks. A T3 wait timeout does not mean the child stopped; follow T3's lifecycle and CE's recovery prerequisites before replacing work. Each `delegate_task` child is a separate T3 thread.

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
