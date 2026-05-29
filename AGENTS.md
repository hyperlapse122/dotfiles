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
├── agents/                          # Cross-tool agent rules + shared slash commands / prompts.
│                                    # SHARED_AGENTS.md links into ~/.config/opencode/AGENTS.md and ~/.codex/AGENTS.md.
│                                    # commands/ links into ~/.config/opencode/commands and ~/.codex/prompts.
├── install.conf.yaml                # Shared dotbot tasks (all OSes)
├── install.linux.yaml               # Linux-only dotbot tasks
├── install.macos.yaml               # macOS-only dotbot tasks
├── install.windows.yaml             # Windows-only dotbot tasks
├── install.sh                       # Bootstrap for macOS + Linux
├── install.ps1                      # Bootstrap for Windows
├── crates/                          # Rust crates built into ~/.local/bin during bootstrap.
│                                    # mxm4-haptic: MX Master 4 HID++ haptic helper (Linux-only).
├── home/                            # Files that symlink into $HOME (home/foo -> ~/foo)
│   ├── .agents/                     # Runtime agent skill tree linked to ~/.agents
│   ├── .config/opencode/            # OpenCode config files (*.json, *.jsonc).
│                                    # AGENTS.md, commands/ are linked from agents/, not here.
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

### Branching — `main` only (overrides global Git Flow gate)

This repository commits directly to `main`. It does **not** use Git Flow branches (`feature/`, `bugfix/`, `hotfix/`, `refactor/`, `docs/`, `chore/`, `release/`) or any other topic-branch workflow. The branch-naming convention and pre-first-commit prefix gate in the global agent rules (`~/.config/opencode/AGENTS.md` / `~/.codex/AGENTS.md`) **do not apply here** — this project-level rule overrides them per the precedence rule (project `AGENTS.md` wins on conflict).

- **Commit straight to `main`.** Do not create, rename to, or switch to a topic branch before committing.
- **Do not run the prefix gate** (`git branch --show-current` check, `git branch -m <prefix>/<slug>` rename) on this repo. It is a single-maintainer dotfiles repo; the Git Flow ceremony adds no value.
- **No PRs/MRs required.** Push commits to `main` directly. (If a PR is ever explicitly requested, open it from `main` against `main` of a fork, or as instructed — but the default is direct commit.)
- Everything else in the global rules still applies: Conventional Commits message format, no committing secrets, no destructive/bypass git operations without explicit confirmation, no git-config edits.

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

NetworkManager unmanaged-device rules live as a single consolidated drop-in `system/linux/etc/NetworkManager/conf.d/99-unmanaged-devices.conf` (replacing earlier per-purpose `80-lo.conf` / `90-unmanaged-vmware.conf` / `91-tailscale.conf` / `92-docker.conf` / `93-veth.conf` split files; one [keyfile]/unmanaged-devices key per file is sufficient and easier to audit than five overlapping drop-ins). The deleted split files are listed in `REMOVED_ETC_PATHS` in `scripts/linux/install-linux-system-config.sh` so machines pulling the consolidation also drop the orphans. Do not consolidate further into a monolithic `NetworkManager.conf` — that file is intentionally absent from this repo (drop-ins under `conf.d/` are the supported integration point).

Current Linux root-owned config includes NetworkManager Wi-Fi power-save and unmanaged-device drop-ins, keyd defaults, a libinput local override, `locale.conf`, Plymouth config, a Logitech receiver udev rule, IPv4/IPv6 forwarding via `sysctl.d/`, a VM-only `sudoers.d/` drop-in granting `%wheel` password-less sudo, and a `docker-prune.service` / `docker-prune.timer` pair under `systemd/system/` that runs `docker system prune --force` + `docker volume prune --force` weekly. All install at mode `0644` except the `sudoers.d/` drop-in (mode `0440`, VM-only) — see `scripts/linux/install-linux-system-config.sh`.

