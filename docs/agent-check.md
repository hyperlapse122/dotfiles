# Set up agent-check

Define one fast `agent-check` task at the Git root. Use the same task for local edits, pre-commit, and CI. This allows Claude Code, Codex, Pi, and OpenCode to use the project's own formatters, linters, and type checkers.

## Define the project task

Add the task to `mise.toml`, or define an `agent-check` recipe in a root justfile or Makefile. The launcher looks for the task in that order.

```toml
[tasks.agent-check]
run = "bash scripts/check-changed-files"
```

The launcher runs the task from the root of the tree being checked. It sets `AGENT_CHECK_FILES` to the absolute path of a NUL-delimited list of changed paths relative to that root. The list includes deletions. Skip absent paths when a tool needs existing files. Read the list as NUL-delimited data to preserve spaces and other characters in filenames.

```bash
while IFS= read -r -d '' path; do
  if [[ $path == *.nix && -f $path ]]; then
    nixfmt --check "./$path" || exit $?
  fi
done < "$AGENT_CHECK_FILES"
```

Set up each tool before running the task. The launcher puts the checkout's `node_modules/.bin` on `PATH`. Home Manager supplies `tsc`, `pyright`, `go`, `statix`, `nixfmt`, and `markdownlint-cli2` as fallbacks. A project can select its own commands, such as `tsc --noEmit` for an affected TypeScript project or `go vet` for affected Go packages.

Run `agent-check` to check staged, unstaged, and untracked changes using the working tree. A clean tree or a project without a task exits quietly. A failing task returns its runner's exit status and up to 100 diagnostic lines. The task can read `AGENT_CHECK_MODE` to distinguish `worktree`, `staged`, and `range`.

## Run it before commit

Use `--staged` in a project-managed Git hook. It runs the task and reads files from a temporary checkout of the index, including the staged contents of partially staged files.

```yaml
# lefthook.yml
pre-commit:
  commands:
    agent-check:
      run: agent-check --staged
```

In this repository, run `mise install` and `git config core.hooksPath .githooks`. The hook calls the same task, and Markdown lint reads the index snapshot with the project's configured globs. The standalone `mise run lint-staged-markdown` command still runs the staged Markdown check.

Enable automatic harness execution only where the native hook runs with the session's existing tool permissions or the owner has authorized that project to run with hook privileges. Enabling this repository's Git hook authorizes its project task for commits in that checkout.

## Require it in CI

Fetch enough history to resolve both endpoints. On a pull request, use the merge base of the target and PR head as the base. On a push, use the event's before and head commits.

```bash
agent-check --range "$base" "$head"
```

The range checks the committed head tree, so it finds changes even when the checkout is clean. The CI job should propagate the task's failure and run without `SKIP` or `continue-on-error`. Require the job in the protected branch's status checks so that skipping the local hook with `git commit --no-verify` still leaves a required check.

This repository's `Nix` workflow runs the `agent-check` job alongside its whole-tree and host checks. Set `agent-check` as a required status check when enabling the branch protection.
