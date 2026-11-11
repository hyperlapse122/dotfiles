# dotfiles

A Nix flake configuring the owner's two personal machines from one repository:

- **`MS-7D91`** (`x86_64-linux`, NixOS): bare-metal desktop workstation running KDE Plasma 6 on Wayland, `nixos-unstable`, LUKS2 + Btrfs via disko, Secure Boot via Lanzaboote, and the proprietary NVIDIA driver.
- **`MacBook-Pro-Mac17-9`** (`aarch64-darwin`, `nix-darwin`): Apple silicon MacBook Pro (M5 Pro, model identifier `Mac17,9`), combining `nix-darwin`, Home Manager, and `nix-homebrew` in one system profile.

Every directory under `hosts/` is a host: the flake builds a production `<host>` output and a secret-free `<host>-bootstrap` output for each (`nixosConfigurations` on NixOS, `darwinConfigurations` on macOS), from one shared profile per OS plus the traits the host declares.

On the NixOS host (`MS-7D91`), apply from the checkout:

```sh
nr switch
```

(Or run `sudo nixos-rebuild switch --flake .#MS-7D91`.) After initial installation and age-key recovery, this applies the NixOS system, Home Manager configuration, `sops-nix` secrets, KWallet-backed desktop SSH key (`~/.ssh/id_ed25519_nix_config`), and `gh`/`glab` authentication files together. Three YubiKeys carry the same OpenPGP signing and encryption key (`keys/signing.asc`), each under its own PIN; any one of them handles Git signing and bootstrap age-identity recovery. Routine rebuilds use the local age identity at `/var/lib/sops-nix/key.txt`, protected by LUKS2 disk encryption.

On the macOS host (`MacBook-Pro-Mac17-9`), apply from the checkout:

```sh
nr switch
```

`nr switch` builds `darwinConfigurations.MacBook-Pro-Mac17-9.system` as the invoking user, registers `/nix/var/nix/profiles/system`, and activates the system and Home Manager layers through `sudo`. The first bootstrap apply installs Homebrew and the declared formulae and casks; production switches use the user-owned age identity at `~/.config/nix-config/age/key.txt` (protected by FileVault) to provision Xcode via `xcodes`, configure the TLS inspection CA bundle, and publish the CLI tokens and host SSH key. See [macOS hosts](docs/macos.md) for first setup and everyday use.

## Hosts

| Host | OS / System | Machine |
| --- | --- | --- |
| `MS-7D91` | NixOS (`x86_64-linux`) | MSI MS-7D91 desktop (Intel i7-13700F, NVIDIA GeForce RTX 3060, Samsung 980 PRO 1 TB NVMe + 2 TB SATA HDD) |
| `MacBook-Pro-Mac17-9` | macOS (`aarch64-darwin`, `nix-darwin`) | Apple silicon MacBook Pro (M5 Pro, model identifier `Mac17,9`) |

[Adding a host](docs/adding-a-host.md) covers adding another NixOS or macOS machine.

## Included tools