The script exits 0 immediately when invoked from a non-interactive shell (stdin is not a TTY) without cached sudo credentials. Dotbot runs this from a `shell:` step during bootstrap; under `./install.sh` stdin is a TTY and sudo can prompt, but under agent or CI runs there is no TTY and an uncached sudo would hang or fail. Skipping cleanly lets the rest of the dotbot run finish. The user re-runs `bash scripts/linux/install-linux-system-config.sh` manually afterwards. After the file-install loop, the same script iterates an explicit `REMOVED_ETC_PATHS=(…)` array hard-coded near the top of the cleanup section and `rm -f`s each entry that still exists (including dangling symlinks, via `[[ -e || -L ]]`). When deleting a tracked file under `system/linux/etc/`, add its absolute `/etc` path to that array in the same commit — that is the manifest every machine reads to clean up orphans after pulling the deletion. The earlier `git status`-based detector was removed because it only saw uncommitted changes (clean worktree after pull == orphan persists); `git log --diff-filter=D` was rejected for the opposite reason (no idempotency, would retry removal forever). Entries can stay in the array for a release cycle or two with no cost — `rm -f` is a no-op once the path is gone. Then it runs `systemctl daemon-reload` (when `system/linux/etc/systemd/system/` exists) and `systemctl enable --now docker-prune.timer` (gated on `command -v docker`, so hosts that never ran `scripts/linux/install-packages.sh` are skipped; the service unit also carries `ConditionPathExists=/usr/bin/docker` as a runtime safety net). It then configures firewalld for Tailscale and VMware: IPv4 masquerade on the default zone (`firewall-cmd --permanent --add-masquerade`), `tailscale0` bound to the `trusted` zone (`--zone=trusted --add-interface=tailscale0`), and UDP 41641 (WireGuard) + UDP 3478 (STUN) opened on the `public` zone (`--zone=public --add-port=…/udp`). Each step is gated on its own `--query-*` probe and a single `--reload` runs at the end only if anything changed. It then sweeps `/etc/NetworkManager/conf.d/` for dangling symlinks (left behind when Home Manager symlinks into `/nix/store/` outlive the store path during Nix decommission) and removes only those — live symlinks and regular files are left alone, so the sweep can't accidentally remove a drop-in placed by another tool. Finally, it runs `systemctl reload NetworkManager` (gated on `systemctl is-active --quiet NetworkManager`, so hosts using systemd-networkd or no NetworkManager are skipped) to pick up the cleaned state and any freshly-installed `/etc/NetworkManager/conf.d/` drop-ins without restarting the service or disrupting active connections. The Tailscale exit-node and VMware NAT egress paths source-NAT through the host's primary interface, which lives in the default zone on Fedora Workstation, and they ride on the IPv4/IPv6 forwarding the `sysctl.d/` drop-in enables. The step is idempotent (`--permanent --query-masquerade` before mutating) and gated on `firewall-cmd --state` so it skips cleanly when firewalld is masked, missing, or replaced by another backend.

### Runtime agent config

