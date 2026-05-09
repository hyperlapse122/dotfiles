# dotfiles

Cross-platform dotfiles for **Windows + macOS + Arch Linux**, managed by [dotbot](https://github.com/anishathalye/dotbot) via mise-managed `uvx`.

`uvx dotbot` is run **ephemerally** through [`mise`](https://mise.jdx.dev/) every time — dotbot itself is never installed. The bootstrap also runs a small set of helpers for fonts, GitLab CLI config, Linux `/etc` drop-ins, and KDE touchpad/font preferences where applicable.

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

### Fresh Arch from ISO

Boot the Arch live ISO, get network up, copy your host's archinstall configs onto the live system, then:

```sh
archinstall \
  --config archinstall/<hostname>/user_configuration.json \
  --creds  archinstall/<hostname>/user_credentials.json \
  --silent
```

`custom_commands` in `user_configuration.json` clones this repo and runs `install.sh` automatically before first boot. See [`archinstall/README.md`](./archinstall/README.md).

Host configs may also install first-boot services. `archinstall/UX5606` enables a Secure Boot/TPM enrollment service that signs boot artifacts with `sbctl` and enrolls TPM2 unlock for the root LUKS device after the installed system boots.

For the Lenovo ThinkPad T14 Gen 2 profile, follow the physical install guide in [`archinstall/t14-gen2/README.md`](./archinstall/t14-gen2/README.md). It covers real credentials, disk selection, Secure Boot Setup Mode, and first-boot TPM verification.

## Requirements

| Platform | Required |
|---|---|
| macOS | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) (Xcode Command Line Tools cover all but `mise`) |
| Linux | `bash`, `curl`, `git`, `unzip`, [`mise`](https://mise.jdx.dev/) |
| Windows | PowerShell 5.1+, [`mise`](https://mise.jdx.dev/), [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/developer-mode-features-and-debugging) enabled (or run as Administrator) for symlink creation |

`unzip` is needed by [`scripts/install-fonts.sh`](./scripts/install-fonts.sh) (Windows uses built-in `Expand-Archive`). The font installer uses GitHub CLI (`gh`) when available and otherwise falls back to `mise exec gh@latest -- gh`.

Install [`mise`](https://mise.jdx.dev/) yourself before running the bootstrap scripts. dotbot itself is **never installed** — mise provides [`uv`](https://docs.astral.sh/uv/) for the invocation, and `uvx dotbot` runs dotbot ephemerally from PyPI every time.

## Repo structure

| Path | Purpose |
|---|---|
| `.agents/` | Repo-local agent skills, currently the `archinstall-host` workflow |
| `agents/` | Cross-tool agent rules linked into `~/.config/opencode/AGENTS.md` and `~/.codex/AGENTS.md` |
| `home/` | Files that symlink into `$HOME` (`home/foo` → `~/foo`) |
| `system/<os>/` | Root-owned config installed to absolute paths (e.g. `/etc/...`) |
| `archinstall/` | Arch unattended install configs + post-install bootstrap |
| `scripts/` | Helpers shared by `install.sh` / `install.ps1` |
| `install.conf.yaml` | Shared dotbot tasks |
| `install.<os>.yaml` | Per-OS dotbot tasks |
| `install.sh` / `install.ps1` | Bootstrap entrypoints |

[`AGENTS.md`](./AGENTS.md) is the source of truth for repo conventions. Read it before adding files.

## Re-running

`./install.sh` and `.\install.ps1` are idempotent — dotbot's `relink: true` default replaces existing symlinks in place, and helper scripts skip or overwrite deterministic targets safely. Re-run after every `git pull`.

The first run downloads fonts (Pretendard, Pretendard JP, JetBrains Mono, D2Coding, plus Nerd Font variants of the latter two) into the user font directory — `~/.local/share/fonts` on Linux, `~/Library/Fonts` on macOS, `%LOCALAPPDATA%\Microsoft\Windows\Fonts` on Windows. Run [`scripts/install-fonts.{sh,ps1}`](./scripts/) directly with `--force` / `-Force` to refresh fonts later.

On Linux, the bootstrap also installs tracked files under [`system/linux/etc/`](./system/linux/etc/) to `/etc/` with `sudo install -D -m 644`, then applies KDE Plasma 6 font and touchpad preferences when a suitable KDE session is available.
