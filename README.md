# dotfiles

Personal [chezmoi](https://chezmoi.io)-managed dotfiles. Fedora Workstation
and KDE are the primary Linux targets; macOS and Windows are secondary targets
that receive the cross-platform dotfiles plus a narrower, OS-native provision
set (see [What the command does](#what-the-command-does)).

### Bootstrap

Each command downloads chezmoi, clones this repo into
`~/.local/share/chezmoi` (the source state), and applies it. Pick your OS:

**Linux & macOS** — curl:

```sh
sh -c "$(curl -fsLS https://get.chezmoi.io/lb)" -- init --apply hyperlapse122
```

**Linux & macOS** — wget (if `curl` is absent):

```sh
sh -c "$(wget -qO- https://get.chezmoi.io/lb)" -- init --apply hyperlapse122
```

**Windows** — PowerShell:

```powershell
iex "&{$(irm 'https://get.chezmoi.io/ps1')} init --apply hyperlapse122"
```

`hyperlapse122` is the GitHub username, which chezmoi expands to
`https://github.com/hyperlapse122/dotfiles.git`.

### What the command does

1. Installs the chezmoi binary into a temporary location.
2. Clones this repo into `~/.local/share/chezmoi` (the source state).
3. Runs the `read-source-state.pre` hook —
   [`.install-prerequisites.sh`](.install-prerequisites.sh) on Linux/macOS,
   [`.install-prerequisites.ps1`](.install-prerequisites.ps1) on Windows —
   which installs the tooling chezmoi itself depends on **before** it reads the
   source state:
   - **1Password** + **1Password CLI (`op`)** — secret templates resolve through
     `op` via `onepasswordRead`.
   - **mise** — the runtime / CLI version manager the rest of this config relies on.
   - **Fedora** installs 1Password / `op` / `mise` via `dnf` (the 1Password RPM
     repo + the `jdxcode/mise` COPR); **macOS** via Homebrew (bootstrapping
     Homebrew first if needed); **Windows** via `winget`. The remaining
     formulas/casks (macOS) and winget packages (Windows) are installed later by
     their own package-authority reconcilers, not by this hook.

   The same hook then refuses to continue until `op` is authenticated, so a
   fresh apply stops with clear guidance here rather than stalling on a
   1Password prompt deep in the source-state read (see the two sections below).
   A missing **GitHub API token** only prints an advisory — renders no longer
   call the GitHub API.

4. Renders every template, applies it to `$HOME`, and runs the provisioning
   scripts under [`.chezmoiscripts/`](.chezmoiscripts). What lands is OS-gated
   in [`.chezmoiignore`](.chezmoiignore), so the scope depends on the host:

   - **Fedora** (full): packages from
     [`.chezmoidata/packages.yaml`](.chezmoidata/packages.yaml) via dnf, fonts,
     GPG key import, GitHub / GitLab / Tailscale / Docker auth, the zsh login
     shell, and desktop config (KDE or GNOME, detected at apply time via
     `plasmashell` vs `gnome-shell`). KDE hosts additionally get the Breeze
     de-branding scripts; GNOME hosts otherwise keep GNOME defaults. fcitx5
     (`fcitx5` + `fcitx5-hangul`) is the unified Korean input method on every
     Linux target — KDE routes it through KWin's Wayland input-method socket,
     GNOME through a per-user XDG autostart entry, with a one-shot migration
     that strips any legacy `('ibus', …)` entry from GNOME's input sources and
     installs the Kimpanel Shell extension so the candidate popup renders inside
     GNOME Shell. Root-owned `/etc` system config (NVIDIA / Secure Boot / TPM2,
     firewalld, resolved, …) is installed from
     [`.chezmoidata/system.yaml`](.chezmoidata/system.yaml), and Tailscale
     egress-NAT via ufw is enabled.
   - **macOS**: the cross-platform dotfiles, Homebrew-managed tools (installed
     by the [`20-darwin`](.chezmoiscripts/20-darwin) Homebrew reconciler), the
     `mxm4-hapticd` LaunchAgent ([`Library/`](Library)), VSCodium user state,
     and the Winbox-from-1Password importer.
   - **Windows**: the cross-platform dotfiles, winget-managed tools, Visual
     Studio ([`.chezmoidata/visualstudio.yaml`](.chezmoidata/visualstudio.yaml)),
     VSCodium extensions ([`30-windows`](.chezmoiscripts/30-windows)), the
     Task-Scheduler haptic daemon, and PowerShell counterparts of the Linux
     agent/auth scripts.

   Every OS fetches pinned standalone CLI binaries into `~/.local/bin` and
   coding-agent skills into `~/.agents/skills/`
   (via [`.chezmoiexternals/`](.chezmoiexternals)), and provisions MCP servers
   via `dotagents` into `~/.agents/` from the pinned set in
   [`dot_agents/private_readonly_agents.toml.tmpl`](dot_agents/private_readonly_agents.toml.tmpl)
   (rendered to `~/.agents/agents.toml`).

GitLab CLI authentication **is** provisioned on apply: personal access tokens for
git.jpi.app and gitlab.com are read from 1Password and stored in the OS keyring
via `glab auth login --use-keyring`, along with the registry→host mapping
`docker-credential-glab` needs. Rotating a token in 1Password re-runs the login
on the next apply. `auth-glab` (deployed to `~/.local/bin`) remains as the
on-demand OAuth **fallback** — for a host without a PAT, a revoked session, or a
host you want on OAuth: browser flow by default, `--device` for headless
sessions.

### Encrypted host prompt (keyring — LUKS passphrase)

The `chezmoi init` prompt on a **Fedora** host asks for your existing LUKS
passphrase (for TPM2 auto-unlock enrollment). It is optional — **leave it blank
to skip** (no full-disk encryption, or a headless host). macOS and Windows never
see this prompt.

It is never written in plaintext. It is stored in
`~/.config/chezmoi/chezmoi.toml` as AES ciphertext under a random 256-bit key
that lives **only in your user keyring** (the Secret Service — GNOME Keyring on
GNOME, KWallet's Secret Service on KDE), under
`service=chezmoi-config-secrets`. The key is minted on demand the moment you type
a non-blank answer, so:

- **Run `chezmoi init` from inside a real graphical desktop session** (not a raw
  TTY / SSH-only shell) so the keyring is unlocked and reachable. If the keyring
  cannot be reached when you type a passphrase, init stops with
  `config-secrets key unavailable (user keyring locked or unreachable)` — re-run
  from a desktop session, or leave the prompt blank to skip.
- A **blank** answer (also what non-interactive / CI runs get) stores nothing and
  simply skips that feature.
- **Re-prompt / recover** later — e.g. to set a passphrase you skipped, or if the
  keyring entry was lost or rotated (a lost key can no longer decrypt the stored
  ciphertext) — by deleting the `luksPassphraseCipher` key
  from `~/.config/chezmoi/chezmoi.toml` and re-running `chezmoi init`
  (or `chezmoi init --data=false`).

## Prerequisites

- **Fedora 44 Workstation** or **Fedora 44 KDE Spin**
  for the full experience. Detection is implicit — `osRelease.id` (`fedora`)
  plus a runtime guard for the desktop (`plasmashell` vs `gnome-shell`); no
  interactive prompt. fcitx5 is the unified input method on
  every Linux target; KDE hosts additionally get the Breeze
  de-branding, while GNOME hosts otherwise keep GNOME defaults.
- **macOS** (Homebrew) and **Windows** (winget / "App Installer") get the
  cross-platform dotfiles plus their OS-native provision set (see above).
- **`sudo` access on Linux** — installing Fedora packages and writing `/etc`
  config needs root. macOS uses Homebrew; Windows uses winget (no `sudo`).
- **A 1Password account.** Secrets are never stored in this repo; they are pulled
  at apply time through the 1Password CLI.

## 1Password authentication (important)

Because secret templates call `onepasswordRead`, chezmoi cannot finish reading
the source state until `op` is signed in. On a brand-new device the first run
installs the 1Password app and CLI but cannot yet resolve secrets. So:

1. Run the one-liner above (installs 1Password, `op`, and mise).
2. Open the **1Password desktop app**, sign in, then enable
   **Settings → Developer → Integrate with 1Password CLI**.
3. Re-run to finish applying. Exporting a GitHub token first is optional but
   recommended — apply-time downloads still benefit from it (see
   [GitHub API token](#github-api-token-important) below):

   ```sh
   export GITHUB_TOKEN=$(op read "op://Private/GitHub/PAT")  # optional
   chezmoi apply
   ```

The prerequisite hook continues once `op vault list` confirms desktop-app or service-account authentication. The later `onepasswordRead` calls still verify access to each exact secret reference, and the apply fails with that lookup error if the account lacks access.

## GitHub API token (important)

Reading the source state performs no GitHub API calls — every tool version,
URL, and checksum is pinned by the generated release lock
([`.chezmoidata/releases.json`](.chezmoidata/releases.json)). Applying still
downloads external repos and release assets (fonts, mise-managed tools) from
GitHub, and anonymous calls share GitHub's 60-requests/hour-per-IP limit, so a
token remains useful on a fresh apply. Right after `op` is authenticated,
[`.install-prerequisites.sh`](.install-prerequisites.sh) prints an advisory
when none of `CHEZMOI_GITHUB_ACCESS_TOKEN`, `GITHUB_ACCESS_TOKEN`, or
`GITHUB_TOKEN` (the variables chezmoi itself reads) is set — it no longer
stops the bootstrap.

To set one, inject the PAT from 1Password in the same shell:

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
settings, and no pro-audio realtime/system provisioning. Surviving agent
dotfiles and `dotagents` provisioning still run.
This makes the repo usable as-is on CI runners and in dedicated containers that
have their own `$HOME`.

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

This repo _is_ chezmoi's source state — edit files here, not the deployed copies
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
(`AGENTS.md`, `LICENSE`, `mise.toml`, …).

- [`.chezmoidata/`](.chezmoidata) — template data, the single source of truth
  for packages ([`packages.yaml`](.chezmoidata/packages.yaml): dnf, flatpaks,
  services, groups), fonts (`fonts.yaml`), the root-owned `/etc`
  install manifest ([`system.yaml`](.chezmoidata/system.yaml): per-path
  modes/gates + removed-path cleanup), and user identity (`user.yaml`).
- [`.chezmoiscripts/`](.chezmoiscripts) — provisioning scripts run on apply,
  grouped by area with numeric prefixes fixing cross-group execution order
  (chezmoi runs each phase's scripts alphabetically by target path):
  `00-tools/`, `10-auth/`, `20-linux-fedora/`, `30-linux/`, `50-linux-kde/`,
  `50-linux-gnome/`, `60-build/`, `70-agents/`, `80-keys/`.
- [`.chezmoitemplates/`](.chezmoitemplates) — shared template partials inlined
  into scripts via `includeTemplate`: the `run_onchange_` dependency
  fingerprint macro plus the sudo/headless/KDE/GNOME guard blocks.
- [`.chezmoiexternals/`](.chezmoiexternals) — pinned external fetches, grouped by
  domain into six files: `ai-agents.toml`, `dev-tools.toml`, `vcs.toml`,
  `k8s.toml`, `system.toml`, `fonts.toml`. Mostly standalone CLI binaries into
  `~/.local/bin` (claude-code, codex, codegraph, gh, glab, kubectl, helm,
  macOS jq, shellcheck, uv, …), plus prezto, the fonts, and the agent skills
  declared in `.chezmoidata/agents.yaml` (`agents.skills.external`), extracted
  into `~/.agents/skills/`.
- [`system/`](system) — root-owned `/etc` config, installed by a script rather
  than linked into `$HOME`. See [`system/README.md`](system/README.md).
- [`crates/mxm4-haptic/`](crates/mxm4-haptic) — Rust sources, built on apply by
  `.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh.tmpl` into
  `~/.local/bin/`. Linux builds all three binaries: `mxm4-hapticd`,
  `mxm4-haptic-notify`, and `mxm4-haptic`; macOS builds only the daemon and
  client.
- [`packages/`](packages) — Bun workspace built on apply with **Vite+** (`vp`).
  `run_onchange_after_build-figma-auth.sh.tmpl` compiles the standalone
  `figma-auth omp` utility into `~/.local/bin/figma-auth`. The Figma MCP endpoint
  is declared once in `.chezmoidata/agents.yaml` and renders without embedded
  credentials. Apply never starts the interactive OAuth flow. Run `figma-auth
  omp` on demand to update omp's private OAuth row. Build failures preserve the
  last executable and retry after an input change or `chezmoi apply --force`.
  `release-lock/` generates the static external-tool lock consumed by templates
  and externals. See [`packages/README.md`](packages/README.md).
- [`dot_agents/`](dot_agents) — deploys to `~/.agents/`: the `dotagents` config
  template (MCP servers) and any locally-authored personal skill under
  `dot_agents/skills/<name>/` (e.g. `daily-report`), deployed to
  `~/.agents/skills/<name>/`.
- [`Library/`](Library) — macOS-only `~/Library` payload (the `mxm4-hapticd`
  LaunchAgent).

The source-only trees are also excluded from taplo formatting via
[`.taplo.toml`](.taplo.toml).

## Managed agent harnesses

This repository manages only **Claude**, **Codex**, and **omp**. Removing the
Pi, Kimi Code, OpenCode, oh-my-openagent, and AGY sources does not delete
already-deployed host files, installed binaries, or provider-side OAuth grants.

OMP settings are asserted per key from `.chezmoidata/agents.yaml`. The declared
policy keeps progress, token usage, and tmux scrollback behavior stable. It
also enables structural search and computer control. Codex-user and
Claude-user/project compatibility skill scans stay disabled so OMP uses the
canonical `~/.agents/skills/` and repository `.agents/skills/` roots without
duplicate discovery.

The following cleanup is optional. Remove only the listed Figma data if the
retired harnesses are no longer in use:

- OpenCode: remove the top-level `figma` and `Figma` properties from
  `~/.local/share/opencode/mcp-auth.json`. Keep the file and all other
  properties.
- Pi: delete
  `~/.pi/agent/mcp-auth/5b79d0d574eedd09.json`.
- Kimi Code: under `~/.kimi-code/credentials/mcp/`, delete the
  `figma-16c8c86ce11b09357be35b5b-{client,tokens,discovery}.json` files and
  `.figma-16c8c86ce11b09357be35b5b-transaction.json` when present.
- AGY: remove only the top-level `https://mcp.figma.com/mcp` property from
  `~/.gemini/antigravity-cli/mcp_oauth_tokens.json`. Keep the file and all
  other properties.

Local deletion does not revoke provider access. To revoke it, open Figma
**Settings → Security → Connected apps** and revoke only the obsolete `Codex`
registrations that correspond to these four stores. Every retired flow used
that client name. If the entries cannot be distinguished, skip provider
revocation rather than invalidate the current omp authorization.

Do not remove omp's Figma row from `~/.omp/agent/agent.db`. The surviving
`figma-auth omp` command owns that row.

## License

[MIT](LICENSE) © Joosung Park
