# home/

This directory is the **chezmoi source root** (`home/` is set as the source via `.chezmoiroot` at the repo root). chezmoi applies files from here into `$HOME` using `mise exec chezmoi@2.70.5 -- chezmoi apply`.

---

## chezmoi source conventions

### Name encoding

chezmoi encodes file attributes in the source name. The rules this repo uses:

| Prefix | Meaning | Example source | Target |
|---|---|---|---|
| `dot_` | Replaces the leading `.` of a dotfile or dotdir | `dot_zshrc` | `~/.zshrc` |
| `private_` | Sets mode 0600 (file) or 0700 (dir) | `private_dot_ssh/` | `~/.ssh/` (mode 0700) |
| `executable_` | Sets Unix execute bit | `executable_opencode` | `~/.local/bin/opencode` |
| *(no prefix)* | Non-dot dirs — used as-is | `Library/` | `~/Library/` |

`dot_` replaces **only the leading dot** of each path component. A file like `home/dot_config/git/config` maps to `~/.config/git/config` — the inner `config` has no leading dot so it needs no prefix.

Private and executable prefixes compose: `home/private_dot_ssh/private_config` → `~/.ssh/config` at mode 0600.

Windows `.ps1` wrappers under `home/dot_local/bin/` are **not** marked `executable_` — Windows doesn't consume Unix execute bits.

### Per-OS gating

chezmoi cannot template destination paths, so files that live at different paths on different OSes need **separate source entries** gated by `.chezmoiignore.tmpl`.

`.chezmoiignore.tmpl` matches **target paths** (relative to `$HOME`), not source paths. The template variable is `.chezmoi.os`, which returns lowercase: `linux`, `darwin`, `windows`.

Example: VS Code settings exist as three separate source trees, each ignored on the other two OSes:

| Source tree | Target | Active on |
|---|---|---|
| `home/dot_config/Code/User/` | `~/.config/Code/User/` | Linux only |
| `home/Library/Application Support/Code/User/` | `~/Library/Application Support/Code/User/` | macOS only |
| `home/AppData/Roaming/Code/User/` | `~/AppData/Roaming/Code/User/` | Windows only |

The same three-tree pattern applies to VSCodium. `settings.json` and `keybindings.json` are kept in sync across all three trees — they should diff clean.

### `.chezmoiignore.tmpl` ownership boundary

`.chezmoiignore.tmpl` controls what chezmoi manages. It does **not** own the live symlinks that `scripts/bootstrap/link-repo-trees.sh` creates. Those targets are excluded from chezmoi's managed set entirely.

Live symlinks created by `link-repo-trees.sh` (NOT chezmoi):

| Symlink target | Points to |
|---|---|
| `~/.agents/skills` | `agents/skills/` in the repo |
| `~/.claude/skills` | `agents/skills/` in the repo |
| `~/.agents/.skill-lock.json` | `agents/.skill-lock.json` |
| `~/.config/opencode/AGENTS.md` | `agents/SHARED_AGENTS.md` |
| `~/.config/opencode/commands` | `agents/commands/` |
| `~/.codex/AGENTS.md` | `agents/SHARED_AGENTS.md` |
| `~/.codex/prompts` | `agents/commands/` |
| `~/.claude/CLAUDE.md` | `agents/SHARED_AGENTS.md` |
| `~/.config/opencode/plugins/mxm4-haptic.js` | built plugin dist (Linux only) |
| `~/.config/opencode/plugins/playwright-cli-session-injection.js` | built plugin dist |

Do not add chezmoi source entries for any of these paths — they must stay live symlinks so edits to the source under `agents/` propagate immediately without a `chezmoi apply`.

`~/.codex/hooks.json` is also a live symlink (to `codex/hooks.json`), managed by the install scripts directly.

---

## File reference

