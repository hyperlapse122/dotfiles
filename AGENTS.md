# AGENTS.md

This is the chezmoi **source state** for `github.com/hyperlapse122/dotfiles`. Edit this checkout, never deployed `$HOME`; apply only when the user asks for deployment. The common guardrails in `dot_agents/readonly_AGENTS.md` are binding; this file is the repository supplement and may add stricter local rules. `CLAUDE.md` must remain exactly `@AGENTS.md`.

## Source layout and attributes

Chezmoi source names encode targets: `dot_foo` -> `~/.foo`, `*.tmpl` is rendered, `private_` is 0600, `readonly_` is 0444, `executable_` is executable, `encrypted_*.asc` is gpg ciphertext, `.chezmoiscripts/run_once_*` runs once ever, `.chezmoiscripts/run_onchange_*` reruns when rendered content changes, `.chezmoiscripts/run_after_*` runs every apply, `.chezmoidata` is data, `.chezmoitemplates` is shared template code, `.chezmoiexternals` is fetched tooling, and `.chezmoiignore` is templated exclusion. Dot-prefixed source paths are internal; non-dot metadata (`AGENTS.md`, `LICENSE`, `opencode.json`) MUST be listed in the root `.chezmoiignore`. `crates/` and `packages/` are source-only build trees.

Edit source files, not deployed files. The source directory itself is the only valid source context; nested worktrees cause recursive data errors, so checks MUST use `--source "$PWD"`. Never commit secrets.

## Apply lifecycle and script tree

Prefer `run_onchange_before_`/`run_onchange_after_` with a comment-only dependency fingerprint over unconditional `run_after_`. Keep bare `run_after_` only when live state must be retried on every apply. Fingerprint raw source content, including unresolved `op://` refs, never rendered secrets or build output. The shared `.chezmoitemplates/fingerprint.tmpl` contract is:

```gotemplate
{{ $sourceDir := .chezmoi.sourceDir -}}
{{ includeTemplate "fingerprint.tmpl" (dict "sourceDir" $sourceDir "globs" (list "path/to/source" "other/**")) }}
```

The partial hashes file content, uses `(stat .).isDir` to skip directories/output directories, and MUST NOT hash a rendered secret. A script with no external dependency hashes only its own rendered content; document that explicitly. A clean exit-0 skip is recorded as successful and will not retry until a fingerprint changes or `chezmoi apply --force` is used; retain `run_after_` only when that retry behavior is essential.

Never add teardown/revert scripts. Delete managed source, use `.chezmoidata/system.yaml` `removed:`, or document a one-time manual reversal. Numeric `.chezmoiscripts/` directories establish phase order; existing `run_*` naming and numeric ordering may be extended, and renaming an onchange script reruns it once per host.

| Directory | Responsibility |
|---|---|
| `00-tools` | trust repo mise; link/prune versioned CLIs; prune old compound-engineering trees |
| `10-auth` | GitHub/GitLab/Docker auth and Tailscale login |
| `20-linux-fedora`, `40-linux-ubuntu` | data-driven dnf/apt provisioning, repos, Secure Boot/NVIDIA |
| `30-linux` | `/etc` manifest, host/network, chsh, Solaar, TPM2, Wi-Fi, browser, Podman, VSCodium |
| `50-linux-kde`, `50-linux-gnome` | desktop configuration |
| `60-build` | Rust haptic and Vite+ agent-plugin builds |
| `70-agents` | dotagents, plugins, Claude values, Pi extensions/auth |
| `80-keys` | one-time GPG and age imports |
| `90-src` | reconcile the `~/src` garden on manifest change (grow-all, the three bootstrap commands, aoe group self-heal); runs last so a garden failure cannot abort other provisioning |

## Host facts, gates, and system configuration

