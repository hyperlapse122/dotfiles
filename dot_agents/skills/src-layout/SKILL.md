---
name: src-layout
description: >
  Playbook for creating and maintaining the
  ~/src/<host>/[<group>/]<project>/<worktree> project layout with the garden
  registry. Load this BEFORE cloning any repository, registering a new project
  under ~/src, choosing or normalizing a group directory name, migrating a
  flat checkout into the layout, or auditing ~/src for drift. Triggers:
  "clone <url>", "set this repo up locally", "add/register a project",
  "where should this checkout live", "src-audit", "garden grow", "layout
  drift". It covers the group-name judgment procedure (mirror-or-ask), the
  garden.yaml tree-entry format and chezmoi edit flow, the grow +
  setup-gitdir bootstrap, the aoe add handoff, the src-audit report and
  remediation, and the forbidden garden operations. Do NOT load it for branch
  naming/commits (use `git-workflow`), for worktree/session management (aoe
  owns those), or for ordinary work inside an already-set-up project.
---

# ~/src Project Layout (garden)

Division of labor — four tools, no overlap:

| Concern | Owner |
|---|---|
| Declared registry of every project (path + url) | `~/src/garden.yaml` — chezmoi-managed 0444; SOURCE is `src/encrypted_readonly_garden.yaml.age` in the chezmoi repo (age-encrypted: the dotfiles repo is public, the project list is not) |
| Bare clone into `<project>/.bare` + fetch refspec | `garden --chdir ~/src grow <name>` |
| `.git` → `gitdir: ./.bare` pointer file | `garden --chdir ~/src setup-gitdir <name>` (custom command declared in the manifest) |
| Worktrees + sessions (create, lock, remove) | `aoe` ONLY — never `git worktree`, never garden `worktree:` trees |
| Drift audit (read-only) | `src-audit` |

## Register + clone a new project

1. **Host segment** — the remote host verbatim: `github.com`, `git.jpi.app`.
2. **Group segment (human judgment — never algorithmic)**:
   - List existing candidates to mirror: `ls ~/src/<host>/ 2>/dev/null` AND the
     declared `path:` values in `~/src/garden.yaml`.
   - The group is the GitHub org / GitLab bottom-most subgroup, kebab-cased
     with its product-family prefix (`365flow` → `examvue-365-flow`).
   - **Omit** the segment when the project name already carries the group
     (GitLab `products/examvue-duo/examvue-apps` → `git.jpi.app/examvue-apps`).
   - MUST mirror an existing sibling directory when one exists; MUST ask the
     user when there is none to copy.
3. **Edit the SOURCE manifest** — it is age-encrypted
   (`src/encrypted_readonly_garden.yaml.age`); the deployed `~/src/garden.yaml`
   is 0444 and must never be edited in place, and the plaintext must never be
   committed. Interactively: `chezmoi edit ~/src/garden.yaml` (transparent
   decrypt/re-encrypt). Non-interactively (agents):

   ```sh
   cd "$(chezmoi source-path)"
   chezmoi decrypt src/encrypted_readonly_garden.yaml.age > "$XDG_RUNTIME_DIR/garden.yaml"
   # edit the scratch copy, then:
   chezmoi encrypt "$XDG_RUNTIME_DIR/garden.yaml" > src/encrypted_readonly_garden.yaml.age
   rm "$XDG_RUNTIME_DIR/garden.yaml"
   ```

   Run every `chezmoi` command through the zsh wrapper — from a non-zsh shell,
   `zsh -ic 'chezmoi <args>'` — so `GITHUB_TOKEN` is injected (the dotfiles
   zshrc defines the wrapper; bare `chezmoi` renders `.chezmoiexternals/`
   against the anonymous GitHub API rate limit and 403s after a few runs).

   Add under `trees:` (replace a bare `trees: {}` if present):

   ```yaml
   trees:
     <project>: # tree name = project leaf; "<group>-<project>" on collision
       path: <host>/[<group>/]<project>/.bare
       url: git@<host>:<remote-namespace>/<project>.git
       bare: true
       gitconfig:
         remote.origin.fetch: "+refs/heads/*:refs/remotes/origin/*"
   ```

   Then `chezmoi apply` to deploy the manifest (commit the source change per
   the repo's commit rules).
4. **Bootstrap**:

   ```sh
   garden --chdir ~/src grow <name>          # bare clone + refspec (idempotent)
   garden --chdir ~/src setup-gitdir <name>  # one-line .git pointer file
   ```
5. **Hand off to aoe** — default-branch worktree + session. `-w` takes the
   EXISTING branch (no `-b`); the title stays the worktree name (`main` for the
   default branch) and project identity goes in the group, never the title:

   ```sh
   aoe add ~/src/<host>/[<group>/]<project> -t <default-branch> -g "[<group-slug>/]<project>" -w <default-branch>
   ```
6. **Verify**: `git -C ~/src/<host>/[<group>/]<project> log --oneline -1`
   resolves via the pointer; `git -C .../.bare rev-parse --is-bare-repository`
   prints `true`; the default-branch worktree directory exists.

## Audit & remediation

Run `src-audit` (read-only; exit 0 = clean or missing-only, 1 = drift, 2 =
setup problem):

| Finding | Meaning | Remediation |
|---|---|---|
| missing | Declared in the manifest but not grown on this host | Informational — the manifest is the union across hosts. Grow on demand. Remove the tree entry only when the project is retired everywhere. |
| broken | Grown, but the project root's `.git` pointer is absent/wrong | `garden --chdir ~/src setup-gitdir <name>` |
| unmanaged | Repo on disk under ~/src that no declared project accounts for | Layout violation: either register it (tree entry + migrate to the bare shape) or relocate/delete — but surface that decision to the user; never delete a repository or worktree yourself. |

Migrating a flat checkout INTO the layout: add the tree entry, `garden grow` a
fresh bare clone, recreate worktrees via `aoe add`, then port uncommitted work
with `git diff`/`git format-patch` from the old checkout; removing the old
checkout is the user's call.

New host / grow everything at once: `garden --chdir ~/src grow '*'`.

## Forbidden

- `garden prune --rm` or `prune --no-prompt` — prune false-positives every
  properly-shaped project root (declared path is `.bare`, not the root), so
  `--rm` would offer to delete real projects. `src-audit` wraps prune safely.
- `garden plant` — would rewrite the 0444 deployed manifest with wrong
  (non-`.bare`) paths.
- garden `worktree:` trees, `git worktree add/remove/unlock` — worktrees are
  created and locked exclusively by aoe.
- Deleting anything under `~/src` yourself — deletion goes through aoe (for
  worktrees/sessions) or the user.
- Editing `~/src/garden.yaml` in place — edit the chezmoi SOURCE and apply.
