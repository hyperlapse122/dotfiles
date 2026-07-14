# dotfiles

Personal [chezmoi](https://chezmoi.io)-managed dotfiles. Four Linux targets are
supported across two distros and two desktops — **Ubuntu 26.04 LTS** (GNOME,
primary), **Ubuntu Studio 26.04 LTS** (KDE Plasma 6), **Fedora 44 Workstation**
(GNOME), and **Fedora 44 KDE Spin** (KDE Plasma 6); macOS and Windows are
supported as secondary targets.

## Set up a new device

Run the one-liner below. It downloads chezmoi, clones this repo, and applies it:

```sh
sh -c "$(curl -fsLS https://get.chezmoi.io/lb)" -- init --apply hyperlapse122
```

`hyperlapse122` is the GitHub username, which chezmoi expands to
`https://github.com/hyperlapse122/dotfiles.git`.

### What the command does

1. Installs the chezmoi binary into a temporary location.
2. Clones this repo into `~/.local/share/chezmoi` (the source state).
3. Runs the [`.install-prerequisites.sh`](.install-prerequisites.sh)
   `read-source-state.pre` hook, which installs the tooling chezmoi itself
   depends on **before** it reads the source state:
   - **1Password** + **1Password CLI (`op`)** — secret templates resolve through
     `op` via `onepasswordRead`.
   - **mise** — the runtime / CLI version manager the rest of this config relies on.
   - **Fedora** installs these with `dnf`; **Ubuntu / Ubuntu Studio** uses `apt`
     (1Password apt repo + mise apt repo); macOS uses Homebrew (bootstrapping
     Homebrew first if needed).

   The same hook then refuses to continue until `op` is authenticated **and** a
   **GitHub API token** is present in the environment, so a fresh apply stops with
   clear guidance here rather than stalling on a 1Password prompt or a GitHub rate
   limit deep in the source-state read (see the two sections below).
4. Renders every template and applies it to `$HOME`, then runs the provisioning
   scripts under [`.chezmoiscripts/`](.chezmoiscripts) — installing packages from
   [`.chezmoidata/packages.yaml`](.chezmoidata/packages.yaml) (Fedora via dnf,
   Ubuntu via apt), fonts, importing the GPG key, authenticating GitHub /
   Tailscale, switching the login shell to zsh, and writing desktop (KDE or
   GNOME) / Solaar / system config. It also fetches pinned standalone CLI
   binaries into `~/.local/bin` (via [`.chezmoiexternals/`](.chezmoiexternals)),
   and provisions coding-agent skills and MCP servers via `dotagents` into
   `~/.agents/` from the pinned set in
   [`dot_agents/private_readonly_agents.toml.tmpl`](dot_agents/private_readonly_agents.toml.tmpl)
   (rendered to `~/.agents/agents.toml`).
   The desktop is detected at apply time (`plasmashell` vs `gnome-shell`):
   KDE hosts get fcitx5 Korean input plus the Breeze de-branding scripts, while
   GNOME hosts stay on GNOME defaults — the only GNOME change is Korean input
   via the desktop's native ibus (`ibus-hangul` + a one-time
   `('ibus', 'hangul')` input source). On Ubuntu, Tailscale egress-NAT via ufw
   is enabled; on Ubuntu Studio specifically (detected by its
   `ubuntustudio-default-settings` package), pro-audio essentials (PipeWire
   config, `@audio` realtime privileges, low-latency boot tuning) are also
   provisioned.

GitLab CLI authentication **is** provisioned on apply: personal access tokens for
git.jpi.app and gitlab.com are read from 1Password and stored in the OS keyring
via `glab auth login --use-keyring`, along with the registry→host mapping
`docker-credential-glab` needs. Rotating a token in 1Password re-runs the login
on the next apply. `auth-glab` (deployed to `~/.local/bin`) remains as the
on-demand OAuth **fallback** — for a host without a PAT, a revoked session, or a
host you want on OAuth: browser flow by default, `--device` for headless
sessions.

## Prerequisites

