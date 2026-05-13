# scripts/

Bootstrap helpers plus manual auth, package, and system setup scripts.

## Layout

| Directory | Purpose |
|---|---|
| `scripts/auth/` | Manual authentication helpers and CLI auth configuration shared by bootstrap |
| `scripts/bootstrap/` | Cross-platform helpers invoked by dotbot bootstrap steps |
| `scripts/linux/` | Linux-only system, package, and desktop setup helpers |

## Current scripts

| Script | Platform | Called by | Purpose |
|---|---|---|---|
| `auth/auth-gh.sh` / `auth/auth-gh.ps1` | macOS+Linux / Windows | Manual | Starts GitHub CLI web login for `github.com`, preferring system `gh` and falling back to `mise exec gh@latest -- gh` |
| `auth/auth-glab.sh` / `auth/auth-glab.ps1` | macOS+Linux / Windows | Manual | Starts GitLab CLI web login for `git.jpi.app` and `gitlab.com`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `auth/auth-tailscale.sh` | Linux only | Manual | Runs `tailscale up --operator "$USER" --accept-routes`, using `sudo` when not already root. Single-platform by design because it targets the Linux Tailscale service configured by `scripts/linux/install-packages.sh` |
| `auth/setup-glab.sh` / `auth/setup-glab.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Configures the `git.jpi.app` GitLab OAuth client ID for `glab`, preferring system `glab` and falling back to `mise exec glab@latest -- glab` |
| `auth/import-gpg-keys.sh` / `auth/import-gpg-keys.ps1` | macOS+Linux / Windows | Manual | Reads the private GPG key from 1Password via `op read` and imports it with `gpg --batch --import` |
| `bootstrap/inject-1password-secrets.sh` / `bootstrap/inject-1password-secrets.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Finds every `*.1password` template in the repo, renders it with `op inject`, and writes it under `~/.secrets/<file-name-without-.1password>`; no-ops when no templates exist; secret files are mode `0600` on Unix, and secret directories are owner-only/traversable (`0700`) so the files remain readable by the owner |
| `bootstrap/install-fonts.sh` / `bootstrap/install-fonts.ps1` | macOS+Linux / Windows | `install.<os>.yaml` `shell:` step (also runnable manually) | Installs desktop fonts user-wide from GitHub Releases. Skips already-installed fonts unless `--force` / `-Force`. Add fonts via the registry block at the top of each script |
| `bootstrap/render-opencode-prompt-append.sh` / `bootstrap/render-opencode-prompt-append.ps1` | macOS+Linux / Windows | `install.conf.yaml` `shell:` step (also runnable manually) | Uses mise-managed Node.js to render `home/.config/opencode/prompts/*_prompt_append.md` into the matching `prompt_append` values in `home/.config/opencode/oh-my-openagent.jsonc`; shared logic lives in `bootstrap/render-opencode-prompt-append.mjs` |
| `linux/install-linux-system-config.sh` | Linux only | `install.linux.yaml` `shell:` step | Recursively discovers files in `system/linux/etc/` and runs `sudo install -D -m 644` to their absolute paths. The `etc/sudoers.d/*` subtree is special-cased: installed at mode `0440` and only on virtual machines (gated on `systemd-detect-virt --vm`); contents are syntax-checked with `visudo -c -f` before install |
| `linux/install-packages.sh` | Linux only (Fedora-oriented) | Manual | Enables Fedora third-party repos, keyd and mise COPRs, RPM Fusion, 1Password, VS Code, Docker, and Tailscale repos; installs development tools plus CLI, fcitx5, keyd, .NET, mise, Solaar, 1Password, VS Code, Docker, Chrome, and Tailscale packages; adds Steam/Discord only on bare metal; installs selected dotnet global tools; enables `keyd`, `docker`, and `tailscaled`; adds the user to `docker` and `keyd` groups |
| `linux/config-kde.sh` | Linux only (KDE Plasma 6) | `install.linux.yaml` `shell:` step (also runnable manually) | Configures KDE Plasma 6 user-side settings for fonts, touchpad, panel grouping, Kickoff list view, and Fcitx virtual keyboard. Requires fonts from `bootstrap/install-fonts.sh` and skips cleanly when a suitable KDE session is not available |

## Conventions

- Scripts that apply to macOS/Linux and Windows ship in `.sh` and `.ps1` pairs with equivalent behavior.
- Single-platform scripts are allowed only when the platform dependency is intrinsic; note that reason in the script header and in this README.
- Bootstrap-invoked paths in `install.conf.yaml` and `install.<os>.yaml` must stay in sync with this directory layout.
