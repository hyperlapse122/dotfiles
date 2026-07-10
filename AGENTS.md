# AGENTS.md

chezmoi-managed dotfiles. Primary Linux targets: **Fedora Linux** and **Ubuntu Studio 26.04** (KDE Plasma 6); macOS (`Library/`,
`darwin` template branches, `dot_default-gems.tmpl`) and Windows (`*.ps1`,
`windows` branches) are secondary. Remote: `github.com/hyperlapse122/dotfiles` (`main`).

## This repo is chezmoi *source state* — never edit `$HOME` directly

Files here are the source; chezmoi renders them into `$HOME`. Editing a deployed
file (e.g. `~/.config/mise/config.toml`, `~/.npmrc`) is wrong — the next
`chezmoi apply` overwrites it. Edit the matching source file here, then apply.

Source filename attributes encode the target:

| Source | Becomes |
|---|---|
| `dot_foo` | `~/.foo` |
| `*.tmpl` | Go-template, rendered at apply time |
| `private_` | mode 0600 |
| `readonly_` | mode 0444 |
| `executable_` | `+x` |
| `.chezmoiscripts/run_once_*` | runs once, ever |
| `.chezmoiscripts/run_onchange_*` | re-runs whenever its rendered content changes |
| `.chezmoiscripts/run_after_*` | re-runs on every `chezmoi apply` (unconditionally) |
| `.chezmoidata/*` | template data (`.packages`, `.fonts`, `.user`) |
| `.chezmoiexternals/*` | external git/archive fetches (e.g. prezto) |
| `.chezmoiignore` | per-OS target exclusions (itself Go-templated) |

Source paths beginning with `.` (e.g. `.taplo.toml`, `.vscode/`,
`.install-prerequisites.sh`) are NOT deployed — chezmoi ignores them except the
`.chezmoi*` specials. Non-dot repo-meta files (`opencode.json`, `LICENSE`,
`AGENTS.md`) must be listed in the root `.chezmoiignore`, or chezmoi would
deploy them into `~/`.

The directories `crates/` and `packages/` are source-only trees excluded from deployment to `$HOME` via `.chezmoiignore`. Instead, they are built on apply by the `.chezmoiscripts/build/` run_onchange scripts:
- `crates/mxm4-haptic/` builds on apply into `~/.local/bin/`. Linux builds three binaries: `mxm4-hapticd`, `mxm4-haptic-notify`, and `mxm4-haptic`. macOS builds only the daemon and client.
- `packages/` is a Bun workspace built on apply with **Vite+** (`vp`) into `~/.config/opencode/plugins/`. This builds `@h82/opencode-playwright-cli-session-injection` (symlinked to `playwright-cli-session-injection.js` on Linux and macOS), `@h82/opencode-scratch-guard` (symlinked to `scratch-guard.js` on Linux and macOS; enforces the temp-file policy via `$TMPDIR` injection + `/tmp`,`/var/tmp`,`/dev/shm` deny), and `@h82/opencode-mxm4-haptic` (symlinked to `mxm4-haptic.js` on Linux). `@h82/mxm4-haptic` is a library, not a plugin.

### Agent skills, MCPs & trust — managed by `dotagents`

