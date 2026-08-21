---
title: "feat: Trim merged local branches on aoe session teardown"
date: 2026-08-21
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# feat: Trim merged local branches on aoe session teardown

## Goal Capsule

- **Objective.** Removing an aoe worktree/session also clears the merged, never-pushed local branches that accumulate in that project's git repository, so a long-lived garden tree stops collecting dead refs.
- **Means.** Append `git trim --no-confirm --delete 'local'` to the `on_destroy` lifecycle hook of the managed aoe `main` profile template (KTD1).
- **Authority hierarchy.** The user's verbatim command string and target file outrank everything else here (KD1, KD2). Below that: the root `AGENTS.md` chezmoi source rules, then this plan.
- **Stop conditions.** Stop and report instead of guessing if: the rendered target is not valid TOML; the render recipe cannot run; or evidence appears that a profile-level `on_destroy` failure can block session deletion (that would invert R6 and make the hook unsafe).
- **Execution profile.** Configuration change. The right first proof is a render/smoke check plus a `git trim --dry-run` observation, not unit tests (this repo has no test seam for a deployed TOML target).
- **Tail ownership.** Standalone: commit, push, open a PR. The PR is deliberately **not** merged by the run that opens it.

## Product Contract

### Summary

One managed line changes. `dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl` gains a second `on_destroy` hook command so that aoe, when it deletes a session, runs `git trim --no-confirm --delete 'local'` in the session's worktree before it removes that worktree.

### Problem Frame

Every aoe session in this garden lives on its own branch in its own locked worktree. `[worktree] delete_branch_on_cleanup = true` (`dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl:30`) already deletes the session's own branch at teardown, and this repo already ships an operator-run pruner for the rest — `dot_local/bin/executable_git-prune-local-branches`, report-first, `--apply`-gated, GitHub-merged-PR-proofed, worktree-guarded, and covered by `.ci/test-git-prune-local-branches.sh` (origin: issue #217). What is missing is not a tool but an occasion: that helper is never invoked automatically anywhere in this repo, so the sweep happens only when someone remembers to run it. This hook supplies the occasion for the narrowest slice of the problem. `--delete local` reaps only **non-tracking** merged branches, so a branch the garden's `setup-upstream` gave an upstream — which is every branch that was ever pushed — is out of reach by construction. What is left in range is the never-pushed kind: a branch created outside aoe, a branch left behind when a cleanup half-failed, a branch whose worktree was removed by hand long ago. Naming that population honestly is the point: the hook is an automatic sweep of local-only residue at the moment the user already intends cleanup, not a replacement for the forge-proofed helper.

### Requirements

- **R1.** The `on_destroy` hook array in `dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl` contains `git trim --no-confirm --delete 'local'`.
- **R2.** That command string is verbatim as directed, single quotes included (KD1).
- **R3.** `mise untrust` stays in `on_destroy` and stays first; `on_create` and `on_launch` are untouched.
- **R4.** The template still renders to valid TOML, and the rendered output differs from the pre-change render only in the `on_destroy` array.
- **R5.** No other managed surface changes: no `hooks` key added under `agents.aoe."config.toml"` in `.chezmoidata/agents.yaml`, no change to `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl`, no new script, no new CI check.
- **R6.** A failing or slow `git trim` must not be able to block session deletion or suppress the other `on_destroy` command. This is a property of aoe to *confirm* from upstream evidence, not something this change implements.

### Key Decisions

