# Agent Instructions

> **Precedence**: Project-level `AGENTS.md` overrides any rule here on conflict. Otherwise these rules apply.
> **Style**: [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords — **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**.
> **Skills**: This core holds the rules that bind on _every_ task. Operation-specific playbooks live in on-demand skills — load the named skill **before** doing the matching operation (see Routing Index). The guardrails below never depend on a skill loading.

## Routing Index

| Before you…                                                                                | Load skill            | What it covers                                                                                      |
| ------------------------------------------------------------------------------------------ | --------------------- | --------------------------------------------------------------------------------------------------- |
| drive a browser / run Playwright tests                                                     | `playwright-cli`      | usage (host-safety rule is in core below)                                                           |

## Project instruction files — `CLAUDE.md` mirrors `AGENTS.md` (guardrail)

- `AGENTS.md` is the **only** place project instructions are written. Every directory that contains an `AGENTS.md` **MUST** also contain a sibling `CLAUDE.md` whose entire content is the single import line `@AGENTS.md` — nothing else, no heading, no copied prose.
- **MUST** create that sibling `CLAUDE.md` in the same turn you create an `AGENTS.md`, and **MUST** repair it whenever you find an `AGENTS.md` without one (or with a `CLAUDE.md` that carries its own content instead of the import).
- Applies at **every** level — repo root and any nested directory. Never let the two files drift into divergent copies: edit `AGENTS.md`, leave `CLAUDE.md` as the one-line pointer.

## Secrets (guardrail)

- **MUST NOT** commit secrets, even briefly or in a squash-fixup: `.env` / `.env.*` (except `*.example` / `*.sample` templates), private keys (`*.pem`, `id_*` without `.pub`, `*.age`, GPG/SSH keys), API tokens, OAuth client / webhook / deploy secrets, cloud creds (`~/.aws/credentials`, token-bearing kubeconfigs, service-account JSON), DB connection strings with passwords.
- Accidental commit → **STOP**, notify the user, treat the secret as compromised, rotate it. **MUST NOT** rewrite history (`rebase` / `filter-repo` / `filter-branch`) without explicit instruction.
- **MUST NOT** read or pass an auth token to a non-native tool (e.g. a GitLab token into `curl`/`wget`/`httpie`, or out of a credential store / env var into another tool). Let the official CLI inject credentials itself; if auth fails, **STOP** and ask the user to re-login — never surface the secret.

## Destructive / bypass operations (guardrail)

- **MUST NOT**, without an explicit user request in the same turn: `git commit/push --no-verify`; `git push --force` / `--force-with-lease` to a shared branch (`main`/`master`/`develop` or any branch others may have pulled); `git reset --hard` / `git clean -fdx` on uncommitted work; `git commit --amend` on a pushed commit; `git rebase -i` or any history rewrite on pushed commits; `rm -rf` outside the repo's ignored / build dirs. When genuinely required, **MUST** confirm the exact command and what it destroys first.

## Git config — NEVER touch (guardrail)

- **MUST NOT** modify any git configuration at any scope (`--system` / `--global` / `--worktree` / `--local`), edit any gitconfig file, or set identity / signing / any key. **MUST NOT** override identity via `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, `git commit --author`, or `-c user.email=…`. A config-driven failure → **STOP** and ask the user. No exceptions; if told to "fix the git setup," confirm the exact `git config` command first and run only that.

## Project layout — `~/src/<host>/[<group>/]<project>/<worktree>`

- Every checkout lives under **`~/src/<git-hostname>/[<group>/]<project>/`**, where `<git-hostname>` is the remote's host verbatim (`github.com`, `git.jpi.app`). **MUST NOT** clone anywhere else under `$HOME`; when the user names a project, resolve it here rather than searching `$HOME`.
- `<group>` is the GitHub **organization** or the GitLab **bottom-most subgroup**, normalized to kebab-case with its product-family prefix (`365flow` → `examvue-365-flow`). The segment is **REQUIRED**: **MUST** include it even when the project name already carries or repeats the group — GitLab `products/examvue-duo/examvue-apps` → `~/src/git.jpi.app/examvue-duo/examvue-apps/`, never `~/src/git.jpi.app/examvue-apps/`. The ONLY sanctioned omission is a remote with genuinely **no** group/org namespace at all (a rare edge case — when in doubt, it has one). The prefix is a human judgment call, not an algorithm: **MUST** mirror an existing sibling directory, and **MUST** ask the user when there is none to copy.
- By default a project directory is **not a working tree** — it is a bare repo plus its worktrees (a **non-bare** tree, below, is the exception):
  - `.bare/` — the bare repository (the only real git dir)
  - `.git` — a one-line file, `gitdir: ./.bare`
  - one directory per **worktree**, plus `.aoe-trash/` (agent-of-empires' deleted-worktree holding area — leave it alone)
- **MUST** `cd` into a worktree before doing any work: the project root has no checkout (`git status` there fails with "this operation must be run in a work tree") and `.bare/` is not one either. `main` is the default-branch worktree.
- A worktree directory is named after its **agent-of-empires session**, which is **not** its branch — `examvue-apps/wu` sits on `chore/add-claude-md-agents-imports`. The Git Flow gate below applies to the **branch**, never to the directory name; **MUST NOT** rename a worktree dir to match its branch, or a branch to match its dir.
- Worktrees are created and **locked** by `aoe` (agent-of-empires). **MUST NOT** hand-remove or unlock one (`git worktree remove` / `--force`) — delete through `aoe`, or ask the user.
- A tree MAY instead be **non-bare** — a plain `git clone` for a third-party tool you only want cloned and updatable, never developed via aoe worktrees. Its garden entry drops `bare: true`, the `/.bare` path suffix, and the fetch refspec, so `garden grow` does a normal clone and the project directory **is** the working checkout (a real `.git/`, no worktrees, no aoe session — the `setup-gitdir` / `setup-upstream` / `aoe-session` bootstrap commands self-skip it, so the wildcard bootstrap is safe on a mixed registry). `src-audit` recognizes both shapes. This is NOT a garden `worktree:` tree (still forbidden) — it is a non-bare tree.
- Clone a new project INTO the layout, never as a flat checkout — and never by a hand-rolled `git clone`: every project is **declared in the garden registry** (`~/src/garden.yaml`, chezmoi-managed 0444, age-ENCRYPTED in the public dotfiles repo — edit with `chezmoi edit ~/src/garden.yaml`, or non-interactively `chezmoi decrypt`/`chezmoi encrypt` on the source `src/encrypted_readonly_garden.yaml.age`, then `chezmoi apply`; never commit the trees list in plaintext). Run every `chezmoi` command through the zsh wrapper — `zsh -ic 'chezmoi <args>'` from a non-zsh shell — so it injects `GITHUB_TOKEN`; bare `chezmoi` renders `.chezmoiexternals/` against the anonymous GitHub API rate limit. `garden grow` performs the bare clone (or a plain clone for a non-bare tree); the default-branch worktree is created by **`aoe`**, not `git worktree add` — `aoe` owns and locks every worktree.

  ```sh
  # after adding the tree entry to the source garden.yaml + chezmoi apply:
  garden --chdir ~/src grow <name>                          # bare clone into <project>/.bare + fetch refspec
  # setup-gitdir writes the one-line "gitdir: ./.bare" pointer; setup-upstream fetches
  # origin and sets the upstream of every origin-mirrored branch (grow never fetches, so
  # a bare clone has no remote-tracking refs and no tracking info — `git pull` in the
  # default-branch worktree fails); aoe-session derives title/group/default-branch from
  # the tree and shells out to `aoe add` (aoe still creates + locks the worktree).
  # All idempotent — '*' bootstraps a new host.
  garden --chdir ~/src cmd <name> setup-gitdir setup-upstream aoe-session
  ```

  `garden cmd` takes **exactly ONE query**, then the command names: `garden cmd <QUERY> <COMMANDS>...`. Extra tree names silently become COMMAND names — `garden cmd a b setup-gitdir setup-upstream aoe-session` runs against tree `a` only, and `b` is read as a command. **MUST NOT** list several trees there; select many with a glob query (`'*'`, `'telerad-*'`) — all three commands are idempotent, so a broad query is safe. `garden grow` is the opposite (`grow <QUERIES>...`) and does take a tree list.

  Hand-run `aoe add ~/src/<host>/<group>/<project> -t <title> -g "<group-slug>/<project-name>" -w <branch>` only for a NON-default-branch worktree; `-w` takes the EXISTING branch (no `-b`).

- garden touches ONLY the repos it grows — bare repos (never their aoe worktrees) or a non-bare tree's plain clone. **MUST NOT** run `garden prune --rm` / `prune --no-prompt` / `garden plant`, and **MUST NOT** declare garden `worktree:` trees — worktrees stay aoe-owned. Audit drift read-only with `src-audit` (missing = grow on demand; broken = re-run `setup-gitdir` for a bare tree or `grow` for a non-bare one; unmanaged = surface to the user, never delete); a branch whose `git pull` reports no tracking information = re-run `setup-upstream` (`src-audit` does not check upstreams).

- An `aoe` session's **title** is its worktree name (`main` for the default branch), and its **group** is the project's path under `~/src/<host>/` — `[<group-slug>/]<project-name>`, a slash-nested group path (`examvue-365-flow/shadcn-registry`, `examvue-duo/examvue-apps`; only a genuinely group-less project is a bare `<project-name>`).
- Project identity lives in the **group**, never in the title. `session.tie_workdir_to_name` (aoe's default, on) makes the worktree directory leaf follow the title's slug — it bypasses `worktree.bare_repo_path_template` — so a project-named title would rename the directory too, and a later `aoe session rename` would MOVE it. **MUST NOT** put the project or group name in a session title, and **MUST NOT** disable the tie to work around that.
- Exception: the chezmoi source dir (`~/.local/share/chezmoi`) is chezmoi-owned and stays a plain checkout outside `~/src`.

## Branch ownership and naming — stay on the current branch

- Branch and worktree creation is owned by `aoe`. Without an explicit user instruction in the same turn, agents **MUST NOT** create or switch branches (`git checkout -b`, `git switch -c`, `git branch`, or an implicit equivalent) and **MUST NOT** create an `aoe` session. This rule overrides generic commit/worktree skills that would automatically create a feature branch. Renaming the **current** branch in place (`git branch -m`) is the one permitted exception — allowed **only** to bring it into Git Flow compliance under the conditions in the branch-naming rule below, never to create, switch, or fork a branch.
- Work **MUST** remain on the branch that was checked out when the task began unless the user explicitly directs a branch change (renaming the current branch in place to add a Git Flow prefix — per the branch-naming rule below — is not such a change: same ref, same commits, no switch). If that branch is the repository's default branch (`main`/`master`), it is valid and exempt from the Git Flow prefix rule. When the user asks to commit or push work performed there, **MUST** commit and push that same default branch; **MUST NOT** move the changes to a newly-created branch.
- An existing non-default branch **MUST** start with a Git Flow prefix: `feature/` `bugfix/` `hotfix/` `refactor/` `docs/` `chore/` `release/` (or the project's documented equivalent set). Before its first commit, **MUST** run `git branch --show-current` and confirm the prefix. A noncompliant current branch that is **absent from the remote** (not yet pushed — confirm the branch itself, e.g. `git ls-remote --exit-code --heads origin <branch>` returns nothing; a missing local upstream alone does **not** qualify, since a branch can be pushed without `-u`) may be renamed in place with `git branch -m` to add the prefix that matches the work, preserving the rest of the slug (`add-widget` → `feature/add-widget`) — this follows the project's flow without creating a new branch. If the branch already exists on the remote, **or** the correct prefix is genuinely ambiguous, **STOP** and ask the user or `aoe` owner instead: **MUST NOT** rename a branch that exists on the remote, **MUST NOT** guess a prefix, and **MUST NOT** rename a branch to match its worktree directory (see the layout rule above).
- When the user explicitly requests a new non-default branch through the `aoe` workflow, its slug **MUST** be a 3–6 word human summary (`-`-separated), not an issue title, number, or placeholder. **One task = one branch**; **MUST NOT** create a sibling branch.

## Commit messages

- **MUST** follow Conventional Commits: `<type>(<scope>)<!>: <description>`.
- Subject **MUST** be entirely lowercase — no exceptions for acronyms, brands, or proper nouns (commitlint `subject-case` rejects any uppercase; put canonical-case tokens in the body) — imperative, no trailing period, ≤50 chars (≤72 max).
- **MUST NOT**: emojis, sentence case, trailing periods, vague subjects (`update stuff`, `fix things`, `wip`), or AI-tool branding (no "Generated with Claude", no `🤖`, no AI `Co-authored-by:`).

## Rebase

- During a rebase Git's `--ours` / `--theirs` are **reversed** vs merge: `--ours` is the rebase target (`main`), `--theirs` is the feature commit being applied. Wrong side / direction → `git rebase --abort` and restart; **MUST NOT** continue.

## Issue ↔ MR scope

- One issue / work item is delivered by **exactly one** MR, regardless of size — **MUST NOT** split it into "phases", stacked/sequential MRs, or a chain of follow-up MRs. Deliver more commits in the single MR, not more MRs.
- **MUST NOT** author or restructure an issue body as sequential delivery "Phase 1 / Phase 2 …" sections that imply multiple MRs. Genuinely separable later work (a prod cut-over, a future migration) → a **separate issue** (itself one MR), linked as a follow-up — never a numbered delivery phase of the current issue.

## CI/CD

- **MUST** monitor the pipeline to a terminal state on every push that opens or updates a PR/MR — the task is done when it lands green, not when the push succeeds. **MUST NOT** declare ready / complete while a pipeline is failing, cancelled, or running.
- **MUST** wait on a running pipeline with a SINGLE native blocking call — `gh run watch <run-id> --exit-status`, `gh pr checks <n> --watch`, or `glab ci status --live`. **MUST NOT** poll it by re-running one-shot status commands as repeated tool calls, or by wrapping any pipeline check in a shell `while` / `until` / `for` / `sleep` / `watch` loop.
- **MUST NOT** "fix" a red pipeline by disabling / skipping / deleting a job, re-running hoping for green, pushing `[skip ci]` on a change-bearing commit, or force-pushing to hide history.

## Task completion — no silent deferral (guardrail)

- A task / issue / MR is **done** only when **every** in-scope item and stated acceptance criterion is actually delivered and verified in it. **MUST NOT** mark work complete while any item is unimplemented, stubbed, reverted, replaced with a weaker substitute, or pushed to a "follow-up" issue/PR, a `TODO`/`FIXME`, or a "known limitation" note. Difficulty or size is not a reason to defer — deliver more commits, not fewer items.
- Genuinely blocked (confirmed upstream/tooling bug, missing access, irreversible/destructive step, or a decision needing human judgment) → **STOP** and surface it to the user with concrete evidence + a proposed path + an explicit ask, then wait. Never silently defer and report done; a user-acknowledged blocker is the only acceptable incomplete item.

## Figma

- **MUST** use the `figma` MCP for any Figma URL; **MUST NOT** fetch via web fetch, browser, or screenshot tools. MCP unavailable → **STOP** and ask the user to fix it; **MUST NOT** improvise an alternative.
- **MUST** re-fetch the latest node every time a node ID is mentioned (cache only within the current turn), and **MUST** diff the fresh response against the implementation before declaring Figma parity, stating any gap explicitly.

## Interactive / long-running processes

- **MUST** use the `tmux` tool (`mcp_interactive_bash`) for dev servers, watch modes, TUIs, REPLs, build watchers — anything that does not terminate. Regular shell execution blocks the session and is **forbidden** for non-terminating commands.

## Temporary / scratch files

- The **shared system temp** dir is **denied** — **MUST NOT** read, write, or execute under `/tmp`, `/var/tmp`, or `/dev/shm`; every operation on those paths fails. This covers ad-hoc scripts, captured logs / command output, and PR / MR / issue body drafts.
- **MUST** use a **per-user** temp dir instead: `$XDG_RUNTIME_DIR` (or `~/.cache` when it is unset or the file is large) on Linux, `$TMPDIR` on macOS, `$env:TEMP` / `%TEMP%` on Windows. Keep scratch in a task-scoped subdir (e.g. `"$XDG_RUNTIME_DIR/agent-scratch"`) and **SHOULD** remove it when the task ends.
- **SHOULD** prefer a git-ignored path **inside the workspace** for files that belong to the task; reserve the per-user temp dir for throwaway scratch that must stay outside the repo.

## Container runtime — rootless Podman (guardrail)

- This host uses **rootless Podman** as its sole container runtime. Docker is not installed.
- **MUST** use `podman` (or the `docker` CLI shim provided by `podman-docker`) for all container operations — `podman run`, `podman build`, `podman compose`, etc.
- **MUST NOT** install Docker, reference `docker.io/docker-ce`, or assume the Docker daemon (`dockerd`) is present. The `docker` binary on this host is the `podman-docker` compatibility shim; it forwards to `podman` and does not start a daemon.
- **MUST NOT** use `sudo podman` unless explicitly required for a root-owned resource. Rootless is the supported mode; all user-space container work runs without `sudo`.
- The rootless socket is at `$XDG_RUNTIME_DIR/podman/podman.sock`. Docker-API clients that read `DOCKER_HOST` are already pointed there via `~/.config/environment.d/65-containers.conf` — no manual override needed.
- Registry auth uses `podman login <registry>` (credentials stored in `~/.config/containers/auth.json`). **MUST NOT** write to or rely on `~/.docker/config.json` — that file is not managed on this host.

## Browser automation (Playwright) — host safety

- Run Playwright **directly** on the host — `npx playwright install`, `playwright install-deps`, and a host-installed browser are all allowed. No container indirection is needed. (Test/automation usage → `playwright-cli`.)

## Scripting runtime

- **MUST NOT** use Python for any new scripting, tooling, or codegen; **MUST** use Node.js / Deno / Bun (TypeScript preferred). Shell (`bash` / PowerShell) is acceptable for system bootstrap and OS glue only — **MUST NOT** use it for application logic or codegen. Exception: an established Python project with existing Python tooling — match it and state the exception.

## JavaScript package managers

- User-global config hardens npm / pnpm / Yarn / Bun via three switches — lifecycle scripts disabled, exact-version pinning, 1-week cooldown. **MUST** preserve all three; **MUST NOT** edit user-global configs to relax any of them.
- **MUST** pin every `dependencies` / `devDependencies` / `optionalDependencies` entry to an exact version (no `^` `~` `>=` `latest` `*` `x`); **MUST** correct an existing range when editing a `package.json` for any reason; **MUST NOT** introduce a range or hand-edit a lockfile to dodge the rule.
- `peerDependencies` are the **exception**: they **MUST NOT** be exact-pinned — declare the widest compatible range (`^<major>`, `>=`, `^18 || ^19`, or `*`). **MUST NOT** "correct" a peer range to an exact pin. Internal lockstep/prerelease-versioned peers are the sub-exception and stay exact-pinned; a project `AGENTS.md` may codify this.
- Cooldown: a version **MUST** be ≥1 week old — pin the most recent that qualifies. **MUST NOT** add a package to a preapproved / exclude list, nor lower the cooldown, without explicit per-package user approval.

## mise (tool version manager)

- If any command fails with a `mise ERROR … not trusted` message, **MUST** immediately run `mise trust <path-to-mise.toml>` (or `mise trust` in the project root) before retrying. **MUST NOT** proceed with the original command while the trust error persists.
- After trusting, re-run the original command in the same turn — do not ask the user to do it.

## GitLab CLI (glab)

- **MUST** pass project paths to `glab` / `glab api` with slashes intact (`group/sub/project`), never URL-encoded (`group%2Fsub%2Fproject`); prefer `:fullpath` when the repo remote points at the target.
