# dotfiles

Cross-platform dotfiles for **Windows · macOS · Fedora Linux**, kept in sync from a single repo and applied with [dotbot](https://github.com/anishathalye/dotbot) — invoked **ephemerally** through [mise](https://mise.jdx.dev/)-managed `uvx`, so dotbot is never installed on the machine.

One `git clone` plus one bootstrap command symlinks every config into place, installs your toolchain via mise, fetches fonts, builds the local Rust/TypeScript helpers, and — on Linux — lays down `/etc` drop-ins, firewall rules, and KDE Plasma preferences. Re-run after any `git pull`; everything is idempotent.

## Quickstart

### macOS / Linux

```sh
git clone https://github.com/hyperlapse122/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh        # auto-detects Darwin vs Linux via `uname -s`
```

### Windows (PowerShell)

```powershell
git clone https://github.com/hyperlapse122/dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
.\install.ps1
```

That's it. The bootstrap script picks the matching `install.<os>.yaml`, runs the shared tasks, and links your dotfiles.

### Fedora packages (optional, manual)

The bootstrap deliberately does **not** install system packages — that list is opinionated and should be reviewed first. When you're ready:

```sh
./scripts/linux/install-packages.sh
```

This enables RPM Fusion, the keyd/mise COPRs, and third-party repos (1Password, VSCodium, Docker, Chrome, Tailscale, Proton VPN, VirtualBox), installs the package set, the Bottles flatpak from Flathub, and selected dotnet global tools, enables `keyd` / `docker` / `tailscaled` / `libvirtd`, and adds you to the relevant groups.

## How it works

| Principle | What it means |
|---|---|
| **Never install dotbot** | `mise exec uv@latest -- uvx dotbot …` runs dotbot straight from PyPI every time. No submodule, no `pip`, no vendoring — every machine gets the same version. |
| **Tracked files are authoritative** | dotbot links with `force: true`. Real files at managed targets are **replaced** by symlinks into the repo. This is overwrite behavior, not `stow --adopt`. |
| **You bring `mise`, the repo brings the rest** | Install [mise](https://mise.jdx.dev/) yourself; it then provides `uv`, Node, Rust, and the rest of the toolchain. `mise install` runs as part of bootstrap. |
| **Hardened package managers** | npm, pnpm, Yarn, and Bun configs ship with lifecycle scripts disabled, exact-version pinning, and a one-week dependency cooldown gate. |
| **Platform gating via files, not `if:`** | OS-specific work lives in `install.linux.yaml` / `install.macos.yaml` / `install.windows.yaml`, never in unreliable cross-shell `if:` directives. |

## What you get

- **Shell & tools** — zsh (Prezto-based), a curated [mise](https://mise.jdx.dev/) toolchain (Node, Bun, Go, Python, Ruby, Rust, plus CLIs like `gh`, `glab`, `ast-grep`, `shellcheck`), git, SSH, GnuPG, and Docker credential helpers.
- **Editors & agents** — VS Code, VSCodium, and Zed settings, plus cross-tool AI agent rules and slash commands linked into OpenCode and Codex from a single source in [`agents/`](./agents/). Shared OpenAI Codex settings are merged into `~/.codex/config.toml` from a tracked [`codex-config.managed.toml`](./codex/codex-config.managed.toml) — without clobbering machine-local state like per-project trust (Codex writes that back into the same file, so it can't be a plain symlink).
- **Fonts** — Pretendard, Pretendard JP, JetBrains Mono, D2Coding, and Nerd Font variants, installed user-wide (no admin) into the platform font directory.
- **Secrets** — any tracked `*.1password` template is rendered into `~/.secrets/` via [`op inject`](https://developer.1password.com/docs/cli/reference/commands/inject/) (no-ops when there are none).
- **Local helpers** — Rust [`crates/`](./crates/) built into `~/.local/bin` and a TypeScript [`packages/`](./packages/) Yarn workspace built in place (e.g. the MX Master 4 haptic stack — Linux + macOS via `hidapi`, autostarted by `systemd --user` / launchd respectively — plus OpenCode plugins auto-linked into `~/.config/opencode/plugins/`, such as the cross-platform `playwright-cli` per-project session injector).
- **Linux desktop polish** — root-owned `/etc` drop-ins, firewalld rules for Tailscale & VMware, and KDE Plasma 6 font/touchpad/panel preferences.

## Requirements

| Platform | Prerequisites |
|---|---|
| **macOS** | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) — Xcode Command Line Tools cover everything but `mise` |
| **Linux** | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) |
| **Windows** | PowerShell 5.1+, [`mise`](https://mise.jdx.dev/), and [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/developer-mode-features-and-debugging) enabled (or run as Administrator) so symlinks can be created |

Install [`mise`](https://mise.jdx.dev/) before bootstrapping — it supplies [`uv`](https://docs.astral.sh/uv/) for the ephemeral `uvx dotbot` run and the Node.js used to render OpenCode prompt config. The font installer uses `gh` when present and falls back to `mise exec gh@latest -- gh`. If any `*.1password` templates are tracked, sign in to the 1Password CLI first.

## Repo structure

| Path | Purpose |
|---|---|
| [`install.sh`](./install.sh) / [`install.ps1`](./install.ps1) | Bootstrap entrypoints (POSIX / PowerShell) |
| [`install.conf.yaml`](./install.conf.yaml) | Shared dotbot tasks, loaded on every OS |
| `install.<os>.yaml` | Per-OS dotbot links and `shell:` steps |
| [`home/`](./home/) | User-owned dotfiles, runtime skill tree, and `*.1password` templates that install under `$HOME` |
| [`system/`](./system/)`<os>/` | Root-owned config installed to absolute paths (e.g. `/etc/...`) via `sudo install -D` |
| [`scripts/`](./scripts/) | Bootstrap helpers plus manual auth/package/system setup, in `.sh` + `.ps1` pairs |
| [`crates/`](./crates/) | Rust crates `cargo install`'d into `~/.local/bin` during bootstrap (e.g. the MX Master 4 haptic daemon + Solaar client — Linux + macOS via `hidapi`, autostarted via `systemd --user`/launchd; the notification bridge is Linux-only) |
| [`packages/`](./packages/) | Private `@h82/dotfiles` Yarn Berry monorepo of TS/JS libraries — built in place, never installed |
| [`agents/`](./agents/) | Cross-tool AI agent rules and slash commands linked into OpenCode & Codex |
| [`codex/`](./codex/) | Tracked shared OpenAI Codex config: `codex-config.managed.toml` merged into `~/.codex/config.toml` by `scripts/bootstrap/configure-codex-config.*`, plus `hooks.json` (MX Master 4 haptic lifecycle hooks) symlinked to `~/.codex/hooks.json` on Linux + macOS |
| [`.github/`](./.github/) | CI: `packages.yml` (build/typecheck/test) and `lint.yml` (ESLint + Prettier) for the `packages/` workspace, plus an hourly workflow that opens PRs bumping opencode plugins to their latest GitHub release |

[`AGENTS.md`](./AGENTS.md) is the authoritative source for repo conventions — read it before adding files. Every tracked top-level directory carries its own `README.md`.

## Re-running

`./install.sh` and `.\install.ps1` are **idempotent** — dotbot creates missing parents, relinks existing symlinks, and forces repo-managed links over real files at managed targets; `mise install` refreshes tools; helper scripts skip or overwrite deterministic targets safely. Run it again after every `git pull`.

- **Fonts** are downloaded on first run into `~/.local/share/fonts` (Linux), `~/Library/Fonts` (macOS), or `%LOCALAPPDATA%\Microsoft\Windows\Fonts` (Windows). Refresh later with [`scripts/bootstrap/install-fonts.{sh,ps1}`](./scripts/bootstrap/) and `--force` / `-Force`.
- **Linux system config** installs tracked files under [`system/linux/etc/`](./system/linux/etc/) to `/etc/` (`sudoers.d/` only on VMs, at mode `0440`; ThinkPad `thinkpad_acpi` fan-control drop-ins only when `dmidecode` reports a ThinkPad), disables NetworkManager Wi-Fi power saving, configures firewalld for Tailscale & VMware (IPv4 masquerade, `tailscale0` → `trusted` zone, UDP 41641/3478 on `public`), and applies KDE Plasma 6 font, touchpad, panel, Kickoff, clock, IME, screen-edge, KRunner (Spotlight-style centered launcher), and Dolphin (home folder on startup) preferences — each step skips cleanly when its prerequisites are absent.

The Linux `/etc` and KDE steps no-op without a TTY (so agent/CI runs don't hang on `sudo`); re-run [`scripts/linux/install-linux-system-config.sh`](./scripts/linux/install-linux-system-config.sh) manually if they were skipped.
