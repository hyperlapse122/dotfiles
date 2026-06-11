# chezmoi migration map

Historical reference for the migration from the old symlink-based layout to the
current chezmoi model. Useful context when reading old commits or understanding
why certain paths are named the way they are.

---

## Old model vs new model

| Concern | Old (symlink-based) | New (chezmoi) |
|---|---|---|
| Dotfile delivery | `ln -s` via `link:` blocks in `install.conf.yaml` / `install.<os>.yaml` | `mise exec chezmoi@2.70.5 -- chezmoi apply` reads `home/` as source root |
| Source root | `home/` with leading-dot names (`home/.config/`, `home/.ssh/`) | `home/` with chezmoi-encoded names (`home/dot_config/`, `home/private_dot_ssh/`) |
| Per-OS gating | Separate `install.<os>.yaml` files with per-OS `link:` blocks | `.chezmoiignore.tmpl` gates target paths on `.chezmoi.os` (`linux`, `darwin`, `windows`) |
| File modes | Symlinks inherit source permissions; no encoding | `private_` prefix = 0600 files / 0700 dirs; `executable_` prefix = Unix execute bit |
| Live symlinks (agents, plugins) | Managed by `link:` blocks in `install.conf.yaml` | Created by `scripts/bootstrap/link-repo-trees.sh` after `chezmoi apply` |
| Root-owned `/etc/` files | Called from `shell:` steps in `install.<os>.yaml` | Called directly by `install.sh` / `install.ps1` (same scripts, different caller) |
| Codex `hooks.json` | `link:` block in `install.linux.yaml` / `install.macos.yaml` | Symlink created by `scripts/bootstrap/link-repo-trees.sh` |
| Codex `config.toml` | Rendered by `configure-codex-config.mjs` via `shell:` step | Same renderer, now called directly by `install.sh` / `install.ps1` |
| CI link guard | `scripts/ci/check-dotbot-links.mjs` (verified `link:` sources) | `scripts/ci/check-chezmoi-apply.sh` (runs `chezmoi apply --dry-run`) |

---

## Path-mapping table

chezmoi encodes dotfile names by replacing the leading `.` with `dot_`. Directories
that need restricted permissions get `private_` prepended. Files that need the
Unix execute bit get `executable_` prepended. Non-dot directories (`Library`,
`AppData`, `zsh`, `Code`) get no prefix.

| Target path (`$HOME/...`) | Source path (`home/...`) | Notes |
|---|---|---|
| `.config/` | `dot_config/` | General XDG config |
| `.config/git/` | `dot_config/git/` | Git config |
| `.config/opencode/` | `dot_config/opencode/` | OpenCode JSON configs only |
| `.config/zsh/` | `dot_config/zsh/` | Zsh config (Prezto-based) |
| `.config/systemd/user/` | `dot_config/systemd/user/` | User systemd units (Linux) |
| `.gitconfig` | `dot_gitconfig` | Root gitconfig |
| `.gitconfig.d/` | `dot_gitconfig.d/` | Per-OS gitconfig fragments |
| `.ssh/` | `private_dot_ssh/` | 0700 dir; `config` is `private_config` (0600) |
| `.gnupg/` | `private_dot_gnupg/` | 0700 dir; key files are `private_*` |
| `.npmrc` | `private_dot_npmrc` | 0600 — contains auth tokens |
| `.yarnrc.yml` | `private_dot_yarnrc.yml` | 0600 — contains auth tokens |
| `.local/bin/<launcher>` | `dot_local/bin/executable_<launcher>` | Execute bit for shell launchers |
| `.secrets/` | `dot_secrets/` | Rendered from `*.1password` templates |
| `Library/` | `Library/` | macOS only; no prefix (non-dot dir) |
| `Library/LaunchAgents/` | `Library/LaunchAgents/` | macOS launchd agents |
| `AppData/Roaming/` | `AppData/Roaming/` | Windows only; no prefix |

### Per-OS ignore gates (`.chezmoiignore.tmpl`)

chezmoi has no destination-path templating, so per-OS differences use ignore gates
on **target paths** (relative to `$HOME`), not source paths:

```
# Linux only
{{ if ne .chezmoi.os "linux" }}
.gitconfig.d/linux.gitconfig
.config/Code
.config/VSCodium
{{ end }}

# macOS only
{{ if ne .chezmoi.os "darwin" }}
Library/Application Support/Code
Library/Application Support/VSCodium
Library/LaunchAgents/dev.h82.mxm4-hapticd.plist
{{ end }}

# Windows only
{{ if ne .chezmoi.os "windows" }}
AppData/Roaming/Code
AppData/Roaming/VSCodium
{{ end }}
```