- `dotagents` (`getsentry/dotagents`) manages user-scoped agent skills, MCP servers, and a trust allowlist under `~/.agents/`.
- `dot_agents/private_readonly_agents.toml.tmpl` (private 0600 + readonly 0444, templated) renders to `~/.agents/agents.toml` and is the single source of truth. It sets `agents = ["claude", "codex"]`, `minimum_release_age = 10080`, and a `[trust]` allowlist (`github_orgs = [getsentry, microsoft, shadcn]`, `git_domains = [git.jpi.app]`).
- It declares three remote skills — `playwright-cli` (`microsoft/playwright-cli`), `improve` (`shadcn/improve`), `dotagents` (`getsentry/dotagents`) — plus the **seven** local skills under `dot_agents/skills/` as `path:skills/<name>` entries: `ci-cd-monitoring`, `git-workflow`, `gitlab-issues`, `glab`, `glab-stack`, `js-package-managers`, `pr-mr`. The same file also registers the MCP servers (`codegraph`, `context7`, Exa `websearch`, and the Z.ai servers), with secrets injected via `onepasswordRead`.
- Provisioning runs via `.chezmoiscripts/agents/run_after_install-dotagents-skills.sh.tmpl` on every `chezmoi apply` (linux + darwin gate): it runs `dotagents --user install` through `mise exec npm:@sentry/dotagents@latest`, soft-skips on missing mise/git or install failure, and is kept in containers.
- One-time teardown is handled by `.chezmoiscripts/agents/run_once_before_teardown-skills-sh.sh.tmpl`.
- `.github/workflows/update-agent-skills.yml` runs weekly (Tue 06:00 UTC) to bump `@`-pinned remote skill refs to the newest release/commit older than a 7-day cutoff and open a PR; it skips `path:` and `https:` sources. The remote skills are currently declared without an explicit `@ref`, so they settle purely via `minimum_release_age`.
- The managed skill refs observe a 7-day settle (`minimum_release_age = 10080`), while the `dotagents` CLI itself still observes the standard 24h mise cooldown.

### Verify edits (don't eyeball raw `.tmpl`)
- `chezmoi diff` — preview what apply would change. **Primary check after any edit.**
- `chezmoi execute-template < file.tmpl` — render one template in isolation (output depends on OS + `.chezmoidata`).
- `chezmoi cat ~/target/path` — show the rendered target.
- `chezmoi apply` — deploy (also runs the scripts). Binary: `/usr/bin/chezmoi`.

#### When local verification is impossible, verify via the PR's CI + artifacts

If the working environment can't run the checks above (no `chezmoi`, no live KDE
session, no root, no target-distro container — e.g. a sandboxed agent), **do not
claim a change is verified**. State the local limitation plainly, open the PR,
and drive verification from the CI run and its artifacts instead. The
`.github/workflows/render-dotfiles.yml` workflow (PR-triggered) is built for
exactly this:
- **`apply --init (fedora|ubuntu)`** runs a real `chezmoi apply --init` in
  `fedora:latest` / `ubuntu:latest` containers → **`rendered-files-<os>`**
  artifact (managed files rendered into an isolated `$HOME`; scripts/externals
  excluded). Catches template errors in deployed files, and asserts the opencode
  plugin versions rendered from GitHub.
- **`render internals (fedora|ubuntu)`** renders every `.chezmoiscripts/**` and
  `.chezmoiexternals/**` template via `chezmoi execute-template` →
  **`rendered-internals-<os>`** artifact. Per-OS gated scripts render to an empty
  file on the non-matching OS; a `*.render-error.txt` beside an entry flags a
  render failure to inspect.
