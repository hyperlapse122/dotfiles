# dotfiles

Cross-platform dotfiles for **Windows + macOS + Fedora Linux**, managed by [dotbot](https://github.com/anishathalye/dotbot) via mise-managed `uvx`.

`uvx dotbot` is run **ephemerally** through [`mise`](https://mise.jdx.dev/) every time — dotbot itself is never installed. The bootstrap also runs a small set of helpers for fonts, GitLab CLI config, 1Password template injection, Linux `/etc` drop-ins, and KDE touchpad/font preferences where applicable.

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

[`scripts/install-packages.sh`](./scripts/install-packages.sh) enables COPRs (keyd, mise), RPM Fusion, and third-party repos (1Password, VS Code, Docker, Chrome) before installing packages via `dnf`. Run it manually once you're sure of the package set:

```sh
./scripts/install-packages.sh
```

It is **not** invoked from `install.sh` — package selection is opinionated and should be reviewed before running.

## Requirements

| Platform | Required |
|---|---|
| macOS | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) (Xcode Command Line Tools cover all but `mise`) |
| Linux | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) |
| Windows | PowerShell 5.1+, [`mise`](https://mise.jdx.dev/), [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/developer-mode-features-and-debugging) enabled (or run as Administrator) for symlink creation |

`unzip` is needed by [`scripts/install-fonts.sh`](./scripts/install-fonts.sh) (Windows uses built-in `Expand-Archive`). The font installer uses GitHub CLI (`gh`) when available and otherwise falls back to `mise exec gh@latest -- gh`. If any `*.1password` templates are tracked in the repo, the bootstrap renders them into `~/.secrets/` with [`op inject`](https://developer.1password.com/docs/cli/reference/commands/inject/); install and sign in to the 1Password CLI before bootstrapping on machines that need those secrets.

Install [`mise`](https://mise.jdx.dev/) yourself before running the bootstrap scripts. dotbot itself is **never installed** — mise provides [`uv`](https://docs.astral.sh/uv/) for the invocation, and `uvx dotbot` runs dotbot ephemerally from PyPI every time.

## Repo structure

| Path | Purpose |
|---|---|
| `.agents/` | Repo-local agent skills (currently empty) |
| `agents/` | Cross-tool agent rules linked into `~/.config/opencode/AGENTS.md` and `~/.codex/AGENTS.md` |
| `home/` | Files that symlink into `$HOME` (`home/foo` → `~/foo`) |
| `system/<os>/` | Root-owned config installed to absolute paths (e.g. `/etc/...`) |
| `scripts/` | Helpers shared by `install.sh` / `install.ps1` |
| `install.conf.yaml` | Shared dotbot tasks |
| `install.<os>.yaml` | Per-OS dotbot tasks |
| `install.sh` / `install.ps1` | Bootstrap entrypoints |

[`AGENTS.md`](./AGENTS.md) is the source of truth for repo conventions. Read it before adding files.

## Re-running

`./install.sh` and `.\install.ps1` are idempotent — dotbot's `relink: true` default replaces existing symlinks in place, and helper scripts skip or overwrite deterministic targets safely. Re-run after every `git pull`.

The first run downloads fonts (Pretendard, Pretendard JP, JetBrains Mono, D2Coding, plus Nerd Font variants of the latter two) into the user font directory — `~/.local/share/fonts` on Linux, `~/Library/Fonts` on macOS, `%LOCALAPPDATA%\Microsoft\Windows\Fonts` on Windows. Run [`scripts/install-fonts.{sh,ps1}`](./scripts/) directly with `--force` / `-Force` to refresh fonts later.

On Linux, the bootstrap also installs tracked files under [`system/linux/etc/`](./system/linux/etc/) to `/etc/` with `sudo install -D -m 644` (the `etc/sudoers.d/` subtree installs at mode `0440` and only on virtual machines), then applies KDE Plasma 6 font and touchpad preferences when a suitable KDE session is available.
