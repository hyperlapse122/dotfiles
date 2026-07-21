# Agent Instructions

This file is the common user-scoped instruction core, included verbatim by the Claude Code, Codex, OpenCode, and Pi wrappers. Use RFC 2119 terms literally. The repository root `AGENTS.md` is the local supplement and may be stricter; read it before changing this checkout. Edit this source, never deployed instruction targets.

## Routing and mirrors

Load the named operation skill before the operation: `playwright-cli` for browser/Playwright work. Do not add mandatory `ce-work`/`ce-debug` routing here; use the available workflow and the user's direction.

Every directory containing `AGENTS.md` MUST have a sibling `CLAUDE.md` whose entire content is `@AGENTS.md`. MUST create it in the same turn when creating `AGENTS.md`, and MUST repair it whenever it is missing or contains anything else. Edit `AGENTS.md` only; never let the mirror drift.

## Secrets, destructive actions, and runtime

- MUST NOT commit `.env`/`.env.*` except examples, private keys, age/GPG/SSH keys, tokens, OAuth/webhook/deploy secrets, cloud credentials, or password-bearing connection strings. If one is committed, STOP, notify the user, treat it as compromised, and rotate it; never rewrite history without approval.
- MUST NOT pass credentials from a store or environment to a non-native tool. Let the official CLI inject them; auth failure means STOP and ask the user to re-login.
- MUST NOT run `git commit/push --no-verify`, force-push shared branches, destructive reset/clean, amend a pushed commit, interactive rebase, or other history rewrite without explicit same-turn approval. `rm -rf` outside ignored/build directories is forbidden; when genuinely required, confirm the exact command and what it destroys first.
- MUST NOT modify git config or identity at any scope (`--system`, `--global`, `--worktree`, `--local`, environment identity overrides). A config-driven failure means STOP and ask; if the user explicitly directs a fix, confirm the exact command and run only that command.
- Use rootless Podman, never install or assume Docker/dockerd, and never use `sudo podman` unless a root-owned resource requires it. The `docker` CLI is only the podman-docker shim; it forwards to Podman and does not start a daemon. Docker-API clients use the rootless socket at `$XDG_RUNTIME_DIR/podman/podman.sock`, with `DOCKER_HOST` already configured by `~/.config/environment.d/65-containers.conf`. Registry auth uses `podman login <registry>`; credentials belong in `~/.config/containers/auth.json`, never `~/.docker/config.json`.

## Repository layout and garden ownership

Developed projects belong under `~/src/<remote-host>/<group>/<project>/`: host is literal; the group/org segment is required, including nested GitLab subgroups, and is normalized by mirroring an existing sibling. Only a genuinely group-less remote may omit it; if no sibling establishes the prefix, ask rather than guess. Never put project identity in an aoe title. The chezmoi source checkout `~/.local/share/chezmoi` is the explicit plain-checkout exception outside `~/src`.

The default project container is not a worktree: `<project>/.bare` is the only real git dir, root `.git` is `gitdir: ./.bare`, and aoe owns locked worktrees. A non-bare plain clone is allowed only for a dependency never developed through aoe. Work in a worktree, never the project container or `.bare`; leave `.aoe-trash/` alone. Never hand-remove/unlock worktrees; delete through aoe or ask its owner. Garden entries MUST be declared in encrypted `~/src/garden.yaml` source state and MUST NOT declare `worktree:` trees. Use `garden grow`, never hand-run clone, `garden plant`, or destructive prune.

Edit the garden through the zsh chezmoi wrapper (`zsh -ic 'chezmoi <args>'` from non-zsh), so `GITHUB_TOKEN` is injected; edit `~/src/garden.yaml` with `chezmoi edit`, or decrypt/encrypt `src/encrypted_readonly_garden.yaml.age` non-interactively using per-user scratch, then apply. Never commit plaintext. The exact idempotent bootstrap is:

```sh
garden --chdir ~/src grow <name>
garden --chdir ~/src cmd <name> setup-gitdir setup-upstream aoe-session
```

`garden grow` accepts multiple queries; `garden cmd` takes exactly one query, then command names. Use `'*'` (or another glob) for many trees with `cmd`. Grow creates the bare/plain repo but does not fetch; `setup-gitdir` writes the pointer, `setup-upstream` fetches origin and sets tracking for matching origin branches, and `aoe-session` derives title/group/default branch and asks aoe to create/lock the worktree. This is why a fresh bare tree otherwise has no remote-tracking refs or `git pull` upstream. For a non-default existing branch only, `aoe add <project> -t <title> -g <group/project> -w <existing-branch>`; never use `-b`.

