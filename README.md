# dotfiles

Personal [chezmoi](https://chezmoi.io)-managed dotfiles. Fedora Workstation
and KDE are the primary Linux targets. Ubuntu 24.04 arm64 is managed only on
an NVIDIA Jetson AGX Thor. macOS is a secondary target that receives the
cross-platform dotfiles plus a narrower, OS-native provision set
(see [What the command does](#what-the-command-does)).

### Bootstrap

Each command downloads chezmoi, clones this repo into
`~/src/github.com/hyperlapse122/dotfiles` (the source state is `home/`), and applies it.

**Linux & macOS** — curl:

```sh
sh -c "$(curl -fsLS https://get.chezmoi.io/lb)" -- init --apply --source ~/src/github.com/hyperlapse122/dotfiles hyperlapse122
```

**Linux & macOS** — wget (if `curl` is absent):

```sh
sh -c "$(wget -qO- https://get.chezmoi.io/lb)" -- init --apply --source ~/src/github.com/hyperlapse122/dotfiles hyperlapse122
```

`hyperlapse122` is the GitHub username, which chezmoi expands to
`https://github.com/hyperlapse122/dotfiles.git`.

### What the command does

1. Installs the chezmoi binary into a temporary location.
2. Clones this repo into `~/src/github.com/hyperlapse122/dotfiles` (the source state is `home/`).
3. Runs the `read-source-state.pre` hook —
   [`.install-prerequisites.sh`](.install-prerequisites.sh) on Linux/macOS —
   which installs the tooling chezmoi itself depends on **before** it reads the
   source state:
   - **1Password** + **1Password CLI (`op`)** — secret templates resolve through
     `op` via `onepasswordRead`.
   - **OpenPGP card stack** — GnuPG, scdaemon, pcscd (or macOS PC/SC framework),
     the desktop pinentry, and the OS keyring CLI for hardware key operations.
   - **mise** — the runtime / CLI version manager the rest of this config relies on.
   - **Fedora** installs 1Password / `op` and the card stack via `dnf`.
   - **Ubuntu arm64 on an NVIDIA Jetson AGX Thor** installs the required
     bootstrap tools through `apt`. The hook accepts `ubuntu` for this path.
   - **macOS** uses Homebrew (bootstrapping Homebrew first if needed). The
     remaining formulas/casks are installed later by their own package-authority
     reconciler, not by this hook.

   The same hook then runs the **Key presence check** before reading source state
   (skipped in real containers and CI): it imports the committed public key,
   verifies that the host holds a local private key or an inserted YubiKey carrying
   the configured key, creates or refreshes GnuPG card stubs, and verifies the
   stored card PIN once under loopback mode. The hook also refuses to continue
   until `op` is authenticated, so a fresh apply stops with clear guidance here
   rather than stalling on a 1Password prompt or missing key deep in the
   source-state read (see the sections below). A missing **GitHub API token** only
   prints an advisory — renders no longer call the GitHub API.

4. Renders every template, applies it to `$HOME`, and runs the provisioning
   scripts under [`home/.chezmoiscripts/`](home/.chezmoiscripts). What lands is OS-gated
   in [`home/.chezmoiignore`](home/.chezmoiignore), so the scope depends on the host:

   - **Fedora** (full): base and component packages via dnf/flatpak/dotnet, fonts,
     public key import and card stubs, GitHub / GitLab / Tailscale / Docker auth, the zsh login
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
     [`home/.chezmoidata/system.yaml`](home/.chezmoidata/system.yaml), and Tailscale
     egress-NAT via ufw is enabled.
   - **Ubuntu arm64 on an NVIDIA Jetson AGX Thor**: cross-platform dotfiles,
     supported Ubuntu packages, JetPack, the 1Password desktop app, and desktop
     configuration. This is not a generic Ubuntu host path.
   - **macOS**: the cross-platform dotfiles, Homebrew-managed tools (installed
     by the [`20-darwin`](home/.chezmoiscripts/20-darwin) Homebrew reconciler),
     VSCodium user state, and the Winbox-from-1Password importer.

   Before the first apply on a shared host, create
   `/etc/dotfiles-shared-host`. The marker declares the host shared and enables
   the `sharedHost` gate. It blocks system-manifest changes and system-wide
   daemon configuration. A non-Jetson shared host without the marker and
   without `@` in its username fails open.

   Every OS fetches pinned standalone CLI binaries into `~/.local/bin` and
   coding-agent skills into `~/.agents/skills/`
   (via [`home/.chezmoiexternals/`](home/.chezmoiexternals)), and provisions MCP servers
   via `dotagents` into `~/.agents/` from the pinned set in
   [`home/dot_agents/private_readonly_agents.toml.tmpl`](home/dot_agents/private_readonly_agents.toml.tmpl)
   (rendered to `~/.agents/agents.toml`).

GitLab CLI authentication **is** provisioned on apply: personal access tokens for
git.jpi.app and gitlab.com are read from 1Password and stored in the OS keyring
via `glab auth login`. The script removes `CI`/`GITLAB_CI` for that invocation
because glab otherwise treats them as an explicit plaintext-storage request; it
then asserts keyring storage and scrubs/refuses any plaintext fallback. The
registry→host mapping remains available to `glab auth docker-helper`. Rotating a
token in 1Password re-runs the login on the next apply. `auth-glab` (deployed to
`~/.local/bin`) remains as the on-demand OAuth **fallback** — for a host without
a PAT, a revoked session, or a host you want on OAuth: browser flow by default,
`--device` for headless sessions.

Container-registry authentication for podman/buildah/skopeo is rendered directly
into `~/.config/containers/auth.json`
([`home/dot_config/containers/private_auth.json.tmpl`](home/dot_config/containers/private_auth.json.tmpl),
0600): GitHub- and GitLab-hosted registries (`ghcr.io`, `registry.jpi.app`,
`registry.gitlab.com`) carry stored base64("user:PAT") keys resolved live from
1Password on every apply, so a rotated PAT propagates on the next apply. Docker
Hub (`docker.io`, `dhi.io`) instead uses the keychain-backed `dockerhub`
credential helper populated by the `auth-dockerhub` script.

### Encrypted host prompt (keyring — LUKS passphrase)

The `chezmoi init` prompt on a **Fedora** host asks for your existing LUKS
passphrase (for TPM2 auto-unlock enrollment). It is optional — **leave it blank
to skip** (no full-disk encryption, or a headless host). macOS never sees
this prompt.

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

### OpenPGP card prompt (keyring — User PIN)

During an interactive `chezmoi init`, the config template checks each declared
card serial (`yubikeySerials` in [`home/.chezmoidata/user.yaml`](home/.chezmoidata/user.yaml))
that has not been prompted yet. It prompts on `/dev/tty` for the card's OpenPGP
User PIN (`YubiKey OpenPGP User PIN for serial <serial>...`). Non-blank answers
are stored directly in the OS keyring under service `gnupg-card-pin` with the
decimal serial as the account. A blank answer (or non-interactive init) stores
nothing and defers capture to the Key presence check on apply.

The PIN rests in your user keyring (Secret Service on Linux, Keychain on macOS)
and is retrieved by the Card PIN wrapper when GnuPG prompts for that card serial.
Every managed host, including the Jetson shared host, keeps the PIN in its user
keyring. The PIN exists in three places: the OS keyring, gpg-agent's in-memory
cache, and 1Password.

This follows the same-user trust boundary: the wrapper releases the stored PIN
to any process that can drive gpg-agent in that desktop session, matching the
Secret Service and Keychain security boundary (which do not isolate callers
running as the same user). A host with console auto-login must keep its wallet
locked at login or accept console-wide card use while the card is inserted.

#### Key presence check

Before any command that reads source state (`apply`, `init --apply`, `update`,
`diff`, `status`, etc.) renders templates, the prerequisite hook runs the Key
presence check (skipped in real containers and CI):

1. It imports the committed public key ([`home/.keys/gpg-A7F1956CD1A035A139BC7ABFCC740A29852C0E95.asc`](home/.keys/gpg-A7F1956CD1A035A139BC7ABFCC740A29852C0E95.asc))
   and sets ultimate ownertrust if not already set.
2. It checks for a usable private key. If the host has a local private key for
   fingerprint `A7F1956CD1A035A139BC7ABFCC740A29852C0E95` (existing hosts), the
   check passes immediately without touching the card.
3. On a host without a local private key, it requires an inserted YubiKey carrying
   that key and matching a declared serial. It creates or updates the card stubs
   in GnuPG and verifies the stored PIN once under loopback mode.

If neither a local private key nor an inserted YubiKey with the expected key is
found, the command stops immediately before any source state is read or
decrypted. The failure message reports:

```text
GPG key presence check failed: no local private key or inserted YubiKey for A7F1956CD1A035A139BC7ABFCC740A29852C0E95
```

This enforces the design rule that "no YubiKey means I am not present" — chezmoi
halts cleanly rather than failing deep in template evaluation or repository
decryption. Insert the YubiKey carrying the key to continue.

#### Adding a backup card

To authorize a backup YubiKey:

1. Append the new card's decimal serial to `yubikeySerials` in
   [`home/.chezmoidata/user.yaml`](home/.chezmoidata/user.yaml) and the literal list in
   [`home/.chezmoi.toml.tmpl`](home/.chezmoi.toml.tmpl).
2. Run `chezmoi init` (or `chezmoi init --apply`). The template prompts for the
   new serial's User PIN and records it in the keyring.
3. Insert the backup card and run any chezmoi command. The Key presence check
   detects the new serial and points the card stubs to it with
   `gpg-connect-agent 'scd learn --force' /bye`.

#### Card-side configuration (R17)

Card-side settings are not automated and must be set manually on each YubiKey:

- **User PIN retry maximum at three**: Keep the User PIN retry counter at three.
  The Key presence check and wrapper require this maximum so a stale stored PIN
  is tested at most once before prompting the operator, avoiding automated
  lockouts. Set with `ykman`:

  ```sh
  ykman openpgp access set-retries 3 3 3
  ```

  A card configured with a counter above three is rejected by the check.
- **Touch policy on signature and decryption slots**: Require physical touch for
  signing and decryption operations. This touch gate is what makes PIN-at-rest
  acceptable (especially on shared hosts). Set with `ykman`:

  ```sh
  ykman openpgp keys set-touch sig on      # or cached
  ykman openpgp keys set-touch dec on      # or cached
  ```

  Or in `gpg --card-edit`: enter `admin`, then `UIF 1 on` (signature) and
  `UIF 2 on` (decryption).
- **Keep signature PIN forcing off**: Ensure signature operations do not force
  PIN entry on every signature, allowing touch to authorize signatures within
  the agent session. Set with `ykman`:

  ```sh
  ykman openpgp access set-signature-policy once
  ```

  Or in `gpg --card-edit`: enter `admin`, then run `forcesig` until
  `Signature PIN ....: not forced`.
- **PIN change outside GnuPG**: After changing the User PIN outside GnuPG (e.g.
  via `ykman` or Yubico Authenticator), the stored keyring PIN becomes stale.
  Run any chezmoi command with the card inserted before performing signing
  operations (such as `git commit`). The Key presence check spends at most one
  attempt, prompts for the new PIN on `/dev/tty`, and updates the keyring record.

## Prerequisites

- **Fedora 44 Workstation** or **Fedora 44 KDE Spin**
  for the full experience. Detection is implicit — `osRelease.id` (`fedora`)
  plus a runtime guard for the desktop (`plasmashell` vs `gnome-shell`); no
  interactive prompt. fcitx5 is the unified input method on
  every Linux target; KDE hosts additionally get the Breeze
  de-branding, while GNOME hosts otherwise keep GNOME defaults.
- **Ubuntu 24.04 arm64 on an NVIDIA Jetson AGX Thor** is supported. This is not
  a generic Ubuntu host path. Run `chezmoi apply` only from the board's local
  GUI session. Keyring- and pinentry-backed steps need an unlocked session.
- **macOS** (Homebrew) gets the cross-platform dotfiles plus its
  OS-native provision set (see above).
- **A YubiKey carrying the configured OpenPGP key** for a new host (existing
  hosts keep their local private key). The Key presence check requires one before
  any source state is read.
- **`sudo` access on Linux** — installing Linux packages and writing `/etc`
  config needs root. macOS uses Homebrew (no `sudo`).
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
   export GITHUB_TOKEN=$(op read "op://tum6wsa7azjvbkgwnp6fgamcvm/GitHub/PAT")  # optional
   chezmoi apply
   ```
4. On a Jetson, after the first apply, run
   `sudo /opt/1Password/after-install.sh` once. It installs a setuid helper and
   a polkit policy, so the repository does not run it.

The prerequisite hook continues once `op vault list` confirms desktop-app or service-account authentication. The later `onepasswordRead` calls still verify access to each exact secret reference, and the apply fails with that lookup error if the account lacks access.

## GitHub API token (important)

Reading the source state performs no GitHub API calls — every tool version,
URL, and checksum is pinned by the generated release lock
([`home/.chezmoidata/releases.json`](home/.chezmoidata/releases.json)). Applying still
downloads external repos and release assets (fonts, mise-managed tools) from
GitHub, and anonymous calls share GitHub's 60-requests/hour-per-IP limit, so a
token remains useful on a fresh apply. Right after `op` is authenticated,
[`.install-prerequisites.sh`](.install-prerequisites.sh) prints an advisory
when none of `CHEZMOI_GITHUB_ACCESS_TOKEN`, `GITHUB_ACCESS_TOKEN`, or
`GITHUB_TOKEN` (the variables chezmoi itself reads) is set — it no longer
stops the bootstrap.

To set one, inject the PAT from 1Password in the same shell:

```sh
export GITHUB_TOKEN=$(op read "op://tum6wsa7azjvbkgwnp6fgamcvm/GitHub/PAT")
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

The chezmoi source state lives under `home/` — edit files there, not the deployed copies
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

The chezmoi source state lives under `home/` behind `.chezmoiroot` (see
the attribute table in [`AGENTS.md`](AGENTS.md)). Repository infrastructure
and source-only trees live at the repository root outside `home/`.

- [`home/`](home) — chezmoi source state rendered into `$HOME`:
  - [`home/.chezmoidata/`](home/.chezmoidata) — template data, the single source of truth
    for fonts (`fonts.yaml`), the root-owned `/etc`
    install manifest ([`system.yaml`](home/.chezmoidata/system.yaml): per-path
    modes/gates + removed-path cleanup), and user identity (`user.yaml`).
  - [`home/.chezmoiscripts/`](home/.chezmoiscripts) — provisioning scripts run on apply,
    grouped by area with numeric prefixes fixing cross-group execution order
    (chezmoi runs each phase's scripts alphabetically by target path):
    `00-tools/`, `10-auth/`, `20-base/`, `30-linux/`, `50-linux-kde/`,
    `50-linux-gnome/`, `60-build/`, `70-agents/`, `80-keys/`, `90-src/`.
  - [`home/.chezmoitemplates/`](home/.chezmoitemplates) — shared template partials inlined
    into scripts via `includeTemplate`: the `run_onchange_` dependency
    fingerprint macro plus the sudo/headless/KDE/GNOME guard blocks.
  - [`home/.chezmoiexternals/`](home/.chezmoiexternals) — pinned external fetches, grouped by
    domain into six files: `ai-agents.toml`, `dev-tools.toml`, `vcs.toml`,
    `k8s.toml`, `system.toml`, `fonts.toml`. Mostly standalone CLI binaries into
    `~/.local/bin` (codegraph, gh, glab, kubectl, helm,
    macOS jq, shellcheck, uv, …), plus prezto, the fonts, and the agent skills
    declared in `home/.chezmoidata/agents.yaml` (`agents.skills.external`), extracted
    into `~/.agents/skills/`.
  - [`home/dot_agents/`](home/dot_agents) — deploys to `~/.agents/`: the `dotagents` config
    template (MCP servers) and any locally-authored personal skill under
    `home/dot_agents/skills/<name>/` (e.g. `daily-report`), deployed to
    `~/.agents/skills/<name>/`.
  - [`home/Library/`](home/Library) — macOS-only `~/Library` payloads.
- [`system/`](system) — root-owned `/etc` config, installed by a script rather
  than linked into `$HOME`. See [`system/README.md`](system/README.md).
- [`crates/mxm4-haptic/`](crates/mxm4-haptic) — Rust haptic client sources and utilities.
- [`packages/`](packages) — Bun workspace built on apply with **Vite+** (`vp`).
  `omp-orca/` supplies Orca instructions to omp and `figma-auth/` authorizes
  the shared Figma MCP server for omp. Build failures preserve the last
  executable and retry after an input change or `chezmoi apply --force`.
  `release-lock/` generates the static external-tool lock consumed by templates
  and externals. `ce-overlay-rebase/` holds rebase state transitions, dispatch
  decision, and failure classification for Compound Engineering overlays. See
  [`packages/README.md`](packages/README.md).
- [`firmware/`](firmware) — keyboard firmware configurations (e.g. NuPhy Gem80 HostRGB).
The source-only trees are also excluded from taplo formatting via
[`.taplo.toml`](.taplo.toml).

## Managed agent harnesses

This repository manages **Claude Code** (`claude`), **OpenAI Codex CLI** (`codex`), and **oh-my-pi** (`omp`).

- **Single source of truth:** `home/.chezmoidata/agents.yaml` defines MCP servers (`agents.mcp.servers` including Exa web search and Context7), external skills (`agents.skills.external`), and harness settings.
- **Universal MCP discovery:** Chezmoi renders `~/.mcp.json` from `agents.mcp.servers` with live 1Password `op://` resolution at apply time, renders the same servers into `~/.omp/agent/mcp.json`, and asserts them into `~/.codex/config.toml`.
- **Model roster:** `home/.chezmoidata/agents.yaml` defines two lead pins and five worker models by agent and role: Claude lead on `opus[1m]` (Fable is reached through Compound Engineering model elevation, which defaults to the authoring entry's model for whichever of `plan_model` and `brainstorm_model` a repository leaves unset), Codex lead on `gpt-6-astra` (low effort), Claude authoring on `fable` at medium effort, Claude judgment-escalation on `fable` at medium effort, Claude judgment-deep on `opus` at xhigh effort, Claude implementation on `sonnet` at xhigh effort, and omp mechanical, implementation, and judgment work on `google-antigravity/gemini-3.8-flash` at high effort. Mechanical and implementation work go to `omp` first, then `claude` `sonnet`. Judgment work is dispatched by rung, matching the CE tier the persona being reviewed declares: `judgment-cheap` and `judgment-standard` go to `omp` alone (`sonnet` replaces it on failure or unavailability), `judgment-deep` goes to `claude` on `opus` at xhigh effort plus `omp` over the same brief, and `judgment-escalation` (`claude` on `fable` at medium effort) is reached only by an explicit upgrade request or the three-consecutive-failure consult path, never by default. An `omp` dispatch starts in one command (`worker-start --agent omp`) with its model pinned by default arguments. Roster changes propagate to settings pins, rendered payloads, and target configs at apply time.
- **Unified skills:** Canonical skills deploy to `~/.agents/skills/`. Chezmoi deploys symbolic links `~/.claude/skills` and `~/.codex/skills` pointing to `~/.agents/skills`.

omp replaces Antigravity CLI in Orca. All eight Git actions use omp; the ordinary TUI default remains Claude. The native omp extension injects the current orchestration role before each model call.

omp sends `google-antigravity/*` requests directly to the provider. Antigravity CLI's managed files are removed; its authentication and conversation history remain.

Run `figma-auth` without arguments to authorize Figma for omp. It opens the browser and stores the result in omp's existing SQLite database. Other harnesses use their native Figma OAuth flow.

See [the transition guide](docs/operations/omp-transition.md) for deployment checks.

## Host steps for the Codex harness (one-time)

Claude Code and Codex are managed again. Two steps stay with the operator:

- If `~/.codex/skills` is a real directory (for example one holding a hand-installed
  skill), move its contents into `~/.agents/skills/` and remove the directory before
  the first apply, so chezmoi can place the symlink. The apply refuses to run while
  that directory still holds files, because chezmoi would delete them.
- After the first apply, run `codex plugin --help` and one `codex plugin add` by
  hand before trusting the reconciler. `codex mcp list` and `codex mcp get` print
  resolved header values; do not paste their output into issues or pull requests.

`home/.chezmoiremove` prunes the stray `~/.codex/codex.toml` that an earlier source
deployed; nothing else under `~/.codex` is touched by removal. Old payloads under
`~/.codex/packages/standalone/` and `~/.local/share/codex-plugins/` are not used
by the command store and may be deleted by hand.

## License

[MIT](LICENSE) © Joosung Park