- **`shellcheck (rendered scripts + repo-meta)`** — `needs: [apply,
  render-internals]`, so it lints the REAL rendered Fedora + Ubuntu output of the
  provisioning scripts (the `.tmpl` files shellcheck can't parse directly) plus
  the non-deployed repo-meta scripts (`.install-prerequisites.sh`, the `.ci`
  smoke test). Findings also land in the **`shellcheck-report`** artifact. This is
  the sole shellcheck gate (it replaced the old source-only `shell-lint` job in
  `ci.yml`), so it is **PR-only** — a direct push to `main` is not shell-linted.

Read the job logs and download the artifacts (they carry `retention-days: 3`) to
confirm what actually rendered before relying on a change. `ci.yml` covers the
rest on both push and PR (TS workspace, Rust crate, Ubuntu Studio pro-audio
smoke).

#### Automated Codex code review — wait for it to finish

When `chatgpt-codex-connector` adds an **eyes** (👀) reaction to a PR (or a
commit/comment on it), an automated Codex code review is **in progress** — do
not treat the PR as reviewed yet. Wait for the review to complete, which
resolves one of two ways:
- **Changes requested** — Codex posts review comment(s) describing items that
  need to be resolved. Address each one (or, if a comment is wrong or
  inapplicable, reply explaining why) before proceeding.
- **LGTM** — Codex replaces the eyes reaction with a **thumbs-up** (👍) and posts
  no blocking comments, signalling the review passed with nothing to resolve.

#### Non-interactive CI/agent verification without real 1Password

For render-only checks in CI or agent verification, **MUST NOT** touch the real
`$HOME` or require a real 1Password sign-in. Use an isolated destination, an
empty scratch config (so the `.chezmoi.toml.tmpl` `read-source-state.pre` hook
does not run), and a PATH-local dummy `op` command that satisfies
`onepasswordRead` calls:

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
cat > "$scratch/bin/op" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1-}" in
  whoami) printf 'dummy@example.invalid\n' ;;
  read|item) printf 'dummy-secret\n' ;;
  *) printf 'dummy-secret\n' ;;
esac
EOF
chmod 700 "$scratch/bin/op"

env PATH="$scratch/bin:$PATH" \
  chezmoi --config "$scratch/empty.toml" \
  --source "$PWD" \
  --destination "$scratch/target" \
  execute-template < .chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl

env PATH="$scratch/bin:$PATH" \
  chezmoi --config "$scratch/empty.toml" \
  --source "$PWD" \
  --destination "$scratch/target" \
  diff --no-pager
