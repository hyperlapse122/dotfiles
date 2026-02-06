# Global Development Workflow

## Merge Requests / Pull Requests

Before performing any MR/PR operations, detect the remote platform:

1. **Check git config first**: Run `git config -l` and look for explicit provider entries like `credential.https://git.jpi.app.provider=gitlab` or `credential.https://github.com.provider=github`.
2. **Fall back to remote URL**: If no provider is configured, inspect `git remote get-url origin` and match the hostname.

- **GitLab** (provider=`gitlab`, or hosts like `gitlab.com`, `git.*.app`): Use `glab` CLI. Terminology: "merge request" (MR).
- **GitHub** (provider=`github`, or hosts like `github.com`): Use `gh` CLI. Terminology: "pull request" (PR).

All rules below apply to both platforms — substitute the appropriate CLI and terminology.

### Rules
- **Always create draft MRs/PRs**: On the first push to any non-default branch, automatically create a draft MR/PR targeting the default branch. After creation, assign yourself.
  - GitLab: `glab mr create --draft --target-branch <default-branch>`, then `glab mr update <id> --assignee @me`
  - GitHub: `gh pr create --draft --base <default-branch>`, then `gh pr edit <id> --add-assignee @me`
- **Always update MR/PR on push**: Before or after every `git push`, update the MR/PR description by regenerating it from all commits between the base branch and HEAD.
- **Never skip MR/PR updates**: Every push should be accompanied by an MR/PR description update reflecting the current state of the branch.

### MR/PR Description Format

Regenerate the full description each time by analyzing all commits (`git log <base>..HEAD`) and the diff stat (`git diff <base>...HEAD --stat`).

**Template priority**: Check for MR/PR templates in the repository first (`.gitlab/merge_request_templates/` for GitLab, `.github/pull_request_template.md` for GitHub). If a template exists, use it as the structure and fill in the sections. If no template exists, use the default format below.

**Default format** (when no template is available):

Analyze all commits together and organize **by component/area** (not commit-by-commit):

1. **Motivation**: One or two sentences explaining *why* this MR/PR exists — the problem being solved or the goal being achieved.
2. **Summary**: Break down changes component-by-component (e.g., "### Admin — Purchase Management", "### Commerce — Checkout", "### Infrastructure"). Each component section has bullet points explaining what changed and why.
3. **Breaking Changes** *(only when applicable)*: List any breaking changes — API changes, removed features, schema migrations, environment variable changes, or anything that requires action from other developers or deployment steps.
4. **Deployment Notes** *(only when applicable)*: Steps required beyond a normal deploy — migrations, seed data, env variable additions, infrastructure changes, or manual configuration.
5. **Validation**: A to-do list (`- [ ]` / `- [x]`) of all validation steps (lint, types, unit tests, E2E tests). Mark each as checked when passed, unchecked when failed or not yet run.
6. **Related Issues** *(only when applicable)*: Link related GitLab issues with `Closes #123` or `Relates to #456`.

### Tips
- When the description contains special characters (backticks, quotes, angle brackets), write it to a temp file first and use `$(cat file)` to pass it to `glab mr update` or `gh pr edit`.
- Use `glab mr list --source-branch <branch>` or `gh pr list --head <branch>` to find existing MRs/PRs before creating a new one.

## Validation

- **Always use CLI tools** for validation — never use IDE diagnostics (e.g., `mcp__ide__getDiagnostics`).
- Run the project's CLI commands for linting, type checking, building, and testing (e.g., `yarn lint`, `yarn tsc --noEmit`, `yarn build`, `yarn test`).
- When validating for an MR/PR, run all applicable validation steps and update the checklist accordingly.