- **Shell and terminal**: zsh (with Prezto modules and extra completions), Ghostty (`Jetendard` font stack), `gh`, `glab`, `ghq` (`~/src`), `ripgrep`, `fd`, `bat`, `eza`, `fzf`, `jq`, `yq-go`, `direnv`, and `mise`.
- **Fonts**: Pretendard (`Pretendard` and `Pretendard Variable`), Jetendard, D2Coding and D2Coding Nerd Font, Monoplex KR Nerd, Kopub, Nanum Square Round, Noto Sans/Serif CJK, and Twemoji.
- **Security and signing**: GnuPG with `gpg-git` (card-status wakeup wrapper) and `dotfiles-pinentry` (`packages/pinentry-keyring.nix`), which stores each YubiKey's OpenPGP user PIN in Secret Service (`kdewallet`) on NixOS or the macOS Keychain under `dotfiles.pinentry.openpgp` (`yubikey:<serial>:user`) and falls back to `pinentry-qt` or `pinentry_mac`. 1Password GUI and CLI, Kleopatra (NixOS), and `sops` + `age`.
- **Coding agents and orchestration**:
  - **T3 Code `0.1.7`** (`packages/t3code.nix` desktop app and `packages/t3code-cli.nix` headless `t3` server, enabled via `my.t3.desktop.enable` and `my.t3.cli.enable`). Merged settings (`home/h82/t3code.nix`) default new threads to Codex `gpt-6.1-sol` at `high` effort, with Claude Opus 5.5 as fallback and `gpt-6-luna` for text generation, starting in a worktree with full access. T3-only delegation and CE model-ladder instructions ([agent routing](docs/agent-routing.md)) are injected at launch through each harness's native per-launch option (`--append-system-prompt-file` for Claude, `-c developer_instructions=...` for Codex, `--append-system-prompt` for Pi), while CLI launches receive only the baseline user instructions.
  - **Claude Code** (`packages/claude-code.nix`) and **Claude Desktop** (`packages/claude-desktop.nix` on NixOS, Homebrew cask on macOS). Scalar preferences (`language = "korean"`, `theme = "auto"`, notifications, cleanup retention, `disableClaudeAiConnectors = true`, `worktree.baseRef = "head"`) and the `fff` MCP server are merged into `~/.claude/settings.json` and `~/.claude.json`; model, effort, and context window remain the owner's choice.
  - **Codex** (`packages/codex.nix`) and **ChatGPT** (`packages/chatgpt.nix` on NixOS, Homebrew cask on macOS). The wrapper and `~/.codex/config.toml` reconciliation disable built-in app connectors and Computer Use ([Codex app connectors and Computer Use](docs/codex.md)).
  - **Pi `1.5.0`** (`packages/pi.nix`, `home/h82/agents/pi.nix`) with `pi-acp` and `acpx`, locked to the Synthetic catalog (`home/h82/agents/pi-model-lock.json` and `home/h82/agents/pi-policy.ts`) and authenticated from `synthetic_api_key` in `secrets/tokens.yaml`. Every Synthetic model the repository uses is tracked in `home/h82/agents/synthetic-models.nix` and checked every 30 minutes against Synthetic's live catalog (`.github/workflows/update-dependencies.yml`).
  - **Grok Build `1.0.77`** (`packages/grok-build.nix`, `home/h82/agents/grok.nix`), with auto-update and Claude/Cursor compatibility disabled so shared skills load once.
  - **Antigravity CLI (`agy`)** and the **Antigravity ACP runtime** (`packages/antigravity-cli.nix`, `packages/antigravity-acp.nix`, `home/h82/agents/gemini.nix`).
  - **Shared plugins, skills, and tools**: Compound Engineering (`v3.36.1`) is registered, installed, and enabled at user scope for every managed harness (`home/h82/agents/agent-plugins.nix`, `home/h82/agents/pi.nix`). Each harness discovers the Korean writing skills (`humanizer`, `grammar-checker`, `style-guide` from `home/h82/agents/korean-skills.nix`), the pinned design/stack skills (`home/h82/agents/pinned-skills.nix`), `design-lenses`, `ux-flows`, and `test-audit` once through its native skill root (`home/h82/agents/skills.nix`). `fff-mcp`, TanStack `intent`, `agent-usage`, and `tokscale` are on `PATH`.
  - **Retired tools**: Oh My Pi and Orca are no longer managed or installed; existing user state on disk is left untouched (`modules/darwin/retired-casks.nix` removes only the retired `grok-bot` and `orca` Homebrew casks without `--zap`).
- **Toolchains and SDKs**: `.NET` 8 and 10 SDKs (`home/h82/dev/dotnet.nix`), Rust via `rustup` (`home/h82/dev/rust.nix`), Clang/LLVM, CMake, Ninja, and `vcpkg` (`home/h82/dev/cpp.nix`), Bun (`packages/bun.nix`), Swift (`swiftformat` and `swiftlint`, plus Xcode via `xcodes` on macOS), VSCodium (`home/h82/dev/vscodium.nix`), and the pinned Android SDK (`packages/android-sdk.nix`) with declarative mobile simulators/AVDs (`home/h82/dev/mobile-devices.nix`).
- **Containers and Kubernetes**:
  - **NixOS (`MS-7D91`)**: rootless Podman (`modules/nixos/services/podman.nix`) and a rootless `minikube` service (`modules/nixos/services/minikube.nix`), plus `kubectl`, `kubernetes-helm`, `k9s`, and `minikube`.
  - **macOS (`MacBook-Pro-Mac17-9`)**: Apple's `container` CLI (`modules/darwin/container.nix`), with `kubectl`, `kubernetes-helm`, and `minikube` as clients only (no Podman machine and no automatic `minikube` cluster).

