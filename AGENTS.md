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

## Tool retirement

- Retiring a tool stops repository management while preserving its installed executable, settings, credentials, plugin state, and session data on existing PCs. Remove its installation declarations, tool-specific release pins, configuration sources, instruction adapters, and integration code from the repository; later applies must neither reinstall nor reconcile the retired tool.
- Do not add cleanup scripts, deletion manifests, or uninstall commands as a consequence of retirement. Uninstalling a binary or deleting existing user configuration or data requires a separate explicit request. Fresh homes must not acquire the retired tool or its configuration.
- When the request explicitly includes removing an integration entry from a configuration file that remains managed, update that file's `modify` transformation to remove the existing entry and keep it absent on repeated applies. Removing insertion logic alone is insufficient. Preserve unrelated entries and settings.
- Keep shared Compound Engineering release pins, skills, instructions, and assets managed while any remaining harness consumes them. Remove only resources exclusive to the retired tool.
- Verify preservation and lack of reconciliation in an existing disposable home, and absence in a fresh disposable home, as described in [Tool Retirement](docs/maintenance/chezmoi-source.md#tool-retirement). Retirement must not apply personal configuration during worktree bootstrap.

## User-scope harness instructions

- Every repository-managed AI harness MUST wire its native user-scope instruction file to `home/.chezmoitemplates/agent-instructions`. Adding a harness is incomplete without this connection.
- Keep common instructions in that shared template and select harness-specific content with its explicit `harness` identifier at render time. Never copy the common body into an adapter or expose another harness's branch in generated instructions.
- When onboarding a harness, verify common-content inclusion, foreign-branch exclusion, and native user-scope discovery in a disposable home. Follow the source layout and editing procedure in [docs/maintenance/chezmoi-source.md](docs/maintenance/chezmoi-source.md#shared-user-scope-harness-onboarding).
- T3-launched instances must receive only the separately selected T3 additions through a supported native per-launch option or SDK equivalent. Keep the normal instruction baseline, homes, credentials, plugins, and configuration shared; never add a shadow home or duplicate the baseline to select T3 context.
- Verify native CLI/T3 baseline equality, addition isolation, existing instruction-setting composition, option precedence, and native CE in disposable homes on eligible platforms. Document an exact harness/adapter limitation when no additive mechanism exists; untrusted application context does not replace that mechanism.

## Harness plugin integration

- Every repository-managed AI harness MUST register, install, and enable the Compound Engineering plugin at user scope through its supported native integration. Adding a harness is incomplete without both this integration and the shared-instruction connection above.
- Reuse the repository-owned CE release and commit pin, and perform installation and configuration only through explicit chezmoi application. Keep worktree preparation read-only for personal settings; use the harness's native mechanism.
- Verify native CE skill discovery and invocation in a disposable home on each eligible platform. Preserve unrelated plugins and settings.
- Every repository-managed AI harness MUST discover each shared user-scope skill from `home/.chezmoidata/harness-skills.json` exactly once, through the skill roots in `home/.chezmoitemplates/external-assets/harness-skills.toml.tmpl`. Adding a harness is incomplete until its native skill listing in a disposable home shows each of those skills once.
