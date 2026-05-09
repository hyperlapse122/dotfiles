# Agent Instructions

> **Precedence**: A project-level `AGENTS.md` (in the repo) **overrides** any rule here when it conflicts. Otherwise these rules apply.
> **Style**: All directives use [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords — **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**.

## Branch Naming

**MUST** rename — never re-create — the branch when the current name is OpenCode's auto-generated `opencode/<adjective>-<noun>` form. Use `git branch -m`; the working tree, index, and history move atomically.

```bash
git branch --show-current                                  # check
git branch -m opencode/playful-engine feature/add-auth     # ✅ rename in place
git checkout -b feature/add-auth-flow                      # ❌ leaves opencode/* orphaned
```

**Naming convention** (Git Flow, unless the project defines its own):

| Prefix      | Use for                       | Matching commit type |
|-------------|-------------------------------|----------------------|
| `feature/`  | New features                  | `feat`               |
| `bugfix/`   | Bug fixes                     | `fix`                |
| `hotfix/`   | Urgent production fixes       | `fix`                |
| `refactor/` | Code restructuring            | `refactor`           |
| `docs/`     | Documentation                 | `docs`               |
| `chore/`    | Maintenance / config          | `chore`              |
| `release/`  | Release preparation           | n/a                  |

**MUST** load the `git-flow-branch-creator` skill when a rename is needed — it analyzes the diff and picks the prefix.

**Rule**: one task = one branch. Name needs changing → rename it. **MUST NOT** create a sibling branch for the same work.

## Commit Messages

**MUST** follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>)<!>: <description>`.

| Type       | Use for                                  |
|------------|------------------------------------------|
| `feat`     | New feature                              |
| `fix`      | Bug fix                                  |
| `docs`     | Documentation only                       |
| `style`    | Formatting, whitespace (no logic change) |
| `refactor` | Restructure (no feature/fix)             |
| `perf`     | Performance improvement                  |
| `test`     | Tests                                    |
| `build`    | Build system / dependencies              |
| `ci`       | CI/CD configuration                      |
| `chore`    | Maintenance                              |
| `revert`   | Reverting a previous commit              |

- **Subject**: lowercase, imperative, no period, ≤72 chars.
- **Scope** (optional): module/area — `feat(auth): add JWT refresh`.
- **Body** (optional): explain *why*, not *what*. Wrap at 72 chars.
- **Breaking change**: `!` after type/scope **and** `BREAKING CHANGE:` footer.

```
feat(auth): add JWT refresh token rotation
feat(api)!: remove deprecated v1 endpoints

BREAKING CHANGE: v1 API endpoints have been removed. Migrate to v2.
```

**MUST NOT**: emojis, sentence case, trailing periods, vague subjects (`update stuff`, `fix things`, `wip`).

## Pull Requests / Merge Requests

**MUST** commit and push **all** changes before opening a PR/MR. Verify both gates pass:

```bash
git status              # MUST be clean (no uncommitted changes)
git log @{u}..          # MUST be empty (everything pushed)
```

**MUST** assign the PR/MR to the authenticated user:

| Host   | Command                                                                                         |
|--------|-------------------------------------------------------------------------------------------------|
| GitHub | `gh pr create --assignee @me`                                                                   |
| GitLab | `glab mr create --assignee "$(glab api user \| jq -r '.username')" --remove-source-branch`     |

**GitLab additionally MUST**:
- Pass `--remove-source-branch` (cleanup after merge).
- Pass `--related-issue <N>` when the MR resolves a tracked issue.

## Figma

**MUST** use the `figma` MCP for any Figma URL.
**MUST NOT** fetch Figma via web fetch, browser automation, screenshot tools, or any other surface.
MCP unavailable / errors → **STOP** and ask the user to fix the MCP. **MUST NOT** improvise an alternative.

## Interactive / Long-Running Processes

**MUST** use the `tmux` tool (`mcp_interactive_bash`) for: dev servers, watch modes, TUI apps, REPLs, build watchers — anything that does not terminate.
Regular shell execution **WILL BLOCK** the agent session and is **forbidden** for non-terminating commands.

## Rebase

When rebasing a feature branch onto the default branch (`main`), conflicts **MUST** resolve in favor of the default branch.

Mental model: your branch carries changes *to be merged into main*. Main is the source of truth; your branch is the diff being replayed onto it.

If you accidentally picked the other side: `git rebase --abort` and restart. **MUST NOT** continue with a wrong-direction merge.

## Scripting Runtime

**MUST NOT** use Python for any new scripting, tooling, or codegen task.
**MUST** use Node.js, Deno, or Bun (TypeScript preferred).

**Exception**: an established Python project that already has Python tooling — match the project, do not fork the runtime. State the exception explicitly in the response when applying it.
