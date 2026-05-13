# home/

Files in this directory install into `$HOME` via dotbot links or helper scripts. Most paths mirror `$HOME` exactly (`home/.config/git/config` → `~/.config/git/config`); `home/.secrets/*.1password` files are templates rendered by the 1Password helper rather than linked directly.

| Source in repo | Installed target / behavior |
|---|---|
| `home/.z*` | `~/.z*` on Linux and macOS |
| `home/.config/git/config` | `~/.config/git/config` |
| `home/.gitconfig.d/<os>.gitconfig` | `~/.gitconfig.d/<os>.gitconfig` from the matching OS yaml |
| `home/.agents/` | `~/.agents/` |
| `home/.config/opencode/` | `~/.config/opencode/` |
| `home/.config/Code/User/*.json` | VS Code user settings/keybindings at the platform-specific Code user path |
| `home/.config/environment.d/` | `~/.config/environment.d/` |
| `home/.config/fcitx5/`, `home/.config/containers/`, `home/.config/solaar/` | Linux-only XDG config via `install.linux.yaml` |
| `home/.config/zed/` | `~/.config/zed/` |
| `home/.gnupg/*.conf` | `~/.gnupg/*.conf` on Linux and macOS |
| `home/.ssh/config` | `~/.ssh/config` |
| `home/.docker/config.json` | `~/.docker/config.json` |
| `home/.npmrc`, `home/.yarnrc.yml` | Cross-platform package-manager hardening config |
| `home/.config/pnpm/config.yaml` | Linux package-manager hardening config via the XDG config glob |
| `home/.bunfig.toml` | Tracked Bun hardening config source; not linked by the current install yaml |
| `home/.local/bin/docker-credential-*`, `home/.local/bin/opencode*` | CLI helpers under `~/.local/bin/` for the platforms that use them |
| `home/.local/share/applications/*.desktop` | Linux desktop entries under `~/.local/share/applications/` |
| `home/.secrets/*.1password` | Rendered by `scripts/bootstrap/inject-1password-secrets.*` to `~/.secrets/<name>` |

## Conventions

- **Cross-platform files** are linked from [`../install.conf.yaml`](../install.conf.yaml), which also runs `mise install`.
- **OS-specific files** are linked from [`../install.linux.yaml`](../install.linux.yaml), [`../install.macos.yaml`](../install.macos.yaml), or [`../install.windows.yaml`](../install.windows.yaml).
- The location of the file inside `home/` does NOT determine which OS gets it — the `link:` block in the matching yaml does. You can place a Linux-only file under `home/.config/foo/` and only link it from `install.linux.yaml`.
- Use forward slashes in YAML paths even for Windows targets (e.g. `~/AppData/...`).
- Linux-only desktop, container, `environment.d`, editor, and SSH snippets live under their mirrored `home/` paths and are linked only from `install.linux.yaml`; that installer also prunes retired `environment.d` symlinks before relinking.
- `home/.agents/` is linked as a runtime skill tree. Its lockfile and skill package directories are managed by OpenCode / oh-my-openagent, not by hand. Do not place `AGENTS.md` inside `home/.agents/`; keep that guidance in [`AGENTS.md`](./AGENTS.md) at this directory level.
- `home/.config/opencode/` is linked recursively for OpenCode config. Do not place `AGENTS.md` inside it — `~/.config/opencode/AGENTS.md` is already an explicit symlink to [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md) (managed by [`../install.conf.yaml`](../install.conf.yaml)). Edit the shared file to change cross-tool agent rules.

## Don't put here

- Rendered secrets — keep only `*.1password` templates here. The generated `~/.secrets/*` files are local machine output and MUST NOT be committed.
- Generated files (caches, lock files for shells, etc.) — link the *config* that produces them, not the output.
- Runtime-managed skill package contents under `home/.agents/skills/`, unless updating through the skill manager.
- `home/.agents/AGENTS.md` — it would be linked into `~/.agents` and can affect every agent run from this user account.
- `home/.config/opencode/AGENTS.md` — it would conflict with the explicit symlink that points `~/.config/opencode/AGENTS.md` at [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md). Edit the shared file instead.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
