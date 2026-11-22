# Set up agent-check

Define one fast `agent-check` task at the Git root. Use the same task for local edits, pre-commit, and CI. This allows Claude Code, Codex, Pi, and OpenCode to use the project's own formatters, linters, and type checkers.

## Define the project task

Add the task to `mise.toml`, a root justfile, or a root Makefile. The launcher looks for the task in that order. In a Makefile, declare a literal top-level `agent-check:` rule. The launcher reads the root Makefile during discovery and starts make only when it finds that rule.

```toml
[tasks.agent-check]
run = "bash scripts/check-changed-files"
```

The launcher runs the task from the root of the tree being checked. It sets `AGENT_CHECK_FILES` to the absolute path of a NUL-delimited list of changed paths relative to that root. The list includes deletions and both sides of a rename. Skip absent paths when a tool needs existing files. Read the list as NUL-delimited data to preserve spaces and other characters in filenames.

```bash
while IFS= read -r -d '' path; do
  if [[ $path == *.nix && -f $path ]]; then
    nixfmt --check "./$path" || exit $?
  fi
done < "$AGENT_CHECK_FILES"
```

Set up each tool before running the task. The launcher prepends the working checkout's `node_modules/.bin` to `PATH` for task discovery and execution after it prepares the selected snapshot. Home Manager supplies `tsc`, `pyright`, `go`, `statix`, `nixfmt`, and `markdownlint-cli2` as fallbacks. A project can select its own commands, such as `tsc --noEmit` for an affected TypeScript project or `go vet` for affected Go packages.

Run `agent-check` to check staged, unstaged, and untracked changes using the working tree. A clean tree or a project without a task exits quietly. A failing task returns its runner's exit status and up to 100 diagnostic lines. The task can read `AGENT_CHECK_MODE` to distinguish `worktree`, `staged`, and `range`.

The launcher reports advisory security patterns in changed source and configuration files before running the task. Warnings include the path, line, and rule name. The scanner omits matched text and runs locally in every mode.

For a frontend project, add `impeccable detect src/` to the project task using the affected UI directory. File detection runs offline and exits 2 for primary findings. Keep slower checks in the staged or CI branch of the task.

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

Enabling this repository's Git hook authorizes its project task for commits in that checkout. An explicit `agent-check` run can evaluate project configuration during task discovery, including Makefile includes.

## Require it in CI

Fetch enough history to resolve both endpoints. On a pull request, use the merge base of the target and PR head as the base. On a push, use the event's before and head commits.

```bash
agent-check --range "$base" "$head"
```

The range checks the committed head tree, so it finds changes even when the checkout is clean. The CI job should propagate the task's failure and run without `SKIP` or `continue-on-error`. Require the job in the protected branch's status checks so that skipping the local hook with `git commit --no-verify` still leaves a required check.

This repository's `Nix` workflow runs the `agent-check` job alongside its whole-tree and host checks. Manual runs and pushes with an all-zero before SHA compare the head against its first parent. For an initial commit, they compare against the empty tree. Set `agent-check` as a required status check when enabling branch protection.

## Configure native hooks

Home Manager configures the four harnesses through `my.agentHooks`. The
pre-command hook catches common `git commit --no-verify`, `git commit -n`,
and `SKIP=… git commit` forms. Create `.agents/freeze-tests` at the Git
root to protect test and spec directories and conventional test file names
from native edit tools. Patch checks cover additions, updates, deletions,
and both paths in a rename.

Use `my.agentHooks.<harness>.enable` to turn off a harness integration.
The harness names are `claude`, `codex`, `pi`, and `opencode`. Each also
has `preShell`, `freezeTests`, and `postEdit` switches.

Automatic feedback requires an exact, canonical checkout root in
`my.agentHooks.trustedProjects`. Use the path returned by
`git rev-parse --show-toplevel` from a physical working directory
(`cd -P`). List each worktree separately. The list starts empty.

After a native edit in a listed checkout, the hook scans the edited files
with the packaged source rules and returns up to 50 lines of advisory
output. It reads regular files up to 1 MiB and skips symbolic and hard
links. The hook uses read-only Git metadata and never loads a project task,
tool, or Git filter as executable code. A listed checkout can still
contain an agent-edited task, so the allowlist grants only this feedback.

Set `my.agentHooks.stop = true` to request one check at the end of a turn
when a listed checkout has changes. The request goes to the agent, which
can run `agent-check` through its normal shell tool under the session's
permissions. A clean checkout ends quietly. A genuine new user turn can
receive a new request. You can also run `agent-check` directly.

Review new or changed Codex hooks with `/hooks` in the CLI using the same
Codex home as T3. A rebuild that changes the command's Nix store path
requires review again. Disabling the managed hooks retains their empty
positions when necessary to preserve the identities of unrelated hooks.

Shell file writes, other tools, and more indirect Git invocations can
bypass this feedback. Require the CI job for enforcement. The repository's
`main` branch currently has no required-check rule.

## Approve registry lookups

Pass `--registry-policy /absolute/path/to/registries.json` before the snapshot option to run the registry check by itself. It works in projects without an `agent-check` task. Keep the policy outside the checkout under the control of the person or system running the check. Run `agent-check` again without the flag to run the project's offline source scan and task. Use the offline invocation in automatic edit and commit hooks.

```json
{
  "public": {
    "npm": ["react", "@types/react"],
    "python": ["httpx"],
    "go": ["golang.org/x/text"]
  },
  "private": {
    "npm": {
      "@team/": { "url": "https://npm.example.org", "tokenEnv": "TEAM_NPM_TOKEN" }
    },
    "python": {
      "team-tools": { "url": "https://python.example.org" }
    },
    "go": {
      "git.example.org/team/": { "url": "https://go.example.org" }
    }
  }
}
```

Public approvals name individual packages. Use normalized names for Python (`team_tools` becomes `team-tools`). Private routes use an exact name or a prefix ending in `/`. The longest private match wins even when the same dependency appears in `public`. The registry must offer the ecosystem's metadata API over HTTPS. Use a trusted installation for authenticated runs and set the token variable only for that invocation. The inspector removes configured token variables from the child environment and gives the HTTP client the token in the request header for the approved registry. It follows no redirects.

The check compares `package.json`, `pyproject.toml`, and `go.mod` with the selected base, using the old path for a detected rename. It follows manifest links within the selected tree and checks them when their targets change. An unresolved link reports incomplete verification. The check handles npm aliases, Python extras and markers, and Go `require` and `replace` directives. Workspace and local path references, Git dependencies, and direct URLs are skipped.

A named Python source or a private npm registry declaration requires a private route in the policy. The check reads default and scoped `registry` settings from the selected tree's `.npmrc` files at or above the manifest. A changed registry setting can require a new lookup even when the manifest is unchanged. The trusted policy supplies the lookup destination. A missing package, missing approval, authentication failure, or unreachable registry fails the check. [npm project configuration](https://docs.npmjs.com/cli/v12/configuring-npm/npmrc/)

Successful lookups report the publication date and download count offered by the approved registry. Public npm reports the package creation date and last week's downloads. PyPI reports the latest release's upload date and the Go proxy reports the queried version's time. Fields the registry does not supply are marked unavailable.

In this repository, the CI registry step reads `AGENT_CHECK_REGISTRY_POLICY` from GitHub Actions repository variables and writes it to the runner's temporary directory. Its default is an empty approval list. Add public approvals there when introducing a dependency. The project task runs in a separate step without the policy. Keep private registry credentials and confidential names out of public pull request workflows.
