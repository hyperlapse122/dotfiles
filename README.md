# dotfiles

Personal [chezmoi](https://chezmoi.io)-managed dotfiles. Primary Linux targets are
**Fedora Linux** (KDE/Wayland) and **Kubuntu 26.04** (KDE Plasma 6); macOS and
Windows are supported as secondary targets.

## Set up a new device

Run the one-liner below. It downloads chezmoi, clones this repo, and applies it:

```sh
sh -c "$(curl -fsLS https://get.chezmoi.io)" -- init --apply hyperlapse122
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
    - **Fedora** installs these with `dnf`; **Kubuntu** (Ubuntu) uses `apt`
      (1Password apt repo + mise apt repo); macOS uses Homebrew (bootstrapping
      Homebrew first if needed).
4. Renders every template and applies it to `$HOME`, then runs the provisioning
   scripts under [`.chezmoiscripts/`](.chezmoiscripts) — installing packages from
   [`.chezmoidata/packages.yaml`](.chezmoidata/packages.yaml) (Fedora via dnf,
   Kubuntu via apt), fonts, importing the GPG key, authenticating GitHub / GitLab
   / Tailscale, switching the login shell to zsh, and writing KDE / Solaar /
   system config. On Kubuntu, additionally strips Canonical branding to upstream
   Breeze (SDDM theme, Plymouth boot splash, per-user desktop theme, branding
   packages) and enables Tailscale egress-NAT via ufw.

## Prerequisites

- **Fedora Linux** or **Kubuntu 26.04 (KDE)** for the full experience.
  Detection is implicit — `osRelease.id` (`fedora` or `ubuntu`) + runtime guards;
  no interactive prompt. On Kubuntu, provisioning is apt-based and additionally
  strips Canonical's Kubuntu branding back to upstream KDE Breeze reproducibly on
  every `chezmoi apply`.
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
3. Re-run to finish applying:

   ```sh
   chezmoi apply
   ```

`op user get --me` must succeed for the apply to complete.

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

This repository contains source-only trees that are excluded from deployment to `$HOME` via `.chezmoiignore`, and excluded from taplo formatting via `.taplo.toml`. Instead, they are built on apply by `.chezmoiscripts/build/` run_onchange scripts:

- `crates/mxm4-haptic/`: Built on apply by `.chezmoiscripts/build/run_onchange_after_build-mxm4-haptic.sh.tmpl` into `~/.local/bin/`. Linux builds all three binaries: `mxm4-hapticd`, `mxm4-haptic-notify`, and `mxm4-haptic`. macOS builds only the daemon and client.
- `packages/`: Built on apply by `.chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl` into `~/.config/opencode/plugins/`. It builds `@h82/opencode-playwright-cli-session-injection` (symlinked as `playwright-cli-session-injection.js` on Linux and macOS) and `@h82/opencode-mxm4-haptic` (symlinked as `mxm4-haptic.js` on Linux). `@h82/mxm4-haptic` is a library, not a plugin.

## License

[MIT](LICENSE) © Joosung Park
