# Task guide

## Decide for CI triage

Read the first relevant CI failure before choosing what to inspect. If the evidence leaves two or more plausible read-only checks and a judgment would change which one you run first, call the `decide` MCP server’s `judge` tool once. Use `choice` with a short description of each candidate and an `insufficient_evidence` option. Send only the evidence needed for the question and permitted for the configured backend.

If the failure already identifies the next check, run it directly. If the failing step or error is missing, retrieve it first. Treat the answer as a lead and verify it against the logs, code, or configuration. If the tool is unavailable, fails, or gives no usable lead, continue the investigation. Follow the existing verification and approval rules.

## Decide for subagent roles

After the workflow decides to delegate, keep its launch route, permissions, provider, model, effort, and context limits. If a role is required, follow the existing path without calling `judge`. Otherwise, consider roles the current session can select through that route. Check each role's purpose, conditions on use, tool restrictions, and effective launch behavior, including any settings it overrides or ignores. If one role qualifies, select it directly.
For Claude Code's built-in roles, start with `~/.local/share/nix-config/claude-code-agents.json`. Confirm availability in the current session and use its effective role definitions when they differ from the pinned catalog.
If two or more roles qualify, ask the `decide` MCP server's `judge` tool once. Use a `choice` question with the eligible role identifiers, their short descriptions, and `insufficient_evidence`. Summarize the task by purpose and tool needs. Send only information permitted for the configured backend. When the backend is unknown, use information permitted to leave the machine.

Pass a returned eligible role to the existing launcher's role selector. Follow the existing selection path if the session has no selectable role, the request cannot be sent, or `judge` fails, abstains, or returns an ineligible role.

## Issues in pull and merge requests

When you create a pull request or merge request, link the issues it addresses in its description.

- Link every issue that the user, the branch, the commits, or the governing plan names for the work. When none is named, search the repository's open issues for ones the change resolves or advances, and link those. Do not create an issue only to have one to link.
- For each issue the change fully resolves, add its own line `Closes #N`. Use `Closes group/project#N` or `Closes owner/repo#N` for an issue in another project. GitHub and GitLab both close the issue when the change merges into the default branch.
- For each issue the change only partly resolves, add `Related to #N` without a closing keyword, and state in the description what remains.
- Put closing keywords only in pull and merge request descriptions, never in commit messages.

Plan issue work so that a pull or merge request closes the issue:

- Work that starts from an issue has the whole issue as its request. Scope it to everything needed to close the issue; under the scope rule above, that is the intended scope, not an addition.
- When one pull or merge request cannot close the issue, plan several from the start. Each one before the last mentions the issue with `Related to #N`, and the one that completes it closes it with `Closes #N`.
- Leave an assigned issue open after its planned pull or merge requests merge only when the user narrowed the scope. The last one then mentions the issue and lists what remains.
- An issue you found only by searching never widens the scope. Close it only when the change fully resolves it; otherwise mention it.

## Web development skills

Before starting HTML, CSS, web UI, or browser-side JavaScript work, load and follow the `modern-web-guidance` skill first. This includes web platform code inside frameworks. Use its guidance alongside other applicable design and framework skills.

Follow the skill's trigger and exclusion rules. Backend-only, infrastructure, tooling-only, and native-only tasks do not require it.

Apply the `design-lenses` craft floor to every UI edit. Use `design-lenses` for flows and states, including CLI prompts and notifications, and `ux-writing` for interface copy.
Use `frontend-design` for the visual direction of new screens. Apply the other skills within that direction.

## Refactoring and test cleanup

When asked to refactor code structure, read `untangle-codebase/SKILL.md` in your user skill directory and use its criteria for coupling and grouping related code. When asked to audit or prune tests, read `prune-tests/SKILL.md` there alongside `test-audit` and follow the repository's testing policy. Apply the guidance within the scope of the request.

## Temporary containers and local Kubernetes

Use container runtimes and local Kubernetes clusters only for temporary development and testing. Cleanup is part of the task, not optional follow-up work.

- Before creating resources, identify the local runtime or cluster endpoint and distinguish this task's resources from those used by other active tasks. Track the resources you create or download so they can all be removed.
- As soon as their use ends, including after success, failure, or orderly cancellation, delete the task's clusters, containers, images, volumes, networks, build caches, and temporary data; stopping containers or pruning unused resources is insufficient. Do not retain volumes for reuse or debugging, even if they already existed, or leave development deployments running after the task ends. After a forced interruption, check for and remove leftover task resources when work resumes.
- Protect resources used by other active tasks, whether run by a user or an agent; their owners must clean them up. Do not use a global prune or runtime reset that would remove those resources, or delete remote resources, installed runtime binaries, credentials, or unrelated host files.
- Before reporting cleanup complete, verify that no task-owned disposable resources remain, including zero task-owned volumes. Report any unfinished cleanup; if deletion fails or ownership cannot be established, report the remaining resources and the reason.
- Check host disk-space reclamation separately from resource deletion. Before stopping a shared runtime or compacting its disk, establish that no other user or agent work depends on it; otherwise leave the runtime running and report the unreclaimed space. Do not shut down unrelated virtual machines.

### macOS

- Use Apple's `container` CLI by default for temporary container-related development work, including image builds, execution, testing, and supported image, network, and volume operations.
- Check the installed `container` version and its capabilities before relying on a required operation. If it cannot perform that operation, explain the concrete limitation and agree on an alternative with the user before using another runtime or installing compatibility tools.
- Explicit configuration application starts a stopped API, installs the recommended kernel, and enables startup at login. Preserve an already running runtime and its kernel. Do not restart or stop shared services to apply configuration or clean up temporary workloads; the managed kernel and login service are host infrastructure.

### NixOS

- Use rootless Podman for temporary NixOS development, with minikube's Podman driver when a task requires Kubernetes.
- Identify the user's Podman socket and keep each task's containers, images, volumes, networks, minikube profile, and kubeconfig separate from other work.
- Close port-forward processes before deleting the owned profile and enumerated resources. Never use global prune or all-profile deletion.
