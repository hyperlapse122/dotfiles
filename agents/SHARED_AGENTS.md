# Agent Instructions

> **Precedence**: A project-level `AGENTS.md` (in the repo) **overrides** any rule here when it conflicts. Otherwise these rules apply.
> **Style**: All directives use [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords — **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**.

## Contents

1. [Branch Naming](#branch-naming)
2. [Commit Messages](#commit-messages)
3. [Pull Requests / Merge Requests](#pull-requests--merge-requests)
4. [Destructive / Bypass Operations](#destructive--bypass-operations)
5. [Secrets](#secrets)
6. [Figma](#figma)
7. [Interactive / Long-Running Processes](#interactive--long-running-processes)
8. [Rebase](#rebase)
9. [Scripting Runtime](#scripting-runtime)
10. [JavaScript Package Managers](#javascript-package-managers)

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

**Rule**: one task = one branch. Name needs changing → rename it. **MUST NOT** create a sibling branch for the same work.

**Issue-resolution rule**: when resolving a GitHub issue or GitLab issue/MR, agents **MUST NOT** keep or push an automatically-generated branch name, including OpenCode's `opencode/<adjective>-<noun>` form or any other tool-generated placeholder. Before committing or pushing, rename the current branch in place with `git branch -m` to a human-readable Git Flow name that reflects the issue being resolved, e.g. `bugfix/<issue-slug>` or `feature/<issue-slug>`.

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

- **Subject**: lowercase, imperative, no period, ≤50 chars (≤72 max).
- **Scope** (optional): module/area — `feat(auth): add JWT refresh`.
- **Body** (optional): explain *why*, not *what*. Wrap at 72 chars.
- **Breaking change**: `!` after type/scope **and** `BREAKING CHANGE:` footer.
- **Trailers** (footer block, when applicable): `Closes #123` / `Fixes #123` (auto-close issues on merge), `Refs #123` / `Refs !456` (reference without closing), `Co-authored-by: Name <email>` (co-attribution).

```
feat(auth): add JWT refresh token rotation
feat(api)!: remove deprecated v1 endpoints

BREAKING CHANGE: v1 API endpoints have been removed. Migrate to v2.
```

**MUST NOT**: emojis, sentence case, trailing periods, vague subjects (`update stuff`, `fix things`, `wip`), AI-tool branding or attribution (no "Generated with Claude", no `🤖` markers, no `Co-authored-by:` trailers naming an AI).

## Pull Requests / Merge Requests

**Before opening a PR/MR**, the project's standard verification commands (test / lint / typecheck / build — whichever the project defines) **MUST** have run on the current HEAD. **MUST NOT** submit a PR/MR with known-failing checks unless the failure is documented in the PR/MR body and the user has approved it.

**MUST** commit and push **all** changes. Verify both gates pass:

```bash
git status                                              # MUST be clean (no uncommitted changes)
git rev-parse --abbrev-ref @{u} >/dev/null 2>&1 \
  && git log @{u}..                                     # if upstream exists, MUST be empty
                                                        # if no upstream: `git push -u origin <branch>` first
```

**MUST** assign the PR/MR to the authenticated user:

| Host   | Command                                                                                         |
|--------|-------------------------------------------------------------------------------------------------|
| GitHub | `gh pr create --assignee @me`                                                                   |
| GitLab | `glab mr create --assignee "$(glab api user \| jq -r '.username')" --remove-source-branch`     |

**PR/MR title MUST** follow [Conventional Commits](https://www.conventionalcommits.org/) format (`<type>(<scope>): <description>`) — a squash merge then produces a clean single commit on the default branch.
**PR/MR body SHOULD** include: problem summary, what changed, how it was verified. Link related work via trailers (`Closes #123`, `Refs !456`).
**MUST NOT** open as draft unless the user explicitly requested a draft.

**GitLab additionally MUST**:
- Pass `--remove-source-branch` (cleanup after merge).
- Pass `--related-issue <N>` when the MR resolves a tracked issue.

## Destructive / Bypass Operations

The following commands silently destroy work or quietly defeat safety nets. **MUST NOT** run any of them without an explicit user request in the same turn:

- `git commit --no-verify`, `git push --no-verify` — bypasses pre-commit / pre-push hooks (including secret scanners).
- `git push --force` / `git push --force-with-lease` to a shared branch (`main`, `master`, `develop`, or any branch someone else may have pulled).
- `git reset --hard`, `git clean -fdx` on a tree with uncommitted work.
- `git commit --amend` on a commit that has already been pushed.
- `git rebase --interactive` (or any other history rewrite) on already-pushed commits.
- `rm -rf` outside the repo's own ignored / build directories.

When a destructive action is genuinely the right answer, **MUST** confirm with the user first — name the exact command and state what it will destroy or rewrite.

## Secrets

**MUST NOT** commit, even briefly, even in a fixup commit you plan to squash later:

- `.env`, `.env.*` (except `.env.example`, `.env.sample`, and other clearly-templated variants).
- Private keys (`*.pem`, `id_*` without `.pub`, `*.age`, GPG private keyrings, SSH host keys).
- API tokens, OAuth client secrets, webhook signing secrets, deploy keys.
- Cloud credentials (`~/.aws/credentials`, kubeconfigs with embedded tokens, service-account JSON).
- Database connection strings with embedded passwords.

If a secret is committed by accident: **STOP**, notify the user, treat the secret as compromised, and rotate it. **MUST NOT** silently rewrite history with `git rebase` / `git filter-repo` / `git filter-branch` to "remove" the secret without explicit user instruction — once a commit is published it propagates to forks, clones, mirrors, and CI caches.

## Figma

**MUST** use the `figma` MCP for any Figma URL.
**MUST NOT** fetch Figma via web fetch, browser automation, screenshot tools, or any other surface.
MCP unavailable / errors → **STOP** and ask the user to fix the MCP. **MUST NOT** improvise an alternative.

## Interactive / Long-Running Processes

**MUST** use the `tmux` tool (`mcp_interactive_bash`) for: dev servers, watch modes, TUI apps, REPLs, build watchers — anything that does not terminate.
Regular shell execution **WILL BLOCK** the agent session and is **forbidden** for non-terminating commands.

## Rebase

When rebasing a feature branch onto the default branch (`main`), resolve conflicts by **intent, not reflex**:

- **Regenerated / generated artifacts** (lockfiles, build outputs, schema migrations with sequence numbers, generated configs): take `main`'s version, then re-run the generator on top so your additions reproduce on the new base.
- **Hand-written code**: review both sides and merge intentionally. **MUST NOT** blindly pick `--ours` or `--theirs` — that silently drops one side's work.

Note: during a rebase Git's `--ours` / `--theirs` are **reversed** compared to merge. `--ours` is `main` (the rebase target you're replaying onto); `--theirs` is the feature commit being applied.

If you picked the wrong side or merged in the wrong direction: `git rebase --abort` and restart. **MUST NOT** continue with a wrong-direction rebase.

## Scripting Runtime

**MUST NOT** use Python for any new scripting, tooling, or codegen task.
**MUST** use Node.js, Deno, or Bun (TypeScript preferred).

**Shell** (`bash` for POSIX, PowerShell for Windows) is acceptable for: system bootstrap, OS-level glue, single-purpose installer scripts. **MUST NOT** use shell for application logic, codegen, or anything that benefits from types and tests — those go to TypeScript.

**Exception**: an established Python project that already has Python tooling — match the project, do not fork the runtime. State the exception explicitly in the response when applying it.

## JavaScript Package Managers

User-global config hardens **npm, pnpm, Yarn, and Bun** against supply-chain attacks via three switches that **MUST** be preserved by agents working in JS/TS projects:

1. **Lifecycle scripts disabled** (`ignore-scripts` / `enableScripts: false` / `ignoreScripts`).
2. **Exact version pinning** on every install (`save-exact` / `defaultSemverRangePrefix: ""` / `saveExact` / `[install] exact`).
3. **One-week cooldown** before any newly-published version is installable (`min-release-age=7` days / `npmMinimalAgeGate: 10080` minutes / `minimumReleaseAge: 10080` minutes / `minimumReleaseAge = 604800` seconds).

**MUST NOT** edit the user-global config files (`~/.npmrc`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/pnpm/config.yaml`, or their per-OS equivalents) to relax any of the three switches. Per-project escape hatches below are the supported override.

### Overriding the Lifecycle-Script Block

When a dependency legitimately needs to run its install script (native build, codegen, etc.), opt in at the **narrowest possible scope**:

| Manager | Scope | Mechanism |
|---|---|---|
| **Yarn Berry** | **per-package** *(preferred — Yarn is the primary manager in this dotfiles policy)* | Add `dependenciesMeta.<pkg>.built: true` to the project's `package.json`. Only that package's install/build scripts run; all other dependencies stay blocked. |
| **npm** | **per-repository** | Set `ignore-scripts=false` in a committed project `.npmrc`. npm has no per-package override; it does not recognise `dependenciesMeta`. |
| **pnpm** | **per-repository** | Add the package to `allowBuilds` (pnpm v11+) or `onlyBuiltDependencies` (v10 and earlier) in `pnpm-workspace.yaml`. **MUST NOT** rely on `dependenciesMeta.<pkg>.built` — pnpm removed that field from its manifest types and silently ignores it. |
| **Bun** | **per-repository** | Add the package name to the `trustedDependencies` array in the project's `package.json`. |

**MUST** name the specific install-time behaviour being unblocked (native binding, codegen, asset fetch, etc.) in the PR/MR description or as a code comment next to the override. "It failed without this" is not sufficient justification.

### Exact Version Pinning

Every dependency in every `package.json` **MUST** be pinned to an exact version — no `^`, no `~`, no `>=`, no `latest`, no `*`, no `x` placeholders.

The user-global config produces exact specs automatically when adding deps via `yarn add` / `npm install` / `pnpm add` / `bun add` — agents **SHOULD NOT** pass any range flag.

**MUST** correct any existing range specifier (`^x.y.z`, `~x.y.z`, `>=x`, etc.) to an exact version when modifying a `package.json` for any reason.
**MUST NOT** introduce a new range specifier.
**MUST NOT** edit a lockfile by hand to dodge the exact-pin rule.

Exception: a project-level `AGENTS.md` may permit ranges where genuinely required (peer-dep flexibility, library `package.json` authored for downstream consumers, etc.) — state the exception explicitly when applying it.

### Cooldown Gate (1 week)

A package version must be **at least one week old** before any of the four managers will resolve it. If `yarn add` / `npm install` / `pnpm add` / `bun add` fails with a "does not meet the minimumReleaseAge constraint" error (or equivalent), the requested version is too fresh and **MUST NOT** be installed.

**MUST** pin to the most recent version that already satisfies the one-week gate.
**MUST NOT** add the package to a preapproved/exclude list (`npmPreapprovedPackages` in Yarn, `minimumReleaseAgeExclude` in pnpm, `minimumReleaseAgeExcludes` in Bun) without explicit user approval per package — bypassing the gate defeats the supply-chain protection it provides.
**MUST NOT** lower the cooldown value in any user-global or project-level config to work around a fresh-version failure.
