# Plan 004: Bound the auto-updating prezto external so `chezmoi apply` stops tracking a moving upstream HEAD

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7a12e58..HEAD -- .chezmoiexternals/prezto.toml dot_config/zsh/dot_zshrc`
> If either file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `7a12e58`, 2026-07-01

## Why this matters

`.chezmoiexternals/prezto.toml` declares the Prezto zsh framework as a chezmoi
`git-repo` external with **no ref pin**. chezmoi clones the upstream default
branch and can `git pull` it on apply, and `dot_config/zsh/dot_zshrc` **sources
that checkout on every interactive shell** (`source …/.zprezto/init.zsh`). That
means whatever the upstream default branch happens to contain — including a
force-pushed or compromised commit — can start executing in your login shells
after a routine `chezmoi apply`/`chezmoi update`, with no review step. This is a
standard-but-real dotfiles supply-chain exposure.

**Honest scope note (read before starting):** Prezto publishes **no release
tags**, and chezmoi's `git-repo` external cannot pin an arbitrary commit SHA
(`--branch` accepts only a branch/tag). So this plan does **not** achieve a
cryptographic pin. What it *does* achieve, cleanly and verifiably, is removing
the "pull latest on every apply" behavior: it freezes the external at its
already-cloned commit and requires an **explicit, deliberate** refresh to
update. That shrinks the exposure window from "every apply" to "only when you
choose to update." A true SHA pin requires a larger decision (fork-and-pin or
vendoring) that is deliberately deferred to the maintainer — see Step 3 and
Maintenance notes. Do not attempt the fork yourself.

## Current state

- **File**: `.chezmoiexternals/prezto.toml` (8 lines, Go-templated):

  ```toml
  {{- if ne .chezmoi.os "windows" }}

  [".config/zsh/.zprezto"]
  type = "git-repo"
  url = "https://github.com/sorin-ionescu/prezto.git"
  clone.args = ["--recursive"]

  {{- end }}
  ```

  There is no `refreshPeriod`, no `pull.args`, and no pinned ref. `--recursive`
  is required because Prezto pulls contrib modules as git submodules (this is
  why a plain archive tarball cannot replace the git-repo external — the
  submodule contents would be missing).

- **The consumer**: `dot_config/zsh/dot_zshrc` lines 9–11:

  ```zsh
  if [[ -s "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
    source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
  fi
  ```

- **chezmoi external-refresh semantics you must confirm (Step 1):** chezmoi
  refreshes externals based on `refreshPeriod`; a longer period means it does not
  re-pull on every apply, and `chezmoi apply --refresh-externals` forces a
  refresh regardless. Verify the exact behavior for `type = "git-repo"` against
  the installed chezmoi's docs/help before relying on it (versions differ).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm current file | `cat .chezmoiexternals/prezto.toml` | matches "Current state" |
| chezmoi external docs | `chezmoi --help` / consult `https://www.chezmoi.io/reference/target-types/` (`.chezmoiexternal` / externals) | confirms `refreshPeriod` + `--refresh-externals` semantics |
| Render check | `chezmoi execute-template < .chezmoiexternals/prezto.toml` | renders valid TOML on non-Windows (needs no secrets) |
| Managed check (optional) | `chezmoi managed \| grep zprezto` | the external target still listed |

> The render command uses the current OS. `chezmoi` may hold a state lock if
> another chezmoi process is running; if a command reports a lock timeout, STOP
> and report rather than forcing it.

## Scope

**In scope** (the only file you should modify):
- `.chezmoiexternals/prezto.toml`

**Out of scope** (do NOT touch):
- `dot_config/zsh/dot_zshrc` and any other zsh config — the consumer is fine;
  the fix is at the external declaration.
- Forking Prezto, changing the `url`, or vendoring a commit — that is the
  deferred decision in Step 3; do NOT do it in this plan.
- `clone.args = ["--recursive"]` — keep it; removing `--recursive` breaks
  Prezto's submodule modules.
- The `{{- if ne .chezmoi.os "windows" }}` gating — keep it exactly.

## Git workflow

- Branch: `chore/bound-prezto-external-refresh`.
- Verify the branch name before the first commit: `git branch --show-current`.
- One commit; Conventional Commits, e.g.
  `chore(zsh): stop prezto external auto-updating on every apply`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm chezmoi's `refreshPeriod` semantics for git-repo externals

Before editing, confirm against the installed chezmoi's documentation/help that:
- a `refreshPeriod` on a `git-repo` external suppresses the automatic `git pull`
  until the period elapses, and
- `chezmoi apply --refresh-externals` (or `chezmoi update --refresh-externals`)
  forces an update on demand.

**Verify**: you can state, from the docs/help output, that setting a long
`refreshPeriod` will stop per-apply pulls and that an explicit
`--refresh-externals` still updates. If the installed chezmoi behaves
differently (e.g. ignores `refreshPeriod` for git-repo, or pulls regardless),
that is a STOP condition — report what you found.

### Step 2: Add a long `refreshPeriod` to the external

Edit `.chezmoiexternals/prezto.toml` to add a `refreshPeriod` key to the
`[".config/zsh/.zprezto"]` block. Result:

```toml
{{- if ne .chezmoi.os "windows" }}

[".config/zsh/.zprezto"]
type = "git-repo"
url = "https://github.com/sorin-ionescu/prezto.git"
clone.args = ["--recursive"]
# Prezto ships no release tags and chezmoi git-repo cannot pin a commit SHA, so
# we cannot cryptographically pin here. Instead, freeze auto-updates: chezmoi
# will NOT pull upstream on every apply. Update deliberately with
# `chezmoi update --refresh-externals` (or `chezmoi apply --refresh-externals`)
# after reviewing upstream changes. See plans/004 and its Maintenance notes.
refreshPeriod = "8760h"

{{- end }}
```

(`8760h` = 365 days — effectively "never auto-pull"; pick a shorter period only
if you *want* periodic auto-updates. Keep every other line unchanged.)

**Verify**:
- `grep -n 'refreshPeriod' .chezmoiexternals/prezto.toml` → shows the new line.
- `grep -c -- '--recursive' .chezmoiexternals/prezto.toml` → `1` (submodule flag preserved).
- `chezmoi execute-template < .chezmoiexternals/prezto.toml` → renders valid TOML
  with the `refreshPeriod` key present (on a non-Windows host).

### Step 3: Record the residual risk + the deferred hard-pin decision (do NOT implement it)

This plan intentionally stops at bounding auto-updates. Do **not** fork Prezto or
change the `url`. Instead, make sure the residual risk and the escalation option
are captured for the maintainer:

- The Maintenance notes below already document: (a) a fresh install still clones
  current upstream HEAD once (unpinned), and (b) the real hard-pin options
  (fork-and-pin to your own repo/commit, or vendor a specific commit) are a
  maintainer decision.
- If, while doing this, the operator explicitly asks for the hard pin, STOP and
  report that it is a separate decision requiring a fork or vendoring — do not
  improvise it inside this plan.

**Verify**: no code/url change beyond Step 2; `git diff --name-only` lists only
`.chezmoiexternals/prezto.toml`.

## Test plan

There is no automated test for chezmoi externals. Verification is structural +
render-based:

- `refreshPeriod` present, `--recursive` preserved, gating intact (Step 2 greps).
- `chezmoi execute-template` renders valid TOML (Step 2).
- Behavioral confirmation is out of band (would require a real `chezmoi apply`
  against the network and a live upstream); do NOT run a full apply as part of
  this plan.

No new automated test file is created.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c 'refreshPeriod' .chezmoiexternals/prezto.toml` → `1`.
- [ ] `grep -c -- '--recursive' .chezmoiexternals/prezto.toml` → `1`.
- [ ] `grep -c 'type = "git-repo"' .chezmoiexternals/prezto.toml` → `1` (url/type unchanged).
- [ ] `chezmoi execute-template < .chezmoiexternals/prezto.toml` exits 0 and shows the `refreshPeriod` key (non-Windows host).
- [ ] `git diff --name-only` lists only `.chezmoiexternals/prezto.toml` (the
      pre-existing `dot_config/agent-of-empires/config.toml` change is not yours;
      leave it unstaged).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The live `.chezmoiexternals/prezto.toml` does not match the "Current state"
  excerpt (drift since this plan was written).
- Step 1 shows the installed chezmoi does not honor `refreshPeriod` for git-repo
  externals the way this plan assumes.
- A chezmoi command reports a persistent-state lock timeout (another chezmoi
  instance is running) — do not force it.
- The task turns out to require the hard pin (fork/vendor) — that is a separate,
  maintainer-owned decision; report and stop.

## Maintenance notes

- **Residual risk (by design of this plan):** a brand-new machine still clones
  current upstream HEAD once at first apply — this plan does not pin the first
  clone. What it removes is the *repeated* auto-pull on every subsequent apply.
- **To fully pin (deferred decision):** either (a) fork
  `sorin-ionescu/prezto`, point `url` at your fork, and advance your fork
  deliberately; or (b) vendor a known-good commit. Both change the maintenance
  model (you own updates), which is why they are not done here.
- **Updating Prezto after this change** is now explicit: run
  `chezmoi update --refresh-externals` (or `chezmoi apply --refresh-externals`)
  after reviewing upstream. Document this in your own runbook if useful.
- A reviewer should confirm only the `refreshPeriod` key was added and the
  `url`, `type`, `clone.args`, and OS gating are untouched.
