# Harness Plugins and AI Agent Configuration

This guide explains how dotfiles installs and manages the [Compound Engineering](https://github.com/EveryInc/compound-engineering-plugin) plugin for oh-my-pi (omp), controls plugin auto-update policies, performs repairs and rollbacks, and wires shared user-scope agent instructions.

## Compound Engineering Plugin for omp

Dotfiles installs Compound Engineering at user scope for the standard omp environment across Windows, Linux, and macOS.

### Architecture

1. **Declarations (`home/.chezmoidata/harness-plugins.json`):** Tracks upstream repository, tag prefixes, and marketplace metadata. Alternate-host symlinks are excluded to ensure smooth installation on Windows without elevated privileges.
2. **Lockfile (`home/.chezmoidata/harness-plugin-lock.json`):** Tracks verified release tags and exact commit SHAs.
3. **Local Marketplace:** Chezmoi extracts the archive into `~/.local/share/dotfiles/harness-plugins/compound-engineering`, registers it as a local marketplace, and runs `omp plugin install --scope user --force` and `omp plugin enable`.

> **Operational Rule:** **Always apply with omp closed.** Starting a new omp session after apply loads the updated skills.

## Disabling Marketplace Auto-Updates

The repository configures omp's mutable configuration (`~/.omp/agent/config.yml` or `config.yaml`):

```yaml
marketplace:
  autoUpdate: "off"
```

> **Important:** This disables background automatic updates for **all** omp marketplace plugins, not only Compound Engineering. This guarantees that your tool versions remain predictable and locked to repository commits.

The template preserves all other settings, custom profiles, and model credentials. If legacy `settings.json` or `agent.db` files exist, apply stops to let omp perform native first-run migration before writing YAML.

## Repair and Rollback

### Manual Cache Repair

If plugin cache files become corrupted or skills are accidentally disabled, run these commands with omp closed:

```sh
omp plugin marketplace update compound-engineering-plugin
omp plugin install --scope user --force compound-engineering@compound-engineering-plugin
omp plugin enable --scope user compound-engineering@compound-engineering-plugin
```

### Version Rollback

To roll back Compound Engineering to an earlier version:
1. Revert `home/.chezmoidata/harness-plugin-lock.json` to the target commit in Git.
2. Run `chezmoi apply` or `mise run apply`.
3. Dotfiles reconciles the dedicated directory and force-reinstalls the pinned commit.

## Refreshing Plugin Pins

To query GitHub for the latest stable release and update the lockfile:

```sh
mise exec -- python scripts/update-harness-plugin-lock.py
```

### Automated Updates

A GitHub Actions workflow (**Update harness plugin pins**) runs daily at 06:43 UTC, validating release tags and commit SHAs against the native test matrix before committing to `main`.

## Shared User-Scope Agent Instructions

Every managed AI harness in this repository wires its native instruction file to a shared template:
- **Shared Source:** `home/.chezmoitemplates/agent-instructions`
- **Native omp Target:** `~/.omp/agent/AGENTS.md` (generated via `home/private_dot_omp/private_agent/private_empty_AGENTS.md.tmpl`)

Applying dotfiles replaces `~/.omp/agent/AGENTS.md` with the rendered repository version. The source is initially empty of policies, preserving an owner-only empty file until rules are authored.

> **Scope Note:** In omp, `~/.omp/agent/AGENTS.md` applies to the main interactive session and advisors. Task subagents do not inherit files named `AGENTS.md`.

For the technical procedure to onboard a new AI harness, see [Chezmoi Source Maintenance](../maintenance/chezmoi-source.md#shared-user-scope-harness-onboarding).

## Verification

To run isolated plugin integration tests:

```sh
mise exec -- python tests/smoke_harness_plugins.py
```

This verifies local marketplace cutover, automatic update policies, skill discovery, and preservation of unrelated plugins in a disposable sandbox.
