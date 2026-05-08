# home/

Files in this directory symlink into `$HOME` via dotbot. The path layout under `home/` mirrors `$HOME` exactly:

| Source in repo | Symlink target |
|---|---|
| `home/.gitconfig` | `~/.gitconfig` |
| `home/.config/nvim/init.lua` | `~/.config/nvim/init.lua` |
| `home/.agents/` | `~/.agents/` |
| `home/.config/environment.d/` | `~/.config/environment.d/` |
| `home/.config/zed/` | `~/.config/zed/` |
| `home/.local/share/applications/` | `~/.local/share/applications/` |
| `home/.local/bin/`                | `~/.local/bin/`                |

## Conventions

- **Cross-platform files** are linked from [`../install.conf.yaml`](../install.conf.yaml).
- **OS-specific files** are linked from [`../install.linux.yaml`](../install.linux.yaml), [`../install.macos.yaml`](../install.macos.yaml), or [`../install.windows.yaml`](../install.windows.yaml).
- The location of the file inside `home/` does NOT determine which OS gets it — the `link:` block in the matching yaml does. You can place a Linux-only file under `home/.config/foo/` and only link it from `install.linux.yaml`.
- Use forward slashes in YAML paths even for Windows targets (e.g. `~/AppData/...`).
- Linux-only desktop, container, `environment.d`, editor, and SSH snippets live under their mirrored `home/` paths and are linked only from `install.linux.yaml`.

## Don't put here

- Files with secrets — use a separate private repo or a secrets plugin (out of scope for this repo today).
- Generated files (caches, lock files for shells, etc.) — link the *config* that produces them, not the output.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
