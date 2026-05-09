# home/

Files in this directory symlink into `$HOME` via dotbot. The path layout under `home/` mirrors `$HOME` exactly:

| Source in repo | Symlink target |
|---|---|
| `home/.config/git/config` | `~/.config/git/config` |
| `home/.agents/` | `~/.agents/` |
| `home/.config/opencode/` | `~/.config/opencode/` |
| `home/.config/environment.d/` | `~/.config/environment.d/` |
| `home/.config/zed/` | `~/.config/zed/` |
| `home/.local/bin/`                | `~/.local/bin/`                |

## Conventions

- **Cross-platform files** are linked from [`../install.conf.yaml`](../install.conf.yaml).
- **OS-specific files** are linked from [`../install.linux.yaml`](../install.linux.yaml), [`../install.macos.yaml`](../install.macos.yaml), or [`../install.windows.yaml`](../install.windows.yaml).
- The location of the file inside `home/` does NOT determine which OS gets it — the `link:` block in the matching yaml does. You can place a Linux-only file under `home/.config/foo/` and only link it from `install.linux.yaml`.
- Use forward slashes in YAML paths even for Windows targets (e.g. `~/AppData/...`).
- Linux-only desktop, container, `environment.d`, editor, and SSH snippets live under their mirrored `home/` paths and are linked only from `install.linux.yaml`.
- `home/.agents/` is linked as a runtime skill tree. Its lockfile and skill package directories are managed by OpenCode / oh-my-openagent, not by hand. Do not place `AGENTS.md` inside `home/.agents/`; keep that guidance in [`AGENTS.md`](./AGENTS.md) at this directory level.
- `home/.config/opencode/` is linked recursively for OpenCode config. Do not place `AGENTS.md` inside it — `~/.config/opencode/AGENTS.md` is already an explicit symlink to [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md) (managed by [`../install.conf.yaml`](../install.conf.yaml)). Edit the shared file to change cross-tool agent rules.

## Don't put here

- Files with secrets — use a separate private repo or a secrets plugin (out of scope for this repo today).
- Generated files (caches, lock files for shells, etc.) — link the *config* that produces them, not the output.
- Runtime-managed skill package contents under `home/.agents/skills/`, unless updating through the skill manager.
- `home/.agents/AGENTS.md` — it would be linked into `~/.agents` and can affect every agent run from this user account.
- `home/.config/opencode/AGENTS.md` — it would conflict with the explicit symlink that points `~/.config/opencode/AGENTS.md` at [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md). Edit the shared file instead.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
