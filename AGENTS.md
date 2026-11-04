`.compound-engineering/artifacts/solutions/` contains documented solutions to past bugs, best practices, and workflow patterns, organized by category with YAML frontmatter (`module`, `tags`, `problem_type`); these records are relevant when implementing or debugging a documented area.

After a solved, verified problem, automatically invoke the `ce-compound` skill with `mode:non-interactive` at the completion checkpoint only when the work produced durable project reasoning that is not readily recoverable from the final code, tests, types, comments, or existing documentation, and losing it would plausibly cause recurrence, material risk, or substantial rediscovery. Apply this counterfactual: if the learning document disappeared, would a future engineer reading the final implementation still be likely to repeat the mistake or redo substantial investigation? If not, do not invoke it. Completion, effort, and diff size alone are not enough. Capture at the checkpoint so a qualifying learning can ship in the PR that produced it, and only where the repository treats captured learnings as tracked, committed knowledge.

Write every report, summary, or handoff to the user through the `ce-noslop` skill. This applies when you are the top-level agent writing to the user, not when you are a subagent reporting to its caller. Do not apply it to code, config, verbatim quotes, or text the user asked to post as written.

Write repository documentation in English.

## Worktree bootstrap

- Initialize every new or existing worktree with `mise install`. Put any additional preparation scripts behind the project-level `postinstall` hook, not a separate setup entry point.
- Keep initialization read-only with respect to personal settings: do not apply chezmoi state or change user-home or OS configuration from bootstrap.
- Bootstrap must use the repository's hook-free chezmoi config; excluding source scripts alone does not prevent hooks from a personal chezmoi config.
- Declare development tools in `mise.toml` and commit the generated `mise.lock`. Keep tool installation in mise rather than duplicating it in chezmoi scripts.
- Use chezmoi for dotfiles. Its source state belongs in `./home`, selected by the repository-root `.chezmoiroot`; the destination is the actual user home directory.
- Use `mise run apply` only when explicitly applying personal configuration. Bind chezmoi commands to the current worktree source rather than changing a user's global source configuration.
- When chezmoi scripts require relative execution order within the same phase, use consistently padded numeric prefixes in their descriptive names, such as `run_once_before_10-windows.ps1.tmpl` and `run_once_before_20-windows-tools.ps1.tmpl`. Preserve `before_` and `after_` phase semantics.
- Keep setup and chezmoi scripts idempotent. Use OS-conditional templates for platform-specific chezmoi scripts.

## User-scope harness instructions

- Every repository-managed AI harness MUST wire its native user-scope instruction file to `home/.chezmoitemplates/agent-instructions`. Adding a harness is incomplete without this connection.
- Keep common instructions in that shared template and select harness-specific content with its explicit `harness` identifier at render time. Never copy the common body into an adapter or expose another harness's branch in generated instructions.
- When onboarding a harness, verify common-content inclusion, foreign-branch exclusion, and native user-scope discovery in a disposable home. Follow the source layout and editing procedure in `home/README.md`.