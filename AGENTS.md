# AGENTS.md

chezmoi-managed dotfiles. Primary target **Fedora Linux**; macOS (`Library/`,
`darwin` template branches, `dot_default-gems.tmpl`) and Windows (`*.ps1`,
`windows` branches) are secondary. Remote: `github.com/hyperlapse122/dotfiles` (`main`).

## This repo is chezmoi *source state* — never edit `$HOME` directly

Files here are the source; chezmoi renders them into `$HOME`. Editing a deployed
file (e.g. `~/.config/mise/config.toml`, `~/.npmrc`) is wrong — the next
`chezmoi apply` overwrites it. Edit the matching source file here, then apply.

Source filename attributes encode the target:

| Source | Becomes |
|---|---|
| `dot_foo` | `~/.foo` |
| `*.tmpl` | Go-template, rendered at apply time |
| `private_` | mode 0600 |
| `readonly_` | mode 0444 |
| `executable_` | `+x` |
| `.chezmoiscripts/run_once_*` | runs once, ever |
| `.chezmoiscripts/run_onchange_*` | re-runs whenever its rendered content changes |
| `.chezmoidata/*` | template data (`.packages`, `.fonts`, `.user`) |
| `.chezmoiexternals/*` | external git/archive fetches (e.g. prezto) |
| `.chezmoiignore` | per-OS target exclusions (itself Go-templated) |

Source paths beginning with `.` (e.g. `.taplo.toml`, `.vscode/`,
`.install-prerequisites.sh`) are NOT deployed — chezmoi ignores them except the
`.chezmoi*` specials. Non-dot repo-meta files (`opencode.json`, `LICENSE`,
`AGENTS.md`) must be listed in the root `.chezmoiignore`, or chezmoi would
deploy them into `~/`.

### Verify edits (don't eyeball raw `.tmpl`)
- `chezmoi diff` — preview what apply would change. **Primary check after any edit.**
- `chezmoi execute-template < file.tmpl` — render one template in isolation (output depends on OS + `.chezmoidata`).
- `chezmoi cat ~/target/path` — show the rendered target.
- `chezmoi apply` — deploy (also runs the scripts). Binary: `/usr/bin/chezmoi`.

## Secrets: 1Password only, never in-repo

Secrets are pulled at apply time via `onepasswordRead "op://..."` inside `.tmpl`
files (GPG key, GitHub/GitLab/Tailscale tokens, opencode API keys under
`dot_config/opencode/private_secrets/`). Never hardcode a secret — add an
`onepasswordRead` reference. The `op` CLI must be signed in: `.install-prerequisites.sh`
runs as a `read-source-state` pre-hook to install 1Password and mise first, and
`chezmoi diff`/`execute-template` over secret templates fails if `op` isn't authed.

## Single source of truth — edit the data, not the generated script

- **dnf packages / repos / COPRs**: `.chezmoidata/packages.yaml`. The
  `run_onchange_before_fedora-install-packages.sh.tmpl` renders and installs from
  it (NVIDIA-GPU and bare-metal sections are auto-gated). Add packages there, not
  in the script — editing the data re-triggers the `run_onchange` installer.
- **Fonts**: `.chezmoidata/fonts.yaml` `legacyFontsList`, pinned per font by
  release tag + sha256. To bump a font: change the tag, re-download, recompute the
  sha256 (a wrong digest aborts that font's install). The bash installer and its
  `.ps1` counterpart both read this list.

## Toolchain quirks

- **mise** owns every runtime/CLI (node, bun, go, python, ruby, rust, gh, glab,
  opencode, …) via `dot_config/mise/config.toml`. It enforces a 24h
  `minimum_release_age` cooldown with an excludes list — add fast-moving tools to
  `minimum_release_age_excludes`, don't disable the gate.
- `python3` is mise-shadowed; system scripts needing real system Python must call
  `/usr/bin/python3` (see the solaar config script).
- **JS package-manager hardening lives here and must stay** — `dot_npmrc`,
  `dot_bunfig.toml`, `dot_yarnrc.yml`, `dot_config/pnpm/config.yaml` all set
  ignore-scripts + exact-pin + 1-week cooldown. Don't relax them.
- TOML is taplo-formatted; `.taplo.toml` excludes `.chezmoidata/**` and
  `.chezmoiexternals/**` (templated / non-standard TOML). biome LSP is disabled in
  the repo `opencode.json`.

## OS gating & script parity

- Branch on `{{ .chezmoi.os }}` (`linux`/`darwin`/`windows`); exclude whole paths
  per-OS via the nearest `.chezmoiignore` (root, `dot_config/`, `dot_local/bin/`).
  git config splits via `config.tmpl` including `.config_<os>`.
- POSIX scripts/wrappers keep a Windows `.ps1` counterpart in sync
  (`executable_code`/`.ps1`, `executable_opencode`/`.ps1`). Files migrated from the
  legacy nix/dotbot config are now the source of truth here — don't defer back to
  the old repo.

## Commits

Conventional Commits (per the global rules), scoped by area — history is mostly
`chore(<area>)`, e.g. `chore(fedora)`, `chore(scripts)`, `chore(tailscale)`.
Trunk-based on `main`; **always `git push` to `origin/main` immediately after
committing** (single-maintainer repo, no PR/review gate).
