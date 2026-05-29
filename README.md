# dotfiles

Cross-platform dotfiles for **Windows + macOS + Fedora Linux**, managed by [dotbot](https://github.com/anishathalye/dotbot) via mise-managed `uvx`.

`uvx dotbot` is run **ephemerally** through [`mise`](https://mise.jdx.dev/) every time — dotbot itself is never installed. The bootstrap also runs a small set of helpers for fonts, GitLab CLI config, OpenCode prompt rendering, retired Linux `environment.d` symlink cleanup, 1Password template injection, Linux `/etc` drop-ins, and KDE touchpad/font preferences where applicable.

## Quickstart

### macOS / Linux

```sh
git clone https://github.com/hyperlapse122/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/hyperlapse122/dotfiles.git $HOME\dotfiles
cd $HOME\dotfiles
.\install.ps1
```

### Fedora packages (optional)

[`scripts/linux/install-packages.sh`](./scripts/linux/install-packages.sh) enables COPRs (keyd, mise), RPM Fusion, and third-party repos (1Password, VS Code, Docker, Chrome, Tailscale, Proton VPN) before installing packages via `dnf`, installing selected dotnet global tools, enabling `keyd`/`docker`/`tailscaled`, and adding the user to the `docker` and `keyd` groups. Run it manually once you're sure of the package set:

```sh
./scripts/linux/install-packages.sh
```

It is **not** invoked from `install.sh` — package selection is opinionated and should be reviewed before running.

## Requirements

| Platform | Required |
|---|---|
| macOS | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) (Xcode Command Line Tools cover all but `mise`) |
| Linux | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) |
| Windows | PowerShell 5.1+, [`mise`](https://mise.jdx.dev/), [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/developer-mode-features-and-debugging) enabled (or run as Administrator) for symlink creation |

`unzip` is needed by [`scripts/bootstrap/install-fonts.sh`](./scripts/bootstrap/install-fonts.sh) (Windows uses built-in `Expand-Archive`). The font installer uses GitHub CLI (`gh`) when available and otherwise falls back to `mise exec gh@latest -- gh`. If any `*.1password` templates are tracked in the repo, the bootstrap renders them into `~/.secrets/` with [`op inject`](https://developer.1password.com/docs/cli/reference/commands/inject/); install and sign in to the 1Password CLI before bootstrapping on machines that need those secrets.

Install [`mise`](https://mise.jdx.dev/) yourself before running the bootstrap scripts. dotbot itself is **never installed** — mise provides [`uv`](https://docs.astral.sh/uv/) for the invocation, `uvx dotbot` runs dotbot ephemerally from PyPI every time, and the OpenCode prompt renderer runs through mise-managed Node.js.

## Repo structure

| Path | Purpose |
|---|---|
| `.agents/` | Reserved repo-local agent skill tree; only the placeholder `skills/.gitkeep` is tracked today |
| `agents/` | Cross-tool agent rules linked into `~/.config/opencode/AGENTS.md` and `~/.codex/AGENTS.md` |
| `crates/` | Rust crates built into `~/.local/bin` during bootstrap (e.g. the Linux-only `mxm4-haptic` set — an MX Master 4 haptic daemon, a desktop-notification bridge, and a Solaar client) |
| `home/` | User-owned dotfiles, runtime skill packages, and `*.1password` templates that install under `$HOME` |
| `packages/` | Yarn Berry monorepo (the private `@h82/dotfiles` workspace, rooted at `packages/`) of TypeScript/JavaScript libraries (e.g. `@h82/mxm4-haptic`, a Node/Bun client for the `mxm4-hapticd` daemon). Not installed by bootstrap |
| `system/<os>/` | Root-owned config installed to absolute paths (e.g. `/etc/...`) |
| `scripts/` | Bootstrap helpers plus manual auth/package/system setup scripts, grouped by role |
| `install.conf.yaml` | Shared dotbot tasks |
| `install.<os>.yaml` | Per-OS dotbot tasks |
| `install.sh` / `install.ps1` | Bootstrap entrypoints |

[`AGENTS.md`](./AGENTS.md) is the source of truth for repo conventions. Read it before adding files.

## Re-running

`./install.sh` and `.\install.ps1` are idempotent — dotbot's link defaults create missing parents, relink existing symlinks, and force repo-managed links over real files at managed targets. This is overwrite behavior, not `stow --adopt`: existing target files are replaced by symlinks to the tracked repo files. `mise install` refreshes configured tools, and helper scripts skip or overwrite deterministic targets safely. Re-run after every `git pull`.

The first run downloads fonts (Pretendard, Pretendard JP, JetBrains Mono, D2Coding, plus Nerd Font variants of the latter two) into the user font directory — `~/.local/share/fonts` on Linux, `~/Library/Fonts` on macOS, `%LOCALAPPDATA%\Microsoft\Windows\Fonts` on Windows. Run [`scripts/bootstrap/install-fonts.{sh,ps1}`](./scripts/bootstrap/) directly with `--force` / `-Force` to refresh fonts later.

On Linux, the bootstrap also installs tracked files under [`system/linux/etc/`](./system/linux/etc/) to `/etc/` with `sudo install -D -m 644` (the `etc/sudoers.d/` subtree installs at mode `0440` and only on virtual machines), disables NetworkManager Wi-Fi power saving by default, configures firewalld for Tailscale and VMware — IPv4 masquerade on the default zone (exit-node + NAT egress), `tailscale0` bound to the `trusted` zone, and UDP 41641 (WireGuard) + UDP 3478 (STUN) opened on the `public` zone (skipped when firewalld is not the active backend), then applies KDE Plasma 6 font, touchpad natural scrolling/tap-to-click/clickfinger, panel grouping, Kickoff list-view, Digital Clock calendar/date, Fcitx virtual-keyboard, and disabled screen-edge/corner preferences when a suitable KDE session is available.
