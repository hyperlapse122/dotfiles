# dotfiles

Personal environment configuration for Windows, Linux, and macOS.
Worktree preparation and applying personal settings are separate operations.
See [STRATEGY.md](STRATEGY.md) for the repository's scope and design boundaries.

Detailed documentation is organized under [docs/](docs/README.md).

## Quick Start

### 1. New Windows PC Bootstrap

On a clean Windows 10/11 machine, enable **Developer Mode** in **Settings > For developers** (`start ms-settings:developers`), then open Windows PowerShell (5.1+) and run:

```powershell
$bootstrap = Join-Path $env:TEMP 'dotfiles-bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/hyperlapse122/dotfiles/main/bootstrap.ps1' -OutFile $bootstrap
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap
```

This checks Developer Mode before making changes, installs missing Git, mise, and chezmoi via WinGet, clones this repository to `~/src/github.com/hyperlapse122/dotfiles`, and initializes the worktree. Bootstrap stops if Developer Mode is disabled or its enabled state cannot be confirmed; it never enables the setting automatically.

After bootstrap completes, open a fresh PowerShell window and register the permanent checkout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\src\github.com\hyperlapse122\dotfiles\configure-chezmoi.ps1"
```

For custom destinations, host application lists, and build toolchains, see the [Windows Setup Guide](docs/setup/windows.md).

### 2. New Apple Silicon Mac

Follow the [macOS Setup and Readiness Guide](docs/setup/macos.md) to install native prerequisites, prepare the permanent checkout with `bootstrap.sh`, register it separately with `configure-chezmoi.sh`, and explicitly apply the environment.
The supported baseline is macOS 15 or later on native Apple Silicon.
The guide covers all managed harnesses, applications, credentials, local containers and native Rust/C++/.NET builds, with separate manual and runtime readiness checks.

### 3. Worktree Preparation (Any OS)

To prepare a fresh git worktree or existing checkout for development without modifying personal settings:

```sh
mise trust
mise install
```

This installs locked development tools and runs read-only source verification via the project `postinstall` hook.

### 4. Apply Personal Settings

To apply managed configuration and personal applications to your actual user home directory:

```sh
mise run apply
```

To preview pending changes before applying:

```sh
mise exec -- chezmoi --source . diff
```

## Common Commands

| Command | Purpose |
|---|---|
| `chezmoi apply` | Apply configuration from the registered permanent checkout to user home |
| `chezmoi update` | Pull latest commits, regenerate configuration, and apply updates |
| `mise run apply` | Apply settings directly from the current repository worktree |
| `mise exec -- chezmoi --source . diff` | Inspect rendered file diffs against destination files |
| `mise run windows-build` | Provision or update Windows native development toolchains (C++, .NET, Rust) |
| `mise run macos-build` | Explicitly provision native Apple Silicon C++/.NET/Rust build tools |
| `mise exec -- python scripts/macos-readiness.py` | Inspect macOS local prerequisites and pending manual/runtime checks |
| `mise exec -- python -m unittest discover -s tests` | Run the repository test suite |

## Documentation

Comprehensive guides are organized in [docs/](docs/README.md):

### Setup
- **[macOS Setup and Readiness](docs/setup/macos.md):** Native prerequisites, source registration, managed apps/harnesses, Podman, native builds, and a complete readiness checklist.
- **[Windows Setup and Bootstrap](docs/setup/windows.md):** Automated PC bootstrap, chezmoi source registration, WinGet host applications, virtualization preflight, build environments, and Podman / Kubernetes onboarding.

### User Guides

- **[Git and GPG Configuration](docs/guides/git-and-gpg.md):** Identity, automatic commit signing, pinentry selection, GPG home safety guards, and `ghq` repository cloning.
- **[Secrets and API Authentication](docs/guides/secrets-and-authentication.md):** Encrypted token source, GitHub and GitLab PAT imports, native OS keyrings, and Git HTTPS credentials.
- **[Personal CLI Applications](docs/guides/personal-applications.md):** Installation of Claude Code, Codex, `omp`, `gh`, `ghq`, and `glab` under `~/.local/bin`, shell PATH activation, pin updates, and PowerShell mise activation.
- **[T3 Code Desktop and Harness Integration](docs/guides/t3-code.md):** Desktop editor installation, command-line launchers, native Claude Code and Codex integration, and oh-my-pi Agent Control Protocol configuration.
- **[Harness Plugins](docs/guides/harness-plugins.md):** Compound Engineering for Claude Code, Codex, and omp, pinned local marketplaces, update controls, and shared agent instructions.
- **[Native System CA Trust](docs/guides/system-ca.md):** Enterprise root certificate trust via `NODE_USE_SYSTEM_CA=1`, runtime support matrix, and platform activation.

### Maintenance
- **[Chezmoi Source Maintenance](docs/maintenance/chezmoi-source.md):** Directory layout (`home/`), script lifecycle phases, dependency signatures, modify templates, and harness onboarding.
- **[Development, Testing, and CI](docs/maintenance/development-and-testing.md):** Worktree initialization, test suite architecture, standalone smoke tests, and CI runner policies.
