# AGENTS.md

Cross-platform dotfiles for **Windows + macOS + Arch Linux**. Symlinks are managed by [dotbot](https://github.com/anishathalye/dotbot) invoked via `uvx`. Arch hosts are provisioned by [archinstall](https://github.com/archlinux/archinstall).

> **Status**: bootstrapped. Framework is in place; per-app dotfile content is migrated from `~/nix-config` (Home Manager outputs) commit-by-commit.
>
> **NixOS is being decommissioned.** Home Manager-generated outputs (`~/.config/*`, `~/.zshrc`, `~/.gnupg/*.conf`, etc.) are imported INTO this repo as the new source of truth. **Once a file is migrated, edit it HERE — never in `~/nix-config/`.** The Nix source tree is being abandoned and will be deleted after Arch Linux migration.

User-facing quickstart belongs in `README.md` (top-level). This file (`AGENTS.md`) is for agents only.

## Layout

```
.
├── AGENTS.md
├── README.md                        # User quickstart, top-level
├── install.conf.yaml                # Shared dotbot tasks (all OSes)
├── install.linux.yaml               # Linux-only dotbot tasks
├── install.macos.yaml               # macOS-only dotbot tasks
├── install.windows.yaml             # Windows-only dotbot tasks
├── install.sh                       # Bootstrap for macOS + Linux
├── install.ps1                      # Bootstrap for Windows
├── home/                            # Files that symlink into $HOME (home/foo -> ~/foo)
├── system/<os>/                     # Root-owned files mirroring absolute paths,
│                                    # e.g. system/linux/etc/NetworkManager/conf.d/...
│                                    # NOT installed via dotbot — see "Root-owned config".
├── archinstall/
│   ├── post-install.sh              # Bootstraps dotfiles after archinstall
│   ├── user_credentials.example.json
│   └── <hostname>/                  # Per-host configs
│       ├── user_configuration.json
│       └── user_credentials.json    # GITIGNORED
└── scripts/                         # Helpers used by install scripts
```

Every top-level directory MUST have its own `README.md` describing what lives there and how it is consumed.

## Hard rules

### dotbot — `uvx` only, NEVER install

- The **only** way dotbot is invoked in this repo is `uvx dotbot ...`. `uvx` runs the package ephemerally from PyPI, so every machine gets the same dotbot regardless of local Python state. **Do not install dotbot.** Forbidden, all of these:
  - `pip install dotbot`, `pip install --user dotbot`
  - `pipx install dotbot`
  - `uv tool install dotbot` (this is `uv`'s *persistent* install — it is NOT what we want)
  - `brew install dotbot`, `apt install dotbot`, `pacman -S dotbot`, etc.
  - vendoring dotbot's source into this repo or adding a `dotbot/` git submodule (the canonical upstream template uses a submodule — **we deliberately don't**)
- The single canonical invocation: `uvx dotbot -d "$REPO_ROOT" -c install.conf.yaml install.<os>.yaml`. Both `install.sh` and `install.ps1` MUST call exactly this; nothing else may run dotbot.
- **Pass both yaml files under a SINGLE `-c` flag.** dotbot's `-c` is argparse `nargs='+'` (not `append`); writing `-c install.conf.yaml -c install.<os>.yaml` silently drops the first file (only the last `-c` wins). Don't change this back.
- The bootstrap scripts' only prerequisite job is "ensure `uv` is on PATH" (via `curl -LsSf https://astral.sh/uv/install.sh | sh` or the matching PowerShell installer). Once `uv` is present, `uvx` handles the rest. **Do not** add a step that installs dotbot itself.
- `install.conf.yaml` MUST start with `defaults: { link: { create: true, relink: true } }` so individual link entries don't have to repeat them.
- Per-OS files exist because dotbot's `if:` directive runs in `$SHELL`, which is unreliable on Windows (requires `bash -c` wrapping and an installed bash). **Do platform-gating via per-OS files, not `if:`.** `if:` is acceptable for finer Unix-only conditionals (per-host gates, optional package presence).
- Forbidden in `link:` blocks: `force: true` — silently overwrites real files. If you truly need destructive behavior, use a `shell:` step that prompts the user.

### Script parity (HARD)

Every script ships in **both** forms or it is broken:

| Surface | Extension | Targets |
|---|---|---|
| POSIX | `.sh` (`#!/usr/bin/env bash`) | macOS + Linux |
| PowerShell | `.ps1` | Windows |

Adding `foo.sh` without `foo.ps1` is a regression. The two MUST behave equivalently for their target platforms; if a feature is impossible on one side, the script SHOULD exit with a clear error rather than silently no-op.

Exception: scripts that are inherently single-platform (e.g. `archinstall/post-install.sh` runs only inside an Arch chroot) MAY skip parity — document the reason in a header comment in the script itself.

### Root-owned config (`/etc/...`)

dotbot has no root mode and no sudo handling. Root-owned files live under `system/<os>/` mirroring their absolute install path:

```
system/linux/etc/NetworkManager/conf.d/wifi-powersave-off.conf
              -> /etc/NetworkManager/conf.d/wifi-powersave-off.conf
```

They are installed by a `shell:` step in the matching `install.<os>.yaml`, calling:

```sh
sudo install -D -m <mode> system/<os>/<abs/path> /<abs/path>
```

Use `sudo install -D` (atomically sets mode and creates parents). Do **not** use `cp`+`chmod` (loses ownership/mode atomicity), and do **not** try to express `/etc/...` as a dotbot `link:` (no sudo, dotbot will fail or silently link a user-owned file into a root-owned tree).

NetworkManager unmanaged-device rules live as split drop-ins under `system/linux/etc/NetworkManager/conf.d/`, matching the legacy dotfiles layout. Do not collapse them back into `NetworkManager.conf`.

### archinstall (Arch Linux only)

- archinstall has **no separate post-install `--script` hook**. The `--script` flag selects the installer flavor (`guided`, `minimal`, ...), not a user post-install step. The actual post-install hook is the `custom_commands` array in `user_configuration.json`. Each entry runs in `arch-chroot` of the new system, after package install and before unmount.
- End the host's `custom_commands` with the dotfiles bootstrap (install `git` and `uv`, clone this repo, run `install.sh`) so the first boot lands on a fully linked system. Keep the same logic in `archinstall/post-install.sh` for re-running outside the installer.
- The JSON schema changes between archinstall releases. **Regenerate with `archinstall --dry-run`** and copy the produced config out of `/var/log/archinstall/`. Don't hand-edit fields you don't understand — legacy keys (`audio_config`, `bootloader`, `!root-password`) still parse, but new configs use the current nested shape (`disk_config`, `bootloader_config`, `auth_config`).
- `user_credentials.json` MUST be gitignored. Only `user_credentials.example.json` lives in git. Same rule for SSH/age/GPG private keys, API tokens, and disk encryption keys — never commit, even briefly.

### Documentation sync (HARD)

Every change to repo structure, conventions, or bootstrap flow MUST update, in the same commit:

1. The owning directory's `README.md`.
2. This `AGENTS.md` if the change affects how an agent should work in this repo.
3. The top-level `README.md` if the change is user-visible (new bootstrap step, new supported platform, new prereq).

A commit or PR that adds or removes directories, renames bootstrap entrypoints, or changes platform support without README updates is incomplete and should not merge.

## Bootstrap chain

| From | Command |
|---|---|
| Fresh macOS / Linux | `./install.sh` (clones if missing, ensures `uv`, runs `uvx dotbot` with shared + OS yaml) |
| Fresh Windows | `.\install.ps1` (same contract, PowerShell) |
| Fresh Arch from ISO | `archinstall --config archinstall/<host>/user_configuration.json --creds archinstall/<host>/user_credentials.json --silent` — `custom_commands` finishes by running `install.sh` inside chroot |
| Re-link after pulling repo | same `install.sh` / `install.ps1`; dotbot's `relink: true` default makes it idempotent |
| Refresh archinstall schema | `archinstall --dry-run`, copy from `/var/log/archinstall/` |

`install.sh` MUST detect OS via `uname -s` (`Darwin` / `Linux`) and pass the matching `install.<os>.yaml` as the second `-c`. `install.ps1` always uses `install.windows.yaml`.

## Common mistakes

- Installing dotbot via `pip`, `pipx`, `uv tool install`, `brew`, or distro package manager. **Always `uvx dotbot`** — ephemeral, no install.
- Adding dotbot as a git submodule or vendoring its source.
- Splitting yaml files across multiple `-c` flags (`-c f1 -c f2`). dotbot's `-c` is `nargs='+'`, so the second `-c` overwrites the first. Use one `-c f1 f2`.
- Committing `user_credentials.json`, SSH/age/GPG private keys, API tokens, or anything else `archinstall/.gitignore` (or root `.gitignore`) is meant to keep out.
- `link: { force: true }` — destroys existing files silently.
- `cp` for `/etc/` files, or `sudo cp` instead of `sudo install -D -m <mode>`.
- Hand-editing archinstall JSON without `archinstall --dry-run` to verify the current schema first.
- Adding `.sh` without matching `.ps1`, or vice versa.
- Adding a top-level directory without a `README.md`, or moving things without updating the layout block in this file.
- Editing migrated files inside `~/nix-config/`. That source tree is being abandoned — edit the copy in this repo's `home/` instead. Re-deriving from `~/nix-config/*.nix` modules is also wrong: those Nix expressions are not the canonical source post-migration.

## References

- dotbot (schema, cross-platform notes): https://github.com/anishathalye/dotbot
- archinstall guided install: https://archinstall.archlinux.page/installing/guided.html
- uv / uvx: https://docs.astral.sh/uv/
