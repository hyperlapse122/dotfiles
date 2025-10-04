This repository manages the author's personal dotfiles and a bundled copy of Dotbot. Keep guidance short, concrete, and focused on the files and workflows an AI coding agent will need to be productive immediately.

Principles
- Prefer small, idempotent changes: dotfiles installs are intended to be re-runnable (see `install.conf.yaml`).
- Make edits in place where user-facing config lives (top-level, e.g. `vscode/`, `zsh/`, `gnupg/`) unless the change is clearly tooling-level (then update under `dotbot/`).

Quick architecture & why
- Repo purpose: a single Git repo of dotfiles that uses Dotbot to apply links, create directories, and run shell steps. The `install` and `bootstrap.sh` scripts are small shims that call into `install.sh` and `dotbot`.
- Major pieces:
  - `install.sh` and `bootstrap.sh`: platform-aware entrypoints for installing the dotfiles.
  - `install.conf.yaml`: the primary Dotbot configuration that declares what gets linked/created.
  - `dotbot/`: vendored Dotbot implementation and plugins (author forks/contains `lib/pyyaml` and `src/dotbot`). Treat this as a third-party dependency unless editing dotbot behavior is required.
  - `vscode/`, `zsh/`, `gnupg/`, `brew/`, etc: the opinionated sets of configs that are symlinked into the user's home directory by Dotbot.

Developer workflows & useful commands
- Install locally (recommended): clone then bootstrap

  1) Clone then bootstrap:
     - `git clone --recursive <repo> ~/.dotfiles && cd ~/.dotfiles && ./bootstrap.sh`

 2) Re-run install after changes:
     - `cd ~/.dotfiles && ./install.sh`

- On macOS the `bootstrap.sh` and `install.sh` will also call `brew bundle --file="brew/Brewfile"`.
- Dotbot invocation: Dotbot reads `install.conf.yaml` by default. If running `dotbot` directly, use: `dotbot -c install.conf.yaml` or add `--plugin` paths to match repo usage.

Project-specific conventions and patterns
- Idempotency: `install.conf.yaml` uses `- defaults: link: relink: true` and many link entries with `create: true` and `force: true`. New directives should maintain idempotency (avoid destructive one-shot operations).
- Path conventions: paths in Dotbot config are relative to the repo base. Examples in `install.conf.yaml`:
  - `"~/.config/Code/User/settings.json": path: vscode/settings.json create: true force: true`
  - `vscode/` contains VS Code user settings and keybindings.
- Vendored libraries: a copy of `pyyaml` and Dotbot live under `dotbot/` and `dotbot/lib/pyyaml`. Prefer not to modify them unless fixing a bug; if you must, keep the change minimal and document why.

Integration points & external dependencies
- `mise` and `stow` are used by `install.sh`/`bootstrap.sh`. `mise` is expected to be available or installed by `install.sh`.
- Homebrew (macOS): `brew` is referenced and `brew/Brewfile` used during macOS installs.
- Git submodules: the repo may use submodules (Dotbot), so tests/actions should use `--recursive` when cloning.

Examples and patterns to follow when making changes
- Add a new symlinked config file:
  1) Add the file under an appropriate directory (e.g. `vscode/my-setting.json`).
  2) Add a mapping to `install.conf.yaml` under `- link:` with `path: vscode/my-setting.json` and `create: true` if parent dirs are required.
  3) Run `./install.sh` locally and verify the symlink is created in `~/.config/...`.

- Update vendored Dotbot behavior only when necessary: prefer to implement logic as a plugin under the repo and register it in `install.conf.yaml` rather than editing `dotbot/src/dotbot` directly.

Files to inspect for context (good starting points)
- `install.sh`, `bootstrap.sh` — installer entrypoints
- `install.conf.yaml` — Dotbot configuration
- `dotbot/README.md`, `dotbot/src/dotbot/` — Dotbot internals and plugins
- `vscode/`, `zsh/`, `gnupg/` — example configuration directories

When uncertain, do this first
- Reproduce locally: run `./install.sh` in a disposable environment or a temp directory to validate dotbot/link behavior.
- Look for `create: true`, `force: true`, `relink: true` in `install.conf.yaml` to understand how existing entries are intended to behave.

Tone and style for PRs
- Keep commits tiny and focused. Describe why a change is needed and any manual verification steps (e.g., `./install.sh` created X symlinks). If modifying vendored code, include tests or a clear rationale.

If anything in this file is unclear or you'd like more examples (for specific directories like `mise/` or `brew/`), tell me which area to expand.