- **Ubuntu 26.04 LTS**, **Ubuntu Studio 26.04 LTS**, **Fedora 44 Workstation**,
  or **Fedora 44 KDE Spin** for the full experience. Detection is implicit —
  `osRelease.id` (`fedora` or `ubuntu`) plus runtime guards for the desktop
  (`plasmashell` vs `gnome-shell`) and for the Ubuntu Studio flavor
  (`ubuntustudio-default-settings`); no interactive prompt. GNOME hosts keep
  GNOME defaults (input method: ibus); KDE hosts get fcitx5 and the Breeze
  de-branding. Ubuntu Studio additionally gets pro-audio essentials on every
  `chezmoi apply`.
- macOS and Windows get the cross-platform dotfiles only.
- **`sudo` access** — installing packages and writing `/etc` config needs root.
- **A 1Password account.** Secrets are never stored in this repo; they are pulled
  at apply time through the 1Password CLI.

## 1Password authentication (important)

Because secret templates call `onepasswordRead`, chezmoi cannot finish reading
the source state until `op` is signed in. On a brand-new device the first run
installs the 1Password app and CLI but cannot yet resolve secrets. So:

1. Run the one-liner above (installs 1Password, `op`, and mise).
2. Open the **1Password desktop app**, sign in, then enable
   **Settings → Developer → Integrate with 1Password CLI**.