- **KD1. The command string is used verbatim, including `'local'`.** (session-settled: user-directed — chosen over `--delete merged,local` or adding `--no-update`: the user specified the exact flags, and the quotes are inert under aoe's shell execution, so nothing is gained by editing them.) Governs R1, R2.
- **KD2. The declaration site is the managed `main` profile template, not a repo-level `.agent-of-empires/config.toml`.** (session-settled: user-directed — chosen over per-repo hooks: the user named the profile file, and repo-level hooks additionally sit behind aoe's trust gate, so they would silently skip after any edit.) Governs R1, R5.

### Scope Boundaries

- **In scope.** The one hook array in the one template file, plus this plan.
- **Out of scope.** Widening the delete range to tracking branches (`merged`, `stray`, `diverged`), setting `trim.bases` / `trim.protected` / `trim.delete` git config, adding `--no-update`, and any change to the other two hook events. Each is a separate decision with its own risk, and none was asked for.
- **Not a goal.** Making trimming reachable from `on_create`/`on_launch`, replacing aoe's own `delete_branch_on_cleanup`, or replacing `dot_local/bin/executable_git-prune-local-branches`. The two sweeps have different safety models and both stay: the helper proves a merged PR on the forge before deleting and refuses on a bounded timeout, while `git trim` decides locally from merge topology. Consolidating them is a separate decision.

## Planning Contract

### Key Technical Decisions

- **KTD1. Append as the second element of `on_destroy`, after `mise untrust`.** aoe runs the array in declared order and — for `on_destroy` specifically — best-effort, attempting every command even when an earlier one fails (`src/session/deletion.rs`, `run_on_destroy_hooks` doc comment: "Uses best-effort execution so all hooks are attempted even if some fail"). So order is a readability choice, not a correctness one; keeping the cheap `mise untrust` first preserves the existing line's meaning at a glance. Instantiates KD1.
- **KTD2. The single quotes are safe because aoe executes host hooks through the user's shell.** `build_hook_command` in `src/session/repo_config.rs` builds `Command::new(shell).arg("-c").arg(shell_cmd).current_dir(project_path)` for local hooks ("Local hooks use the user's `$SHELL`"), and the upstream hooks guide documents shell semantics by telling authors to quote expansions (`on_create = ["port \"$AOE_SESSION_TITLE\""]`). `zsh -c` strips the quotes, so git-trim receives the argument `local`, not `'local'`. Had aoe split argv itself, git-trim would have rejected the literal `'local'` as an invalid delete range — that was the one way the verbatim string could have failed, and it is closed. Governs R2.
- **KTD3. Rely on git-trim's own preservation filters rather than adding `--protected`.** git-trim resolves `git worktree list --porcelain` and drops every branch checked out in any worktree (`src/core.rs`, `preserve_worktree`, reason `worktree at <path>`), and it never deletes a base branch (`--bases`, default: whatever tracks `refs/remotes/*/HEAD`). Verified locally in this checkout: a `--dry-run --no-update --delete local` listed all 16 sibling branches under "Branches that will remain" and named exactly one deletion candidate. `--delete local` is also the narrowest useful range — it scans only *non-tracking* merged branches, so every branch the garden's `setup-upstream` gave an upstream is out of scope by construction, and no remote ref is ever touched. Governs R1, R6.
- **KTD4. Accept that git-trim detaches HEAD to delete the session's own branch.** With no `--no-detach`, git-trim detaches HEAD and deletes the current branch when that branch itself is a merged non-tracking branch — which is exactly the session branch case at teardown (observed in the same dry run). This is benign here: the hook runs *before* aoe removes the worktree, and aoe's own `delete_branch_on_cleanup` treats an already-absent branch as success ("delete_branch: branch already absent, treating as success"). Adding `--no-detach` was rejected as an unrequested behavior change (KD1). Governs R6.
- **KTD5. No new test or CI gate.** No `.ci/` check and no workflow covers `dot_config/**` beyond the render itself; `.github/workflows/render-dotfiles.yml` already renders this target into a throwaway `$HOME`, which is the whole available contract for a deployed TOML file. Adding an aoe-specific test harness for one config line is not proportionate. Governs R5.

### Assumptions

- aoe's hook semantics are those of the pinned release (`aoe` v1.14.1 in `.chezmoidata/releases.json`), read from upstream `agent-of-empires/agent-of-empires` at `src/session/deletion.rs`, `src/session/repo_config.rs`, and `docs/guides/repo-config.md`.
- `git trim` is reachable from a non-interactive hook shell. Verified, not assumed: `dot_config/zsh/dot_zshenv:1` runs `eval "$(mise activate zsh)"`, and `.zshenv` is read by `zsh -c`, so `env -i HOME=$HOME zsh -c 'command -v git-trim'` resolves the mise install path.
- The teardown-time cost of the default `--update` behavior is accepted, not overlooked. Without `--no-update` (out of scope per KD1) git-trim runs `git remote update --prune` before it scans, so every session deletion does a blocking network fetch, throttled to once per 5s by `--update-interval`. Offline or on a slow link that shows up as teardown latency until git's own timeout fires. Teardown is already asynchronous from the user's viewpoint (aoe deletes the row after the hooks return), and failures are warnings, so the cost is latency, never a wedged session.
- **That accepted cost is the same failure shape issue #227 fixed in the sibling helper, and this change does not carry the fix over.** `git-prune-local-branches` was hardened with `GIT_TERMINAL_PROMPT=0` and a bounded timeout on every `ls-remote`/`fetch` precisely because an auth prompt or unreachable remote could block it indefinitely. `git trim` has no such wrapper here. aoe's TUI and web paths detach the hook and export `GIT_TERMINAL_PROMPT=0`/`GIT_ASKPASS=true`, so a prompt cannot hang those; the CLI path (`aoe remove` from a terminal) leaves the hook attached, where a credential prompt can block until the operator answers. The verbatim command is user-directed (KD1), so the mitigation is named rather than applied: `--no-update` removes the fetch entirely, and it is one token if the latency is ever felt.
- Trimming before removal means the branch ref can be gone while the worktree is still on disk. If aoe's own worktree removal then fails (permissions, a file lock), the leftover directory is in detached HEAD with its branch already deleted, which makes manual recovery harder than a plain failed cleanup. Accepted because git-trim only deletes branches it has proved merged, so nothing unreachable is lost.
- Three shadow paths end in a non-zero exit that aoe absorbs as a logged warning, and none of them is guarded: a scratch session whose project path is not a git repository at all (`fatal: not a git repository`), a repository with no `origin/HEAD` for git-trim to derive its base from, and two sessions of the same repository torn down concurrently (git ref/index lock contention).
- Sandboxed sessions are the one configuration where this hook cannot work: aoe runs hooks inside the container for them (`execute_hooks_in_container_best_effort`), and the sandbox image has no `git-trim`. The failure is a logged warning, so it is accepted rather than guarded.

### Sequencing

Single unit. The plan itself is the only other artifact.

## Implementation Units

### U1. Append the trim command to the `on_destroy` hook

- **Goal.** `on_destroy` runs `mise untrust` and then `git trim --no-confirm --delete 'local'`.
- **Requirements.** R1, R2, R3, R4, R5.
- **Files.** `dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl` (line 3 only).
- **Approach.** Replace the single-element `on_destroy` array with a two-element array, keeping `mise untrust` first (KTD1). Do not reformat, reorder, or touch any other line — this template is a static TOML target with no conditional logic around `[hooks]`.
- **Test scenarios.** None as automated tests (KTD5). The behavior scenarios the verification below must cover: (a) the rendered `on_destroy` is a two-element TOML array of strings; (b) the rest of the render is byte-identical to the pre-change render; (c) `git trim --delete local` in a real worktree of this repository leaves every sibling worktree branch and every tracking branch alone.
- **Verification.** The Verification Contract below, in order.

## Verification Contract

1. **Render the changed template in isolation** (root `AGENTS.md`, "Verification"; the stub `op` is required because the repo's render recipe is shared across templates that resolve `op://` refs):

   ```sh
   scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
   mkdir -p "$scratch/bin" "$scratch/target"
   : > "$scratch/empty.toml"
   printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
   chmod 700 "$scratch/bin/op"
   env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" \
     --destination "$scratch/target" execute-template \
     < dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl
   ```

   Gate: exit 0, and the output parses as TOML with `hooks.on_destroy == ["mise untrust", "git trim --no-confirm --delete 'local'"]`.
2. **Diff the render against the pre-change render.** Render `HEAD`'s copy of the template through the same recipe and diff the two outputs; the only difference must be the `on_destroy` line (R4):

   ```sh
   git show HEAD:dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl \
     | env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" \
         --destination "$scratch/target" execute-template
   ```
3. **Smoke the command itself** with `git trim --dry-run --no-update --delete local` in this worktree, and confirm the output keeps every sibling branch under "Branches that will remain" (KTD3). `--dry-run` is mandatory here: the repository's own rules forbid running an unverified destructive git command, and `--no-update` keeps the probe off the network.
4. **CI**: after push, watch `.github/workflows/render-dotfiles.yml` and `.github/workflows/ci.yml` to terminal success. The render workflow is the gate that actually exercises this file; `ci.yml` runs the `.ci/` suites, none of which claim this path.

## Definition of Done

- R1–R5 are true in the source tree, and R6 is documented with upstream evidence (KTD1, KTD4).
- Verification steps 1–3 pass locally; step 4 is green.
- **Verification limitation, stated rather than closed.** Nothing above observes the hook actually firing: steps 1–3 prove the rendered config and the command in isolation, so a defect in the live path (a hook-shell environment difference, an aoe timeout, an unexpected git-trim exit) would surface only on the first real session deletion. Closing it would mean creating and deleting a throwaway aoe session, and session lifecycle is aoe-owned — the instruction core forbids creating one without explicit user direction. What would falsify "this works" is therefore a post-apply observation, not a step of this plan: after the next `chezmoi apply`, the first session deletion should log no `on_destroy` hook failure (`aoe logs`), and the trimmed branch should be gone from `git branch`.
- `git diff` touches exactly two files: the template and this plan.
- No scaffolding, commented-out variants, or leftover probe scripts remain.
- The branch is pushed and a PR is open. Merging is explicitly out of scope for the opening run.