`.chezmoidata/facts.yaml` is the sole host-identity registry: each fact has a type, `hook`/safe template/builtin probe, gates, and fail-safe `whenFalse`. Hook facts are written once per chezmoi command by `.install-prerequisites.{sh,ps1}`; template facts come from `.chezmoitemplates/facts.tmpl`. The hook's `is_container`/`is_devbox` predicate and `facts.tmpl` predicate MUST remain byte-for-byte lockstep: a real container is `/run/.containerenv` or `/.dockerenv` without `/run/.toolboxenv`; distrobox/toolbox is treated as the host. Windows retains the all-false mirror.

Gate grammar is `<fact>`, `!<fact>`, or `<fact>.<value>`; YAML values beginning `!` MUST be quoted. `facts-validate.tmpl` rejects unknown facts, missing probes, invalid comparisons, malformed desktop values, and undeclared emitted facts. Consumers use only `facts.tmpl`, `facts-sh.tmpl`, and `facts-gate.sh.tmpl`, never the cache. Every fact is render-time and fail-safe: false MUST skip rather than grant. `FORCE_NVIDIA` and `FORCE_INTEL` are installer-only overrides, never facts or system-file gates; `INSTALL_SYSTEM_CONFIG_FORCE` layers only on the headless guard. `stat` is required before absolute `include`; `glob` does not traverse symlinks; never use template `output` for a fact probe. Runtime scripts call shared `fact_gate()` and MUST NOT duplicate gate logic. Shared script guards receive `(dict "ctx" . "name" ...)`, not a bare name. `host-facts` is read-only and always exits 0.

`system/linux/etc/**` mirrors `/etc`; `.chezmoidata/system.yaml` owns mode, gate, check, distro-scoped `removed:`, and reload behavior. Edit the manifest and tree, not installers. `install-system-10-files`, `20-host`, and `30-network` have independent onchange triggers. Reload only changed services; Bluetooth restarts only when Bluetooth files differ. Network changes can restart firewalld, resolved, NetworkManager, and Tailscale. GDM greeter fingerprint login MUST remain disabled while in-session fingerprint remains available. Polkit may add `pam_fprintd` only when the Debian `common-auth` conjunction is true; MUST NOT use `pam-auth-update` or a `common-auth` integration for fingerprint support, because it would re-enable greeter fingerprint authentication and break the GDM/Fedora polkit boundary. Sudo remains password-only. Fcitx5 is the KDE/GNOME input method; the GNOME autostart entry MUST NOT add `X-GNOME-Autostart-Phase`. TPM2 uses the shared dracut/systemd-cryptenroll backend and blank/missing credentials skip. Plymouth remains distro-native; SDDM Breeze is gated on its installed theme.

## Agent surfaces and ownership

All agent data is in `.chezmoidata/agents.yaml`. MCPs are transport-neutral and feed dotagents, Pi, and OpenCode. `op://` strings resolve only at render; OAuth entries stay headerless for native stores, while Pi receives `auth: oauth` and `lifecycle: eager`. Figma/Pi and OpenCode authorization is on-demand via `figma-auth`; never commit tokens.