3. Export a GitHub token so chezmoi does not hit GitHub's anonymous rate limit
   while reading the source state (see [GitHub API token](#github-api-token-important)
   below), then re-run to finish applying — all in the same shell:

   ```sh
   export GITHUB_TOKEN=$(op read "op://Private/GitHub/PAT")
   chezmoi apply
   ```

The apply completes once `op` can resolve secrets (`op whoami` succeeds) and a
GitHub token is present in the environment.

## GitHub API token (important)

Reading the source state fetches external repos (e.g. prezto) from GitHub, and
provisioning pulls release assets — fonts and mise-managed tools — from it too.
Anonymous, those calls share GitHub's 60-requests/hour-per-IP limit, so a fresh
apply can fail partway with an HTTP 403. Right after `op` is authenticated,
[`.install-prerequisites.sh`](.install-prerequisites.sh) therefore requires a
GitHub token in the environment: it uses the first of `CHEZMOI_GITHUB_ACCESS_TOKEN`,
`GITHUB_ACCESS_TOKEN`, or `GITHUB_TOKEN` (the variables chezmoi itself reads for
GitHub API calls) and stops with guidance if none is set.

Inject a token from 1Password, then re-run in the same shell:

```sh
export GITHUB_TOKEN=$(op read "op://Private/GitHub/PAT")
chezmoi apply
```

A token with default read-only scope is enough — it only lifts the anonymous
rate limit.

## Running in a container / CI

`chezmoi apply` is container-aware. When it detects a container — Podman's
`/run/.containerenv` or Docker's `/.dockerenv` — it deploys the cross-platform
**CLI dotfiles only** and skips all host provisioning: no package installs, no
`/etc` system config, no GPG / GitHub / Tailscale auth, no fonts, no KDE/GNOME
settings, and no pro-audio realtime/system provisioning. The OpenCode plugin build and `dotagents`
skills install still run (and soft-skip if their toolchains are missing). This
makes the repo usable as-is on CI runners and in dedicated containers that have
their own `$HOME`.

**distrobox and toolbox are the exception.** Both bind-mount the host `$HOME` and
both create `/run/.toolboxenv`, so `chezmoi apply` inside one detects the shared
home and provisions fully like the host instead of skipping — no opt-in needed.

Because the repo never installs packages inside a container, two things must come
from the image and environment:

1. **`op` and `mise` baked into the base image.** The
   [`.install-prerequisites.sh`](.install-prerequisites.sh) hook installs nothing
   in a container — it fails fast with guidance if either is missing.
2. **A 1Password service-account token for secrets.** Secret templates still
   resolve through `onepasswordRead`, so export a service-account token before
   applying — no interactive desktop sign-in is needed:

   ```sh
   export OP_SERVICE_ACCOUNT_TOKEN=...   # create one: op service account create --help
   sh -c "$(curl -fsLS https://get.chezmoi.io)" -- init --apply hyperlapse122
   ```

## Day-to-day

This repo *is* chezmoi's source state — edit files here, not the deployed copies
in `$HOME` (a `chezmoi apply` would overwrite direct `$HOME` edits).

```sh
chezmoi diff      # preview what an apply would change
chezmoi apply     # render templates + run scripts, deploy to $HOME
chezmoi update    # git pull this repo, then apply
chezmoi edit ~/.zshenv   # edit the source of a deployed file
```

See [`AGENTS.md`](AGENTS.md) for the repository conventions (source-state model,
single-source-of-truth data files, OS gating, secrets, and commit style).

## Repository structure

Everything at the top level is chezmoi source state rendered into `$HOME` (see
the attribute table in [`AGENTS.md`](AGENTS.md)), except the source-only trees
below — excluded from deployment via `.chezmoiignore` — and the repo-meta files
(`AGENTS.md`, `LICENSE`, `mise.toml`, `agents.toml`, …).

- [`.chezmoidata/`](.chezmoidata) — template data, the single source of truth
  for packages ([`packages.yaml`](.chezmoidata/packages.yaml): dnf + apt,
  flatpaks, services, groups), fonts (`fonts.yaml`), the root-owned `/etc`
  install manifest ([`system.yaml`](.chezmoidata/system.yaml): per-path
  modes/gates + removed-path cleanup), and user identity (`user.yaml`).
- [`.chezmoiscripts/`](.chezmoiscripts) — provisioning scripts run on apply,
  grouped by area with numeric prefixes fixing cross-group execution order
  (chezmoi runs each phase's scripts alphabetically by target path):
  `00-tools/`, `10-auth/`, `20-linux-fedora/`, `30-linux/`, `40-linux-ubuntu/`,
  `50-linux-kde/`, `50-linux-gnome/`, `60-build/`, `70-agents/`, `80-keys/`,
  `90-services/`.
- [`.chezmoitemplates/`](.chezmoitemplates) — shared template partials inlined
  into scripts via `includeTemplate`: the `run_onchange_` dependency
  fingerprint macro plus the sudo/headless/KDE/GNOME guard blocks.
- [`.chezmoiexternals/`](.chezmoiexternals) — pinned external fetches, grouped by
  domain into six files: `ai-agents.toml`, `dev-tools.toml`, `vcs.toml`,
  `k8s.toml`, `system.toml`, `fonts.toml`. Mostly standalone CLI binaries into
  `~/.local/bin` (claude-code, codex, codegraph, cli-proxy-api, gh, glab,
  kubectl, helm, shellcheck, uv, …), plus prezto and the fonts.
- [`system/`](system) — root-owned `/etc` config, installed by a script rather
  than linked into `$HOME`. See [`system/README.md`](system/README.md).
- [`crates/mxm4-haptic/`](crates/mxm4-haptic) — Rust sources, built on apply by
  `.chezmoiscripts/60-build/run_onchange_after_build-mxm4-haptic.sh.tmpl` into
  `~/.local/bin/`. Linux builds all three binaries: `mxm4-hapticd`,
  `mxm4-haptic-notify`, and `mxm4-haptic`; macOS builds only the daemon and
  client.
- [`packages/`](packages) — Bun workspace built on apply with **Vite+** (`vp`)
  by `.chezmoiscripts/60-build/run_onchange_after_build-opencode-plugins.sh.tmpl`
  into `~/.config/opencode/plugins/`, producing
  `@h82/opencode-playwright-cli-session-injection` (symlinked as
  `playwright-cli-session-injection.js` on Linux and macOS),
  `@h82/opencode-scratch-guard` (symlinked as `scratch-guard.js` on Linux and
  macOS), and `@h82/opencode-mxm4-haptic` (symlinked as `mxm4-haptic.js` on
  Linux). `@h82/mxm4-haptic` is a library, not a plugin. See
  [`packages/README.md`](packages/README.md).
- [`dot_agents/`](dot_agents) — deploys to `~/.agents/`: the `dotagents` config
  template plus the local agent skills under `dot_agents/skills/`.
- [`Library/`](Library) — macOS-only `~/Library` payload (LaunchAgents for
  `cli-proxy-api` and `mxm4-hapticd`).

The source-only trees are also excluded from taplo formatting via
[`.taplo.toml`](.taplo.toml).

## License

[MIT](LICENSE) © Joosung Park