- `.agents/skills/` is reserved for repo-local skills that describe how to operate this repository. No skills are currently tracked.
- `home/.agents/` is linked to `~/.agents` and is intentionally writable by OpenCode / oh-my-openagent at runtime. Do not describe it as Nix-managed.
- `home/.agents/.skill-lock.json` and `home/.agents/skills/*` are managed artifacts. Do not hand-edit them unless explicitly working through the skill manager.
- `home/.agents/AGENTS.md` MUST NOT exist. Because `home/.agents/` links to `~/.agents`, that file can be injected into every agent run from this user account. Put that guidance in `home/AGENTS.md` instead.
- `agents/SHARED_AGENTS.md` is the cross-tool agent rules file. `install.conf.yaml` symlinks it to each AI tool's global AGENTS.md path: `~/.config/opencode/AGENTS.md` (OpenCode) and `~/.codex/AGENTS.md` (Codex). Edit `agents/SHARED_AGENTS.md` once; every linked tool sees the change. Add support for a new tool by adding a new explicit `link:` entry in `install.conf.yaml` and updating the linkage table in [`agents/README.md`](agents/README.md).
- `agents/commands/` is the cross-tool shared slash-command / prompt directory. `install.conf.yaml` symlinks the whole directory into each tool's command path: `~/.config/opencode/commands` (OpenCode slash commands) and `~/.codex/prompts` (Codex prompts). Each `*.md` file is a single command/prompt and works in either tool — keep the body tool-agnostic. Add a new command by dropping a `<name>.md` file in `agents/commands/`; no further wiring is needed. Add support for a new tool by adding a new explicit `link:` entry in `install.conf.yaml` pointing that tool's command path at `agents/commands` and updating the linkage table in [`agents/README.md`](agents/README.md).
- `home/.config/opencode/AGENTS.md` MUST NOT exist. `~/.config/opencode/AGENTS.md` is already an explicit symlink to `agents/SHARED_AGENTS.md` (managed in `install.conf.yaml`); a sibling source under `home/.config/opencode/` would conflict with that link. Put cross-tool rules in `agents/SHARED_AGENTS.md`. Put OpenCode-only rules in a new file under `agents/` linked separately from `install.conf.yaml`.
- `home/.config/opencode/commands/` MUST NOT exist. `~/.config/opencode/commands` is already an explicit symlink to `agents/commands`; a sibling source under `home/.config/opencode/commands/` would conflict with that link. Put new slash commands in `agents/commands/`. The OpenCode glob link for `home/.config/opencode/` is intentionally narrowed to `*.{json,jsonc}` so a stray `commands/` subdir there cannot collide.
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
| Fedora package install | `scripts/linux/install-packages.sh` (manual; enables COPRs, RPM Fusion, 1Password, VS Code, Docker, Tailscale, and Proton VPN repos; installs packages, dotnet tools, and enables services) |

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
- Adding `home/.config/opencode/commands/`. `~/.config/opencode/commands` is already an explicit symlink to `agents/commands`; a sibling source would conflict. Put new slash commands in `agents/commands/`.
- Hand-editing `~/.config/opencode/AGENTS.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/commands/*`, or `~/.codex/prompts/*`. Those are symlinks into `agents/` — edit the source under `agents/`.
- Updating agent workflow rules in only one `AGENTS.md` when the change also applies to the linked runtime agent docs.
- Editing migrated files inside `~/nix-config/`. That source tree is being abandoned — edit the copy in this repo's `home/` instead. Re-deriving from `~/nix-config/*.nix` modules is also wrong: those Nix expressions are not the canonical source post-migration.

## Solaar haptic playback (MX Master 4)

The MX Master 4 exposes HID++ feature `0x19B0` (HAPTIC) with 16 built-in waveforms. Solaar surfaces this as the `haptic-play` setting — a write-only action setting, not stateful. From shell:

```bash
solaar config "MX Master 4" haptic-play "<WAVEFORM>" 2>/dev/null || true
```

The `2>/dev/null || true` swallows the Solaar 1.1.19 + Python 3.14 `Gio.Application.run` marshalling crash (`TypeError: Unable to marshal str as an array`) — the same upstream bug that breaks `solaar config divert-keys`. The runtime HID++ command is dispatched before the persistence step crashes, so the mouse pulses regardless; only the post-dispatch persistence layer crashes. Track the upstream fix at <https://github.com/pwr-Solaar/Solaar>.

**Spawn cost per pulse is ~3.7 SECONDS** on this host (cold-cache `time` measurement, repeated three times) — the CLI bootstraps the full Solaar Python stack on every call. That makes `solaar config haptic-play` **unsuitable for any latency-sensitive feedback**: if you fire it from inside a Solaar rule via `Execute`, the pulse arrives 3-4 seconds after the trigger, which is well past any normal button hold.