`dot_agents/private_readonly_agents.toml.tmpl` is user-scoped **Claude/Codex only**: it owns their MCP/trust configuration and the `~/.claude/skills` -> `~/.agents/skills` symlink path. It MUST NOT own OpenCode config (`~/.config/opencode/opencode.json` is managed separately), MUST NOT carry hooks, and MUST NOT overwrite hooks. Hooks belong in plugins; live Claude `settings.json` and aoe/settings hooks MUST be preserved. External skills come from `agents.skills.external` -> `.chezmoiexternals/ai-agents.toml` -> `~/.agents/skills/<name>`; keep the exact isolated subtree and no pin-bump workflow. GitLab-sourced skills (glab, glab-stack) are raw single-file externals (`type = "file"` on `<name>/SKILL.md`) pinned to the glab release via `.chezmoitemplates/glab-release-ref.tmpl`, which `.chezmoiexternals/vcs.toml`'s glab binary also consumes, so the skills and the CLI never diverge by configuration. Locally-authored personal skills (unpublished, e.g. `daily-report`) are managed directly as chezmoi source under `dot_agents/skills/<name>/` and deploy to the same `~/.agents/skills/<name>` — dotagents stays MCP-only and does not manage them. Compound-engineering is one versioned local archive for OpenCode/Claude/Codex/AGY; AGY installs its native bundle root, while Pi deliberately installs its native unpinned `git:` package. The mxm4-haptic plugin ships to Claude, Codex, AND AGY from local marketplaces (Claude/Codex carry a `hooks/hooks.json`; AGY carries a ROOT `hooks.json` wired to bundled helper scripts, because `agy plugin validate` only recognizes a root hooks file, not a `hooks/` dir); its hook wrappers are silent/exit-0 no-ops that never block or slow a turn — Codex leaves `SubagentStop` unhooked (root-only gating), AGY gates its Stop buzz on `fullyIdle`, and the AGY `ask_question` PreToolUse hook ALWAYS returns `{"decision":"allow"}` so it can never deny a tool. Codex has no failed waveform (its Stop payload carries no error field); its plugin hooks merge with the aoe-managed `~/.codex/hooks.json`. Pi settings are managed readonly, packages reconcile with `pi update --extensions`, auth is a 0600 read-merge-write preserving Pi OAuth, and models are a managed empty-provider baseline. OpenCode plugins use `<pkg>@file:<absolute-path>`, not a bare absolute path.

## Verification (never deploy live `$HOME`)

The default check uses a per-user scratch directory, stub `op`, empty config, throwaway destination, and `--source "$PWD"`; use the zsh chezmoi wrapper for normal commands, or inject `GITHUB_TOKEN="$(gh auth token)"` when PATH must be controlled. The stub must return newline-free secrets when parsing rendered JSON/TOML. With no readiness marker present (the default), the secret-read / resolve-op-refs cache shims fall back to live `onepasswordRead`, so the `op` stub covers them; to exercise the GPG cache path instead, set `~/.config/chezmoi/gpg-cache-ready` and pass a gpg `--config` carrying the recipient so `decrypt` runs. Render every changed template/script through `chezmoi execute-template`; scripts are not targets and MUST be compared as rendered text on both sides. Disclose any onchange side effects, especially network/service restarts; the first apply that reruns `install-system-30-network` MUST be performed from a local console, not SSH/Tailscale.

