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

## Parity with the former chezmoi setup

The comparison baseline is commit `501dfdf`, as requested in [issue #133](https://github.com/hyperlapse122/dotfiles/issues/133).
The table records repository and sandbox evidence; actual-machine checks remain separate.

| Issue gap | Disposition | Evidence or reason |
| --- | --- | --- |
| Automatic updates | Implemented | `prezto-release` discovers upstream's default branch, resolves every recursive gitlink, hashes downloaded archives, and atomically replaces the complete pin; the dependency workflow verifies it before publication. |
| Submodule coverage | Verified in the package | All nine historically selected submodules remain pinned; the complete upstream tree also includes `fasd`, making eleven archives including Prezto itself. Install checks compare assembled submodule content and load sorin, powerline, agnoster, pure, and powerlevel10k. |
| Module order | Restored | Utility precedes Git; interactive checks assert the selected order. |
| Color style | Already supplied | The pinned Home Manager Prezto module emits the enabled color style; the interactive check queries it. Prezto retains its upstream behavior for dumb terminals. |
| Conditional modules | Restored | Git requires `git`; Homebrew requires Darwin and `brew`; GPG requires `gpg-agent` and both SSH guard conditions. Generated module selection is executed with present and absent command fixtures. |
| GPG_TTY | Already supplied | Interactive startup exports a nonempty terminal TTY; PTY checks verify it and preserve an existing SSH-agent socket under each guard. |
| Completions | Verified | The package supplies codex, gh, glab, ghq, mise, and usage functions; interactive shells verify all six registrations and function definitions. Bash executes `_init_completion` through Home Manager's bash-completion package. |
| mise activation | Already supplied | Home Manager emits mise's zsh activation; runtime checks require its shell hook. |
| Environment | Completed | `NODE_USE_SYSTEM_CA=1` is retained and local binaries precede profile tools. Mise may prepend its shims, as it did after the old environment loader. The retired chezmoi helper-bin path is unnecessary for store-managed tools. |
| Single initialization | Verified | Login and non-login shells initialize Prezto exactly once, checked through execution tracing. History keeps its XDG state path, 10,000-entry limits, extended format, duplicate handling, and sharing. |
| User-owned files | Documented and verified | Actual generated collision checks preserve conflicting contents, accept identical files and managed links, and leave root `.zshrc` unmanaged. Fresh-shell checks prove the old root `.zshrc` is inactive. |

The old bash-completion 2.18.0 asset was loaded by the Bash branch of `home/.chezmoitemplates/cli-completions-shell`.
The zsh branch used native zsh completions; it did not enable a Bash-completion bridge.
Nix supplies Bash completion through Home Manager, so the separate chezmoi asset and loader are unnecessary.

The `fasd` archive retains a dangling link to a manual page that upstream removed.
Packaging removes that one unusable documentation link while retaining the executable and the default broken-symlink check.
Archive hashes still cover the original downloaded bytes; normal Nix shebang adaptation also applies to installed scripts.

## Updating Prezto

The existing dependency workflow runs every 30 minutes and can also be dispatched manually.
It runs the packaged helper and includes its pin in the normal formatting, flake-check, and VM verification path.
A failed refresh exits nonzero, preserves the previous pin, and stops that update run.
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
In each actual terminal, open login and non-login zsh sessions and confirm the sorin prompt, emacs bindings, six CLI completions, mise activation, and absence of startup errors.
Use history across two sessions to confirm persistence and sharing, and check that the intended SSH-agent socket remains selected.
Repository checks and CI do not establish those hardware results.