## Installation and operation

- [Fresh installation (NixOS)](docs/install.md): back up, verify disk IDs, partition with `disko`, install `MS-7D91-bootstrap`, recover the age identity, enroll Secure Boot and TPM2, and switch to `MS-7D91`.
- [macOS hosts](docs/macos.md): back up, reinstall macOS, install Nix, apply `MacBook-Pro-Mac17-9-bootstrap`, recover the user age identity, and switch to `MacBook-Pro-Mac17-9`.
- [Updates and recovery](docs/recovery.md): routine switches, rollbacks, LUKS and Secure Boot backup/repair from installation media, YubiKey replacement, desktop SSH key recovery/rotation, host decommission, and iPhone/iPad IPSW restore.
- [Microsoft Intune on NixOS](docs/intune.md): what `my.intune.enable` installs, how to enroll `MS-7D91`, and what to do when a compliance check fails.
- [Adding a host](docs/adding-a-host.md): create a NixOS or macOS host directory, its bootstrap age material, per-host secrets, and `.sops.yaml` rules.
- [Agent routing](docs/agent-routing.md): T3 delegation policy, CE model-selection ladder, and launch-time instruction composition.
- [Shell configuration](docs/shell.md): Prezto parity, automatic updates, and migration of existing startup files.
- [Codex app connectors and Computer Use](docs/codex.md): how Codex app connectors and Computer Use are disabled.
- [Secret file conventions](secrets/README.md): sops/age layout, recipient rules, and recovery pipelines.

Each `<host>-bootstrap` output can be evaluated, built, and installed without private keys or tokens. Production `<host>` outputs also evaluate and build without plaintext secrets; activating them requires the host's recovered age identity and the encrypted files in `secrets/`.

## Development checks and CI

```sh
nix fmt -- --ci
nix flake check
nix build --no-link .#vmChecks.all  # NixOS VM tests; requires Linux with /dev/kvm
nix eval .#nixosConfigurations --apply builtins.attrNames
for host in $(nix eval --raw .#nixosConfigurations --apply 'c: toString (builtins.attrNames c)'); do
  nix build --no-link ".#nixosConfigurations.$host.config.system.build.toplevel"
done
nix eval .#darwinConfigurations --apply builtins.attrNames
for host in $(nix eval --raw .#darwinConfigurations --apply 'c: toString (builtins.attrNames c)'); do
  nix build --no-link ".#darwinConfigurations.$host.system"  # macOS builder only
done
```

### Continuous integration (`.github/workflows/check.yml`)

- **Every pull request** runs `fmt` (`nix fmt -- --ci`), path classification (`changes` via `scripts/ci-docs-only-paths`), `markdown-lint` (standalone on docs-only pull requests), `flake-check` (`nix flake check --no-build`), and the `light-*` shards of `checkShards` (`tests/check-shards.nix`).
- **Heavy closure builds** — `host-checks` (`.#checkShards.hosts`), `vm-checks` (`.#vmChecks.*`), `build` (`.#nixosConfigurations.<host>.config.system.build.toplevel`), and `build-darwin` (`.#darwinConfigurations.<host>.system` and `.#checks.aarch64-darwin.*` on `macos-26`) — run only on a push to `main`, a manual `workflow_dispatch`, or a pull request carrying the `full-ci` label.

### Scheduled maintenance (`.github/workflows/update-dependencies.yml`)

One workflow runs dependency updates, Synthetic catalog refreshes, and drift reporting every 30 minutes, at :07 and :37. Manual dispatch selects `all` (the default), `dependencies`, `catalogs`, or `drift`.

Catalog changes publish first, followed by dependency changes through the same verification and push helper. A failure in one part does not stop the other selected parts. Changed candidates pass their applicable checks before publication and again after a rebase onto changed `main`; unchanged candidates skip heavy verification. Dependency failures retain reconciliation PRs, and drift reporting retains its issue lifecycle without repeated writes for unchanged results. The separate drift job holds no push token.

This workflow replaces `model-catalogs.yml` and `synthetic-models.yml`; external dispatch callers should use the new selection input. The merged `update-dependencies-reconcile` check owns updater, publication, selection, and drift lifecycle coverage, including guard-removal mutations.

Installation, disk partitioning, key enrollment, and host switches are manual owner operations. Never run `disko`, `nixos-install`, `nixos-rebuild switch`, or `nr switch` on a host as a validation step.
