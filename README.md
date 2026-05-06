# dotfiles

Cross-platform dotfiles for **Windows + macOS + Arch Linux**, managed by [dotbot](https://github.com/anishathalye/dotbot) via `uvx`.

`uvx dotbot` is run **ephemerally** every time — dotbot itself is never installed, only [`uv`](https://docs.astral.sh/uv/) is.

## Quickstart

### macOS / Linux

```sh
git clone https://github.com/hyperlapse122/dotfiles-next.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/hyperlapse122/dotfiles-next.git $HOME\dotfiles
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

## Requirements

| Platform | Required |
|---|---|
| macOS | `bash`, `curl`, `git` (Xcode Command Line Tools cover all three) |
| Linux | `bash`, `curl`, `git` |
| Windows | PowerShell 5.1+, [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/developer-mode-features-and-debugging) enabled (or run as Administrator) for symlink creation |

The bootstrap scripts install [`uv`](https://docs.astral.sh/uv/) automatically if missing. dotbot itself is **never installed** — `uvx dotbot` runs it ephemerally from PyPI on every invocation.

## Repo structure

| Path | Purpose |
|---|---|
| `home/` | Files that symlink into `$HOME` (`home/foo` → `~/foo`) |
| `system/<os>/` | Root-owned config installed to absolute paths (e.g. `/etc/...`) |
| `archinstall/` | Arch unattended install configs + post-install bootstrap |
| `scripts/` | Helpers shared by `install.sh` / `install.ps1` |
| `install.conf.yaml` | Shared dotbot tasks |
| `install.<os>.yaml` | Per-OS dotbot tasks |
| `install.sh` / `install.ps1` | Bootstrap entrypoints |

[`AGENTS.md`](./AGENTS.md) is the source of truth for repo conventions. Read it before adding files.

## Re-running

`./install.sh` and `.\install.ps1` are idempotent — dotbot's `relink: true` default replaces existing symlinks in place. Re-run after every `git pull`.