`git diff --check`, `git status`, and a diff limited to the requested scope are required. `CLAUDE.md` MUST remain exactly `@AGENTS.md`; wrappers remain bare one-line includes. `chezmoi archive --exclude=encrypted,externals,scripts` may compare extracted target trees, but archive bytes are not comparable by mtime and the archive omits scripts; compare rendered scripts separately and state that blind spot. If local rendering is unavailable, use CI artifacts from `.github/workflows/render-dotfiles.yml` and state the limitation. After a PR receives a `chatgpt-codex-connector` eyes reaction, wait for it to resolve to blocking review comments (address/reply to each) or a thumbs-up before treating review as complete.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/60-build/run_onchange_after_build-opencode-plugins.sh.tmpl
```

## Secrets and encrypted state

Secrets are resolved cache-first: the `secret-read.tmpl` / `resolve-op-refs-json.tmpl` shims read a committed GPG-encrypted bundle (`.chezmoitemplates/secrets-bundle.json.asc`, refreshed from 1Password by `chezmoi-secrets-sync`) when the GPG key is ready, else fall back to live `onepasswordRead "op://..."`; the GPG key import is the one always-live-`op` site. The sanctioned repository ciphertexts are that secrets bundle and `src/encrypted_readonly_garden.yaml.asc` (both GPG); edit the garden via the wrapper (`chezmoi edit ~/src/garden.yaml`), never commit plaintext. Host LUKS/MOK prompts are AES-encrypted with a key only in the user keyring; read consumers fail soft when unavailable, and only the nonblank prompt path may create a key. Never infer that desktop-mediated `op read` is unavailable from a failed interactive `op whoami`. GitLab PAT setup is data-driven; `auth-glab` remains OAuth fallback.

## Single source of truth

Edit data, not generated scripts or rendered targets:

| Data | Consumers |
|---|---|
| `.chezmoidata/facts.yaml` | host identity, `gate:`/`gates:` decisions, probes and fail-safe direction |
| `.chezmoidata/packages.yaml` | Fedora/Ubuntu packages, repos, COPRs/PPAs, flatpaks, dotnet, direct packages, services/groups |
| `.chezmoidata/fonts.yaml` | font archives, families, sizes and fallbacks for KDE/GNOME/fcitx/VSCodium |
| `.chezmoidata/vscodium.yaml` | additive VSCodium extension installer |
| `.chezmoidata/solaar.yaml` | device settings/rules and restart fingerprint |
| `.chezmoidata/networking.yaml` | Wi-Fi importer, DNS defaults/overrides, unresolved-ref fingerprint |
| `.chezmoidata/kde.yaml`, `.chezmoidata/gnome.yaml` | desktop manifests and tunables |
| `.chezmoidata/haptic.yaml` | daemon/notify environment and Claude/Pi/Codex/AGY event waveforms |
| `.chezmoidata/agents.yaml` | MCPs, skills, marketplaces/plugins, Claude values, Pi settings/packages/auth/models, OpenCode providers/plugins/models |
| `.chezmoidata/system.yaml` | `/etc` manifest gates/modes/checks/removals |
| `dot_agents/readonly_AGENTS.md` | common instruction source; wrappers are one-line includes |
| `src/encrypted_readonly_garden.yaml.asc` | private `~/src/garden.yaml` registry (GPG) |
| `.chezmoitemplates/secrets-bundle.json.asc` | GPG secrets cache (`chezmoi-secrets-sync` <- 1Password), read by the secret-read / resolve-op-refs shims |

Standalone release CLIs belong in grouped `.chezmoiexternals/{ai-agents,dev-tools,vcs,k8s,system,fonts}.toml`; language runtimes/registry backends belong in mise. Keep `rust-analyzer` external plus rustup component, use `/usr/bin/python3` for system scripts, and preserve npm/Bun/Yarn/pnpm hardening.

## OS, desktop, and containers

Branch templates on `.chezmoi.os` and distro on `.chezmoi.osRelease.id`; keep POSIX scripts and Windows `.ps1` counterparts aligned. KDE/GNOME scripts use the desktop fact and soft-skip missing runtime/session tools. GNOME remains stock except data-driven listed exceptions, fonts, fcitx5, and password-only GDM. Ubuntu and Fedora have separate package mechanisms but share facts. Do not turn runtime tool presence into a host fact.

A real container is `/run/.containerenv` or `/.dockerenv` without `/run/.toolboxenv`; the `facts.tmpl` and `.install-prerequisites.sh` `is_container`/`is_devbox` predicates MUST stay in lockstep. Containers skip package/system/auth/desktop/haptic provisioning, garden, and the GPG key, but keep CLI dotfiles, `00-tools`, OpenCode plugin build, Claude/Codex dotagents, compound-engineering, and Pi. No package installation occurs in a container. Change container skips only in the single gated `.chezmoiignore` block, never by editing scripts. `OP_SERVICE_ACCOUNT_TOKEN` is the CI secret path.

## Repository delivery

Remain on the current branch; the common branch/commit/CI rules apply and this supplement may be stricter. Before a commit, verify the branch and Git Flow prefix unless it is the default branch. Keep changes within the requested scope, use lowercase Conventional Commits, and after any push watch both `render-dotfiles.yml` and `ci.yml` to terminal success.