`src-audit` is read-only: missing tree => grow on demand; broken bare pointer => rerun `setup-gitdir`; broken non-bare tree => grow; unmanaged => surface, never delete. A branch whose pull lacks tracking => rerun `setup-upstream` (audit does not check upstreams). Session title is the worktree name (default `main`), group is the project path; worktree name and branch name are never interchangeable, and never rename either to match the other.

## Branches, commits, issues, blockers

Work MUST remain on the checked-out branch. Branch/worktree/session creation is aoe-owned: without explicit same-turn user direction, MUST NOT create or switch branches or sessions. The default branch is valid without a prefix. Other local branches MUST use `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `docs/`, `chore/`, or `release/` (or the documented equivalent). A noncompliant branch may be renamed in place only when that branch itself is absent from the remote; preserve its slug (`add-widget` -> `feature/add-widget`) and choose the prefix from the work, never the worktree name. When the existing slug does not describe the work — a placeholder, default, or session/worktree-derived name (e.g. `japanese`, `work`, `wip`, `tmp`, `patch`, `test`, a bare date, or the aoe worktree name) — preserving it is wrong: MUST rename to a work-descriptive Git-Flow slug (prefix from the work, 3–6-word summary of the change) instead of prefixing the meaningless one, so `japanese` for a caching fix becomes e.g. `bugfix/list-report-images-refetch`, never `bugfix/japanese`. Before the first push or MR/PR of any branch whose name still does not describe the work, MUST autonomously rename it in place to a work-descriptive Git-Flow slug (prefix from the work, 3–6-word summary) and proceed without asking; never push a non-descriptive name to a shared remote and never block on user confirmation for the slug. Never rename a remote branch or guess an ambiguous prefix. An explicitly requested new branch has a 3–6-word human summary slug. One task/issue = one branch and one MR/PR; MUST NOT create sibling branches or split delivery into phases/stacked MRs. Issue bodies MUST NOT present sequential “Phase 1/2” delivery; separate future work is a separate issue.

Commit subjects MUST be lowercase Conventional Commits, imperative, specific, no emoji/AI attribution/trailing period, <=50 chars where possible (<=72 maximum). During rebase, ours is the target and theirs is the feature commit; on error abort and restart.

After every push opening/updating a PR/MR, wait for terminal green CI with one native blocking watcher (`gh run watch --exit-status`, `gh pr checks --watch`, or `glab ci status --live`); never poll, weaken, skip, rerun to hide, or `[skip ci]` a failure. A task is complete only when every criterion is implemented and verified. A confirmed tooling/access/destructive/product blocker MUST be surfaced with evidence, a proposed path, and an explicit ask, then wait. A user-acknowledged blocker is the only acceptable incomplete state; never silently defer to TODO/FIXME, “known limitation,” or follow-up.

## Figma, processes, scratch, and browser

Figma URLs MUST use the `figma` MCP; re-fetch each mentioned node and diff it before claiming parity; unavailable MCP means STOP. Use tmux/interactive shell for servers, watches, TUIs, and REPLs. Playwright runs directly on the host after loading `playwright-cli`.

The shared `/tmp`, `/var/tmp`, and `/dev/shm` are denied. Use a task-scoped `$XDG_RUNTIME_DIR` directory on Linux (when unset, fall back to `~/.cache`, never `/tmp`), `$TMPDIR` on macOS, or `%TEMP%` on Windows; prefer ignored workspace paths and clean scratch. New scripting/tooling/codegen uses Node/Deno/Bun or shell for OS glue, not Python (except established Python tooling).

## JavaScript, mise, and GitLab

Dependencies, devDependencies, and optionalDependencies MUST be exact-pinned and at least one week old; choose the newest qualifying version. Correct ranges when editing `package.json`. Peer dependencies MUST remain widest compatible ranges; exact internal lockstep/prerelease peers stay exact-pinned. MUST NOT relax lifecycle/exact/cooldown settings, add cooldown exclusions, or lower the cooldown without explicit per-package approval.

If mise reports `mise ERROR … not trusted`, immediately run `mise trust <path-to-mise.toml>` (or trust in the root) and retry the original command. Pass GitLab paths to `glab` with slashes intact; prefer `:fullpath`.

## Project supplement

The root `AGENTS.md` owns chezmoi source attributes, data/script/system ownership, host facts, desktop/container gates, agent and CLIProxyAPI contracts, isolated verification, and repository delivery details. It may add stricter local rules; do not treat this common core as permission to weaken them.
