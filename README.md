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
   binaries into `~/.local/bin` and coding-agent skills into `~/.agents/skills/`
   (via [`.chezmoiexternals/`](.chezmoiexternals)), and provisions MCP servers
   via `dotagents` into `~/.agents/` from the pinned
   set in
   [`dot_agents/private_readonly_agents.toml.tmpl`](dot_agents/private_readonly_agents.toml.tmpl)
   (rendered to `~/.agents/agents.toml`).
   The desktop is detected at apply time (`plasmashell` vs `gnome-shell`).
   fcitx5 (`fcitx5` + `fcitx5-hangul`) is installed on every Linux target as
   the unified Korean input method — KDE routes it through KWin's Wayland
   input-method socket, GNOME through a per-user XDG autostart entry, with a
   one-shot migration that strips any legacy `('ibus', …)` entry from GNOME's
   input sources and installs the Kimpanel Shell extension so the candidate
   popup renders inside GNOME Shell. KDE hosts additionally get the Breeze
   de-branding scripts, while GNOME hosts otherwise stay on GNOME defaults.
   On Ubuntu, Tailscale egress-NAT via ufw is enabled; on Ubuntu Studio
   specifically (detected by its `ubuntustudio-default-settings` package),
   pro-audio essentials (PipeWire config, `@audio` realtime privileges,
   low-latency boot tuning) are also provisioned. On Linux and macOS workstation
   hosts, apply also installs and readiness-checks the authenticated loopback
   CLIProxyAPI localhost service described below.

GitLab CLI authentication **is** provisioned on apply: personal access tokens for
git.jpi.app and gitlab.com are read from 1Password and stored in the OS keyring
via `glab auth login --use-keyring`, along with the registry→host mapping
`docker-credential-glab` needs. Rotating a token in 1Password re-runs the login
on the next apply. `auth-glab` (deployed to `~/.local/bin`) remains as the
on-demand OAuth **fallback** — for a host without a PAT, a revoked session, or a
host you want on OAuth: browser flow by default, `--device` for headless
sessions.

### Encrypted host prompts (keyring — LUKS passphrase / MOK password)

During `chezmoi init`, Linux hosts are prompted for two per-host secrets that
have no 1Password item — the existing **LUKS passphrase** (Fedora + Ubuntu, for
TPM2 auto-unlock enrollment) and, on Ubuntu, the **MOK password** (Secure Boot
signing of the NVIDIA DKMS modules). Both are optional; **leave a prompt blank to
skip** it (no full-disk encryption, no NVIDIA / Secure Boot, or a headless host).

These are never written in plaintext. Each is stored in
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
  ciphertext) — by deleting the `luksPassphraseCipher` / `mokPasswordCipher` keys
  from `~/.config/chezmoi/chezmoi.toml` and re-running `chezmoi init`
  (or `chezmoi init --data=false`).

## CLIProxyAPI localhost service and agent routing