**Inside Solaar rules, use the [`mxm4-haptic`](crates/mxm4-haptic/) binary** — `Execute: [mxm4-haptic, "<WAVEFORM>"]`. A zero-dependency Rust binary ([`crates/mxm4-haptic/`](crates/mxm4-haptic/), built into `~/.local/bin/` during bootstrap) that writes one HID++ Long report directly to the Bolt receiver's `:1.2` hidraw interface with **no ack wait** (~1-2 ms cold). An earlier Python helper did the same job at ~14 ms — interpreter startup was the entire cost, so it was rewritten in Rust. Solaar's own `Set: [null, haptic-play, "<WAVEFORM>"]` is the obvious-looking alternative and was tried first; it's in-process (no spawn) but `PlayHapticWaveForm` doesn't set `no_reply=True` on `FeatureRW`, so Solaar waits for an HID++ ack — and Bolt-wireless ack timing varies 30-300 ms, making some pulses feel "missing" because they arrive after the user has stopped paying attention. The binary bypasses that entirely.

The binary requires `~/.cache/mxm4-haptic.json` populated by [`scripts/linux/config-solaar.sh`](scripts/linux/config-solaar.sh) during dotbot bootstrap (parses `solaar show` for the MX Master 4 device index on the Bolt receiver and the HAPTIC feature index). The binary also caches the resolved `/dev/hidrawN` node there on first run (hidraw numbering isn't stable across reboots, so it re-resolves on open failure). Re-run that script after re-pairing the mouse.

For shell scripts where you don't have a Solaar rule context, either invoke the binary directly (`mxm4-haptic "<WAVEFORM>"`) or fall back to `solaar config haptic-play "<WAVEFORM>" 2>/dev/null || true` — accept the 3.7s spawn latency for the latter. **Do not chain `solaar config` calls in a tight loop** under any path — the HID++ queue backlogs. Concurrent use of the binary with a running Solaar autostart session is safe: writes go to the same hidraw node Solaar holds, and Solaar's reader is unaffected by fire-and-forget writes from another process.

Waveforms (from `logitech_receiver.hidpp20_constants.HapticWaveForms`):

| Theme | Names |
|---|---|
| State / collision | `SHARP STATE CHANGE`, `DAMP STATE CHANGE`, `SHARP COLLISION`, `DAMP COLLISION`, `SUBTLE COLLISION`, `WHISPER COLLISION` |
| Alerts | `HAPPY ALERT`, `ANGRY ALERT`, `COMPLETED`, `MAD` |
| Rhythmic | `SQUARE`, `WAVE`, `FIREWORK`, `KNOCK`, `JINGLE`, `RINGING` |

Multi-word names **require quoting**. Intensity scales with `haptic-level` (0-100, persists across reconnect; set in the Solaar GUI — the dotfiles bootstrap deliberately does NOT enforce a level since the helper's no-ack-wait path makes mid-range intensities reliably perceived). A current consumer of this API: the Haptic-hold-detection rule in [`home/.config/solaar/rules.yaml`](home/.config/solaar/rules.yaml) pulses a waveform from a `Later` callback when hold-mode is detected, giving tactile confirmation that the threshold was crossed.

For a non-Solaar path (direct HID++ over `/dev/hidraw5` to feature `0x19B0`), the byte sequence is what `mxm4-haptic` implements — see that script for the exact packet layout. The shortcut to write your own variant from scratch is documented in the Logitech HID++ 2.0 spec.

## References

- dotbot (schema, cross-platform notes): https://github.com/anishathalye/dotbot
- mise: https://mise.jdx.dev/
- uv / uvx: https://docs.astral.sh/uv/
- Fedora package management (`dnf`): https://docs.fedoraproject.org/en-US/quick-docs/dnf/
- Solaar rules reference: https://pwr-solaar.github.io/Solaar/rules
- Solaar HID++ feature implementations: <https://github.com/pwr-Solaar/Solaar/tree/master/lib/logitech_receiver>