```

Evidence from 2026-07-08 on this repo: the command sequence above rendered
`.chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl` with
`execute-template exit=0` and ran full `chezmoi diff --no-pager` with
`diff exit=0` without real `op` authentication. A warning that the config file
template changed is acceptable in this mode because the empty scratch config is
intentional; failures from `op`, prompts, writes under real `$HOME`, or hook
execution are not acceptable.

## Secrets: 1Password only, never in-repo

Secrets are pulled at apply time via `onepasswordRead "op://..."` inside `.tmpl`
files (GPG key, GitHub/Tailscale tokens, opencode API keys under
`dot_config/opencode/private_secrets/`). GitLab CLI auth is not secret-driven:
`~/.local/bin/auth-glab` performs a semi-interactive `glab auth login` OAuth
flow (`--web`/`--device`) on demand instead of provisioning PATs. Never hardcode a secret — add an
`onepasswordRead` reference. The `op` CLI must be able to resolve secrets:
`.install-prerequisites.sh` runs as a `read-source-state` pre-hook to install
1Password and mise first, and `chezmoi diff`/`execute-template` over secret
templates fails if `op` can't read.

**`op whoami` is NOT a reliable "is op usable?" check on an interactive host.**
When `op` is wired to the 1Password desktop app (Settings → Developer →
Integrate with 1Password CLI), the CLI defers authentication to the GUI:
`op whoami` prints `account is not signed in` and exits non-zero until the app
authorizes a request — yet `op read` / `onepasswordRead` still succeed because
the desktop app prompts for biometric unlock on demand. An agent **MUST NOT**
conclude `op` is unusable (or that it cannot inspect an item) from a failing
`op whoami`; assume the user can resolve secrets and proceed, letting an actual
`op read` / `onepasswordRead` be the real test. The container service-account
path is the exception — there `op whoami` is authoritative (see Containerized /
CI environments).

## Single source of truth — edit the data, not the generated script

- **dnf packages / repos / COPRs**: `.chezmoidata/packages.yaml`. The
  `run_onchange_before_fedora.sh.tmpl` renders and installs from it (NVIDIA-GPU
  and bare-metal sections are auto-gated, and it also drives flatpaks, dotnet
  tools, direct-URL RPMs, services, and user groups). Add packages/items there,
  not in the script — editing the data re-triggers the `run_onchange` installer.
- **apt packages / repos (Ubuntu)**: `.chezmoidata/packages.yaml` under `packages.linux.ubuntu.*`. The `run_onchange_before_ubuntu.sh.tmpl` renders and installs from it (NVIDIA packages from CUDA + libnvidia-container repos under the `HAS_NVIDIA` gate, bare-metal, flatpaks, dotnet tools, and direct `.deb`s). Add packages/items there; editing the data re-triggers the installer.
- **Fonts**: `.chezmoidata/fonts.yaml` `legacyFontsList`, pinned per font by
  release tag + sha256. To bump a font: change the tag, re-download, recompute the
  sha256 (a wrong digest aborts that font's install). The bash installer and its
  `.ps1` counterpart both read this list.

## Toolchain quirks

- **mise** owns every runtime/CLI (node, bun, viteplus, go, python, ruby, rust,
  gh, glab, opencode, …) via `dot_config/mise/config.toml`. It enforces a 24h
  `minimum_release_age` cooldown with an excludes list — add fast-moving tools to
  `minimum_release_age_excludes`, don't disable the gate.
- `python3` is mise-shadowed; system scripts needing real system Python must call
  `/usr/bin/python3` (see the solaar config script).
- **JS package-manager hardening lives here and must stay** — `dot_npmrc` sets
  `ignore-scripts=true`, `save-exact=true`, and `min-release-age=0` (npm has no
  cooldown); `dot_bunfig.toml` sets `ignoreScripts=true`, `exact=true`, and
  `minimumReleaseAge=604800`; `dot_yarnrc.yml` sets `enableScripts: false`,
  `defaultSemverRangePrefix: ""`, `enableImmutableInstalls: true`,
  `enableTelemetry: false`, `preferReuse: true`, and `npmMinimalAgeGate: 10080`;
  `dot_config/pnpm/config.yaml` sets `ignoreScripts: true`, `saveExact: true`,
  and `minimumReleaseAge: 10080`. Don't relax them. The `packages/` Vite+
  workspace additionally carries a local `bunfig.toml` that mirrors the Bun
  hardening and adds `linker = "hoisted"` (a single Vitest copy for `vp test`).
- TOML is taplo-formatted; `.taplo.toml` excludes `crates/**`, `packages/**`, `.chezmoidata/**`, and
  `.chezmoiexternals/**` (templated or non-standard TOML). biome LSP is disabled in
  the repo `opencode.json`.

## OS gating & script parity

- Branch on `{{ .chezmoi.os }}` (`linux`/`darwin`/`windows`); exclude whole paths
  per-OS via the nearest `.chezmoiignore` (root, `dot_config/`, `dot_local/bin/`).
  git config splits via `config.tmpl` including `.config_<os>`.
- **Distro detection** is by `.chezmoi.osRelease.id` (`fedora` or `ubuntu`) at template render time, plus runtime bash guards (`$os_id` from `/etc/os-release`). No new chezmoi prompt or persisted data var. Ubuntu Studio reports `ID=ubuntu` like any Ubuntu flavor; the runtime marker if ever needed is the `ubuntustudio-default-settings` package.
- **KDE scripts** (`.chezmoiscripts/linux-kde/*.tmpl`) render on both Fedora and Ubuntu Studio: gate `{{ if and (eq .chezmoi.os "linux") (or (eq .chezmoi.osRelease.id "fedora") (eq .chezmoi.osRelease.id "ubuntu")) -}}`. The runtime `command -v plasmashell` guard still skips non-KDE hosts.
- **Shared system-config** (`run_onchange_after_install-system-config.sh.tmpl`) includes Ubuntu runtime branches: skips the Fedora `plymouthd.conf` deploy on Ubuntu (Ubuntu uses `update-alternatives` for plymouth, not `plymouthd.conf`), and masks `zramswap.service` on Ubuntu via a separate block (never appended to the Fedora mask line — `systemctl mask` writes `/dev/null` even for nonexistent units).
- **Ubuntu-specific scripts** (`linux-ubuntu` gate = `{{ if eq (printf "%s-%s" .chezmoi.os .chezmoi.osRelease.id) "linux-ubuntu" -}}`):
  - `run_onchange_before_ubuntu.sh.tmpl` — apt provisioner (mirrors the Fedora installer with apt semantics; idempotent, all service/group steps guarded)
  - `run_after_ubuntu-tailscale-ufw.sh.tmpl` — sets `DEFAULT_FORWARD_POLICY=ACCEPT` and inserts a marker-delimited `*nat`/`MASQUERADE` block in `/etc/ufw/before.rules`; idempotent
  - `run_after_ubuntu-plymouth-bgrt.sh.tmpl` — points the `default.plymouth` update-alternatives link at the neutral `bgrt` theme (firmware/OEM logo, same theme Fedora defaults to) + `update-initramfs -u`; idempotent (no-op when already bgrt), config-override only. Fedora already ships `Theme=bgrt`, so it has no counterpart script.
  - Ubuntu Studio pro-audio: `packages.yaml` audio essentials (4 pkgs: `ubuntustudio-audio-core`, `ubuntustudio-pipewire-config`, `ubuntustudio-performance-tweaks`, `ubuntustudio-lowlatency-settings`), the `audio` group added in `configure_user_groups()`, and the ubuntu-gated `system/linux/etc/security/limits.d/95-ubuntustudio-audio.conf` realtime limits drop-in.
- **De-branded** (both Fedora and Ubuntu Studio; GRUB is left native by choice): each distro's shipped desktop branding is reverted to stock across four surfaces — the desktop to Plasma/Breeze, the boot splash to the neutral `bgrt` (firmware-logo) theme — **config-override only, no branding package is purged (and none is added)**:
  - **Global Theme**: one cross-distro script, `config-kde-autotheme` (Fedora + Ubuntu Studio, `(or fedora ubuntu)` gate), puts Plasma's default Breeze Global Theme on automatic day/night switching: `AutomaticLookAndFeel=true` + `DefaultLightLookAndFeel=org.kde.breeze.desktop` / `DefaultDarkLookAndFeel=org.kde.breezedark.desktop` + an initial `LookAndFeelPackage=org.kde.breezedark.desktop` pin (automatic Breeze Dark ⇄ Light, timed off the Night Light schedule). On Plasma < 6.5 the auto-switch keys are silently ignored, so it degrades to the `LookAndFeelPackage` Breeze Dark pin. The Plasma session's icon theme, cursor, and splash follow the active Breeze variant on next login. (The former `config-kde-darkmode` Breeze-Dark-pin script was removed in favour of this.)
  - **Boot splash (Plymouth) → `bgrt`**: the `bgrt` theme renders the firmware/OEM boot logo instead of a distro splash. Fedora already ships `Theme=bgrt` in `system/linux/etc/plymouth/plymouthd.conf` (its native default), so there is no Fedora action — no theme swap, no initramfs rebuild. Ubuntu owns plymouth via the `default.plymouth` update-alternatives link, so `run_after_ubuntu-plymouth-bgrt.sh.tmpl` (`linux-ubuntu` gate) points it at `bgrt` + `update-initramfs -u`, idempotent on the alternative's current value and skipped when the `bgrt` theme (from `plymouth-theme-ubuntu-logo`) is absent. `breeze` plymouth was deliberately NOT used: it is not guaranteed installed on either KDE base, so pointing at it risked a broken splash.
  - **Login greeter (SDDM)**: `system/linux/etc/sddm.conf.d/90-breeze.conf` (`[Theme] Current=breeze`) deploys to both distros via the system tree; the `90-` prefix outranks vendor drop-ins. `install-system-config` skips deploying it when `/usr/share/sddm/themes/breeze/theme.conf` is absent (forcing a missing theme breaks the login screen). This path was previously an orphan in `REMOVED_ETC_PATHS`; that entry is dropped now that the file is shipped again.
  - **Wallpaper**: `run_after_config-kde-wallpaper-breeze.sh.tmpl` (`(or fedora ubuntu)` KDE gate) applies Plasma's default "Next" wallpaper via `plasma-apply-wallpaperimage`, live-session-guarded, **exactly once** (per-user stamp under `${XDG_STATE_HOME:-~/.local/state}/chezmoi/`) so a wallpaper the user later picks is never reverted.
- **Mechanism deltas** (Fedora-only infra, not gaps): KR mirror lists and RPM Fusion/COPRs have no Ubuntu equivalent; Ubuntu provisioning uses multiverse + vendor apt repos plus CUDA/libnvidia-container NVIDIA packages under the `HAS_NVIDIA` gate instead.
- POSIX scripts/wrappers keep a Windows `.ps1` counterpart in sync
  (`executable_code`/`.ps1`, `executable_opencode`/`.ps1`). Files migrated from the
  legacy nix/dotbot config are now the source of truth here — don't defer back to
  the old repo.

## Containerized / CI environments

Runtime-detected, no prompt: Podman creates `/run/.containerenv`, Docker creates
`/.dockerenv` (neither exists on a bare-metal host or VM, so a normal host
`chezmoi apply` is unaffected). Both the root `.chezmoiignore` (via `stat`) and
`.install-prerequisites.sh` (via `is_container()`) branch on these markers.
Intended for CI runners and dedicated containers with their own `$HOME`.

**distrobox and toolbox are the explicit opt-out** — both bind-mount the host
`$HOME` and both create `/run/.toolboxenv` (distrobox `touch`es it for toolbx
prompt compatibility), so an apply inside one targets the real host `$HOME` and
must provision fully like the host, not skip. Detection therefore skips only a
*real* container: a Podman/Docker marker present **without** `/run/.toolboxenv`
(`is_devbox()` in the hook; a `(not (stat "/run/.toolboxenv"))` guard in
`.chezmoiignore`). Keep the two detection sites in lockstep — same markers, same
sense — or the hook and the ignore set will disagree.

- **Only the CLI dotfiles deploy in a container.** The `.chezmoiignore` container
  block skips every provisioning script — `.chezmoiscripts/{linux,linux-kde,auth,gpg}/*.sh`
  plus `.chezmoiscripts/build/*mxm4-haptic.sh` (no package installs, `/etc` config,
  GPG/GitHub/Tailscale auth, fonts, KDE settings, pro-audio realtime provisioning, or
  MX Master haptic build). The opencode plugin build (`build-opencode-plugins`) and
  the dotagents skills install (`run_after_install-dotagents-skills`) are deliberately
  KEPT — opencode is a first-class CLI here and it soft-skips when mise is absent,
  while dotagents soft-skips on missing prerequisites and preflights `~/.claude/skills`.
  Adjust skips in that one gated block, never by editing the scripts.
- **No package installs in a container.** `.install-prerequisites.sh` expects `op` +
  `mise` from the base image; it never runs dnf/apt/brew inside a container and fails
  fast with guidance when either is missing.
- **Secrets via a 1Password service account.** Export `OP_SERVICE_ACCOUNT_TOKEN`
  before applying; `op_ready()` prefers `op whoami` (works for service accounts;
  `op user get --me` is the human-account fallback), so `onepasswordRead` templates
  resolve exactly as on a host.

## Commits

Conventional Commits (per the global rules), scoped by area — history is mostly
`chore(<area>)`, e.g. `chore(fedora)`, `chore(scripts)`, `chore(tailscale)`.
Trunk-based on `main`; **always `git push` to `origin/main` immediately after
committing** (single-maintainer repo, no PR/review gate).