| Source in repo | Installed target / behavior |
|---|---|
| `home/dot_zshrc`, `home/dot_zprofile`, etc. | `~/.zshrc`, `~/.zprofile`, etc. on Linux and macOS |
| `home/dot_config/git/config` | `~/.config/git/config` |
| `home/dot_gitconfig.d/<os>.gitconfig` | `~/.gitconfig.d/<os>.gitconfig` — gated by `.chezmoiignore.tmpl` per OS |
| `home/dot_config/opencode/*.{json,jsonc}` | `~/.config/opencode/` (top-level OpenCode JSON config only) |
| `home/dot_config/opencode/prompts/*_prompt_append.md` | Prompt append sources rendered into `home/dot_config/opencode/oh-my-openagent.jsonc` by `scripts/bootstrap/render-opencode-prompt-append.*` — the `prompts/` dir is not a chezmoi target |
| `home/dot_config/Code/User/*.json` | `~/.config/Code/User/` on Linux |
| `home/Library/Application Support/Code/User/*.json` | `~/Library/Application Support/Code/User/` on macOS |
| `home/AppData/Roaming/Code/User/*.json` | `~/AppData/Roaming/Code/User/` on Windows |
| `home/dot_config/VSCodium/User/*.json` | `~/.config/VSCodium/User/` on Linux |
| `home/Library/Application Support/VSCodium/User/*.json` | `~/Library/Application Support/VSCodium/User/` on macOS |
| `home/AppData/Roaming/VSCodium/User/*.json` | `~/AppData/Roaming/VSCodium/User/` on Windows |
| `home/dot_config/environment.d/` | `~/.config/environment.d/` — Linux only; includes `65-containers.conf` (routes Docker-API clients through the rootless `podman.socket`) and Testcontainers Ryuk privilege vars |
| `home/dot_config/fcitx5/`, `home/dot_config/containers/`, `home/dot_config/solaar/` | Linux-only XDG config |
| `home/dot_config/chromium/External Extensions/<id>.json` | `~/.config/chromium/External Extensions/<id>.json` on Linux. Chromium auto-installs each referenced extension on startup (user-scope, no root). Only `*.json` files are read; the tracked `README.md` and `*.json.example` template are ignored |
| `home/dot_config/wireplumber/wireplumber.conf.d/*.conf` | Linux-only WirePlumber 0.5 drop-ins; currently `51-disable-bt-autoswitch.conf` (keeps Bluetooth headsets in A2DP, not HFP) |
| `home/dot_config/zed/` | `~/.config/zed/` |
| `home/private_dot_gnupg/*.conf` | `~/.gnupg/*.conf` on Linux and macOS |
| `home/private_dot_ssh/private_config` | `~/.ssh/config` at mode 0600 |
| `home/dot_npmrc`, `home/dot_yarnrc.yml` | Cross-platform package-manager hardening config |
| `home/dot_config/pnpm/config.yaml` | Linux package-manager hardening config |
| `home/dot_bunfig.toml` | Bun hardening config |
| `home/dot_local/bin/executable_opencode`, `home/dot_local/bin/opencode.ps1` | `mise exec` wrapper that resolves the latest opencode release via `gh release download` and falls back to the unpinned backend |
| `home/dot_local/bin/executable_code`, `home/dot_local/bin/code.ps1` | VS Codium shim so `code` keeps working after the VS Code → VS Codium migration |
| `home/dot_local/share/applications/*.desktop` | Linux desktop entries under `~/.local/share/applications/` |
| `home/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist` | macOS launchd agent for the MX Master 4 haptic daemon — gated to darwin in `.chezmoiignore.tmpl` |
| `home/dot_secrets/*.1password` | Rendered by `scripts/bootstrap/inject-1password-secrets.*` to `~/.secrets/<name>` — not applied by chezmoi directly |

---

## Adding a new dotfile

1. Create the source file under `home/` using chezmoi name encoding:
   - `home/dot_<name>` for a dotfile at `~/.<name>`
   - `home/dot_config/<name>` for `~/.config/<name>`
   - Add `private_` prefix for files that should be mode 0600
   - Add `executable_` prefix for scripts that need the execute bit
2. If the file is OS-specific, add a target-path ignore gate in `home/.chezmoiignore.tmpl`.
3. Run `mise exec chezmoi@2.70.5 -- chezmoi apply` to apply it.

---

## Post-migration: container registry auth

After the Docker → Podman migration, registry credentials for `ghcr.io`, `docker.io`, and `registry.jpi.app` no longer exist on disk. Re-establish them manually on each machine with `podman login <registry>`; podman stores credentials in `~/.config/containers/auth.json`, which is machine-local and not tracked here.

---

## Conventions

- The location of a file inside `home/` determines its target path under `$HOME` — chezmoi derives the target from the source path after stripping name-encoding prefixes.
- OS gating is done via `.chezmoiignore.tmpl`, not by which install script links a file. A Linux-only file lives under its natural `home/dot_config/foo/` path and is excluded on other OSes by an ignore rule.
- `home/dot_config/opencode/` holds only top-level `*.json`/`*.jsonc` OpenCode config. Do not place `AGENTS.md` or a `commands/` subdir here — those are live symlinks managed by `link-repo-trees.sh`.
- OpenCode agent prompt append text lives in `home/dot_config/opencode/prompts/*_prompt_append.md`; run `scripts/bootstrap/render-opencode-prompt-append.*` to render those sources into `home/dot_config/opencode/oh-my-openagent.jsonc`. The `prompts/` directory is not a chezmoi target.
- The runtime skill tree is **not** under `home/` — it lives in [`../agents/skills`](../agents/skills) (with [`../agents/.skill-lock.json`](../agents/.skill-lock.json)), linked into `~/.agents/skills` and `~/.claude/skills`. See [`../agents/README.md`](../agents/README.md).

---

## Don't put here

- Rendered secrets — keep only `*.1password` templates here. The generated `~/.secrets/*` files are local machine output and MUST NOT be committed.
- Generated files (caches, lock files for shells, etc.) — track the config that produces them, not the output.
- A `home/dot_agents/` skill tree — it lives in [`../agents/skills`](../agents/skills); don't reintroduce it here.
- `home/dot_config/opencode/AGENTS.md` — conflicts with the live symlink at `~/.config/opencode/AGENTS.md`. Edit [`../agents/SHARED_AGENTS.md`](../agents/SHARED_AGENTS.md) instead.
- `home/dot_config/opencode/commands/` — conflicts with the live symlink at `~/.config/opencode/commands`. Put new slash commands in [`../agents/commands/`](../agents/commands/) instead.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
