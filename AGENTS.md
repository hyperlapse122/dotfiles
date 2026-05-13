# AGENTS.md

Cross-platform dotfiles for **Windows + macOS + Fedora Linux**. Symlinks are managed by [dotbot](https://github.com/anishathalye/dotbot) invoked via mise-managed `uvx`.

> **Status**: bootstrapped. Framework is in place; per-app dotfile content is migrated from `~/nix-config` (Home Manager outputs) commit-by-commit.
>
> **NixOS is being decommissioned.** Home Manager-generated outputs (`~/.config/*`, `~/.zshrc`, `~/.gnupg/*.conf`, etc.) are imported INTO this repo as the new source of truth. **Once a file is migrated, edit it HERE — never in `~/nix-config/`.** The Nix source tree is being abandoned and will be deleted after Fedora migration.

User-facing quickstart belongs in `README.md` (top-level). This file (`AGENTS.md`) is for agents only.

## Layout

```
.
├── AGENTS.md
├── README.md                        # User quickstart, top-level
├── .agents/                         # Reserved repo-local agent skill tree (placeholder only today)
├── agents/                          # Cross-tool agent rules linked into ~/.config/opencode/AGENTS.md, ~/.codex/AGENTS.md, ...
├── install.conf.yaml                # Shared dotbot tasks (all OSes)
├── install.linux.yaml               # Linux-only dotbot tasks
├── install.macos.yaml               # macOS-only dotbot tasks
├── install.windows.yaml             # Windows-only dotbot tasks
├── install.sh                       # Bootstrap for macOS + Linux
├── install.ps1                      # Bootstrap for Windows
├── home/                            # Files that symlink into $HOME (home/foo -> ~/foo)
│   ├── .agents/                     # Runtime agent skill tree linked to ~/.agents
│   ├── .config/opencode/            # OpenCode config and custom commands (not AGENTS.md)
│   └── .secrets/*.1password         # 1Password templates rendered to ~/.secrets/
├── system/<os>/                     # Root-owned files mirroring absolute paths,
│                                    # e.g. system/linux/etc/NetworkManager/conf.d/...
│                                    # NOT installed via dotbot — see "Root-owned config".
└── scripts/                         # Bootstrap helpers plus manual setup scripts
    ├── auth/                        # Auth/login helpers and CLI auth configuration
    ├── bootstrap/                   # Helpers invoked by dotbot bootstrap steps
    └── linux/                       # Linux-only package, system, and KDE setup
```

Every tracked top-level directory MUST have its own `README.md` describing what lives there and how it is consumed. Untracked tool state directories such as `.git/`, `.codex/`, and `.sisyphus/` are not part of the documented repo surface.

## Hard rules

### dotbot — mise-managed `uvx` only, NEVER install

- The **only** way dotbot is invoked in this repo is `mise exec uv@latest -- uvx dotbot ...`. `uvx` runs the package ephemerally from PyPI, so every machine gets the same dotbot regardless of local Python state. **Do not install dotbot.** Forbidden, all of these:
  - `pip install dotbot`, `pip install --user dotbot`
  - `pipx install dotbot`
  - `uv tool install dotbot` (this is `uv`'s *persistent* install — it is NOT what we want)
  - `brew install dotbot`, `apt install dotbot`, `dnf install dotbot`, etc.
  - vendoring dotbot's source into this repo or adding a `dotbot/` git submodule (the canonical upstream template uses a submodule — **we deliberately don't**)
- The single canonical invocation: `mise exec uv@latest -- uvx dotbot -d "$REPO_ROOT" -c install.conf.yaml install.<os>.yaml`. Both `install.sh` and `install.ps1` MUST call exactly this; nothing else may run dotbot.
- **Pass both yaml files under a SINGLE `-c` flag.** dotbot's `-c` is argparse `nargs='+'` (not `append`); writing `-c install.conf.yaml -c install.<os>.yaml` silently drops the first file (only the last `-c` wins). Don't change this back.
- The bootstrap scripts MUST NOT install `mise`; users install `mise` themselves before running the scripts. The scripts may only verify that `mise` is available, then use `mise exec uv@latest -- uvx`. **Do not** add a step that installs dotbot itself.
- `install.conf.yaml` MUST start with `defaults: { link: { create: true, relink: true, force: true } }` so individual link entries don't have to repeat them. This repo intentionally treats tracked dotfiles as authoritative: real files at managed targets are overwritten with repo symlinks during bootstrap. This is **not** stow-style adoption; do not move target files into the repo unless explicitly asked.
- Per-OS files exist because dotbot's `if:` directive runs in `$SHELL`, which is unreliable on Windows (requires `bash -c` wrapping and an installed bash). **Do platform-gating via per-OS files, not `if:`.** `if:` is acceptable for finer Unix-only conditionals (per-host gates, optional package presence).
- Per-OS install files SHOULD also keep the same link defaults (`create`, `relink`, and `force`) unless a platform has a specific reason to diverge.

### Script parity (HARD)

Every script ships in **both** forms or it is broken:

| Surface | Extension | Targets |
|---|---|---|
| POSIX | `.sh` (`#!/usr/bin/env bash`) | macOS + Linux |
| PowerShell | `.ps1` | Windows |

Adding `foo.sh` without `foo.ps1` is a regression. The two MUST behave equivalently for their target platforms; if a feature is impossible on one side, the script SHOULD exit with a clear error rather than silently no-op.

Exception: scripts that are inherently single-platform MAY skip parity — document the reason in a header comment in the script itself. Current exceptions: `scripts/linux/install-linux-system-config.sh` (writes to `/etc/`, Linux only), `scripts/linux/install-packages.sh` (uses `dnf`, Fedora only), `scripts/linux/config-kde.sh` (configures KDE Plasma 6, Linux only), and `scripts/auth/auth-tailscale.sh` (runs Linux `tailscale up` with `sudo`).

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

The Linux installer discovers files with a recursive glob under `system/linux/etc/`; most files install at mode `0644`. The one exception is `system/linux/etc/sudoers.d/*`, which the installer special-cases: mode `0440` (sudo refuses group/world-readable drop-ins) and gated on `systemd-detect-virt --vm` so the rule only lands on virtual machines, never on bare-metal hosts. Sudoers drop-ins are also syntax-checked with `visudo -c -f` before install. Adding or removing a root-owned config file outside `sudoers.d/` should not require editing the install script; any other file that needs a non-default mode or a platform/host gate does.

NetworkManager unmanaged-device rules live as split drop-ins under `system/linux/etc/NetworkManager/conf.d/`, matching the legacy dotfiles layout. Do not consolidate them into a monolithic `NetworkManager.conf` — that file is intentionally absent from this repo.

Current Linux root-owned config includes NetworkManager unmanaged-device drop-ins, keyd defaults, a libinput local override, `locale.conf`, Plymouth config, a Logitech receiver udev rule, and a VM-only `sudoers.d/` drop-in granting `%wheel` password-less sudo. All install at mode `0644` except the `sudoers.d/` drop-in (mode `0440`, VM-only) — see `scripts/linux/install-linux-system-config.sh`.

### Runtime agent config

- `.agents/skills/` is reserved for repo-local skills that describe how to operate this repository. No skills are currently tracked.
- `home/.agents/` is linked to `~/.agents` and is intentionally writable by OpenCode / oh-my-openagent at runtime. Do not describe it as Nix-managed.
- `home/.agents/.skill-lock.json` and `home/.agents/skills/*` are managed artifacts. Do not hand-edit them unless explicitly working through the skill manager.
- `home/.agents/AGENTS.md` MUST NOT exist. Because `home/.agents/` links to `~/.agents`, that file can be injected into every agent run from this user account. Put that guidance in `home/AGENTS.md` instead.
- `agents/SHARED_AGENTS.md` is the cross-tool agent rules file. `install.conf.yaml` symlinks it to each AI tool's global AGENTS.md path: `~/.config/opencode/AGENTS.md` (OpenCode) and `~/.codex/AGENTS.md` (Codex). Edit `agents/SHARED_AGENTS.md` once; every linked tool sees the change. Add support for a new tool by adding a new explicit `link:` entry in `install.conf.yaml` and updating the linkage table in [`agents/README.md`](agents/README.md).
- `home/.config/opencode/AGENTS.md` MUST NOT exist. `~/.config/opencode/AGENTS.md` is already an explicit symlink to `agents/SHARED_AGENTS.md` (managed in `install.conf.yaml`); a sibling source under `home/.config/opencode/` would conflict with that link. Put cross-tool rules in `agents/SHARED_AGENTS.md`. Put OpenCode-only rules in a new file under `agents/` linked separately from `install.conf.yaml`.
- Keep all agent rule files in sync when changing agent workflow rules. In this repo that currently means this file, `home/AGENTS.md`, `agents/AGENTS.md`, and `agents/SHARED_AGENTS.md`. The shared file is loaded globally by OpenCode and Codex via the symlinks above, so changes propagate to both tools immediately.

### Documentation sync (HARD)

Every change to repo structure, conventions, or bootstrap flow MUST update, in the same commit:

1. The owning directory's `README.md`.
2. This `AGENTS.md` if the change affects how an agent should work in this repo.
3. The top-level `README.md` if the change is user-visible (new bootstrap step, new supported platform, new prereq).

A commit or PR that adds or removes directories, renames bootstrap entrypoints, or changes platform support without README updates is incomplete and should not merge.

## Bootstrap chain

| From | Command |
|---|---|
| Fresh macOS / Linux | install `mise`, then `./install.sh` (runs mise-managed `uvx dotbot` with shared + OS yaml; shared yaml renders OpenCode prompt appends through mise-managed Node.js; OS yaml also runs `scripts/bootstrap/inject-1password-secrets.sh`, which no-ops when no `*.1password` templates exist and otherwise requires an authenticated `op` CLI session) |
| Fresh Windows | `.\install.ps1` (same contract, PowerShell; shared yaml renders OpenCode prompt appends through mise-managed Node.js; OS yaml also runs `scripts/bootstrap/inject-1password-secrets.ps1`, which no-ops when no `*.1password` templates exist and otherwise requires an authenticated `op` CLI session) |
| Re-link after pulling repo | same `install.sh` / `install.ps1`; dotbot's `relink: true` default makes it idempotent |
| Fedora package install | `scripts/linux/install-packages.sh` (manual; enables COPRs, RPM Fusion, 1Password, VS Code, Docker, and Tailscale repos; installs packages, dotnet tools, and enables services) |

`install.sh` MUST detect OS via `uname -s` (`Darwin` / `Linux`) and pass the matching `install.<os>.yaml` as the second `-c`. `install.ps1` always uses `install.windows.yaml`.

## Common mistakes

- Installing dotbot via `pip`, `pipx`, `uv tool install`, `brew`, or distro package manager. **Always use mise-managed `uvx dotbot`** — ephemeral, no install.
- Adding dotbot as a git submodule or vendoring its source.
- Splitting yaml files across multiple `-c` flags (`-c f1 -c f2`). dotbot's `-c` is `nargs='+'`, so the second `-c` overwrites the first. Use one `-c f1 f2`.
- Committing SSH/age/GPG private keys, API tokens, `.env` files, or anything else `.gitignore` is meant to keep out.
- `link: { force: true }` — destroys existing files silently.
- `cp` for `/etc/` files, or `sudo cp` instead of `sudo install -D -m <mode>`.
- Adding `.sh` without matching `.ps1`, or vice versa.
- Adding a top-level directory without a `README.md`, or moving things without updating the layout block in this file.
- Adding `home/.agents/AGENTS.md`. Use `home/AGENTS.md` for parent-scoped guidance instead.
- Adding `home/.config/opencode/AGENTS.md`. `~/.config/opencode/AGENTS.md` is already an explicit symlink to `agents/SHARED_AGENTS.md`; a second source would conflict. Edit the shared file, or add a new tool-specific file under `agents/` with its own `link:` entry.
- Hand-editing `~/.config/opencode/AGENTS.md` or `~/.codex/AGENTS.md`. Those are symlinks to `agents/SHARED_AGENTS.md` — edit the source.
- Updating agent workflow rules in only one `AGENTS.md` when the change also applies to the linked runtime agent docs.
- Editing migrated files inside `~/nix-config/`. That source tree is being abandoned — edit the copy in this repo's `home/` instead. Re-deriving from `~/nix-config/*.nix` modules is also wrong: those Nix expressions are not the canonical source post-migration.

## References

- dotbot (schema, cross-platform notes): https://github.com/anishathalye/dotbot
- mise: https://mise.jdx.dev/
- uv / uvx: https://docs.astral.sh/uv/
- Fedora package management (`dnf`): https://docs.fedoraproject.org/en-US/quick-docs/dnf/