Linux and macOS workstation applies install
[`router-for-me/CLIProxyAPI`](https://github.com/router-for-me/CLIProxyAPI) as a
managed loopback service. Pi alone routes its built-in Anthropic models through
`127.0.0.1:8317`; OpenCode, Claude Code, Codex, and non-Anthropic providers keep
their existing direct configuration. The endpoint and fixed non-secret
`sk-dummy` compatibility token live under `agents.pi.models` in
`.chezmoidata/agents.yaml`. Its Management API credential is read from
`op://Private/CLI Proxy API/password` at apply time; the source snapshot stays
read-only and the private runtime copy is bcrypt-locked at mode 0400 before
supervision. Server-side client API keys and provider plugins remain disabled;
the dummy token only satisfies client-library model-availability checks and is
not validated by the service. Provider credentials created through the loopback
Management UI/API persist only as owner-private live files under
`~/.local/share/cli-proxy-api/auth/`; they are never rendered from this repo.

Chezmoi downloads the latest full native release with its official SHA-256 into
a version-and-digest candidate directory. A late `90-services` reconciler first
disables config persistence, commits the candidate links, and proves listener,
PID, health, credential-safe route, disabled-route, config, auth-metadata,
binary, and output-log semantics in a bounded foreground launch. Host readiness
uses only local parser/model-list checks and never consumes a provider credential.
Only after those checks does the reconciler enable the native user supervisor and
repeat readiness before pinning the extracted binary digest. Native CI separately
proves both an isolated empty-auth `no auth available` response and persistent-auth
startup with a disabled synthetic credential. Failed
binary-only updates can restart a manifest-proven prior candidate; a changed
config, policy, or candidate integrity check leaves the service disabled across
future logins for inspection. Verified older candidates are retained rather
than pruned automatically.

Both systemd and launchd call a private internal launcher that accepts persistent
top-level auth files only when each is non-empty, owner-owned, mode 0600,
non-symlink, and singly linked; unsafe entries and a working-directory `.env`
fail closed without reading, printing, or deleting credential contents. It then
starts through `env -i` with `-local-model`. The reconciler rejects missing,
malformed, or unreadable Management credentials, performs complete apply-time
rotation, and only permits
binary-only rollback when the credential and every policy input are unchanged.
systemd retries failures within a bounded window;
the LaunchAgent starts once per login and deliberately stays stopped after a
failure rather than looping indefinitely. The complete managed config is a reviewed upstream
`v7.2.80` snapshot and advances only by an explicit source diff. Historical
`~/.cli-proxy-api` credentials are never read, printed, migrated, or deleted.
The remaining credential-free Antigravity version metadata request is upstream
behavior with no disable switch.

Inspect the service with:

```sh
systemctl --user status cli-proxy-api.service                    # Linux
launchctl print "gui/$(id -u)/dev.h82.cli-proxy-api"             # macOS
```

Authenticated localhost Management API activation is delivered by
[issue #48](https://github.com/hyperlapse122/dotfiles/issues/48); CPA Usage Keeper
and GNOME/KDE applets remain future consumers, not part of this service. The
Management API is loopback-only. Mode 0400 blocks persistence to the managed
runtime file, but authenticated holders retain full upstream Management authority;
unsupported write routes may transiently affect in-memory state until restart even
when persistence fails. Provider-auth lifecycle routes in the local control panel
are supported; other consumers use read endpoints only. A future fine-grained
route-filtering gateway remains out of scope.
Other operating systems and real containers receive neither these artifacts nor
the Pi localhost routing override.

## Prerequisites

- **Ubuntu 26.04 LTS**, **Ubuntu Studio 26.04 LTS**, **Fedora 44 Workstation**,
  or **Fedora 44 KDE Spin** for the full experience. Detection is implicit —
  `osRelease.id` (`fedora` or `ubuntu`) plus runtime guards for the desktop
  (`plasmashell` vs `gnome-shell`) and for the Ubuntu Studio flavor
  (`ubuntustudio-default-settings`); no interactive prompt. fcitx5 is the
  unified input method on every Linux target (see `packages.yaml`
  `kdePackages` / `gnomePackages`); KDE hosts additionally get the Breeze
  de-branding, while GNOME hosts otherwise keep GNOME defaults. Ubuntu Studio
  additionally gets pro-audio essentials on every `chezmoi apply`.
- macOS gets the cross-platform dotfiles plus the CLIProxyAPI user service;
  Windows gets cross-platform dotfiles only.
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
settings, no pro-audio realtime/system provisioning, no CLIProxyAPI localhost
service, and no Pi localhost provider override. The OpenCode plugin build and
`dotagents` install still run (and soft-skip if their toolchains are missing).
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
  `~/.local/bin` (claude-code, codex, CLIProxyAPI, codegraph, gh, glab, kubectl,
  helm, macOS jq, shellcheck, uv, …), plus prezto, the fonts, and the agent skills
  declared in `.chezmoidata/agents.yaml` (`agents.skills.external`), extracted
  into `~/.agents/skills/`.
- [`system/`](system) — root-owned `/etc` config, installed by a script rather
  than linked into `$HOME`. See [`system/README.md`](system/README.md).
- [`crates/mxm4-haptic/`](crates/mxm4-haptic) — Rust sources, built on apply by
  `.chezmoiscripts/60-build/run_onchange_after_build-mxm4-haptic.sh.tmpl` into
  `~/.local/bin/`. Linux builds all three binaries: `mxm4-hapticd`,
  `mxm4-haptic-notify`, and `mxm4-haptic`; macOS builds only the daemon and
  client.
- [`packages/`](packages) — Bun workspace built on apply with **Vite+** (`vp`).
  `run_onchange_after_build-opencode-plugins.sh.tmpl` builds and links the
  OpenCode plugins; `run_onchange_after_build-figma-auth.sh.tmpl` compiles the
  standalone `figma-auth <opencode|pi>` utility into `~/.local/bin/figma-auth`.
  Apply never starts its interactive OAuth flow: run it on demand to write the
  selected harness's private native credential file. Build failures preserve
  the last executable and retry after an input change or `chezmoi apply
  --force`. See [`packages/README.md`](packages/README.md).
- [`dot_agents/`](dot_agents) — deploys to `~/.agents/`: the `dotagents` config
  template (MCP servers).
- [`Library/`](Library) — macOS-only `~/Library` payload (LaunchAgents for
  `mxm4-hapticd` and CLIProxyAPI).

The source-only trees are also excluded from taplo formatting via
[`.taplo.toml`](.taplo.toml).

## License

[MIT](LICENSE) © Joosung Park
