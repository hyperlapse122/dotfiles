# Shell configuration

Home Manager owns zsh startup under `~/.config/zsh` and the root `~/.zshenv` bridge that selects it.
Prezto comes from `packages/prezto-pin.json`; its installed runcom loads the framework by store path, so a fresh account needs no `~/.zprezto` checkout.

## Migrating an existing account

Home Manager does not merge arbitrary startup code into these files.
A differing unmanaged `~/.zshenv` or file at a managed XDG destination stops the collision check before Home Manager replaces files.
This repository configures no shell-specific force or automatic backup policy.
Identical-content files are accepted and may remain regular files; existing Home Manager links are accepted.

Before the owner applies the configuration:

1. Inspect `~/.zshenv`, `~/.zshrc`, and the files under `~/.config/zsh` for customizations worth retaining.
2. Move conflicting unmanaged files to uniquely named backups outside the managed destinations, preserving their contents.
3. Port wanted customizations into the repository's shell declarations before applying the configuration.

An old root `~/.zshrc` remains untouched because Home Manager declares the XDG `.zshrc` instead.
Once the root bridge selects ZDOTDIR, zsh reads the XDG file; custom lines left only in root `.zshrc` are inactive.
Backups are not sourced automatically.

On NixOS, an unchanged Home Manager generation does not necessarily activate again during an unchanged system rebuild.
The macOS integration invokes Home Manager activation directly on each apply.
See [generations](../CONCEPTS.md#generations) and [activation reassertion](../CONCEPTS.md#coding-agent-configuration) for those distinctions.

## Updating Prezto

The unified maintenance workflow runs every 30 minutes and can also be dispatched manually with `part: dependencies` or `part: all`.
Prezto belongs to the dependency candidate, which starts from current main after catalog publication.
It runs the packaged helper and includes its pin in the normal formatting, flake-check, and VM verification path, repeated after each changed-main rebase.
A failed refresh exits nonzero, preserves the previous pin, and stops the dependency candidate; catalog updates remain independent.
Verification failures use the workflow's existing reconciliation path.

On a Linux builder, from the repository root:

```sh
nix run .#prezto-release -- --output packages/prezto-pin.json
nix run .#prezto-release -- --check --output packages/prezto-pin.json
```

Both commands require GitHub API access through `gh`; the packaged helper supplies `gh` and `curl`.
`--check` reports a stale pin without writing it.

## Verification

The `zsh-prezto` check runs interactive login and non-login shells in PTYs from copies of materialized startup files and the built profile.
It relocates only account paths and the session-variable script into disposable homes, keeping package paths and production startup logic.
It also executes the generated collision-check activation block against distinct existing files.
The check is declared for Linux and Darwin production and bootstrap environments; Darwin execution requires a Darwin builder.

```sh
nix build --no-link .#checks.x86_64-linux.zsh-prezto
nix build --no-link .#checks.x86_64-linux.prezto-release
nix build --no-link .#checks.x86_64-linux.update-dependencies-reconcile
```

Actual-host verification remains pending until the owner applies the intended generation and checks both machines.
In each actual terminal, open login and non-login zsh sessions and confirm the sorin prompt, emacs bindings, seven CLI completions, mise activation, and absence of startup errors.
Use history across two sessions to confirm persistence and sharing, and check that the intended SSH-agent socket remains selected.
Repository checks and CI do not establish those hardware results.