`.chezmoi.os` returns lowercase: `linux`, `darwin`, `windows`.

---

## Orchestrator ordering

`install.sh` / `install.ps1` run steps in this order:

1. **Verify mise** — abort if `mise` is not on PATH (users install it themselves).
2. **Toolchain provision** — `mise install` from the tracked `mise.toml`.
3. **Remove old symlinks** — `scripts/bootstrap/remove-dotbot-symlinks.sh` (or `.ps1`) cleans up any leftover symlinks from the old layout that would conflict with chezmoi-managed files.
4. **glab skills** — `mise exec glab -- glab skills install` (Linux + macOS).
5. **Render prompts** — `scripts/bootstrap/render-opencode-prompt-append.sh` (or `.ps1`) renders `home/dot_config/opencode/prompts/*_prompt_append.md` into the OpenCode config.
6. **chezmoi apply** — `mise exec chezmoi@2.70.5 -- chezmoi apply` materialises all dotfiles from `home/` into `$HOME`.
7. **setup-glab** — `scripts/auth/setup-glab.sh` (or `.ps1`) configures the GitLab OAuth client ID.
8. **cargo build** — `cargo install` for crates in `crates/` into `~/.local/bin/`.
9. **yarn build** — `mise -C packages exec -- yarn build` builds the TypeScript workspace in place (Linux only).
10. **link-repo-trees** — `scripts/bootstrap/link-repo-trees.sh` (or `.ps1`) creates the live symlinks that must point into the repo rather than be chezmoi-managed copies: agent skills, shared commands, shared agent rules, skills lockfile, Codex hooks (Linux + macOS), and built OpenCode plugin entrypoints.
11. **configure-codex** — `scripts/bootstrap/configure-codex-config.sh` (or `.ps1`) merges shared Codex settings into `~/.codex/config.toml`.
12. **inject-secrets** — `scripts/bootstrap/inject-1password-secrets.sh` (or `.ps1`) renders `*.1password` templates into `~/.secrets/` (no-op when none exist).
13. **Linux-only block** — `scripts/linux/install-linux-system-config.sh` (root-owned `/etc/` files, firewalld, lingering), `scripts/linux/config-kde.sh` (KDE Plasma settings), and `systemctl --user enable` for user units.

---

## Ownership boundary

Two distinct mechanisms manage files in `$HOME`:

**chezmoi** owns content files — anything that should be a regular file at a
fixed path under `$HOME`. It reads `home/` as its source root (`.chezmoiroot =
home`), applies encoding rules (`dot_`, `private_`, `executable_`), and writes
the decoded files to `$HOME`. chezmoi is the authority for file content and
permissions.

**`link-repo-trees.sh`** owns live symlinks — paths that must resolve back into
the repo so that edits to the source are immediately visible without re-running
bootstrap. These are:

- `~/.agents/skills` → `agents/skills/`
- `~/.claude/skills` → `agents/skills/`
- `~/.config/opencode/commands` → `agents/commands/`
- `~/.config/opencode/AGENTS.md` → `agents/SHARED_AGENTS.md`
- `~/.codex/AGENTS.md` → `agents/SHARED_AGENTS.md`
- `~/.claude/CLAUDE.md` → `agents/SHARED_AGENTS.md`
- `~/.agents/.skill-lock.json` → `agents/.skill-lock.json`
- `~/.codex/hooks.json` → `codex/hooks.json` (Linux + macOS)
- `~/.config/opencode/plugins/mxm4-haptic.js` → `packages/opencode-mxm4-haptic/dist/index.mjs` (Linux)
- `~/.config/opencode/plugins/playwright-cli-session-injection.js` → `packages/opencode-playwright-cli-session-injection/dist/index.mjs`

chezmoi's `.chezmoiignore.tmpl` excludes all of these target paths so chezmoi
never overwrites a live symlink with a regular file.

---

## First-boot contract

The only prerequisite a user installs by hand is `mise`. Everything else flows
from there:

```
# 1. Install mise (user does this once, outside the repo)
# 2. Clone the repo
git clone https://github.com/hyperlapse122/dotfiles.git ~/dotfiles

# 3. Run bootstrap
./install.sh          # macOS + Linux
.\install.ps1         # Windows (pwsh)
```

`install.sh` / `install.ps1` are idempotent. Re-run after every `git pull`.

The canonical chezmoi invocation is always:

```sh
mise exec chezmoi@2.70.5 -- chezmoi apply
```

Never use an ambient `chezmoi` on PATH and never install chezmoi globally.
The version pin (`2.70.5`) lives in `install.sh` / `install.ps1` and must be
updated there when bumping chezmoi.
