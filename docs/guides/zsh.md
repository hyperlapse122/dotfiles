# Zsh and Prezto

Explicit chezmoi application configures Prezto for Linux AMD64/ARM64 and Apple Silicon macOS.
Install zsh through the platform setup first; changing the default login shell is a separate operation.

```sh
mise install
mise run apply
```

Open a new zsh session after application.
Worktree preparation (`mise install`) installs development tools and checks source state; it does not apply personal shell configuration.

## Configuration and startup

The active configuration directory is `${XDG_CONFIG_HOME:-$HOME/.config}/zsh`.
Its `.zprezto` link points to the checksum-pinned payload under `~/.local/share/dotfiles/zsh/prezto`.
Bundled theme dependencies are pinned because upstream prompt initialization registers those themes, and `sorin` needs the bundled async library.
`sorin` remains the selected theme.
Chezmoi manages staging beneath the home directory, and an apply hook publishes the startup blocks at the selected XDG path, including absolute paths outside home.
The shared external asset preparation hook stages Prezto and the locked ghq completion before zsh publication.
An unchanged apply reuses verified prepared assets; `mise run assets:verify` checks their full contents and repairs installed payloads.
Set `XDG_CONFIG_HOME` before applying when using a custom location; apply again after changing it.

The root `~/.zshenv` connects zsh discovery to that directory.
When application inherits an existing `ZDOTDIR`, it also connects that startup entry to the selected XDG directory.
Managed blocks preserve other startup text, and a conflicting unmanaged directory at a reserved payload link fails without deletion.

Interactive zsh loads the upstream default modules and `sorin` theme, plus autosuggestions and syntax highlighting.
Git and macOS Homebrew modules load when their commands are available.
GPG integration retains existing signing and pinentry configuration; Prezto agent management is skipped when SSH-agent support or cached SSH exports would interfere with the existing agent lifecycle.
Mise activates automatically in interactive sessions.
Noninteractive and nested zsh retain the native CA setting without loading interactive Prezto features.

## Official completions

Application publishes these supported completion definitions before Prezto initializes its completion system:

| Command | Official provider |
|---|---|
| `codex` | `codex completion zsh` |
| `omp` | `omp completions zsh` |
| `gh` | `gh completion -s zsh` |
| `glab` | `glab completion -s zsh` |
| `ghq` | `misc/zsh/_ghq` from the same locked release tag |
| `mise` | `mise completion zsh` |
| `usage` | `usage --completions zsh` |

Definitions are generated during each explicit application, with only changed successful output replacing existing files.
An empty or failed generator fails application and preserves the previous complete file.
Reapplying repairs missing completion files.
Successful application clears Prezto's completion dump so an existing cache cannot hide installed definitions.
Shell startup does not download or regenerate definitions.

Usage is declared and locked in mise, then exposed through a persistent executable link alongside the managed zsh environment.
It remains available outside the checkout for official Usage-backed completions.

## Updates and verification

Prezto and its required gitlink dependencies are pinned in `home/.chezmoidata/zsh-lock.json`.
Refresh them explicitly, review the lock diff, and apply:

```sh
mise exec gh python -- python scripts/update-zsh-lock.py
mise run apply
```

Personal command versions and the ghq completion checksum follow the existing [personal application lock](personal-applications.md#release-pin-architecture).
Restoring the desired committed locks and reapplying restores their selected payloads and completion definitions.
Usage follows `mise.toml` and `mise.lock`; do not install a second copy through the zsh hook.

The native smoke test uses temporary HOME, XDG, cache, configuration, and state directories:

```sh
mise exec chezmoi python usage -- python tests/smoke_zsh.py --expected-target linux-amd64
```

Use the host's eligible target (`linux-amd64`, `linux-arm64`, or `darwin-arm64`).
The existing native application CI jobs run this proof on Linux and macOS, including the actual pinned Prezto modules and official generators.
